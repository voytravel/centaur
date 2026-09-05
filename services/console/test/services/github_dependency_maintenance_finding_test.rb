require "test_helper"

class GithubDependencyMaintenanceFindingTest < ActiveSupport::TestCase
  test "parses one approval-required security proposal into a scoped action input" do
    finding = GithubDependencyMaintenanceFinding.find_for_approval(
      run: maintenance_run(
        security: {
          "mode" => "approval_required",
          "outcome" => "observed",
          "alert_numbers" => [ 19 ]
        },
        proposals: [
          {
            "kind" => "security_advisory",
            "action" => "draft_pr",
            "source_numbers" => [ 19 ]
          }
        ]
      ),
      repository: "acme/widgets",
      finding_key: "security:19"
    )

    assert_equal "security alert #19", finding.source_label
    assert_equal "Create a scoped Draft PR", finding.action_label
    assert_equal "https://github.com/acme/widgets/security/dependabot/19", finding.source_url
    assert_equal(
      {
        "source_run_id" => "run-observation-1",
        "repository" => "acme/widgets",
        "base_branch" => "main",
        "finding" => {
          "key" => "security:19",
          "kind" => "security_advisory",
          "action" => "draft_pr",
          "source_numbers" => [ 19 ]
        },
        "approved_by" => "usr_approved"
      },
      finding.action_input(approved_by: "usr_approved")
    )
    assert_equal "github-dependency-maintenance-action:run-observation-1:security:19", finding.idempotency_key
  end

  test "parses a repair proposal only when it matches the observed Dependabot outcome" do
    run = maintenance_run(
      dependabot: {
        "mode" => "approval_required",
        "outcome" => "repair_needed",
        "source_pr_numbers" => [ 42 ]
      },
      proposals: [
        {
          "kind" => "dependabot_pull_request",
          "action" => "repair",
          "source_numbers" => [ 42 ]
        }
      ]
    )

    findings = GithubDependencyMaintenanceFinding.for_run(run)
    assert_equal 1, findings.length
    finding = findings.first

    assert_equal "dependabot:42", finding.key
    assert_equal "Repair the existing Dependabot PR", finding.action_label
    assert_equal "https://github.com/acme/widgets/pull/42", finding.source_url
    assert_match(/ordinary non-force update/, finding.action_explanation)
  end

  test "parses a ready Dependabot merge proposal only when it matches the observed direct path" do
    run = maintenance_run(
      dependabot: {
        "mode" => "approval_required",
        "outcome" => "direct_ready",
        "source_pr_numbers" => [ 42 ]
      },
      proposals: [
        {
          "kind" => "dependabot_pull_request",
          "action" => "merge",
          "source_numbers" => [ 42 ]
        }
      ]
    )

    finding = GithubDependencyMaintenanceFinding.find_for_approval(
      run: run,
      repository: "acme/widgets",
      finding_key: "dependabot:42"
    )

    assert_equal "Merge the ready Dependabot PR", finding.action_label
    assert_match(/squash-merge/, finding.action_explanation)
    assert_match(/can merge only if GitHub still accepts/, finding.approval_confirmation)
    assert_match(/may squash-merge only the revalidated ready/, finding.queued_notice)
  end

  test "parses an approval finding from the Python workflow-host result envelope" do
    run = maintenance_run(
      security: {
        "mode" => "approval_required",
        "outcome" => "observed",
        "alert_numbers" => [ 19 ]
      },
      proposals: [
        {
          "kind" => "security_advisory",
          "action" => "draft_pr",
          "source_numbers" => [ 19 ]
        }
      ]
    )
    payload = run.fetch("result")
    run["result"] = {
      "output" => payload,
      "run_id" => "run-observation-1",
      "steps" => [ "python_host" ],
      "task_id" => "task-observation-1",
      "workflow_name" => "github_dependency_maintenance"
    }

    finding = GithubDependencyMaintenanceFinding.find_for_approval(
      run: run,
      repository: "acme/widgets",
      finding_key: "security:19"
    )

    assert_equal "security:19", finding.key
    assert_equal "Create a scoped Draft PR", finding.action_label
  end

  test "parses an approval finding from the current observation schema" do
    finding = GithubDependencyMaintenanceFinding.find_for_approval(
      run: maintenance_run(
        schema_version: "3",
        security: {
          "mode" => "approval_required",
          "outcome" => "observed",
          "open_total" => 52,
          "alert_numbers" => [ 52 ]
        },
        proposals: [
          {
            "kind" => "security_advisory",
            "action" => "draft_pr",
            "source_numbers" => [ 52 ]
          }
        ]
      ),
      repository: "acme/widgets",
      finding_key: "security:52"
    )

    assert_equal "security:52", finding.key
  end

  test "renders only a fixed diagnostic for a rejected observer result" do
    diagnostics = GithubDependencyMaintenanceFinding.diagnostics_for_run(
      maintenance_run(
        schema_version: "3",
        security: { "outcome" => "blocked" },
        dependabot: { "outcome" => "blocked" },
        diagnostic: {
          "kind" => "observer_result_rejected",
          "code" => "obsolete_proposal_shape",
          "summary" => "untrusted model text must never render"
        }
      )
    )

    assert_equal 1, diagnostics.length
    diagnostic = diagnostics.first
    assert_equal "acme/widgets", diagnostic.repository
    assert_equal "obsolete_proposal_shape", diagnostic.code
    assert_equal "Observer result rejected", diagnostic.title
    assert_equal "The observer used an obsolete proposal shape. No repository action was authorized.", diagnostic.detail
    assert_not_includes diagnostic.detail, "untrusted"
  end

  test "recognizes a pre-diagnostic contract rejection without exposing an approval" do
    diagnostics = GithubDependencyMaintenanceFinding.diagnostics_for_run(
      maintenance_run(
        security: { "outcome" => "blocked" },
        dependabot: { "outcome" => "blocked" },
        validation: [
          {
            "command" => "structured workflow result",
            "status" => "failed",
            "detail" => "Required delimited JSON was missing or invalid; no action was authorized."
          }
        ]
      )
    )

    assert_equal [ "legacy_contract_rejection" ], diagnostics.map(&:code)
    assert_empty GithubDependencyMaintenanceFinding.for_run(
      maintenance_run(
        security: { "outcome" => "blocked" },
        dependabot: { "outcome" => "blocked" },
        validation: [
          {
            "command" => "structured workflow result",
            "status" => "failed",
            "detail" => "Required delimited JSON was missing or invalid; no action was authorized."
          }
        ]
      )
    )
  end

  test "does not expose an action for an observe-only or mismatched proposal" do
    observed = maintenance_run(
      security: {
        "mode" => "observe",
        "outcome" => "observed",
        "alert_numbers" => [ 19 ]
      },
      proposals: [
        {
          "kind" => "security_advisory",
          "action" => "draft_pr",
          "source_numbers" => [ 19 ]
        }
      ]
    )

    assert_empty GithubDependencyMaintenanceFinding.for_run(observed)
    assert_raises(GithubDependencyMaintenanceFinding::Invalid) do
      GithubDependencyMaintenanceFinding.find_for_approval(
        run: observed,
        repository: "acme/widgets",
        finding_key: "security:19"
      )
    end
  end

  test "rejects a proposal that targets a source outside the normalized evidence" do
    run = maintenance_run(
      security: {
        "mode" => "approval_required",
        "outcome" => "observed",
        "alert_numbers" => [ 19 ]
      },
      proposals: [
        {
          "kind" => "security_advisory",
          "action" => "draft_pr",
          "source_numbers" => [ 20 ]
        }
      ]
    )

    assert_empty GithubDependencyMaintenanceFinding.for_run(run)
  end

  test "does not expose multiple security proposals from one observation route" do
    run = maintenance_run(
      security: {
        "mode" => "approval_required",
        "outcome" => "observed",
        "alert_numbers" => [ 19, 20 ]
      },
      proposals: [
        {
          "kind" => "security_advisory",
          "action" => "draft_pr",
          "source_numbers" => [ 19 ]
        },
        {
          "kind" => "security_advisory",
          "action" => "draft_pr",
          "source_numbers" => [ 20 ]
        }
      ]
    )

    assert_empty GithubDependencyMaintenanceFinding.for_run(run)
  end

  test "fails closed when a completed run lacks a result object" do
    run = {
      "workflow_name" => "github_dependency_maintenance",
      "run_id" => "run-observation-1"
    }

    assert_empty GithubDependencyMaintenanceFinding.for_run(run)
  end

  private

  def maintenance_run(schema_version: "2", security: {}, dependabot: {}, proposals: [], diagnostic: nil, validation: [])
    {
      "workflow_name" => "github_dependency_maintenance",
      "run_id" => "run-observation-1",
      "result" => {
        "status" => "completed",
        "routes" => [
          {
            "schema_version" => schema_version,
            "repository" => "acme/widgets",
            "base_branch" => "main",
            "security_advisories" => {
              "mode" => "approval_required",
              "outcome" => "none",
              "alert_numbers" => []
            }.merge(security),
            "dependabot" => {
              "mode" => "approval_required",
              "outcome" => "none",
              "source_pr_numbers" => []
            }.merge(dependabot),
            "proposals" => proposals,
            "diagnostic" => diagnostic,
            "validation" => validation
          }
        ]
      }
    }
  end
end

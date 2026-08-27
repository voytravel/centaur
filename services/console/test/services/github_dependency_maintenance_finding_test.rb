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
    assert_equal "Repair through a scoped Draft PR", finding.action_label
    assert_equal "https://github.com/acme/widgets/pull/42", finding.source_url
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

  def maintenance_run(security: {}, dependabot: {}, proposals: [])
    {
      "workflow_name" => "github_dependency_maintenance",
      "run_id" => "run-observation-1",
      "result" => {
        "status" => "completed",
        "routes" => [
          {
            "schema_version" => "2",
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
            "proposals" => proposals
          }
        ]
      }
    }
  end
end

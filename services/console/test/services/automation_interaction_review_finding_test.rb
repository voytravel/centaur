require "test_helper"

class AutomationInteractionReviewFindingTest < ActiveSupport::TestCase
  def review_run
    {
      "workflow_name" => "automation_interaction_review",
      "run_id" => "run-review-1",
      "result" => {
        "status" => "completed",
        "schema_version" => 1,
        "findings" => [
          {
            "repository" => "acme/centaur",
            "base_branch" => "main",
            "fingerprint" => "0123456789abcdef",
            "category" => "workflow_contract",
            "evidence_refs" => [ "workflow:github_dependency_maintenance:failed" ],
            "title" => "Harden a workflow result contract",
            "rationale" => "The same workflow failed repeatedly during the review window.",
            "proposed_change" => "Validate the result before it reaches the scheduled batch reporter."
          }
        ]
      }
    }
  end

  test "parses a bounded weekly review proposal into a scoped action" do
    finding = AutomationInteractionReviewFinding.find_for_approval(
      run: review_run,
      repository: "acme/centaur",
      finding_key: "0123456789abcdef"
    )

    assert_equal "Draft a verified improvement PR", finding.action_label
    assert_equal "https://github.com/acme/centaur", finding.source_url
    assert_equal(
      {
        "source_run_id" => "run-review-1",
        "repository" => "acme/centaur",
        "base_branch" => "main",
        "finding" => {
          "fingerprint" => "0123456789abcdef",
          "category" => "workflow_contract",
          "evidence_refs" => [ "workflow:github_dependency_maintenance:failed" ],
          "title" => "Harden a workflow result contract",
          "rationale" => "The same workflow failed repeatedly during the review window.",
          "proposed_change" => "Validate the result before it reaches the scheduled batch reporter."
        },
        "approved_by" => "usr_operator"
      },
      finding.action_input(approved_by: "usr_operator")
    )
    assert_equal(
      "automation-interaction-review-action:run-review-1:0123456789abcdef",
      finding.idempotency_key
    )
  end

  test "fails closed on unsupported finding fields and malformed evidence" do
    malformed = review_run.deep_dup
    malformed["result"]["findings"][0]["unexpected"] = "ignored"
    assert_empty AutomationInteractionReviewFinding.for_run(malformed)

    malformed = review_run.deep_dup
    malformed["result"]["findings"][0]["evidence_refs"] = "workflow:github_dependency_maintenance:failed"
    assert_empty AutomationInteractionReviewFinding.for_run(malformed)
  end

  test "accepts the known Python workflow-host result wrapper" do
    wrapped = review_run.deep_dup
    wrapped["result"] = {
      "output" => wrapped.fetch("result"),
      "run_id" => wrapped.fetch("run_id"),
      "workflow_name" => "automation_interaction_review"
    }

    assert_equal 1, AutomationInteractionReviewFinding.for_run(wrapped).length
  end
end

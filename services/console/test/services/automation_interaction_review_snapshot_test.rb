require "test_helper"

class AutomationInteractionReviewSnapshotTest < ActiveSupport::TestCase
  test "rejects unbounded review windows" do
    assert_raises(AutomationInteractionReviewSnapshot::InvalidWindow) do
      AutomationInteractionReviewSnapshot.new(days: 15)
    end

    assert_raises(AutomationInteractionReviewSnapshot::InvalidWindow) do
      AutomationInteractionReviewSnapshot.new(days: "one-week")
    end
  end

  test "normalizes only bounded, printable policy reasons" do
    snapshot = AutomationInteractionReviewSnapshot.new(days: 7)

    assert_equal "policy disabled", snapshot.send(:safe_reason, "policy disabled")
    assert_nil snapshot.send(:safe_reason, "line\u0000break")
    assert_nil snapshot.send(:safe_reason, "x" * 241)
  end

  test "combines aggregate-only evidence without selecting message content" do
    snapshot = AutomationInteractionReviewSnapshot.new(days: 7)
    session_item = {
      "id" => "session:slack:completed",
      "source" => "slack",
      "metric" => "execution_status",
      "count" => 4,
      "attributes" => { "status" => "completed" }
    }
    feedback_item = {
      "id" => "feedback:console",
      "source" => "feedback",
      "metric" => "received",
      "count" => 1,
      "attributes" => { "feedback_source" => "console" }
    }

    snapshot.stub(:session_execution_evidence, [ [ session_item ], "available" ]) do
      snapshot.stub(:feedback_evidence, [ [ feedback_item ], "available" ]) do
        snapshot.stub(:automation_event_evidence, [ [], "available" ]) do
          snapshot.stub(:workflow_run_evidence, [ [], "unavailable" ]) do
            result = snapshot.as_json

            assert_equal [ feedback_item, session_item ], result.fetch("evidence")
            assert_equal(
              {
                "session_executions" => "available",
                "user_feedback" => "available",
                "automation_events" => "available",
                "workflow_runs" => "unavailable"
              },
              result.fetch("availability")
            )
          end
        end
      end
    end
  end
end

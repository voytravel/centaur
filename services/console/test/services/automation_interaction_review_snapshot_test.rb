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

  test "feedback aggregation bounds arbitrary sources in SQL and preserves overflow count" do
    # Execute the production aggregate query against a disposable SQL table.
    # Source values are free-form at ingress, not a bounded enum.
    connection = CentaurSessionRecord.connection
    connection.execute("CREATE TEMP TABLE user_feedback (source text, message text, created_at timestamp)")
    begin
      now = Time.current
      quoted_time = connection.quote(now)
      connection.execute("INSERT INTO user_feedback SELECT 'custom-' || n, 'never select this content', #{quoted_time} FROM generate_series(1, 300) AS n")
      connection.execute("INSERT INTO user_feedback VALUES ('slack', 'private body', #{quoted_time})")
      # Rails's schema query excludes temporary tables, although the query
      # itself correctly resolves pg_temp first on this connection.
      rows, availability = connection.stub(:data_source_exists?, true) do
        AutomationInteractionReviewSnapshot.new(now: now + 1.second).send(:feedback_evidence)
      end
      assert_equal "available", availability
      assert_equal 2, rows.length
      assert_equal 301, rows.sum { |row| row.fetch("count") }
      assert_equal 300, rows.find { |row| row["id"] == "feedback:other" }.fetch("count")
      refute_includes rows.to_json, "custom-"
      refute_includes rows.to_json, "private body"
    ensure
      connection.execute("DROP TABLE pg_temp.user_feedback")
    end
  end
end

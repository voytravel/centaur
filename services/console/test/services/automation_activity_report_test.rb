require "test_helper"

class AutomationActivityReportTest < ActiveSupport::TestCase
  test "builds a redacted accepted-work report with safe source and audit links" do
    event, workstream = configured_event
    with_env("CENTAUR_CONSOLE_PUBLIC_URL" => "https://console.example.test") do
      input = AutomationActivityReport.new(event).workflow_input

      assert_equal "C0123456789", input.fetch("channel")
      assert_equal "accepted", input.fetch("kind")
      assert_equal(
        [
          ":gear: *Centaur automation accepted*",
          "Source: <https://github.com/acme/widgets/pull/42|github:acme/widgets:pr:42>",
          "Actions: `review`, `resolve_conflict`",
          "Audit: <https://console.example.test/console/automation_workstreams/#{workstream.oid}|#{workstream.oid}>"
        ].join("\n"),
        input.fetch("text")
      )
    end
  end

  test "does not build a report for an incomplete or unsafe persisted snapshot" do
    event, = configured_event(activity_report: { "kind" => "accepted", "slack_channel" => "U0123456789" })
    assert_nil AutomationActivityReport.new(event).workflow_input

    event.update!(metadata: { "activity_report" => { "kind" => "completed", "slack_channel" => "C0123456789" } })
    assert_nil AutomationActivityReport.new(event).workflow_input
  end

  test "omits a malformed public console URL rather than emitting it" do
    event, workstream = configured_event
    with_env("CENTAUR_CONSOLE_PUBLIC_URL" => "https://user@example.test/?token=not-for-slack") do
      text = AutomationActivityReport.new(event).workflow_input.fetch("text")
      assert_includes text, "Audit: `#{workstream.oid}`"
      assert_no_match "example.test", text
    end
  end

  private

  def configured_event(activity_report: { "kind" => "accepted", "slack_channel" => "C0123456789" })
    policy = AutomationPolicy.create!(
      name: "Widgets activity reporting #{SecureRandom.hex(4)}",
      provider: "github",
      repository: "acme/widgets-#{SecureRandom.hex(4)}",
      enabled: true,
      mode: "observe",
      created_by: users(:acme_admin),
      settings: { "github" => { "review" => "all_eligible" } }
    )
    workstream = AutomationWorkstream.create!(
      automation_policy: policy,
      provider: "github",
      repository: "acme/widgets",
      subject_key: "github:acme/widgets:pr:42",
      session_key: "github-manage:acme/widgets:42",
      last_event_at: Time.current
    )
    event = AutomationEvent.create!(
      automation_workstream: workstream,
      provider: "github",
      deduplication_key: "activity-report-#{SecureRandom.hex(8)}",
      event_type: "pull_request",
      event_action: "opened",
      decision: "act",
      action_kind: "review,resolve_conflict",
      metadata: { "activity_report" => activity_report },
      received_at: Time.current
    )
    [ event, workstream ]
  end
end

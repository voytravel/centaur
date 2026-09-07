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

  test "builds a redacted app-created pull request report" do
    event, workstream = configured_event(activity_report: { "kind" => "pr_created", "slack_channel" => "C0123456789" })
    with_env("CENTAUR_CONSOLE_PUBLIC_URL" => "https://console.example.test") do
      input = AutomationActivityReport.new(event).workflow_input

      assert_equal "pr_created", input.fetch("kind")
      assert_equal(
        [
          ":sparkles: *Centaur created a pull request*",
          "Pull request: <https://github.com/acme/widgets/pull/42|github:acme/widgets:pr:42>",
          "Audit: <https://console.example.test/console/automation_workstreams/#{workstream.oid}|#{workstream.oid}>"
        ].join("\n"),
        input.fetch("text")
      )
    end
  end

  test "omits a malformed public console URL rather than emitting it" do
    event, workstream = configured_event
    with_env("CENTAUR_CONSOLE_PUBLIC_URL" => "https://user@example.test/?token=not-for-slack") do
      text = AutomationActivityReport.new(event).workflow_input.fetch("text")
      assert_includes text, "Audit: `#{workstream.oid}`"
      assert_no_match "example.test", text
    end
  end

  test "batches and describes Linear accepted work without audit identifiers" do
    received_at = Time.zone.parse("2026-09-08 09:01:12 UTC")
    policy = linear_policy
    first = configured_linear_event(
      issue_id: "issue-1422", identifier: "ENG-1422", title: "Clear stale sign-out button",
      received_at: received_at, policy: policy
    )
    configured_linear_event(
      issue_id: "issue-1423", identifier: "ENG-1423", title: "Improve session recovery",
      received_at: received_at + 20.seconds, policy: policy
    )

    report = AutomationActivityReport.new(first)
    input = report.workflow_input

    assert_equal "accepted", input.fetch("kind")
    assert_equal [
      ":gear: *Centaur accepted 2 Linear issues*",
      "• <https://linear.app/voytravel/issue/ENG-1422/clear-stale-sign-out-button|ENG-1422 — Clear stale sign-out button> — will implement",
      "• <https://linear.app/voytravel/issue/ENG-1423/improve-session-recovery|ENG-1423 — Improve session recovery> — will implement"
    ].join("\n"), input.fetch("text")
    assert_equal(
      "automation-activity-report:accepted-linear:C0123456789:#{received_at.beginning_of_minute.to_i}",
      report.idempotency_key
    )
    assert_equal received_at.beginning_of_minute + 75.seconds, report.delivery_at
    assert_not_includes input.fetch("text"), "Audit:"
    assert_not_includes input.fetch("text"), "linear:issue-"
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

  def linear_policy
    AutomationPolicy.create!(
      name: "Linear activity reporting #{SecureRandom.hex(4)}",
      provider: "linear",
      linear_team_id: "team-1",
      enabled: true,
      mode: "act",
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "issue" => "ready_issues",
          "ready_statuses" => [ "Ready" ],
          "github_repository" => "acme/widgets"
        }
      }
    )
  end

  def configured_linear_event(issue_id:, identifier:, title:, received_at:, policy:)
    workstream = AutomationWorkstream.create!(
      automation_policy: policy,
      provider: "linear",
      repository: "acme/widgets",
      subject_key: "linear:#{issue_id}",
      session_key: "linear:#{issue_id}",
      last_event_at: received_at,
      metadata: {
        "linear_issue_identifier" => identifier,
        "linear_issue_title" => title,
        "linear_issue_url" => "https://linear.app/voytravel/issue/#{identifier}/#{title.parameterize}"
      }
    )
    AutomationEvent.create!(
      automation_workstream: workstream,
      provider: "linear",
      deduplication_key: "activity-report-#{issue_id}",
      event_type: "Issue",
      event_action: "create",
      decision: "act",
      action_kind: "implement_issue",
      metadata: { "activity_report" => { "kind" => "accepted", "slack_channel" => "C0123456789" } },
      received_at: received_at
    )
  end
end

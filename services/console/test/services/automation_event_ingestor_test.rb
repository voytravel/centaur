require "test_helper"

class AutomationEventIngestorTest < ActiveSupport::TestCase
  test "deduplicates delivery events and continues one GitHub PR workstream" do
    policy = AutomationPolicy.create!(
      name: "Widgets",
      provider: "github",
      repository: "acme/widgets",
      enabled: true,
      mode: "act",
      execution_role: automation_role,
      created_by: users(:acme_admin),
      settings: { "github" => { "review" => "all_eligible" } }
    )
    input = {
      "provider" => "github",
      "deduplication_key" => "delivery-1",
      "event_type" => "pull_request",
      "event_action" => "opened",
      "repository" => "acme/widgets",
      "subject_number" => "42",
      "head_sha" => "abc123",
      "base_branch" => "main",
      "draft" => false,
      "labels" => []
    }

    first = AutomationEventIngestor.new(input).call
    second = AutomationEventIngestor.new(input).call

    assert_equal "act", first["decision"]
    assert_equal [ "review" ], first["actions"]
    assert_equal first, second
    assert_equal 1, AutomationEvent.count
    workstream = AutomationWorkstream.sole
    assert_equal policy, workstream.automation_policy
    assert_equal "github-manage:acme/widgets:42", workstream.session_key
    assert_equal "github:acme/widgets:pr:42", workstream.subject_key
    assert_equal 1, workstream.event_count
  end

  test "queues one Slack activity report for a newly accepted workstream, not continuations" do
    policy = AutomationPolicy.create!(
      name: "Reported widgets",
      provider: "github",
      repository: "acme/reported-widgets",
      enabled: true,
      mode: "act",
      execution_role: automation_role,
      created_by: users(:acme_admin),
      settings: {
        "github" => { "review" => "all_eligible", "feedback" => "eligible" },
        "activity_reporting" => { "slack_channel" => "C0123456789", "accepted" => true }
      }
    )
    first_event = {
      "provider" => "github",
      "deduplication_key" => "reported-review",
      "event_type" => "pull_request",
      "event_action" => "opened",
      "repository" => policy.repository,
      "subject_number" => 42,
      "draft" => false,
      "labels" => []
    }
    continuation_event = first_event.merge(
      "deduplication_key" => "reported-feedback",
      "event_type" => "pull_request_review",
      "event_action" => "submitted"
    )
    queued_event_ids = []

    AutomationActivityReportJob.stub(:perform_later, ->(event_id) { queued_event_ids << event_id }) do
      assert_equal "act", AutomationEventIngestor.new(first_event).call.fetch("decision")
      assert_equal "act", AutomationEventIngestor.new(continuation_event).call.fetch("decision")
      assert_equal "act", AutomationEventIngestor.new(first_event).call.fetch("decision")
    end

    first = AutomationEvent.find_by!(deduplication_key: "reported-review")
    assert_equal [ first.id ], queued_event_ids
    assert_equal(
      { "kind" => "accepted", "slack_channel" => "C0123456789" },
      first.metadata.fetch("activity_report")
    )
    assert_nil AutomationEvent.find_by!(deduplication_key: "reported-feedback").metadata["activity_report"]
  end

  test "queues one pull-request-created report only for a GitHub App-authored opened event" do
    policy = AutomationPolicy.create!(
      name: "App-created PR reporting",
      provider: "github",
      repository: "acme/app-created-prs",
      enabled: true,
      mode: "act",
      execution_role: automation_role,
      created_by: users(:acme_admin),
      settings: {
        "github" => { "review" => "off" },
        "activity_reporting" => { "slack_channel" => "C0123456789", "pr_created" => true }
      }
    )
    created_event = {
      "provider" => "github",
      "deduplication_key" => "app-created-pr",
      "event_type" => "pull_request",
      "event_action" => "opened",
      "repository" => policy.repository,
      "subject_number" => 42,
      "draft" => true,
      "labels" => [],
      "created_by_bot" => true
    }
    human_event = created_event.merge(
      "deduplication_key" => "human-created-pr",
      "subject_number" => 43,
      "created_by_bot" => false
    )
    queued_event_ids = []

    AutomationActivityReportJob.stub(:perform_later, ->(event_id) { queued_event_ids << event_id }) do
      assert_equal "ignored", AutomationEventIngestor.new(created_event).call.fetch("decision")
      assert_equal "ignored", AutomationEventIngestor.new(human_event).call.fetch("decision")
      assert_equal "ignored", AutomationEventIngestor.new(created_event).call.fetch("decision")
    end

    created = AutomationEvent.find_by!(deduplication_key: "app-created-pr")
    assert_equal [ created.id ], queued_event_ids
    assert_equal(
      { "kind" => "pr_created", "slack_channel" => "C0123456789" },
      created.metadata.fetch("activity_report")
    )
    assert_equal true, created.metadata.fetch("created_by_bot")
    assert_nil AutomationEvent.find_by!(deduplication_key: "human-created-pr").metadata["activity_report"]
  end

  test "prefers one pull-request-created report over accepted-work reporting for the same event" do
    policy = AutomationPolicy.create!(
      name: "No duplicate app-created PR reports",
      provider: "github",
      repository: "acme/no-duplicate-pr-reports",
      enabled: true,
      mode: "act",
      execution_role: automation_role,
      created_by: users(:acme_admin),
      settings: {
        "github" => { "review" => "all_eligible" },
        "activity_reporting" => {
          "slack_channel" => "C0123456789",
          "accepted" => true,
          "pr_created" => true
        }
      }
    )
    event = {
      "provider" => "github",
      "deduplication_key" => "no-duplicate-app-created-pr",
      "event_type" => "pull_request",
      "event_action" => "opened",
      "repository" => policy.repository,
      "subject_number" => 42,
      "draft" => false,
      "labels" => [],
      "created_by_bot" => true
    }
    queued_event_ids = []

    AutomationActivityReportJob.stub(:perform_later, ->(event_id) { queued_event_ids << event_id }) do
      assert_equal "act", AutomationEventIngestor.new(event).call.fetch("decision")
    end

    report = AutomationEvent.find_by!(deduplication_key: "no-duplicate-app-created-pr")
    assert_equal [ report.id ], queued_event_ids
    assert_equal "pr_created", report.metadata.dig("activity_report", "kind")
  end

  test "continues an explicitly requested GitHub PR while blocking safety rejections" do
    role = automation_role
    AutomationPolicy.create!(
      name: "Explicit widgets",
      provider: "github",
      repository: "acme/widgets",
      enabled: true,
      mode: "act",
      execution_role: role,
      created_by: users(:acme_admin),
      settings: {
        "github" => {
          "review" => "assigned_or_mentioned",
          "feedback" => "explicit",
          "checks" => "explicit",
          "conflicts" => "explicit",
          "excluded_labels" => [ "no-agent" ]
        }
      }
    )
    review = AutomationEventIngestor.new(
      "provider" => "github",
      "deduplication_key" => "requested-review",
      "event_type" => "pull_request",
      "event_action" => "review_requested",
      "repository" => "acme/widgets",
      "subject_number" => 42,
      "draft" => false,
      "labels" => [],
      "review_requested_for_bot" => true
    ).call

    assert_equal "act", review["decision"]
    assert_equal [ "review" ], review["actions"]
    workstream = AutomationWorkstream.sole
    assert_equal "active", workstream.state

    principal = Principal.create!(
      foreign_id: "github-explicit-role-#{SecureRandom.hex(6)}",
      name: "acme/widgets#42",
      kind: "github_pull_request",
      labels: {
        "github_repository" => "acme/widgets",
        "github_pull_request_number" => "42"
      },
      created_by: users(:acme_admin)
    )
    AutomationPrincipalAuthorizer.reconcile_principal(principal)
    assert_includes principal.reload.roles, role

    noise = AutomationEventIngestor.new(
      "provider" => "github",
      "deduplication_key" => "unrelated-lifecycle",
      "event_type" => "pull_request",
      "event_action" => "assigned",
      "repository" => "acme/widgets",
      "subject_number" => 42,
      "draft" => false,
      "labels" => []
    ).call
    assert_equal "ignored", noise["decision"]
    assert_equal "no automatic action is enabled for this event", noise["reason"]
    assert_equal "active", workstream.reload.state
    assert_includes principal.reload.roles, role

    feedback = AutomationEventIngestor.new(
      "provider" => "github",
      "deduplication_key" => "requested-review-feedback",
      "event_type" => "pull_request_review",
      "event_action" => "submitted",
      "repository" => "acme/widgets",
      "subject_number" => 42,
      "draft" => false,
      "labels" => []
    ).call
    assert_equal "act", feedback["decision"]
    assert_equal [ "address_feedback" ], feedback["actions"]

    blocked = AutomationEventIngestor.new(
      "provider" => "github",
      "deduplication_key" => "requested-review-no-agent",
      "event_type" => "check_run",
      "event_action" => "completed",
      "repository" => "acme/widgets",
      "subject_number" => 42,
      "draft" => false,
      "labels" => [ "no-agent" ]
    ).call
    assert_equal "ignored", blocked["decision"]
    assert_equal "an excluded label is present", blocked["reason"]
    assert_equal "blocked", workstream.reload.state
    assert_not_includes principal.reload.roles, role
  end

  test "records a disabled manual mention without revoking an active PR workstream" do
    role = automation_role
    AutomationPolicy.create!(
      name: "Lifecycle-only widgets",
      provider: "github",
      repository: "acme/lifecycle-only-widgets",
      enabled: true,
      mode: "act",
      execution_role: role,
      created_by: users(:acme_admin),
      settings: {
        "github" => {
          "review" => "all_eligible",
          "manual_mentions" => false
        }
      }
    )

    review = AutomationEventIngestor.new(
      "provider" => "github",
      "deduplication_key" => "lifecycle-review",
      "event_type" => "pull_request",
      "event_action" => "opened",
      "repository" => "acme/lifecycle-only-widgets",
      "subject_number" => 42,
      "draft" => false,
      "labels" => []
    ).call
    assert_equal "act", review["decision"]
    workstream = AutomationWorkstream.sole

    denied = AutomationEventIngestor.new(
      "provider" => "github",
      "deduplication_key" => "disabled-manual-mention",
      "event_type" => "pull_request",
      "event_action" => "manual_mention",
      "mentioned_bot" => true,
      "repository" => "acme/lifecycle-only-widgets",
      "subject_number" => 42,
      "draft" => false,
      "labels" => []
    ).call
    assert_equal "ignored", denied["decision"]
    assert_equal "manual mentions are disabled", denied["reason"]
    assert_equal "active", workstream.reload.state
  end

  test "does not persist unmatched events or authorize work" do
    result = AutomationEventIngestor.new(
      "provider" => "github",
      "deduplication_key" => "delivery-2",
      "event_type" => "pull_request",
      "event_action" => "opened",
      "repository" => "acme/no-policy",
      "subject_number" => 7
    ).call

    assert_equal "ignored", result["decision"]
    assert_equal "no matching automation policy", result["reason"]
    assert_equal [], result["actions"]
    assert_equal "github-manage:acme/no-policy:7", result["session_key"]
    assert_nil result["workstream_id"]
    assert_equal 0, AutomationWorkstream.count
    assert_equal 0, AutomationEvent.count
  end

  test "uses one Linear issue session for updates" do
    AutomationPolicy.create!(
      name: "Linear",
      provider: "linear",
      linear_team_id: "team-1",
      enabled: true,
      mode: "act",
      execution_role: automation_role,
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "issue" => "ready_issues",
          "ready_statuses" => [ "Ready" ],
          "github_repository" => "acme/widgets"
        }
      }
    )

    result = AutomationEventIngestor.new(
      "provider" => "linear",
      "deduplication_key" => "issue-1-v1",
      "event_type" => "Issue",
      "event_action" => "update",
      "linear_issue_id" => "issue-1",
      "linear_issue_identifier" => "ENG-42",
      "linear_issue_url" => "https://linear.app/voytravel/issue/ENG-42/implement-it?utm=bot#activity",
      "linear_team_id" => "team-1",
      "title" => "Implement it",
      "description" => "Ready to ship",
      "status" => "Ready"
    ).call

    assert_equal "act", result["decision"]
    assert_equal [ "implement_issue" ], result["actions"]
    assert_equal "linear:issue-1", result["session_key"]
    workstream = AutomationWorkstream.sole
    assert_equal "ENG-42", workstream.metadata["linear_issue_identifier"]
    assert_equal "https://linear.app/voytravel/issue/ENG-42/implement-it", workstream.metadata["linear_issue_url"]
  end

  test "returns the explicitly selected Linear repository route and preview label" do
    AutomationPolicy.create!(
      name: "Routed Linear",
      provider: "linear",
      linear_team_id: "team-1",
      enabled: true,
      mode: "act",
      execution_role: automation_role,
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "issue" => "ready_issues",
          "repository_routes" => [
            {
              "repository" => "acme/widgets",
              "required_labels" => [ "repo:widgets" ]
            },
            {
              "repository" => "acme/travel",
              "required_labels" => [ "repo:travel" ],
              "preview_label" => "preview"
            }
          ]
        }
      }
    )

    input = {
      "provider" => "linear",
      "deduplication_key" => "routed-issue-v1",
      "event_type" => "Issue",
      "event_action" => "update",
      "linear_issue_id" => "routed-issue",
      "linear_team_id" => "team-1",
      "title" => "Implement travel UI",
      "description" => "Ready to ship",
      "labels" => [ "repo:travel" ]
    }

    first = AutomationEventIngestor.new(input).call
    second = AutomationEventIngestor.new(input).call

    assert_equal "act", first["decision"]
    assert_equal "acme/travel", first["github_repository"]
    assert_equal "preview", first["preview_label"]
    assert_equal first, second
    event = AutomationEvent.sole
    assert_equal "acme/travel", event.metadata.dig("result", "github_repository")
    assert_equal "preview", event.metadata.dig("result", "preview_label")
    assert_equal "acme/travel", AutomationWorkstream.sole.repository
  end

  test "re-evaluates a duplicate delivery after an operator disables its policy" do
    policy = AutomationPolicy.create!(
      name: "Widgets",
      provider: "github",
      repository: "acme/widgets",
      enabled: true,
      mode: "act",
      execution_role: automation_role,
      created_by: users(:acme_admin),
      settings: { "github" => { "review" => "all_eligible" } }
    )
    input = {
      "provider" => "github",
      "deduplication_key" => "delivery-disable",
      "event_type" => "pull_request",
      "event_action" => "opened",
      "repository" => "acme/widgets",
      "subject_number" => 42,
      "draft" => false,
      "labels" => []
    }

    assert_equal "act", AutomationEventIngestor.new(input).call["decision"]
    policy.update!(enabled: false)

    duplicate = AutomationEventIngestor.new(input).call
    assert_equal "ignored", duplicate["decision"]
    assert_equal "policy is disabled", duplicate["reason"]
    assert_equal 1, AutomationEvent.count
  end

  test "binds and revokes an act policy role only for its Linear workstream principal" do
    role = automation_role
    policy = AutomationPolicy.create!(
      name: "Linear implementation",
      provider: "linear",
      linear_team_id: "team-1",
      enabled: true,
      mode: "act",
      execution_role: role,
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "issue" => "ready_issues",
          "github_repository" => "acme/widgets"
        }
      }
    )
    AutomationEventIngestor.new(
      "provider" => "linear",
      "deduplication_key" => "issue-role-v1",
      "event_type" => "Issue",
      "event_action" => "create",
      "linear_issue_id" => "issue-role",
      "linear_team_id" => "team-1",
      "title" => "Implement it",
      "description" => "Ready to ship",
      "labels" => []
    ).call

    principal = Principal.create!(
      foreign_id: "linear-issue-role-#{SecureRandom.hex(6)}",
      name: "ENG-42",
      kind: "linear_issue",
      labels: { "linear_issue_id" => "issue-role" },
      created_by: users(:acme_admin)
    )
    AutomationPrincipalAuthorizer.reconcile_principal(principal)

    workstream = AutomationWorkstream.sole
    assert_equal principal, workstream.reload.principal
    assert_equal role, workstream.authorization_role
    assert_includes principal.reload.roles, role

    policy.update!(enabled: false)

    assert_nil workstream.reload.authorization_role
    assert_not_includes principal.reload.roles, role
  end

  test "binds a GitHub workstream only to the matching pull request principal" do
    role = automation_role
    AutomationPolicy.create!(
      name: "Widgets",
      provider: "github",
      repository: "acme/widgets",
      enabled: true,
      mode: "act",
      execution_role: role,
      created_by: users(:acme_admin),
      settings: { "github" => { "review" => "all_eligible" } }
    )
    AutomationEventIngestor.new(
      "provider" => "github",
      "deduplication_key" => "github-role-v1",
      "event_type" => "pull_request",
      "event_action" => "opened",
      "repository" => "acme/widgets",
      "subject_number" => 42,
      "draft" => false,
      "labels" => []
    ).call

    matching = Principal.create!(
      foreign_id: "github-pr-role-#{SecureRandom.hex(6)}",
      name: "acme/widgets#42",
      kind: "github_pull_request",
      labels: {
        "github_repository" => "acme/widgets",
        "github_pull_request_number" => "42"
      },
      created_by: users(:acme_admin)
    )
    unrelated = Principal.create!(
      foreign_id: "github-pr-other-#{SecureRandom.hex(6)}",
      name: "acme/widgets#43",
      kind: "github_pull_request",
      labels: {
        "github_repository" => "acme/widgets",
        "github_pull_request_number" => "43"
      },
      created_by: users(:acme_admin)
    )
    AutomationPrincipalAuthorizer.reconcile_principal(matching)
    AutomationPrincipalAuthorizer.reconcile_principal(unrelated)

    assert_includes matching.reload.roles, role
    assert_not_includes unrelated.reload.roles, role
  end

  private

  def automation_role
    @automation_role ||= Role.create!(
      foreign_id: "automation-test-#{SecureRandom.hex(6)}",
      name: "Automation test role",
      labels: { Role::AUTOMATION_EXECUTION_LABEL => "true" },
      created_by: users(:acme_admin)
    )
  end
end

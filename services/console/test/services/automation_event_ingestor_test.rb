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

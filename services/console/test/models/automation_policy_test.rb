require "test_helper"

class AutomationPolicyTest < ActiveSupport::TestCase
  test "routes only eligible GitHub PR events in act mode" do
    policy = github_policy(
      mode: "act",
      settings: {
        "github" => {
          "review" => "all_eligible",
          "feedback" => "eligible",
          "checks" => "eligible",
          "conflicts" => "eligible",
          "base_branches" => [ "main" ],
          "required_labels" => [ "agent-ok" ],
          "excluded_labels" => [ "no-agent" ]
        }
      }
    )

    review = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "pull_request",
      "event_action" => "opened",
      "base_branch" => "main",
      "draft" => false,
      "labels" => [ "agent-ok" ]
    )
    assert_equal "act", review["decision"]
    assert_equal [ "review" ], review["actions"]

    feedback = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "pull_request_review",
      "event_action" => "submitted",
      "base_branch" => "main",
      "draft" => false,
      "labels" => [ "agent-ok" ]
    )
    assert_equal [ "address_feedback" ], feedback["actions"]

    excluded = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "pull_request",
      "event_action" => "opened",
      "base_branch" => "main",
      "draft" => false,
      "labels" => [ "agent-ok", "no-agent" ]
    )
    assert_equal "ignored", excluded["decision"]
    assert_equal "an excluded label is present", excluded["reason"]
  end

  test "uses verified reviewer requests and durable workstream facts for scoped GitHub continuation" do
    policy = github_policy(
      mode: "act",
      settings: {
        "github" => {
          "review" => "assigned_or_mentioned",
          "feedback" => "explicit",
          "checks" => "explicit",
          "conflicts" => "explicit"
        }
      }
    )

    requested = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "pull_request",
      "event_action" => "review_requested",
      "draft" => false,
      "labels" => [],
      "review_requested_for_bot" => true
    )
    assert_equal "act", requested["decision"]
    assert_equal [ "review" ], requested["actions"]

    other_reviewer = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "pull_request",
      "event_action" => "review_requested",
      "draft" => false,
      "labels" => [],
      "review_requested_for_bot" => false
    )
    assert_equal "ignored", other_reviewer["decision"]
    assert_equal "no automatic action is enabled for this event", other_reviewer["reason"]

    feedback = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "pull_request_review",
      "event_action" => "submitted",
      "draft" => false,
      "labels" => [],
      "continuation_authorized" => true
    )
    assert_equal [ "address_feedback" ], feedback["actions"]

    check = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "check_run",
      "draft" => false,
      "labels" => [],
      "continuation_authorized" => true
    )
    assert_equal [ "fix_checks" ], check["actions"]

    conflict = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "pull_request",
      "event_action" => "synchronize",
      "draft" => false,
      "labels" => [],
      "continuation_authorized" => true
    )
    assert_equal [ "resolve_conflict" ], conflict["actions"]
  end

  test "uses a Githubbot-derived ownership fact for bot-owned repairs" do
    policy = github_policy(
      mode: "act",
      settings: { "github" => { "checks" => "bot_owned" } }
    )

    owned = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "check_run",
      "draft" => false,
      "labels" => [],
      "bot_owned" => true
    )
    assert_equal "act", owned["decision"]
    assert_equal [ "fix_checks" ], owned["actions"]

    unowned = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "check_run",
      "draft" => false,
      "labels" => [],
      "bot_owned" => false
    )
    assert_equal "ignored", unowned["decision"]
    assert_equal "no automatic action is enabled for this event", unowned["reason"]
  end

  test "observe mode records a ready Linear issue without authorizing an agent" do
    policy = AutomationPolicy.create!(
      name: "Linear ready issues",
      provider: "linear",
      linear_team_id: "team-1",
      enabled: true,
      mode: "observe",
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "issue" => "ready_issues",
          "ready_statuses" => [ "Ready" ],
          "required_fields" => [ "description", "acceptance_criteria" ],
          "github_repository" => "acme/widgets"
        }
      }
    )

    result = policy.evaluate(
      "event_type" => "Issue",
      "event_action" => "create",
      "linear_team_id" => "team-1",
      "title" => "Ship the widget",
      "description" => "Acceptance Criteria\n- The widget is shipped.",
      "status" => "Ready",
      "labels" => []
    )

    assert_equal "observe", result["decision"]
    assert_equal [ "implement_issue" ], result["actions"]

    blocked = policy.evaluate(
      "event_type" => "Issue",
      "event_action" => "update",
      "linear_team_id" => "team-1",
      "title" => "Ship the widget",
      "description" => "Acceptance Criteria\n- The widget is shipped.",
      "status" => "Ready",
      "labels" => [],
      "blocked" => true
    )
    assert_equal "ignored", blocked["decision"]
    assert_equal "issue is blocked", blocked["reason"]
  end

  test "ready issue policy requires a GitHub repository mapping" do
    policy = AutomationPolicy.new(
      name: "Broken",
      provider: "linear",
      linear_team_id: "team-1",
      created_by: users(:acme_admin),
      settings: { "linear" => { "issue" => "ready_issues" } }
    )

    assert_not policy.valid?
    assert_includes policy.errors[:settings], "needs a GitHub repository for ready issue automation"
  end

  test "act mode requires an explicit execution role" do
    policy = AutomationPolicy.new(
      name: "No capability boundary",
      provider: "github",
      repository: "acme/widgets",
      mode: "act",
      created_by: users(:acme_admin)
    )

    assert_not policy.valid?
    assert_includes policy.errors[:execution_role], "can't be blank"
  end

  test "act mode rejects a role that is not approved for repository automation" do
    generic_role = Role.create!(
      foreign_id: "generic-test-#{SecureRandom.hex(6)}",
      name: "Generic role",
      created_by: users(:acme_admin)
    )
    policy = AutomationPolicy.new(
      name: "Unsafe capability boundary",
      provider: "github",
      repository: "acme/widgets",
      mode: "act",
      execution_role: generic_role,
      created_by: users(:acme_admin)
    )

    assert_not policy.valid?
    assert_includes policy.errors[:execution_role], "is not approved for autonomous repository automation"
  end

  test "allows one team-wide and one project-specific Linear policy" do
    AutomationPolicy.create!(
      name: "Team policy",
      provider: "linear",
      linear_team_id: "team-1",
      created_by: users(:acme_admin),
      settings: { "linear" => { "issue" => "off" } }
    )

    project_policy = AutomationPolicy.new(
      name: "Project policy",
      provider: "linear",
      linear_team_id: "team-1",
      linear_project_id: "project-1",
      created_by: users(:acme_admin),
      settings: { "linear" => { "issue" => "off" } }
    )

    assert_predicate project_policy, :valid?
  end

  test "normalizes a blank Linear project scope and rejects a duplicate team policy" do
    AutomationPolicy.create!(
      name: "Team policy",
      provider: "linear",
      linear_team_id: "team-1",
      created_by: users(:acme_admin),
      settings: { "linear" => { "issue" => "off" } }
    )

    duplicate = AutomationPolicy.new(
      name: "Duplicate",
      provider: "linear",
      linear_team_id: "team-1",
      linear_project_id: "   ",
      created_by: users(:acme_admin),
      settings: { "linear" => { "issue" => "off" } }
    )

    assert_nil duplicate.linear_project_id
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:linear_project_id], "already has a policy in this team"
  end

  test "auto merge evaluates eligible PR and check events without authorizing CI fixes" do
    policy = github_policy(
      mode: "act",
      settings: {
        "github" => {
          "auto_merge" => true,
          "base_branches" => [ "main", "release/*" ]
        }
      }
    )

    pull_request = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "pull_request",
      "event_action" => "opened",
      "base_branch" => "main",
      "draft" => false,
      "labels" => []
    )
    assert_equal [ "evaluate_merge" ], pull_request["actions"]
    assert_equal true, pull_request["auto_merge"]

    check = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "check_run",
      "base_branch" => "release/2026.08",
      "draft" => false,
      "labels" => []
    )
    assert_equal [ "evaluate_merge" ], check["actions"]
  end

  test "keeps valid managed-source provenance outside provider evaluation settings" do
    policy = AutomationPolicy.create!(
      name: "Managed widgets",
      provider: "github",
      repository: "acme/managed-widgets",
      enabled: true,
      mode: "observe",
      created_by: users(:acme_admin),
      settings: {
        "github" => { "review" => "all_eligible" },
        "_centaur_managed_source" => {
          "kind" => "git",
          "repository" => "acme/infra",
          "path" => "automation/policies.json",
          "revision" => "a" * 40,
          "content_sha256" => "b" * 64
        }
      }
    )

    assert_predicate policy, :source_managed?
    assert_equal "acme/infra:automation/policies.json@aaaaaaaaaaaa", policy.managed_source_label
    expected_url = "https://github.com/acme/infra/blob/#{"a" * 40}/automation/policies.json"
    assert_equal expected_url, policy.safe_managed_source_url
    assert_equal "all_eligible", policy.github_settings["review"]
  end

  test "does not create an external source URL from non-GitHub repository syntax" do
    policy = AutomationPolicy.new(
      name: "Opaque managed source",
      provider: "github",
      repository: "acme/widgets",
      created_by: users(:acme_admin),
      settings: {
        "_centaur_managed_source" => {
          "kind" => "git",
          "repository" => "acme?source/infra",
          "path" => "automation/policies.json",
          "revision" => "a" * 40,
          "content_sha256" => "b" * 64
        }
      }
    )

    assert_predicate policy, :valid?
    assert_nil policy.safe_managed_source_url
  end

  test "rejects malformed managed-source provenance" do
    policy = AutomationPolicy.new(
      name: "Bad source",
      provider: "github",
      repository: "acme/widgets",
      created_by: users(:acme_admin),
      settings: {
        "_centaur_managed_source" => {
          "kind" => "git",
          "repository" => "acme/infra",
          "path" => "../policies.json",
          "revision" => "a" * 40,
          "content_sha256" => "b" * 64
        }
      }
    )

    assert_not policy.valid?
    assert_includes policy.errors[:settings], "has invalid managed source metadata"
  end

  private

  def github_policy(overrides = {})
    AutomationPolicy.create!(
      {
        name: "Widgets",
        provider: "github",
        repository: "acme/widgets",
        enabled: true,
        execution_role: automation_role,
        created_by: users(:acme_admin)
      }.merge(overrides)
    )
  end

  def automation_role
    @automation_role ||= Role.create!(
      foreign_id: "automation-test-#{SecureRandom.hex(6)}",
      name: "Automation test role",
      labels: { Role::AUTOMATION_EXECUTION_LABEL => "true" },
      created_by: users(:acme_admin)
    )
  end
end

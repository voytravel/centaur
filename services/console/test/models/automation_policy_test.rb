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

  test "requires an explicit verified-manual-mention opt-in and permits it on drafts" do
    policy = github_policy(
      mode: "act",
      settings: {
        "github" => {
          "manual_mentions" => true,
          "base_branches" => [ "main" ],
          "required_labels" => [ "agent-ok" ],
          "excluded_labels" => [ "no-agent" ]
        }
      }
    )

    allowed = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "pull_request",
      "event_action" => "manual_mention",
      "mentioned_bot" => true,
      "base_branch" => "main",
      "draft" => false,
      "labels" => [ "agent-ok" ]
    )
    assert_equal "act", allowed["decision"]
    assert_equal [ "respond_to_mention" ], allowed["actions"]
    assert_includes policy.automation_summary, "manual mentions: enabled"

    draft_allowed = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "pull_request",
      "event_action" => "manual_mention",
      "mentioned_bot" => true,
      "base_branch" => "main",
      "draft" => true,
      "labels" => [ "agent-ok" ]
    )
    assert_equal "act", draft_allowed["decision"]
    assert_equal [ "respond_to_mention" ], draft_allowed["actions"]

    unattended_draft = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "pull_request",
      "event_action" => "opened",
      "base_branch" => "main",
      "draft" => true,
      "labels" => []
    )
    assert_equal "ignored", unattended_draft["decision"]
    assert_equal "draft pull requests are excluded", unattended_draft["reason"]

    spoofed = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "pull_request",
      "event_action" => "manual_mention",
      "mentioned_bot" => false,
      "base_branch" => "main",
      "draft" => true,
      "labels" => [ "agent-ok" ]
    )
    assert_equal "ignored", spoofed["decision"]
    assert_equal "event is not a verified bot mention", spoofed["reason"]

    missing_required = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "pull_request",
      "event_action" => "manual_mention",
      "mentioned_bot" => true,
      "base_branch" => "main",
      "draft" => true,
      "labels" => []
    )
    assert_equal "ignored", missing_required["decision"]
    assert_equal "required label is missing", missing_required["reason"]

    excluded = policy.evaluate(
      "repository" => "acme/widgets",
      "event_type" => "pull_request",
      "event_action" => "manual_mention",
      "mentioned_bot" => true,
      "base_branch" => "main",
      "draft" => true,
      "labels" => [ "agent-ok", "no-agent" ]
    )
    assert_equal "ignored", excluded["decision"]
    assert_equal "an excluded label is present", excluded["reason"]
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
          "required_labels" => [ "agent:ready" ],
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
      "labels" => [ "agent:ready" ]
    )

    assert_equal "observe", result["decision"]
    assert_equal [ "implement_issue" ], result["actions"]
    assert_includes policy.automation_summary, "required labels: agent:ready"

    missing_opt_in = policy.evaluate(
      "event_type" => "Issue",
      "event_action" => "update",
      "linear_team_id" => "team-1",
      "title" => "Ship the widget",
      "description" => "Acceptance Criteria\n- The widget is shipped.",
      "status" => "Ready",
      "labels" => []
    )
    assert_equal "ignored", missing_opt_in["decision"]
    assert_equal "a required label is missing", missing_opt_in["reason"]

    blocked = policy.evaluate(
      "event_type" => "Issue",
      "event_action" => "update",
      "linear_team_id" => "team-1",
      "title" => "Ship the widget",
      "description" => "Acceptance Criteria\n- The widget is shipped.",
      "status" => "Ready",
      "labels" => [ "agent:ready" ],
      "blocked" => true
    )
    assert_equal "ignored", blocked["decision"]
    assert_equal "issue is blocked", blocked["reason"]
  end

  test "normalizes and validates optional Slack activity reporting" do
    policy = github_policy(
      settings: {
        "github" => { "review" => "all_eligible" },
        "activity_reporting" => {
          "slack_channel" => "c0123456789",
          "accepted" => "1",
          "pr_created" => "1"
        }
      }
    )

    assert_predicate policy, :valid?
    assert_equal "C0123456789", policy.activity_reporting_settings["slack_channel"]
    assert policy.reports_activity?("accepted")
    assert policy.reports_activity?("pr_created")
    assert_includes policy.automation_summary, "Slack accepted-work + PR-created report"

    invalid = AutomationPolicy.new(
      name: "Invalid activity reporting",
      provider: "github",
      repository: "acme/invalid-activity-reporting",
      enabled: true,
      execution_role: automation_role,
      created_by: users(:acme_admin),
      settings: {
        "github" => { "review" => "all_eligible" },
        "activity_reporting" => { "slack_channel" => "U0123456789", "accepted" => true }
      }
    )

    assert_not invalid.valid?
    assert_includes invalid.errors[:settings], "activity reporting has an invalid Slack channel"

    malformed = AutomationPolicy.new(
      name: "Malformed activity reporting",
      provider: "github",
      repository: "acme/malformed-activity-reporting",
      enabled: true,
      execution_role: automation_role,
      created_by: users(:acme_admin),
      settings: {
        "github" => { "review" => "all_eligible" },
        "activity_reporting" => "C0123456789"
      }
    )

    assert_not malformed.valid?
    assert_includes malformed.errors[:settings], "activity reporting must be an object"
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
    assert_includes policy.errors[:settings], "needs a GitHub repository or repository routes for Linear automation"
  end

  test "dispatches QA only on a verified transition into a configured status" do
    policy = AutomationPolicy.create!(
      name: "Linear QA",
      provider: "linear",
      linear_team_id: "team-1",
      enabled: true,
      mode: "act",
      execution_role: automation_role,
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "issue" => "ready_issues",
          "qa" => "status_transition",
          "qa_statuses" => [ "QA" ],
          "qa_profiles" => [ "ios_smoke" ],
          "ready_statuses" => [ "Ready" ],
          "github_repository" => "acme/widgets"
        }
      }
    )
    event = {
      "event_type" => "Issue",
      "event_action" => "update",
      "linear_team_id" => "team-1",
      "title" => "Verify the widget",
      "description" => "Ready for QA",
      "status" => "QA",
      "labels" => []
    }

    unrelated_update = policy.evaluate(event.merge("updated_fields" => [ "title" ]))
    assert_equal "ignored", unrelated_update["decision"]
    assert_equal "issue status is not ready", unrelated_update["reason"]

    transition = policy.evaluate(event.merge("updated_fields" => [ "stateId" ]))
    assert_equal "act", transition["decision"]
    assert_equal [ "run_qa" ], transition["actions"]
    assert_equal [ "ios_smoke" ], transition["qa_profiles"]
    assert_equal "acme/widgets", transition["github_repository"]

    created_in_qa = policy.evaluate(event.merge("event_action" => "create"))
    assert_equal [ "run_qa" ], created_in_qa["actions"]
  end

  test "QA automation requires an explicit destination status" do
    policy = AutomationPolicy.new(
      name: "Broken QA",
      provider: "linear",
      linear_team_id: "team-1",
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "qa" => "status_transition",
          "github_repository" => "acme/widgets"
        }
      }
    )

    assert_not policy.valid?
    assert_includes policy.errors[:settings], "needs at least one QA status when QA automation is enabled"
  end

  test "QA automation rejects unbounded executor inputs" do
    policy = AutomationPolicy.new(
      name: "Unsafe QA inputs",
      provider: "linear",
      linear_team_id: "team-1",
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "qa" => "status_transition",
          "qa_target" => "../../runner",
          "qa_statuses" => [ "QA" ],
          "qa_profiles" => [ "../../shell" ],
          "github_repository" => "acme/widgets"
        }
      }
    )

    assert_not policy.valid?
    assert_includes policy.errors[:settings], "has an invalid QA target"
    assert_includes policy.errors[:settings], "has invalid QA profiles"
  end

  test "QA-only policy uses its workflow principal instead of an issue coding role" do
    policy = AutomationPolicy.new(
      name: "Workflow-only QA",
      provider: "linear",
      linear_team_id: "team-1",
      enabled: true,
      mode: "act",
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "issue" => "off",
          "qa" => "status_transition",
          "qa_target" => "auto",
          "qa_statuses" => [ "QA" ],
          "github_repository" => "acme/widgets"
        }
      }
    )

    assert_predicate policy, :valid?
    assert_not policy.requires_execution_role?
  end

  test "routes ready Linear issues by project, with an explicit label override" do
    policy = AutomationPolicy.create!(
      name: "Routed Linear issues",
      provider: "linear",
      linear_team_id: "team-1",
      enabled: true,
      mode: "act",
      execution_role: automation_role,
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "issue" => "ready_issues",
          "required_labels" => [ "agent:ready" ],
          "repository_routes" => [
            {
              "repository" => "acme/widgets",
              "required_labels" => [ "repo:widgets" ],
              "label_project_ids" => [ "11111111-1111-1111-1111-111111111111" ]
            },
            {
              "repository" => "acme/travel",
              "linear_project_ids" => [ "11111111-1111-1111-1111-111111111111" ],
              "reviewer_logins" => [ "octocat" ],
              "reviewer_team_slugs" => [ "product" ],
              "preview_label" => "preview"
            }
          ]
        }
      }
    )

    routed = policy.evaluate(
      "event_type" => "Issue",
      "event_action" => "update",
      "linear_team_id" => "team-1",
      "title" => "Ship travel UI",
      "description" => "Acceptance Criteria\n- It is shippable.",
      "labels" => [ "agent:ready" ],
      "linear_project_id" => "11111111-1111-1111-1111-111111111111"
    )

    assert_equal "act", routed["decision"]
    assert_equal "acme/travel", routed["github_repository"]
    assert_equal "preview", routed["preview_label"]
    assert_equal [ "octocat" ], routed["reviewer_logins"]
    assert_equal [ "product" ], routed["reviewer_team_slugs"]
    assert_includes policy.automation_summary, "acme/widgets, acme/travel"

    unmatched = policy.evaluate(
      "event_type" => "Issue",
      "event_action" => "update",
      "linear_team_id" => "team-1",
      "title" => "Ship unknown UI",
      "description" => "Acceptance Criteria\n- It is shippable.",
      "labels" => [ "agent:ready" ],
      "linear_project_id" => "22222222-2222-2222-2222-222222222222"
    )
    assert_equal "ignored", unmatched["decision"]
    assert_equal "no configured repository route matches issue labels or project", unmatched["reason"]

    label_override = policy.evaluate(
      "event_type" => "Issue",
      "event_action" => "update",
      "linear_team_id" => "team-1",
      "title" => "Ship conflicting UI",
      "description" => "Acceptance Criteria\n- It is shippable.",
      "labels" => [ "agent:ready", "repo:widgets" ],
      "linear_project_id" => "11111111-1111-1111-1111-111111111111"
    )
    assert_equal "act", label_override["decision"]
    assert_equal "acme/widgets", label_override["github_repository"]

    off_scope_label = policy.evaluate(
      "event_type" => "Issue",
      "event_action" => "update",
      "linear_team_id" => "team-1",
      "title" => "Ship an unrelated widget",
      "description" => "Acceptance Criteria\n- It is shippable.",
      "labels" => [ "agent:ready", "repo:widgets" ],
      "linear_project_id" => "22222222-2222-2222-2222-222222222222"
    )
    assert_equal "ignored", off_scope_label["decision"]
    assert_equal "no configured repository route matches issue labels or project", off_scope_label["reason"]
  end

  test "rejects overlapping explicit Linear label routes even with a project default" do
    policy = AutomationPolicy.create!(
      name: "Ambiguous label override",
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
              "repository" => "acme/web",
              "required_labels" => [ "repo:widgets", "area:web" ]
            },
            {
              "repository" => "acme/travel",
              "linear_project_ids" => [ "11111111-1111-1111-1111-111111111111" ]
            }
          ]
        }
      }
    )

    result = policy.evaluate(
      "event_type" => "Issue",
      "event_action" => "update",
      "linear_team_id" => "team-1",
      "title" => "Ship the web widget",
      "description" => "Acceptance Criteria\n- It is shippable.",
      "labels" => [ "repo:widgets", "area:web" ],
      "linear_project_id" => "11111111-1111-1111-1111-111111111111"
    )

    assert_equal "ignored", result["decision"]
    assert_equal "multiple configured repository routes match issue labels or project", result["reason"]
  end

  test "requires a verified, fully qualified Linear issue for a manual mention" do
    policy = AutomationPolicy.create!(
      name: "Manual Linear issues",
      provider: "linear",
      linear_team_id: "team-1",
      enabled: true,
      mode: "act",
      execution_role: automation_role,
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "issue" => "ready_issues",
          "manual_mentions" => true,
          "ready_statuses" => [ "Ready" ],
          "required_fields" => [ "description", "acceptance_criteria" ],
          "required_labels" => [ "agent:ready" ],
          "repository_routes" => [
            {
              "repository" => "acme/widgets",
              "required_labels" => [ "agent:repo:widgets" ]
            }
          ]
        }
      }
    )

    allowed = policy.evaluate(
      "event_type" => "Issue",
      "event_action" => "manual_mention",
      "mentioned_bot" => true,
      "linear_team_id" => "team-1",
      "title" => "Ship the widget",
      "description" => "Acceptance Criteria\n- The widget is shipped.",
      "status" => "Ready",
      "labels" => [ "agent:ready", "agent:repo:widgets" ]
    )
    assert_equal "act", allowed["decision"]
    assert_equal [ "respond_to_mention" ], allowed["actions"]
    assert_equal "acme/widgets", allowed["github_repository"]

    unverified = policy.evaluate(
      "event_type" => "Issue",
      "event_action" => "manual_mention",
      "mentioned_bot" => false,
      "linear_team_id" => "team-1",
      "title" => "Ship the widget",
      "description" => "Acceptance Criteria\n- The widget is shipped.",
      "status" => "Ready",
      "labels" => [ "agent:ready", "agent:repo:widgets" ]
    )
    assert_equal "ignored", unverified["decision"]
    assert_equal "event is not a verified bot mention", unverified["reason"]

    incomplete = policy.evaluate(
      "event_type" => "Issue",
      "event_action" => "manual_mention",
      "mentioned_bot" => true,
      "linear_team_id" => "team-1",
      "title" => "Ship the widget",
      "description" => "",
      "status" => "Ready",
      "labels" => [ "agent:ready", "agent:repo:widgets" ]
    )
    assert_equal "ignored", incomplete["decision"]
    assert_equal "issue description is missing", incomplete["reason"]
  end

  test "runs deterministic QA only for an explicitly QA-enabled repository route" do
    policy = AutomationPolicy.create!(
      name: "Routed QA",
      provider: "linear",
      linear_team_id: "team-1",
      enabled: true,
      mode: "act",
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "issue" => "off",
          "qa" => "status_transition",
          "qa_statuses" => [ "QA" ],
          "repository_routes" => [
            {
              "repository" => "acme/widgets",
              "linear_project_ids" => [ "11111111-1111-1111-1111-111111111111" ],
              "qa_enabled" => true
            },
            {
              "repository" => "acme/infra",
              "linear_project_ids" => [ "22222222-2222-2222-2222-222222222222" ],
              "qa_enabled" => false
            }
          ]
        }
      }
    )

    qa = policy.evaluate(
      "event_type" => "Issue",
      "event_action" => "update",
      "linear_team_id" => "team-1",
      "linear_project_id" => "11111111-1111-1111-1111-111111111111",
      "title" => "Verify widget",
      "description" => "Ready for QA",
      "status" => "QA",
      "updated_fields" => [ "stateId" ],
      "labels" => []
    )
    assert_equal "act", qa["decision"]
    assert_equal [ "run_qa" ], qa["actions"]
    assert_equal "acme/widgets", qa["github_repository"]

    excluded = policy.evaluate(
      "event_type" => "Issue",
      "event_action" => "update",
      "linear_team_id" => "team-1",
      "linear_project_id" => "22222222-2222-2222-2222-222222222222",
      "title" => "Verify infrastructure",
      "description" => "Ready for QA",
      "status" => "QA",
      "updated_fields" => [ "stateId" ],
      "labels" => []
    )
    assert_equal "ignored", excluded["decision"]
    assert_equal "ready issue automation is disabled", excluded["reason"]
  end

  test "requires repository routes to be explicit" do
    policy = AutomationPolicy.new(
      name: "Unsafe routes",
      provider: "linear",
      linear_team_id: "team-1",
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "issue" => "ready_issues",
          "github_repository" => "acme/widgets",
          "repository_routes" => [
            {
              "repository" => "acme/widgets",
              "required_labels" => []
            },
            {
              "repository" => "acme/other-widgets",
              "required_labels" => [ "repo:widgets" ],
              "unknown" => true
            }
          ]
        }
      }
    )

    assert_not policy.valid?
    assert_includes policy.errors[:settings], "must use either a GitHub repository or repository routes, not both"
    assert_includes policy.errors[:settings], "repository route 1 needs at least one project or label selector"
    assert_includes policy.errors[:settings], "repository route 2 has unsupported fields"
  end

  test "rejects invalid and overlapping Linear project route selectors" do
    policy = AutomationPolicy.new(
      name: "Unsafe project routes",
      provider: "linear",
      linear_team_id: "team-1",
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "issue" => "ready_issues",
          "repository_routes" => [
            {
              "repository" => "acme/widgets",
              "linear_project_ids" => [ "not-a-linear-project-id" ],
              "label_project_ids" => [ "also-not-a-linear-project-id" ]
            },
            {
              "repository" => "acme/travel",
              "linear_project_ids" => [ "11111111-1111-1111-1111-111111111111" ]
            },
            {
              "repository" => "acme/other",
              "linear_project_ids" => [ "11111111-1111-1111-1111-111111111111" ]
            }
          ]
        }
      }
    )

    assert_not policy.valid?
    assert_includes policy.errors[:settings], "repository route 1 has invalid Linear project IDs"
    assert_includes policy.errors[:settings], "repository route 1 has invalid label project IDs"
    assert_includes policy.errors[:settings], "repository route 3 repeats a Linear project ID from route 2"
  end

  test "allows distinct label routes to share a repository" do
    policy = AutomationPolicy.new(
      name: "One repository, two work types",
      provider: "linear",
      linear_team_id: "team-1",
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "issue" => "ready_issues",
          "repository_routes" => [
            {
              "repository" => "acme/widgets",
              "required_labels" => [ "area:api" ]
            },
            {
              "repository" => "acme/widgets",
              "required_labels" => [ "area:web" ],
              "preview_label" => "preview"
            }
          ]
        }
      }
    )

    assert_predicate policy, :valid?
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

  test "validates and routes a bounded cross-model GitHub review group" do
    orchestration = {
      "mode" => "cross_model",
      "max_concurrency" => 2,
      "reviewers" => [
        {
          "id" => "correctness",
          "harness" => "codex",
          "model" => "glm-5.2-fp8",
          "reasoning" => "high",
          "focus" => [ "correctness", "tests" ],
          "max_runs_per_epoch" => 3,
          "fallbacks" => [ { "harness" => "codex", "model" => "glm-5.1-fp8", "reasoning" => "high" } ]
        },
        {
          "id" => "independent",
          "harness" => "codex",
          "model" => "glm-5.1-fp8",
          "reasoning" => "high",
          "focus" => [ "security" ],
          "max_runs_per_epoch" => 3,
          "fallbacks" => []
        }
      ],
      "synthesizer" => {
        "id" => "synthesis",
        "harness" => "codex",
        "model" => "glm-5.2-fp8",
        "reasoning" => "high",
        "focus" => [],
        "max_runs_per_epoch" => 3,
        "fallbacks" => []
      }
    }
    policy = AutomationPolicy.new(
      name: "Cross-model widgets",
      provider: "github",
      repository: "acme/cross-model-widgets",
      enabled: true,
      mode: "observe",
      created_by: users(:acme_admin),
      settings: { "github" => { "review" => "all_eligible", "review_orchestration" => orchestration } }
    )

    assert_predicate policy, :valid?
    outcome = policy.evaluate(
      "repository" => "acme/cross-model-widgets",
      "event_type" => "pull_request",
      "event_action" => "opened",
      "base_branch" => "main",
      "draft" => false,
      "labels" => []
    )
    assert_equal orchestration, outcome["review_orchestration"]

    policy.settings["github"]["review_orchestration"]["reviewers"][1]["model"] = "glm-5.2-fp8"
    assert_not_predicate policy, :valid?
    assert_includes policy.errors[:settings], "cross-model review needs at least two distinct primary models"
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

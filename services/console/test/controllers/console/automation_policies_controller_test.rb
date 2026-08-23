require "test_helper"

class Console::AutomationPoliciesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @operator = users(:acme_admin)
    post login_url, params: { email: @operator.email, password: "password123456" }
  end

  test "renders the automation page and creates an observe-only GitHub policy" do
    get console_automation_policies_url

    assert_response :ok
    assert_select "h1", text: "Repository Automations"
    assert_select "a[href=?]", new_console_automation_policy_path, text: "New policy"

    assert_difference -> { AutomationPolicy.count }, 1 do
      post console_automation_policies_url, params: {
        automation_policy: {
          name: "Widgets",
          provider: "github",
          repository: "acme/widgets",
          mode: "observe",
          enabled: "1",
          github_review_mode: "all_eligible",
          github_feedback_mode: "eligible",
          github_checks_mode: "eligible",
          github_conflicts_mode: "eligible",
          github_base_branches: "main",
          github_required_labels: "agent-ok",
          github_excluded_labels: "no-agent",
          github_auto_merge: "0"
        }
      }
    end

    assert_redirected_to console_automation_policies_path
    policy = AutomationPolicy.order(:id).last
    assert_equal @operator, policy.created_by
    assert_equal "all_eligible", policy.github_settings["review"]
    assert_equal [ "main" ], policy.github_settings["base_branches"]
  end

  test "does not let a non-admin write policies" do
    delete logout_url
    post login_url, params: { email: users(:member_user).email, password: "password123456" }

    assert_no_difference -> { AutomationPolicy.count } do
      post console_automation_policies_url, params: {
        automation_policy: { name: "Nope", provider: "github", repository: "acme/widgets" }
      }
    end

    assert_redirected_to console_threads_path
  end

  test "renders the latest safe decision and reason for a workstream" do
    policy = AutomationPolicy.create!(
      name: "Widgets automation",
      provider: "github",
      repository: "acme/widgets",
      enabled: true,
      mode: "observe",
      created_by: @operator,
      settings: { "github" => { "review" => "all_eligible" } }
    )
    workstream = AutomationWorkstream.create!(
      automation_policy: policy,
      provider: "github",
      repository: "acme/widgets",
      session_key: "github-manage:acme/widgets:42",
      subject_key: "github:acme/widgets:pr:42",
      event_count: 1,
      last_event_at: Time.current
    )
    AutomationEvent.create!(
      automation_workstream: workstream,
      provider: "github",
      deduplication_key: "delivery-42",
      event_type: "pull_request",
      event_action: "opened",
      decision: "observe",
      action_kind: "review",
      metadata: { "result" => { "reason" => "policy authorizes automation" } },
      received_at: workstream.last_event_at
    )

    get console_automation_policies_url

    assert_response :ok
    assert_select "span", text: "observe"
    assert_select ".automation-workstream-reason", text: "policy authorizes automation"
  end
end

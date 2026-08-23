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

  test "searches workstreams by normalized provider delivery and links to the audit trail" do
    matching = create_workstream_with_event(
      subject_key: "github:acme/widgets:pr:42",
      deduplication_key: "delivery-search-42"
    )
    create_workstream_with_event(
      subject_key: "github:acme/widgets:pr:43",
      deduplication_key: "delivery-other-43"
    )

    get console_automation_policies_url, params: { q: "search-42" }

    assert_response :ok
    assert_select "input[name=q][value='search-42']"
    assert_select "a[href=?]", console_automation_workstream_path(matching.oid), text: "Audit"
    assert_select "a", text: "github:acme/widgets:pr:42"
    assert_select "a", text: "github:acme/widgets:pr:43", count: 0
  end

  test "searches workstreams by a native execution ID" do
    matching = create_workstream_with_event(
      subject_key: "github:acme/widgets:pr:84",
      deduplication_key: "delivery-execution-84"
    )
    test_case = self
    relation = Object.new
    relation.define_singleton_method(:limit) { |limit| test_case.assert_equal 100, limit; self }
    relation.define_singleton_method(:pluck) { |column| test_case.assert_equal :thread_key, column; [ matching.session_key ] }

    CentaurSessionExecution.stub(:where, lambda { |sql, pattern|
      assert_equal "execution_id ILIKE ?", sql
      assert_equal "%execution-search-84%", pattern
      relation
    }) do
      get console_automation_policies_url, params: { q: "execution-search-84" }
    end

    assert_response :ok
    assert_select "a[href=?]", console_automation_workstream_path(matching.oid), text: "Audit"
  end

  test "renders only normalized event audit fields on a workstream" do
    workstream = create_workstream_with_event(
      subject_key: "github:acme/widgets:pr:4242",
      deduplication_key: "linear-delivery-42",
      metadata: {
        "result" => { "reason" => "issue is blocked" },
        "untrusted_payload" => "must not render"
      }
    )

    execution = Struct.new(:execution_id, :status, :started_at, :created_at, :completed_at).new(
      "execution-native-42",
      "completed",
      5.minutes.ago,
      5.minutes.ago,
      Time.current
    )
    relation = Object.new
    relation.define_singleton_method(:order) { |*| self }
    relation.define_singleton_method(:limit) { |*| self }
    relation.define_singleton_method(:to_a) { [ execution ] }

    CentaurSessionExecution.stub(:where, lambda { |*args, **kwargs|
      filters = kwargs.presence || args.first
      assert_equal({ thread_key: workstream.session_key }, filters)
      relation
    }) do
      get console_automation_workstream_path(workstream.oid)
    end

    assert_response :ok
    assert_select "h1", text: "Automation audit"
    assert_select "td", text: "issue is blocked"
    assert_select "td", text: "linear-delivery-42"
    assert_select "h2", text: "Native session executions"
    assert_select "td", text: "execution-native-42"
    assert_select "td", text: "completed"
    assert_no_match "must not render", response.body
    assert_select "a[href=?]", console_threads_path(thread: workstream.session_key)
  end

  test "does not let a non-admin inspect a workstream audit trail" do
    workstream = create_workstream_with_event(
      subject_key: "github:acme/widgets:pr:44",
      deduplication_key: "delivery-member-44"
    )
    delete logout_url
    post login_url, params: { email: users(:member_user).email, password: "password123456" }

    get console_automation_workstream_path(workstream.oid)

    assert_redirected_to console_threads_path
  end

  private

  def create_workstream_with_event(subject_key:, deduplication_key:, metadata: nil)
    policy = AutomationPolicy.create!(
      name: "Audit #{subject_key}",
      provider: "github",
      repository: "acme/widgets-#{SecureRandom.hex(4)}",
      enabled: true,
      mode: "observe",
      created_by: @operator,
      settings: { "github" => { "review" => "all_eligible" } }
    )
    workstream = AutomationWorkstream.create!(
      automation_policy: policy,
      provider: "github",
      repository: "acme/widgets",
      session_key: "github-manage:acme/widgets:#{SecureRandom.random_number(1_000_000)}",
      subject_key: subject_key,
      event_count: 1,
      last_event_at: Time.current
    )
    AutomationEvent.create!(
      automation_workstream: workstream,
      provider: "github",
      deduplication_key: deduplication_key,
      event_type: "pull_request",
      event_action: "opened",
      decision: "observe",
      action_kind: "review",
      metadata: metadata || { "result" => { "reason" => "policy authorizes automation" } },
      received_at: workstream.last_event_at
    )
    workstream
  end
end

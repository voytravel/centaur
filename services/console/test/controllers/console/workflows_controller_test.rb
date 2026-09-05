require "test_helper"

class Console::WorkflowsControllerTest < ActionDispatch::IntegrationTest
  FakeWorkflowRun = Struct.new(
    :workflow_name,
    :workflow_name_label,
    :task_name,
    :display_status,
    :queue_name,
    :queue_label,
    :attempts,
    :max_attempts,
    :started_or_created_at,
    :created_at,
    :terminal_at,
    :recency_at,
    :run_id,
    :task_id,
    :harness_type,
    :queue_run_count,
    keyword_init: true
  ) do
    def workflow_name_label
      self[:workflow_name_label].presence || workflow_name.presence || task_name.presence || "unknown workflow"
    end

    def workflow_key
      workflow_name.presence || task_name.presence
    end

    def recency_at
      self[:recency_at] || terminal_at || started_or_created_at
    end
  end

  # Stands in for CentaurApiClient: schedules/run details for show-page
  # enrichment, plus a capture of force-started runs.
  class FakeApiClient
    attr_reader :created_runs, :idempotency_lookups

    def initialize(schedules: [], run_details: {}, action_runs: {}, create_result: nil, create_error: nil, lookup_error: nil)
      @schedules = schedules
      @run_details = run_details
      @action_runs = action_runs
      @create_result = create_result || { "ok" => true, "run_id" => "run-new", "created" => true }
      @create_error = create_error
      @lookup_error = lookup_error
      @created_runs = []
      @idempotency_lookups = []
    end

    def list_workflow_schedules
      { "ok" => true, "schedules" => @schedules }
    end

    def get_workflow_run(run_id)
      detail = @run_details[run_id]
      raise CentaurApiClient::Error, "run not found" unless detail

      { "ok" => true, "run" => detail }
    end

    def find_workflow_run_by_idempotency_key(workflow_name:, idempotency_key:)
      raise CentaurApiClient::Error, @lookup_error if @lookup_error
      @idempotency_lookups << { workflow_name: workflow_name, idempotency_key: idempotency_key }
      @action_runs[idempotency_key]
    end

    def create_workflow_run(workflow_name:, input: nil, idempotency_key: nil, max_attempts: nil)
      raise CentaurApiClient::Error, @create_error if @create_error

      @created_runs << {
        workflow_name: workflow_name,
        input: input,
        idempotency_key: idempotency_key,
        max_attempts: max_attempts
      }
      @create_result
    end
  end

  setup do
    @original_client_factory = Console::WorkflowsController.client_factory
    with_api_client(FakeApiClient.new)
    @operator = users(:acme_admin)
    post login_url, params: { email: @operator.email, password: "password123456" }
  end

  teardown do
    Console::WorkflowsController.client_factory = @original_client_factory
  end

  test "an admin sees one row per workflow" do
    run = fake_run(workflow_name: "slack_sync", display_status: "running")

    with_workflow_index(runs: [ run ]) do
      get console_workflows_url
    end

    assert_response :ok
    assert_select "h1", count: 0
    assert_select ".console-thread-group-title-active", text: /Workflows/
    assert_select "a[href=?]", console_workflow_path("slack_sync"), text: /slack_sync/
    assert_select "span", text: "running"
    assert_select "a[href=?]", console_workflows_path
    assert response.body.index('href="/console/workflows"') < response.body.index('href="/console/threads"')
  end

  test "the workflow index does not show run ids" do
    run = fake_run(workflow_name: "slack_sync")

    with_workflow_index(runs: [ run ]) do
      get console_workflows_url
    end

    assert_response :ok
    assert_no_match run.run_id, response.body
    assert_no_match run.task_id, response.body
  end

  test "a non-admin is redirected away from the workflow dashboard" do
    delete logout_url
    post login_url, params: { email: users(:member_user).email, password: "password123456" }

    get console_workflows_url

    assert_redirected_to console_threads_path
    assert_nil flash[:alert]
  end

  test "a non-admin does not see the workflows tab" do
    delete logout_url
    post login_url, params: { email: users(:member_user).email, password: "password123456" }

    get console_threads_url

    assert_response :ok
    assert_select ".console-nav-link", text: "Control", count: 0
    assert_select ".console-nav-link", text: "Data Sync", count: 0
    assert_select ".console-thread-group-title", text: /Chats/
    assert_select ".console-thread-group-title", text: /Scheduled/, count: 0
    assert_select ".console-thread-group-title", text: /Workflows/, count: 0
  end

  test "workflow show page marks the active status tab and passes the filter through" do
    run = fake_run(workflow_name: "slack_sync", display_status: "failed")
    seen = {}

    with_workflow_history(
      "slack_sync",
      runs: [ run ],
      status_counts: { "completed" => 9, "failed" => 1 },
      capture: seen
    ) do
      get console_workflow_url("slack_sync"), params: { status: "failed" }
    end

    assert_response :ok
    assert_equal "failed", seen[:status]
    assert_select "a.chip-on", text: /failed\s*1/
  end

  test "workflow show page renders without api enrichment when the api is down" do
    run = fake_run(workflow_name: "slack_sync")
    with_api_client(FakeApiClient.new(run_details: {}))

    with_workflow_history("slack_sync", runs: [ run ]) do
      get console_workflow_url("slack_sync")
    end

    assert_response :ok
    assert_select "h2", text: "Debugging", count: 0
    assert_select "dt", text: "Schedule", count: 0
  end

  test "a completed QA monitor prominently shows a failed QA outcome" do
    run = fake_run(workflow_name: "linear_qa_control_plane", display_status: "completed")
    with_api_client(FakeApiClient.new(run_details: {
      run.run_id => { "run_id" => run.run_id, "workflow_name" => run.workflow_name, "status" => "completed",
                      "result" => { "output" => { "conclusion" => "failure" } } }
    }))
    with_workflow_history(run.workflow_name, runs: [ run ]) do
      get console_workflow_url(run.workflow_name)
    end
    assert_response :ok
    assert_select "span", text: "Engine: completed"
    assert_select "span", text: "QA failure"
    assert_select "a[href=?]", console_workflow_path(run.workflow_name, run_id: run.run_id)
  end

  test "force starting a workflow queues a run with the schedule input" do
    client = FakeApiClient.new(schedules: [ slack_sync_schedule ])
    with_api_client(client)

    post run_console_workflow_url("slack_sync")

    assert_redirected_to console_workflow_path("slack_sync")
    assert_match(/Run queued \(run-new\)/, flash[:notice])
    assert_equal [
      {
        workflow_name: "slack_sync",
        input: { "mode" => "incremental" },
        idempotency_key: nil,
        max_attempts: nil
      }
    ], client.created_runs
  end

  test "renders an approval-required dependency-maintenance finding from the selected observation run" do
    run = fake_run(workflow_name: "github_dependency_maintenance")
    detail = maintenance_run_detail(run.run_id)
    with_api_client(FakeApiClient.new(run_details: { run.run_id => detail }))

    with_workflow_history("github_dependency_maintenance", runs: [ run ]) do
      get console_workflow_url("github_dependency_maintenance", run_id: run.run_id)
    end

    assert_response :ok
    assert_select "h2", text: "Approval-required findings"
    assert_select "p", text: /acme\/widgets.*security alert #19/
    assert_select "form[action=?]", approve_finding_console_workflow_path("github_dependency_maintenance")
    assert_select "button", text: "Approve scoped action"
  end

  test "renders an approval-required finding from a Python workflow-host result envelope" do
    run = fake_run(workflow_name: "github_dependency_maintenance")
    detail = maintenance_run_detail(run.run_id)
    payload = detail.fetch("result")
    detail["result"] = {
      "output" => payload,
      "run_id" => run.run_id,
      "steps" => [ "python_host" ],
      "task_id" => run.task_id,
      "workflow_name" => "github_dependency_maintenance"
    }
    with_api_client(FakeApiClient.new(run_details: { run.run_id => detail }))

    with_workflow_history("github_dependency_maintenance", runs: [ run ]) do
      get console_workflow_url("github_dependency_maintenance", run_id: run.run_id)
    end

    assert_response :ok
    assert_select "h2", text: "Approval-required findings"
    assert_select "button", text: "Approve scoped action"
  end

  test "links an already queued scoped action instead of offering a second approval" do
    run = fake_run(workflow_name: "github_dependency_maintenance")
    finding_key = GithubDependencyMaintenanceFinding.for_run(maintenance_run_detail(run.run_id)).first.idempotency_key
    client = FakeApiClient.new(
      run_details: { run.run_id => maintenance_run_detail(run.run_id) },
      action_runs: {
        finding_key => { "run_id" => "action-run-1", "status" => "queued" }
      }
    )
    with_api_client(client)

    with_workflow_history("github_dependency_maintenance", runs: [ run ]) do
      get console_workflow_url("github_dependency_maintenance", run_id: run.run_id)
    end

    assert_response :ok
    assert_select "button", text: "Approve scoped action", count: 0
    assert_select "span", text: "Action queued"
    assert_select(
      "a[href=?]",
      console_workflow_path("github_dependency_maintenance_action", run_id: "action-run-1"),
      text: "Open action ↗"
    )
    assert_empty client.created_runs
    assert_equal [
      {
        workflow_name: "github_dependency_maintenance_action",
        idempotency_key: finding_key
      }
    ], client.idempotency_lookups
  end

  test "approving a validated dependency finding queues one scoped action with a durable idempotency key" do
    source_run_id = "run-observation-1"
    client = FakeApiClient.new(run_details: { source_run_id => maintenance_run_detail(source_run_id) })
    with_api_client(client)

    post approve_finding_console_workflow_path("github_dependency_maintenance"), params: {
      run_id: source_run_id,
      repository: "acme/widgets",
      finding_key: "security:19"
    }

    assert_redirected_to console_workflow_path("github_dependency_maintenance", run_id: source_run_id)
    assert_match(/Scoped action queued/, flash[:notice])
    assert_equal [
      {
        workflow_name: "github_dependency_maintenance_action",
        input: {
          "source_run_id" => source_run_id,
          "repository" => "acme/widgets",
          "base_branch" => "main",
          "finding" => {
            "key" => "security:19",
            "kind" => "security_advisory",
            "action" => "draft_pr",
            "source_numbers" => [ 19 ]
          },
          "approved_by" => @operator.oid
        },
        idempotency_key: GithubDependencyMaintenanceFinding.for_run(maintenance_run_detail(source_run_id)).first.idempotency_key,
        max_attempts: nil
      }
    ], client.created_runs
  end

  test "unknown action status hides approval and also rejects a direct approval POST" do
    run = fake_run(workflow_name: "github_dependency_maintenance")
    client = FakeApiClient.new(run_details: { run.run_id => maintenance_run_detail(run.run_id) }, lookup_error: "unavailable")
    with_api_client(client)
    with_workflow_history("github_dependency_maintenance", runs: [ run ]) do
      get console_workflow_url("github_dependency_maintenance", run_id: run.run_id)
    end
    assert_select "button", text: "Approve scoped action", count: 0
    assert_select "span", text: /Action status unavailable/
    post approve_finding_console_workflow_path("github_dependency_maintenance"), params: {
      run_id: run.run_id, repository: "acme/widgets", finding_key: "security:19"
    }
    assert_match(/Could not queue/, flash[:alert])
    assert_empty client.created_runs
  end

  test "mutating workflow diagnostics never claim that no action happened" do
    run = fake_run(workflow_name: "github_dependency_maintenance")
    detail = maintenance_run_detail(run.run_id)
    route = detail.fetch("result").fetch("routes").first
    route["security_advisories"]["mode"] = "draft_pr"
    route["proposals"] = []
    route["diagnostic"] = { "kind" => "observer_unavailable", "code" => "agent_turn_unavailable", "summary" => "unused untrusted description" }
    with_api_client(FakeApiClient.new(run_details: { run.run_id => detail }))
    with_workflow_history(run.workflow_name, runs: [ run ]) do
      get console_workflow_url(run.workflow_name, run_id: run.run_id)
    end
    assert_response :ok
    assert_select "h2", text: "Workflow diagnostics"
    assert_select "p.text-red-300", text: /Repository action state is unknown/
    assert_select "p", text: /inspect GitHub before retrying/
    refute_includes response.body, "no-action workflow failures"
    refute_includes response.body, "No repository action was authorized"
    assert_select "button", text: "Approve scoped action", count: 0
  end

  test "matching legacy action is linked and cannot be approved a second time" do
    detail = maintenance_run_detail("run-observation-1")
    finding = GithubDependencyMaintenanceFinding.for_run(detail).first
    client = FakeApiClient.new(
      run_details: {
        finding.source_run_id => detail,
        "legacy-action" => { "run_id" => "legacy-action", "workflow_name" => "github_dependency_maintenance_action", "status" => "completed", "input" => finding.action_input(approved_by: "usr_previous") }
      },
      action_runs: { finding.legacy_idempotency_key => { "run_id" => "legacy-action" } }
    )
    with_api_client(client)
    post approve_finding_console_workflow_path("github_dependency_maintenance"), params: {
      run_id: finding.source_run_id, repository: finding.repository, finding_key: finding.key
    }
    assert_match(/already exists/, flash[:notice])
    assert_empty client.created_runs
  end

  test "selected action status does not show the latest run status or an empty trigger" do
    latest = fake_run(workflow_name: "github_dependency_maintenance_action", display_status: "completed")
    with_api_client(FakeApiClient.new(run_details: {
      "selected-failure" => { "run_id" => "selected-failure", "workflow_name" => latest.workflow_name, "status" => "failed", "failure" => { "message" => "fixture failure" } }
    }))
    with_workflow_history(latest.workflow_name, runs: [ latest ]) do
      get console_workflow_url(latest.workflow_name, run_id: "selected-failure")
    end
    assert_select "div[role=status]", text: /Viewing selected run.*failed/m
    assert_select "span", text: "failed"
    assert_select "button", text: "Manually Trigger", count: 0
    post run_console_workflow_path(latest.workflow_name)
    assert_match(/approval card/, flash[:alert])
  end

  test "renders a ready Dependabot merge as a distinct, revalidated approval" do
    run = fake_run(workflow_name: "github_dependency_maintenance")
    detail = maintenance_run_detail(run.run_id)
    route = detail.fetch("result").fetch("routes").first
    route["security_advisories"] = {
      "mode" => "approval_required",
      "outcome" => "none",
      "alert_numbers" => []
    }
    route["dependabot"] = {
      "mode" => "approval_required",
      "outcome" => "direct_ready",
      "source_pr_numbers" => [ 42 ]
    }
    route["proposals"] = [
      {
        "kind" => "dependabot_pull_request",
        "action" => "merge",
        "source_numbers" => [ 42 ]
      }
    ]
    with_api_client(FakeApiClient.new(run_details: { run.run_id => detail }))

    with_workflow_history("github_dependency_maintenance", runs: [ run ]) do
      get console_workflow_url("github_dependency_maintenance", run_id: run.run_id)
    end

    assert_response :ok
    assert_select "p", text: /Merge the ready Dependabot PR/
    assert_select "p", text: /squash-merge it through GitHub's normal protections/
    assert_select "button", text: "Approve scoped action"
  end

  test "does not queue an action when a proposal fails the approval-required contract" do
    source_run_id = "run-observation-1"
    detail = maintenance_run_detail(source_run_id)
    detail["result"]["routes"][0]["security_advisories"]["mode"] = "observe"
    client = FakeApiClient.new(run_details: { source_run_id => detail })
    with_api_client(client)

    post approve_finding_console_workflow_path("github_dependency_maintenance"), params: {
      run_id: source_run_id,
      repository: "acme/widgets",
      finding_key: "security:19"
    }

    assert_redirected_to console_workflow_path("github_dependency_maintenance")
    assert_match(/Could not approve finding/, flash[:alert])
    assert_empty client.created_runs
  end

  test "force starting a workflow surfaces api errors" do
    with_api_client(FakeApiClient.new(create_error: "workflow runtime is not enabled"))

    post run_console_workflow_url("slack_sync")

    assert_redirected_to console_workflow_path("slack_sync")
    assert_match(/workflow runtime is not enabled/, flash[:alert])
  end

  test "a non-admin cannot force start a workflow" do
    delete logout_url
    post login_url, params: { email: users(:member_user).email, password: "password123456" }
    client = FakeApiClient.new
    with_api_client(client)

    post run_console_workflow_url("slack_sync")

    assert_redirected_to console_threads_path
    assert_empty client.created_runs
  end

  test "a non-admin cannot approve a dependency-maintenance finding" do
    delete logout_url
    post login_url, params: { email: users(:member_user).email, password: "password123456" }
    source_run_id = "run-observation-1"
    client = FakeApiClient.new(run_details: { source_run_id => maintenance_run_detail(source_run_id) })
    with_api_client(client)

    post approve_finding_console_workflow_url("github_dependency_maintenance"), params: {
      run_id: source_run_id,
      repository: "acme/widgets",
      finding_key: "security:19"
    }

    assert_redirected_to console_threads_path
    assert_empty client.created_runs
  end

  test "workflow show page returns not found for unknown workflow" do
    with_workflow_history("missing") do
      get console_workflow_url("missing")
    end

    assert_response :not_found
    assert_select "body", text: /No workflow runs found for missing/
  end

  private

  def with_api_client(client)
    Console::WorkflowsController.client_factory = -> { client }
  end

  def slack_sync_schedule
    {
      "schedule_id" => "slack_sync",
      "workflow_name" => "slack_sync",
      "source_path" => "workflows/slack/sync.py",
      "kind" => { "type" => "cron", "cron" => "*/5 * * * *" },
      "timezone" => "America/Los_Angeles",
      "input" => { "mode" => "incremental" },
      "enabled" => true,
      "no_delivery" => false
    }
  end

  def maintenance_run_detail(run_id)
    {
      "workflow_name" => "github_dependency_maintenance",
      "run_id" => run_id,
      "status" => "completed",
      "result" => {
        "status" => "completed",
        "routes" => [
          {
            "schema_version" => "2",
            "repository" => "acme/widgets",
            "base_branch" => "main",
            "security_advisories" => {
              "mode" => "approval_required",
              "outcome" => "observed",
              "alert_numbers" => [ 19 ]
            },
            "dependabot" => {
              "mode" => "approval_required",
              "outcome" => "none",
              "source_pr_numbers" => []
            },
            "proposals" => [
              {
                "kind" => "security_advisory",
                "action" => "draft_pr",
                "source_numbers" => [ 19 ]
              }
            ]
          }
        ]
      }
    }
  end

  def fake_run(attrs = {})
    now = Time.zone.parse("2026-07-06 12:00:00 UTC")
    FakeWorkflowRun.new({
      workflow_name: "echo",
      workflow_name_label: nil,
      task_name: "centaur_workflow",
      display_status: "completed",
      queue_name: "centaur_workflows",
      queue_label: "default",
      attempts: 1,
      max_attempts: 3,
      started_or_created_at: now,
      created_at: now,
      terminal_at: now + 2.minutes,
      recency_at: nil,
      run_id: "00000000-0000-0000-0000-000000000001",
      task_id: "00000000-0000-0000-0000-000000000002",
      harness_type: nil,
      queue_run_count: 1
    }.merge(attrs))
  end

  def with_workflow_index(runs:, queue_breakdown: {}, workflow_count: nil)
    with_centaur_workflow_run_methods(
      available?: -> { true },
      workflow_count: -> { workflow_count || runs.size },
      latest_per_workflow: ->(limit:, offset: 0) { runs },
      latest_per_queue: ->(keys) { queue_breakdown }
    ) do
      yield
    end
  end

  def with_workflow_history(workflow_name, runs: [], status_counts: nil, queue_names: [], run_count: nil, capture: nil)
    status_counts ||= runs.group_by(&:display_status).transform_values(&:size)
    with_centaur_workflow_run_methods(
      available?: -> { true },
      for_workflow: ->(name, limit:, offset: 0, status: nil, queue: nil) {
        capture&.merge!(status: status, queue: queue, offset: offset)
        name == workflow_name && limit.positive? ? runs : []
      },
      status_counts: ->(name) { name == workflow_name ? status_counts : {} },
      queue_names: ->(name) { name == workflow_name ? queue_names : [] },
      run_count: ->(name, status: nil, queue: nil) { run_count || runs.size }
    ) do
      yield
    end
  end

  def with_centaur_workflow_run_methods(overrides)
    originals = overrides.keys.to_h { |name| [ name, CentaurWorkflowRun.method(name) ] }

    overrides.each do |name, implementation|
      CentaurWorkflowRun.define_singleton_method(name, &implementation)
    end

    yield
  ensure
    originals&.each do |name, original|
      CentaurWorkflowRun.define_singleton_method(name, original)
    end
  end
end

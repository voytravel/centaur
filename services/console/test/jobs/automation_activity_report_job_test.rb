require "test_helper"

class AutomationActivityReportJobTest < ActiveJob::TestCase
  class FakeApiClient
    attr_reader :requests

    def initialize
      @requests = []
    end

    def create_workflow_run(**request)
      @requests << request
      { "run_id" => "workflow-report-123", "created" => true }
    end
  end

  setup do
    @original_client_factory = AutomationActivityReportJob.client_factory
  end

  teardown do
    AutomationActivityReportJob.client_factory = @original_client_factory
  end

  test "starts one checkpointed workflow with the persisted event key" do
    event = reportable_event
    client = FakeApiClient.new
    AutomationActivityReportJob.client_factory = -> { client }

    with_env("CENTAUR_CONSOLE_PUBLIC_URL" => "https://console.example.test") do
      AutomationActivityReportJob.perform_now(event.id)
    end

    request = client.requests.sole
    assert_equal AutomationActivityReport::WORKFLOW_NAME, request[:workflow_name]
    assert_equal "automation-activity-report:#{event.id}", request[:idempotency_key]
    assert_equal AutomationActivityReport::WORKFLOW_MAX_ATTEMPTS, request[:max_attempts]
    assert_equal "C0123456789", request.dig(:input, "channel")
    assert_equal "accepted", request.dig(:input, "kind")
    assert_includes request.dig(:input, "text"), "Centaur automation accepted"
  end

  test "does nothing when the event has no policy-authorized report snapshot" do
    event = reportable_event(activity_report: {})
    client = FakeApiClient.new
    AutomationActivityReportJob.client_factory = -> { client }

    AutomationActivityReportJob.perform_now(event.id)

    assert_empty client.requests
  end

  test "starts a PR-created report from the persisted snapshot" do
    event = reportable_event(activity_report: { "kind" => "pr_created", "slack_channel" => "C0123456789" })
    client = FakeApiClient.new
    AutomationActivityReportJob.client_factory = -> { client }

    AutomationActivityReportJob.perform_now(event.id)

    request = client.requests.sole
    assert_equal "pr_created", request.dig(:input, "kind")
    assert_includes request.dig(:input, "text"), "Centaur created a pull request"
  end

  private

  def reportable_event(activity_report: { "kind" => "accepted", "slack_channel" => "C0123456789" })
    policy = AutomationPolicy.create!(
      name: "Report job #{SecureRandom.hex(4)}",
      provider: "github",
      repository: "acme/report-job-#{SecureRandom.hex(4)}",
      enabled: true,
      mode: "observe",
      created_by: users(:acme_admin),
      settings: { "github" => { "review" => "all_eligible" } }
    )
    workstream = AutomationWorkstream.create!(
      automation_policy: policy,
      provider: "github",
      repository: "acme/widgets",
      subject_key: "github:acme/widgets:pr:#{SecureRandom.random_number(10_000) + 1}",
      session_key: "github-manage:acme/widgets:#{SecureRandom.random_number(10_000) + 1}",
      last_event_at: Time.current
    )
    AutomationEvent.create!(
      automation_workstream: workstream,
      provider: "github",
      deduplication_key: "report-job-#{SecureRandom.hex(8)}",
      event_type: "pull_request",
      event_action: "opened",
      decision: "act",
      action_kind: "review",
      metadata: { "activity_report" => activity_report },
      received_at: Time.current
    )
  end
end

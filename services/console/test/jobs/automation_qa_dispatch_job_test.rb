require "test_helper"

class AutomationQaDispatchJobTest < ActiveJob::TestCase
  class FakeApiClient
    attr_reader :requests

    def initialize
      @requests = []
    end

    def create_workflow_run(**request)
      @requests << request
      {
        "run_id" => "workflow-qa-123",
        "task_id" => "task-qa-123",
        "status" => "pending",
        "created" => true
      }
    end
  end

  setup do
    @original_client_factory = AutomationQaDispatchJob.client_factory
  end

  teardown do
    AutomationQaDispatchJob.client_factory = @original_client_factory
  end

  test "starts one reviewed QA workflow and records its durable run" do
    event = qa_event
    client = FakeApiClient.new
    AutomationQaDispatchJob.client_factory = -> { client }

    AutomationQaDispatchJob.perform_now(event.id)

    request = client.requests.sole
    assert_equal AutomationQaDispatch::WORKFLOW_NAME, request[:workflow_name]
    assert_equal "automation-qa-dispatch:#{event.id}", request[:idempotency_key]
    assert_equal "ENG-42", request.dig(:input, "issue_identifier")
    assert_equal "Verify it", request.dig(:input, "issue_title")
    assert_equal "acme/widgets", request.dig(:input, "repository")
    assert_equal [ "ios_smoke" ], request.dig(:input, "profiles")
    assert_equal "auto", request.dig(:input, "target")
    assert_equal "workflow-qa-123", event.reload.metadata.dig("qa_workflow", "run_id")
  end

  test "does nothing for an event not authorized to run QA" do
    event = qa_event(action_kind: "implement_issue")
    client = FakeApiClient.new
    AutomationQaDispatchJob.client_factory = -> { client }

    AutomationQaDispatchJob.perform_now(event.id)

    assert_empty client.requests
  end

  private

  def qa_event(action_kind: "run_qa")
    policy = AutomationPolicy.create!(
      name: "QA job #{SecureRandom.hex(4)}",
      provider: "linear",
      linear_team_id: "team-#{SecureRandom.hex(4)}",
      enabled: true,
      mode: "act",
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "qa" => "status_transition",
          "qa_statuses" => [ "QA" ],
          "github_repository" => "acme/widgets"
        }
      }
    )
    workstream = AutomationWorkstream.create!(
      automation_policy: policy,
      provider: "linear",
      repository: "acme/widgets",
      subject_key: "linear:issue-#{SecureRandom.hex(6)}",
      session_key: "linear:issue-#{SecureRandom.hex(6)}",
      metadata: {
        "linear_issue_id" => "issue-42",
        "linear_issue_identifier" => "ENG-42",
        "linear_issue_title" => "Verify it",
        "linear_issue_url" => "https://linear.app/acme/issue/ENG-42/verify"
      },
      last_event_at: Time.current
    )
    AutomationEvent.create!(
      automation_workstream: workstream,
      provider: "linear",
      deduplication_key: "qa-job-#{SecureRandom.hex(8)}",
      event_type: "Issue",
      event_action: "update",
      decision: "act",
      action_kind: action_kind,
      metadata: { "result" => { "qa_profiles" => [ "ios_smoke" ] } },
      received_at: Time.current
    )
  end
end

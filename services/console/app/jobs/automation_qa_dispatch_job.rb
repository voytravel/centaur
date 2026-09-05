# Starts the reviewed QA orchestration workflow for one policy-authorized
# Linear transition. The persisted event id is the idempotency boundary, so a
# retried Active Job cannot create a second GitHub Actions run.
class AutomationQaDispatchJob < ApplicationJob
  queue_as :default

  retry_on CentaurApiClient::Error, wait: :polynomially_longer, attempts: 5
  discard_on ActiveRecord::RecordNotFound

  class_attribute :client_factory, default: -> { CentaurApiClient.new }

  def perform(event_id)
    event = AutomationEvent.includes(:automation_workstream).find(event_id)
    dispatch = AutomationQaDispatch.new(event)
    input = dispatch.workflow_input
    return unless input

    response = client_factory.call.create_workflow_run(
      workflow_name: AutomationQaDispatch::WORKFLOW_NAME,
      input: input,
      idempotency_key: dispatch.idempotency_key,
      max_attempts: AutomationQaDispatch::WORKFLOW_MAX_ATTEMPTS
    )
    record_dispatch(event, response)
  end

  private

  def record_dispatch(event, response)
    result = response.to_h.stringify_keys.slice("run_id", "task_id", "status", "created")
    result["workflow_name"] = AutomationQaDispatch::WORKFLOW_NAME
    event.with_lock do
      event.update!(metadata: event.metadata.merge("qa_workflow" => result))
    end
  end
end

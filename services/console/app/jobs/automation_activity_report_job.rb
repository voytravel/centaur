# Starts the native Workflow v2 delivery path for a single, policy-authorized
# activity notice. Its idempotency key is derived from the persisted event, so
# a retried Console job cannot create a second workflow or Slack root message.
class AutomationActivityReportJob < ApplicationJob
  queue_as :default

  retry_on CentaurApiClient::Error, wait: :polynomially_longer, attempts: 5
  discard_on ActiveRecord::RecordNotFound

  class_attribute :client_factory, default: -> { CentaurApiClient.new }

  def perform(event_id)
    event = AutomationEvent.includes(:automation_workstream).find(event_id)
    report = AutomationActivityReport.new(event)
    input = report.workflow_input
    return unless input

    client_factory.call.create_workflow_run(
      workflow_name: AutomationActivityReport::WORKFLOW_NAME,
      input: input,
      idempotency_key: report.idempotency_key,
      max_attempts: AutomationActivityReport::WORKFLOW_MAX_ATTEMPTS
    )
  end
end

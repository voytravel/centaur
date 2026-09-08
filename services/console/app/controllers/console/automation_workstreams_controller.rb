# Read-only operator view of the normalized automation audit trail. It does
# not expose raw provider payloads and does not mutate Centaur sessions.
class Console::AutomationWorkstreamsController < ApplicationController
  layout "console"

  before_action :require_admin

  def show
    @workstream = AutomationWorkstream
      .includes(:automation_policy, :principal, :authorization_role)
      .find_by_oid!(params[:id])
    # safe_source_url validates the provider-owned destination before this
    # presentation-only value reaches the template.
    @source_url = @workstream.safe_source_url
    @events = @workstream.automation_events.order(received_at: :desc, id: :desc).limit(100)
    @executions = native_executions
  end

  private

  # The session API is the source of truth for executions. Keep this observer
  # read-only and resilient if the session database is temporarily unavailable.
  def native_executions
    CentaurSessionExecution
      .where(thread_key: @workstream.session_key)
      .order(created_at: :desc, execution_id: :desc)
      .limit(25)
      .to_a
  rescue ActiveRecord::ActiveRecordError, PG::Error => e
    Rails.logger.debug("console_automation_execution_load_failed error=#{e.class}: #{e.message}")
    []
  end
end

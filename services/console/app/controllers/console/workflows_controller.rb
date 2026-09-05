class Console::WorkflowsController < ApplicationController
  layout "console"
  before_action :require_admin

  class_attribute :client_factory, default: -> { CentaurApiClient.new }

  PER_PAGE = 50

  def index
    @workflow_db_unavailable = false
    @workflow_runs = []
    @queue_breakdown = {}
    @page = page_param
    @total_pages = 1

    unless CentaurWorkflowRun.available?
      @workflow_db_unavailable = true
      return
    end

    @total_workflows = CentaurWorkflowRun.workflow_count
    @total_pages = [ (@total_workflows.to_f / PER_PAGE).ceil, 1 ].max
    @page = [ @page, @total_pages ].min

    @workflow_runs = CentaurWorkflowRun.latest_per_workflow(
      limit: PER_PAGE,
      offset: (@page - 1) * PER_PAGE
    )
    @queue_breakdown = CentaurWorkflowRun.latest_per_queue(@workflow_runs.map(&:workflow_key))
  rescue ActiveRecord::ActiveRecordError, PG::Error => e
    Rails.logger.warn("console_workflows_load_failed error=#{e.class}: #{e.message}")
    @workflow_db_unavailable = true
    @workflow_runs = []
    @queue_breakdown = {}
  end

  def show
    @workflow_db_unavailable = false
    @workflow_name = params[:id].to_s
    @workflow_runs = []
    @status_counts = {}
    @queue_names = []
    @status = params[:status].presence
    @queue = params[:queue].presence
    @page = page_param
    @total_pages = 1

    unless CentaurWorkflowRun.available?
      @workflow_db_unavailable = true
      return
    end

    @latest_run = CentaurWorkflowRun.for_workflow(@workflow_name, limit: 1).first
    if @latest_run.blank?
      response.status = :not_found
      return
    end

    @status_counts = CentaurWorkflowRun.status_counts(@workflow_name)
    @total_runs = @status_counts.values.sum
    @queue_names = CentaurWorkflowRun.queue_names(@workflow_name)

    @filtered_count = CentaurWorkflowRun.run_count(@workflow_name, status: @status, queue: @queue)
    @total_pages = [ (@filtered_count.to_f / PER_PAGE).ceil, 1 ].max
    @page = [ @page, @total_pages ].min

    @workflow_runs = CentaurWorkflowRun.for_workflow(
      @workflow_name,
      limit: PER_PAGE,
      offset: (@page - 1) * PER_PAGE,
      status: @status,
      queue: @queue
    )

    load_workflow_api_details
  rescue ActiveRecord::ActiveRecordError, PG::Error => e
    Rails.logger.warn("console_workflow_load_failed workflow=#{@workflow_name} error=#{e.class}: #{e.message}")
    @workflow_db_unavailable = true
    @workflow_runs = []
    @latest_run = nil
  end

  # Enqueue a run through the workflows API. Scheduled workflows are started
  # with their registered schedule input so a forced run matches a normal tick.
  def force_start
    workflow_name = params[:id].to_s
    if workflow_name == GithubDependencyMaintenanceFinding::ACTION_WORKFLOW_NAME
      redirect_to console_workflow_path(workflow_name), alert: "Start a scoped action from its observation approval card, not an empty manual run."
      return
    end
    schedule = workflow_schedules_for(workflow_name).first
    result = api_client.create_workflow_run(
      workflow_name: workflow_name,
      input: schedule&.dig("input")
    )
    notice =
      if result["created"] == false
        "A run with this idempotency key is already queued (#{result["run_id"]})."
      else
        "Run queued (#{result["run_id"]})."
      end
    redirect_to console_workflow_path(workflow_name), notice: notice
  rescue StandardError => e
    Rails.logger.warn("console_workflow_force_start_failed workflow=#{workflow_name} error=#{e.class}: #{e.message}")
    redirect_to console_workflow_path(workflow_name), alert: "Could not start workflow: #{e.message}"
  end

  # A scheduled observation is never itself permission to change a repository.
  # This trusted Console transition re-reads the immutable workflow result,
  # validates the selected proposal, and starts one separately scoped action
  # workflow under an idempotency key. The action workflow must still re-check
  # the reviewed route and live GitHub state before its narrowly scoped action.
  def approve_finding
    workflow_name = params[:id].to_s
    unless workflow_name == GithubDependencyMaintenanceFinding::WORKFLOW_NAME
      redirect_to console_workflow_path(workflow_name), alert: "This workflow has no approvable findings."
      return
    end

    source_run = api_client.get_workflow_run(params.require(:run_id)).fetch("run")
    finding = GithubDependencyMaintenanceFinding.find_for_approval(
      run: source_run,
      repository: params.require(:repository),
      finding_key: params.require(:finding_key)
    )
    existing = action_run_for(finding)
    result = existing&.merge("created" => false) || api_client.create_workflow_run(
      workflow_name: GithubDependencyMaintenanceFinding::ACTION_WORKFLOW_NAME,
      input: finding.action_input(approved_by: current_user.oid),
      idempotency_key: finding.idempotency_key
    )
    run_id = result["run_id"]
    notice =
      if result["created"] == false
        "That scoped action already exists (#{run_id}). Open action on its card to see the current outcome."
      else
        "Scoped action queued (#{run_id}). #{finding.queued_notice}"
      end
    redirect_to console_workflow_path(workflow_name, run_id: finding.source_run_id), notice: notice
  rescue GithubDependencyMaintenanceFinding::Invalid, ActionController::ParameterMissing, KeyError => e
    redirect_to console_workflow_path(workflow_name || params[:id]), alert: "Could not approve finding: #{e.message}"
  rescue StandardError => e
    Rails.logger.warn("console_workflow_finding_approval_failed workflow=#{workflow_name} error=#{e.class}: #{e.message}")
    redirect_to console_workflow_path(workflow_name || params[:id]), alert: "Could not queue scoped action: #{e.message}"
  end

  private

  # Best-effort enrichment from the workflows API: the registered schedule
  # (cron/interval, source path for the GitHub link) and the latest run's
  # input/result/failure for debugging. The page renders without any of it
  # when the API is unreachable.
  def load_workflow_api_details
    @workflow_schedules = workflow_schedules_for(@workflow_name)
    @latest_run_detail = fetch_run_detail(@latest_run&.run_id)
    selected_detail = fetch_run_detail(params[:run_id]) if params[:run_id].present?
    @selected_run_detail = selected_detail if selected_detail&.fetch("workflow_name", nil) == @workflow_name
    @selected_run_unavailable = params[:run_id].present? && @selected_run_detail.nil?
    @maintenance_run_detail = @selected_run_detail || @latest_run_detail
    @display_run_detail = @maintenance_run_detail
    @maintenance_findings =
      if @workflow_name == GithubDependencyMaintenanceFinding::WORKFLOW_NAME
        GithubDependencyMaintenanceFinding.for_run(@maintenance_run_detail)
      else
        []
      end
    @maintenance_diagnostics =
      if @workflow_name == GithubDependencyMaintenanceFinding::WORKFLOW_NAME
        GithubDependencyMaintenanceFinding.diagnostics_for_run(@maintenance_run_detail)
      else
        []
      end
    @maintenance_action_lookup_failures = []
    @maintenance_action_runs = action_runs_for(@maintenance_findings)

    return if @selected_run_detail.present?
    return if @latest_run_detail.blank? && @workflow_schedules.blank?
    return if @latest_run&.display_status == "failed"
    return unless @status_counts["failed"].to_i.positive?

    failed_run = CentaurWorkflowRun.for_workflow(@workflow_name, limit: 1, status: "failed").first
    @latest_failure_detail = fetch_run_detail(failed_run&.run_id)
  end

  def workflow_schedules_for(workflow_name)
    response = api_client.list_workflow_schedules
    Array(response["schedules"]).select do |schedule|
      schedule.is_a?(Hash) && schedule["workflow_name"] == workflow_name
    end
  rescue StandardError => e
    Rails.logger.warn("console_workflow_schedules_failed error=#{e.class}: #{e.message}")
    []
  end

  def fetch_run_detail(run_id)
    return nil if run_id.blank?

    response = api_client.get_workflow_run(run_id)
    detail = response["run"]
    detail.is_a?(Hash) ? detail : nil
  rescue StandardError => e
    Rails.logger.warn("console_workflow_run_detail_failed run=#{run_id} error=#{e.class}: #{e.message}")
    nil
  end

  # A page render must not queue an action. The action's durable idempotency
  # key makes this lookup exact even after the action has left recent history.
  def action_runs_for(findings)
    findings.each_with_object({}) do |finding, action_runs|
      action_run = action_run_for(finding)
      next unless action_run.is_a?(Hash) && action_run["run_id"].present?

      action_runs[finding.idempotency_key] = action_run
    rescue StandardError => e
      @maintenance_action_lookup_failures << finding.idempotency_key
      Rails.logger.warn(
        "console_workflow_finding_action_lookup_failed key=#{finding.idempotency_key} " \
        "error=#{e.class}: #{e.message}"
      )
    end
  end

  def action_run_for(finding)
    action_run = api_client.find_workflow_run_by_idempotency_key(
      workflow_name: GithubDependencyMaintenanceFinding::ACTION_WORKFLOW_NAME,
      idempotency_key: finding.idempotency_key
    )
    return action_run if action_run.is_a?(Hash) && action_run["run_id"].present?

    # Old keys omitted the repository/action. Preserve already-authorized work,
    # but only after checking its immutable input belongs to this exact card.
    legacy = api_client.find_workflow_run_by_idempotency_key(
      workflow_name: GithubDependencyMaintenanceFinding::ACTION_WORKFLOW_NAME,
      idempotency_key: finding.legacy_idempotency_key
    )
    return unless legacy.is_a?(Hash) && legacy["run_id"].present?

    detail = api_client.get_workflow_run(legacy.fetch("run_id")).fetch("run")
    detail if detail["workflow_name"] == GithubDependencyMaintenanceFinding::ACTION_WORKFLOW_NAME &&
      finding.matches_action_input?(detail["input"])
  end

  def api_client
    @api_client ||= self.class.client_factory.call
  end

  def page_param
    page = Integer(params[:page].to_s, 10, exception: false) || 1
    page < 1 ? 1 : page
  end
end

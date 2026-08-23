class Console::AutomationPoliciesController < ApplicationController
  layout "console"
  before_action :require_admin
  before_action :set_policy, only: %i[edit update destroy]
  before_action :reject_source_managed_policy_mutation, only: %i[edit update destroy]
  before_action :load_execution_roles, only: %i[new create edit update]

  def index
    @policies = AutomationPolicy.includes(:created_by, :execution_role).order(:provider, :repository, :linear_team_id, :id)
    @workstream_query = params[:q].to_s.strip
    workstreams = AutomationWorkstream.matching_operator_query(@workstream_query)
    execution_session_keys = matching_execution_session_keys(@workstream_query)
    workstreams = workstreams.or(AutomationWorkstream.where(session_key: execution_session_keys)) if execution_session_keys.any?

    @workstreams = workstreams.includes(:automation_policy, :principal, :authorization_role)
      .joins(<<~SQL.squish)
        LEFT JOIN LATERAL (
          SELECT decision, action_kind, metadata -> 'result' ->> 'reason' AS reason
          FROM automation_events
          WHERE automation_events.automation_workstream_id = automation_workstreams.id
          ORDER BY received_at DESC, id DESC
          LIMIT 1
        ) latest_automation_event ON TRUE
      SQL
      .select(
        "automation_workstreams.*, " \
        "latest_automation_event.decision AS latest_automation_decision, " \
        "latest_automation_event.action_kind AS latest_automation_action_kind, " \
        "latest_automation_event.reason AS latest_automation_reason"
      )
      .order(last_event_at: :desc, id: :desc)
      .limit(30)
    @latest_executions = latest_executions_for(@workstreams.map(&:session_key))
  end

  def new
    @policy = AutomationPolicy.new(
      provider: params[:provider].presence_in(AutomationPolicy::PROVIDERS) || "github",
      enabled: true,
      mode: "observe"
    )
  end

  def create
    @policy = current_user.created_automation_policies.new(policy_attributes)
    if @policy.save
      redirect_to console_automation_policies_path, notice: "Automation policy created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @policy.update(policy_attributes)
      redirect_to console_automation_policies_path, notice: "Automation policy saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @policy.destroy!
    redirect_to console_automation_policies_path, notice: "Automation policy deleted."
  end

  private

  def set_policy
    @policy = AutomationPolicy.find_by_oid!(params[:id])
  end

  def policy_attributes
    values = policy_params
    provider = values.fetch(:provider)
    common = values.slice(:name, :provider, :repository, :linear_team_id, :linear_project_id,
                          :execution_role_id, :enabled, :mode)
    common[:settings] =
      if provider == "github"
        {
          "github" => {
            "review" => values[:github_review_mode],
            "feedback" => values[:github_feedback_mode],
            "checks" => values[:github_checks_mode],
            "conflicts" => values[:github_conflicts_mode],
            "auto_merge" => boolean_value(values[:github_auto_merge]),
            "base_branches" => comma_list(values[:github_base_branches]),
            "required_labels" => comma_list(values[:github_required_labels]),
            "excluded_labels" => comma_list(values[:github_excluded_labels])
          }
        }
      else
        repository_routes = linear_repository_routes(values[:linear_repository_routes])
        github_repository = repository_routes.any? ? "" : values[:linear_github_repository].to_s.strip
        {
          "linear" => {
            "issue" => values[:linear_issue_mode],
            "ready_statuses" => comma_list(values[:linear_ready_statuses]),
            "required_fields" => comma_list(values[:linear_required_fields]),
            "required_labels" => comma_list(values[:linear_required_labels]),
            "excluded_labels" => comma_list(values[:linear_excluded_labels]),
            "github_repository" => github_repository,
            "repository_routes" => repository_routes,
            "reviewer_logins" => comma_list(values[:linear_reviewer_logins]),
            "reviewer_team_slugs" => comma_list(values[:linear_reviewer_team_slugs]),
            "move_to_in_progress" => boolean_value(values[:linear_move_to_in_progress])
          }
        }
      end
    common
  end

  def policy_params
    params.require(:automation_policy).permit(
      :name,
      :provider,
      :repository,
      :linear_team_id,
      :linear_project_id,
      :execution_role_id,
      :enabled,
      :mode,
      :github_review_mode,
      :github_feedback_mode,
      :github_checks_mode,
      :github_conflicts_mode,
      :github_auto_merge,
      :github_base_branches,
      :github_required_labels,
      :github_excluded_labels,
      :linear_issue_mode,
      :linear_ready_statuses,
      :linear_required_fields,
      :linear_required_labels,
      :linear_excluded_labels,
      :linear_github_repository,
      :linear_reviewer_logins,
      :linear_reviewer_team_slugs,
      :linear_move_to_in_progress,
      linear_repository_routes: %i[
        repository
        required_labels
        reviewer_logins
        reviewer_team_slugs
        preview_label
      ]
    )
  end

  def comma_list(value)
    value.to_s.split(",").filter_map { |item| item.strip.presence }.uniq
  end

  def linear_repository_routes(value)
    routes =
      if value.is_a?(Array)
        value
      elsif value.respond_to?(:to_h)
        value.to_h.values
      else
        []
      end
    routes.filter_map do |route|
      next unless route.respond_to?(:[])

      route = route.to_h.with_indifferent_access
      repository = route[:repository].to_s.strip
      labels = comma_list(route[:required_labels])
      reviewer_logins = comma_list(route[:reviewer_logins])
      reviewer_team_slugs = comma_list(route[:reviewer_team_slugs])
      preview_label = route[:preview_label].to_s.strip
      blank_route = repository.blank? && labels.empty? && reviewer_logins.empty? &&
        reviewer_team_slugs.empty? && preview_label.blank?
      next if blank_route

      {
        "repository" => repository,
        "required_labels" => labels,
        "reviewer_logins" => reviewer_logins.presence,
        "reviewer_team_slugs" => reviewer_team_slugs.presence,
        "preview_label" => preview_label.presence
      }.compact
    end
  end

  def boolean_value(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def load_execution_roles
    @automation_roles = Role.automation_execution_roles.order(:name, :id)
  end

  def reject_source_managed_policy_mutation
    return unless @policy.source_managed?

    redirect_to console_automation_policies_path,
                alert: "This policy is managed in #{@policy.managed_source_label}. Update its reviewed source and deploy."
  end

  # Execution records belong to Centaur's durable session API, not the
  # Console's policy database. Search their stable IDs only to locate the
  # corresponding policy workstream; raw session metadata stays in the thread
  # observer.
  def matching_execution_session_keys(query)
    return [] if query.blank?

    pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
    CentaurSessionExecution
      .where("execution_id ILIKE ?", pattern)
      .limit(100)
      .pluck(:thread_key)
  rescue ActiveRecord::ActiveRecordError, PG::Error => e
    Rails.logger.debug("console_automation_execution_search_failed error=#{e.class}: #{e.message}")
    []
  end

  # Execution records belong to Centaur's durable session API. This is a
  # read-only summary for the policy list; the thread observer remains the
  # detailed execution view.
  def latest_executions_for(keys)
    return {} if keys.empty?

    CentaurSessionExecution
      .where(thread_key: keys)
      .select("distinct on (thread_key) session_executions.*")
      .order(Arel.sql("thread_key, created_at desc, execution_id desc"))
      .index_by(&:thread_key)
  rescue ActiveRecord::ActiveRecordError, PG::Error => e
    Rails.logger.debug("console_automation_execution_index_load_failed error=#{e.class}: #{e.message}")
    {}
  end
end

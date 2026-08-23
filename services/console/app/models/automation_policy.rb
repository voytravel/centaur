class AutomationPolicy < ApplicationRecord
  oid_prefix "aut"

  PROVIDERS = %w[github linear].freeze
  MODES = %w[observe act].freeze
  GITHUB_REVIEW_MODES = %w[off assigned_or_mentioned all_eligible].freeze
  GITHUB_REPAIR_MODES = %w[off observe bot_owned explicit eligible].freeze
  LINEAR_ISSUE_MODES = %w[off ready_issues].freeze

  GITHUB_REVIEW_ACTIONS = %w[opened reopened ready_for_review synchronize].freeze
  GITHUB_CONFLICT_ACTIONS = %w[synchronize edited ready_for_review].freeze
  GITHUB_MERGE_ACTIONS = %w[opened reopened synchronize edited ready_for_review].freeze
  CHECK_EVENT_TYPES = %w[check_run check_suite status workflow_run].freeze

  belongs_to :created_by, class_name: "User"
  belongs_to :execution_role, class_name: "Role", optional: true
  has_many :automation_workstreams, dependent: :nullify

  normalizes :name, :provider, with: ->(value) { value.to_s.strip }
  normalizes :linear_team_id, :linear_project_id,
             with: ->(value) { value.to_s.strip.presence }
  normalizes :repository, with: ->(value) { value.to_s.strip.downcase }

  before_validation :normalize_settings

  validates :name, presence: true, length: { maximum: 120 }
  validates :provider, inclusion: { in: PROVIDERS }
  validates :mode, inclusion: { in: MODES }
  validates :execution_role, presence: true, if: :act?
  validates :repository, format: {
    with: %r{\A[^/\s]+/[^/\s]+\z},
    message: "must be an owner/repository name"
  }, allow_blank: true
  validates :repository, presence: true, if: :github?
  validates :linear_team_id, presence: true, if: :linear?
  validates :repository, uniqueness: { scope: :provider }, if: :github?
  validate :linear_scope_is_unique
  validate :execution_role_is_safe_for_automation
  validate :settings_are_valid

  after_update_commit :reconcile_workstream_authorizations,
                      if: :authorization_changed?
  before_destroy :revoke_workstream_authorizations

  def github?
    provider == "github"
  end

  def linear?
    provider == "linear"
  end

  def act?
    mode == "act"
  end

  def github_settings
    github_defaults.merge(settings.fetch("github", {}).slice(*github_defaults.keys))
  end

  def linear_settings
    linear_defaults.merge(settings.fetch("linear", {}).slice(*linear_defaults.keys))
  end

  def scope_label
    return repository if github?

    [ linear_team_id.presence || "all teams", linear_project_id.presence ].compact.join(" / ")
  end

  def automation_summary
    if github?
      config = github_settings
      "review: #{config["review"].tr("_", " ")} · feedback: #{config["feedback"].tr("_", " ")} · checks: #{config["checks"].tr("_", " ")}"
    else
      config = linear_settings
      "issues: #{config["issue"].tr("_", " ")} · repo: #{config["github_repository"].presence || "not mapped"}"
    end
  end

  # Evaluates a normalized, metadata-only ingress event. This intentionally
  # contains no model call: event routing and safety gates are deterministic;
  # agents decide how to implement only after a policy has authorized a turn.
  def evaluate(event)
    payload = event.deep_stringify_keys
    return ignored("policy is disabled") unless enabled?

    case provider
    when "github" then evaluate_github(payload)
    when "linear" then evaluate_linear(payload)
    else ignored("unsupported provider")
    end
  end

  def self.for_github(repository)
    where(provider: "github", repository: repository.to_s.strip.downcase).order(:id).first
  end

  def self.for_linear(team_id:, project_id:)
    scope = where(provider: "linear", linear_team_id: team_id.to_s.strip)
    exact = scope.where(linear_project_id: project_id.to_s.strip).order(:id).first if project_id.present?
    exact || scope.where(linear_project_id: [ nil, "" ]).order(:id).first
  end

  private

  def github_defaults
    {
      "review" => "assigned_or_mentioned",
      "feedback" => "bot_owned",
      "checks" => "observe",
      "conflicts" => "observe",
      "auto_merge" => false,
      "base_branches" => [],
      "required_labels" => [],
      "excluded_labels" => []
    }
  end

  def linear_defaults
    {
      "issue" => "off",
      "ready_statuses" => [],
      "required_fields" => [ "description" ],
      "excluded_labels" => [ "no-agent" ],
      "github_repository" => "",
      "reviewer_logins" => [],
      "reviewer_team_slugs" => [],
      "move_to_in_progress" => true
    }
  end

  def normalize_settings
    self.settings = {} unless settings.is_a?(Hash)
    self.settings = settings.deep_stringify_keys
    self.settings["github"] = normalize_config(settings["github"]) if github?
    self.settings["linear"] = normalize_config(settings["linear"]) if linear?
  end

  def normalize_config(config)
    return {} unless config.is_a?(Hash)

    config.deep_stringify_keys.transform_values do |value|
      case value
      when Array
        value.filter_map { |item| item.to_s.strip.presence }.uniq
      when String
        value.strip
      else
        value
      end
    end
  end

  def linear_scope_is_unique
    return unless linear? && linear_team_id.present?

    relation = self.class.where(
      provider: "linear",
      linear_team_id: linear_team_id,
      linear_project_id: linear_project_id.presence
    )
    relation = relation.where.not(id: id) if persisted?
    errors.add(:linear_project_id, "already has a policy in this team") if relation.exists?
  end

  def execution_role_is_safe_for_automation
    return unless act? && execution_role
    return if execution_role.automation_execution_role?

    errors.add(:execution_role, "is not approved for autonomous repository automation")
  end

  def settings_are_valid
    if github?
      config = github_settings
      errors.add(:settings, "has an invalid review mode") unless GITHUB_REVIEW_MODES.include?(config["review"])
      %w[feedback checks conflicts].each do |key|
        errors.add(:settings, "has an invalid #{key} mode") unless GITHUB_REPAIR_MODES.include?(config[key])
      end
    elsif linear?
      config = linear_settings
      errors.add(:settings, "has an invalid issue mode") unless LINEAR_ISSUE_MODES.include?(config["issue"])
      repository = config["github_repository"].to_s
      if config["issue"] == "ready_issues" && !repository.match?(%r{\A[^/\s]+/[^/\s]+\z})
        errors.add(:settings, "needs a GitHub repository for ready issue automation")
      end
    end
  end

  def evaluate_github(event)
    return ignored("event is outside this repository") unless event["repository"] == repository

    allowed, reason = github_eligible?(event)
    return ignored(reason) unless allowed

    actions = case event["event_type"]
    when "pull_request"
      actions = []
      actions << "review" if github_settings["review"] == "all_eligible" &&
                             GITHUB_REVIEW_ACTIONS.include?(event["event_action"])
      actions << "resolve_conflict" if github_settings["conflicts"] == "eligible" &&
                                       GITHUB_CONFLICT_ACTIONS.include?(event["event_action"])
      actions << "evaluate_merge" if github_settings["auto_merge"] == true &&
                                      GITHUB_MERGE_ACTIONS.include?(event["event_action"])
      actions
    when "pull_request_review"
      if event["event_action"] == "submitted"
        actions = []
        actions << "address_feedback" if github_settings["feedback"] == "eligible"
        actions << "evaluate_merge" if github_settings["auto_merge"] == true
        actions
      else
        []
      end
    when *CHECK_EVENT_TYPES
      actions = []
      actions << "fix_checks" if github_settings["checks"] == "eligible"
      actions << "evaluate_merge" if github_settings["auto_merge"] == true
      actions
    else
      []
    end

    return ignored("no automatic action is enabled for this event") if actions.empty?

    routed(actions)
  end

  def evaluate_linear(event)
    return ignored("event is outside this Linear team") unless event["linear_team_id"] == linear_team_id
    return ignored("event is outside this Linear project") if linear_project_id.present? &&
                                                              event["linear_project_id"] != linear_project_id
    return ignored("not an issue create or update") unless event["event_type"] == "Issue" &&
                                                           %w[create update].include?(event["event_action"])

    config = linear_settings
    return ignored("ready issue automation is disabled") unless config["issue"] == "ready_issues"

    ready, reason = linear_issue_ready?(event, config)
    return ignored(reason) unless ready

    routed([ "implement_issue" ])
  end

  def github_eligible?(event)
    return [ false, "draft pull requests are excluded" ] if event["draft"] == true

    config = github_settings
    base_branches = Array(config["base_branches"]).map(&:downcase)
    base_branch = event["base_branch"].to_s.downcase
    if base_branches.any? && !base_branches.any? { |pattern| File.fnmatch?(pattern, base_branch) }
      return [ false, "base branch is not allowed" ]
    end

    labels = Array(event["labels"]).map { |label| label.to_s.downcase }
    required = Array(config["required_labels"]).map(&:downcase)
    excluded = Array(config["excluded_labels"]).map(&:downcase)
    return [ false, "required label is missing" ] unless (required - labels).empty?
    return [ false, "an excluded label is present" ] if (excluded & labels).any?

    [ true, nil ]
  end

  def linear_issue_ready?(event, config)
    return [ false, "issue is blocked" ] if event["blocked"] == true
    return [ false, "issue title is missing" ] if event["title"].to_s.strip.empty?

    description = event["description"].to_s
    Array(config["required_fields"]).each do |field|
      case field
      when "description"
        return [ false, "issue description is missing" ] if description.strip.empty?
      when "acceptance_criteria"
        return [ false, "acceptance criteria are missing" ] unless description.match?(/acceptance\s+criteria/i)
      end
    end

    ready_statuses = Array(config["ready_statuses"]).map(&:downcase)
    if ready_statuses.any? && !ready_statuses.include?(event["status"].to_s.downcase)
      return [ false, "issue status is not ready" ]
    end

    labels = Array(event["labels"]).map { |label| label.to_s.downcase }
    excluded = Array(config["excluded_labels"]).map(&:downcase)
    return [ false, "an excluded label is present" ] if (excluded & labels).any?

    [ true, nil ]
  end

  def routed(actions)
    linear = linear? ? linear_settings : {}
    {
      "decision" => mode == "act" ? "act" : "observe",
      "reason" => mode == "act" ? "policy authorizes automation" : "policy is in observe mode",
      "actions" => actions,
      "auto_merge" => github? && github_settings["auto_merge"] == true,
      "github_repository" => linear["github_repository"],
      "move_to_in_progress" => linear["move_to_in_progress"] != false,
      "reviewer_logins" => Array(linear["reviewer_logins"]),
      "reviewer_team_slugs" => Array(linear["reviewer_team_slugs"])
    }
  end

  def ignored(reason)
    { "decision" => "ignored", "reason" => reason, "actions" => [] }
  end

  def authorization_changed?
    saved_change_to_enabled? || saved_change_to_mode? || saved_change_to_execution_role_id?
  end

  def reconcile_workstream_authorizations
    AutomationPrincipalAuthorizer.reconcile_policy(self)
  end

  def revoke_workstream_authorizations
    AutomationPrincipalAuthorizer.revoke_policy(self)
  end
end

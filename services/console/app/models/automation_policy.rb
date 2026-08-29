class AutomationPolicy < ApplicationRecord
  oid_prefix "aut"

  PROVIDERS = %w[github linear].freeze
  MODES = %w[observe act].freeze
  GITHUB_REVIEW_MODES = %w[off assigned_or_mentioned all_eligible].freeze
  GITHUB_REPAIR_MODES = %w[off observe bot_owned explicit eligible].freeze
  GITHUB_REVIEW_ORCHESTRATION_MODES = %w[single cross_model].freeze
  GITHUB_REVIEW_HARNESSES = %w[codex claudecode].freeze
  GITHUB_REVIEW_REASONING = %w[none minimal low medium high xhigh max].freeze
  GITHUB_REVIEW_FOCUS = %w[
    correctness dependencies integration maintainability security tests
  ].freeze
  LINEAR_ISSUE_MODES = %w[off ready_issues].freeze
  LINEAR_QA_MODES = %w[off status_transition].freeze
  ACTIVITY_REPORT_KINDS = %w[accepted pr_created].freeze
  LINEAR_REPOSITORY_ROUTE_KEYS = %w[
    repository
    required_labels
    reviewer_logins
    reviewer_team_slugs
    preview_label
  ].freeze
  MANAGED_SOURCE_KEY = "_centaur_managed_source".freeze
  MANAGED_SOURCE_FIELDS = %w[kind repository path revision content_sha256].freeze
  GITHUB_REPOSITORY_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*\z/.freeze
  SLACK_CHANNEL_ID_PATTERN = /\A[CG][A-Z0-9]{8,}\z/.freeze
  QA_ID_PATTERN = /\A[a-z][a-z0-9_-]{0,63}\z/.freeze
  GITHUB_REVIEW_PROFILE_ID_PATTERN = /\A[a-z][a-z0-9_-]{0,31}\z/.freeze
  GITHUB_REVIEW_MODEL_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._\/-]{0,127}\z/.freeze

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
  validates :execution_role, presence: true, if: :requires_execution_role?
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
  validate :managed_source_is_valid

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

  # GitHub and Linear coding actions create agent sandboxes and therefore need
  # a policy-owned execution role. A QA-only Linear policy starts an isolated
  # workflow principal instead; granting the issue principal a coding role
  # would be unnecessary ambient authority.
  def requires_execution_role?
    return false unless act?
    return true if github?

    linear_settings["issue"] == "ready_issues"
  end

  def github_settings
    github_defaults.merge(settings.fetch("github", {}).slice(*github_defaults.keys))
  end

  def linear_settings
    linear_defaults.merge(settings.fetch("linear", {}).slice(*linear_defaults.keys))
  end

  # Reporting is deliberately a small, provider-independent policy surface:
  # a configured channel receives one redacted notification for selected
  # policy-owned lifecycle milestones. It never receives provider payloads,
  # agent output, credentials, or a notification for every continuation.
  def activity_reporting_settings
    config = settings["activity_reporting"]
    config = {} unless config.is_a?(Hash)
    activity_reporting_defaults.merge(
      config.slice(*activity_reporting_defaults.keys)
    )
  end

  def reports_activity?(kind)
    return false unless ACTIVITY_REPORT_KINDS.include?(kind.to_s)

    config = activity_reporting_settings
    config["slack_channel"].present? && config[kind.to_s] == true
  end

  def scope_label
    return repository if github?

    [ linear_team_id.presence || "all teams", linear_project_id.presence ].compact.join(" / ")
  end

  def automation_summary
    if github?
      config = github_settings
      manual_mentions = config["manual_mentions"] ? " · manual mentions: enabled" : ""
      review_group = config.dig("review_orchestration", "mode") == "cross_model" ?
        " · review group: cross model" : ""
      "review: #{config["review"].tr("_", " ")} · feedback: #{config["feedback"].tr("_", " ")} · checks: #{config["checks"].tr("_", " ")}#{review_group}#{manual_mentions}#{activity_reporting_summary}"
    else
      config = linear_settings
      required_labels = Array(config["required_labels"])
      label_summary = required_labels.any? ? required_labels.join(", ") : "none"
      manual_mentions = config["manual_mentions"] ? " · manual mentions: enabled" : ""
      qa_summary = config["qa"] == "status_transition" ? " · QA: #{Array(config["qa_statuses"]).join(", ")}" : ""
      "issues: #{config["issue"].tr("_", " ")}#{qa_summary} · repo: #{linear_repository_summary(config)} · required labels: #{label_summary}#{manual_mentions}#{activity_reporting_summary}"
    end
  end

  # Deployment reconciliation stamps source-managed policies with a compact,
  # non-secret provenance record. The source is intentionally separate from the
  # provider settings so it cannot influence policy evaluation.
  def source_managed?
    managed_source.present?
  end

  def managed_source
    source = normalized_managed_source
    return unless managed_source_valid?(source)

    source.slice(*MANAGED_SOURCE_FIELDS)
  end

  def managed_source_label
    source = managed_source
    return unless source

    "#{source.fetch("repository")}:#{source.fetch("path")}@#{source.fetch("revision").first(12)}"
  end

  # Source-managed policies are reconciled from a reviewed GitHub repository.
  # Only build an external href when each dynamic segment fits the narrow source
  # metadata contract, rather than treating the stored provenance label as a
  # general URL.
  def safe_managed_source_url
    source = managed_source
    return unless source

    repository = source.fetch("repository")
    return unless GITHUB_REPOSITORY_PATTERN.match?(repository)

    "https://github.com/#{repository}/blob/#{source.fetch("revision")}/#{source.fetch("path")}"
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
      "manual_mentions" => false,
      "auto_merge" => false,
      "base_branches" => [],
      "required_labels" => [],
      "excluded_labels" => [],
      # Kept opt-in: existing policies preserve their established single-review
      # behavior until a reviewed source policy explicitly chooses a group.
      "review_orchestration" => { "mode" => "single" }
    }
  end

  def linear_defaults
    {
      "issue" => "off",
      "qa" => "off",
      "qa_target" => "auto",
      "qa_statuses" => [],
      "qa_profiles" => [],
      "ready_statuses" => [],
      "required_fields" => [ "description" ],
      "required_labels" => [],
      "excluded_labels" => [ "no-agent" ],
      "github_repository" => "",
      "repository_routes" => [],
      "reviewer_logins" => [],
      "reviewer_team_slugs" => [],
      "manual_mentions" => false,
      "move_to_in_progress" => true
    }
  end

  def activity_reporting_defaults
    {
      "slack_channel" => "",
      "accepted" => false,
      "pr_created" => false
    }
  end

  def normalize_settings
    self.settings = {} unless settings.is_a?(Hash)
    self.settings = settings.deep_stringify_keys
    if settings.key?("activity_reporting")
      self.settings["activity_reporting"] = normalize_activity_reporting_config(settings["activity_reporting"])
    end
    self.settings["github"] = normalize_config(settings["github"]) if github?
    self.settings["linear"] = normalize_linear_config(settings["linear"]) if linear?
  end

  def normalize_activity_reporting_config(config)
    return config unless config.is_a?(Hash)

    normalized = normalize_config(config)
    if normalized["slack_channel"].is_a?(String)
      normalized["slack_channel"] = normalized["slack_channel"].upcase
    end
    ACTIVITY_REPORT_KINDS.each do |kind|
      next unless normalized.key?(kind)

      normalized[kind] = ActiveModel::Type::Boolean.new.cast(normalized[kind])
    end
    normalized
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

  def normalize_linear_config(config)
    normalized = normalize_config(config)
    return normalized unless config.is_a?(Hash) && config.key?("repository_routes")

    normalized["repository_routes"] = Array(config["repository_routes"]).map do |route|
      next route unless route.is_a?(Hash)

      route.deep_stringify_keys.transform_values do |value|
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
    normalized
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
      errors.add(:settings, "manual mentions must be true or false") unless boolean?(config["manual_mentions"])
      validate_github_review_orchestration(config)
    elsif linear?
      config = linear_settings
      errors.add(:settings, "has an invalid issue mode") unless LINEAR_ISSUE_MODES.include?(config["issue"])
      errors.add(:settings, "has an invalid QA mode") unless LINEAR_QA_MODES.include?(config["qa"])
      errors.add(:settings, "manual mentions must be true or false") unless boolean?(config["manual_mentions"])
      if config["qa"] == "status_transition" && Array(config["qa_statuses"]).empty?
        errors.add(:settings, "needs at least one QA status when QA automation is enabled")
      end
      qa_statuses = config["qa_statuses"]
      unless qa_statuses.is_a?(Array) && qa_statuses.length <= 20 &&
          qa_statuses.all? { |status| status.is_a?(String) && status.present? && status.length <= 100 }
        errors.add(:settings, "has invalid QA statuses")
      end
      qa_profiles = config["qa_profiles"]
      unless qa_profiles.is_a?(Array) && qa_profiles.length <= 20 &&
          qa_profiles.all? { |profile| profile.is_a?(String) && QA_ID_PATTERN.match?(profile) }
        errors.add(:settings, "has invalid QA profiles")
      end
      if config["qa"] == "status_transition" && !QA_ID_PATTERN.match?(config["qa_target"].to_s)
        errors.add(:settings, "has an invalid QA target")
      end
      validate_linear_repository_routes(config)
    end
    validate_activity_reporting
  end

  # Cross-model review is a compact source-managed policy surface, not arbitrary
  # prompt/configuration JSON. The Githubbot validates it again at execution
  # ingress; keeping the two independently bounded protects both stale workers
  # and direct API callers.
  def validate_github_review_orchestration(config)
    raw = config["review_orchestration"]
    unless raw.is_a?(Hash)
      errors.add(:settings, "review orchestration must be an object")
      return
    end

    orchestration = raw.deep_stringify_keys
    unsupported = orchestration.keys - %w[mode reviewers synthesizer max_concurrency]
    errors.add(:settings, "review orchestration has unsupported fields") if unsupported.any?
    mode = orchestration["mode"]
    unless GITHUB_REVIEW_ORCHESTRATION_MODES.include?(mode)
      errors.add(:settings, "has an invalid review orchestration mode")
      return
    end
    return if mode == "single"

    reviewers = orchestration["reviewers"]
    synthesizer = orchestration["synthesizer"]
    max_concurrency = orchestration["max_concurrency"]
    unless reviewers.is_a?(Array) && reviewers.length.between?(2, 3)
      errors.add(:settings, "cross-model review needs two or three reviewers")
      return
    end
    unless max_concurrency.is_a?(Integer) && max_concurrency.between?(1, 3)
      errors.add(:settings, "cross-model review needs max concurrency from 1 to 3")
    end

    profiles = reviewers.each_with_index.filter_map do |profile, index|
      validate_github_review_profile(profile, "reviewer #{index + 1}")
    end
    synthesis = validate_github_review_profile(synthesizer, "synthesizer")
    return unless profiles.length == reviewers.length && synthesis

    ids = profiles.map { |profile| profile.fetch("id") }
    errors.add(:settings, "cross-model reviewer IDs must be unique") if ids.uniq.length != ids.length
    primary_pairs = profiles.map { |profile| [ profile.fetch("harness"), profile.fetch("model") ] }
    if primary_pairs.uniq.length < 2
      errors.add(:settings, "cross-model review needs at least two distinct primary models")
    end
  end

  def validate_github_review_profile(value, label)
    unless value.is_a?(Hash)
      errors.add(:settings, "cross-model #{label} must be an object")
      return nil
    end
    profile = value.deep_stringify_keys
    unsupported = profile.keys - %w[id harness model reasoning focus max_runs_per_epoch fallbacks]
    valid = unsupported.empty?
    errors.add(:settings, "cross-model #{label} has unsupported fields") unless valid

    id = profile["id"]
    harness = profile["harness"]
    model = profile["model"]
    reasoning = profile["reasoning"]
    focus = profile["focus"]
    max_runs = profile["max_runs_per_epoch"]
    fallbacks = profile["fallbacks"]
    unless id.is_a?(String) && GITHUB_REVIEW_PROFILE_ID_PATTERN.match?(id)
      errors.add(:settings, "cross-model #{label} has an invalid ID")
      valid = false
    end
    unless GITHUB_REVIEW_HARNESSES.include?(harness)
      errors.add(:settings, "cross-model #{label} has an invalid harness")
      valid = false
    end
    unless model.is_a?(String) && GITHUB_REVIEW_MODEL_PATTERN.match?(model)
      errors.add(:settings, "cross-model #{label} has an invalid model")
      valid = false
    end
    unless reasoning.nil? || (harness == "codex" && GITHUB_REVIEW_REASONING.include?(reasoning))
      errors.add(:settings, "cross-model #{label} has invalid reasoning")
      valid = false
    end
    unless focus.is_a?(Array) && focus.all? { |item| GITHUB_REVIEW_FOCUS.include?(item) }
      errors.add(:settings, "cross-model #{label} has invalid focus")
      valid = false
    end
    unless max_runs.is_a?(Integer) && max_runs.between?(1, 3)
      errors.add(:settings, "cross-model #{label} has invalid per-epoch budget")
      valid = false
    end
    unless fallbacks.is_a?(Array) && fallbacks.length <= 2
      errors.add(:settings, "cross-model #{label} has invalid fallbacks")
      return nil
    end

    attempts = [ { "harness" => harness, "model" => model }, *fallbacks ]
    valid_fallbacks = fallbacks.all? do |fallback|
      next false unless fallback.is_a?(Hash)

      candidate = fallback.deep_stringify_keys
      fallback_harness = candidate["harness"]
      fallback_model = candidate["model"]
      fallback_reasoning = candidate["reasoning"]
      (candidate.keys - %w[harness model reasoning]).empty? &&
        GITHUB_REVIEW_HARNESSES.include?(fallback_harness) &&
        fallback_model.is_a?(String) &&
        GITHUB_REVIEW_MODEL_PATTERN.match?(fallback_model) &&
        (fallback_reasoning.nil? ||
          (fallback_harness == "codex" && GITHUB_REVIEW_REASONING.include?(fallback_reasoning)))
    end
    unless valid_fallbacks
      errors.add(:settings, "cross-model #{label} has an invalid fallback")
      valid = false
    end
    normalized_attempts = attempts.filter_map do |attempt|
      harness_value = attempt["harness"] || attempt[:harness]
      model_value = attempt["model"] || attempt[:model]
      [ harness_value, model_value ] if harness_value.is_a?(String) && model_value.is_a?(String)
    end
    if normalized_attempts.uniq.length != normalized_attempts.length
      errors.add(:settings, "cross-model #{label} repeats a model attempt")
      valid = false
    end
    valid ? profile : nil
  end

  def validate_activity_reporting
    raw_config = settings["activity_reporting"]
    return if raw_config.nil?

    unless raw_config.is_a?(Hash)
      errors.add(:settings, "activity reporting must be an object")
      return
    end

    config = raw_config.deep_stringify_keys
    unsupported = config.keys - activity_reporting_defaults.keys
    errors.add(:settings, "activity reporting has unsupported fields") if unsupported.any?

    channel = config["slack_channel"]
    unless channel.nil? || (channel.is_a?(String) && (channel.blank? || SLACK_CHANNEL_ID_PATTERN.match?(channel)))
      errors.add(:settings, "activity reporting has an invalid Slack channel")
    end

    enabled_kinds = []
    ACTIVITY_REPORT_KINDS.each do |kind|
      enabled = config[kind]
      unless enabled.nil? || enabled == true || enabled == false
        errors.add(:settings, "activity reporting #{kind.tr('_', ' ')} must be true or false")
      end
      enabled_kinds << kind if enabled == true
    end
    if enabled_kinds.any? && channel.to_s.blank?
      errors.add(:settings, "activity reporting needs a Slack channel when reporting is enabled")
    end
  end

  def managed_source_is_valid
    return unless settings.key?(MANAGED_SOURCE_KEY)

    source = normalized_managed_source
    return if managed_source_valid?(source)

    errors.add(:settings, "has invalid managed source metadata")
  end

  def normalized_managed_source
    source = settings[MANAGED_SOURCE_KEY]
    source.deep_stringify_keys if source.is_a?(Hash)
  end

  def managed_source_valid?(source)
    path = source["path"].to_s if source.is_a?(Hash)
    source.is_a?(Hash) &&
      source.keys.sort == MANAGED_SOURCE_FIELDS.sort &&
      source["kind"] == "git" &&
      source["repository"].to_s.match?(%r{\A[^/\s]+/[^/\s]+\z}) &&
      path.match?(%r{\A[A-Za-z0-9][A-Za-z0-9._/-]*\z}) &&
      !path.split("/").include?("..") &&
      source["revision"].to_s.match?(/\A[0-9a-f]{40}\z/) &&
      source["content_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
  end

  def evaluate_github(event)
    return ignored("event is outside this repository") unless event["repository"] == repository

    allowed, reason = github_eligible?(event)
    return ignored(reason) unless allowed

    actions = case event["event_type"]
    when "pull_request"
      actions = []
      actions << "respond_to_mention" if github_manual_mention_enabled?(event)
      actions << "review" if github_review_enabled?(event)
      actions << "resolve_conflict" if github_repair_enabled?("conflicts", event) &&
                                       GITHUB_CONFLICT_ACTIONS.include?(event["event_action"])
      actions << "evaluate_merge" if github_settings["auto_merge"] == true &&
                                      GITHUB_MERGE_ACTIONS.include?(event["event_action"])
      actions
    when "pull_request_review"
      if event["event_action"] == "submitted"
        actions = []
        actions << "address_feedback" if github_repair_enabled?("feedback", event)
        actions << "evaluate_merge" if github_settings["auto_merge"] == true
        actions
      else
        []
      end
    when *CHECK_EVENT_TYPES
      actions = []
      actions << "fix_checks" if github_repair_enabled?("checks", event)
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
    return ignored("not an issue create, update, or manual mention") unless event["event_type"] == "Issue" &&
                                                                        %w[create update manual_mention].include?(event["event_action"])

    config = linear_settings
    if event["event_action"] == "manual_mention"
      return ignored("ready issue automation is disabled") unless config["issue"] == "ready_issues"
      return ignored("manual mentions are disabled") unless config["manual_mentions"] == true
      return ignored("event is not a verified bot mention") unless event["mentioned_bot"] == true
    end

    qa_transition = linear_qa_transition?(event, config)
    ready, reason = linear_issue_ready?(event, config, enforce_ready_status: !qa_transition)
    return ignored(reason) unless ready

    route, route_reason = linear_repository_route_for(event, config)
    return ignored(route_reason) unless route

    if qa_transition
      return routed([ "run_qa" ], linear_route: route)
    end

    return ignored("ready issue automation is disabled") unless config["issue"] == "ready_issues"

    actions = event["event_action"] == "manual_mention" ? [ "respond_to_mention" ] : [ "implement_issue" ]
    routed(actions, linear_route: route)
  end

  def linear_qa_transition?(event, config)
    return false unless config["qa"] == "status_transition"

    qa_statuses = Array(config["qa_statuses"]).map(&:downcase)
    return false unless qa_statuses.include?(event["status"].to_s.downcase)
    return true if event["event_action"] == "create"

    event["event_action"] == "update" && Array(event["updated_fields"]).include?("stateId")
  end

  def github_eligible?(event)
    # A draft remains a hard stop for unattended lifecycle automation. A
    # verified, explicitly enabled manual mention is different: it is a
    # collaborator's deliberate request to start the scoped workstream, while
    # still passing the normal repository, branch, and label gates below.
    manual_mention = event["event_action"] == "manual_mention"
    config = github_settings
    if manual_mention
      return [ false, "manual mentions are disabled" ] unless config["manual_mentions"] == true
      return [ false, "event is not a verified bot mention" ] unless event["mentioned_bot"] == true
    end

    if event["draft"] == true && !manual_mention
      return [ false, "draft pull requests are excluded" ]
    end

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

  # Githubbot, not an untrusted webhook payload, establishes these two flags
  # after signature verification and (for a review request) bot/team identity
  # matching. A policy may use them only after the ordinary repository, branch,
  # and label gates above have passed; the draft gate continues to apply to
  # unattended lifecycle events.
  #
  # `continuation_authorized` is derived by AutomationEventIngestor from the
  # same durable PR workstream that holds the selected execution role. It is
  # deliberately not a second workflow engine or a caller-supplied flag.
  def github_review_enabled?(event)
    case github_settings["review"]
    when "all_eligible"
      GITHUB_REVIEW_ACTIONS.include?(event["event_action"])
    when "assigned_or_mentioned"
      event["event_action"] == "review_requested" && event["review_requested_for_bot"] == true
    else
      false
    end
  end

  # A direct GitHub comment is not an autonomous lifecycle trigger. Githubbot
  # first verifies the commenter and then supplies this fact only after it has
  # fetched the PR through the GitHub App. Keeping the opt-in separate from
  # review mode means a repository can receive automatic reviews without
  # allowing a comment to start a write-capable agent turn.
  def github_manual_mention_enabled?(event)
    github_settings["manual_mentions"] == true &&
      event["event_action"] == "manual_mention" &&
      event["mentioned_bot"] == true
  end

  def github_repair_enabled?(setting, event)
    case github_settings[setting]
    when "eligible"
      true
    when "bot_owned"
      event["bot_owned"] == true
    when "explicit"
      event["continuation_authorized"] == true
    else
      false
    end
  end

  def linear_issue_ready?(event, config, enforce_ready_status: true)
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
    if enforce_ready_status && ready_statuses.any? && !ready_statuses.include?(event["status"].to_s.downcase)
      return [ false, "issue status is not ready" ]
    end

    labels = Array(event["labels"]).map { |label| label.to_s.downcase }
    required = Array(config["required_labels"]).map(&:downcase)
    return [ false, "a required label is missing" ] unless (required - labels).empty?

    excluded = Array(config["excluded_labels"]).map(&:downcase)
    return [ false, "an excluded label is present" ] if (excluded & labels).any?

    [ true, nil ]
  end

  def linear_repository_route_for(event, config)
    routes = Array(config["repository_routes"])
    return [ legacy_linear_repository_route(config), nil ] if routes.empty?

    labels = Array(event["labels"]).map { |label| label.to_s.downcase }
    matches = routes.select do |route|
      required = Array(route["required_labels"]).map(&:downcase)
      (required - labels).empty?
    end
    return [ nil, "no configured repository route matches issue labels" ] if matches.empty?
    return [ nil, "multiple configured repository routes match issue labels" ] if matches.many?

    [ matches.first, nil ]
  end

  def boolean?(value)
    value == true || value == false
  end

  def legacy_linear_repository_route(config)
    {
      "repository" => config["github_repository"],
      "reviewer_logins" => config["reviewer_logins"],
      "reviewer_team_slugs" => config["reviewer_team_slugs"]
    }
  end

  def routed(actions, linear_route: nil)
    linear = linear? ? linear_settings : {}
    route = linear_route || legacy_linear_repository_route(linear)
    reviewer_logins = route.key?("reviewer_logins") ?
      Array(route["reviewer_logins"]) :
      Array(linear["reviewer_logins"])
    reviewer_team_slugs = route.key?("reviewer_team_slugs") ?
      Array(route["reviewer_team_slugs"]) :
      Array(linear["reviewer_team_slugs"])

    {
      "decision" => mode == "act" ? "act" : "observe",
      "reason" => mode == "act" ? "policy authorizes automation" : "policy is in observe mode",
      "actions" => actions,
      "auto_merge" => github? && github_settings["auto_merge"] == true,
      "review_orchestration" => github? ? github_settings["review_orchestration"] : nil,
      "github_repository" => route["repository"],
      "move_to_in_progress" => linear["move_to_in_progress"] != false,
      "preview_label" => route["preview_label"],
      "qa_profiles" => Array(linear["qa_profiles"]),
      "qa_target" => linear["qa_target"],
      "reviewer_logins" => reviewer_logins,
      "reviewer_team_slugs" => reviewer_team_slugs
    }
  end

  def validate_linear_repository_routes(config)
    routes = config["repository_routes"]
    unless routes.is_a?(Array)
      errors.add(:settings, "repository routes must be a list")
      return
    end

    legacy_repository = config["github_repository"].to_s
    if routes.any? && legacy_repository.present?
      errors.add(:settings, "must use either a GitHub repository or repository routes, not both")
    end

    if (config["issue"] == "ready_issues" || config["qa"] == "status_transition") &&
       routes.empty? && !legacy_repository.match?(%r{\A[^/\s]+/[^/\s]+\z})
      errors.add(:settings, "needs a GitHub repository or repository routes for Linear automation")
    end

    routes.each_with_index do |route, index|
      unless route.is_a?(Hash)
        errors.add(:settings, "repository route #{index + 1} must be an object")
        next
      end
      route = route.deep_stringify_keys
      unsupported = route.keys - LINEAR_REPOSITORY_ROUTE_KEYS
      errors.add(:settings, "repository route #{index + 1} has unsupported fields") if unsupported.any?

      repository = route["repository"].to_s
      unless repository.match?(%r{\A[^/\s]+/[^/\s]+\z})
        errors.add(:settings, "repository route #{index + 1} needs a GitHub repository")
      end

      labels = route["required_labels"]
      unless labels.is_a?(Array) && labels.all? { |label| label.is_a?(String) && label.present? } && labels.any?
        errors.add(:settings, "repository route #{index + 1} needs at least one required label")
      end

      %w[reviewer_logins reviewer_team_slugs].each do |field|
        next unless route.key?(field)

        unless route[field].is_a?(Array) && route[field].all? { |value| value.is_a?(String) && value.present? }
          errors.add(:settings, "repository route #{index + 1} has invalid #{field}")
        end
      end

      next unless route.key?("preview_label")

      preview_label = route["preview_label"]
      unless preview_label.is_a?(String) && preview_label.present? && preview_label.length <= 100
        errors.add(:settings, "repository route #{index + 1} has an invalid preview label")
      end
    end
  end

  def linear_repository_summary(config)
    routes = Array(config["repository_routes"])
    return config["github_repository"].presence || "not mapped" if routes.empty?

    routes.map { |route| route["repository"] }.compact.join(", ")
  end

  def activity_reporting_summary
    kinds = []
    kinds << "accepted-work" if reports_activity?("accepted")
    kinds << "PR-created" if reports_activity?("pr_created")
    kinds.any? ? " · Slack #{kinds.join(' + ')} report" : ""
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

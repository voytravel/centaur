require "uri"

class AutomationWorkstream < ApplicationRecord
  oid_prefix "aws"

  STATES = %w[idle active blocked completed].freeze
  GITHUB_PR_SUBJECT_PATTERN = /\Agithub:([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+):pr:([1-9]\d*)\z/.freeze
  LINEAR_ISSUE_TITLE_MAX_LENGTH = 240

  belongs_to :automation_policy, optional: true
  belongs_to :principal, optional: true
  belongs_to :authorization_role, class_name: "Role", optional: true
  has_many :automation_events, dependent: :delete_all

  normalizes :provider, :subject_key, :session_key, :repository,
             with: ->(value) { value.to_s.strip }

  validates :provider, inclusion: { in: AutomationPolicy::PROVIDERS }
  validates :subject_key, :session_key, presence: true
  validates :subject_key, uniqueness: { scope: :provider }
  validates :state, inclusion: { in: STATES }
  validate :metadata_is_a_hash

  # Search only stable, normalized audit identifiers. The EXISTS clause keeps
  # delivery-id lookup scoped to the workstream rather than joining every event
  # into the index relation.
  scope :matching_operator_query, lambda { |query|
    term = query.to_s.strip
    if term.blank?
      all
    else
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
      where(
        <<~SQL.squish,
          LOWER(automation_workstreams.subject_key) LIKE LOWER(:pattern)
          OR LOWER(automation_workstreams.session_key) LIKE LOWER(:pattern)
          OR LOWER(COALESCE(automation_workstreams.repository, '')) LIKE LOWER(:pattern)
          OR EXISTS (
            SELECT 1
            FROM automation_events
            WHERE automation_events.automation_workstream_id = automation_workstreams.id
              AND LOWER(automation_events.deduplication_key) LIKE LOWER(:pattern)
          )
        SQL
        pattern: pattern
      )
    end
  }

  # The Console policy index selects these aliases with a lateral join so an
  # operator can see the latest safe policy outcome without loading every raw
  # provider event. They are deliberately not persisted workstream state.
  def latest_automation_decision
    self[:latest_automation_decision].presence
  end

  def latest_automation_action_kind
    self[:latest_automation_action_kind].presence
  end

  def latest_automation_reason
    self[:latest_automation_reason].presence
  end

  # The operator audit view can link back to a provider item only when the
  # destination is derived from a normalized, provider-owned identifier. This
  # keeps provider payload URLs out of templates and prevents a future event
  # field from becoming an arbitrary external-link sink.
  def safe_source_url
    case provider
    when "github" then github_pull_request_url
    when "linear" then self.class.normalize_linear_issue_url(metadata["linear_issue_url"])
    end
  end

  # Linear's server-side issue context provides this as a permalink. Normalize
  # it once at ingestion and again before rendering so existing data cannot turn
  # a Console source link into an arbitrary external destination.
  def self.normalize_linear_issue_url(value)
    value = value.to_s.strip
    return if value.blank?

    uri = URI.parse(value)
    host = uri.host.to_s.downcase
    return unless uri.is_a?(URI::HTTPS)
    return unless host == "linear.app" || host.end_with?(".linear.app")
    return if uri.userinfo.present?
    return unless uri.port == 443

    # Query strings and fragments can carry transient or user-specific context
    # and are not needed to navigate to an issue.
    uri.query = nil
    uri.fragment = nil
    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  # A Linear title is useful for concise operator-facing status, but it is
  # provider content rather than policy input. Normalize it before durable
  # storage so downstream renderers receive one bounded, single-line value.
  def self.normalize_linear_issue_title(value)
    title = value.to_s.encode(
      Encoding::UTF_8,
      invalid: :replace,
      undef: :replace,
      replace: ""
    )
    title = title.gsub(/[[:cntrl:]]+/, " ").squish
    return if title.blank?

    title.truncate(LINEAR_ISSUE_TITLE_MAX_LENGTH, omission: "…")
  end

  private

  def github_pull_request_url
    match = GITHUB_PR_SUBJECT_PATTERN.match(subject_key)
    return unless match && repository.to_s.casecmp?(match[1])

    "https://github.com/#{match[1]}/pull/#{match[2]}"
  end

  def metadata_is_a_hash
    errors.add(:metadata, "must be an object") unless metadata.is_a?(Hash)
  end
end

class AutomationWorkstream < ApplicationRecord
  oid_prefix "aws"

  STATES = %w[idle active blocked completed].freeze

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

  private

  def metadata_is_a_hash
    errors.add(:metadata, "must be an object") unless metadata.is_a?(Hash)
  end
end

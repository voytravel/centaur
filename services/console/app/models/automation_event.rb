class AutomationEvent < ApplicationRecord
  DECISIONS = %w[ignored observe act].freeze

  belongs_to :automation_workstream

  normalizes :provider, :deduplication_key, :event_type, :event_action, :decision, :action_kind,
             with: ->(value) { value.to_s.strip }

  validates :provider, inclusion: { in: AutomationPolicy::PROVIDERS }
  validates :deduplication_key, :event_type, :decision, :received_at, presence: true
  validates :deduplication_key, uniqueness: { scope: :provider }
  validates :decision, inclusion: { in: DECISIONS }
  validate :metadata_is_a_hash

  private

  def metadata_is_a_hash
    errors.add(:metadata, "must be an object") unless metadata.is_a?(Hash)
  end
end

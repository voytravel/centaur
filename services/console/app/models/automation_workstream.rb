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

  private

  def metadata_is_a_hash
    errors.add(:metadata, "must be an object") unless metadata.is_a?(Hash)
  end
end

# The existing normalized event wire contract shared by Githubbot, Linearbot,
# and Console. Keep validation here so provider adapters can change without
# widening the authority accepted by the policy/audit plane.
class AutomationIngressContractV1
  class InvalidEvent < StandardError; end

  def self.validate!(event)
    provider = event["provider"]
    raise InvalidEvent, "provider is required" unless AutomationPolicy::PROVIDERS.include?(provider)
    raise InvalidEvent, "event_type is required" if event["event_type"].blank?
    raise InvalidEvent, "deduplication_key is required" if event["deduplication_key"].blank?

    case provider
    when "github"
      raise InvalidEvent, "repository is required" unless event["repository"].to_s.match?(%r{\A[^/\s]+/[^/\s]+\z})
      raise InvalidEvent, "subject_number is required" unless event["subject_number"].to_s.match?(/\A\d+\z/)
    when "linear"
      raise InvalidEvent, "linear_issue_id is required" if event["linear_issue_id"].blank?
      raise InvalidEvent, "linear_team_id is required" if event["linear_team_id"].blank?
    end
  end
end

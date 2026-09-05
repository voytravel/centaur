# Builds the narrow input for the reviewed QA orchestration workflow. Provider
# webhook bodies never cross this boundary: the workflow receives only the
# normalized issue identity/title and policy-selected repository/profile fields.
class AutomationQaDispatch
  WORKFLOW_NAME = "linear_qa_control_plane"
  WORKFLOW_MAX_ATTEMPTS = 3
  ISSUE_IDENTIFIER_PATTERN = /\A[A-Z][A-Z0-9]*-[1-9]\d*\z/
  REPOSITORY_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*\z/
  PROFILE_PATTERN = /\A[a-z][a-z0-9_-]{0,63}\z/

  def initialize(event)
    @event = event
    @workstream = event.automation_workstream
  end

  def workflow_input
    return unless @event.decision == "act"
    return unless @event.action_kind.to_s.split(",").map(&:strip).include?("run_qa")
    return unless ISSUE_IDENTIFIER_PATTERN.match?(issue_identifier)
    return unless REPOSITORY_PATTERN.match?(repository)

    {
      "automation_event_id" => @event.id,
      "issue_id" => @workstream.metadata["linear_issue_id"].to_s,
      "issue_identifier" => issue_identifier,
      "issue_title" => issue_title,
      "issue_url" => @workstream.safe_source_url,
      "repository" => repository,
      "profiles" => profiles,
      "target" => qa_target,
      "workstream_id" => @workstream.oid
    }.compact
  end

  def idempotency_key
    "automation-qa-dispatch:#{@event.id}"
  end

  private

  def issue_identifier
    @workstream.metadata["linear_issue_identifier"].to_s.strip.upcase
  end

  def issue_title
    AutomationWorkstream.normalize_linear_issue_title(@workstream.metadata["linear_issue_title"])
  end

  def repository
    @workstream.repository.to_s.strip.downcase
  end

  def profiles
    Array(@event.metadata.dig("result", "qa_profiles"))
      .filter_map { |profile| PROFILE_PATTERN.match?(profile.to_s) ? profile.to_s : nil }
      .uniq
      .first(20)
  end

  def qa_target
    value = @event.metadata.dig("result", "qa_target").to_s.strip.downcase
    return value if PROFILE_PATTERN.match?(value)

    "auto"
  end
end

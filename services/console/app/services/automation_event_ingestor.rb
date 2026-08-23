# Receives a normalized event summary from a verified platform ingress. It never
# accepts raw webhook bodies or secrets: webhook signature verification remains
# in githubbot/linearbot, while this service owns durable audit state, policy
# evaluation, and stable session/workstream identity.
class AutomationEventIngestor
  class InvalidEvent < StandardError; end

  def initialize(event)
    @event = event.deep_stringify_keys
  end

  def call
    validate_event!
    policy = resolve_policy
    existing = AutomationEvent.find_by(
      provider: @event.fetch("provider"),
      deduplication_key: @event.fetch("deduplication_key")
    )
    # A duplicate delivery retains its original audit event, but evaluates the
    # *current* policy before authorizing another ingress attempt. Disabling or
    # narrowing a policy therefore takes effect immediately rather than letting
    # an old recorded `act` decision revive work on a webhook redelivery.
    return response_for(existing, existing.automation_workstream, policy_outcome(policy), policy) if existing

    return no_policy_response unless policy

    workstream = find_or_create_workstream!
    outcome = policy.evaluate(@event)
    record = workstream.automation_events.create!(
      provider: @event.fetch("provider"),
      deduplication_key: @event.fetch("deduplication_key"),
      event_type: @event.fetch("event_type"),
      event_action: @event["event_action"],
      decision: outcome.fetch("decision"),
      action_kind: outcome.fetch("actions").join(",").presence,
      metadata: safe_metadata(outcome),
      received_at: Time.current
    )
    workstream.with_lock do
      workstream.update!(
        automation_policy: policy,
        last_event_at: record.received_at,
        event_count: workstream.event_count + 1,
        state: outcome["decision"] == "act" ? "active" : workstream.state
      )
    end

    response_for(record, workstream, nil, policy)
  rescue ActiveRecord::RecordNotUnique
    existing = AutomationEvent.find_by!(
      provider: @event.fetch("provider"),
      deduplication_key: @event.fetch("deduplication_key")
    )
    policy = resolve_policy
    response_for(existing, existing.automation_workstream, policy_outcome(policy), policy)
  end

  private

  def validate_event!
    provider = @event["provider"]
    raise InvalidEvent, "provider is required" unless AutomationPolicy::PROVIDERS.include?(provider)
    raise InvalidEvent, "event_type is required" if @event["event_type"].blank?
    raise InvalidEvent, "deduplication_key is required" if @event["deduplication_key"].blank?

    case provider
    when "github"
      raise InvalidEvent, "repository is required" unless @event["repository"].to_s.match?(%r{\A[^/\s]+/[^/\s]+\z})
      raise InvalidEvent, "subject_number is required" unless @event["subject_number"].to_s.match?(/\A\d+\z/)
    when "linear"
      raise InvalidEvent, "linear_issue_id is required" if @event["linear_issue_id"].blank?
      raise InvalidEvent, "linear_team_id is required" if @event["linear_team_id"].blank?
    end
  end

  def find_or_create_workstream!
    provider = @event.fetch("provider")
    subject_key = subject_key_for
    AutomationWorkstream.find_or_create_by!(provider: provider, subject_key: subject_key) do |workstream|
      workstream.session_key = session_key_for
      workstream.repository = @event["repository"]
      workstream.metadata = {
        "linear_issue_id" => @event["linear_issue_id"],
        "linear_team_id" => @event["linear_team_id"],
        "linear_project_id" => @event["linear_project_id"]
      }.compact
    end
  end

  def resolve_policy
    if @event["provider"] == "github"
      AutomationPolicy.for_github(@event.fetch("repository"))
    else
      AutomationPolicy.for_linear(
        team_id: @event.fetch("linear_team_id"),
        project_id: @event["linear_project_id"]
      )
    end
  end

  def subject_key_for
    if @event["provider"] == "github"
      "github:#{@event.fetch("repository")}:pr:#{@event.fetch("subject_number")}"
    else
      "linear:#{@event.fetch("linear_issue_id")}"
    end
  end

  # Existing ingress-scoped session families are deliberately reused. This
  # preserves api-rs authorization and makes every policy-driven PR/issue event
  # continue on the same durable session/workspace rather than cold-starting a
  # sibling sandbox.
  def session_key_for
    if @event["provider"] == "github"
      "github-manage:#{@event.fetch("repository")}:#{@event.fetch("subject_number")}"
    else
      "linear:#{@event.fetch("linear_issue_id")}"
    end
  end

  def safe_metadata(outcome)
    {
      "result" => {
        "actions" => outcome.fetch("actions"),
        "auto_merge" => outcome["auto_merge"] == true,
        "github_repository" => outcome["github_repository"],
        "move_to_in_progress" => outcome["move_to_in_progress"] != false,
        "reason" => outcome.fetch("reason"),
        "reviewer_logins" => Array(outcome["reviewer_logins"]),
        "reviewer_team_slugs" => Array(outcome["reviewer_team_slugs"])
      },
      "base_branch" => @event["base_branch"],
      "head_sha" => @event["head_sha"],
      "labels" => Array(@event["labels"]).first(50),
      "linear_project_id" => @event["linear_project_id"],
      "status" => @event["status"],
      "title_present" => @event["title"].to_s.strip.present?,
      "description_present" => @event["description"].to_s.strip.present?
    }.compact
  end

  def response_for(record, workstream, outcome = nil, policy = :stored)
    result = outcome || record.metadata.fetch("result", {})
    resolved_policy = policy == :stored ? workstream.automation_policy : policy
    {
      "event_id" => record.id,
      "workstream_id" => workstream.oid,
      "session_key" => workstream.session_key,
      "decision" => result["decision"] || record.decision,
      "reason" => result["reason"] || "previously recorded event",
      "actions" => Array(result["actions"]),
      "auto_merge" => result["auto_merge"] == true,
      "github_repository" => result["github_repository"],
      "move_to_in_progress" => result["move_to_in_progress"] != false,
      "policy_id" => resolved_policy&.oid,
      "reviewer_logins" => Array(result["reviewer_logins"]),
      "reviewer_team_slugs" => Array(result["reviewer_team_slugs"])
    }
  end

  def ignored(reason)
    { "decision" => "ignored", "reason" => reason, "actions" => [] }
  end

  def policy_outcome(policy)
    policy ? policy.evaluate(@event) : ignored("no matching automation policy")
  end

  def no_policy_response
    result = ignored("no matching automation policy")
    {
      "event_id" => nil,
      "workstream_id" => nil,
      "session_key" => session_key_for,
      "decision" => result.fetch("decision"),
      "reason" => result.fetch("reason"),
      "actions" => [],
      "auto_merge" => false,
      "github_repository" => nil,
      "move_to_in_progress" => true,
      "policy_id" => nil,
      "reviewer_logins" => [],
      "reviewer_team_slugs" => []
    }
  end
end

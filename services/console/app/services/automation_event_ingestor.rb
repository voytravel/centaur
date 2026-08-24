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
    if existing
      AutomationPrincipalAuthorizer.reconcile_workstream(existing.automation_workstream)
      return response_for(
        existing,
        existing.automation_workstream,
        policy_outcome(policy, existing.automation_workstream),
        policy
      )
    end

    return no_policy_response unless policy

    workstream = find_or_create_workstream!
    record = outcome = activity_report = nil
    workstream.with_lock do
      # Evaluate and persist each event serially per durable workstream. In
      # particular, this makes the accepted-work notification a true state
      # transition: concurrent first events cannot each observe `idle` and
      # schedule duplicate Slack reports.
      previous_state = workstream.state
      outcome = policy.evaluate(policy_event(workstream, policy))
      activity_report = activity_report_metadata(policy, outcome, previous_state)
      record = workstream.automation_events.create!(
        provider: @event.fetch("provider"),
        deduplication_key: @event.fetch("deduplication_key"),
        event_type: @event.fetch("event_type"),
        event_action: @event["event_action"],
        decision: outcome.fetch("decision"),
        action_kind: outcome.fetch("actions").join(",").presence,
        metadata: safe_metadata(outcome, activity_report:),
        received_at: Time.current
      )
      workstream.update!(
        automation_policy: policy,
        last_event_at: record.received_at,
        event_count: workstream.event_count + 1,
        state: next_workstream_state(workstream, outcome)
      )
    end
    AutomationPrincipalAuthorizer.reconcile_workstream(workstream)
    enqueue_activity_report(record) if activity_report

    response_for(record, workstream, nil, policy)
  rescue ActiveRecord::RecordNotUnique
    existing = AutomationEvent.find_by!(
      provider: @event.fetch("provider"),
      deduplication_key: @event.fetch("deduplication_key")
    )
    policy = resolve_policy
    AutomationPrincipalAuthorizer.reconcile_workstream(existing.automation_workstream)
    response_for(
      existing,
      existing.automation_workstream,
      policy_outcome(policy, existing.automation_workstream),
      policy
    )
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
    workstream = AutomationWorkstream.find_or_create_by!(provider: provider, subject_key: subject_key) do |workstream|
      workstream.session_key = session_key_for
      workstream.repository = @event["repository"]
      workstream.metadata = workstream_metadata
    end
    refresh_workstream_metadata!(workstream)
    workstream
  end

  def refresh_workstream_metadata!(workstream)
    incoming = workstream_metadata
    return if incoming.empty?

    workstream.with_lock do
      merged = workstream.metadata.merge(incoming)
      workstream.update!(metadata: merged) if merged != workstream.metadata
    end
  end

  def workstream_metadata
    {
      "linear_issue_id" => @event["linear_issue_id"],
      "linear_team_id" => @event["linear_team_id"],
      "linear_project_id" => @event["linear_project_id"],
      "linear_issue_identifier" => @event["linear_issue_identifier"].to_s.strip.presence,
      "linear_issue_url" => AutomationWorkstream.normalize_linear_issue_url(@event["linear_issue_url"])
    }.compact
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

  def safe_metadata(outcome, activity_report: nil)
    {
      "result" => {
        "actions" => outcome.fetch("actions"),
        "auto_merge" => outcome["auto_merge"] == true,
        "github_repository" => outcome["github_repository"],
        "move_to_in_progress" => outcome["move_to_in_progress"] != false,
        "preview_label" => outcome["preview_label"],
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
    }.compact.tap do |metadata|
      metadata["activity_report"] = activity_report if activity_report
    end
  end

  # A report is a notification of a newly accepted workstream, not a second
  # activity/event store. We snapshot only the destination selected by the
  # policy at authorization time; a later policy edit cannot redirect a queued
  # report. Active workstreams deliberately suppress continuation noise.
  def activity_report_metadata(policy, outcome, previous_state)
    return unless outcome["decision"] == "act"
    return if previous_state == "active"
    return unless policy.reports_activity?("accepted")

    {
      "kind" => "accepted",
      "slack_channel" => policy.activity_reporting_settings.fetch("slack_channel")
    }
  end

  def enqueue_activity_report(record)
    AutomationActivityReportJob.perform_later(record.id)
  rescue StandardError => e
    # Reporting must not make verified ingress retry or prevent the already
    # authorized workstream from starting. The durable event remains visible in
    # Console and operators get a concise infrastructure log to investigate.
    Rails.logger.warn(
      "automation_activity_report_enqueue_failed event_id=#{record.id} error=#{e.class}: #{e.message}"
    )
  end

  # GitHub repair policies can continue only a PR that this same durable
  # workstream previously authorized. The fact is derived in Console, after
  # matching the scope and before evaluating the next event; Githubbot cannot
  # manufacture it from a webhook field.
  def policy_event(workstream, policy)
    return @event unless @event["provider"] == "github"

    @event.merge(
      "continuation_authorized" => workstream.state == "active" &&
        workstream.automation_policy_id == policy.id
    )
  end

  # An Act event begins or resumes an existing workstream. A safety rejection
  # (for example, a draft, disallowed branch, or no-agent label) blocks it and
  # releases its role. An otherwise eligible lifecycle event with no configured
  # action is merely noise: retain the prior authorization so a later review,
  # check, or conflict event can continue the same session.
  def next_workstream_state(workstream, outcome)
    return "active" if outcome["decision"] == "act"
    return workstream.state unless outcome["decision"] == "ignored"
    return workstream.state if outcome["reason"] == "no automatic action is enabled for this event"

    "blocked"
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
      "preview_label" => result["preview_label"],
      "policy_id" => resolved_policy&.oid,
      "reviewer_logins" => Array(result["reviewer_logins"]),
      "reviewer_team_slugs" => Array(result["reviewer_team_slugs"])
    }
  end

  def ignored(reason)
    { "decision" => "ignored", "reason" => reason, "actions" => [] }
  end

  def policy_outcome(policy, workstream = nil)
    policy ? policy.evaluate(policy_event(workstream, policy)) : ignored("no matching automation policy")
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
      "preview_label" => nil,
      "policy_id" => nil,
      "reviewer_logins" => [],
      "reviewer_team_slugs" => []
    }
  end
end

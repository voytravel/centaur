require "digest"

# Produces a bounded, redacted evidence snapshot for the scheduled automation
# interaction review. It intentionally exposes operational outcomes only: no
# Slack/Linear message bodies, provider payloads, execution errors, secrets,
# or repository contents cross this boundary.
class AutomationInteractionReviewSnapshot
  DEFAULT_DAYS = 7
  MAX_DAYS = 14
  MAX_AUTOMATION_REASON_ROWS = 20
  REVIEWED_WORKFLOWS = %w[
    automation_activity_report
    github_dependency_maintenance
    github_dependency_maintenance_action
    linear_qa_control_plane
    sentry_alert_triage
  ].freeze

  class InvalidWindow < StandardError; end

  def initialize(days: DEFAULT_DAYS, now: Time.current)
    @days = normalize_days(days)
    @now = now.utc
    @since = @now - @days.days
  end

  def as_json(*)
    evidence = []
    availability = {}

    session_evidence, availability["session_executions"] = session_execution_evidence
    evidence.concat(session_evidence)

    feedback_items, availability["user_feedback"] = feedback_evidence
    evidence.concat(feedback_items)

    automation_evidence, availability["automation_events"] = automation_event_evidence
    evidence.concat(automation_evidence)

    workflow_evidence, availability["workflow_runs"] = workflow_run_evidence
    evidence.concat(workflow_evidence)

    {
      "schema_version" => 1,
      "window" => {
        "days" => @days,
        "start" => @since.iso8601,
        "end" => @now.iso8601
      },
      "availability" => availability,
      "evidence" => evidence.sort_by { |item| [ item.fetch("source"), item.fetch("id") ] }
    }
  end

  private

  def normalize_days(value)
    days = Integer(value)
    return days if days.between?(1, MAX_DAYS)

    raise InvalidWindow, "days must be between 1 and #{MAX_DAYS}"
  rescue ArgumentError, TypeError
    raise InvalidWindow, "days must be an integer between 1 and #{MAX_DAYS}"
  end

  # Thread-key prefixes are Centaur-owned durable routing identifiers. Keep the
  # classification static rather than looking at provider metadata, which may
  # contain arbitrary provider text.
  def session_execution_evidence
    platform = <<~SQL.squish
      CASE
        WHEN thread_key LIKE 'slack:%' THEN 'slack'
        WHEN thread_key LIKE 'github:%' OR thread_key LIKE 'github-%' THEN 'github'
        WHEN thread_key LIKE 'linear:%' THEN 'linear'
        WHEN thread_key LIKE 'sentry:%' THEN 'sentry'
        ELSE 'other'
      END
    SQL
    counts = CentaurSessionExecution
      .where("created_at >= ? AND created_at <= ?", @since, @now)
      .group(Arel.sql(platform), :status)
      .count
    [
      counts.map do |(source, status), count|
        evidence(
          id: "session:#{source}:#{safe_token(status)}",
          source: source,
          metric: "execution_status",
          count: count,
          attributes: { "status" => safe_token(status) }
        )
      end,
      "available"
    ]
  rescue ActiveRecord::ActiveRecordError, PG::Error
    [ [], "unavailable" ]
  end

  # Feedback text is intentionally never selected. A feedback count is enough
  # to tell the reviewer that a human signal exists and to prompt a targeted,
  # operator-visible follow-up rather than synthetic sentiment analysis.
  def feedback_evidence
    connection = CentaurSessionRecord.connection
    return [ [], "unavailable" ] unless connection.data_source_exists?("user_feedback")

    rows = connection.select_all(
      CentaurSessionRecord.send(
        :sanitize_sql_array,
        [
          <<~SQL.squish,
            SELECT CASE WHEN source IN ('console', 'slack', 'github', 'linear', 'sentry', 'qa_bot')
                        THEN source ELSE 'other' END AS source,
                   COUNT(*) AS count
            FROM user_feedback WHERE created_at >= ? AND created_at <= ?
            GROUP BY 1 ORDER BY 1
          SQL
          @since,
          @now
        ]
      )
    )
    [
      rows.filter_map do |row|
        source = safe_token(row["source"])
        count = row["count"].to_i
        next if count <= 0

        evidence(
          id: "feedback:#{source}",
          source: "feedback",
          metric: "received",
          count: count,
          attributes: { "feedback_source" => source }
        )
      end,
      "available"
    ]
  rescue ActiveRecord::ActiveRecordError, PG::Error
    [ [], "unavailable" ]
  end

  # These are policy-produced outcomes, not webhook fields. Reasons help the
  # reviewer identify repeated configuration gates without exposing provider
  # content. Keep the output bounded and aggregate identical reasons.
  def automation_event_evidence
    scope = AutomationEvent.where(received_at: @since..@now)
    decisions = scope.group(:provider, :decision).count
    reasons = scope
      .where("metadata -> 'result' ->> 'reason' IS NOT NULL")
      .group(:provider, :decision, Arel.sql("metadata -> 'result' ->> 'reason'"))
      .count
      .sort_by { |(_provider, _decision, reason), count| [ -count, reason.to_s ] }
      .first(MAX_AUTOMATION_REASON_ROWS)

    rows = decisions.map do |(provider, decision), count|
      evidence(
        id: "automation:#{safe_token(provider)}:#{safe_token(decision)}",
        source: safe_token(provider),
        metric: "policy_decision",
        count: count,
        attributes: { "decision" => safe_token(decision) }
      )
    end
    rows.concat(
      reasons.filter_map do |(provider, decision, reason), count|
        normalized_reason = safe_reason(reason)
        next unless normalized_reason

        evidence(
          id: "automation:#{safe_token(provider)}:#{safe_token(decision)}:#{Digest::SHA256.hexdigest(normalized_reason)[0, 12]}",
          source: safe_token(provider),
          metric: "policy_reason",
          count: count,
          attributes: {
            "decision" => safe_token(decision),
            "reason" => normalized_reason
          }
        )
      end
    )
    [ rows, "available" ]
  rescue ActiveRecord::ActiveRecordError, PG::Error
    [ [], "unavailable" ]
  end

  def workflow_run_evidence
    return [ [], "unavailable" ] unless CentaurWorkflowRun.available?

    counts = CentaurWorkflowRun
      .where(workflow_name: REVIEWED_WORKFLOWS)
      .where("#{CentaurWorkflowRun::RECENCY_SQL} >= ? AND #{CentaurWorkflowRun::RECENCY_SQL} <= ?", @since, @now)
      .group(:workflow_name, Arel.sql(CentaurWorkflowRun::DISPLAY_STATUS_SQL))
      .count
    [
      counts.map do |(workflow_name, status), count|
        evidence(
          id: "workflow:#{safe_token(workflow_name)}:#{safe_token(status)}",
          source: workflow_source(workflow_name),
          metric: "workflow_status",
          count: count,
          attributes: {
            "workflow_name" => safe_token(workflow_name),
            "status" => safe_token(status)
          }
        )
      end,
      "available"
    ]
  rescue ActiveRecord::ActiveRecordError, PG::Error
    [ [], "unavailable" ]
  end

  def workflow_source(workflow_name)
    case workflow_name
    when "linear_qa_control_plane" then "qa_bot"
    when "sentry_alert_triage" then "sentry"
    when /github/ then "github"
    else "automation"
    end
  end

  def evidence(id:, source:, metric:, count:, attributes:)
    {
      "id" => id,
      "source" => source,
      "metric" => metric,
      "count" => count.to_i,
      "attributes" => attributes
    }
  end

  def safe_token(value)
    token = value.to_s.downcase.gsub(/[^a-z0-9_-]+/, "-").delete_prefix("-").delete_suffix("-")
    token.presence&.slice(0, 80) || "unknown"
  end

  def safe_reason(value)
    reason = value.to_s.strip.gsub(/[\r\n\t]+/, " ")
    return if reason.blank? || reason.bytesize > 240
    return unless reason.match?(/\A[\p{Print} ]+\z/)

    reason
  end
end

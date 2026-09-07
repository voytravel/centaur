require "uri"

# Builds the compact, policy-authorized Slack notification for one automation
# event. This is intentionally not an event relay: it uses only normalized
# workstream identifiers and policy-produced actions, excludes provider bodies
# and agent output, and leaves durable delivery/idempotency to Workflow v2.
class AutomationActivityReport
  WORKFLOW_NAME = "automation_activity_report"
  WORKFLOW_MAX_ATTEMPTS = 3
  REPORT_KINDS = AutomationPolicy::ACTIVITY_REPORT_KINDS.freeze
  ACCEPTED_LINEAR_BATCH_WINDOW = 1.minute
  ACCEPTED_LINEAR_BATCH_DELAY = 15.seconds
  MAX_BATCH_ITEMS = 10

  def initialize(event)
    @event = event
    @workstream = event.automation_workstream
  end

  def workflow_input
    return unless REPORT_KINDS.include?(report_kind)

    channel = report_channel
    return unless AutomationPolicy::SLACK_CHANNEL_ID_PATTERN.match?(channel)

    {
      "channel" => channel,
      "kind" => report_kind,
      "text" => message_text
    }
  end

  def idempotency_key
    if batchable_linear_acceptance?
      return "automation-activity-report:accepted-linear:#{report_channel}:#{batch_window_start.to_i}"
    end

    "automation-activity-report:#{@event.id}"
  end

  # A brief fixed window turns a burst of newly accepted Linear work into one
  # readable status without delaying it indefinitely. The key is deterministic,
  # so duplicate delayed jobs produce one native workflow delivery.
  def delivery_at
    return unless batchable_linear_acceptance?

    batch_window_start + ACCEPTED_LINEAR_BATCH_WINDOW + ACCEPTED_LINEAR_BATCH_DELAY
  end

  private

  def report_configuration
    value = @event.metadata["activity_report"]
    value.is_a?(Hash) ? value.deep_stringify_keys : {}
  end

  def report_kind
    report_configuration["kind"].to_s
  end

  def report_channel
    report_configuration["slack_channel"].to_s.strip.upcase
  end

  def message_text
    return pr_created_message_text if report_kind == "pr_created"
    return accepted_linear_message_text if batchable_linear_acceptance?

    lines = [ ":gear: *Centaur automation accepted*" ]
    lines << "Source: #{source_reference}"
    lines << "Actions: #{action_summary}"
    lines << "Audit: #{audit_reference}"
    lines.join("\n")
  end

  def accepted_linear_message_text
    events = batched_events
    heading = if events.one?
      ":gear: *Centaur accepted a Linear issue*"
    else
      ":gear: *Centaur accepted #{events.length} Linear issues*"
    end
    lines = [ heading ]
    events.first(MAX_BATCH_ITEMS).each do |event|
      lines << "• #{linear_issue_reference(event.automation_workstream)} — #{action_summary(event, descriptive: true)}"
    end
    remaining = events.length - MAX_BATCH_ITEMS
    lines << "• … and #{remaining} more accepted issues" if remaining.positive?
    lines.join("\n")
  end

  def pr_created_message_text
    [
      ":sparkles: *Centaur created a pull request*",
      "Pull request: #{source_reference}",
      "Audit: #{audit_reference}"
    ].join("\n")
  end

  def source_reference
    slack_link(@workstream.safe_source_url, @workstream.subject_key) ||
      "`#{slack_escape(@workstream.subject_key)}`"
  end

  def linear_issue_reference(workstream)
    metadata = workstream.metadata
    identifier = metadata["linear_issue_identifier"].to_s.strip
    title = metadata["linear_issue_title"].to_s.strip
    label = [ identifier.presence, title.presence ].compact.join(" — ").presence || "Linear issue"
    slack_link(workstream.safe_source_url, label) || slack_escape(label)
  end

  def audit_reference
    label = "#{@workstream.oid}"
    slack_link(console_workstream_url, label) || "`#{slack_escape(label)}`"
  end

  def action_summary(event = @event, descriptive: false)
    actions = event.action_kind.to_s.split(",").map(&:strip).reject(&:blank?).first(5)
    return "authorized work" if actions.empty?

    return actions.map { |action| "`#{slack_escape(action)}`" }.join(", ") unless descriptive

    labels = {
      "implement_issue" => "implement",
      "run_qa" => "run QA",
      "review" => "review",
      "resolve_conflict" => "resolve conflicts",
      "fix_feedback" => "address feedback",
      "fix_checks" => "repair failing checks"
    }
    "will #{actions.map { |action| labels.fetch(action, action.tr("_", " ")) }.join(" and ")}"
  end

  def batchable_linear_acceptance?
    report_kind == "accepted" && @workstream.provider == "linear"
  end

  def batch_window_start
    @event.received_at.beginning_of_minute
  end

  def batched_events
    AutomationEvent.includes(:automation_workstream)
      .where(provider: "linear", decision: "act", received_at: batch_window_start...(batch_window_start + ACCEPTED_LINEAR_BATCH_WINDOW))
      .where("metadata -> 'activity_report' ->> 'kind' = ?", "accepted")
      .where("metadata -> 'activity_report' ->> 'slack_channel' = ?", report_channel)
      .order(:received_at, :id)
      .to_a
  end

  # Deployment configuration is trusted, but it is still constrained here so a
  # malformed public URL cannot turn the reporter into an arbitrary link sink.
  # An unavailable public Console URL merely omits the link; it never blocks
  # the authorized agent turn or emits untrusted text.
  def console_workstream_url
    public_url = ConsoleEnv["PUBLIC_URL"].to_s.strip
    return if public_url.blank?

    uri = URI.parse(public_url)
    return unless uri.is_a?(URI::HTTPS)
    return if uri.host.blank? || uri.userinfo.present? || uri.query.present? || uri.fragment.present?

    base = uri.to_s.delete_suffix("/")
    path = Rails.application.routes.url_helpers.console_automation_workstream_path(@workstream.oid)
    "#{base}#{path}"
  rescue URI::InvalidURIError
    nil
  end

  def slack_link(url, label)
    return if url.blank?

    "<#{url}|#{slack_escape(label)}>"
  end

  def slack_escape(value)
    value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub("|", "&#124;")
  end
end

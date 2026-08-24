require "uri"

# Builds the compact, policy-authorized Slack notification for one automation
# event. This is intentionally not an event relay: it uses only normalized
# workstream identifiers and policy-produced actions, excludes provider bodies
# and agent output, and leaves durable delivery/idempotency to Workflow v2.
class AutomationActivityReport
  WORKFLOW_NAME = "automation_activity_report"
  WORKFLOW_MAX_ATTEMPTS = 3
  REPORT_KIND = "accepted"

  def initialize(event)
    @event = event
    @workstream = event.automation_workstream
  end

  def workflow_input
    return unless report_kind == REPORT_KIND

    channel = report_channel
    return unless AutomationPolicy::SLACK_CHANNEL_ID_PATTERN.match?(channel)

    {
      "channel" => channel,
      "kind" => REPORT_KIND,
      "text" => message_text
    }
  end

  def idempotency_key
    "automation-activity-report:#{@event.id}"
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
    lines = [ ":gear: *Centaur automation accepted*" ]
    lines << "Source: #{source_reference}"
    lines << "Actions: #{action_summary}"
    lines << "Audit: #{audit_reference}"
    lines.join("\n")
  end

  def source_reference
    slack_link(@workstream.safe_source_url, @workstream.subject_key) ||
      "`#{slack_escape(@workstream.subject_key)}`"
  end

  def audit_reference
    label = "#{@workstream.oid}"
    slack_link(console_workstream_url, label) || "`#{slack_escape(label)}`"
  end

  def action_summary
    actions = @event.action_kind.to_s.split(",").map(&:strip).reject(&:blank?).first(5)
    return "authorized work" if actions.empty?

    actions.map { |action| "`#{slack_escape(action)}`" }.join(", ")
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

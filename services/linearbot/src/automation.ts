import type { LinearbotFetch, LinearbotOptions } from "./types";
import { errorMessage, noopLogger, stringValue } from "./utils";

type JsonRecord = Record<string, unknown>;

export type LinearAutomationDecision = {
  actions: string[];
  decision: "act" | "ignored" | "observe";
  githubRepository?: string;
  moveToInProgress: boolean;
  previewLabel?: string;
  policyId?: string;
  reason: string;
  reviewerLogins: string[];
  reviewerTeamSlugs: string[];
  sessionKey: string;
  workstreamId?: string;
};

export type LinearAutomationEvent = {
  blocked?: boolean;
  deduplication_key: string;
  description?: string;
  event_action: "create" | "update" | "manual_mention";
  event_type: "Issue";
  labels: string[];
  /** True only after Linearbot verifies that the comment addressed this app. */
  mentioned_bot?: boolean;
  linear_issue_id: string;
  /** Safe, provider-owned issue permalink for the operator audit view. */
  linear_issue_identifier?: string;
  linear_issue_url?: string;
  linear_project_id?: string;
  linear_team_id: string;
  provider: "linear";
  status?: string;
  title?: string;
};

export async function evaluateLinearAutomation(
  options: LinearbotOptions,
  event: LinearAutomationEvent,
): Promise<LinearAutomationDecision | null> {
  if (!options.automationApiUrl || !options.automationIngressToken) return null;
  const fetcher: LinearbotFetch = options.fetch ?? globalThis.fetch;
  const logger = options.logger ?? noopLogger;
  try {
    const response = await fetcher(
      options.automationApiUrl!.replace(/\/$/, "") + "/api/internal/automation_events",
      {
        body: JSON.stringify({ event }),
        headers: {
          Authorization: "Bearer " + options.automationIngressToken,
          "Content-Type": "application/json",
        },
        method: "POST",
      },
    );
    if (!response.ok) {
      logger.warn("linearbot_automation_policy_lookup_failed", {
        status: response.status,
      });
      return null;
    }
    const body = (await response.json()) as { data?: unknown };
    const data = body.data;
    if (!isRecord(data)) return null;
    const decision = stringValue(data.decision);
    const sessionKey = stringValue(data.session_key);
    if (
      !sessionKey ||
      (decision !== "act" && decision !== "observe" && decision !== "ignored")
    ) {
      return null;
    }
    return {
      actions: stringArray(data.actions),
      decision,
      githubRepository: stringValue(data.github_repository),
      moveToInProgress: data.move_to_in_progress !== false,
      previewLabel: stringValue(data.preview_label),
      policyId: stringValue(data.policy_id),
      reason: stringValue(data.reason) ?? "policy result",
      reviewerLogins: stringArray(data.reviewer_logins),
      reviewerTeamSlugs: stringArray(data.reviewer_team_slugs),
      sessionKey,
      workstreamId: stringValue(data.workstream_id),
    };
  } catch (error) {
    logger.warn("linearbot_automation_policy_lookup_failed", {
      error: errorMessage(error),
    });
    return null;
  }
}

export type LinearIssueWebhook = {
  action: "create" | "update";
  issueId: string;
  trigger: string;
};

/**
 * Reduces a Linear Issue webhook to a safe automation trigger. Assignment and
 * delegation remain an explicit, separate handoff path; do not let a policy
 * spawn a duplicate run for an issue the bot was just given directly.
 */
export function parseLinearIssueAutomationWebhook(
  rawBody: string,
  botUserId?: string,
): LinearIssueWebhook | null {
  let payload: unknown;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return null;
  }
  if (!isRecord(payload) || payload.type !== "Issue") return null;
  const action = payload.action;
  if (action !== "create" && action !== "update") return null;
  const data = isRecord(payload.data) ? payload.data : undefined;
  const issueId = stringValue(data?.id);
  if (!issueId) return null;
  const actor = isRecord(payload.actor) ? payload.actor : undefined;
  if (botUserId && stringValue(actor?.id) === botUserId) return null;
  if (
    botUserId &&
    (stringValue(data?.assigneeId) === botUserId ||
      stringValue(data?.delegateId) === botUserId)
  ) {
    return null;
  }
  const trigger =
    stringValue(data?.updatedAt) ??
    stringValue(data?.createdAt) ??
    action;
  return { action, issueId, trigger };
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}

function isRecord(value: unknown): value is JsonRecord {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

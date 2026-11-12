/**
 * Version 1 of the existing Console automation ingress. The version names the
 * current wire shape; adding a version field to live requests would require a
 * separate, coordinated rollout across Console and both bot services.
 */
export const AUTOMATION_INGRESS_CONTRACT_VERSION = 1;

type EventBase = {
  deduplication_key: string;
  event_action?: string;
  event_type: string;
  labels: string[];
};

export type GithubAutomationEventV1 = EventBase & {
  provider: "github";
  repository: string;
  subject_number: number;
  base_branch?: string;
  bot_owned?: boolean;
  created_by_bot?: boolean;
  continuation_authorized?: boolean;
  draft?: boolean;
  head_sha?: string;
  mentioned_bot?: boolean;
  review_requested_for_bot?: boolean;
};

export type LinearAutomationEventV1 = EventBase & {
  provider: "linear";
  linear_issue_id: string;
  linear_team_id: string;
  linear_issue_identifier?: string;
  linear_issue_url?: string;
  linear_project_id?: string;
  title?: string;
  description?: string;
  status?: string;
  blocked?: boolean;
  mentioned_bot?: boolean;
  updated_fields?: string[];
};

export type AutomationEventV1 = GithubAutomationEventV1 | LinearAutomationEventV1;

export type AutomationDecisionV1 = {
  actions: string[];
  decision: "act" | "ignored" | "observe";
  reason: string;
  session_key: string;
  workstream_id?: string;
  policy_id?: string;
};

export type ParsedAutomationDecisionV1 = {
  actions: string[];
  decision: "act" | "ignored" | "observe";
  policyId?: string;
  reason: string;
  sessionKey: string;
  workstreamId?: string;
  /** Provider-specific policy fields remain untrusted until their bot reads them. */
  fields: Record<string, unknown>;
};

/** Parse only the common fields accepted by both existing bots. */
export function parseAutomationDecisionV1(value: unknown): ParsedAutomationDecisionV1 | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const fields = value as Record<string, unknown>;
  const decision = stringValue(fields.decision);
  const sessionKey = stringValue(fields.session_key);
  if (!sessionKey || (decision !== "act" && decision !== "observe" && decision !== "ignored")) {
    return null;
  }
  return {
    actions: stringArray(fields.actions),
    decision,
    fields,
    policyId: stringValue(fields.policy_id),
    reason: stringValue(fields.reason) ?? "policy result",
    sessionKey,
    workstreamId: stringValue(fields.workstream_id),
  };
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}

type Fetcher = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

/** Send only an already verified, normalized event to Console's policy plane. */
export function submitAutomationEventV1(
  fetcher: Fetcher,
  baseUrl: string,
  ingressToken: string,
  event: AutomationEventV1,
): Promise<Response> {
  return fetcher(baseUrl.replace(/\/$/, "") + "/api/internal/automation_events", {
    body: JSON.stringify({ event }),
    headers: {
      Authorization: "Bearer " + ingressToken,
      "Content-Type": "application/json",
    },
    method: "POST",
  });
}

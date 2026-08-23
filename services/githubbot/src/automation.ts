import type { GithubbotFetch, GithubbotOptions } from "./types";
import { errorMessage, noopLogger, stringValue } from "./utils";

type JsonRecord = Record<string, unknown>;

export type GithubAutomationDecision = {
  actions: string[];
  autoMerge: boolean;
  decision: "act" | "ignored" | "observe";
  policyId?: string;
  reason: string;
  sessionKey: string;
  workstreamId?: string;
};

export type GithubAutomationEvent = {
  base_branch?: string;
  /** True only when Githubbot's own principal is assigned to the pull request. */
  bot_owned?: boolean;
  /** Derived by Console from a previously authorized durable PR workstream. */
  continuation_authorized?: boolean;
  deduplication_key: string;
  draft?: boolean;
  event_action?: string;
  event_type: string;
  head_sha?: string;
  labels: string[];
  provider: "github";
  repository: string;
  /** True only after Githubbot verifies a requested reviewer/team targets it. */
  review_requested_for_bot?: boolean;
  subject_number: number;
};

/**
 * Sends a compact, verified webhook summary to the Console automation service.
 * The Console is deliberately the policy/audit owner; githubbot continues to
 * own GitHub signature verification and execution. A missing or failed policy
 * lookup is fail-closed: existing explicit review/assignment behavior remains
 * available, but no newly configured automatic action is started.
 */
export async function evaluateGithubAutomation(
  options: GithubbotOptions,
  eventType: string,
  rawBody: string,
  deliveryId: string,
  enrich?: (event: GithubAutomationEvent) => Promise<GithubAutomationEvent>,
  associatedPrNumbers?: (repository: string, headSha: string) => Promise<number[]>,
): Promise<GithubAutomationDecision[]> {
  if (!options.automationApiUrl || !options.automationIngressToken) return [];
  const events = await normalizeGithubEvents(
    eventType,
    rawBody,
    deliveryId,
    associatedPrNumbers,
  );
  if (events.length === 0) return [];

  const results = await Promise.all(events.map(async (event) =>
    submitEvent(options, enrich ? await enrich(event) : event)
  ));
  return results.filter(
    (decision): decision is GithubAutomationDecision => decision !== null,
  );
}

async function normalizeGithubEvents(
  eventType: string,
  rawBody: string,
  deliveryId: string,
  associatedPrNumbers?: (repository: string, headSha: string) => Promise<number[]>,
): Promise<GithubAutomationEvent[]> {
  const payload = parseJson(rawBody);
  if (!payload) return [];
  const repository = repositoryName(payload);
  if (!repository || !deliveryId) return [];
  const eventAction = stringValue(payload.action);

  const pullRequest = isRecord(payload.pull_request) ? payload.pull_request : undefined;
  if (pullRequest) {
    const number = numberValue(pullRequest.number);
    if (number === undefined) return [];
    return [
      {
        base_branch: stringValue(isRecord(pullRequest.base) ? pullRequest.base.ref : undefined),
        deduplication_key: "github:" + deliveryId + ":" + number,
        draft: pullRequest.draft === true,
        event_action: eventAction,
        event_type: eventType,
        head_sha: stringValue(isRecord(pullRequest.head) ? pullRequest.head.sha : undefined),
        labels: labelNames(pullRequest.labels),
        provider: "github",
        repository,
        subject_number: number,
      },
    ];
  }

  // A legacy status payload only carries the head SHA. Resolve its associated
  // PRs through the verified GitHub client when the caller supplied one.
  if (eventType === "status") {
    const headSha = stringValue(payload.sha);
    if (!headSha || !associatedPrNumbers) return [];
    const numbers = await associatedPrNumbers(repository, headSha);
    return numbers.map((number) => ciAutomationEvent({
      deliveryId,
      eventAction,
      eventType,
      headSha,
      number,
      repository,
    }));
  }

  // CI lifecycle payloads may name one or more associated pull requests. Do
  // not guess when GitHub omitted that relationship: a policy with branch/label
  // gates must be evaluated against a concrete PR, and guessing would weaken
  // the fail-closed boundary.
  const ciNode =
    eventType === "check_run"
      ? payload.check_run
      : eventType === "check_suite"
        ? payload.check_suite
        : eventType === "workflow_run"
          ? payload.workflow_run
          : undefined;
  if (!isRecord(ciNode)) return [];
  const headSha = stringValue(ciNode.head_sha);
  const pullRequests = Array.isArray(ciNode.pull_requests)
    ? ciNode.pull_requests
    : [];
  const directEvents = pullRequests.flatMap((pr) => {
    if (!isRecord(pr)) return [];
    const number = numberValue(pr.number);
    return number === undefined
      ? []
      : [
          {
            base_branch: stringValue(isRecord(pr.base) ? pr.base.ref : undefined),
            deduplication_key: "github:" + deliveryId + ":" + number,
            draft: pr.draft === true,
            event_action: eventAction,
            event_type: eventType,
            head_sha: headSha,
            labels: labelNames(pr.labels),
            provider: "github" as const,
            repository,
            subject_number: number,
          },
        ];
  });
  if (directEvents.length > 0 || !headSha || !associatedPrNumbers) return directEvents;

  const numbers = await associatedPrNumbers(repository, headSha);
  return numbers.map((number) => ciAutomationEvent({
    deliveryId,
    eventAction,
    eventType,
    headSha,
    number,
    repository,
  }));
}

function ciAutomationEvent(input: {
  deliveryId: string;
  eventAction?: string;
  eventType: string;
  headSha: string;
  number: number;
  repository: string;
}): GithubAutomationEvent {
  return {
    deduplication_key: "github:" + input.deliveryId + ":" + input.number,
    event_action: input.eventAction,
    event_type: input.eventType,
    head_sha: input.headSha,
    labels: [],
    provider: "github",
    repository: input.repository,
    subject_number: input.number,
  };
}

async function submitEvent(
  options: GithubbotOptions,
  event: GithubAutomationEvent,
): Promise<GithubAutomationDecision | null> {
  const logger = options.logger ?? noopLogger;
  const fetcher: GithubbotFetch = options.fetch ?? globalThis.fetch;
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
      logger.warn("githubbot_automation_policy_lookup_failed", {
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
      autoMerge: data.auto_merge === true,
      decision,
      policyId: stringValue(data.policy_id),
      reason: stringValue(data.reason) ?? "policy result",
      sessionKey,
      workstreamId: stringValue(data.workstream_id),
    };
  } catch (error) {
    logger.warn("githubbot_automation_policy_lookup_failed", {
      error: errorMessage(error),
    });
    return null;
  }
}

function repositoryName(payload: JsonRecord): string | undefined {
  const repository = isRecord(payload.repository) ? payload.repository : undefined;
  return stringValue(repository?.full_name)?.toLowerCase();
}

function labelNames(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((label) => {
    const name = isRecord(label) ? stringValue(label.name) : undefined;
    return name ? [ name ] : [];
  });
}

function parseJson(value: string): JsonRecord | null {
  try {
    const parsed = JSON.parse(value);
    return isRecord(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}

function isRecord(value: unknown): value is JsonRecord {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

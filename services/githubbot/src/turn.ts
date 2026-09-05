import {
  harnessToChatSdkStream,
  type CodexAppServerToChatStreamOptions,
  type RendererEvent,
} from "@centaur/rendering";
import type { GitHubAdapter } from "@chat-adapter/github";
import type { Thread } from "chat";
import {
  buildFailedReplyBody,
  buildPublicCommentReply,
  buildWorkingReplyBody,
  CommentReplyCollector,
  type GithubPublicReply,
  type GithubWorkingReplyKind,
} from "./comment-bot";
import { runExclusive } from "./context";
import { resolveStickyProvider } from "./overrides";
import {
  executeSessionTurn,
  forwardToSessionApi,
  isRetryableSessionApiError,
  openSessionEventStream,
  sessionStreamError,
  startingStreamNotification,
} from "./session-api";
import type {
  ForwardSessionInput,
  GithubbotApiMessage,
  GithubbotExecuteSessionResponse,
  GithubbotOptions,
  GithubbotRendererSource,
  GithubbotThreadState,
  GithubbotTrace,
} from "./types";
import { errorMessage, noopLogger, traceLog } from "./utils";

const THREAD_TURN_MAX_RETRIES = 3;
const RENDER_RETRY_INITIAL_DELAY_MS = 250;
const RENDER_RETRY_MAX_DELAY_MS = 5_000;
const REVIEW_HUNK_MAX_CHARS = 4_000;

/**
 * Internal review profiles are started by Githubbot's policy orchestration,
 * never by asking another GitHub bot to review. Keep this guard in the prompt
 * that every conversational and management turn receives: a literal mention
 * such as `@codex review` can trigger an unrelated third-party automation and
 * create a repair/review loop outside Centaur's bounded epoch state.
 */
export const EXTERNAL_AI_REVIEWER_GUARD = [
  "External GitHub AI reviewer guard:",
  "- Centaur invokes its configured internal Codex and Claude reviewer profiles itself. Do not request, re-request, @-mention, or otherwise trigger an external AI reviewer through a GitHub comment, review request, or `gh pr edit --add-reviewer`. A human must explicitly choose and invoke any external reviewer.",
].join("\n");

/**
 * A non-negotiable evidence contract for code-changing PR work. It is shared
 * by direct PR conversations and lifecycle-managed PR work, so a custom
 * management prompt cannot reduce validation to a narrow test or turn a
 * screenshot into an unrendered artifact.
 */
export const PR_CHANGE_VERIFICATION_AND_EVIDENCE_GUARD = [
  "PR change verification and visual evidence:",
  "- Before pushing a code change, inspect the repository's documented development path and CI workflows. Try the documented whole-stack or local-application flow needed to exercise the affected behavior, rather than relying only on a narrow test. Follow existing scripts and setup instructions; do not invent a stack command or claim a full-stack result that did not run.",
  "- Run focused tests too. In the PR, distinguish a completed stack/preview check from focused checks and from anything blocked by missing dependencies, credentials, or environment access.",
  "- For a user-visible UI change, capture a real screenshot from the verified local or preview flow. Put it inline in the PR description or a PR comment as rendered Markdown (for example `![Verified flow](https://...)`). Do not leave it only as an attachment, local file, artifact, or bare link. Never fabricate a screenshot; if it cannot be safely published inline, say why in the PR.",
].join("\n");

/** Decoded GitHub thread key (mirrors the adapter's encodeThreadId formats). */
export type GithubThreadRef = {
  owner: string;
  repo: string;
  number: number;
  type: "pr" | "issue";
  reviewCommentId?: number;
};

/** The file/line/hunk a review-comment thread is anchored to. */
export type ReviewCommentContext = {
  path?: string;
  line?: number;
  diffHunk?: string;
};

/** A policy-authorized instruction that changes the PR turn from discussion to execution. */
export type GithubPrExecutionIntent = "resolve_conflict";

/** Accumulated result of one streamed agent turn. */
export type TurnResult = {
  failed: boolean;
  fallbackText: string;
  /**
   * A deliberately coarse failure category. It is safe to use for a bounded
   * model fallback decision, unlike raw provider error text which remains in
   * the durable Console execution record only.
   */
  failureKind?: TurnFailureKind;
};

export type TurnFailureKind =
  | "cancelled"
  | "credential"
  | "provider_unavailable"
  | "unsupported_capability"
  | "unknown";

/**
 * Builds the only public reply path shared by comment and body-mention turns.
 * Keep the summary-availability event here so both entry points provide the
 * same operational signal without logging any agent text.
 */
export function buildTurnPublicReply(
  options: GithubbotOptions,
  trace: GithubbotTrace,
  result: TurnResult,
): GithubPublicReply {
  const publicReply = result.failed
    ? { body: buildFailedReplyBody(), summaryAvailable: false }
    : buildPublicCommentReply({ fallback: result.fallbackText });
  if (!result.failed && !publicReply.summaryAvailable) {
    traceLog(options, "githubbot_public_summary_unavailable", trace, {
      terminal_result_available: Boolean(result.fallbackText),
    });
  }
  return publicReply;
}

const THREAD_KEY_PATTERN =
  /^github:([^/:]+)\/([^:]+):(?:issue:(\d+)|(\d+)(?::rc:(\d+))?)$/;

/**
 * Parse a `github:{owner}/{repo}:{number}` style thread key back into its parts.
 * Returns null for keys that don't match (e.g. the synthetic `github-review:…`
 * key, or a non-GitHub key).
 */
export function parseGithubThreadKey(threadKey: string): GithubThreadRef | null {
  const match = THREAD_KEY_PATTERN.exec(threadKey);
  if (!match) return null;
  const issueNumber = match[3];
  const number = Number(issueNumber ?? match[4]);
  if (!Number.isFinite(number)) return null;
  return {
    owner: match[1]!,
    repo: match[2]!,
    number,
    type: issueNumber ? "issue" : "pr",
    ...(match[5] ? { reviewCommentId: Number(match[5]) } : {}),
  };
}

/**
 * Pull the file/line/diff-hunk a review-comment message is anchored to out of the
 * adapter's raw message (`{type: "review_comment", comment}`). Returns undefined
 * for PR-conversation or issue messages.
 */
export function reviewCommentContextFromRaw(
  raw: unknown,
): ReviewCommentContext | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const record = raw as { type?: unknown; comment?: unknown };
  if (record.type !== "review_comment") return undefined;
  if (!record.comment || typeof record.comment !== "object") return undefined;
  const comment = record.comment as {
    path?: unknown;
    line?: unknown;
    diff_hunk?: unknown;
  };
  return {
    path: typeof comment.path === "string" ? comment.path : undefined,
    line: typeof comment.line === "number" ? comment.line : undefined,
    diffHunk:
      typeof comment.diff_hunk === "string" ? comment.diff_hunk : undefined,
  };
}

/**
 * Per-turn context header naming the PR/issue the thread maps to and how to
 * reply. The agent runs in a sandbox with `gh`/git, so it fetches the details
 * itself — this anchors it to the right subject. For a review-comment thread it
 * also carries the file/line and diff hunk the thread is pinned to, since that
 * location is the whole point of the thread.
 */
export function githubContextPreamble(
  threadKey: string,
  reviewComment?: ReviewCommentContext,
  executionIntent?: GithubPrExecutionIntent,
): string | undefined {
  const ref = parseGithubThreadKey(threadKey);
  if (!ref) return undefined;
  const subject = `${ref.owner}/${ref.repo}#${ref.number}`;

  if (ref.type === "issue") {
    return (
      `You are responding in the comment thread of GitHub issue ${subject}. ` +
      `Fetch the issue's details with the gh CLI in your sandbox (e.g. ` +
      `\`gh issue view ${ref.number}\`) for any context the comment doesn't ` +
      `give you. Your turn's final message is posted back as your reply here.`
    );
  }

  if (ref.reviewCommentId !== undefined) {
    const location = reviewComment?.path
      ? `\`${reviewComment.path}\`${reviewComment.line ? ` line ${reviewComment.line}` : ""}`
      : "a specific line";
    const hunk = reviewComment?.diffHunk
      ? `\n\nThe diff hunk this thread is anchored to:\n\n\`\`\`diff\n${truncate(reviewComment.diffHunk, REVIEW_HUNK_MAX_CHARS)}\n\`\`\``
      : "";
    return (
      `You are responding in a pull-request review-comment thread on ${subject}, ` +
      `pinned to ${location}. This is an independent thread scoped to that code ` +
      `location — keep your reply focused on it. Use the gh CLI and git in your ` +
      `sandbox to read the surrounding code and the full diff as needed. Your ` +
      `turn's final message is posted back as your reply in this thread.${hunk}`
    );
  }

  const repairDirective = executionIntent === "resolve_conflict"
    ? "\n\nThis is an explicit, authorized repair request. The PR is currently conflicted. " +
      "Resolve the merge conflict in the existing PR branch, validate it, then commit and push " +
      "the repair. Do not stop at diagnosis or merely describe a fix. Do not merge or deploy. " +
      "Only resolve it when the intended behavior is clear from both sides of the conflict, the " +
      "PR context, and verification. If the resolution is not straightforward — for example, " +
      "the two sides represent competing behavior or you cannot validate the result — do NOT " +
      "push or force-push a guess. Make the handoff conspicuous in the final `GITHUB_SUMMARY`: " +
      "set `Outcome: ⚠️ Human review needed — merge conflict`, name the affected area and the " +
      "decision a human must make, state what you tried, and @-mention a human maintainer when " +
      "one is known. Do not leave only a generic blocked message."
    : "";
  return (
    `You are responding in the main conversation thread of GitHub pull request ` +
    `${subject}. The comment alone may not be enough context, so fetch the PR ` +
    `before replying — use the gh CLI in your sandbox (e.g. \`gh pr view ` +
    `${ref.number}\`, \`gh pr diff ${ref.number}\`). Your turn's final message ` +
    `is posted back as your reply in this thread.${repairDirective}`
  );
}

/**
 * GitHub gets a concise, public result while Console retains execution detail.
 * This applies to every comment-driven turn even when the caller supplied its
 * own subject preamble.
 */
export function githubTurnPreamble(preamble?: string): string {
  const publicReplyContract = [
    "Public GitHub response contract:",
    "- An acknowledgement is already visible. Work silently; do not narrate intermediate reasoning, plans, commands, raw logs, or tool output in GitHub.",
    "- Keep detailed execution evidence in Console. Your terminal text must be exactly one concise block in this form (use one short factual sentence or phrase per field; use `None.` for a field with no relevant value):\nGITHUB_SUMMARY:\nOutcome: ...\nChanges: ...\nVerification: ...\nCI: ...\nNext: ...\nThe GitHub renderer turns a complete block into a compact Markdown update. For reviews, report the verdict and high-level next step only; keep code walkthroughs, command lines, hashes, timings, detailed nit lists, and baseline diagnosis in Console.",
    "- If you change code, inspect the repository CI workflow and run the closest local equivalent before pushing. Do not call CI green based only on a narrow test subset when a broader local equivalent is available.",
    "- When relevant and feasible, start the local app or preview needed to validate the change. After pushing, monitor checks for the new head; if a check fails because of your change, diagnose, fix, and verify it before finalizing. If you cannot run a check, name it and explain why.",
    PR_CHANGE_VERIFICATION_AND_EVIDENCE_GUARD,
    EXTERNAL_AI_REVIEWER_GUARD,
  ].join("\n");
  return [preamble, publicReplyContract].filter(Boolean).join("\n\n");
}

export async function reactSafe(
  adapter: GitHubAdapter,
  threadKey: string,
  messageId: string,
  emoji: string,
  logger: GithubbotOptions["logger"],
): Promise<void> {
  try {
    await adapter.addReaction(threadKey, messageId, emoji);
  } catch (error) {
    (logger ?? noopLogger).debug("githubbot_reaction_failed", {
      error: errorMessage(error),
    });
  }
}

/**
 * Run the create/append + execute + stream + collect core for one turn, with a
 * bounded retry on transient (cold-start) failures. Thread-agnostic: it operates
 * on the session API alone, so both the conversational path (which has a Chat
 * thread to post into) and the review path (which posts via the agent's own gh
 * calls) share it.
 */
export function runTurnStream(
  options: GithubbotOptions,
  forwardInput: ForwardSessionInput,
): Promise<TurnResult> {
  // Serialize turns targeting the same session so a conversational mention and a
  // lifecycle-driven management turn (both keyed to `github-manage:…`) can't run
  // concurrently in one sandbox and interleave git/push operations. Different
  // session keys still run in parallel.
  return runExclusive(forwardInput.threadId, () =>
    runTurnStreamInner(options, forwardInput),
  );
}

async function runTurnStreamInner(
  options: GithubbotOptions,
  forwardInput: ForwardSessionInput,
): Promise<TurnResult> {
  const logger = options.logger ?? noopLogger;
  for (let attempt = 0; attempt <= THREAD_TURN_MAX_RETRIES; attempt++) {
    try {
      // create + append (idempotent), then execute + stream.
      await forwardToSessionApi(
        options,
        { ...forwardInput, executeMessage: undefined, openStream: false },
        {},
      );
      const collector = new CommentReplyCollector();
      const fallback = new GithubRenderFallback();
      for await (const chunk of harnessToChatSdkStream(
        fallback.collectSource(streamSessionAfterHandoff(options, forwardInput)),
        rendererOptions(options),
      )) {
        collector.update(chunk);
      }
      return {
        failed: collector.failed || Boolean(fallback.error()),
        fallbackText: fallback.text(),
        ...(collector.failed || fallback.error()
          ? { failureKind: classifyTurnFailure(fallback.error()) }
          : {}),
      };
    } catch (error) {
      if (
        isRetryableSessionApiError(error) &&
        attempt < THREAD_TURN_MAX_RETRIES
      ) {
        traceLog(options, "githubbot_turn_stream_retry", forwardInput.trace, {
          retry_attempt: attempt + 1,
        });
        await sleep(renderRetryDelayMs(attempt));
        continue;
      }
      logger.warn("githubbot_turn_stream_failed", {
        error: errorMessage(error),
      });
      return {
        failed: true,
        fallbackText: "",
        failureKind: classifyTurnFailure(errorMessage(error)),
      };
    }
  }
  return {
    failed: true,
    fallbackText: "",
    failureKind: "unknown",
  };
}

/**
 * Runs one conversational agent turn on a thread's sandbox and posts the result
 * as a single comment. A 👀 reaction acks the triggering comment while the bot
 * works, then settles to 🚀 (done) or 😕 (failed). The answer streams into a
 * collector and posts once at the end — GitHub rate-limits comment edits, so v1
 * buffers rather than live-editing.
 */
export async function runSessionTurn(input: {
  adapter: GitHubAdapter;
  contextPreamble?: string;
  conversationName?: string;
  executeMessage: GithubbotApiMessage;
  options: GithubbotOptions;
  overrides: { harnessType?: string; model?: string; provider?: string };
  /** Comment to react to (👀 → 🚀/😕); the triggering comment, if any. */
  reactMessageId?: string;
  /**
   * Session/sandbox key, when it differs from the posting thread — e.g. an
   * owned PR's conversation mention runs in the PR's management session
   * (`github-manage:…`) for shared context but still posts to the
   * conversation thread. Defaults to `threadKey`.
   */
  sessionThreadKey?: string;
  thread: Thread<GithubbotThreadState>;
  threadKey: string;
  trace: GithubbotTrace;
  /** Make an authorized repair acknowledgement explicit without exposing work logs. */
  workingReplyKind?: GithubWorkingReplyKind;
}): Promise<void> {
  const {
    adapter,
    conversationName,
    executeMessage,
    options,
    overrides,
    reactMessageId,
    thread,
    threadKey,
    trace,
  } = input;
  const logger = options.logger ?? noopLogger;
  try {
    await thread.post(buildWorkingReplyBody(input.workingReplyKind));
  } catch (error) {
    logger.warn("githubbot_thread_acknowledgement_failed", {
      error: errorMessage(error),
    });
  }
  // The 👀 working ack is fired by the caller (handleMessage) before this turn's
  // setup so it lands instantly; here we only settle it to 🚀/😕 at the end.
  const threadState = (await thread.state) ?? {};
  const provider = resolveStickyProvider(threadState.provider, overrides);
  if (provider.update !== undefined) {
    // Commit the selection before execution so a bot/sandbox crash cannot lose
    // the provider needed to resume this Codex thread on the next turn.
    await thread.setState({ provider: provider.update });
  }
  let lastEventId = threadState.lastEventId ?? 0;
  const forwardInput: ForwardSessionInput = {
    afterEventId: lastEventId,
    contextPreamble: githubTurnPreamble(
      input.contextPreamble ?? githubContextPreamble(threadKey),
    ),
    conversationName,
    executeMessage,
    harnessType: overrides.harnessType,
    messages: [],
    model: overrides.model,
    provider: provider.provider,
    onEventId: (eventId) => {
      lastEventId = Math.max(lastEventId, eventId);
      forwardInput.afterEventId = lastEventId;
    },
    openStream: false,
    threadId: input.sessionThreadKey ?? threadKey,
    trace,
  };

  const result = await runTurnStream(options, forwardInput);
  await thread.setState({
    contextSeeded: true,
    historyForwarded: true,
    lastEventId,
  });
  const publicReply = buildTurnPublicReply(options, trace, result);
  const body = publicReply.body;
  try {
    await thread.post(body);
  } catch (error) {
    logger.warn("githubbot_thread_reply_failed", {
      error: errorMessage(error),
    });
  }
  if (reactMessageId) {
    await reactSafe(
      adapter,
      threadKey,
      reactMessageId,
      result.failed ? "confused" : "rocket",
      logger,
    );
  }
  traceLog(options, "githubbot_thread_turn_complete", trace, {
    chars: body.length,
    failed: result.failed,
    public_summary_available: publicReply.summaryAvailable,
    terminal_result_available: Boolean(result.fallbackText),
  });
}

/**
 * Captures the structured terminal result text. Raw provider output is never a
 * GitHub reply source: providers can encode their full work trace as prose.
 */
export class GithubRenderFallback {
  private terminalText = "";
  private terminalError = "";

  async *collectSource(
    stream: AsyncIterable<GithubbotRendererSource>,
  ): AsyncIterable<GithubbotRendererSource> {
    for await (const event of stream) {
      this.captureTerminalText(event);
      yield event;
    }
  }

  text(): string {
    return this.terminalText.trim();
  }

  error(): string {
    return this.terminalError.trim();
  }

  private captureTerminalText(event: GithubbotRendererSource): void {
    if (!event || typeof event !== "object") return;
    const eventKind = String(
      "eventKind" in event
        ? event.eventKind
        : "event" in event
          ? event.event
          : "",
    );
    const data =
      "data" in event && event.data && typeof event.data === "object"
        ? event.data
        : event;
    if (
      eventKind === "session.execution_failed" ||
      eventKind === "session.stream_error" ||
      eventKind === "session.execution_cancelled"
    ) {
      this.terminalError = terminalErrorText(data);
      return;
    }
    if (eventKind !== "session.execution_completed") return;
    const text = terminalResultText(data);
    if (text) this.terminalText = text;
  }
}

function terminalResultText(event: unknown): string {
  if (!event || typeof event !== "object") return "";
  for (const key of ["result", "result_text", "text", "final_text"]) {
    const value = (event as Record<string, unknown>)[key];
    if (typeof value !== "string") continue;
    const resultText = value.trim();
    if (resultText) return resultText;
  }
  return "";
}

function terminalErrorText(event: unknown): string {
  if (!event || typeof event !== "object") return "Execution failed";
  const error = (event as Record<string, unknown>).error;
  return typeof error === "string" && error.trim()
    ? error.trim()
    : "Execution failed";
}

/**
 * Permit automatic model fallback only for an exhausted provider transport or
 * an explicitly unsupported model/capability. Authentication failures,
 * cancellations, and all ambiguous failures remain visible for operators and
 * never silently change the reviewing identity.
 */
export function classifyTurnFailure(value: string | undefined): TurnFailureKind {
  const text = value?.toLowerCase() ?? "";
  if (!text) return "unknown";
  if (text.includes("cancelled")) return "cancelled";
  if (
    /\b(?:401|403)\b/.test(text) ||
    /(?:unauthori[sz]ed|forbidden|invalid api key|invalid token|credential)/.test(text)
  ) {
    return "credential";
  }
  if (
    /(?:not a multimodal model|unsupported (?:model|capability)|no endpoints? found|model .* not found|unknown model)/.test(text)
  ) {
    return "unsupported_capability";
  }
  if (
    /\b(?:408|425|429|500|502|503|504)\b/.test(text) ||
    /(?:timeout|timed out|overloaded|rate limit|temporarily unavailable|service unavailable|connection (?:reset|refused)|network error|fetch failed|econn(?:reset|refused)|dns|socket hang up)/.test(text)
  ) {
    return "provider_unavailable";
  }
  return "unknown";
}

async function* streamSessionAfterHandoff(
  options: GithubbotOptions,
  input: ForwardSessionInput,
  onExecutionStarted?: (
    execution: GithubbotExecuteSessionResponse,
  ) => Promise<void>,
): AsyncIterable<GithubbotRendererSource> {
  // The synthetic starting item primes the mapper's task state so answer deltas
  // stream without the pre-stream grace delay. Execute runs here, inside the
  // render stream, so a sandbox-spawn failure surfaces in the same render
  // rather than leaving the run looking alive forever (api-rs writes no event
  // if the spawn itself fails).
  yield startingStreamNotification(input.threadId);
  traceLog(options, "githubbot_stream_heartbeat_emitted", input.trace);

  if (input.executeMessage) {
    try {
      const execution = await executeSessionTurn(options, input);
      if (execution) {
        // Scope the event stream we open below to this execution.
        input.executionId = execution.execution_id;
        await onExecutionStarted?.(execution);
      }
    } catch (error) {
      traceLog(options, "githubbot_forward_failed", input.trace, {
        error: errorMessage(error),
      });
      if (isRetryableSessionApiError(error)) throw error;
      yield sessionStreamError(error);
      return;
    }
  }

  let stream: AsyncIterable<GithubbotRendererSource>;
  try {
    stream = await openSessionEventStream(options, input);
  } catch (error) {
    traceLog(options, "githubbot_forward_failed", input.trace, {
      error: errorMessage(error),
    });
    if (isRetryableSessionApiError(error)) throw error;
    yield sessionStreamError(error);
    return;
  }

  for await (const event of stream) yield event;
}

// Vestigial wrapper kept so call sites diff cleanly against slackbotv2, whose
// rendererOptions hooks onRendererEvent to update the Slack assistant title (no
// GitHub analog). Today it only forwards the configured mapper.
function rendererOptions(
  options: GithubbotOptions,
): CodexAppServerToChatStreamOptions {
  const mapper = options.mapper;
  return {
    ...mapper,
    // Some providers emit unphased assistant messages for interim narration.
    // Treat those as Console-only commentary; GitHub receives the terminal
    // completion payload rather than a raw execution transcript.
    unknownAgentMessagePhase: "commentary",
    async onRendererEvent(event: RendererEvent) {
      await mapper?.onRendererEvent?.(event);
    },
  };
}

function renderRetryDelayMs(attempt: number): number {
  return Math.min(
    RENDER_RETRY_INITIAL_DELAY_MS * 2 ** attempt,
    RENDER_RETRY_MAX_DELAY_MS,
  );
}

function truncate(text: string, maxChars: number): string {
  if (text.length <= maxChars) return text;
  return `${text.slice(0, maxChars)}\n…(truncated)`;
}

async function sleep(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

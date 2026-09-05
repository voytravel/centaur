import type { ChatSDKStreamChunk } from "@centaur/rendering";

// A Linear comment is a product surface, not an execution trace. Durable
// session events retain the detailed reasoning and tool activity for Console;
// Linear gets one short status and the final answer only.

const ANSWER_MAX_CHARS = 50_000;

export const WORKING_REPLY_BODY =
  "I’m assessing this issue and will post a concise result here.";

export const FAILED_REPLY_BODY =
  "⚠️ I couldn’t complete this run. The technical details are available in Centaur Console; retry or ask me to investigate.";

/**
 * True when the comment addresses the bot. Linear encodes a mention as the
 * mentioned profile's plain URL in the markdown body
 * (`https://linear.app/{ws}/profiles/{handle}`), not as `@name` text or the
 * user UUID. Match that handle first, then retain the user-id and typed-name
 * fallbacks for compatibility.
 */
export function commentMentionsBot(
  body: string,
  names: string[],
  markers: { botUserId?: string; profileHandle?: string } = {},
): boolean {
  if (
    markers.profileHandle &&
    body.includes(`/profiles/${markers.profileHandle}`)
  ) {
    return true;
  }
  if (markers.botUserId && body.includes(markers.botUserId)) return true;
  const haystack = body.toLowerCase();
  return names.some((name) => {
    const needle = name.trim().toLowerCase();
    return needle.length > 0 && haystack.includes(`@${needle}`);
  });
}

/**
 * Collects only terminal user-facing content. Task updates and plans are kept
 * in the durable execution event stream, but must never be copied into a
 * Linear comment where they would disclose chain-of-thought or shell commands.
 */
export class CommentReplyCollector {
  private answerText = "";
  private sawError = false;

  update(chunk: ChatSDKStreamChunk): void {
    if (chunk.type === "markdown_text") {
      this.answerText += chunk.text;
      return;
    }
    if (chunk.type === "task_update" && chunk.status === "error") {
      this.sawError = true;
    }
  }

  get answer(): string {
    return this.answerText.trim();
  }

  get failed(): boolean {
    return this.sawError;
  }
}

/** Builds the short initial status that is updated in place at completion. */
export function buildWorkingReplyBody(): string {
  return WORKING_REPLY_BODY;
}

/** Builds a final answer without appending execution, reasoning, or tool data. */
export function buildCommentReplyBody(input: {
  answer: string;
  fallback?: string;
}): string {
  const raw =
    input.answer.trim() ||
    input.fallback?.trim() ||
    "Execution completed, but no final text was captured.";
  return raw.length > ANSWER_MAX_CHARS
    ? `${raw.slice(0, ANSWER_MAX_CHARS).trimEnd()}\n[truncated]`
    : raw;
}

/**
 * Return a safe error to Linear. The concrete execution error remains in the
 * durable session record and service logs, where operators can diagnose it
 * without exposing credentials, provider details, or tool output to a thread.
 */
export function buildFailedReplyBody(): string {
  return FAILED_REPLY_BODY;
}

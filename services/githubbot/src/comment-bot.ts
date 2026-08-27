import type { ChatSDKStreamChunk } from "@centaur/rendering";

// Threads are king: a GitHub PR/issue comment thread maps to one Centaur
// sandbox/context. GitHub is a concise public outcome surface; Console is the
// durable execution record. In particular, do not carry task updates or model
// reasoning from the stream into a GitHub comment.

const ANSWER_MAX_CHARS = 8_000;
const INTERNAL_DETAILS_SECTION =
  /<details\b[^>]*>\s*<summary>\s*(?:chain\s+of\s+thought|thinking|reasoning|work\s+log|execution\s+log)\b[^<]*<\/summary>[\s\S]*?<\/details>\s*/gi;

/**
 * Accumulates the public final answer from a streamed run. Task updates are
 * deliberately not rendered to GitHub: they can contain tool commands and
 * execution detail that belongs in the durable Console record instead.
 */
export class CommentReplyCollector {
  private answerText = "";
  private sawError = false;
  private errorTextValue = "";

  update(chunk: ChatSDKStreamChunk): void {
    if (chunk.type === "markdown_text") {
      this.answerText += chunk.text;
      return;
    }
    if (chunk.type !== "task_update" || chunk.status !== "error") return;
    this.sawError = true;
    this.errorTextValue = [chunk.title, chunk.output ?? chunk.details]
      .filter(Boolean)
      .join("\n");
  }

  get answer(): string {
    return this.answerText.trim();
  }

  get failed(): boolean {
    return this.sawError;
  }

  get errorText(): string {
    return this.errorTextValue;
  }
}

/**
 * A short acknowledgement posted before a potentially long-lived sandbox turn.
 * It establishes the public contract without narrating the execution itself.
 */
export function buildWorkingReplyBody(): string {
  return "I’m on it. I’ll inspect the request, reproduce relevant failures locally, run the closest CI-equivalent checks, and report the verified outcome here.";
}

/**
 * Composes the final public comment. Prefer the terminal result because it is
 * the harness's concise completion payload; streamed text may include
 * intermediary narration from providers that do not label message phases.
 */
export function buildCommentReplyBody(input: {
  answer: string;
  fallback?: string;
}): string {
  const raw =
    input.fallback?.trim() ||
    input.answer.trim() ||
    "Execution completed, but no final text was captured.";
  const answer =
    raw.replace(INTERNAL_DETAILS_SECTION, "").trim() ||
    "Execution completed, but no final text was captured.";
  return answer.length > ANSWER_MAX_CHARS
    ? answer.slice(0, ANSWER_MAX_CHARS).trimEnd() + "\n[truncated]"
    : answer;
}

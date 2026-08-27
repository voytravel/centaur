import type { ChatSDKStreamChunk } from "@centaur/rendering";

// Threads are king: a GitHub PR/issue comment thread maps to one Centaur
// sandbox/context. GitHub is a concise public outcome surface; Console is the
// durable execution record. In particular, do not carry task updates or model
// reasoning from the stream into a GitHub comment.

const PUBLIC_SUMMARY_MAX_CHARS = 2_000;
const PUBLIC_SUMMARY_MAX_LINES = 8;
const PUBLIC_SUMMARY_MARKER = /^\s*GITHUB_SUMMARY\s*:\s*/im;
const INTERNAL_DETAILS_SECTION =
  /<details\b[^>]*>\s*<summary>\s*(?:chain\s+of\s+thought|thinking|reasoning|work\s+log|execution\s+log)\b[^<]*<\/summary>[\s\S]*?<\/details>\s*/gi;
const EXECUTION_TRANSCRIPT_MARKERS =
  /<details\b|<summary\b|\b(?:chain\s+of\s+thought|command execution|tool output|raw log|execution log)\b|(?:^|\n)\s*(?:let me|i need to|i'll|i’ll|now i'll|now i’ll|first,? let me|plan(?:'|’)s clear)\b/im;
const MISSING_PUBLIC_SUMMARY =
  "Execution completed, but a concise verified summary was unavailable. Review the latest PR commit and checks; Centaur Console has the detailed record.";
const FAILED_PUBLIC_SUMMARY =
  "⚠️ The execution ended before a verified outcome could be posted. Review the latest PR commits and checks; Centaur Console has the detailed diagnostic record.";

/**
 * Accumulates the public final answer from a streamed run. Task updates are
 * deliberately not rendered to GitHub: they can contain tool commands and
 * execution detail that belongs in the durable Console record instead.
 */
export class CommentReplyCollector {
  private sawError = false;

  update(chunk: ChatSDKStreamChunk): void {
    // Markdown chunks are deliberately ignored. Some providers classify their
    // entire work trace as assistant prose, so treating this stream as a final
    // answer is a chain-of-thought disclosure bug. The structured terminal
    // result is captured separately by GithubRenderFallback.
    if (chunk.type === "markdown_text") return;
    if (chunk.type !== "task_update" || chunk.status !== "error") return;
    this.sawError = true;
  }

  get answer(): string {
    return "";
  }

  get failed(): boolean {
    return this.sawError;
  }

  get errorText(): string {
    // Do not surface command/tool diagnostics in a public comment. Callers
    // use this only for observability; the public failure body is fixed text.
    return this.sawError ? "agent task reported an error" : "";
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
  // A provider may put hidden work narration in either stream. Only accept an
  // explicitly-delimited, compact final summary. If the harness cannot supply
  // one, fail closed to a truthful status note rather than leaking a trace.
  for (const candidate of [input.fallback, input.answer]) {
    const summary = extractPublicSummary(candidate);
    if (summary) return summary;
  }
  return MISSING_PUBLIC_SUMMARY;
}

/** Fixed public error text; Console remains the diagnostic surface. */
export function buildFailedReplyBody(): string {
  return FAILED_PUBLIC_SUMMARY;
}

function extractPublicSummary(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const marker = PUBLIC_SUMMARY_MARKER.exec(value);
  if (!marker || marker.index === undefined) return undefined;
  const summary = value
    .slice(marker.index + marker[0].length)
    .replace(INTERNAL_DETAILS_SECTION, "")
    .trim();
  if (!summary || summary.length > PUBLIC_SUMMARY_MAX_CHARS) return undefined;
  if (summary.split(/\r?\n/).filter((line) => line.trim()).length > PUBLIC_SUMMARY_MAX_LINES) {
    return undefined;
  }
  if (EXECUTION_TRANSCRIPT_MARKERS.test(summary)) return undefined;
  return summary;
}

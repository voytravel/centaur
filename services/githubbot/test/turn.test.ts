import { describe, expect, test } from "bun:test";
import {
  classifyTurnFailure,
  buildTurnPublicReply,
  GithubRenderFallback,
  githubContextPreamble,
  githubTurnPreamble,
  parseGithubThreadKey,
  reviewCommentContextFromRaw,
} from "../src/turn";
import type { GithubbotOptions } from "../src/types";

describe("parseGithubThreadKey", () => {
  test("parses a PR-level thread key", () => {
    expect(parseGithubThreadKey("github:0xSplits/centaur:123")).toEqual({
      owner: "0xSplits",
      repo: "centaur",
      number: 123,
      type: "pr",
    });
  });

  test("parses an issue thread key", () => {
    expect(parseGithubThreadKey("github:0xSplits/centaur:issue:42")).toEqual({
      owner: "0xSplits",
      repo: "centaur",
      number: 42,
      type: "issue",
    });
  });

  test("parses a review-comment thread key", () => {
    expect(
      parseGithubThreadKey("github:0xSplits/centaur:123:rc:99887766"),
    ).toEqual({
      owner: "0xSplits",
      repo: "centaur",
      number: 123,
      type: "pr",
      reviewCommentId: 99887766,
    });
  });

  test("returns null for non-github / malformed / synthetic keys", () => {
    expect(parseGithubThreadKey("linear:abc:c:def")).toBeNull();
    expect(parseGithubThreadKey("github:no-repo:1")).toBeNull();
    expect(parseGithubThreadKey("github:owner/repo:notanumber")).toBeNull();
    // The isolated review/issue-work/management thread keys are intentionally
    // not postable github keys.
    expect(parseGithubThreadKey("github-review:0xSplits/centaur:7")).toBeNull();
    expect(parseGithubThreadKey("github-issue:0xSplits/centaur:7")).toBeNull();
    expect(parseGithubThreadKey("github-manage:0xSplits/centaur:7")).toBeNull();
  });
});

describe("reviewCommentContextFromRaw", () => {
  test("extracts path/line/hunk from a review_comment raw message", () => {
    expect(
      reviewCommentContextFromRaw({
        type: "review_comment",
        comment: {
          path: "src/index.ts",
          line: 42,
          diff_hunk: "@@ -1 +1 @@\n-old\n+new",
        },
      }),
    ).toEqual({
      path: "src/index.ts",
      line: 42,
      diffHunk: "@@ -1 +1 @@\n-old\n+new",
    });
  });

  test("returns undefined for non-review-comment messages", () => {
    expect(reviewCommentContextFromRaw({ type: "issue_comment" })).toBeUndefined();
    expect(reviewCommentContextFromRaw(null)).toBeUndefined();
    expect(reviewCommentContextFromRaw("nope")).toBeUndefined();
  });
});

describe("githubContextPreamble", () => {
  test("PR conversation: names the main thread and tells it to fetch the PR", () => {
    const preamble = githubContextPreamble("github:0xSplits/centaur:123");
    expect(preamble).toContain("main conversation thread");
    expect(preamble).toContain("0xSplits/centaur#123");
    expect(preamble).toContain("gh pr diff 123");
  });

  test("issue thread: uses issue wording", () => {
    const preamble = githubContextPreamble("github:0xSplits/centaur:issue:42");
    expect(preamble).toContain("issue 0xSplits/centaur#42");
    expect(preamble).toContain("gh issue view 42");
  });

  test("review-comment thread: anchors to the file/line and includes the hunk", () => {
    const preamble = githubContextPreamble(
      "github:0xSplits/centaur:123:rc:55",
      { path: "src/turn.ts", line: 88, diffHunk: "@@ -1 +1 @@\n+x" },
    );
    expect(preamble).toContain("review-comment thread");
    expect(preamble).toContain("`src/turn.ts` line 88");
    expect(preamble).toContain("@@ -1 +1 @@");
  });

  test("returns undefined for an unparseable key", () => {
    expect(githubContextPreamble("not-a-github-key")).toBeUndefined();
  });

  test("adds a concise public-response and CI-verification contract", () => {
    const preamble = githubTurnPreamble("Inspect the pull request.");
    expect(preamble).toContain("Public GitHub response contract:");
    expect(preamble).toContain("do not narrate intermediate reasoning");
    expect(preamble).toContain("compact Markdown update");
    expect(preamble).toContain("detailed nit lists");
    expect(preamble).toContain("closest local equivalent");
    expect(preamble).toContain("monitor checks for the new head");
  });
});

describe("GithubRenderFallback", () => {
  test("captures the canonical terminal result for the public reply", async () => {
    const fallback = new GithubRenderFallback();
    async function* source() {
      yield {
        eventKind: "session.execution_completed",
        data: { result_text: "Pushed the fix; CI is running." },
      };
    }

    const forwarded: unknown[] = [];
    for await (const event of fallback.collectSource(source())) {
      forwarded.push(event);
    }

    expect(forwarded).toHaveLength(1);
    expect(fallback.text()).toBe("Pushed the fix; CI is running.");
  });
});

describe("classifyTurnFailure", () => {
  test("permits fallback only for provider or capability failures", () => {
    expect(classifyTurnFailure("HTTP 503 Service Unavailable")).toBe("provider_unavailable");
    expect(classifyTurnFailure("TypeError: fetch failed")).toBe("provider_unavailable");
    expect(classifyTurnFailure("glm-5.3 is not a multimodal model")).toBe("unsupported_capability");
  });

  test("keeps credential, cancellation, and ambiguous failures fail-closed", () => {
    expect(classifyTurnFailure("401 Unauthorized: invalid API key")).toBe("credential");
    expect(classifyTurnFailure("execution cancelled by caller")).toBe("cancelled");
    expect(classifyTurnFailure("unexpected result")).toBe("unknown");
  });
});

describe("buildTurnPublicReply", () => {
  test("records a missing structured summary without logging its content", () => {
    const entries: Array<{ event: string; fields: Record<string, unknown> }> = [];
    const logger = {
      debug: () => undefined,
      info(event: string, fields: Record<string, unknown>) {
        entries.push({ event, fields });
      },
      warn: () => undefined,
      error: () => undefined,
      child: () => logger,
    };
    const options = {
      apiUrl: "http://console.test",
      logger,
      webhookSecret: "test",
    } satisfies GithubbotOptions;
    const reply = buildTurnPublicReply(
      options,
      {
        includeContext: false,
        messageId: "message-1",
        mode: "execute",
        openStream: true,
        startedAtMs: 0,
        threadId: "github:owner/repo:1",
      },
      { failed: false, fallbackText: "unmarked terminal result" },
    );

    expect(reply.summaryAvailable).toBe(false);
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatchObject({
      event: "githubbot_public_summary_unavailable",
      fields: { terminal_result_available: true },
    });
    expect(JSON.stringify(entries)).not.toContain("unmarked terminal result");
  });
});

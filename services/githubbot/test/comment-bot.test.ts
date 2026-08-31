import { describe, expect, test } from "bun:test";
import {
  buildPublicCommentReply,
  buildWorkingReplyBody,
  CommentReplyCollector,
} from "../src/comment-bot";

describe("GitHub public reply rendering", () => {
  test("keeps task activity out of the public reply", () => {
    const collector = new CommentReplyCollector();
    collector.update({ type: "markdown_text", text: "Let me inspect this first." });
    collector.update({
      type: "task_update",
      id: "command-1",
      title: "Command execution",
      status: "complete",
      details: "git push origin branch",
    });

    expect(
      buildPublicCommentReply({}).body,
    ).toContain("concise verified summary was unavailable");
  });

  test("renders a complete terminal contract as a scannable Markdown update", () => {
    expect(
      buildPublicCommentReply({
        fallback:
          "GITHUB_SUMMARY:\nOutcome: Fixed the conflict. Changes: Pushed one commit. Verification: Full local suite passed. CI: Running. Next: Monitor checks.",
      }),
    ).toMatchObject({
      body:
        "### Centaur update\n\n- **Outcome:** Fixed the conflict.\n- **Changes:** Pushed one commit.\n- **Verification:** Full local suite passed.\n- **CI:** Running.\n- **Next:** Monitor checks.",
    });
  });

  test("keeps a concise partial terminal summary backwards-compatible", () => {
    expect(
      buildPublicCommentReply({ fallback: "GITHUB_SUMMARY:\nOutcome: Completed." }),
    ).toMatchObject({ body: "Outcome: Completed." });
  });

  test("fails closed rather than publishing an unmarked execution transcript", () => {
    expect(
      buildPublicCommentReply({
        fallback: "The log shows an error. Let me grep the run log.",
      }).body,
    ).toContain("concise verified summary was unavailable");
  });

  test("rejects a marked block that still contains process narration", () => {
    expect(
      buildPublicCommentReply({
        fallback:
          "GITHUB_SUMMARY:\nOutcome: Fixed it.\nLet me now explain every command I ran.",
      }).body,
    ).toContain("concise verified summary was unavailable");
  });

  test("retains the observed Plan's clear transcript backstop", () => {
    expect(
      buildPublicCommentReply({
        fallback: "GITHUB_SUMMARY:\nPlan's clear, let me start the work.",
      }).body,
    ).toContain("concise verified summary was unavailable");
  });

  test("reports missing structured summaries for operational rate monitoring", () => {
    expect(buildPublicCommentReply({}).summaryAvailable).toBe(false);
    expect(
      buildPublicCommentReply({
        fallback: "GITHUB_SUMMARY:\nOutcome: Completed.",
      }),
    ).toMatchObject({ summaryAvailable: true });
  });

  test("acknowledges the verification contract without exposing execution detail", () => {
    const body = buildWorkingReplyBody();
    expect(body).toContain("carry out the requested work");
    expect(body).toContain("verify it locally");
    expect(body).not.toContain("Command execution");
  });

  test("makes an explicit PR repair acknowledgement action-oriented", () => {
    const body = buildWorkingReplyBody("repair");
    expect(body).toContain("resolving the requested PR repair");
    expect(body).toContain("make and push");
    expect(body).not.toContain("inspect the request");
  });
});

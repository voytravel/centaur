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

  test("renders only an explicitly marked concise terminal outcome", () => {
    expect(
      buildPublicCommentReply({
        fallback:
          "GITHUB_SUMMARY:\nOutcome: Fixed the conflict.\nChanges: Pushed one commit.\nVerification: Full local suite passed.\nCI: Running.\nNext: Monitor checks.",
      }),
    ).toMatchObject({
      body:
        "Outcome: Fixed the conflict.\nChanges: Pushed one commit.\nVerification: Full local suite passed.\nCI: Running.\nNext: Monitor checks.",
    });
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
    expect(body).toContain("reproduce relevant failures locally");
    expect(body).toContain("CI-equivalent checks");
    expect(body).not.toContain("Command execution");
  });
});

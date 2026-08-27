import { describe, expect, test } from "bun:test";
import {
  buildCommentReplyBody,
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

    expect(collector.answer).toBe("");
    expect(
      buildCommentReplyBody({ answer: collector.answer }),
    ).toContain("concise verified summary was unavailable");
  });

  test("renders only an explicitly marked concise terminal outcome", () => {
    expect(
      buildCommentReplyBody({
        answer: "Let me inspect this first.",
        fallback:
          "GITHUB_SUMMARY:\nOutcome: Fixed the conflict.\nChanges: Pushed one commit.\nVerification: Full local suite passed.\nCI: Running.\nNext: Monitor checks.",
      }),
    ).toBe(
      "Outcome: Fixed the conflict.\nChanges: Pushed one commit.\nVerification: Full local suite passed.\nCI: Running.\nNext: Monitor checks.",
    );
  });

  test("fails closed rather than publishing an unmarked execution transcript", () => {
    expect(
      buildCommentReplyBody({
        answer:
          "Let me inspect this first.\nCommand execution: gh pr checks 426\nNow I will fix it.",
        fallback: "The log shows an error. Let me grep the run log.",
      }),
    ).toContain("concise verified summary was unavailable");
  });

  test("rejects a marked block that still contains process narration", () => {
    expect(
      buildCommentReplyBody({
        answer: "",
        fallback:
          "GITHUB_SUMMARY:\nOutcome: Fixed it.\nLet me now explain every command I ran.",
      }),
    ).toContain("concise verified summary was unavailable");
  });

  test("acknowledges the verification contract without exposing execution detail", () => {
    const body = buildWorkingReplyBody();
    expect(body).toContain("reproduce relevant failures locally");
    expect(body).toContain("CI-equivalent checks");
    expect(body).not.toContain("Command execution");
  });
});

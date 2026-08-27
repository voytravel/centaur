import { describe, expect, test } from "bun:test";
import {
  buildCommentReplyBody,
  buildWorkingReplyBody,
  CommentReplyCollector,
} from "../src/comment-bot";

describe("GitHub public reply rendering", () => {
  test("keeps task activity out of the public reply", () => {
    const collector = new CommentReplyCollector();
    collector.update({ type: "markdown_text", text: "Fixed the conflict." });
    collector.update({
      type: "task_update",
      id: "command-1",
      title: "Command execution",
      status: "complete",
      details: "git push origin branch",
    });

    expect(collector.answer).toBe("Fixed the conflict.");
    expect(
      buildCommentReplyBody({ answer: collector.answer }),
    ).toBe("Fixed the conflict.");
  });

  test("prefers the terminal outcome and removes accidental reasoning sections", () => {
    expect(
      buildCommentReplyBody({
        answer: "Let me inspect this first.",
        fallback:
          "Pushed the fix and the full local suite passed.\n\n<details>\n<summary>Chain of thought</summary>\n\n- command output\n</details>",
      }),
    ).toBe("Pushed the fix and the full local suite passed.");
  });

  test("acknowledges the verification contract without exposing execution detail", () => {
    const body = buildWorkingReplyBody();
    expect(body).toContain("reproduce relevant failures locally");
    expect(body).toContain("CI-equivalent checks");
    expect(body).not.toContain("Command execution");
  });
});

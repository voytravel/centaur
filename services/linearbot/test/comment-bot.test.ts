import { describe, expect, it } from "bun:test";
import {
  buildCommentReplyBody,
  buildFailedReplyBody,
  buildWorkingReplyBody,
  CommentReplyCollector,
  FAILED_REPLY_BODY,
  WORKING_REPLY_BODY,
} from "../src/comment-bot";
import type { ChatSDKStreamChunk } from "@centaur/rendering";

function command(details: string): ChatSDKStreamChunk {
  return {
    type: "task_update",
    id: "cmd-1",
    title: "Command execution",
    status: "complete",
    details,
  };
}

describe("CommentReplyCollector", () => {
  it("keeps final markdown while discarding task and reasoning details", () => {
    const collector = new CommentReplyCollector();
    collector.update(command("```sh\nprintenv | grep API_KEY\n```"));
    collector.update({
      type: "plan_update",
      title: "Inspect the provider configuration",
    });
    collector.update({ type: "markdown_text", text: "The fix is ready." });

    expect(collector.answer).toBe("The fix is ready.");
    expect(buildCommentReplyBody({ answer: collector.answer })).not.toContain(
      "API_KEY",
    );
    expect(buildCommentReplyBody({ answer: collector.answer })).not.toContain(
      "Inspect the provider",
    );
  });

  it("records a terminal task failure without retaining its raw detail", () => {
    const collector = new CommentReplyCollector();
    collector.update({
      type: "task_update",
      id: "provider-error",
      title: "Provider request",
      status: "error",
      output: "unexpected status 401 with bearer token details",
    });

    expect(collector.failed).toBe(true);
    expect(buildFailedReplyBody()).toBe(FAILED_REPLY_BODY);
    expect(buildFailedReplyBody()).not.toContain("401");
    expect(buildFailedReplyBody()).not.toContain("token");
  });
});

describe("Linear reply bodies", () => {
  it("uses one concise working status", () => {
    expect(buildWorkingReplyBody()).toBe(WORKING_REPLY_BODY);
    expect(buildWorkingReplyBody()).not.toContain("Thinking");
  });

  it("returns only the final answer", () => {
    const body = buildCommentReplyBody({ answer: "About a day." });
    expect(body).toBe("About a day.");
    expect(body).not.toContain("Chain of thought");
    expect(body).not.toContain(">>>");
  });
});

import { describe, expect, test } from "bun:test";
import { DEFAULT_ISSUE_PROMPT } from "../src/issue-prompt";

describe("DEFAULT_ISSUE_PROMPT", () => {
  test("requires visual evidence to be inline in the pull request", () => {
    expect(DEFAULT_ISSUE_PROMPT).toContain(
      "Embed the screenshot inline as Markdown in the PR description",
    );
    expect(DEFAULT_ISSUE_PROMPT).toContain(
      "Do not leave a screenshot as a standalone attachment",
    );
  });
});

import { describe, expect, test } from "bun:test";
import { evaluateGithubAutomation } from "../src/automation";
import type { GithubbotOptions } from "../src/types";

function options(overrides: Partial<GithubbotOptions> = {}): GithubbotOptions {
  return {
    apiUrl: "http://api",
    automationApiUrl: "http://console",
    automationIngressToken: "automation-token",
    fetch: async () =>
      new Response(
        JSON.stringify({
          data: {
            actions: [ "review" ],
            auto_merge: false,
            decision: "act",
            reason: "policy authorizes automation",
            session_key: "github-manage:acme/widgets:9",
          },
        }),
        { status: 200 },
      ),
    token: "github-token",
    webhookSecret: "webhook-secret",
    ...overrides,
  };
}

describe("evaluateGithubAutomation", () => {
  test("normalizes a PR event and returns the Console decision", async () => {
    let requestBody = "";
    const decisions = await evaluateGithubAutomation(
      options({
        fetch: async (_url, init) => {
          requestBody = String(init?.body);
          return new Response(
            JSON.stringify({
              data: {
                actions: [ "review" ],
                auto_merge: false,
                decision: "act",
                reason: "policy authorizes automation",
                session_key: "github-manage:acme/widgets:9",
              },
            }),
          );
        },
      }),
      "pull_request",
      JSON.stringify({
        action: "opened",
        pull_request: {
          base: { ref: "main" },
          draft: false,
          head: { sha: "abc" },
          labels: [ { name: "agent-ok" } ],
          number: 9,
        },
        repository: { full_name: "Acme/Widgets" },
      }),
      "delivery-1",
    );

    expect(decisions).toEqual([
      expect.objectContaining({
        actions: [ "review" ],
        decision: "act",
        sessionKey: "github-manage:acme/widgets:9",
      }),
    ]);
    expect(JSON.parse(requestBody).event).toMatchObject({
      deduplication_key: "github:delivery-1:9",
      repository: "acme/widgets",
      subject_number: 9,
    });
  });

  test("fails closed when the policy client is not configured", async () => {
    const decisions = await evaluateGithubAutomation(
      options({ automationIngressToken: undefined }),
      "pull_request",
      "{}",
      "delivery-2",
    );

    expect(decisions).toEqual([]);
  });

  test("resolves a legacy status webhook to its associated pull request", async () => {
    const decisions = await evaluateGithubAutomation(
      options(),
      "status",
      JSON.stringify({
        repository: { full_name: "acme/widgets" },
        sha: "abc123",
        state: "success",
      }),
      "delivery-status",
      undefined,
      async (repository, headSha) => {
        expect(repository).toBe("acme/widgets");
        expect(headSha).toBe("abc123");
        return [ 9 ];
      },
    );

    expect(decisions).toHaveLength(1);
    expect(decisions[0]).toMatchObject({ sessionKey: "github-manage:acme/widgets:9" });
  });
});

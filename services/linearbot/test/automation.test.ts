import { describe, expect, test } from "bun:test";
import {
  evaluateLinearAutomation,
  parseLinearIssueAutomationWebhook,
} from "../src/automation";
import type { LinearbotOptions } from "../src/types";

function options(overrides: Partial<LinearbotOptions> = {}): LinearbotOptions {
  return {
    apiUrl: "http://api",
    automationApiUrl: "http://console",
    automationIngressToken: "automation-token",
    linearWebhookSecret: "webhook-secret",
    ...overrides,
  };
}

describe("parseLinearIssueAutomationWebhook", () => {
  test("accepts a human issue update and excludes a direct bot assignment", () => {
    expect(
      parseLinearIssueAutomationWebhook(
        JSON.stringify({
          action: "update",
          data: { id: "issue-1", updatedAt: "2026-08-23T00:00:00Z" },
          type: "Issue",
        }),
        "bot-1",
      ),
    ).toEqual({
      action: "update",
      issueId: "issue-1",
      trigger: "2026-08-23T00:00:00Z",
    });

    expect(
      parseLinearIssueAutomationWebhook(
        JSON.stringify({
          action: "update",
          data: { assigneeId: "bot-1", id: "issue-1" },
          type: "Issue",
        }),
        "bot-1",
      ),
    ).toBeNull();
  });
});

describe("evaluateLinearAutomation", () => {
  test("returns the mapped repository and reviewer routing from Console", async () => {
    const result = await evaluateLinearAutomation(
      options({
        fetch: async () =>
          new Response(
            JSON.stringify({
              data: {
                actions: [ "implement_issue" ],
                decision: "act",
                github_repository: "acme/widgets",
                move_to_in_progress: true,
                reason: "policy authorizes automation",
                reviewer_logins: [ "octocat" ],
                reviewer_team_slugs: [ "platform" ],
                session_key: "linear:issue-1",
              },
            }),
          ),
      }),
      {
        deduplication_key: "linear:issue-1:v1",
        event_action: "update",
        event_type: "Issue",
        labels: [],
        linear_issue_id: "issue-1",
        linear_team_id: "team-1",
        provider: "linear",
        status: "Ready",
        title: "Ship it",
      },
    );

    expect(result).toEqual(
      expect.objectContaining({
        githubRepository: "acme/widgets",
        reviewerLogins: [ "octocat" ],
        reviewerTeamSlugs: [ "platform" ],
        sessionKey: "linear:issue-1",
      }),
    );
  });
});

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

  test("carries Linear's verified update delta for transition policies", () => {
    expect(
      parseLinearIssueAutomationWebhook(
        JSON.stringify({
          action: "update",
          data: { id: "issue-1", updatedAt: "2026-08-23T00:00:00Z" },
          type: "Issue",
          updatedFrom: { stateId: "old-state", title: "Old title" },
        }),
      ),
    ).toEqual({
      action: "update",
      issueId: "issue-1",
      trigger: "2026-08-23T00:00:00Z",
      updatedFields: [ "stateId", "title" ],
    });
  });
});

describe("evaluateLinearAutomation", () => {
  test("forwards a verified manual mention as a distinct policy action", async () => {
    let requestBody = "";
    const result = await evaluateLinearAutomation(
      options({
        fetch: async (_url, init) => {
          requestBody = String(init?.body);
          return Response.json({
            data: {
              actions: [ "respond_to_mention" ],
              decision: "act",
              github_repository: "acme/widgets",
              move_to_in_progress: true,
              reason: "policy authorizes automation",
              reviewer_logins: [],
              reviewer_team_slugs: [],
              session_key: "linear:issue-1",
            },
          });
        },
      }),
      {
        deduplication_key: "linear:manual-mention:issue-1:comment-1",
        event_action: "manual_mention",
        event_type: "Issue",
        labels: [ "agent:ready" ],
        linear_issue_id: "issue-1",
        linear_team_id: "team-1",
        mentioned_bot: true,
        provider: "linear",
        status: "Ready",
        title: "Ship it",
      },
    );

    expect(result).toMatchObject({
      actions: [ "respond_to_mention" ],
      decision: "act",
      sessionKey: "linear:issue-1",
    });
    expect(JSON.parse(requestBody).event).toMatchObject({
      event_action: "manual_mention",
      linear_issue_id: "issue-1",
      mentioned_bot: true,
    });
  });

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
                preview_label: "preview",
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
        previewLabel: "preview",
        reviewerLogins: [ "octocat" ],
        reviewerTeamSlugs: [ "platform" ],
        sessionKey: "linear:issue-1",
      }),
    );
  });
});

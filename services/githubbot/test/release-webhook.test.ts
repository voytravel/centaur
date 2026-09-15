import { describe, expect, test } from "bun:test";
import { forwardGithubReleaseWebhook } from "../src/release-webhook";
import type { GithubbotOptions } from "../src/types";

function options(overrides: Partial<GithubbotOptions> = {}): GithubbotOptions {
  return {
    apiUrl: "http://centaur-api-rs:8080",
    releaseWebhookSlug: "production-release-announcement",
    token: "github-token",
    webhookSecret: "webhook-secret",
    ...overrides,
  };
}

const successfulPayload = JSON.stringify({
  deployment: { id: 42 },
  deployment_status: { id: 43, state: "success" },
  repository: { full_name: "acme/widgets" },
});

describe("forwardGithubReleaseWebhook", () => {
  test("forwards the untouched successful receipt and GitHub verification headers", async () => {
    let requestUrl = "";
    let request: RequestInit | undefined;
    const result = await forwardGithubReleaseWebhook(
      options({
        fetch: async (url, init) => {
          requestUrl = String(url);
          request = init;
          return Response.json({ run_id: "run-1" }, { status: 202 });
        },
      }),
      {
        deliveryId: "delivery-1",
        rawBody: successfulPayload,
        signature: "sha256=signed",
      },
    );

    expect(result).toBe("forwarded");
    expect(requestUrl).toBe(
      "http://centaur-api-rs:8080/api/webhooks/production-release-announcement",
    );
    expect(request?.body).toBe(successfulPayload);
    expect(request?.method).toBe("POST");
    expect(request?.headers).toEqual({
      "Content-Type": "application/json",
      "X-GitHub-Delivery": "delivery-1",
      "X-GitHub-Event": "deployment_status",
      "X-Hub-Signature-256": "sha256=signed",
    });
  });

  test("ignores non-success states and deployments without an enabled route", async () => {
    let calls = 0;
    const fetch = async () => {
      calls += 1;
      return new Response("unexpected");
    };

    expect(await forwardGithubReleaseWebhook(
      options({ fetch }),
      {
        deliveryId: "delivery-2",
        rawBody: JSON.stringify({ deployment_status: { state: "failure" } }),
        signature: "sha256=signed",
      },
    )).toBe("ignored");
    expect(await forwardGithubReleaseWebhook(
      options({ fetch, releaseWebhookSlug: undefined }),
      {
        deliveryId: "delivery-3",
        rawBody: successfulPayload,
        signature: "sha256=signed",
      },
    )).toBe("ignored");
    expect(calls).toBe(0);
  });

  test("marks the delivery failed when durable workflow ingestion fails", async () => {
    const result = await forwardGithubReleaseWebhook(
      options({ fetch: async () => new Response("unavailable", { status: 503 }) }),
      {
        deliveryId: "delivery-4",
        rawBody: successfulPayload,
        signature: "sha256=signed",
      },
    );

    expect(result).toBe("failed");
  });
});

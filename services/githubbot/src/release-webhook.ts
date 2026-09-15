import type { GithubbotFetch, GithubbotOptions } from "./types";
import { errorMessage, noopLogger } from "./utils";

type JsonRecord = Record<string, unknown>;

export type GithubReleaseForwardResult = "failed" | "forwarded" | "ignored";

const WEBHOOK_SLUG_PATTERN = /^[a-z0-9][a-z0-9-]{0,63}$/;

/**
 * Forward a signature-verified successful deployment receipt to api-rs's
 * durable workflow webhook. The original raw body and signature are preserved
 * so api-rs independently verifies the same GitHub HMAC before creating state.
 */
export async function forwardGithubReleaseWebhook(
  options: GithubbotOptions,
  input: {
    deliveryId: string;
    rawBody: string;
    signature: string;
  },
): Promise<GithubReleaseForwardResult> {
  const slug = options.releaseWebhookSlug?.trim();
  if (!slug) return "ignored";
  const logger = options.logger ?? noopLogger;
  if (!WEBHOOK_SLUG_PATTERN.test(slug)) {
    logger.warn("githubbot_release_webhook_invalid_slug");
    return "failed";
  }
  if (!isSuccessfulDeploymentStatus(input.rawBody)) return "ignored";
  if (!input.deliveryId || !input.signature) return "failed";

  const fetcher: GithubbotFetch = options.fetch ?? globalThis.fetch;
  try {
    const response = await fetcher(
      `${options.apiUrl.replace(/\/$/, "")}/api/webhooks/${slug}`,
      {
        body: input.rawBody,
        headers: {
          "Content-Type": "application/json",
          "X-GitHub-Delivery": input.deliveryId,
          "X-GitHub-Event": "deployment_status",
          "X-Hub-Signature-256": input.signature,
        },
        method: "POST",
        signal: AbortSignal.timeout(5_000),
      },
    );
    if (!response.ok) {
      logger.warn("githubbot_release_webhook_forward_failed", {
        status: response.status,
      });
      return "failed";
    }
    return "forwarded";
  } catch (error) {
    logger.warn("githubbot_release_webhook_forward_failed", {
      error: errorMessage(error),
    });
    return "failed";
  }
}

function isSuccessfulDeploymentStatus(rawBody: string): boolean {
  let payload: unknown;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return false;
  }
  if (!isRecord(payload) || !isRecord(payload.deployment_status)) return false;
  return payload.deployment_status.state === "success";
}

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

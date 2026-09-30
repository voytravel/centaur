import { describe, expect, test } from "bun:test";
import {
  AUTOMATION_INGRESS_CONTRACT_VERSION,
  submitAutomationEventV1,
  type AutomationEventV1,
} from "../src/index";

describe("automation ingress v1", () => {
  test("preserves the current event envelope and single-purpose credential", async () => {
    const event: AutomationEventV1 = {
      deduplication_key: "github:delivery-7:9",
      event_type: "pull_request",
      labels: ["ready"],
      provider: "github",
      repository: "acme/widgets",
      subject_number: 9,
    };
    let request: { url: string; init?: RequestInit } | undefined;
    const fetcher = async (url: RequestInfo | URL, init?: RequestInit) => {
      request = { url: String(url), init };
      return Response.json({ data: { decision: "observe" } });
    };

    const response = await submitAutomationEventV1(
      fetcher, "https://console.example/", "test-token", event,
    );

    expect(AUTOMATION_INGRESS_CONTRACT_VERSION).toBe(1);
    expect(response.ok).toBe(true);
    expect(request?.url).toBe("https://console.example/api/internal/automation_events");
    expect(request?.init?.method).toBe("POST");
    expect(request?.init?.headers).toEqual({
      Authorization: "Bearer test-token",
      "Content-Type": "application/json",
    });
    expect(JSON.parse(String(request?.init?.body))).toEqual({ event });
  });
});

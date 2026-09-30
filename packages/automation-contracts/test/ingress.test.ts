import { describe, expect, test } from "bun:test";
import {
  AUTOMATION_INGRESS_CONTRACT_VERSION,
  parseAutomationDecisionV1,
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

  test("parses the common decision without changing bot fallback behavior", () => {
    const parsed = parseAutomationDecisionV1({
      actions: ["review", 42, "run_qa"],
      decision: "act",
      policy_id: "  aut_123  ",
      reason: "  ",
      session_key: "  linear:issue-42  ",
      workstream_id: "aws_42",
      qa_target: "voy",
    });
    expect(parsed).toEqual({
      actions: ["review", "run_qa"],
      decision: "act",
      fields: {
        actions: ["review", 42, "run_qa"],
        decision: "act",
        policy_id: "  aut_123  ",
        reason: "  ",
        session_key: "  linear:issue-42  ",
        workstream_id: "aws_42",
        qa_target: "voy",
      },
      policyId: "aut_123",
      reason: "policy result",
      sessionKey: "linear:issue-42",
      workstreamId: "aws_42",
    });
    expect(parseAutomationDecisionV1({ decision: "act", session_key: " " })).toBeNull();
    expect(parseAutomationDecisionV1({ decision: "allow", session_key: "x" })).toBeNull();
    expect(parseAutomationDecisionV1([])).toBeNull();
  });
});

import { describe, expect, test } from "bun:test";
import {
  DEFAULT_SESSION_IDLE_TIMEOUT_MS,
  DEFAULT_SESSION_MAX_DURATION_MS,
  parseSessionEventStream,
  sessionTimeouts,
} from "../src/session-api";

describe("GitHub session timeouts", () => {
  test("bounds a turn even when deployment options are omitted", () => {
    expect(sessionTimeouts({})).toEqual({
      idleTimeoutMs: DEFAULT_SESSION_IDLE_TIMEOUT_MS,
      maxDurationMs: DEFAULT_SESSION_MAX_DURATION_MS,
    });
  });

  test("honors a configured bound and keeps idle within it", () => {
    expect(sessionTimeouts({ idleTimeoutMs: 90_000, maxDurationMs: 60_000 })).toEqual({
      idleTimeoutMs: 60_000,
      maxDurationMs: 60_000,
    });
  });
});

describe("parseSessionEventStream", () => {
  test("waits for structured completion after a raw terminal provider record", async () => {
    const encoder = new TextEncoder();
    const sse = [
      "id: 1",
      "event: session.output.line",
      `data: ${JSON.stringify({ type: "turn.completed", turn: { status: "completed" } })}`,
      "",
      "id: 2",
      "event: session.execution_completed",
      `data: ${JSON.stringify({ result_text: "GITHUB_SUMMARY:\nOutcome: Done." })}`,
      "",
      "",
    ].join("\n");
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(encoder.encode(sse));
        controller.close();
      },
    });
    const eventIds: number[] = [];
    const events = [];
    for await (const event of parseSessionEventStream(stream, (id) => eventIds.push(id))) {
      events.push(event);
    }

    expect(eventIds).toEqual([1, 2]);
    expect(events).toEqual([
      {
        data: { result_text: "GITHUB_SUMMARY:\nOutcome: Done." },
        event: "session.execution_completed",
        eventId: 2,
        eventKind: "session.execution_completed",
      },
    ]);
  });

  test("keeps normal output lines while suppressing only terminal provider records", async () => {
    const encoder = new TextEncoder();
    const sse = [
      "id: 1",
      "event: session.output.line",
      `data: ${JSON.stringify({ type: "item.started", item: { id: "work-1" } })}`,
      "",
      "id: 2",
      "event: session.execution_completed",
      `data: ${JSON.stringify({ result_text: "GITHUB_SUMMARY:\nOutcome: Done." })}`,
      "",
      "",
    ].join("\n");
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(encoder.encode(sse));
        controller.close();
      },
    });
    const events = [];
    for await (const event of parseSessionEventStream(stream, () => undefined)) {
      events.push(event);
    }

    expect(events).toHaveLength(2);
    expect(events[0]).toMatchObject({ eventKind: "session.output.line" });
    expect(events[1]).toMatchObject({ eventKind: "session.execution_completed" });
  });

  test("fails safely when a raw terminal record is not followed by durable completion", async () => {
    const encoder = new TextEncoder();
    const sse = [
      "id: 1",
      "event: session.output.line",
      `data: ${JSON.stringify({ type: "turn.completed", turn: { status: "completed" } })}`,
      "",
      "",
    ].join("\n");
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(encoder.encode(sse));
        controller.close();
      },
    });
    const events = [];
    for await (const event of parseSessionEventStream(stream, () => undefined)) {
      events.push(event);
    }

    expect(events).toEqual([
      {
        data: { error: "Session stream ended before durable execution completion" },
        event: "session.stream_error",
        eventKind: "session.stream_error",
      },
    ]);
  });
});

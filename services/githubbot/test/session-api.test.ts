import { describe, expect, test } from "bun:test";
import { parseSessionEventStream } from "../src/session-api";

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
});

import { describe, expect, test } from "bun:test";
import type { StateAdapter } from "chat";
import { reservePrPost } from "../src/pr-post-budget";
import type { GithubbotOptions } from "../src/types";

function memoryState(): StateAdapter {
  const keys = new Set<string>();
  return {
    async setIfNotExists(key: string) {
      if (keys.has(key)) return false;
      keys.add(key);
      return true;
    },
  } as unknown as StateAdapter;
}

const options = {
  webhookSecret: "test",
  apiUrl: "http://127.0.0.1:8080",
  stateKeyPrefix: "test",
  prPostsPerDay: 2,
} satisfies GithubbotOptions;

function input(state: StateAdapter, dedupId: string, now = new Date("2026-10-07T12:00:00Z")) {
  return { state, options, owner: "example", repo: "app", number: 42, dedupId, now };
}

describe("reservePrPost", () => {
  test("reserves one reply for a review thread on a head, including after retry", async () => {
    const state = memoryState();
    expect(await reservePrPost(input(state, "review-thread:10:head:abc"))).toBe("reserved");
    expect(await reservePrPost(input(state, "review-thread:10:head:abc"))).toBe("duplicate");
    expect(await reservePrPost(input(state, "review-thread:10:head:def"))).toBe("pause");
  });

  test("atomically caps concurrent PR posts and resets the next UTC day", async () => {
    const state = memoryState();
    const results = await Promise.all(
      Array.from({ length: 8 }, (_, i) => reservePrPost(input(state, `turn:${i}`))),
    );
    expect(results.filter((result) => result === "reserved")).toHaveLength(1);
    expect(results.filter((result) => result === "pause")).toHaveLength(1);
    expect(results.filter((result) => result === "limit")).toHaveLength(6);
    expect(await reservePrPost(input(state, "turn:next", new Date("2026-10-08T00:00:00Z"))))
      .toBe("reserved");
  });

  test("fails closed when durable state is unavailable", async () => {
    const state = {
      async setIfNotExists() { throw new Error("unavailable"); },
    } as unknown as StateAdapter;
    expect(await reservePrPost(input(state, "turn:1"))).toBe("unavailable");
  });
});

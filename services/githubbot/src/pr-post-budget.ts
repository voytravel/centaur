import type { StateAdapter } from "chat";
import type { GithubbotOptions } from "./types";

const DAY_MS = 24 * 60 * 60 * 1_000;
const DEDUP_TTL_MS = 30 * DAY_MS;
const DAILY_SLOT_TTL_MS = 2 * DAY_MS;
export const DEFAULT_PR_POSTS_PER_DAY = 25;
export const PR_POST_PAUSE_MESSAGE =
  "Centaur paused automatic replies on this PR after reaching today's posting limit. " +
  "Further run details are available in Centaur Console. A maintainer can review the outstanding work; " +
  "the posting budget resets at 00:00 UTC.";

/** Reserve a public PR post before sending it. A failed state write fails closed. */
export async function reservePrPost(input: {
  state: StateAdapter;
  options: GithubbotOptions;
  owner: string;
  repo: string;
  number: number;
  dedupId: string;
  now?: Date;
}): Promise<"reserved" | "pause" | "duplicate" | "limit" | "unavailable"> {
  const { state, options, owner, repo, number, dedupId } = input;
  const limit = options.prPostsPerDay ?? DEFAULT_PR_POSTS_PER_DAY;
  if (!Number.isSafeInteger(limit) || limit < 1) return "unavailable";
  const prefix = `${options.stateKeyPrefix ?? "centaur-githubbot"}:pr-post:${owner}/${repo}#${number}`;
  const day = (input.now ?? new Date()).toISOString().slice(0, 10);
  try {
    const fresh = await state.setIfNotExists(
      `${prefix}:dedup:${dedupId}`,
      "1",
      DEDUP_TTL_MS,
    );
    if (!fresh) return "duplicate";
    for (let slot = 1; slot <= limit; slot++) {
      if (await state.setIfNotExists(`${prefix}:day:${day}:${slot}`, "1", DAILY_SLOT_TTL_MS)) {
        return slot === limit ? "pause" : "reserved";
      }
    }
    return "limit";
  } catch {
    return "unavailable";
  }
}

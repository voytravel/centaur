import { describe, expect, test } from "bun:test";
import {
  parseCrossModelReviewOrchestration,
  planCrossModelReview,
} from "../src/review-orchestration";

const valid = {
  max_concurrency: 2,
  mode: "cross_model",
  reviewers: [
    {
      fallbacks: [{ harness: "codex", model: "glm-5.1-fp8", reasoning: "high" }],
      focus: ["correctness", "tests"],
      harness: "codex",
      id: "correctness",
      max_runs_per_epoch: 3,
      model: "glm-5.2-fp8",
      reasoning: "high",
    },
    {
      fallbacks: [],
      focus: ["security", "dependencies"],
      harness: "codex",
      id: "independent",
      max_runs_per_epoch: 2,
      model: "glm-5.1-fp8",
      reasoning: "high",
    },
  ],
  synthesizer: {
    fallbacks: [{ harness: "codex", model: "glm-5.1-fp8", reasoning: "high" }],
    focus: [],
    harness: "codex",
    id: "synthesis",
    max_runs_per_epoch: 3,
    model: "glm-5.2-fp8",
    reasoning: "high",
  },
};

describe("cross-model review orchestration", () => {
  test("accepts a bounded distinct reviewer group", () => {
    expect(parseCrossModelReviewOrchestration(valid)).toMatchObject({
      maxConcurrency: 2,
      mode: "cross_model",
      reviewers: [
        { harnessType: "codex", id: "correctness", model: "glm-5.2-fp8" },
        { harnessType: "codex", id: "independent", model: "glm-5.1-fp8" },
      ],
      synthesizer: { harnessType: "codex", id: "synthesis", model: "glm-5.2-fp8" },
    });
  });

  test("fails closed on duplicate primary reviewer models", () => {
    const invalid = structuredClone(valid);
    invalid.reviewers[1]!.model = "glm-5.2-fp8";
    expect(parseCrossModelReviewOrchestration(invalid)).toBeUndefined();
  });

  test("fails closed on unrecognized profile fields or focus", () => {
    const unknownField = structuredClone(valid);
    (unknownField.reviewers[0] as Record<string, unknown>).unbounded_prompt = "do anything";
    expect(parseCrossModelReviewOrchestration(unknownField)).toBeUndefined();

    const invalidFocus = structuredClone(valid);
    invalidFocus.reviewers[0]!.focus = ["invented" as never];
    expect(parseCrossModelReviewOrchestration(invalidFocus)).toBeUndefined();
  });

  test("reserves separate reviewer and synthesis budgets before execution", () => {
    const orchestration = parseCrossModelReviewOrchestration(valid)!;
    const first = planCrossModelReview(orchestration, undefined);
    expect(first.reviewers.map((profile) => profile.id)).toEqual(["correctness", "independent"]);
    expect(first.reviewerRuns).toEqual({
      __synthesizer: 1,
      correctness: 1,
      independent: 1,
    });

    const second = planCrossModelReview(orchestration, {
      __synthesizer: 3,
      correctness: 3,
      independent: 1,
    });
    expect(second.reviewers).toEqual([]);
    expect(second.synthesizer).toBeUndefined();
  });
});

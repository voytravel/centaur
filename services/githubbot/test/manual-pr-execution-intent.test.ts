import { describe, expect, test } from "bun:test";
import { manualPrExecutionIntent } from "../src/index";

describe("manualPrExecutionIntent", () => {
  test("turns an explicit conflict-fix mention on a dirty PR into repair work", () => {
    expect(
      manualPrExecutionIntent({
        messageText: "@voy-centaur you were supposed to fix the conflict",
        mergeableState: "dirty",
      }),
    ).toBe("resolve_conflict");
  });

  test("does not turn a generic mention into repair work", () => {
    expect(
      manualPrExecutionIntent({
        messageText: "@voy-centaur what is the status here?",
        mergeableState: "dirty",
      }),
    ).toBeUndefined();
  });

  test("does not infer conflict repair when GitHub reports a clean PR", () => {
    expect(
      manualPrExecutionIntent({
        messageText: "@voy-centaur please fix the merge conflict",
        mergeableState: "clean",
      }),
    ).toBeUndefined();
  });
});

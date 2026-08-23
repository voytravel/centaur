import { describe, expect, it } from "bun:test";
import { fetchLinearIssueContext } from "../src/linear-context";
import type { LinearRawRequestClient } from "../src/types";
import { noopLogger } from "../src/utils";

function client(data: unknown): LinearRawRequestClient {
  return {
    client: { rawRequest: async <Data>() => ({ data: data as Data }) },
  };
}

function issue(inverseRelations: unknown) {
  return {
    issue: {
      identifier: "ENG-42",
      title: "Ship the widget",
      inverseRelations,
    },
  };
}

describe("fetchLinearIssueContext", () => {
  it("marks an issue blocked only for an unresolved inbound blocks relation", async () => {
    const result = await fetchLinearIssueContext(
      client(issue({
        nodes: [
          { type: "related", issue: { state: { type: "started" } } },
          { type: "blocks", issue: { state: { type: "completed" } } },
          { type: "blocks", issue: { state: { type: "started" } } },
        ],
        pageInfo: { hasNextPage: false },
      })),
      "issue-42",
      noopLogger,
    );

    expect(result).toEqual(expect.objectContaining({ blocked: true }));
  });

  it("allows terminal blockers and unrelated inbound relations", async () => {
    const result = await fetchLinearIssueContext(
      client(issue({
        nodes: [
          { type: "blocks", issue: { state: { type: "completed" } } },
          { type: "blocks", issue: { state: { type: "canceled" } } },
          { type: "related", issue: { state: { type: "started" } } },
        ],
        pageInfo: { hasNextPage: false },
      })),
      "issue-42",
      noopLogger,
    );

    expect(result).toEqual(expect.objectContaining({ blocked: false }));
  });

  it("fails closed when the blocker relation page is incomplete", async () => {
    const result = await fetchLinearIssueContext(
      client(issue({ nodes: [], pageInfo: { hasNextPage: true } })),
      "issue-42",
      noopLogger,
    );

    expect(result).toEqual(expect.objectContaining({ blocked: true }));
  });

  it("fails closed when Linear does not return blocker relation data", async () => {
    const result = await fetchLinearIssueContext(
      client(issue(undefined)),
      "issue-42",
      noopLogger,
    );

    expect(result).toEqual(expect.objectContaining({ blocked: true }));
  });
});

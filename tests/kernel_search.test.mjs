import assert from "node:assert/strict";
import test from "node:test";
import { compareVersions, filterOptions, search } from "../site/kernel-search/search.js";

function manifest(scenario, distribution, release, version, path = version) {
  return { scenario, distribution, release, version, architecture: "64", path, url: `https://example.com/${path}` };
}

const index = {
  manifests: [
    manifest("A2A", "Ubuntu", "22.04", "9.68.9.1"),
    manifest("A2A", "Ubuntu", "22.04", "9.68.10.1"),
    manifest("V2A", "Debian", "12", "9.66.7643.1"),
    manifest("A2A", "Ubuntu", "24.04", "9.68.10.1"),
  ],
  kernels: {
    "6.1.0-13-amd64": [0, 1, 2],
    "6.1.0-13-cloud-amd64": [2],
    "6.1.0-13-amd64-extra": [3],
    "6x1x0-13-amd64": [3],
  },
};

test("exact search trims whitespace but preserves suffixes and case", () => {
  const result = search(index, { query: " 6.1.0-13-amd64\n" });
  assert.equal(result.length, 2);
  assert.deepEqual(result.map((match) => match.kernel), ["6.1.0-13-amd64", "6.1.0-13-amd64"]);
  assert.deepEqual(result[0].manifests.map((item) => item.version), ["9.68.10.1", "9.68.9.1"]);
  assert.equal(search(index, { query: "6.1.0-13-AMD64" }).length, 0);
  assert.equal(search(index, { query: "6.1.0-13" }).length, 0);
});

test("partial matching is an explicit literal substring search", () => {
  assert.equal(search(index, { query: "6.1.0-13", partial: true }).length, 4);
  const matches = search(index, { query: "6.1.0", partial: true });
  assert.ok(matches.every((match) => !match.kernel.startsWith("6x")));
  assert.deepEqual(search(index, { query: ".*", partial: true }), []);
});

test("filters combine without leaking support across scenarios or updates", () => {
  const result = search(index, {
    query: "6.1.0-13-amd64",
    scenario: "A2A",
    distribution: "Ubuntu 22.04",
    version: "9.68.9.1",
  });
  assert.equal(result.length, 1);
  assert.equal(result[0].manifests.length, 1);
  assert.equal(result[0].manifests[0].version, "9.68.9.1");
  assert.deepEqual(search(index, { query: "6.1.0-13-cloud-amd64", scenario: "A2A" }), []);
  assert.deepEqual(search(index, { query: "6.1.0-13-amd64", distribution: "Ubuntu 24.04" }), []);
});

test("empty, missing, and cleared queries have no results", () => {
  assert.deepEqual(search(index), []);
  assert.deepEqual(search(index, { query: "  ", partial: true }), []);
  assert.deepEqual(search(index, { query: "not-a-kernel" }), []);
  assert.deepEqual(search(index, { query: "toString" }), []);
});

test("filter options deduplicate and sort versions numerically, newest first", () => {
  assert.deepEqual(filterOptions(index), {
    scenarios: ["A2A", "V2A"],
    distributions: ["Debian 12", "Ubuntu 22.04", "Ubuntu 24.04"],
    versions: ["9.68.10.1", "9.68.9.1", "9.66.7643.1"],
  });
  assert.deepEqual(["9.9.1.1", "9.10.1.1", "10.1.1.1"].sort(compareVersions), [
    "10.1.1.1", "9.10.1.1", "9.9.1.1",
  ]);
});

test("grouping preserves every original manifest without changing the index", () => {
  const before = JSON.stringify(index);
  const result = search(index, { query: "6.1.0-13-amd64" });
  assert.equal(result[0].manifests[0].url, "https://example.com/9.68.10.1");
  assert.equal(JSON.stringify(index), before);
});

import assert from "node:assert/strict";
import test from "node:test";
import {
  MAX_HOOKS_PER_DEPENDENCY_KEY,
  planDependencyCountIssues,
} from "../src/onchain/validate/limits.js";
import type { OnchainCompiledHook } from "../src/types/index.js";

test("per-dependency-key hook fan-out is capped (MAX_HOOKS_PER_DEPENDENCY_KEY)", () => {
  const sharedKey = `0x${"ab".repeat(32)}`;
  const hooksOf = (count: number): readonly OnchainCompiledHook[] =>
    Array.from({ length: count }, (_, index) => ({
      hookId: `0x${(index + 1).toString(16).padStart(64, "0")}`,
      dependencies: [{ signalKey: sharedKey }],
    })) as unknown as readonly OnchainCompiledHook[];
  assert.deepEqual(
    planDependencyCountIssues(hooksOf(MAX_HOOKS_PER_DEPENDENCY_KEY)),
    [],
    `${MAX_HOOKS_PER_DEPENDENCY_KEY} hooks on one key is the boundary and must pass`,
  );
  assert.ok(
    planDependencyCountIssues(hooksOf(MAX_HOOKS_PER_DEPENDENCY_KEY + 1)).some(
      (issue) =>
        issue.includes(`fans out to ${MAX_HOOKS_PER_DEPENDENCY_KEY + 1} hooks`),
    ),
    "one hook past the per-key cap must be rejected",
  );
});

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  assertHookPlanArtifact,
  HookPlanArtifactValidationError,
  HookPlanCompilationError,
  compileZhixuHookPlan,
  validateHookPlanArtifact,
} from "../src/hook-plan.js";
import {
  assertOnchainHookPlanArtifact,
  compileZhixuOnchainHookPlan,
  hashOnchainPlanPayload,
  OnchainHookPlanArtifactValidationError,
  validateOnchainHookPlanArtifact,
} from "../src/onchain-hook-plan.js";
import {
  dockRoutesRootOf,
  EMPTY_MERKLE_ROOT,
  interfaceRootOf,
} from "../src/dock.js";
import type {
  DockResolutionManifest,
  ZhixuDefinition,
} from "../src/types/index.js";

/**
 * Protocol freeze gate: Rust's generated compatibility manifest is the only
 * fixture input for this test.  The target artifact in its resolution entry,
 * the parent route, and both EVM-facing plans must all resolve to the same
 * committed identities and dock roots.
 */
const manifestPath = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../../../../uvp-core/fixtures/dock/v1/manifest.json",
);
const fixture = JSON.parse(readFileSync(manifestPath, "utf8")) as DockCompatFixture;

interface DockCompatFixture {
  readonly schemaVersion: string;
  readonly targetDefinition: ZhixuDefinition;
  readonly parentDefinition: ZhixuDefinition;
  readonly resolutionManifest: DockResolutionManifest;
  readonly expected: {
    readonly targetPlanId: `0x${string}`;
    readonly targetArtifactHash: `0x${string}`;
    readonly targetDefinitionRefHash: `0x${string}`;
    readonly parentDefinitionRefHash: `0x${string}`;
    readonly dockRoutesRoot: `0x${string}`;
    readonly dockInterfaceRoot: `0x${string}`;
    readonly dockRoutes: readonly unknown[];
    readonly interfaceArtifact: { readonly interfaceRoot: `0x${string}` };
  };
}

test("protocol freeze consumes one Rust dock fixture and one resolved artifact", () => {
  assert.equal(fixture.schemaVersion, "uvp.dock.compat.v1");
  const targetEntry = fixture.resolutionManifest.definitions.find(
    (entry) => entry.zhixu === fixture.targetDefinition.metadata.uid,
  );
  assert.ok(targetEntry, "shared fixture must contain the target resolution entry");

  const target = compileZhixuHookPlan(fixture.targetDefinition);
  const parent = compileZhixuHookPlan(
    fixture.parentDefinition,
    fixture.resolutionManifest,
  );
  assert.equal(target.planId, fixture.expected.targetPlanId);
  assert.equal(target.planHash, fixture.expected.targetArtifactHash);
  assert.equal(targetEntry.evmPlanId, target.planId);
  assert.equal(targetEntry.artifactHash, target.planHash);
  assert.equal(targetEntry.definitionRefHash, fixture.expected.targetDefinitionRefHash);
  assert.deepEqual(target.dockInterface, targetEntry.interface);
  assert.deepEqual(target.dockInterface, fixture.expected.interfaceArtifact);
  assert.deepEqual(parent.dockRoutes, fixture.expected.dockRoutes);
  assert.equal(parent.dockRoutesRoot, fixture.expected.dockRoutesRoot);
  assert.equal(parent.dockInterfaceRoot, fixture.expected.dockInterfaceRoot);
  assert.equal(interfaceRootOf(target.dockInterface!), fixture.expected.interfaceArtifact.interfaceRoot);
  assert.equal(dockRoutesRootOf(parent.dockRoutes), fixture.expected.dockRoutesRoot);
  assert.deepEqual(validateHookPlanArtifact(target), []);
  assert.deepEqual(validateHookPlanArtifact(parent), []);

  const targetOnchain = compileZhixuOnchainHookPlan(fixture.targetDefinition);
  const parentOnchain = compileZhixuOnchainHookPlan(
    fixture.parentDefinition,
    fixture.resolutionManifest,
  );
  assert.deepEqual(validateOnchainHookPlanArtifact(targetOnchain), []);
  assert.deepEqual(validateOnchainHookPlanArtifact(parentOnchain), []);
  assert.doesNotThrow(() => assertOnchainHookPlanArtifact(targetOnchain));
  assert.doesNotThrow(() => assertOnchainHookPlanArtifact(parentOnchain));
});

test("artifact validators reject stale dock roots with structured issues", () => {
  const target = compileZhixuHookPlan(fixture.targetDefinition);
  const staleSourceRoot = {
    ...target,
    dockInterfaceRoot: EMPTY_MERKLE_ROOT,
  };
  const sourceIssues = validateHookPlanArtifact(staleSourceRoot);
  assert.ok(
    sourceIssues.some((issue) =>
      /artifact\.dockInterfaceRoot must match the recomputed root/.test(issue),
    ),
    sourceIssues.join("; "),
  );
  assert.throws(
    () => assertHookPlanArtifact(staleSourceRoot),
    (error: unknown) =>
      error instanceof HookPlanArtifactValidationError &&
      error.issues.some((issue) => issue.includes("dockInterfaceRoot")),
  );

  const onchain = compileZhixuOnchainHookPlan(fixture.targetDefinition);
  const { planHash: _stalePlanHash, ...onchainPayload } = onchain;
  const staleOnchainRoot = {
    ...onchainPayload,
    dockInterfaceRoot: EMPTY_MERKLE_ROOT,
    planHash: "" as `0x${string}`,
  };
  staleOnchainRoot.planHash = hashOnchainPlanPayload(staleOnchainRoot);
  const onchainIssues = validateOnchainHookPlanArtifact(staleOnchainRoot);
  assert.ok(
    onchainIssues.some((issue) =>
      /artifact\.dockInterfaceRoot must match the recomputed root/.test(issue),
    ),
    onchainIssues.join("; "),
  );
  assert.throws(
    () => assertOnchainHookPlanArtifact(staleOnchainRoot),
    (error: unknown) =>
      error instanceof OnchainHookPlanArtifactValidationError &&
      error.issues.some((issue) => issue.includes("dockInterfaceRoot")),
  );
});

test("core linker errors retain stable code, path, and target reference", () => {
  const brokenParent = structuredClone(fixture.parentDefinition) as unknown as {
    spec: {
      taskPatterns: Array<{
        stages: Array<{
          executor?: {
            zhixuExecutorConfig?: { inputMap: Record<string, string> };
          };
        }>;
      }>;
    };
  };
  const dockStage = brokenParent.spec.taskPatterns[1]?.stages[0];
  assert.ok(dockStage?.executor?.zhixuExecutorConfig, "fixture route missing");
  dockStage.executor.zhixuExecutorConfig.inputMap.CANCEL = "missing_port";

  assert.throws(
    () =>
      compileZhixuHookPlan(
        brokenParent as unknown as ZhixuDefinition,
        fixture.resolutionManifest,
      ),
    (error: unknown) => {
      assert.ok(error instanceof HookPlanCompilationError);
      assert.ok(
        error.issues.some(
          (issue) =>
            /D009/.test(issue) &&
            /inputMap\.CANCEL/.test(issue) &&
            /zx-payment-execution/.test(issue),
        ),
        error.issues.join("; "),
      );
      return true;
    },
  );
});

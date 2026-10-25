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
import { compileZhixuOnchainHookPlan } from "../src/onchain/compile.js";
import { hashOnchainPlanPayload } from "../src/onchain/hash/plan.js";
import {
  assertOnchainHookPlanArtifact,
  OnchainHookPlanArtifactValidationError,
  validateOnchainHookPlanArtifact,
} from "../src/onchain/validate/artifact.js";
import {
  dockRoutesRootOf,
  EMPTY_MERKLE_ROOT,
  interfaceRootOf,
} from "../src/dock.js";
import type {
  DockInterfaceArtifactV2,
  DockResolutionManifest,
  ZhixuDefinition,
} from "../src/types/index.js";

const manifestPath = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../fixtures/dock/v1/manifest.json",
);
const fixture = JSON.parse(readFileSync(manifestPath, "utf8")) as DockCompatFixture;

interface DockCompatFixture {
  readonly schemaVersion: string;
  readonly identities: { readonly targetUid: string; readonly parentUid: string };
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
    readonly interfaceArtifact: DockInterfaceArtifactV2;
  };
}

test("protocol freeze consumes one Rust dock fixture and one resolved artifact", () => {
  assert.equal(fixture.schemaVersion, "uvp.dock.compat.v1");
  const targetEntry = fixture.resolutionManifest.definitions.find(
    (entry) => entry.zhixu === fixture.identities.targetUid,
  );
  assert.ok(targetEntry, "shared fixture must contain the target resolution entry");

  const target = compileZhixuHookPlan(fixture.targetDefinition);
  const parent = compileZhixuHookPlan(
    fixture.parentDefinition,
    fixture.resolutionManifest,
  );
  assert.equal(target.planId, fixture.expected.targetPlanId);
  assert.equal(target.planHash, fixture.expected.targetArtifactHash);
  assert.equal(target.zhixuId, fixture.identities.targetUid);
  assert.equal(parent.zhixuId, fixture.identities.parentUid);
  assert.equal(targetEntry.evmPlanId, target.planId);
  assert.equal(targetEntry.artifactHash, target.planHash);
  assert.equal(targetEntry.definitionRefHash, fixture.expected.targetDefinitionRefHash);
  assert.deepEqual(target.dockInterface?.interfaces, targetEntry.interfaces);
  assert.deepEqual(target.dockInterface, fixture.expected.interfaceArtifact);
  assert.deepEqual(parent.dockRoutes, fixture.expected.dockRoutes);
  assert.equal(parent.dockRoutesRoot, fixture.expected.dockRoutesRoot);
  assert.equal(parent.dockInterfaceRoot, fixture.expected.dockInterfaceRoot);
  assert.equal(
    interfaceRootOf(target.dockInterface!),
    fixture.expected.interfaceArtifact.interfaceRoot,
  );
  assert.equal(dockRoutesRootOf(parent.dockRoutes), fixture.expected.dockRoutesRoot);
  assert.deepEqual(validateHookPlanArtifact(target), []);
  assert.deepEqual(validateHookPlanArtifact(parent), []);

  assert.deepEqual(
    parent.dockRoutes.map((route) => [route.target.interfaceName, route.orderMode]),
    [
      ["production_service", "new"],
      ["production_evidence", "existing"],
    ],
  );

  const targetOnchain = compileZhixuOnchainHookPlan(fixture.targetDefinition);
  assert.deepEqual(validateOnchainHookPlanArtifact(targetOnchain), []);
  assert.doesNotThrow(() => assertOnchainHookPlanArtifact(targetOnchain));
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
      stages: Array<{
        executor?: {
          zhixuExecutorConfig?: { inputMap: Record<string, string> };
        };
      }>;
    };
  };
  const dockStage = brokenParent.spec.stages[1];
  assert.ok(dockStage?.executor?.zhixuExecutorConfig, "fixture route missing");
  dockStage.executor.zhixuExecutorConfig.inputMap.EXECUTE = "missing_port";

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
            /inputMap\.EXECUTE/.test(issue) &&
            issue.includes(fixture.identities.targetUid),
        ),
        error.issues.join("; "),
      );
      return true;
    },
  );
});

test("D020 mode-not-allowed and D003 target-shape errors surface from the core linker", () => {
  const wrongMode = structuredClone(fixture.parentDefinition) as unknown as ZhixuDefinition & {
    spec: {
      stages: Array<{
        name: string;
        executor?: {
          zhixuExecutorConfig?: { order: { mode: string } };
        };
      }>;
    };
  };
  const manufactureStage = wrongMode.spec.stages[1]!;
  (manufactureStage.executor!.zhixuExecutorConfig!.order as { mode: string }).mode = "existing";
  assert.throws(
    () =>
      compileZhixuHookPlan(wrongMode as unknown as ZhixuDefinition, fixture.resolutionManifest),
    (error: unknown) => {
      assert.ok(error instanceof HookPlanCompilationError);
      assert.ok(
        error.issues.some(
          (issue) => /D020/.test(issue) && /orderModes/.test(issue),
        ),
        error.issues.join("; "),
      );
      return true;
    },
  );

  for (const badTargetValue of ["Payment-Zhixu", "payment-zhixu"]) {
    const badName = structuredClone(fixture.parentDefinition) as unknown as ZhixuDefinition & {
      spec: {
        stages: Array<{
          executor?: {
            zhixuExecutorConfig?: { target: { zhixu: string } };
          };
        }>;
      };
    };
    badName.spec.stages[1]!.executor!.zhixuExecutorConfig!.target.zhixu = badTargetValue;
    assert.throws(
      () => compileZhixuHookPlan(badName as unknown as ZhixuDefinition, fixture.resolutionManifest),
      (error: unknown) => {
        assert.ok(error instanceof HookPlanCompilationError);
        assert.ok(
          error.issues.some(
            (issue) => /D003/.test(issue) && /content-derived uid/.test(issue),
          ),
          `${badTargetValue}: ${error.issues.join("; ")}`,
        );
        return true;
      },
    );
  }
});

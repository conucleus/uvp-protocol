import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import test from "node:test";
import { keccak256, concat, stringToHex, pad, toHex } from "viem";
import { compileZhixuHookPlan } from "../src/hook-plan.js";
import {
  canonicalSignalHash,
  dockInputBindingHash,
  dockInputPayloadHash,
  dockInterfaceInputLeaf,
  EMPTY_MERKLE_ROOT,
  dockInterfaceOutputLeaf,
  dockOutputBindingHash,
  dockRouteHash,
  signalKey,
  cloudRuntimeDomain,
  definitionRefHash,
  dockInputIdempotencyKey,
  dockInstanceId,
  dockOutputIdempotencyKey,
  evmRuntimeDomain,
  hookKey,
  interfaceRootOf,
  linkedOrderId,
  localOrderKey,
  merkleProof,
  merkleRoot,
  portKey,
  sourceFactSetHash,
  stageKey,
  verifyMerkleProof,
} from "../src/dock.js";
import type { DockResolutionManifest, ZhixuDefinition } from "../src/types/index.js";

/**
 * M0 跨语言 golden vectors：本测试与 Rust
 * `uvp-compiler` 的 `gen_dock_fixtures`、Solidity Foundry 测试消费同一份
 * `uvp-core/fixtures/dock/v1/manifest.json`；任何一侧的哈希/ID/编码分叉
 * 都会在这里失败。
 */
const manifestPath = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../../../../uvp-core/fixtures/dock/v1/manifest.json",
);
const fixture = JSON.parse(
  readFileSync(manifestPath, "utf8"),
) as DockCompatFixture;

interface DockCompatFixture {
  readonly schemaVersion: string;
  readonly inputs: {
    readonly chainId: number;
    readonly stateMachineAddress: `0x${string}`;
    readonly dockingModuleAddress: `0x${string}`;
    readonly cloudDeploymentId: string;
    readonly cloudSecurityDomain: string;
    readonly localOrderId: string;
    readonly parentPlanIdWord: `0x${string}`;
  };
  readonly targetDefinition: ZhixuDefinition;
  readonly parentDefinition: ZhixuDefinition;
  readonly resolutionManifest: DockResolutionManifest;
  readonly expected: {
    readonly targetDefinitionRefHash: `0x${string}`;
    readonly parentDefinitionRefHash: `0x${string}`;
    readonly targetPlanId: `0x${string}`;
    readonly targetArtifactHash: `0x${string}`;
    readonly interfaceArtifact: {
      readonly interfaceRoot: `0x${string}`;
      readonly inputs: readonly { readonly port: string; readonly leafHash: `0x${string}` }[];
      readonly outputs: readonly { readonly port: string; readonly leafHash: `0x${string}` }[];
    };
    readonly dockRoutes: readonly {
      readonly routeId: `0x${string}`;
      readonly routeHash: `0x${string}`;
      readonly local: { readonly stageKey: `0x${string}` };
      readonly entrance: {
        readonly localHookName: string;
        readonly targetInputSignalHash: `0x${string}`;
      };
      readonly inputs: readonly {
        readonly kind: string;
        readonly bindingHash: `0x${string}`;
        readonly targetInputSignalHash: `0x${string}`;
        readonly localHookName: string;
        readonly targetPort: string;
        readonly targetSourceId: `0x${string}`;
        readonly targetSignalId: `0x${string}`;
      }[];
      readonly outputs: readonly {
        readonly localSignalName: string;
        readonly bindingHash: `0x${string}`;
        readonly localSourceId: `0x${string}`;
        readonly localSignalId: `0x${string}`;
        readonly targetPort: string;
        readonly targetSourceId: `0x${string}`;
        readonly targetSignalId: `0x${string}`;
        readonly terminal: "none" | "success" | "failure" | "cancelled";
      }[];
    }[];
    readonly dockRoutesRoot: `0x${string}`;
    readonly dockInterfaceRoot: `0x${string}`;
    readonly evmRuntimeDomain: `0x${string}`;
    readonly cloudRuntimeDomain: `0x${string}`;
    readonly localOrderKey: `0x${string}`;
    readonly dockInstanceId: `0x${string}`;
    readonly linkedOrderId: `0x${string}`;
    readonly sourceFactSetHash: `0x${string}`;
    readonly inputPayloadHash: `0x${string}`;
    readonly inputIdempotencyKey: `0x${string}`;
    readonly outputIdempotencyKey: `0x${string}`;
    readonly permitDigest: `0x${string}`;
    readonly routeLeafProof: readonly `0x${string}`[];
    readonly entranceInterfaceLeafProof: readonly `0x${string}`[];
  };
}

test("golden fixture compiles to identical routes, roots, and hashes", () => {
  const parentPlan = compileZhixuHookPlan(
    fixture.parentDefinition,
    fixture.resolutionManifest,
  );
  const targetPlan = compileZhixuHookPlan(fixture.targetDefinition);
  const expected = fixture.expected;

  // The target identity must be freshly compiled from the fixture definition,
  // then matched back to the exact resolution-manifest artifact consumed by
  // the parent linker.  Comparing only route fields would allow a stale
  // target planId/planHash to remain hidden in an otherwise valid route.
  const targetResolution = fixture.resolutionManifest.definitions.find(
    (definition) =>
      definition.zhixu === fixture.targetDefinition.metadata.uid &&
      definition.version === fixture.targetDefinition.metadata.annotations?.version,
  );
  assert.ok(targetResolution, "golden fixture is missing its target resolution entry");
  assert.equal(targetPlan.planId, expected.targetPlanId);
  assert.equal(targetPlan.planHash, expected.targetArtifactHash);
  assert.equal(targetResolution.evmPlanId, targetPlan.planId);
  assert.equal(targetResolution.artifactHash, targetPlan.planHash);
  assert.equal(targetResolution.definitionRefHash, targetPlan.dockInterface?.definition.definitionRefHash);
  assert.deepEqual(targetResolution.interface, targetPlan.dockInterface);

  assert.equal(targetPlan.dockInterface?.definition.definitionRefHash, expected.targetDefinitionRefHash);
  assert.equal(
    definitionRefHash("zx-payment-execution", "1.2.0"),
    expected.targetDefinitionRefHash,
  );
  assert.equal(
    definitionRefHash("zx-settlement", "2.0.0"),
    expected.parentDefinitionRefHash,
  );

  // 目标接口 root：重算 == manifest 声明 == 编译产物。
  assert.equal(interfaceRootOf(targetPlan.dockInterface!), expected.interfaceArtifact.interfaceRoot);

  // 父定义 route 集与 Rust 输出一致。
  assert.equal(parentPlan.dockRoutes.length, expected.dockRoutes.length);
  const route = parentPlan.dockRoutes[0]!;
  const expectedRoute = expected.dockRoutes[0]!;
  assert.equal(route.routeId, expectedRoute.routeId);
  assert.equal(route.routeHash, expectedRoute.routeHash);
  assert.equal(route.local.stageKey, expectedRoute.local.stageKey);
  assert.equal(route.entrance.localHookName, expectedRoute.entrance.localHookName);
  assert.equal(route.inputs.length, expectedRoute.inputs.length);
  assert.equal(route.outputs.length, expectedRoute.outputs.length);
  for (const [actual, want] of zip(route.inputs, expectedRoute.inputs)) {
    // TS 独立重算（不读 Rust 产物的哈希字段）
    const recomputed = dockInputBindingHash({
      routeId: route.routeId,
      localHookId: keccak256(stringToHex(`${route.local.stageIdentifier}#${actual.localHookName}`)),
      targetPort: actual.targetPort,
      targetSourceId: actual.targetSourceId,
      targetSignalId: actual.targetSignalId,
      kind: actual.kind as "entrance" | "signal",
    });
    assert.equal(recomputed, want.bindingHash);
    assert.equal(actual.bindingHash, want.bindingHash);
    assert.equal(actual.kind, want.kind);
  }
  for (const [actual, want] of zip(route.outputs, expectedRoute.outputs)) {
    const recomputed = dockOutputBindingHash({
      routeId: route.routeId,
      localSourceId: actual.localSourceId,
      localSignalId: actual.localSignalId,
      targetPort: actual.targetPort,
      targetSourceId: actual.targetSourceId,
      targetSignalId: actual.targetSignalId,
      terminal: actual.terminal,
    });
    assert.equal(recomputed, want.bindingHash);
    assert.equal(actual.bindingHash, want.bindingHash);
    assert.equal(actual.localSignalName, want.localSignalName);
  }
  // 接口叶子逐个重算 + root 重算
  const targetInterface = targetPlan.dockInterface!;
  for (const port of targetInterface.inputs) {
    assert.equal(
      dockInterfaceInputLeaf({
        definitionRefHash: targetInterface.definition.definitionRefHash,
        portName: port.port,
        kind: port.kind,
        hookId: port.hookId,
        sourceId: port.sourceId,
        signalId: port.signalId,
        accessPolicy: port.accessPolicy,
      }),
      port.leafHash,
    );
  }
  for (const port of targetInterface.outputs) {
    assert.equal(
      dockInterfaceOutputLeaf({
        definitionRefHash: targetInterface.definition.definitionRefHash,
        portName: port.port,
        sourceId: port.sourceId,
        signalId: port.signalId,
        terminal: port.terminal,
      }),
      port.leafHash,
    );
  }
  // routeHash 全量重算（含 targetPlanId word）
  const expectedRoute0 = expectedRoute;
  assert.equal(
    dockRouteHash({
      routeId: route.routeId,
      targetDefinitionRefHash: route.target.definitionRefHash,
      targetArtifactHash: route.target.artifactHash,
      targetInterfaceRoot: route.target.interfaceRoot,
      targetPlanId: route.target.evmPlanId ?? EMPTY_MERKLE_ROOT,
      sourceSeam: route.sourceSeam,
      entranceBindingHash: route.inputs.find((i) => i.kind === "entrance")!.bindingHash,
      accessPolicy: route.entrance.accessPolicy,
      inputsRoot: merkleRoot(route.inputs.map((i) => i.bindingHash)),
      outputsRoot: merkleRoot(route.outputs.map((o) => o.bindingHash)),
    }),
    expectedRoute0.routeHash,
  );
  // input payload hash 独立重算
  const entranceInput0 = route.inputs.find((i) => i.kind === "entrance")!;
  assert.equal(
    dockInputPayloadHash({
      dockInstanceId: expected.dockInstanceId,
      routeHash: route.routeHash,
      localPlanId: pad(fixture.inputs.parentPlanIdWord, { size: 32 }),
      localOrderId: expected.localOrderKey,
      localStageId: route.local.stageKey,
      localHookId: keccak256(stringToHex(`${route.local.stageIdentifier}#${route.entrance.localHookName}`)),
      targetPlanId: fixture.expected.targetPlanId,
      linkedOrderId: expected.linkedOrderId,
      targetPort: route.entrance.targetPort,
      targetSignalId: entranceInput0.targetSignalId,
    }),
    expected.inputPayloadHash,
  );
  assert.equal(parentPlan.dockRoutesRoot, expected.dockRoutesRoot);
  assert.equal(parentPlan.dockInterfaceRoot, expected.dockInterfaceRoot);
  assert.equal(
    merkleRoot(parentPlan.dockRoutes.map((dockRoute) => dockRoute.routeHash)),
    expected.dockRoutesRoot,
  );
});

test("runtime domains and derived identities match the golden vectors", () => {
  const inputs = fixture.inputs;
  const expected = fixture.expected;
  assert.equal(
    evmRuntimeDomain(BigInt(inputs.chainId), inputs.stateMachineAddress),
    expected.evmRuntimeDomain,
  );
  assert.equal(
    cloudRuntimeDomain(inputs.cloudDeploymentId, inputs.cloudSecurityDomain),
    expected.cloudRuntimeDomain,
  );
  assert.equal(localOrderKey(inputs.localOrderId), expected.localOrderKey);

  const route = fixture.expected.dockRoutes[0]!;
  const instance = dockInstanceId({
    runtimeDomain: expected.evmRuntimeDomain,
    localPlanId: pad(fixture.inputs.parentPlanIdWord, { size: 32 }),
    localDefinitionRefHash: expected.parentDefinitionRefHash,
    localOrderKey: expected.localOrderKey,
    routeId: route.routeId,
    routeHash: route.routeHash,
  });
  assert.equal(instance, expected.dockInstanceId);
  assert.equal(
    linkedOrderId(instance, expected.targetDefinitionRefHash),
    expected.linkedOrderId,
  );
});

test("envelope and idempotency keys match the golden vectors", () => {
  const expected = fixture.expected;
  const route = expected.dockRoutes[0]!;
  const factSet = sourceFactSetHash([
    canonicalSignalHash("buyer::checkout.confirm.cmp"),
    canonicalSignalHash("buyer::checkout.cancel.cmp"),
  ]);
  assert.equal(factSet, expected.sourceFactSetHash);

  const entranceInput = route.inputs.find((input) => input.kind === "entrance")!;
  assert.equal(
    dockInputIdempotencyKey({
      dockInstanceId: expected.dockInstanceId,
      inputBindingHash: entranceInput.bindingHash,
      localHookReadyOccurrence: 0n,
    }),
    expected.inputIdempotencyKey,
  );

  const completedOutput = route.outputs.find(
    (output) => output.localSignalName === "cmp",
  )!;
  assert.equal(
    dockOutputIdempotencyKey({
      dockInstanceId: expected.dockInstanceId,
      outputBindingHash: completedOutput.bindingHash,
      targetFactId: signalKey(
        keccak256(stringToHex("payment")),
        keccak256(stringToHex("payment_flow.settle.cmp")),
      ),
    }),
    expected.outputIdempotencyKey,
  );
});

test("merkle proofs from the golden fixture verify against the roots", () => {
  const expected = fixture.expected;
  const routeLeaf = expected.dockRoutes[0]!.routeHash;
  assert.ok(
    verifyMerkleProof(expected.dockRoutesRoot, routeLeaf, expected.routeLeafProof),
  );
  assert.ok(
    !verifyMerkleProof(
      expected.dockRoutesRoot,
      stageKey("not-a-leaf"),
      expected.routeLeafProof,
    ),
  );

  const entranceLeaf = expected.interfaceArtifact.inputs.find(
    (port) => port.port === "execute",
  )!.leafHash;
  assert.ok(
    verifyMerkleProof(
      expected.interfaceArtifact.interfaceRoot,
      entranceLeaf,
      expected.entranceInterfaceLeafProof,
    ),
  );
  // TS 侧重建的 proof 与 Rust 提供的 proof 逐字相同。
  const leaves = [
    ...expected.interfaceArtifact.inputs.map((port) => port.leafHash),
    ...expected.interfaceArtifact.outputs.map((port) => port.leafHash),
  ];
  assert.deepEqual(merkleProof(leaves, entranceLeaf), expected.entranceInterfaceLeafProof);
});

test("EIP-712 entrance permit digest matches the golden vector", () => {
  const inputs = fixture.inputs;
  const expected = fixture.expected;
  const route = expected.dockRoutes[0]!;

  const domainSeparator = keccak256(
    concat([
      keccak256(
        stringToHex(
          "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
        ),
      ),
      keccak256(stringToHex("UVPDockingModule")),
      keccak256(stringToHex("2")),
      toHex(BigInt(inputs.chainId), { size: 32 }),
      pad(inputs.dockingModuleAddress.toLowerCase() as `0x${string}`, { size: 32 }),
    ]),
  );
  const structHash = keccak256(
    concat([
      keccak256(
        stringToHex(
          "UVPDockEntrancePermitV1(bytes32 targetPlanId,bytes32 targetEntrancePortId,bytes32 localPlanId,bytes32 routeHash,bytes32 dockInstanceId,bytes32 linkedOrderId,uint256 feeLimit,uint256 nonce,uint256 deadline)",
        ),
      ),
      pad(fixture.expected.targetPlanId, { size: 32 }),
      portKey("execute"),
      pad(inputs.parentPlanIdWord, { size: 32 }),
      route.routeHash,
      expected.dockInstanceId,
      expected.linkedOrderId,
      toHex(0n, { size: 32 }),
      toHex(1n, { size: 32 }),
      toHex(2000000000n, { size: 32 }),
    ]),
  );
  const digest = keccak256(
    concat([stringToHex("\u0019\u0001"), domainSeparator, structHash]),
  );
  assert.equal(digest, expected.permitDigest);
  // hookKey 基元也被 permit/typehash 之外的身份推导使用，钉住一个样本。
  assert.equal(hookKey("settlement.execute_payment#EXECUTE").length, 66);
});

function zip<T>(left: readonly T[], right: readonly T[]): [T, T][] {
  assert.equal(left.length, right.length);
  return left.map((item, index) => [item, right[index]!] as [T, T]);
}

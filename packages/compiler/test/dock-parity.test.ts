import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import test from "node:test";
import { compileZhixuHookPlan } from "../src/hook-plan.js";
import { validateDockCommitments } from "../src/dock-validation.js";
import {
  canonicalSignalHash,
  cloudRuntimeDomain,
  definitionRefHash,
  definitionUid,
  dockInputIdempotencyKey,
  dockInputPayloadHash,
  dockInstanceId,
  dockOutputIdempotencyKey,
  dockRouteId,
  dockRoutesRootOf,
  EMPTY_MERKLE_ROOT,
  eip712PermitDigest,
  evmRuntimeDomain,
  hookKey,
  inputBindingHash,
  inputPortLeaf,
  interfaceLeaf,
  interfaceNameKey,
  interfaceRootOf,
  linkedOrderId,
  localOrderKey,
  merkleProof,
  merkleRoot,
  modeWord,
  orderModesWord,
  outputBindingHash,
  outputPortLeaf,
  routeHash,
  signalKey,
  sourceFactSetHash,
  stageKey,
  targetOrderRefKey,
  verifyMerkleProof,
} from "../src/dock.js";
import {
  DOCK_INTERFACE_ARTIFACT_SCHEMA_VERSION,
  DOCK_RESOLUTION_SCHEMA_VERSION,
  DOCK_ROUTE_SCHEMA_VERSION,
  type DockInterfaceArtifactV2,
  type DockOrderMode,
  type DockResolutionManifest,
  type DockRouteV2,
  type HexString,
  type ZhixuDefinition,
} from "../src/types/index.js";

/**
 * M0 跨语言 golden vectors（dock v2）：本测试、Solidity Foundry 测试与
 * uvp-deploy verify-stack 消费同一份 TS 权威生成器产出的
 * `packages/compiler/fixtures/dock/v1/manifest.json`；任何一侧的
 * 哈/ID/编码分叉都会在这里失败。word 布局权威 =
 * packages/compiler/docs/dock-word-layout.md（冻结于 abiVersion 3.0）。
 */
const manifestPath = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../fixtures/dock/v1/manifest.json",
);
const fixture = JSON.parse(
  readFileSync(manifestPath, "utf8"),
) as DockCompatFixture;

interface DockCompatFixture {
  readonly schemaVersion: string;
  readonly constants: {
    readonly schemaVersions: {
      readonly dockInterfaceArtifact: string;
      readonly dockRoute: string;
      readonly resolution: string;
    };
    readonly domains: Record<string, string>;
    readonly merkle: { readonly emptyRoot: `0x${string}` };
    readonly enumWords: {
      readonly orderMode: { readonly new: number; readonly existing: number };
      readonly orderModesMask: { readonly new: number; readonly existing: number };
    };
    readonly permitTypeHash: string;
    readonly permitDomainVersion: string;
  };
  readonly inputs: {
    readonly chainId: number;
    readonly stateMachineAddress: `0x${string}`;
    readonly dockingModuleAddress: `0x${string}`;
    readonly cloudDeploymentId: string;
    readonly cloudSecurityDomain: string;
    readonly localOrderId: string;
    readonly existingTargetOrderRef: string;
    readonly parentPlanIdWord: `0x${string}`;
  };
  readonly identities: {
    readonly targetUid: string;
    readonly parentUid: string;
  };
  readonly targetDefinition: ZhixuDefinition;
  readonly parentDefinition: ZhixuDefinition;
  readonly resolutionManifest: DockResolutionManifest;
  readonly expected: {
    readonly targetDefinitionRefHash: `0x${string}`;
    readonly parentDefinitionRefHash: `0x${string}`;
    readonly targetPlanId: `0x${string}`;
    readonly targetArtifactHash: `0x${string}`;
    readonly interfaceArtifact: DockInterfaceArtifactV2;
    readonly interfaceNameIds: Record<string, `0x${string}`>;
    readonly dockRoutes: readonly DockRouteV2[];
    readonly dockRoutesRoot: `0x${string}`;
    readonly dockInterfaceRoot: `0x${string}`;
    readonly evmRuntimeDomain: `0x${string}`;
    readonly cloudRuntimeDomain: `0x${string}`;
    readonly localOrderKey: `0x${string}`;
    readonly dockInstanceId: `0x${string}`;
    readonly linkedOrderId: `0x${string}`;
    readonly existingDockInstanceId: `0x${string}`;
    readonly sourceFactSetHash: `0x${string}`;
    readonly inputPayloadHash: `0x${string}`;
    readonly inputIdempotencyKey: `0x${string}`;
    readonly outputIdempotencyKey: `0x${string}`;
    readonly permitDigest: `0x${string}`;
    readonly routeLeafProof: readonly `0x${string}`[];
    readonly interfaceLeafProof: readonly `0x${string}`[];
    readonly inputPortLeafProof: readonly `0x${string}`[];
  };
}

const parentPlan = compileZhixuHookPlan(
  fixture.parentDefinition,
  fixture.resolutionManifest,
);
const targetPlan = compileZhixuHookPlan(fixture.targetDefinition);
const expected = fixture.expected;
const targetInterface = targetPlan.dockInterface!;

function findRoute(interfaceName: string): DockRouteV2 {
  const route = parentPlan.dockRoutes.find(
    (candidate) => candidate.target.interfaceName === interfaceName,
  );
  assert.ok(route, `route on ${interfaceName} present`);
  return route;
}

test("frozen constants match the golden manifest", () => {
  assert.equal(fixture.schemaVersion, "uvp.dock.compat.v1");
  assert.equal(
    fixture.constants.schemaVersions.dockInterfaceArtifact,
    DOCK_INTERFACE_ARTIFACT_SCHEMA_VERSION,
  );
  assert.equal(fixture.constants.schemaVersions.dockRoute, DOCK_ROUTE_SCHEMA_VERSION);
  assert.equal(
    fixture.constants.schemaVersions.resolution,
    DOCK_RESOLUTION_SCHEMA_VERSION,
  );
  assert.equal(fixture.constants.merkle.emptyRoot, EMPTY_MERKLE_ROOT);
  assert.equal(fixture.constants.permitTypeHash.length > 0, true);
  assert.equal(fixture.constants.domains.definitionUid, "uvp:definition-uid:v1");
  assert.equal(fixture.constants.domains.dockInstance, "UVP_DOCK_INSTANCE_V2");
  assert.equal(fixture.constants.domains.dockInterface, "UVP_DOCK_INTERFACE_V2");
  assert.equal(
    fixture.constants.domains.interfaceInput,
    "UVP_DOCK_INTERFACE_INPUT_V2",
  );
  assert.equal(
    fixture.constants.domains.interfaceOutput,
    "UVP_DOCK_INTERFACE_OUTPUT_V2",
  );
  assert.equal(fixture.constants.domains.inputBinding, "UVP_DOCK_INPUT_BINDING_V2");
  assert.equal(
    fixture.constants.domains.outputBinding,
    "UVP_DOCK_OUTPUT_BINDING_V2",
  );
  assert.equal(fixture.constants.domains.route, "UVP_DOCK_ROUTE_V2");
  assert.equal(fixture.constants.domains.routeId, "UVP_DOCK_ROUTE_ID_V1");

  // 枚举 word：modeWord new=0/existing=1；orderModes 位掩码 bit0/bit1。
  assert.equal(modeWord("new"), `0x${"0".repeat(63)}0`);
  assert.equal(modeWord("existing"), `0x${"0".repeat(63)}1`);
  assert.equal(fixture.constants.enumWords.orderMode.new, 0);
  assert.equal(fixture.constants.enumWords.orderMode.existing, 1);
  assert.equal(
    orderModesWord(["new"]),
    `0x${"0".repeat(63)}${fixture.constants.enumWords.orderModesMask.new.toString(16)}`,
  );
  assert.equal(
    orderModesWord(["existing"]),
    `0x${"0".repeat(63)}${fixture.constants.enumWords.orderModesMask.existing.toString(16)}`,
  );
  assert.equal(orderModesWord(["existing", "new"]), `0x${"0".repeat(63)}3`);
  assert.equal(orderModesWord([]), undefined);
  assert.equal(orderModesWord(["new", "new"]), undefined);
  assert.equal(orderModesWord(["bogus"]), undefined);
});

test("definition uid parity: TS derivation matches the Rust-computed identities", () => {
  // TS 对拍函数（仅测试/工具用）：canonical 去 annotations + 域前缀哈希，
  // 必须与 Rust definition_uid 在 golden 样本上逐字符一致。
  assert.equal(definitionUid(fixture.targetDefinition), fixture.identities.targetUid);
  assert.equal(definitionUid(fixture.parentDefinition), fixture.identities.parentUid);
  assert.match(fixture.identities.targetUid, /^zx-[0-9a-f]{32}$/);

  // 注解永不参与身份：加 annotations 派生不变，改 name/labels 即变。
  const annotated = structuredClone(fixture.targetDefinition) as ZhixuDefinition & {
    metadata: { annotations?: Record<string, string>; labels?: Record<string, string> };
  };
  annotated.metadata.annotations = { doc: "parity-probe" };
  assert.equal(definitionUid(annotated), fixture.identities.targetUid);
  annotated.metadata.labels = { site: "factory-a" };
  assert.notEqual(definitionUid(annotated), fixture.identities.targetUid);

  // definitionRefHash 公式不变（吃派生 uid）。
  assert.equal(
    definitionRefHash(fixture.identities.targetUid),
    expected.targetDefinitionRefHash,
  );
  assert.equal(
    definitionRefHash(fixture.identities.parentUid),
    expected.parentDefinitionRefHash,
  );
});

test("golden fixture compiles to identical interfaces, routes, roots, and hashes", () => {
  // 目标身份/产物与 manifest 声明逐项一致（stale planId/planHash 无处可藏）。
  const targetResolution = fixture.resolutionManifest.definitions.find(
    (definition) => definition.zhixu === fixture.identities.targetUid,
  );
  assert.ok(targetResolution, "golden fixture is missing its target resolution entry");
  assert.equal(targetPlan.zhixuId, fixture.identities.targetUid);
  assert.equal(targetPlan.planId, expected.targetPlanId);
  assert.equal(targetPlan.planHash, expected.targetArtifactHash);
  assert.equal(targetResolution.evmPlanId, targetPlan.planId);
  assert.equal(targetResolution.artifactHash, targetPlan.planHash);
  assert.equal(
    targetResolution.definitionRefHash,
    targetPlan.dockInterface?.definition.definitionRefHash,
  );
  assert.deepEqual(targetResolution.interfaces, targetPlan.dockInterface?.interfaces);
  assert.deepEqual(targetPlan.dockInterface, expected.interfaceArtifact);
  assert.equal(targetPlan.dockInterfaceRoot, expected.interfaceArtifact.interfaceRoot);

  // ---- 接口承诺：端口叶 → 两 root → interfaceLeaf_v2 → 定义级 root ----
  for (const entry of targetInterface.interfaces) {
    const name = entry.name;
    for (const port of entry.inputs) {
      assert.equal(
        inputPortLeaf({
          uid: targetInterface.definition.uid,
          interfaceName: name,
          portName: port.port,
          hookId: port.hookId,
        }),
        port.leafHash,
      );
    }
    for (const port of entry.outputs) {
      assert.equal(
        outputPortLeaf({
          uid: targetInterface.definition.uid,
          interfaceName: name,
          portName: port.port,
          canonicalSignal: port.canonicalOutputSignal,
        }),
        port.leafHash,
      );
    }
    const inputsRoot = merkleRoot(entry.inputs.map((port) => port.leafHash));
    const outputsRoot = merkleRoot(entry.outputs.map((port) => port.leafHash));
    assert.equal(inputsRoot, entry.inputsRoot);
    assert.equal(outputsRoot, entry.outputsRoot);
    assert.equal(
      interfaceLeaf({
        uid: targetInterface.definition.uid,
        interfaceName: name,
        orderModes: entry.orderModes,
        inputsRoot: entry.inputsRoot,
        outputsRoot: entry.outputsRoot,
      }),
      entry.interfaceRoot,
    );
  }
  assert.equal(
    interfaceRootOf(targetInterface),
    expected.interfaceArtifact.interfaceRoot,
  );

  // ---- 父定义 route 集：与 Rust 输出一致 ----
  assert.equal(parentPlan.zhixuId, fixture.identities.parentUid);
  assert.deepEqual(parentPlan.dockRoutes, expected.dockRoutes);
  assert.equal(parentPlan.dockRoutesRoot, expected.dockRoutesRoot);
  // 父定义无 dockInterface → 定义级 root 是 EMPTY root。
  assert.equal(parentPlan.dockInterface, null);
  assert.equal(parentPlan.dockInterfaceRoot, EMPTY_MERKLE_ROOT);

  for (const route of parentPlan.dockRoutes) {
    // TS 独立重算（不读 Rust 产物的哈希字段）
    const recomputedRouteId = dockRouteId(
      expected.parentDefinitionRefHash,
      stageKey(route.local.stageIdentifier),
    );
    assert.equal(recomputedRouteId, route.routeId);
    for (const binding of route.inputBindings) {
      assert.equal(
        inputBindingHash({
          routeId: route.routeId,
          interfaceName: route.target.interfaceName,
          localHookId: `${route.local.stageIdentifier}#${binding.localHookName}`,
          portName: binding.targetPort,
          targetSourceId: binding.targetSourceId,
          targetSignalId: binding.targetSignalId,
        }),
        binding.bindingHash,
      );
    }
    for (const binding of route.outputBindings) {
      assert.equal(
        outputBindingHash({
          routeId: route.routeId,
          interfaceName: route.target.interfaceName,
          localSourceId: binding.localSourceId,
          localSignalId: binding.localSignalId,
          portName: binding.targetPort,
          targetSourceId: binding.targetSourceId,
          targetSignalId: binding.targetSignalId,
        }),
        binding.bindingHash,
      );
    }
    const inputsRoot = merkleRoot(
      route.inputBindings.map((binding) => binding.bindingHash),
    );
    const outputsRoot = merkleRoot(
      route.outputBindings.map((binding) => binding.bindingHash),
    );
    assert.equal(inputsRoot, route.inputBindingsRoot);
    assert.equal(outputsRoot, route.outputBindingsRoot);
    assert.equal(
      routeHash({
        localDefinitionRefHash: expected.parentDefinitionRefHash,
        targetDefinitionRefHash: route.target.definitionRefHash,
        interfaceName: route.target.interfaceName,
        orderMode: route.orderMode,
        inputBindingsRoot: route.inputBindingsRoot,
        outputBindingsRoot: route.outputBindingsRoot,
      }),
      route.routeHash,
    );
  }
  assert.equal(
    dockRoutesRootOf(parentPlan.dockRoutes),
    expected.dockRoutesRoot,
  );
});

test("runtime domains and derived identities match the golden vectors", () => {
  const inputs = fixture.inputs;
  assert.equal(
    evmRuntimeDomain(BigInt(inputs.chainId), inputs.stateMachineAddress),
    expected.evmRuntimeDomain,
  );
  assert.equal(
    cloudRuntimeDomain(inputs.cloudDeploymentId, inputs.cloudSecurityDomain),
    expected.cloudRuntimeDomain,
  );
  assert.equal(localOrderKey(inputs.localOrderId), expected.localOrderKey);

  const serviceRoute = findRoute("production_service");
  const evidenceRoute = findRoute("production_evidence");
  // 接口名 word：keccak(interfaceName)。
  assert.equal(
    interfaceNameKey("production_service"),
    expected.interfaceNameIds.production_service,
  );
  assert.equal(
    interfaceNameKey("production_evidence"),
    expected.interfaceNameIds.production_evidence,
  );

  // new 模式 dockInstanceId：恰 8 word（route 身份 + 本地单幂等建单锚）。
  const instance = dockInstanceId({
    runtimeDomain: expected.evmRuntimeDomain,
    localPlanId: inputs.parentPlanIdWord,
    localDefinitionRefHash: expected.parentDefinitionRefHash,
    localOrderKey: expected.localOrderKey,
    routeId: serviceRoute.routeId,
    routeHash: serviceRoute.routeHash,
    orderMode: "new",
    interfaceName: "production_service",
  });
  assert.equal(instance, expected.dockInstanceId);
  assert.equal(
    linkedOrderId(instance, expected.targetDefinitionRefHash),
    expected.linkedOrderId,
  );

  // existing 模式：尾部追加第 9 word = target order 引用（A07）。
  assert.equal(
    dockInstanceId({
      runtimeDomain: expected.cloudRuntimeDomain,
      localPlanId: inputs.parentPlanIdWord,
      localDefinitionRefHash: expected.parentDefinitionRefHash,
      localOrderKey: expected.localOrderKey,
      routeId: evidenceRoute.routeId,
      routeHash: evidenceRoute.routeHash,
      orderMode: "existing",
      interfaceName: "production_evidence",
      targetOrderRef: inputs.existingTargetOrderRef,
    }),
    expected.existingDockInstanceId,
  );
  // 引用不同即不同实例（targetOrderRefKey 参与派生）。
  assert.notEqual(
    dockInstanceId({
      runtimeDomain: expected.cloudRuntimeDomain,
      localPlanId: inputs.parentPlanIdWord,
      localDefinitionRefHash: expected.parentDefinitionRefHash,
      localOrderKey: expected.localOrderKey,
      routeId: evidenceRoute.routeId,
      routeHash: evidenceRoute.routeHash,
      orderMode: "existing",
      interfaceName: "production_evidence",
      targetOrderRef: "factory-a/P002",
    }),
    expected.existingDockInstanceId,
  );
  assert.equal(
    targetOrderRefKey(inputs.existingTargetOrderRef).length,
    66,
  );
});

test("envelope and idempotency keys match the golden vectors", () => {
  const inputs = fixture.inputs;
  const serviceRoute = findRoute("production_service");
  const birthBinding = serviceRoute.inputBindings.find(
    (binding) => binding.targetPort === "execute",
  )!;
  const completedOutput = serviceRoute.outputBindings.find(
    (binding) => binding.localSignalName === "cmp",
  )!;

  assert.equal(
    sourceFactSetHash([
      canonicalSignalHash("purchaser::procurement.confirm.cmp"),
    ]),
    expected.sourceFactSetHash,
  );

  assert.equal(
    dockInputPayloadHash({
      dockInstanceId: expected.dockInstanceId,
      routeHash: serviceRoute.routeHash,
      localPlanId: inputs.parentPlanIdWord,
      localOrderId: expected.localOrderKey,
      localStageId: serviceRoute.local.stageKey,
      localHookId: hookKey("sourcing.manufacture#EXECUTE"),
      targetPlanId: expected.targetPlanId,
      linkedOrderId: expected.linkedOrderId,
      targetPort: "execute",
      targetSignalId: birthBinding.targetSignalId,
      sequence: 0,
    }),
    expected.inputPayloadHash,
  );

  assert.equal(
    dockInputIdempotencyKey({
      dockInstanceId: expected.dockInstanceId,
      inputBindingHash: birthBinding.bindingHash,
      localHookReadyOccurrence: 0n,
    }),
    expected.inputIdempotencyKey,
  );

  assert.equal(
    dockOutputIdempotencyKey({
      dockInstanceId: expected.dockInstanceId,
      outputBindingHash: completedOutput.bindingHash,
      targetFactId: signalKey(
        interfaceNameKey("factory"),
        interfaceNameKey("manufacturing.produce.cmp"),
      ),
    }),
    expected.outputIdempotencyKey,
  );
});

test("merkle proofs from the golden fixture verify against the roots", () => {
  const serviceRoute = findRoute("production_service");
  const evidenceRoute = findRoute("production_evidence");
  assert.ok(
    verifyMerkleProof(
      expected.dockRoutesRoot,
      serviceRoute.routeHash,
      expected.routeLeafProof,
    ),
  );
  assert.ok(
    !verifyMerkleProof(
      expected.dockRoutesRoot,
      stageKey("not-a-leaf"),
      expected.routeLeafProof,
    ),
  );
  // TS 侧重建的 proof 与 Rust 提供的 proof 逐字相同。
  assert.deepEqual(
    merkleProof(
      parentPlan.dockRoutes.map((route) => route.routeHash),
      serviceRoute.routeHash,
    ),
    expected.routeLeafProof,
  );

  const serviceInterface = targetInterface.interfaces.find(
    (entry) => entry.name === "production_service",
  )!;
  const evidenceInterface = targetInterface.interfaces.find(
    (entry) => entry.name === "production_evidence",
  )!;
  assert.ok(
    verifyMerkleProof(
      expected.interfaceArtifact.interfaceRoot,
      serviceInterface.interfaceRoot,
      expected.interfaceLeafProof,
    ),
  );
  assert.deepEqual(
    merkleProof(
      targetInterface.interfaces.map((entry) => entry.interfaceRoot),
      serviceInterface.interfaceRoot,
    ),
    expected.interfaceLeafProof,
  );

  const executeLeaf = serviceInterface.inputs.find(
    (port) => port.port === "execute",
  )!.leafHash;
  assert.ok(
    verifyMerkleProof(
      serviceInterface.inputsRoot,
      executeLeaf,
      expected.inputPortLeafProof,
    ),
  );
  assert.deepEqual(
    merkleProof(
      serviceInterface.inputs.map((port) => port.leafHash),
      executeLeaf,
    ),
    expected.inputPortLeafProof,
  );
  void evidenceInterface;
  void evidenceRoute;
});

test("EIP-712 entrance permit digest matches the golden vector (V2 typehash, version 3)", () => {
  const inputs = fixture.inputs;
  const serviceRoute = findRoute("production_service");
  const digest = eip712PermitDigest({
    chainId: BigInt(inputs.chainId),
    verifyingContract: inputs.dockingModuleAddress,
    version: fixture.constants.permitDomainVersion,
    targetPlanId: expected.targetPlanId,
    targetEntrancePortId: interfaceNameKey("execute"),
    interfaceNameId: interfaceNameKey("production_service"),
    localPlanId: inputs.parentPlanIdWord,
    routeHash: serviceRoute.routeHash,
    dockInstanceId: expected.dockInstanceId,
    linkedOrderId: expected.linkedOrderId,
    nonce: 1,
    deadline: 2000000000,
  });
  assert.equal(digest, expected.permitDigest);
});

test("golden routes satisfy the TS commitment recomputation", () => {
  // dock-validation 的逐 word 重算对 golden 产物零 issue（fail-closed 镜像）。
  assert.deepEqual(
    validateDockCommitments({
      dockRoutes: parentPlan.dockRoutes,
      dockRoutesRoot: parentPlan.dockRoutesRoot,
      dockInterface: targetPlan.dockInterface,
      dockInterfaceRoot: targetPlan.dockInterfaceRoot,
    }),
    [],
  );
  // 篡改任一 leafHash/bindingHash/routeHash 必须被重算路径捕获。
  const tamperedRoute = structuredClone(findRoute("production_service")) as DockRouteV2;
  const tamperedBinding = tamperedRoute.outputBindings[0] as unknown as
    | Record<string, unknown>
    | undefined;
  assert.ok(tamperedBinding, "production_service route has output bindings");
  tamperedBinding.bindingHash = `0x${"0".repeat(63)}7`;
  const routeIssues = validateDockCommitments({
    dockRoutes: [tamperedRoute as unknown as DockRouteV2],
    dockRoutesRoot: merkleRoot([tamperedRoute.routeHash]),
    dockInterface: null,
    dockInterfaceRoot: EMPTY_MERKLE_ROOT,
  });
  assert.ok(
    routeIssues.some((issue) =>
      /outputBindings\[0\]\.bindingHash must match the recomputed/.test(issue),
    ),
    routeIssues.join("; "),
  );
  const tamperedInterface = structuredClone(targetPlan.dockInterface!) as DockInterfaceArtifactV2;
  const service = tamperedInterface.interfaces.find(
    (entry) => entry.name === "production_service",
  ) as unknown as Record<string, unknown>;
  service.orderModes = ["existing"];
  const interfaceIssues = validateDockCommitments({
    dockRoutes: [],
    dockRoutesRoot: EMPTY_MERKLE_ROOT,
    dockInterface: tamperedInterface,
    dockInterfaceRoot: tamperedInterface.interfaceRoot,
  });
  assert.ok(
    interfaceIssues.some((issue) =>
      /interfaceRoot must match the recomputed interface-leaf preimage/.test(issue),
    ),
    interfaceIssues.join("; "),
  );
});

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
  dockCandidateLeaf,
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
  ZERO_WORD,
} from "../src/dock.js";
import {
  DOCK_INTERFACE_ARTIFACT_SCHEMA_VERSION,
  DOCK_RESOLUTION_SCHEMA_VERSION,
  DOCK_ROUTE_SCHEMA_VERSION,
  type DockInterfaceArtifactV2,
  type DockOrderMode,
  type DockResolutionManifest,
  type DockRouteInputBinding,
  type DockRouteV2,
  type HexString,
  type ZhixuDefinition,
} from "../src/types/index.js";
import { commitmentUidVector } from "./commitment-golden.js";

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
    readonly existingEvmTargetOrderRef: `0x${string}`;
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
    readonly existingEvmDockInstanceId: `0x${string}`;
    readonly dynamicSelection: {
      readonly routeId: `0x${string}`;
      readonly candidateLeaf: `0x${string}`;
      readonly otherCandidateLeaf: `0x${string}`;
      readonly candidatesRoot: `0x${string}`;
      readonly candidateProof: readonly `0x${string}`[];
      readonly candidateProofLength: number;
      readonly dynamicRouteHash: `0x${string}`;
    };
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
  assert.equal(fixture.constants.domains.definitionUid, "uvp:definition-uid:v2");
  assert.equal(fixture.constants.domains.dockInstance, "UVP_DOCK_INSTANCE_V2");
  assert.equal(fixture.constants.domains.dockInterface, "UVP_DOCK_INTERFACE_V2");
  assert.equal(
    fixture.constants.domains.interfaceInput,
    "UVP_DOCK_INTERFACE_INPUT_V2",
  );
  assert.equal(
    fixture.constants.domains.interfaceOutput,
    "UVP_DOCK_INTERFACE_OUTPUT_V3",
  );
  assert.equal(fixture.constants.domains.inputBinding, "UVP_DOCK_INPUT_BINDING_V2");
  assert.equal(
    fixture.constants.domains.outputBinding,
    "UVP_DOCK_OUTPUT_BINDING_V2",
  );
  assert.equal(fixture.constants.domains.route, "UVP_DOCK_ROUTE_V3");
  assert.equal(fixture.constants.domains.routeId, "UVP_DOCK_ROUTE_ID_V1");

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
  assert.equal(definitionUid(fixture.targetDefinition), fixture.identities.targetUid);
  assert.equal(definitionUid(fixture.parentDefinition), fixture.identities.parentUid);
  assert.match(fixture.identities.targetUid, /^zx-[0-9a-f]{32}$/);

  const uidVector = commitmentUidVector("minimal_cloud_definition");
  assert.equal(
    definitionUid(uidVector.input.definition),
    uidVector.expected.uid,
  );

  const displayOnly = structuredClone(fixture.targetDefinition) as ZhixuDefinition & {
    metadata: {
      name: string;
      annotations?: Record<string, string>;
      labels?: Record<string, string>;
    };
  };
  displayOnly.metadata.annotations = { doc: "parity-probe" };
  assert.equal(definitionUid(displayOnly), fixture.identities.targetUid);
  displayOnly.metadata.name = "renamed_target";
  assert.equal(definitionUid(displayOnly), fixture.identities.targetUid);
  const renamedOnly = {
    ...structuredClone(fixture.targetDefinition),
    metadata: { ...fixture.targetDefinition.metadata, name: "renamed_target" },
  };
  assert.equal(definitionUid(renamedOnly), definitionUid(fixture.targetDefinition));
  assert.equal(definitionUid(displayOnly), definitionUid(renamedOnly));
  displayOnly.metadata.labels = { site: "factory-a" };
  assert.notEqual(definitionUid(displayOnly), fixture.identities.targetUid);

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

  assert.equal(parentPlan.zhixuId, fixture.identities.parentUid);
  assert.deepEqual(parentPlan.dockRoutes, expected.dockRoutes);
  assert.equal(parentPlan.dockRoutesRoot, expected.dockRoutesRoot);
  assert.equal(parentPlan.dockInterface, null);
  assert.equal(parentPlan.dockInterfaceRoot, EMPTY_MERKLE_ROOT);

  for (const route of parentPlan.dockRoutes) {
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
        targetPlanId: route.target.chainPlanId,
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
  assert.equal(
    interfaceNameKey("production_service"),
    expected.interfaceNameIds.production_service,
  );
  assert.equal(
    interfaceNameKey("production_evidence"),
    expected.interfaceNameIds.production_evidence,
  );

  const instance = dockInstanceId({
    runtimeDomain: expected.evmRuntimeDomain,
    localPlanId: inputs.parentPlanIdWord,
    localDefinitionRefHash: expected.parentDefinitionRefHash,
    localOrderKey: expected.localOrderKey,
    routeId: serviceRoute.routeId,
    routeHash: serviceRoute.routeHash,
    orderMode: "new",
    interfaceName: "production_service",
    targetPlanId: expected.targetPlanId,
  });
  assert.equal(instance, expected.dockInstanceId);
  assert.equal(
    linkedOrderId(instance, expected.targetDefinitionRefHash),
    expected.linkedOrderId,
  );
  assert.notEqual(
    dockInstanceId({
      runtimeDomain: expected.evmRuntimeDomain,
      localPlanId: inputs.parentPlanIdWord,
      localDefinitionRefHash: expected.parentDefinitionRefHash,
      localOrderKey: expected.localOrderKey,
      routeId: serviceRoute.routeId,
      routeHash: serviceRoute.routeHash,
      orderMode: "new",
      interfaceName: "production_service",
      targetPlanId: inputs.parentPlanIdWord,
    }),
    expected.dockInstanceId,
  );

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
      targetPlanId: expected.targetPlanId,
      targetOrderRef: inputs.existingTargetOrderRef,
    }),
    expected.existingDockInstanceId,
  );
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
      targetPlanId: expected.targetPlanId,
      targetOrderRef: "factory-a/P002",
    }),
    expected.existingDockInstanceId,
  );
  assert.equal(
    targetOrderRefKey(inputs.existingTargetOrderRef).length,
    66,
  );
});

test("existing evm instance and dynamic-selection vectors match the golden", () => {
  const inputs = fixture.inputs;
  const dynamic = expected.dynamicSelection;
  const evidenceRoute = findRoute("production_evidence");

  assert.equal(inputs.existingEvmTargetOrderRef.length, 66);
  assert.equal(
    dockInstanceId({
      runtimeDomain: expected.evmRuntimeDomain,
      localPlanId: inputs.parentPlanIdWord,
      localDefinitionRefHash: expected.parentDefinitionRefHash,
      localOrderKey: expected.localOrderKey,
      routeId: evidenceRoute.routeId,
      routeHash: evidenceRoute.routeHash,
      orderMode: "existing",
      interfaceName: "production_evidence",
      targetPlanId: expected.targetPlanId,
      targetOrderRef: inputs.existingEvmTargetOrderRef,
    }),
    expected.existingEvmDockInstanceId,
  );

  const candidateLeaf = dockCandidateLeaf({
    routeId: dynamic.routeId,
    targetDefinitionRefHash: expected.targetDefinitionRefHash,
    targetPlanId: expected.targetPlanId,
    interfaceName: "production_evidence",
  });
  assert.equal(candidateLeaf, dynamic.candidateLeaf);
  assert.equal(
    verifyMerkleProof(dynamic.candidatesRoot, dynamic.candidateLeaf, dynamic.candidateProof),
    true,
  );
  assert.equal(
    routeHash({
      localDefinitionRefHash: expected.parentDefinitionRefHash,
      targetDefinitionRefHash: dynamic.candidatesRoot,
      targetPlanId: ZERO_WORD,
      interfaceName: "production_evidence",
      orderMode: "existing",
      inputBindingsRoot: EMPTY_MERKLE_ROOT,
      outputBindingsRoot: EMPTY_MERKLE_ROOT,
    }),
    dynamic.dynamicRouteHash,
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
      canonicalSignalHash("purchaser::confirm.cmp"),
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
      localHookId: hookKey("manufacture#EXECUTE"),
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
        interfaceNameKey("produce.cmp"),
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

test("EIP-712 entrance permit digest matches the golden vector (V2 typehash, version 4)", () => {
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

test("chainId overflow guard rejects >=2^64, negative, and fractional chain ids", () => {
  const inputs = fixture.inputs;
  assert.doesNotThrow(() =>
    evmRuntimeDomain(0xffffffffffffffffn, inputs.stateMachineAddress),
  );
  assert.throws(
    () => evmRuntimeDomain(1n << 64n, inputs.stateMachineAddress),
    /chainId must fit the 64-bit range \(< 2\^64\)/,
  );
  assert.throws(
    () => evmRuntimeDomain(2n ** 128n, inputs.stateMachineAddress),
    /chainId must fit the 64-bit range \(< 2\^64\)/,
  );
  assert.throws(
    () => evmRuntimeDomain(-1n, inputs.stateMachineAddress),
    /chainId must be a non-negative chain id/,
  );
  assert.throws(
    () => evmRuntimeDomain(1.5, inputs.stateMachineAddress),
    /chainId must be an integer chain id/,
  );
  assert.throws(
    () => evmRuntimeDomain(1e19, inputs.stateMachineAddress),
    /chainId must be a safe integer chain id/,
  );
  const permitInput = {
    verifyingContract: inputs.dockingModuleAddress,
    targetPlanId: expected.targetPlanId,
    targetEntrancePortId: interfaceNameKey("execute"),
    interfaceNameId: interfaceNameKey("production_service"),
    localPlanId: inputs.parentPlanIdWord,
    routeHash: findRoute("production_service").routeHash,
    dockInstanceId: expected.dockInstanceId,
    linkedOrderId: expected.linkedOrderId,
    nonce: 1,
    deadline: 2000000000,
  };
  assert.doesNotThrow(() => eip712PermitDigest({ ...permitInput, chainId: 1n }));
  assert.throws(
    () => eip712PermitDigest({ ...permitInput, chainId: 1n << 64n }),
    /chainId must fit the 64-bit range \(< 2\^64\)/,
  );
  assert.throws(
    () => eip712PermitDigest({ ...permitInput, chainId: -31337n }),
    /chainId must be a non-negative chain id/,
  );
  assert.throws(
    () => eip712PermitDigest({ ...permitInput, chainId: 31337.5 }),
    /chainId must be an integer chain id/,
  );
});

test("golden routes satisfy the TS commitment recomputation", () => {
  assert.deepEqual(
    validateDockCommitments({
      dockRoutes: parentPlan.dockRoutes,
      dockRoutesRoot: parentPlan.dockRoutesRoot,
      dockInterface: targetPlan.dockInterface,
      dockInterfaceRoot: targetPlan.dockInterfaceRoot,
    }),
    [],
  );
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

test("an attach cannot bind two inputs to the same target fact key", () => {
  const route = structuredClone(findRoute("production_service")) as DockRouteV2;
  const first = route.inputBindings[0] as DockRouteInputBinding;
  assert.ok(first, "production_service route has an input binding");
  const duplicatePort = first.targetPort === "evidence_pkg" ? "evidence_alt" : "evidence_pkg";
  const duplicate = {
    ...first,
    targetPort: duplicatePort,
    bindingHash: inputBindingHash({
      routeId: route.routeId,
      interfaceName: route.target.interfaceName,
      localHookId: `${route.local.stageIdentifier}#${first.localHookName}`,
      portName: duplicatePort,
      targetSourceId: first.targetSourceId,
      targetSignalId: first.targetSignalId,
    }),
  };
  const tampered = {
    ...route,
    inputBindings: [...route.inputBindings, duplicate],
  } as unknown as DockRouteV2;
  const issues = validateDockCommitments({
    dockRoutes: [tampered],
    dockRoutesRoot: merkleRoot([route.routeHash]),
    dockInterface: null,
    dockInterfaceRoot: EMPTY_MERKLE_ROOT,
  });
  assert.ok(
    issues.some((issue) =>
      /targets fact key .* already bound by an earlier input of the same attach/.test(issue),
    ),
    issues.join("; "),
  );
});

test("localOrderKey and targetOrderRefKey keep EVM word ids verbatim", () => {
  const word = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef" as `0x${string}`;
  assert.equal(localOrderKey(word), word);
  assert.equal(targetOrderRefKey(word), word);
  assert.notEqual(localOrderKey("order-fixture-001"), "order-fixture-001");
  assert.match(localOrderKey("order-fixture-001"), /^0x[0-9a-f]{64}$/u);
});

test("permit nonce/deadline reject non-canonical string and unsafe number forms (L10)", () => {
  const permitInput = {
    chainId: 31337,
    verifyingContract: fixture.inputs.dockingModuleAddress,
    targetPlanId: expected.targetPlanId,
    targetEntrancePortId: interfaceNameKey("execute"),
    interfaceNameId: interfaceNameKey("production_service"),
    localPlanId: fixture.inputs.parentPlanIdWord,
    routeHash: findRoute("production_service").routeHash,
    dockInstanceId: expected.dockInstanceId,
    linkedOrderId: expected.linkedOrderId,
  };
  assert.throws(
    () =>
      eip712PermitDigest({
        ...permitInput,
        nonce: "0x10" as unknown as number,
        deadline: 2000000000,
      }),
    /permit nonce must be an integer \(bigint, safe number, or canonical base-10 string/,
  );
  assert.throws(
    () =>
      eip712PermitDigest({
        ...permitInput,
        nonce: 1,
        deadline: "0x10" as unknown as number,
      }),
    /permit deadline must be an integer \(bigint, safe number, or canonical base-10 string/,
  );
  for (const bad of ["01", "1.0", "-1", "1e3", ""]) {
    assert.throws(
      () =>
        eip712PermitDigest({
          ...permitInput,
          nonce: bad as unknown as number,
          deadline: 2000000000,
        }),
      /permit nonce must be an integer/,
      `nonce=${JSON.stringify(bad)} must be rejected`,
    );
  }
  assert.throws(
    () =>
      eip712PermitDigest({
        ...permitInput,
        nonce: 2 ** 60,
        deadline: 2000000000,
      }),
    /permit nonce must be a safe integer/,
  );
  assert.doesNotThrow(() =>
    eip712PermitDigest({
      ...permitInput,
      nonce: "1",
      deadline: "2000000000",
    }),
  );
  assert.doesNotThrow(() =>
    eip712PermitDigest({
      ...permitInput,
      nonce: 1n,
      deadline: 2000000000n,
    }),
  );
});

import assert from "node:assert/strict";
import test from "node:test";
import { EMPTY_MERKLE_ROOT, verifyMerkleProof } from "../src/merkle.js";
import { definitionUid } from "../src/identity.js";
import { canonicalJson } from "@uvp-eth/canonical-json";
import {
  assertOnchainHookPlanArtifact,
  compileZhixuOnchainHookPlan,
  supplierBindingsRootOf,
  hashSolidityRegisterHooks,
  keccak256Hex,
  supplierIdFromUuid,
  onchainSelectorBindingHash,
  OnchainHookPlanArtifactValidationError,
  toSolidityRegisterPlanArgs,
  validateOnchainHookPlanArtifact,
  type OnchainHookPlanArtifact,
  type OnchainSignalInstruction,
  type ZhixuDefinition,
} from "../src/index.js";
import {
  compileZhixuHookPlan,
  compareCanonicalKey,
  HookPlanCompilationError,
} from "../src/hook-plan.js";
import { hookPlanHashOf } from "../src/hook-plan/assemble.js";
import { compileOnchainHookPlan } from "../src/onchain/compile.js";
import { hashOnchainPlanPayload } from "../src/onchain/hash/plan.js";
import {
  artifactCapabilitiesRoot,
  capabilitiesRootOf,
  capabilityTablesOf,
  selectorBindingLeaf,
  selectorBindingProof,
  signalCapabilityLeaf,
  signalCapabilityProof,
} from "../src/onchain/capabilities-root.js";
import { fileWriterLeaf, fileWriterProof } from "../src/index.js";
import {
  onchainSignalId,
  onchainSignalKey,
  onchainSourceId,
  onchainStageId,
  onchainSignalCapabilityHash,
} from "../src/onchain/hash/route.js";
import type { HookPlanArtifact } from "../src/types/index.js";
import {
  commitmentGoldenCase,
  commitmentGoldenVectors,
  commitmentRegisterHooksArgs,
  commitmentRegisterHooksVector,
} from "./commitment-golden.js";

function resign<A extends { planHash: string }>(artifact: A): A {
  return {
    ...artifact,
    planHash: hookPlanHashOf(artifact as unknown as HookPlanArtifact),
  };
}

function replaceDelay(node: unknown, seconds: number): unknown {
  if (Array.isArray(node)) {
    return node.map((item) => replaceDelay(item, seconds));
  }
  if (node === null || typeof node !== "object") {
    return node;
  }
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(node)) {
    out[key] = key === "durationSeconds" ? seconds : replaceDelay(value, seconds);
  }
  return out;
}

function rebuildDependencyIndex(
  hooks: readonly { hookId: string; dependencies: readonly { source: string; signalName: string }[] }[],
): Record<string, string[]> {
  const index = new Map<string, string[]>();
  for (const hook of hooks) {
    for (const dependency of hook.dependencies) {
      const key = `${dependency.source}::${dependency.signalName}`;
      const hookIds = index.get(key) ?? [];
      if (!hookIds.includes(hook.hookId)) {
        hookIds.push(hook.hookId);
      }
      index.set(key, hookIds);
    }
  }
  return Object.fromEntries(
    [...index.entries()]
      .sort(([left], [right]) => compareCanonicalKey(left, right))
      .map(([key, hookIds]) => [
        key,
        [...hookIds].sort(compareCanonicalKey),
      ]),
  );
}

const SUPPLIER_SELECTOR = "5f0b1e2a-7c9d-4e1f-9a2b-000000000001";
const SUPPLIER_WORK = "5f0b1e2a-7c9d-4e1f-9a2b-000000000002";
const SUPPLIER_WATCHER = "5f0b1e2a-7c9d-4e1f-9a2b-000000000003";
const SUPPLIER_FULFILLER = "5f0b1e2a-7c9d-4e1f-9a2b-000000000004";
const SUPPLIER_ROUTING = "5f0b1e2a-7c9d-4e1f-9a2b-000000000005";

const baseZhixu: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: {
    name: "demo_zhixu",
  },
  spec: {
    platform: {
      type: "cloud",
    },
    nucleation: {
      id: "core",
    },
    stages: [{
        name: "assign",
        source: "buyer",
        selectedStages: ["main"],
        receiveSignals: {
          PLACE: "buyer::assign.seed",
        },
        sendSignals: [{ name: "executor_selected" }, { name: "seed" }],
        executor: {
          supplierType: "organization",
          supplierID: SUPPLIER_SELECTOR,
        },
      },
{
        name: "main",
        source: "buyer",
        receiveSignals: {
          START: "buyer::assign.executor_selected",
          TIMEOUT:
            "buyer::(assign.executor_selected +5s) & ~main.cmp",
        },
        sendSignals: [{ name: "str" }, { name: "cmp" }, { name: "err" }],
        executor: {
          supplierType: "organization",
          supplierID: SUPPLIER_WORK,
        },
      }],
  },
};

test("compiles a stable compact on-chain HookPlan artifact", () => {
  const sourcePlan = compileZhixuHookPlan(baseZhixu);
  const onchain = compileOnchainHookPlan(sourcePlan);
  const again = compileZhixuOnchainHookPlan(baseZhixu);

  assert.deepEqual(onchain, again);
  assert.equal(onchain.schemaVersion, "uvp.onchainHookPlan.v8");
  assert.equal(onchain.planId, sourcePlan.planId);
  assert.deepEqual(onchain.platform, sourcePlan.platform);
  assert.equal(onchain.sourcePlanHash, sourcePlan.planHash);
  const { planHash: _onchainPlanHash, ...onchainPayload } = onchain;
  assert.equal(onchain.planHash, hashOnchainPlanPayload(onchainPayload));
  assert.equal(onchain.supplierBindings.length, 2);
  assert.deepEqual(
    onchain.supplierBindings.map((binding) => binding.kind),
    [0, 0],
  );
  assert.equal(
    onchain.supplierBindingsRoot,
    supplierBindingsRootOf(onchain.supplierBindings),
  );
  assert.equal(
    onchain.capabilitiesRoot,
    capabilitiesRootOf(
      onchain.selectorBindings.map((binding) => ({
        selectorStageId: binding.selectorStageId,
        targetStageId: binding.targetStageId,
      })),
      onchain.signalCapabilities.map((capability) => ({
        stageId: capability.stageId,
        targetSourceId: capability.targetSourceId,
        signalId: capability.signalId,
        targetOrderRelation: capability.targetOrderRelation === "current" ? 0 : 1,
      })),
    ),
  );
  assert.deepEqual(onchain.selectorBindings, [
    {
      selectorStageIdentifier: "assign",
      targetStageIdentifier: "main",
      selectorStageId: keccak256Hex("assign"),
      targetStageId: keccak256Hex("main"),
      bindingHash: onchainSelectorBindingHash(
        keccak256Hex("assign"),
        keccak256Hex("main"),
      ),
    },
  ]);
  assert.deepEqual(
    onchain.signalCapabilities.map((capability) => [
      capability.stageIdentifier,
      capability.targetSource,
      capability.targetSignalName,
      capability.targetOrderRelation,
    ]),
    [
      ["assign", "buyer", "assign.seed", "current"],
      [
        "assign",
        "buyer",
        "assign.executor_selected",
        "current",
      ],
      ["main", "buyer", "main.str", "current"],
      ["main", "buyer", "main.err", "current"],
      ["main", "buyer", "main.cmp", "current"],
    ],
  );
  assert.equal(onchain.compiledHooks.length, 3);
  assert.equal(
    onchain.compiledHooks[1]?.hookId,
    keccak256Hex("main#START"),
  );
  assert.equal(
    onchain.compiledHooks[1]?.stageId,
    keccak256Hex("main"),
  );

  const startSignal = onchain.compiledHooks[1]
    ?.instructions[0] as OnchainSignalInstruction;
  assert.equal(startSignal.sourceId, keccak256Hex("buyer"));
  assert.equal(
    startSignal.signalId,
    keccak256Hex("assign.executor_selected"),
  );
  assert.equal(
    startSignal.signalKey,
    "0x1b1de81020b6a7096a0b9065a7794434b919e4672276725e9db798cf42be930d",
  );

  assert.deepEqual(validateOnchainHookPlanArtifact(onchain), []);
  assert.doesNotThrow(() => assertOnchainHookPlanArtifact(onchain));
});

test("compiles Hook AST nodes to stable on-chain instruction arrays", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu));
  const timeoutHook = onchain.compiledHooks.find(
    (hook) => hook.hookName === "TIMEOUT",
  );

  assert.deepEqual(timeoutHook?.instructions, [
    {
      op: "SIGNAL",
      source: "buyer",
      signalName: "assign.executor_selected",
      sourceId:
        "0x9c1bfc34ea7e295ac684c026c6d4de765734cb6b37fa07330bcfc241743ebbaf",
      signalId:
        "0xa5deb3301e6adb05d817001102db90a89e616cbb0b973d8c2d9804de3c9023ee",
      signalKey:
        "0x1b1de81020b6a7096a0b9065a7794434b919e4672276725e9db798cf42be930d",
    },
    {
      op: "DELAY",
      delaySeconds: 5,
    },
    {
      op: "SIGNAL",
      source: "buyer",
      signalName: "main.cmp",
      sourceId:
        "0x9c1bfc34ea7e295ac684c026c6d4de765734cb6b37fa07330bcfc241743ebbaf",
      signalId:
        "0xfc048ed71eb35af7cf07cd3fd924feda583a9c3fb1bef1ad593f2472956ca060",
      signalKey:
        "0x25414fc8fc1bb291d8a071f2578468f9e877eb0d5a9feca914c77e8371f87d2f",
    },
    {
      op: "NOT",
    },
    {
      op: "AND",
      arity: 2,
    },
  ]);

  const orZhixu: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: baseZhixu.spec.stages.map((stage) =>
        stage.name !== "main"
          ? stage
          : {
              ...stage,
              receiveSignals: {
                ...stage.receiveSignals,
                ALT: "buyer::main.str | main.err",
              },
            },
      ),
    },
  };
  const orHook = compileOnchainHookPlan(
    compileZhixuHookPlan(orZhixu),
  ).compiledHooks.find((hook) => hook.hookName === "ALT");

  assert.deepEqual(
    orHook?.instructions.map((instruction) => instruction.op),
    ["SIGNAL", "SIGNAL", "OR"],
  );
  assert.deepEqual(orHook?.instructions[2], { op: "OR", arity: 2 });
});

test("builds a stable on-chain dependency index and route references", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu));

  assert.deepEqual(onchain.dependencyIndex, {
    "0x25414fc8fc1bb291d8a071f2578468f9e877eb0d5a9feca914c77e8371f87d2f": [
      "0x06bd2f15baa717eaf5dd21f3fe27553dfdf46b39fba3ec0307af57fa21e12b5b",
    ],
    "0xb54bec63127fe06ab8c13d6946d6ebcccf61559e49a9fcf8b44e77c15cc990fc": [
      "0xc04b87f873ad87ab715a6832a137ec6385d144adb11f87bb75fc74af7252f365",
    ],
    "0x1b1de81020b6a7096a0b9065a7794434b919e4672276725e9db798cf42be930d": [
      "0xba0b51c636886102cf9187a49d54f74059f630f8a08c22a301144b7bf0a06a64",
      "0x06bd2f15baa717eaf5dd21f3fe27553dfdf46b39fba3ec0307af57fa21e12b5b",
    ],
  });

  assert.deepEqual(
    onchain.supplierRoutes.map((route) => route.routeId),
    [
      "0x320cb9a7512c3259a18b51e46118fb023d0dbc780811958feedb1b630bae7b55",
      "0x2a05600dd140e0e8053c65920cd602198cefa5b52886a12003680905eb82de67",
    ],
  );
  assert.equal(
    onchain.compiledHooks.find((hook) => hook.hookName === "START")?.routeRef
      ?.routeId,
    "0x2a05600dd140e0e8053c65920cd602198cefa5b52886a12003680905eb82de67",
  );
});

test("dependencyIndex hookIds follow calldata order, not keccak order (oracle pairing)", () => {
  const zhixu: ZhixuDefinition = {
    ...baseZhixu,
    metadata: {
      name: "shared_key_order_demo",
    },
    spec: {
      ...baseZhixu.spec,
      stages: [{
          name: "stage",
          source: "buyer",
          receiveSignals: {
            FIRST: "buyer::stage.seed",
            SECOND: "buyer::stage.seed",
          },
          sendSignals: [{ name: "seed" }],
          executor: {
            supplierType: "organization",
            supplierID: SUPPLIER_WATCHER,
          },
        }],
    },
  };
  const onchain = compileZhixuOnchainHookPlan(zhixu);
  const seedKey = onchainSignalKey(
    onchainSourceId("buyer"),
    onchainSignalId("stage.seed"),
  );
  const calldataOrder = onchain.compiledHooks.map((hook) => hook.hookId);
  assert.deepEqual(
    onchain.compiledHooks.map((hook) => hook.hookName),
    ["FIRST", "SECOND"],
  );
  assert.notDeepEqual([...calldataOrder].sort(), calldataOrder);
  assert.deepEqual(onchain.dependencyIndex[seedKey], calldataOrder);

  const args = toSolidityRegisterPlanArgs(onchain);
  assert.deepEqual(
    args.dependencyIndex.find((entry) => entry.signalKey === seedKey)?.hookIds,
    calldataOrder,
  );

  const { planHash: _staleHash, ...payload } = onchain;
  const keccakOrdered = {
    ...payload,
    dependencyIndex: Object.fromEntries(
      Object.entries(payload.dependencyIndex).map(([key, hookIds]) => [
        key,
        [...hookIds].sort(),
      ]),
    ),
  };
  assert.ok(
    validateOnchainHookPlanArtifact({
      ...keccakOrdered,
      planHash: hashOnchainPlanPayload(keccakOrdered),
    }).some(
      (issue) =>
        issue === "dependencyIndex must match on-chain hook dependencies",
    ),
  );
});

test("rejects a repinned capabilitiesRoot that drifts from the capability tables", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu));

  const { planHash: _storedHash, ...payload } = onchain;
  const tampered = {
    ...payload,
    capabilitiesRoot: keccak256Hex("tampered capabilities root"),
  };
  const repinned: OnchainHookPlanArtifact = {
    ...tampered,
    planHash: hashOnchainPlanPayload(tampered),
  };
  assert.ok(
    validateOnchainHookPlanArtifact(repinned).some(
      (issue) =>
        issue ===
        "capabilitiesRoot must match the recomputed root over selector bindings, signal capabilities, and stage file writers",
    ),
  );
  assert.throws(
    () => toSolidityRegisterPlanArgs(repinned),
    /capabilitiesRoot must match the recomputed root/,
  );

  assert.equal(
    onchain.capabilitiesRoot,
    artifactCapabilitiesRoot(onchain),
  );
  assert.equal(
    toSolidityRegisterPlanArgs(onchain).capabilitiesRoot,
    onchain.capabilitiesRoot,
  );
  assert.deepEqual(validateOnchainHookPlanArtifact(onchain), []);
});

test("compiles fileWriters into artifact leaves and the capabilities root", () => {
  const withFileWriters: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: baseZhixu.spec.stages.map((stage) =>
        stage.name === "main" ? { ...stage, fileWriters: ["assign"] } : stage,
      ),
    },
  };
  const without = compileZhixuOnchainHookPlan(baseZhixu);
  const withWriters = compileZhixuOnchainHookPlan(withFileWriters);

  assert.deepEqual(without.stageFileWriters, []);
  const [binding] = withWriters.stageFileWriters;
  assert.ok(binding);
  const targetStageId = onchainStageId("main");
  const writerStageId = onchainStageId("assign");
  assert.deepEqual(binding, {
    targetStageIdentifier: "main",
    targetStageId,
    writerStageIdentifier: "assign",
    writerStageId,
    fileWriterLeaf: fileWriterLeaf(targetStageId, writerStageId),
  });

  const tables = capabilityTablesOf(withWriters);
  assert.equal(
    withWriters.capabilitiesRoot,
    capabilitiesRootOf(
      tables.selectorBindings,
      tables.signalCapabilities,
      tables.fileWriterBindings,
    ),
  );
  assert.notEqual(withWriters.capabilitiesRoot, without.capabilitiesRoot);
  assert.notEqual(withWriters.planHash, without.planHash);

  const proof = fileWriterProof(
    tables.selectorBindings,
    tables.signalCapabilities,
    tables.fileWriterBindings,
    targetStageId,
    writerStageId,
  );
  assert.ok(proof);
  assert.equal(
    verifyMerkleProof(
      withWriters.capabilitiesRoot,
      fileWriterLeaf(targetStageId, writerStageId),
      proof,
    ),
    true,
  );
  assert.deepEqual(validateOnchainHookPlanArtifact(withWriters), []);

  const { planHash: _staleHash, ...payload } = withWriters;
  const tampered = {
    ...payload,
    stageFileWriters: [
      {
        ...binding,
        fileWriterLeaf: keccak256Hex("tampered file writer leaf"),
      },
    ],
  };
  assert.deepEqual(validateOnchainHookPlanArtifact({
    ...tampered,
    planHash: hashOnchainPlanPayload(tampered),
  }), [
    'stageFileWriters[0].fileWriterLeaf must match keccak256("UVP_FILE_WRITER_V1", targetStageId, writerStageId)',
  ]);
});

test("maps on-chain artifacts to Solidity register-plan argument shape", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu));
  const args = toSolidityRegisterPlanArgs(onchain);

  assert.equal(args.schemaVersion, "uvp.onchainHookPlan.v8");
  assert.equal(args.sourcePlanId, onchain.planId);
  const { planHash: _storedPlanHash, ...artifactPayload } = onchain;
  assert.equal(args.artifactHash, hashOnchainPlanPayload(artifactPayload));
  assert.notEqual(args.planHash, args.artifactHash);
  assert.match(args.hooksHash, /^0x[0-9a-f]{64}$/);
  assert.match(args.capabilitiesRoot, /^0x[0-9a-f]{64}$/);
  assert.equal(args.hooks[2]?.hookName, keccak256Hex("TIMEOUT"));
  assert.deepEqual(
    args.hooks[2]?.instructions.map((instruction) => instruction.op),
    ["SIGNAL", "DELAY", "SIGNAL", "NOT", "AND"],
  );
  assert.equal(args.dependencyIndex.length, 3);
  assert.deepEqual(
    args.supplierRoutes.map((route) => route.supplierID),
    [SUPPLIER_SELECTOR, SUPPLIER_WORK],
  );
  assert.deepEqual(args.supplierBindings, [
    {
      stageId: keccak256Hex("assign"),
      supplierId: supplierIdFromUuid(SUPPLIER_SELECTOR),
      kind: 0,
    },
    {
      stageId: keccak256Hex("main"),
      supplierId: supplierIdFromUuid(SUPPLIER_WORK),
      kind: 0,
    },
  ]);
  assert.equal(args.supplierBindingsRoot, onchain.supplierBindingsRoot);
  assert.deepEqual(args.selectorBindings, [
    {
      selectorStageId: keccak256Hex("assign"),
      targetStageId: keccak256Hex("main"),
    },
  ]);
  assert.deepEqual(
    args.signalCapabilities.map((capability) => capability.targetOrderRelation),
    [0, 0, 0, 0, 0],
  );
});

test("includes selector bindings in on-chain plan hash", () => {
  const withBinding = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu));
  const withoutSelectedStages: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: baseZhixu.spec.stages.map((stage) => ({
        ...stage,
        selectedStages: [],
      })),
    },
  };
  const withoutBinding = compileOnchainHookPlan(
    compileZhixuHookPlan(withoutSelectedStages),
  );

  assert.deepEqual(withoutBinding.selectorBindings, []);
  assert.notEqual(withBinding.planHash, withoutBinding.planHash);
});

test("capability tables feed the capabilitiesRoot and the runtime plan hash", () => {
  const withBinding = toSolidityRegisterPlanArgs(
    compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu)),
  );
  const withoutBinding = toSolidityRegisterPlanArgs(
    compileOnchainHookPlan(
      compileZhixuHookPlan(
        {
          ...baseZhixu,
          spec: {
            ...baseZhixu.spec,
            stages: baseZhixu.spec.stages.map((stage) => ({
              ...stage,
              selectedStages: [],
            })),
          },
        },
      ),
    ),
  );

  assert.deepEqual(withoutBinding.selectorBindings, []);
  assert.deepEqual(withBinding.signalCapabilities, withoutBinding.signalCapabilities);
  assert.notEqual(withBinding.capabilitiesRoot, withoutBinding.capabilitiesRoot);
  assert.notEqual(withBinding.planHash, withoutBinding.planHash);
  assert.equal(
    withBinding.capabilitiesRoot,
    capabilitiesRootOf(withBinding.selectorBindings, withBinding.signalCapabilities),
  );
  const bindingProof = selectorBindingProof(
    withBinding.selectorBindings,
    withBinding.signalCapabilities,
    withBinding.selectorBindings[0]!.selectorStageId,
    withBinding.selectorBindings[0]!.targetStageId,
  );
  assert.ok(bindingProof);
  assert.ok(
    verifyMerkleProof(
      withBinding.capabilitiesRoot,
      selectorBindingLeaf(
        withBinding.selectorBindings[0]!.selectorStageId,
        withBinding.selectorBindings[0]!.targetStageId,
      ),
      bindingProof,
    ),
  );
  const leafCapability = withBinding.signalCapabilities[0]!;
  const capabilityProof = signalCapabilityProof(
    withBinding.selectorBindings,
    withBinding.signalCapabilities,
    leafCapability.stageId,
    leafCapability.targetSourceId,
    leafCapability.signalId,
    leafCapability.targetOrderRelation,
  );
  assert.ok(capabilityProof);
  assert.ok(
    verifyMerkleProof(
      withBinding.capabilitiesRoot,
      signalCapabilityLeaf(
        leafCapability.stageId,
        leafCapability.targetSourceId,
        leafCapability.signalId,
        leafCapability.targetOrderRelation,
      ),
      capabilityProof,
    ),
  );
  assert.notEqual(
    withBinding.capabilitiesRoot,
    capabilitiesRootOf(
      withoutBinding.selectorBindings,
      withBinding.signalCapabilities,
    ),
  );
});

test("hooksHash frozen vector pins the zero-word instruction fill cross-language", () => {
  const vector = commitmentRegisterHooksVector("register_hooks_zero_word_fill");

  assert.equal(
    hashSolidityRegisterHooks(commitmentRegisterHooksArgs(vector.input.hooks)),
    vector.expected.hooksHash,
  );
});

test("commitment golden vectors pin uid/planHash/hooksHash from the shared fixture", () => {
  const vectors = commitmentGoldenVectors();
  assert.equal(vectors.uidVectors.length, 1);
  assert.equal(vectors.cases.length, 7);
  assert.equal(vectors.registerHooksVectors.length, 1);

  for (const vector of vectors.uidVectors) {
    assert.equal(
      definitionUid(vector.input.definition),
      vector.expected.uid,
      `${vector.name}: uid`,
    );
  }

  for (const golden of vectors.cases) {
    const { definition, supplierCandidates } = golden.input;
    const plan = compileZhixuHookPlan(definition);
    const onchain = compileZhixuOnchainHookPlan(
      definition,
      supplierCandidates,
    );
    const args = toSolidityRegisterPlanArgs(onchain);

    assert.equal(plan.zhixuId, golden.expected.uid, `${golden.name}: uid`);
    assert.equal(plan.planHash, golden.expected.hookPlanHash, `${golden.name}: IR planHash`);
    assert.equal(onchain.planHash, golden.expected.onchainPlanHash, `${golden.name}: onchain planHash`);
    assert.equal(args.planHash, golden.expected.runtimePlanHash, `${golden.name}: runtime planHash`);
    assert.equal(args.hooksHash, golden.expected.hooksHash, `${golden.name}: hooksHash`);
    assert.equal(args.capabilitiesRoot, golden.expected.capabilitiesRoot, `${golden.name}: capabilitiesRoot`);
    assert.equal(
      onchain.supplierBindingsRoot,
      golden.expected.supplierBindingsRoot,
      `${golden.name}: supplierBindingsRoot`,
    );
    assert.deepEqual(
      onchain.supplierBindings.map((binding) => ({
        stageId: binding.stageId,
        supplierId: binding.supplierId,
        kind: binding.kind,
      })),
      golden.expected.supplierBindings,
      `${golden.name}: supplierBindings`,
    );
    assert.deepEqual(
      args.supplierBindings,
      golden.expected.supplierBindings,
      `${golden.name}: register-args supplierBindings`,
    );

    assert.equal(args.hooks.length, golden.counts.hooks, `${golden.name}: counts.hooks`);
    assert.deepEqual(
      args.hooks.map((hook) => hook.instructions.length),
      golden.counts.instructions,
      `${golden.name}: counts.instructions`,
    );
    assert.deepEqual(
      args.hooks.map((hook) => hook.dependencyKeys.length),
      golden.counts.dependencyKeys,
      `${golden.name}: counts.dependencyKeys`,
    );
    assert.equal(
      hashSolidityRegisterHooks(commitmentRegisterHooksArgs(golden.input.hooks)),
      golden.expected.hooksHash,
      `${golden.name}: pinned hooks array must rehash to the expected hooksHash`,
    );

    assert.equal(
      keccak256Hex(`uvp:hook-plan-artifact:v1:${golden.preimages.hookPlanCanonical}`),
      golden.expected.hookPlanHash,
      `${golden.name}: hookPlanHash preimage rehash`,
    );
    assert.equal(
      keccak256Hex(`uvp:onchain-hook-plan-artifact:v1:${golden.preimages.onchainPlanCanonical}`),
      golden.expected.onchainPlanHash,
      `${golden.name}: onchainPlanHash preimage rehash`,
    );
    assert.equal(
      canonicalJson(JSON.parse(golden.preimages.hookPlanCanonical)),
      golden.preimages.hookPlanCanonical,
      `${golden.name}: hookPlanCanonical must stay in canonical form`,
    );
    assert.equal(
      canonicalJson(JSON.parse(golden.preimages.onchainPlanCanonical)),
      golden.preimages.onchainPlanCanonical,
      `${golden.name}: onchainPlanCanonical must stay in canonical form`,
    );
  }
});

test("cross-stage dependency guard fires on deserialized artifacts and follows contract order", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu));

  const sharedKey = onchainSignalKey(
    onchainSourceId("buyer"),
    onchainSignalId("assign.executor_selected"),
  );
  assert.ok(sharedKey, "base artifact must expose a watcher dependency");
  const watchesSharedKey = (hook: (typeof onchain.compiledHooks)[number]) =>
    hook.orderTriggerKind === "none" &&
    hook.dependencies.some((dependency) => dependency.signalKey === sharedKey);
  const watcherIndex = onchain.compiledHooks.findIndex(watchesSharedKey);
  const laterWatcherIndex = onchain.compiledHooks.findIndex(
    (hook, index) => index > watcherIndex && watchesSharedKey(hook),
  );
  assert.ok(watcherIndex >= 0 && laterWatcherIndex > watcherIndex, "need two shared-key watchers");
  const foreignStageIdentifier = "stage";
  const tamperedHooks = onchain.compiledHooks.map((hook, index) =>
    index === watcherIndex
      ? {
          ...hook,
          stageIdentifier: foreignStageIdentifier,
          stageId: keccak256Hex(foreignStageIdentifier),
          hookId: keccak256Hex(`${foreignStageIdentifier}#${hook.hookName}`),
        }
      : hook,
  );
  const issues = validateOnchainHookPlanArtifact({
    ...onchain,
    compiledHooks: tamperedHooks,
    dependencyIndex: Object.fromEntries(
      Object.entries(onchain.dependencyIndex).map(([key, hookIds]) => [
        key,
        hookIds,
      ]),
    ),
  });
  assert.equal(
    issues.some((issue) => /is shared across stages/.test(issue)),
    true,
    `expected cross-stage issue, got: ${issues.join("; ")}`,
  );

  const stageA = "0x" + "01".repeat(32);
  const stageB = "0x" + "02".repeat(32);
  const dep = {
    kind: "positive",
    source: "buyer",
    signalName: "buyer::shared",
    sourceId: onchainSourceId("buyer"),
    signalId: onchainSignalId("buyer::shared"),
    signalKey: sharedKey,
  };
  const hookOf = (
    name: string,
    stageIdentifier: string,
    stageId: string,
    orderTriggerKind: "trigger" | "none",
  ) => ({
    hookId: keccak256Hex(`${stageIdentifier}#${name}`),
    stageId,
    stageIdentifier,
    hookName: name,
    kind: "receive",
    orderTriggerKind,
    emitReady: orderTriggerKind !== "none",
    instructions: [
      {
        op: "SIGNAL",
        source: "buyer",
        signalName: "buyer::shared",
        sourceId: dep.sourceId,
        signalId: dep.signalId,
        signalKey: sharedKey,
      },
    ],
    dependencies: [dep],
  });
  const sequentialHookLists = {
    accepted: [
      hookOf("t1", "a", stageA, "trigger"),
      hookOf("t2", "b", stageB, "trigger"),
      hookOf("w1", "a", stageA, "none"),
    ],
    rejected: [
      hookOf("w1", "a", stageA, "none"),
      hookOf("t1", "b", stageB, "trigger"),
    ],
  };
  const sequentialArtifact = (hooks: readonly ReturnType<typeof hookOf>[]) => ({
    ...onchain,
    compiledHooks: hooks,
    dependencyIndex: { [sharedKey]: hooks.map((hook) => hook.hookId) },
  });
  const acceptedIssues = validateOnchainHookPlanArtifact(sequentialArtifact(sequentialHookLists.accepted)).filter(
    (issue) => /is shared across stages/.test(issue),
  );
  assert.deepEqual(acceptedIssues, []);

  const rejectedIssues = validateOnchainHookPlanArtifact(sequentialArtifact(sequentialHookLists.rejected)).filter(
    (issue) => /is shared across stages/.test(issue),
  );
  assert.equal(rejectedIssues.length, 1);
});

test("compiles capability tables beyond gas caps into a verifiable capabilitiesRoot", () => {
  const tableBindings = Array.from({ length: 400 }, (_, index) => ({
    selectorStageId: keccak256Hex(`capability.selector-${index}`),
    targetStageId: keccak256Hex(`capability.target-${index}`),
  }));
  const tableCapabilities = Array.from({ length: 400 }, (_, index) => ({
    stageId: keccak256Hex(`capability.stage-${index}`),
    targetSourceId: keccak256Hex(`capability.source-${index}`),
    signalId: keccak256Hex(`stage.signal-${index}`),
    targetOrderRelation: (index % 2 === 0 ? 0 : 1) as 0 | 1,
  }));
  const root = capabilitiesRootOf(tableBindings, tableCapabilities);
  assert.notEqual(root, EMPTY_MERKLE_ROOT);
  assert.match(root, /^0x[0-9a-f]{64}$/);

  const deepCapability = tableCapabilities[200]!;
  const deepCapabilityProof = signalCapabilityProof(
    tableBindings,
    tableCapabilities,
    deepCapability.stageId,
    deepCapability.targetSourceId,
    deepCapability.signalId,
    deepCapability.targetOrderRelation,
  );
  assert.ok(deepCapabilityProof, "mid-table capability leaf must have a proof");
  assert.ok(deepCapabilityProof.length >= 9, "800-leaf tree proofs must be deep");
  assert.ok(
    verifyMerkleProof(
      root,
      signalCapabilityLeaf(
        deepCapability.stageId,
        deepCapability.targetSourceId,
        deepCapability.signalId,
        deepCapability.targetOrderRelation,
      ),
      deepCapabilityProof,
    ),
  );
  for (const binding of [tableBindings[0]!, tableBindings[399]!]) {
    const proof = selectorBindingProof(
      tableBindings,
      tableCapabilities,
      binding.selectorStageId,
      binding.targetStageId,
    );
    assert.ok(proof);
    assert.ok(
      verifyMerkleProof(
        root,
        selectorBindingLeaf(binding.selectorStageId, binding.targetStageId),
        proof,
      ),
    );
  }
  assert.ok(
    !verifyMerkleProof(
      root,
      signalCapabilityLeaf(
        deepCapability.stageId,
        deepCapability.targetSourceId,
        deepCapability.signalId,
        (deepCapability.targetOrderRelation === 0 ? 1 : 0) as 0 | 1,
      ),
      deepCapabilityProof,
    ),
  );

  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu));
  const template = onchain.signalCapabilities[0];
  assert.ok(template);
  const expanded = Array.from({ length: 400 }, (_, index) => {
    const targetSource = `bulk-source-${index}`;
    const targetSignalName = `main.bulk-${index}`;
    const targetSourceId = onchainSourceId(targetSource);
    const signalId = onchainSignalId(targetSignalName);
    return {
      ...template,
      targetSource,
      targetSourceId,
      targetSignalName,
      signalId,
      capabilityHash: onchainSignalCapabilityHash(
        template.stageId,
        targetSourceId,
        signalId,
        template.targetOrderRelation,
      ),
    };
  }).sort((left, right) => {
      const bySource = left.targetSourceId < right.targetSourceId ? -1
        : left.targetSourceId > right.targetSourceId ? 1 : 0;
      if (bySource !== 0) {
        return bySource;
      }
      return left.signalId < right.signalId ? -1
        : left.signalId > right.signalId ? 1 : 0;
    });
  const { planHash: _staleHash, capabilitiesRoot: _staleRoot, ...payload } = onchain;
  const solidityBindings = onchain.selectorBindings.map((binding) => ({
    selectorStageId: binding.selectorStageId,
    targetStageId: binding.targetStageId,
  }));
  const solidityCapabilities = expanded.map((capability) => ({
    stageId: capability.stageId,
    targetSourceId: capability.targetSourceId,
    signalId: capability.signalId,
    targetOrderRelation: 0 as const,
  }));
  const expandedRoot = capabilitiesRootOf(solidityBindings, solidityCapabilities);
  const expandedPayload = {
    ...payload,
    signalCapabilities: expanded,
    capabilitiesRoot: expandedRoot,
  };
  const expandedArtifact = {
    ...expandedPayload,
    planHash: hashOnchainPlanPayload(expandedPayload),
  };
  assert.deepEqual(validateOnchainHookPlanArtifact(expandedArtifact), []);
  const expandedArgs = toSolidityRegisterPlanArgs(expandedArtifact);
  assert.equal(expandedArgs.signalCapabilities.length, 400);
  assert.equal(
    expandedArgs.capabilitiesRoot,
    capabilitiesRootOf(expandedArgs.selectorBindings, expandedArgs.signalCapabilities),
  );
});

test("rejects cross-stage current-order fact key duplication (E16 mirror)", () => {
  const sourcePlan = compileZhixuHookPlan(baseZhixu);
  const fact = sourcePlan.signalCapabilities[0]!;
  const otherStage =
    sourcePlan.signalCapabilities.find(
      (capability) => capability.stageIdentifier !== fact.stageIdentifier,
    )?.stageIdentifier ?? "other";
  const crossStageDuplicate = resign({
    ...sourcePlan,
    signalCapabilities: [
      ...sourcePlan.signalCapabilities.map((capability) =>
        capability === fact ? { ...capability, targetOrderRelation: "current" as const } : capability,
      ),
      { ...fact, stageIdentifier: otherStage, targetOrderRelation: "current" as const },
    ],
  });
  assert.throws(
    () => compileOnchainHookPlan(crossStageDuplicate),
    (error: unknown) =>
      error instanceof HookPlanCompilationError &&
      error.issues.some((issue) =>
        /current-order fact key .* already owned by stage .*must resolve to exactly one owner stage/.test(issue),
      ),
  );
});

test("rejects duplicate on-chain selector bindings", () => {
  const sourcePlan = compileZhixuHookPlan(baseZhixu);

  const duplicated = {
    ...sourcePlan,
    selectedStageBindings: [
      ...sourcePlan.selectedStageBindings,
      sourcePlan.selectedStageBindings[0]!,
    ],
  };
  assert.throws(
    () =>
      compileOnchainHookPlan({
        ...duplicated,
        planHash: hookPlanHashOf(duplicated),
      }),
    OnchainHookPlanArtifactValidationError,
  );
});

test("rejects invalid on-chain HookPlan artifact shapes", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu));

  assert.deepEqual(
    validateOnchainHookPlanArtifact({ ...onchain, schemaVersion: "wrong" }),
    ["schemaVersion must be uvp.onchainHookPlan.v8"],
  );
  assert.match(
    validateOnchainHookPlanArtifact({
      ...onchain,
      compiledHooks: [
        {
          ...onchain.compiledHooks[0]!,
          hookId:
            "0x0000000000000000000000000000000000000000000000000000000000000000",
        },
        ...onchain.compiledHooks.slice(1),
      ],
    }).join("; "),
    /hookId must be keccak256/,
  );
  assert.throws(
    () =>
      assertOnchainHookPlanArtifact({
        ...onchain,
        dependencyIndex: {},
      }),
    OnchainHookPlanArtifactValidationError,
  );
  assert.ok(
    validateOnchainHookPlanArtifact({
      ...onchain,
      planId: `0x${"22".repeat(32)}`,
    }).includes(
      "planId must match the recomputed H(uvp:hook-plan-id:v1; compiler/platform/zhixuId/zhixuName)",
    ),
  );
});

test("rejects empty instructions the way the contract reverts InvalidHook", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu));
  assert.deepEqual(validateOnchainHookPlanArtifact(onchain), []);

  assert.match(
    validateOnchainHookPlanArtifact({
      ...onchain,
      compiledHooks: [
        { ...onchain.compiledHooks[0]!, instructions: [] },
        ...onchain.compiledHooks.slice(1),
      ],
    }).join("; "),
    /compiledHooks\[0\]\.instructions must leave exactly one stack item/,
  );
});

test("rejects empty dependency keys the way the contract reverts InvalidHook", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu));
  assert.doesNotThrow(() => toSolidityRegisterPlanArgs(onchain));

  const withEmptyDependencies = {
    ...onchain,
    compiledHooks: [
      { ...onchain.compiledHooks[0]!, dependencies: [] },
      ...onchain.compiledHooks.slice(1),
    ],
  };
  assert.match(
    validateOnchainHookPlanArtifact(withEmptyDependencies).join("; "),
    /compiledHooks\[0\]\.dependencies must not be empty/,
  );
  assert.throws(
    () => toSolidityRegisterPlanArgs(withEmptyDependencies),
    (error: unknown) =>
      error instanceof OnchainHookPlanArtifactValidationError &&
      error.issues.some((issue) =>
        /dependencies must not be empty/.test(issue)
      )
  );
});

test("rejects DELAY seconds beyond the 30-day contract bound", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu));
  const withDelay = (
    delaySeconds: number
  ): OnchainHookPlanArtifact => ({
    ...onchain,
    compiledHooks: onchain.compiledHooks.map((hook) =>
      hook.hookName === "TIMEOUT"
        ? {
            ...hook,
            instructions: hook.instructions.map((instruction) =>
              instruction.op === "DELAY"
                ? { op: "DELAY", delaySeconds }
                : instruction
            ),
          }
        : hook
    ),
  });

  assert.match(
    validateOnchainHookPlanArtifact(withDelay(2_592_001)).join("; "),
    /delaySeconds must not exceed 2592000.*HookDelayTooLong/,
  );

  const atBound = withDelay(2_592_000);
  const { planHash: staleHash, ...payload } = atBound;
  void staleHash;
  const repinned = {
    ...payload,
    planHash: hashOnchainPlanPayload(payload),
  };
  assert.deepEqual(validateOnchainHookPlanArtifact(repinned), []);
  assert.deepEqual(
    toSolidityRegisterPlanArgs(repinned)
      .hooks.find((hook) => hook.hookName === keccak256Hex("TIMEOUT"))
      ?.instructions.filter((instruction) => instruction.op === "DELAY"),
    [{ op: "DELAY", delaySeconds: 2_592_000 }],
  );
});

test("rejects a dependency key shared across stages", () => {
  const sharedZhixu: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: baseZhixu.spec.stages.map((stage) =>
        stage.name === "assign"
          ? {
              ...stage,
              receiveSignals: {
                ECHO: "buyer::assign.executor_selected"
              }
            }
          : stage
      )
    }
  };

  assert.throws(
    () => compileOnchainHookPlan(compileZhixuHookPlan(sharedZhixu)),
    (error: unknown) =>
      error instanceof HookPlanCompilationError &&
      error.issues.some((issue) => /shared across stages/.test(issue))
  );
});

test("flags stages whose hooks can never materialize on-chain", () => {
  const materializationIssues = (issues: readonly string[]): readonly string[] =>
    issues.filter((issue) => /no order-trigger or EMIT_READY hook/.test(issue));

  const triggerZhixu: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: [
        ...baseZhixu.spec.stages,
        {
          name: "birth",
          source: "fulfiller",
          sendSignals: [{ name: "str", trigger: true }, { name: "cmp" }, { name: "err" }],
          executor: {
            supplierType: "organization",
            supplierID: SUPPLIER_FULFILLER,
          },
        }],
    },
  };
  const triggerOnchain = compileOnchainHookPlan(
    compileZhixuHookPlan(triggerZhixu),
  );
  assert.deepEqual(materializationIssues(validateOnchainHookPlanArtifact(triggerOnchain)), []);

  const baseOnchain = compileOnchainHookPlan(
    compileZhixuHookPlan(baseZhixu),
  );
  assert.deepEqual(materializationIssues(validateOnchainHookPlanArtifact(baseOnchain)), []);

  const watcherOnly: OnchainHookPlanArtifact = {
    ...baseOnchain,
    compiledHooks: baseOnchain.compiledHooks.map((hook) =>
      hook.stageIdentifier === "main"
        ? { ...hook, orderTriggerKind: "none" as const, emitReady: false }
        : hook,
    ),
  };
  const watcherIssues = materializationIssues(
    validateOnchainHookPlanArtifact(watcherOnly),
  );
  assert.equal(watcherIssues.length, 2);
  for (const issue of watcherIssues) {
    assert.match(
      issue,
      /^stage main has no order-trigger or EMIT_READY hook; its hooks compile to flags=0 watchers which can never materialize the stage on-chain \(deadlock, no recovery path\) — the Rust compiler must reject this shape$/,
    );
  }

  const watcherSourcePlan = compileZhixuHookPlan(baseZhixu);
  const mutatedSourcePlan = {
    ...watcherSourcePlan,
    compiledHooks: watcherSourcePlan.compiledHooks.map((hook) =>
      hook.stageIdentifier === "main"
        ? { ...hook, orderTriggerKind: "none" as const, emitReady: false }
        : hook,
    ),
  };
  const resignedMutatedPlan = {
    ...mutatedSourcePlan,
    planHash: hookPlanHashOf(mutatedSourcePlan),
  };
  assert.throws(
    () => compileOnchainHookPlan(resignedMutatedPlan),
    (error: unknown) =>
      error instanceof HookPlanCompilationError &&
      error.issues.some((issue) =>
        /stage main has no order-trigger or EMIT_READY hook/.test(issue),
      ),
  );
});

test("rejects stages that compile to zero hooks (materialization gate)", () => {
  const zeroHookIssues = (issues: readonly string[]): readonly string[] =>
    issues.filter((issue) =>
      /declares no receiveSignals and compiles to zero hooks/.test(issue),
    );
  const sourcePlan = compileZhixuHookPlan(baseZhixu);
  const onchain = compileOnchainHookPlan(sourcePlan);

  const placeHook = onchain.compiledHooks.find(
    (hook) => hook.hookName === "PLACE",
  );
  assert.equal(placeHook?.stageIdentifier, "assign");
  assert.equal(placeHook?.orderTriggerKind, "none");
  assert.equal(placeHook?.emitReady, true);
  assert.deepEqual(zeroHookIssues(validateOnchainHookPlanArtifact(onchain)), []);

  const strippedHookIds = new Set(
    sourcePlan.compiledHooks
      .filter((hook) => hook.stageIdentifier === "assign")
      .map((hook) => hook.hookId),
  );
  const zeroHookSourcePlan = {
    ...sourcePlan,
    compiledHooks: sourcePlan.compiledHooks.filter(
      (hook) => hook.stageIdentifier !== "assign",
    ),
    dependencyIndex: Object.fromEntries(
      Object.entries(sourcePlan.dependencyIndex)
        .map(([key, hookIds]): [string, readonly string[]] => [
          key,
          hookIds.filter((hookId) => !strippedHookIds.has(hookId)),
        ])
        .filter(([, hookIds]) => hookIds.length > 0),
    ),
    selectedStageBindings: sourcePlan.selectedStageBindings.filter(
      (binding) => binding.selectorStageIdentifier !== "assign",
    ),
    signalCapabilities: sourcePlan.signalCapabilities.filter(
      (capability) => capability.stageIdentifier !== "assign",
    ),
  };
  const unsignedZeroHookPlan = {
    ...zeroHookSourcePlan,
    planHash: hookPlanHashOf(zeroHookSourcePlan),
  };
  assert.throws(
    () => compileOnchainHookPlan(unsignedZeroHookPlan),
    (error: unknown) =>
      error instanceof HookPlanCompilationError &&
      zeroHookIssues(error.issues).length === 1 &&
      /^stage assign declares no receiveSignals and compiles to zero hooks: the stage can never materialize on-chain \(materialization only happens via this stage's own order-trigger\/EMIT_READY hooks\) and its sendSignals have no hook to hang on — submitSignal requires the source stage to be materialized and reverts UnknownHook forever \(deadlock, no recovery path\); declare a trigger signal, receiveSignals, or a static supplier$/.test(
        zeroHookIssues(error.issues)[0] ?? "",
      ),
  );

  const zeroHookOnchain: OnchainHookPlanArtifact = {
    ...onchain,
    compiledHooks: onchain.compiledHooks.filter(
      (hook) => hook.stageIdentifier !== "assign",
    ),
  };
  const boundaryIssues = zeroHookIssues(
    validateOnchainHookPlanArtifact(zeroHookOnchain),
  );
  assert.equal(boundaryIssues.length, 1);
  assert.match(
    boundaryIssues[0] ?? "",
    /^stage assign declares no receiveSignals and compiles to zero hooks/,
  );
});

test("rejects silent order-trigger hooks (trigger without emitReady)", () => {
  const silentTriggerIssues = (issues: readonly string[]): readonly string[] =>
    issues.filter((issue) => /order trigger without emitReady/.test(issue));

  const baseOnchain = compileOnchainHookPlan(
    compileZhixuHookPlan(baseZhixu),
  );
  assert.deepEqual(silentTriggerIssues(validateOnchainHookPlanArtifact(baseOnchain)), []);

  const silentTrigger: OnchainHookPlanArtifact = {
    ...baseOnchain,
    compiledHooks: baseOnchain.compiledHooks.map((hook) =>
      hook.stageIdentifier === "main" && hook.hookName === "START"
        ? { ...hook, orderTriggerKind: "trigger" as const, emitReady: false }
        : hook,
    ),
  };
  const triggerIssues = silentTriggerIssues(validateOnchainHookPlanArtifact(silentTrigger));
  assert.ok(triggerIssues.length >= 1, "silent trigger birth must be flagged");
  for (const issue of triggerIssues) {
    assert.match(
      issue,
      /hook main#.+ is an order trigger without emitReady; UVPStateMachine\.commitPlan reverts SilentOrderTriggerHook — the Rust compiler must always emit trigger flags with EMIT_READY$/,
    );
  }

  const silentSourcePlan = compileZhixuHookPlan(baseZhixu);
  const mutatedSilentPlan = resign({
    ...silentSourcePlan,
    compiledHooks: silentSourcePlan.compiledHooks.map((hook) =>
      hook.stageIdentifier === "main" && hook.hookName === "START"
        ? { ...hook, orderTriggerKind: "trigger" as const, emitReady: false }
        : hook,
    ),
  });
  assert.throws(
    () => compileOnchainHookPlan(mutatedSilentPlan),
    (error: unknown) =>
      error instanceof HookPlanCompilationError &&
      error.issues.some((issue) =>
        /order trigger without emitReady/.test(issue),
      ),
  );
});

test("mirrors _validateHook DELAY/NOT/anchor rejection branches at the artifact boundary", () => {
  const baseOnchain = compileOnchainHookPlan(
    compileZhixuHookPlan(baseZhixu),
  );
  const rehashed = (artifact: OnchainHookPlanArtifact): OnchainHookPlanArtifact => {
    const { planHash: _stale, ...payload } = artifact;
    void _stale;
    return {
      ...payload,
      planHash: hashOnchainPlanPayload(payload as never),
    } as OnchainHookPlanArtifact;
  };

  const mutateHookInstructions = (
    hookName: string,
    instructions: unknown,
    extra?: (hook: unknown) => unknown,
  ): OnchainHookPlanArtifact =>
    rehashed({
      ...structuredClone(baseOnchain),
      compiledHooks: baseOnchain.compiledHooks.map((hook) =>
        hook.hookName === hookName
          ? { ...hook, instructions, ...(extra?.(hook) ?? {}) }
          : hook,
      ),
    } as OnchainHookPlanArtifact);

  const timeoutInstructions = baseOnchain.compiledHooks
    .find((hook) => hook.hookName === "TIMEOUT")!
    .instructions;
  const triggerDelay = mutateHookInstructions(
    "START",
    [...timeoutInstructions.slice(0, 2)],
    () => ({ orderTriggerKind: "trigger" as const }),
  );
  const triggerDelayIssues = validateOnchainHookPlanArtifact(triggerDelay);
  assert.ok(
    triggerDelayIssues.some((issue) =>
      /DELAY is not allowed on order-trigger hooks/.test(issue),
    ),
    triggerDelayIssues.join("; "),
  );

  const anchorFreeDelay = mutateHookInstructions("TIMEOUT", [
    timeoutInstructions[0],
    { op: "NOT" },
    { op: "DELAY", delaySeconds: 5 },
    timeoutInstructions[2],
    { op: "AND", arity: 2 },
  ]);
  assert.ok(
    validateOnchainHookPlanArtifact(anchorFreeDelay).some((issue) =>
      /DELAY requires an operand with a positive signal anchor/.test(issue),
    ),
  );

  const notOverAnd = mutateHookInstructions("TIMEOUT", [
    timeoutInstructions[0],
    timeoutInstructions[2],
    { op: "AND", arity: 2 },
    { op: "NOT" },
  ]);
  assert.ok(
    validateOnchainHookPlanArtifact(notOverAnd).some((issue) =>
      /requires a bare SIGNAL operand/.test(issue),
    ),
  );

  const pureNegative = mutateHookInstructions("TIMEOUT", [
    timeoutInstructions[0],
    { op: "NOT" },
  ]);
  assert.ok(
    validateOnchainHookPlanArtifact(pureNegative).some((issue) =>
      /at least one positive signal anchor/.test(issue),
    ),
  );

  assert.deepEqual(
    validateOnchainHookPlanArtifact(rehashed(structuredClone(baseOnchain) as OnchainHookPlanArtifact)),
    [],
  );
});

test("admits the decaying veto at the conjunction slot and mirrors its position gates", () => {
  const baseOnchain = compileOnchainHookPlan(
    compileZhixuHookPlan(baseZhixu),
  );
  const rehashed = (artifact: OnchainHookPlanArtifact): OnchainHookPlanArtifact => {
    const { planHash: _stale, ...payload } = artifact;
    void _stale;
    return {
      ...payload,
      planHash: hashOnchainPlanPayload(payload as never),
    } as OnchainHookPlanArtifact;
  };

  const mutateHookInstructions = (
    instructions: unknown,
  ): OnchainHookPlanArtifact =>
    rehashed({
      ...structuredClone(baseOnchain),
      compiledHooks: baseOnchain.compiledHooks.map((hook) =>
        hook.hookName === "TIMEOUT" ? { ...hook, instructions } : hook,
      ),
    } as OnchainHookPlanArtifact);

  const timeoutInstructions = baseOnchain.compiledHooks
    .find((hook) => hook.hookName === "TIMEOUT")!
    .instructions;
  const [delaySignal, , plainSignal] = timeoutInstructions;

  const vetoOperand = mutateHookInstructions([
    delaySignal,
    { op: "DELAY", delaySeconds: 5 },
    { op: "NOT" },
    plainSignal,
    { op: "AND", arity: 2 },
  ]);
  assert.deepEqual(
    validateOnchainHookPlanArtifact(vetoOperand),
    [],
  );

  assert.ok(
    validateOnchainHookPlanArtifact(mutateHookInstructions([
      delaySignal,
      { op: "DELAY", delaySeconds: 5 },
      { op: "NOT" },
    ])).some((issue) => /leaves a decaying veto at the root/.test(issue)),
  );

  assert.ok(
    validateOnchainHookPlanArtifact(mutateHookInstructions([
      delaySignal,
      { op: "DELAY", delaySeconds: 5 },
      { op: "NOT" },
      plainSignal,
      { op: "OR", arity: 2 },
    ])).some((issue) => /cannot take a decaying veto operand/.test(issue)),
  );

  assert.ok(
    validateOnchainHookPlanArtifact(mutateHookInstructions([
      delaySignal,
      { op: "DELAY", delaySeconds: 5 },
      { op: "NOT" },
      { op: "NOT" },
      plainSignal,
      { op: "AND", arity: 2 },
    ])).some((issue) => /requires a bare SIGNAL operand/.test(issue)),
  );

  assert.ok(
    validateOnchainHookPlanArtifact(mutateHookInstructions([
      delaySignal,
      { op: "DELAY", delaySeconds: 5 },
      { op: "NOT" },
      { op: "DELAY", delaySeconds: 10 },
      plainSignal,
      { op: "AND", arity: 2 },
    ])).some((issue) => /DELAY cannot consume an operand containing a decaying veto/.test(issue)),
  );

  assert.ok(
    validateOnchainHookPlanArtifact(mutateHookInstructions([
      delaySignal,
      { op: "DELAY", delaySeconds: 5 },
      { op: "NOT" },
      plainSignal,
      { op: "AND", arity: 2 },
      { op: "DELAY", delaySeconds: 10 },
    ])).some((issue) => /DELAY cannot consume an operand containing a decaying veto/.test(issue)),
  );
});

test("compiles the decaying veto DSL form through the full on-chain pipeline", () => {
  const vetoZhixu: ZhixuDefinition = structuredClone(baseZhixu);
  const execution = vetoZhixu.spec.stages[1]!;
  execution.receiveSignals!.TIMEOUT =
    "buyer::main.cmp & ~(assign.executor_selected +5s)";

  const onchain = compileZhixuOnchainHookPlan(vetoZhixu);
  const timeoutHook = onchain.compiledHooks.find((hook) => hook.hookName === "TIMEOUT")!;
  assert.deepEqual(
    timeoutHook.instructions.map((instruction) => instruction.op),
    ["SIGNAL", "SIGNAL", "DELAY", "NOT", "AND"],
  );
  assert.deepEqual(
    validateOnchainHookPlanArtifact(onchain),
    [],
  );
});

test("rejects DELAY on order-trigger conditions at the compile boundary (producer side)", () => {
  const triggerZhixu: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: [
        ...baseZhixu.spec.stages,
        {
          name: "birth",
          source: "fulfiller",
          sendSignals: [{ name: "str", trigger: true }, { name: "cmp" }],
          executor: {
            supplierType: "organization",
            supplierID: SUPPLIER_FULFILLER,
          },
        }],
    },
  };
  const triggerPlan = compileZhixuHookPlan(triggerZhixu);
  const triggerHook = triggerPlan.compiledHooks.find(
    (hook) => hook.orderTriggerKind === "trigger",
  );
  assert.ok(triggerHook, "the trigger fixture must expose its birth hook");
  const delayed = resign({
    ...triggerPlan,
    compiledHooks: triggerPlan.compiledHooks.map((hook) =>
      hook === triggerHook
        ? {
            ...hook,
            ast: {
              ...hook.ast,
              condition: {
                kind: "delay" as const,
                durationSeconds: 5,
                expr: hook.ast.condition,
                rawDuration: "5s",
              },
            },
          }
        : hook,
    ) as typeof triggerPlan.compiledHooks,
  });
  assert.throws(
    () => compileOnchainHookPlan(delayed),
    (error: unknown) => {
      assert.ok(error instanceof HookPlanCompilationError);
      assert.match(
        error.issues.join("; "),
        /order-trigger hook \(trigger\) must not contain DELAY/,
      );
      return true;
    },
  );
});

test("rejects supplierType outside the closed enum at the on-chain compile boundary", () => {
  const hookPlan = compileZhixuHookPlan(baseZhixu);
  const mutated = resign({
    ...hookPlan,
    supplierRoutes: {
      ...hookPlan.supplierRoutes,
      "assign": {
        ...hookPlan.supplierRoutes["assign"]!,
        executor: {
          ...hookPlan.supplierRoutes["assign"]!.executor,
          supplierType: "Organization",
        },
      },
    },
  } as unknown as typeof hookPlan);
  assert.throws(
    () => compileOnchainHookPlan(mutated),
    (error: unknown) => {
      assert.ok(error instanceof HookPlanCompilationError);
      assert.match(
        error.issues.join("; "),
        /supplierType must be one of individual\|organization \(case-sensitive\), received "Organization"/,
      );
      return true;
    },
  );
});

test("rejects whitespace-padded supplierType at the on-chain compile boundary", () => {
  const hookPlan = compileZhixuHookPlan(baseZhixu);
  for (const supplierType of [" organization ", "individual "]) {
    const mutated = resign({
      ...hookPlan,
      supplierRoutes: {
        ...hookPlan.supplierRoutes,
        "assign": {
          ...hookPlan.supplierRoutes["assign"]!,
          executor: {
            ...hookPlan.supplierRoutes["assign"]!.executor,
            supplierType,
          },
        },
      },
    } as typeof hookPlan);
    assert.throws(
      () => compileOnchainHookPlan(mutated),
      (error: unknown) => {
        assert.ok(error instanceof HookPlanCompilationError);
        assert.match(
          error.issues.join("; "),
          new RegExp(
            `supplierType must be one of individual\\|organization \\(case-sensitive\\), received ${JSON.stringify(supplierType).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`,
          ),
        );
        return true;
      },
      `supplierType=${JSON.stringify(supplierType)} must be rejected by exact match`,
    );
  }
});

test("rejects selectableResource fileType outside the closed enum at the on-chain compile boundary", () => {
  const selectorStage = baseZhixu.spec.stages[0]!;
  const withSelectableZhixu: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: [
        ...baseZhixu.spec.stages.slice(0, 1).map((stage) => ({
          ...stage,
          executor: {
            ...stage.executor!,
            selectableResource: {
              dataset: { fileType: "plain_text", plainText: { content: "x" } },
            },
          },
        })),
        ...baseZhixu.spec.stages.slice(1),
      ],
    },
  };
  compileOnchainHookPlan(compileZhixuHookPlan(withSelectableZhixu));

  const hookPlan = compileZhixuHookPlan(baseZhixu);
  for (const fileType of ["tx_cloud", " local", "http "]) {
    const mutated = resign({
      ...hookPlan,
      supplierRoutes: {
        ...hookPlan.supplierRoutes,
        "assign": {
          ...hookPlan.supplierRoutes["assign"]!,
          executor: {
            ...hookPlan.supplierRoutes["assign"]!.executor,
            selectableResource: {
              dataset: { fileType, plainText: { content: "x" } },
            },
          },
        },
      },
    } as typeof hookPlan);
    assert.throws(
      () => compileOnchainHookPlan(mutated),
      (error: unknown) => {
        assert.ok(error instanceof HookPlanCompilationError);
        assert.match(
          error.issues.join("; "),
          /executor\.selectableResource\["dataset"\]\.fileType must be one of local\|http\|txcloud\|plain_text/,
        );
        return true;
      },
      `fileType=${JSON.stringify(fileType)} must be rejected by exact match`,
    );
  }
});

test("rejects fileResources fileType outside the closed enum at the on-chain compile boundary", () => {
  const hookPlan = compileZhixuHookPlan(baseZhixu);
  const route = hookPlan.supplierRoutes["assign"]!;
  const mutated = resign({
    ...hookPlan,
    supplierRoutes: {
      ...hookPlan.supplierRoutes,
      "assign": {
        ...route,
        fileResources: {
          contract_template: { fileType: "locale", path: "./template.md" },
        },
      },
    },
  } as typeof hookPlan);
  assert.throws(
    () => compileOnchainHookPlan(mutated),
    (error: unknown) => {
      assert.ok(error instanceof HookPlanCompilationError);
      assert.match(
        error.issues.join("; "),
        /fileType must be one of local\|http\|txcloud\|plain_text, received "locale"/,
      );
      return true;
    },
  );
});

test("rejects non-map file-resource shapes at the on-chain compile boundary", () => {
  const hookPlan = compileZhixuHookPlan(baseZhixu);
  const mutateExecutor = (
    selectableResource: unknown,
  ): Parameters<typeof compileOnchainHookPlan>[0] =>
    resign({
      ...hookPlan,
      supplierRoutes: {
        ...hookPlan.supplierRoutes,
        "assign": {
          ...hookPlan.supplierRoutes["assign"]!,
          executor: {
            ...hookPlan.supplierRoutes["assign"]!.executor,
            ...(selectableResource === undefined
              ? {}
              : { selectableResource }),
          },
        },
      },
    } as unknown as typeof hookPlan);
  for (const shape of ["http", 7, ["dataset"], true]) {
    assert.throws(
      () => compileOnchainHookPlan(mutateExecutor(shape)),
      (error: unknown) => {
        assert.ok(error instanceof HookPlanCompilationError);
        assert.match(
          error.issues.join("; "),
          /executor\.selectableResource must be a map of file resources/,
        );
        return true;
      },
      `selectableResource=${JSON.stringify(shape)} must be rejected as a non-map shape`,
    );
  }
  assert.throws(
    () => compileOnchainHookPlan(mutateExecutor(null)),
    (error: unknown) => {
      assert.ok(error instanceof HookPlanCompilationError);
      assert.doesNotMatch(
        error.issues.join("; "),
        /must be a map of file resources/,
      );
      return true;
    },
  );
  for (const shape of [null, "local", 7]) {
    const mutated = resign({
      ...hookPlan,
      supplierRoutes: {
        ...hookPlan.supplierRoutes,
        "assign": {
          ...hookPlan.supplierRoutes["assign"]!,
          fileResources: shape,
        },
      },
    } as unknown as typeof hookPlan);
    assert.throws(
      () => compileOnchainHookPlan(mutated),
      (error: unknown) => {
        assert.ok(error instanceof HookPlanCompilationError);
        assert.match(
          error.issues.join("; "),
          /fileResources must be a map of file resources/,
        );
        return true;
      },
      `fileResources=${JSON.stringify(shape)} must be rejected as a non-map shape`,
    );
  }
});

test("artifact boundary enforces the supplierType closed enum and non-empty supplierID", () => {
  const onchain = compileOnchainHookPlan(
    compileZhixuHookPlan(baseZhixu),
  );
  const route = onchain.supplierRoutes[0]!;
  const rehashed = (mutated: OnchainHookPlanArtifact): OnchainHookPlanArtifact => {
    const { planHash: _drop, ...payload } = mutated;
    void _drop;
    return {
      ...mutated,
      planHash: hashOnchainPlanPayload(payload as never),
    } as OnchainHookPlanArtifact;
  };
  const mutateRoute = (
    patch: Partial<(typeof onchain.supplierRoutes)[number]>,
  ): OnchainHookPlanArtifact =>
    rehashed({
      ...onchain,
      supplierRoutes: onchain.supplierRoutes.map((candidate) =>
        candidate === route ? { ...candidate, ...patch } : candidate,
      ),
    } as OnchainHookPlanArtifact);

  const issues = validateOnchainHookPlanArtifact(
    mutateRoute({ supplierType: "Vendor" }),
  );
  assert.ok(
    issues.some((issue) =>
      /supplierType must be one of individual\|organization \(case-sensitive\), received "Vendor"/.test(
        issue,
      ),
    ),
    issues.join("; "),
  );
  for (const supplierType of [" organization ", "dock ", "\tindividual"]) {
    const paddedIssues = validateOnchainHookPlanArtifact(
      mutateRoute({ supplierType }),
    );
    assert.ok(
      paddedIssues.some((issue) =>
        new RegExp(
          `supplierType must be one of individual\\|organization \\(case-sensitive\\), received ${JSON.stringify(supplierType).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`,
        ).test(issue),
      ),
      `supplierType=${JSON.stringify(supplierType)}: ${paddedIssues.join("; ")}`,
    );
  }
  for (const supplierID of ["", "   "]) {
    const idIssues = validateOnchainHookPlanArtifact(
      mutateRoute({ supplierID }),
    );
    assert.ok(
      idIssues.some((issue) =>
        /supplierID must be a non-empty supplier UUID/.test(issue),
      ),
      `supplierID=${JSON.stringify(supplierID)}: ${idIssues.join("; ")}`,
    );
  }
  assert.deepEqual(
    validateOnchainHookPlanArtifact(
      rehashed(structuredClone(onchain) as OnchainHookPlanArtifact),
    ),
    [],
  );
});

test("compile boundary rejects empty and non-UUID executor.supplierID", () => {
  const mutateSupplierID = (supplierID: string) => {
    const hookPlan = compileZhixuHookPlan(baseZhixu);
    return resign({
      ...hookPlan,
      supplierRoutes: {
        ...hookPlan.supplierRoutes,
        "assign": {
          ...hookPlan.supplierRoutes["assign"]!,
          executor: {
            ...hookPlan.supplierRoutes["assign"]!.executor,
            supplierID,
          },
        },
      },
    } as typeof hookPlan);
  };
  for (const supplierID of ["   ", ""]) {
    assert.throws(
      () => compileOnchainHookPlan(mutateSupplierID(supplierID)),
      (error: unknown) => {
        assert.ok(error instanceof HookPlanCompilationError);
        assert.match(
          error.issues.join("; "),
          /is missing a non-empty executor\.supplierID/,
        );
        return true;
      },
      `supplierID=${JSON.stringify(supplierID)} must be rejected as empty`,
    );
  }
  for (const supplierID of ["selector-org", "5f0b1e2a-7c9d-4e1f-9a2b-00000000001"]) {
    assert.throws(
      () => compileOnchainHookPlan(mutateSupplierID(supplierID)),
      (error: unknown) => {
        assert.ok(error instanceof HookPlanCompilationError);
        assert.match(
          error.issues.join("; "),
          /must be a canonical 8-4-4-4-12 UUID/,
        );
        return true;
      },
      `supplierID=${JSON.stringify(supplierID)} must be rejected as a non-UUID`,
    );
  }
});

test("compile boundary mirrors _validateHook shape gates before producing artifacts", () => {
  const hookPlan = compileZhixuHookPlan(baseZhixu);
  const timeoutHook = hookPlan.compiledHooks.find(
    (hook) => hook.hookName === "TIMEOUT",
  );
  assert.ok(timeoutHook, "base fixture exposes the TIMEOUT watcher hook");

  const overDelay = resign({
    ...hookPlan,
    compiledHooks: hookPlan.compiledHooks.map((hook) =>
      hook === timeoutHook
        ? { ...hook, ast: replaceDelay(hook.ast, 2_592_001) as typeof hook.ast }
        : hook,
    ),
  } as typeof hookPlan);
  assert.throws(
    () => compileOnchainHookPlan(overDelay),
    (error: unknown) => {
      assert.ok(error instanceof HookPlanCompilationError);
      assert.match(
        error.issues.join("; "),
        /delaySeconds must not exceed 2592000/,
      );
      return true;
    },
  );

  const emptyDepsHooks = hookPlan.compiledHooks.map((hook) =>
    hook === timeoutHook ? { ...hook, dependencies: [] } : hook,
  );
  const emptyDeps = resign({
    ...hookPlan,
    compiledHooks: emptyDepsHooks,
    dependencyIndex: rebuildDependencyIndex(emptyDepsHooks),
  } as typeof hookPlan);
  assert.throws(
    () => compileOnchainHookPlan(emptyDeps),
    (error: unknown) => {
      assert.ok(error instanceof HookPlanCompilationError);
      assert.match(
        error.issues.join("; "),
        /dependencies must not be empty/,
      );
      return true;
    },
  );

  const emptyPlan = resign({
    ...hookPlan,
    compiledHooks: [],
    dependencyIndex: {},
    supplierRoutes: {},
    selectedStageBindings: [],
    signalCapabilities: [],
  } as typeof hookPlan);
  assert.throws(
    () => compileOnchainHookPlan(emptyPlan),
    (error: unknown) => {
      assert.ok(error instanceof HookPlanCompilationError);
      assert.match(
        error.issues.join("; "),
        /compiledHooks must not be empty \(contract reverts EmptyPlan\)/,
      );
      return true;
    },
  );
});

test("artifact boundary rejects compiledHooks arrays that break the canonical order", () => {
  const onchain = compileOnchainHookPlan(
    compileZhixuHookPlan(baseZhixu),
  );
  const reversed = [...onchain.compiledHooks].reverse();
  const index = new Map<string, string[]>();
  for (const hook of reversed) {
    for (const dependency of hook.dependencies) {
      const hookIds = index.get(dependency.signalKey) ?? [];
      if (!hookIds.includes(hook.hookId)) {
        hookIds.push(hook.hookId);
      }
      index.set(dependency.signalKey, hookIds);
    }
  }
  const dependencyIndex = Object.fromEntries(
    [...index.entries()].sort(([left], [right]) =>
      left < right ? -1 : left > right ? 1 : 0,
    ),
  ) as OnchainHookPlanArtifact["dependencyIndex"];
  const reordered = {
    ...onchain,
    compiledHooks: reversed,
    dependencyIndex,
  };
  const { planHash: _drop, ...payload } = reordered;
  void _drop;
  const issues = validateOnchainHookPlanArtifact({
    ...reordered,
    planHash: hashOnchainPlanPayload(payload),
  });
  assert.ok(
    issues.some((issue) => issue.includes("breaks the canonical order")),
    `重排 compiledHooks 应触发规范序 issue，实际 issues：${JSON.stringify(issues)}`,
  );
});

test("collects non-canonicalizable planHash payloads as issues instead of throwing (L8)", () => {
  const onchain = compileOnchainHookPlan(
    compileZhixuHookPlan(baseZhixu),
  );
  const poisoned = structuredClone(onchain) as unknown as {
    compiledHooks: Array<{
      dependencies: Array<Record<string, unknown>>;
    }>;
  };
  poisoned.compiledHooks[0]!.dependencies[0]!.signalKey = 1n as never;
  const issues = validateOnchainHookPlanArtifact(poisoned);
  assert.ok(
    issues.includes(
      "planHash preimage is not canonicalizable (payload carries undefined or non-JSON values)",
    ),
    `expected a canonicalizability issue, got: ${JSON.stringify(issues)}`,
  );
  assert.doesNotThrow(() => validateOnchainHookPlanArtifact(poisoned));
});

test("rejects undeclared extra fields on on-chain HookPlan artifacts (L9)", () => {
  const onchain = compileOnchainHookPlan(
    compileZhixuHookPlan(baseZhixu),
  );
  const issues = validateOnchainHookPlanArtifact({
    ...onchain,
    note: "hand-added",
  });
  assert.deepEqual(issues, [
    "unknown field `note` on the artifact — planHash does not cover undeclared fields, so the artifact would not be the plan's unique byte form; remove it or recompile",
  ]);
});

test("rejects undeclared extra fields on deep on-chain artifact objects (L9 mirror)", () => {
  const zhixu: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: baseZhixu.spec.stages.map((stage) =>
        stage.name === "assign"
          ? {
              ...stage,
              sendSignals: [
                { name: "executor_selected", validWhen: ["buyer::assign.seed"] },
                { name: "seed" },
              ],
            }
          : stage
      ),
    },
  };
  const onchain = compileOnchainHookPlan(
    compileZhixuHookPlan(zhixu),
  );
  assert.ok(onchain.admissions.length > 0, "fixture must carry an admission entry");

  const rehashed = (mutated: OnchainHookPlanArtifact): OnchainHookPlanArtifact => {
    const { planHash: _drop, ...payload } = mutated;
    void _drop;
    return {
      ...mutated,
      planHash: hashOnchainPlanPayload(payload as never),
    } as OnchainHookPlanArtifact;
  };
  const issuesOf = (
    locate: (artifact: OnchainHookPlanArtifact) => object | undefined,
  ): readonly string[] => {
    const clone = structuredClone(onchain) as OnchainHookPlanArtifact;
    const target = locate(clone);
    if (target !== undefined) {
      (target as Record<string, unknown>).smuggled = 1;
    }
    return validateOnchainHookPlanArtifact(rehashed(clone));
  };
  const closureIssue = (path: string): string =>
    `unknown field \`smuggled\` on ${path} — the artifact schema is a closed field set, `
    + "so the artifact would not be the plan's unique byte form; remove it or recompile";
  const routedHookIndex = onchain.compiledHooks.findIndex(
    (hook) => hook.stageIdentifier === "assign",
  );
  assert.ok(routedHookIndex >= 0 && onchain.compiledHooks[routedHookIndex]!.routeRef,
    "fixture must expose a routeRef");
  const compositeHookIndex = onchain.compiledHooks.findIndex((hook) =>
    hook.instructions.some((instruction) => instruction.op !== "SIGNAL"),
  );
  assert.ok(compositeHookIndex >= 0, "fixture must expose a non-SIGNAL instruction");
  const compositeInstructionIndex = onchain.compiledHooks[compositeHookIndex]!.instructions
    .findIndex((instruction) => instruction.op !== "SIGNAL");

  assert.ok(
    issuesOf((a) => a.compiledHooks[0]).includes(closureIssue("compiledHooks[0]")),
  );
  assert.ok(
    issuesOf((a) => a.compiledHooks[0]!.instructions[0]).includes(
      closureIssue("compiledHooks[0].instructions[0]"),
    ),
  );
  assert.ok(
    issuesOf(
      (a) =>
        a.compiledHooks[compositeHookIndex]!.instructions[compositeInstructionIndex],
    ).includes(
      closureIssue(
        `compiledHooks[${compositeHookIndex}].instructions[${compositeInstructionIndex}]`,
      ),
    ),
  );
  assert.ok(
    issuesOf((a) => a.compiledHooks[0]!.dependencies[0]).includes(
      closureIssue("compiledHooks[0].dependencies[0]"),
    ),
  );
  assert.ok(
    issuesOf((a) => a.compiledHooks[routedHookIndex]!.routeRef).includes(
      closureIssue(`compiledHooks[${routedHookIndex}].routeRef`),
    ),
  );
  assert.ok(
    issuesOf((a) => a.admissions[0]).includes(closureIssue("admissions[0]")),
  );
  assert.ok(
    issuesOf((a) => a.supplierRoutes[0]).includes(closureIssue("supplierRoutes[0]")),
  );
  assert.ok(
    issuesOf((a) => a.selectorBindings[0]).includes(closureIssue("selectorBindings[0]")),
  );
  assert.ok(
    issuesOf((a) => a.signalCapabilities[0]).includes(closureIssue("signalCapabilities[0]")),
  );
  assert.ok(
    issuesOf((a) => a.supplierBindings[0]).includes(closureIssue("supplierBindings[0]")),
  );

  assert.deepEqual(
    validateOnchainHookPlanArtifact(rehashed(structuredClone(onchain))),
    [],
  );
});

test("rejects trigger birth stages without their own static supplier route", () => {
  const zhixu: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: [
        ...baseZhixu.spec.stages.map((stage) =>
          stage.name === "assign"
            ? {
                ...stage,
                name: "selector",
                receiveSignals: { PLACE: "buyer::selector.seed" },
              }
            : stage.name === "main"
              ? {
                  ...stage,
                  receiveSignals: {
                    START: "buyer::selector.executor_selected",
                    TIMEOUT:
                      "buyer::(selector.executor_selected +5s) & ~main.cmp",
                  },
                }
              : stage,
        ),
        {
          name: "birth",
          source: "fulfiller",
          sendSignals: [{ name: "str", trigger: true }, { name: "cmp" }, { name: "err" }],
          executor: { supplierType: "organization", supplierID: SUPPLIER_FULFILLER },
        },
        {
          name: "routing",
          source: "buyer",
          selectedStages: ["birth"],
          receiveSignals: { PLACE: "buyer::routing.seed" },
          sendSignals: [{ name: "picked" }, { name: "seed" }],
          executor: { supplierType: "organization", supplierID: SUPPLIER_ROUTING },
        }],
    },
  };

  const ir = compileZhixuHookPlan(zhixu);
  const onchain = compileOnchainHookPlan(ir);
  const birthHook = onchain.compiledHooks.find(
    (hook) => hook.stageIdentifier === "birth",
  );
  assert.ok(birthHook, "birth hook missing from compiled plan");
  assert.equal(birthHook.orderTriggerKind, "trigger");
  assert.ok(
    onchain.selectorBindings.some(
      (binding) => binding.targetStageIdentifier === "birth",
    ),
    "fixture must anchor the birth stage through selectedStages",
  );
  assert.deepEqual(validateOnchainHookPlanArtifact(onchain), []);

  const strippedIr = resign({
    ...ir,
    supplierRoutes: Object.fromEntries(
      Object.entries(ir.supplierRoutes).filter(
        ([stageIdentifier]) => stageIdentifier !== "birth",
      ),
    ),
    compiledHooks: ir.compiledHooks.map((hook) => {
      if (hook.stageIdentifier !== "birth") {
        return hook;
      }
      const { route: _omitted, ...withoutRoute } = hook;
      void _omitted;
      return withoutRoute;
    }),
  } as typeof ir);
  assert.throws(
    () => compileOnchainHookPlan(strippedIr),
    (error: unknown) =>
      error instanceof HookPlanCompilationError &&
      error.issues.some((issue) =>
        /birth is a trigger birth stage \(trigger order-trigger hook\) and requires its own static supplier route/.test(
          issue,
        )
      ),
    "compile preflight must reject a trigger birth stage without its own supplier route",
  );

  const rehashed = (mutated: OnchainHookPlanArtifact): OnchainHookPlanArtifact => {
    const { planHash: _drop, ...payload } = mutated;
    void _drop;
    return {
      ...mutated,
      planHash: hashOnchainPlanPayload(payload as never),
    } as OnchainHookPlanArtifact;
  };
  const strippedOnchain = rehashed({
    ...structuredClone(onchain),
    supplierRoutes: onchain.supplierRoutes.filter(
      (route) => route.stageIdentifier !== "birth",
    ),
    compiledHooks: onchain.compiledHooks.map((hook) => {
      if (hook.stageIdentifier !== "birth") {
        return hook;
      }
      const { routeRef: _omitted, ...withoutRouteRef } = hook;
      void _omitted;
      return withoutRouteRef;
    }),
  } as OnchainHookPlanArtifact);
  assert.ok(
    validateOnchainHookPlanArtifact(strippedOnchain).some((issue) =>
      /birth is a trigger birth stage \(trigger order-trigger hook\) and requires its own static supplier route/.test(
        issue,
      )
    ),
    "artifact boundary must reject a trigger birth stage without its own supplier route",
  );
});
test("hook dependencies must mirror the SIGNAL atom key set (contract mirror)", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu));
  const watcher = onchain.compiledHooks.find(
    (hook) => hook.orderTriggerKind === "none" && hook.dependencies.length === 1,
  );
  assert.ok(watcher, "demo artifact must expose a single-dependency watcher");

  const ghostSignalName = "buyer::ghost.signal";
  const ghost = {
    kind: "positive",
    source: watcher.dependencies[0]!.source,
    signalName: ghostSignalName,
    sourceId: watcher.dependencies[0]!.sourceId,
    signalId: onchainSignalId(ghostSignalName),
    signalKey: onchainSignalKey(
      watcher.dependencies[0]!.sourceId,
      onchainSignalId(ghostSignalName),
    ),
  };
  const issues = validateOnchainHookPlanArtifact({
    ...onchain,
    compiledHooks: onchain.compiledHooks.map((hook) =>
      hook === watcher ? { ...hook, dependencies: [ghost] } : hook,
    ),
    dependencyIndex: {
      ...onchain.dependencyIndex,
      [ghost.signalKey]: [watcher.hookId],
      [watcher.dependencies[0]!.signalKey]: onchain.dependencyIndex[
        watcher.dependencies[0]!.signalKey
      ]!.filter((hookId) => hookId !== watcher.hookId),
    },
  });
  assert.equal(
    issues.some((issue) =>
      /dependencies key .* is not a SIGNAL atom of this hook/.test(issue),
    ),
    true,
    `expected dangling dependency issue, got: ${issues.join("; ")}`,
  );
  assert.equal(
    issues.some((issue) =>
      /SIGNAL key .* is not declared in dependencies/.test(issue),
    ),
    true,
    `expected undeclared SIGNAL atom issue, got: ${issues.join("; ")}`,
  );
});

test("capabilitiesRoot varies with table contents and pins empty tables to EMPTY_MERKLE_ROOT", () => {
  assert.equal(capabilitiesRootOf([], []), EMPTY_MERKLE_ROOT);

  const withBinding = compileOnchainHookPlan(
    compileZhixuHookPlan(baseZhixu),
  );
  const withoutBinding = compileOnchainHookPlan(
    compileZhixuHookPlan(
      {
        ...baseZhixu,
        spec: {
          ...baseZhixu.spec,
          stages: baseZhixu.spec.stages.map((stage) => ({
            ...stage,
            selectedStages: [],
          })),
        },
      },
    ),
  );
  assert.deepEqual(withoutBinding.selectorBindings, []);
  assert.deepEqual(withBinding.signalCapabilities, withoutBinding.signalCapabilities);
  assert.notEqual(withBinding.capabilitiesRoot, withoutBinding.capabilitiesRoot);
  assert.notEqual(withoutBinding.capabilitiesRoot, EMPTY_MERKLE_ROOT);

  const tables = capabilityTablesOf(withoutBinding);
  const flipped = tables.signalCapabilities.map((capability, index) =>
    index === 0
      ? { ...capability, targetOrderRelation: (capability.targetOrderRelation === 0 ? 1 : 0) as 0 | 1 }
      : capability,
  );
  assert.notEqual(
    capabilitiesRootOf(tables.selectorBindings, flipped),
    withoutBinding.capabilitiesRoot,
  );
  assert.equal(
    withBinding.capabilitiesRoot,
    artifactCapabilitiesRoot(withBinding),
  );
});

test("triggers are derived, not committed: boundary rejects tampering and planHash excludes them", () => {
  const TRIGGER_ENUMERATION_ISSUE =
    "triggers must enumerate every order-trigger hook of compiledHooks in canonical hook order, "
    + "each entry derived from that hook's single positive dependency; a missing, surplus, reordered, "
    + "or tampered entry is rejected";
  const enumerationIssues = (
    artifact: OnchainHookPlanArtifact,
  ): readonly string[] =>
    validateOnchainHookPlanArtifact(artifact).filter(
      (issue) => issue === TRIGGER_ENUMERATION_ISSUE,
    );

  const triggerZhixu: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: [
        ...baseZhixu.spec.stages,
        {
          name: "birth",
          source: "fulfiller",
          sendSignals: [{ name: "str", trigger: true }, { name: "ack", trigger: true }, { name: "cmp" }],
          executor: { supplierType: "organization", supplierID: SUPPLIER_FULFILLER },
        },
      ],
    },
  };
  const onchain = compileOnchainHookPlan(
    compileZhixuHookPlan(triggerZhixu),
  );
  assert.deepEqual(
    onchain.triggers.map((trigger) => [
      trigger.stageIdentifier,
      trigger.hookName,
      trigger.orderTriggerKind,
    ]),
    [
      ["birth", "ack", "trigger"],
      ["birth", "str", "trigger"],
    ],
  );
  assert.deepEqual(enumerationIssues(onchain), []);

  assert.equal(enumerationIssues({ ...onchain, triggers: [] }).length, 1);
  assert.equal(
    enumerationIssues({
      ...onchain,
      triggers: [...onchain.triggers].reverse(),
    }).length,
    1,
  );
  assert.equal(
    enumerationIssues({
      ...onchain,
      triggers: onchain.triggers.map((trigger, index) =>
        index === 0 ? { ...trigger, hookName: "tampered" } : trigger,
      ),
    }).length,
    1,
  );

  const { planHash: _committed, ...payload } = onchain;
  assert.equal(
    hashOnchainPlanPayload({
      ...payload,
      triggers: onchain.triggers.map((trigger) => ({
        ...trigger,
        stageIdentifier: "tampered",
      })),
    }),
    onchain.planHash,
    "triggers are a derived read face and must not enter the planHash preimage",
  );
  assert.notEqual(
    hashOnchainPlanPayload({
      ...payload,
      compiledHooks: payload.compiledHooks.map((hook, index) =>
        index === 0 ? { ...hook, emitReady: !hook.emitReady } : hook,
      ),
    }),
    onchain.planHash,
    "the committed compiledHooks stay inside the planHash preimage",
  );
});

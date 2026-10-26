import assert from "node:assert/strict";
import {
  dockDemoResolutionManifest,
  dockDemoTargetUid,
  dockProductionTargetDefinition,
} from "./dock-demo.js";
import {
  EMPTY_MERKLE_ROOT,
  definitionUid,
  verifyMerkleProof,
  dockCandidateLeaf,
  dockRouteId,
  merkleRoot,
  routeHash,
  stageKey,
  ZERO_WORD,
} from "../src/dock.js";
import test from "node:test";
import { canonicalJson } from "@uvp-eth/canonical-json";
import {
  assertOnchainHookPlanArtifact,
  compileZhixuOnchainHookPlan,
  hashSolidityRegisterHooks,
  keccak256Hex,
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
import { hookPlanHashOf } from "../src/dock-commitments.js";
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

const demoManifest = dockDemoResolutionManifest();
const goldenDemo = commitmentGoldenCase("demo_zhixu_production_dock");

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

function compileZhixuHookPlanWithManifest(
  definition: ZhixuDefinition,
): ReturnType<typeof compileZhixuHookPlan> {
  return compileZhixuHookPlan(definition, demoManifest);
}

function compileZhixuOnchainHookPlanWithManifest(
  definition: ZhixuDefinition,
): ReturnType<typeof compileZhixuOnchainHookPlan> {
  return compileZhixuOnchainHookPlan(definition, demoManifest);
}

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
          supplierID: "selector-org",
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
          supplierType: "zhixu",
          zhixuExecutorConfig: {
            target: { zhixu: dockDemoTargetUid() },
            interface: "production_service",
            order: { mode: "new" },
            inputMap: { START: "execute" },
            signalMap: { str: "started", cmp: "completed" },
          },
        },
      }],
  },
};

test("compiles a stable compact on-chain HookPlan artifact", () => {
  const sourcePlan = compileZhixuHookPlan(baseZhixu, demoManifest);
  const onchain = compileOnchainHookPlan(sourcePlan);
  const again = compileZhixuOnchainHookPlan(baseZhixu, demoManifest);

  assert.deepEqual(onchain, again);
  assert.equal(onchain.schemaVersion, "uvp.onchainHookPlan.v3");
  assert.equal(onchain.planId, sourcePlan.planId);
  assert.deepEqual(onchain.platform, sourcePlan.platform);
  assert.equal(onchain.sourcePlanHash, sourcePlan.planHash);
  assert.equal(onchain.planHash, goldenDemo.expected.onchainPlanHash);
  assert.deepEqual(onchain.executorCandidates, []);
  assert.equal(onchain.executorCandidatesRoot, EMPTY_MERKLE_ROOT);
  assert.equal(onchain.capabilitiesRoot, goldenDemo.expected.capabilitiesRoot);
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
  assert.deepEqual(
    onchain.compiledHooks.map((hook) => hook.hookId),
    goldenDemo.input.hooks.map((hook) => hook.hookId),
  );
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
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));
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
    compileZhixuHookPlan(orZhixu, demoManifest),
  ).compiledHooks.find((hook) => hook.hookName === "ALT");

  assert.deepEqual(
    orHook?.instructions.map((instruction) => instruction.op),
    ["SIGNAL", "SIGNAL", "OR"],
  );
  assert.deepEqual(orHook?.instructions[2], { op: "OR", arity: 2 });
});

test("builds a stable on-chain dependency index and route references", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));

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
    onchain.executorRoutes.map((route) => route.routeId),
    ["0x35f6e55806e8018d555e976995705fa96f202a0a8499a801846c3d0c8d83c1e4"],
  );
  assert.equal(
    onchain.compiledHooks.find((hook) => hook.hookName === "START")?.routeRef,
    undefined,
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
            supplierID: "watcher-org",
          },
        }],
    },
  };
  const onchain = compileZhixuOnchainHookPlanWithManifest(zhixu);
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
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));

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
        "capabilitiesRoot must match the recomputed root over selector bindings and signal capabilities",
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

test("maps on-chain artifacts to Solidity register-plan argument shape", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));
  const args = toSolidityRegisterPlanArgs(onchain);

  assert.equal(args.schemaVersion, "uvp.onchainHookPlan.v3");
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
    args.executorRoutes.map((route) => route.executorId),
    ["selector-org"],
  );
  assert.match(args.dockRoutesRoot, /^0x[0-9a-f]{64}$/);
  assert.notEqual(args.dockRoutesRoot, EMPTY_MERKLE_ROOT);
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
  const withBinding = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));
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
    compileZhixuHookPlan(withoutSelectedStages, demoManifest),
  );

  assert.deepEqual(withoutBinding.selectorBindings, []);
  assert.notEqual(withBinding.planHash, withoutBinding.planHash);
});

test("capability tables feed the capabilitiesRoot and the runtime plan hash", () => {
  const withBinding = toSolidityRegisterPlanArgs(
    compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest)),
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
        demoManifest,
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
  assert.equal(vectors.cases.length, 10);
  assert.equal(vectors.registerHooksVectors.length, 1);

  for (const vector of vectors.uidVectors) {
    assert.equal(
      definitionUid(vector.input.definition),
      vector.expected.uid,
      `${vector.name}: uid`,
    );
  }

  for (const golden of vectors.cases) {
    const { definition, dockManifest, executorCandidates } = golden.input;
    const plan = compileZhixuHookPlan(definition, dockManifest);
    const onchain = compileZhixuOnchainHookPlan(
      definition,
      dockManifest,
      executorCandidates,
    );
    const args = toSolidityRegisterPlanArgs(onchain);

    assert.equal(plan.zhixuId, golden.expected.uid, `${golden.name}: uid`);
    assert.equal(plan.planHash, golden.expected.hookPlanHash, `${golden.name}: IR planHash`);
    assert.equal(onchain.planHash, golden.expected.onchainPlanHash, `${golden.name}: onchain planHash`);
    assert.equal(args.planHash, golden.expected.runtimePlanHash, `${golden.name}: runtime planHash`);
    assert.equal(args.hooksHash, golden.expected.hooksHash, `${golden.name}: hooksHash`);
    assert.equal(args.capabilitiesRoot, golden.expected.capabilitiesRoot, `${golden.name}: capabilitiesRoot`);
    assert.equal(onchain.dockRoutesRoot, golden.expected.dockRoutesRoot, `${golden.name}: dockRoutesRoot`);
    assert.equal(onchain.dockInterfaceRoot, golden.expected.dockInterfaceRoot, `${golden.name}: dockInterfaceRoot`);
    assert.equal(onchain.executorCandidatesRoot, golden.expected.executorCandidatesRoot, `${golden.name}: executorCandidatesRoot`);

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
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));

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
    orderTriggerKind: "mint" | "none",
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
      hookOf("t1", "a", stageA, "mint"),
      hookOf("t2", "b", stageB, "mint"),
      hookOf("w1", "a", stageA, "none"),
    ],
    rejected: [
      hookOf("w1", "a", stageA, "none"),
      hookOf("t1", "b", stageB, "mint"),
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

  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));
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
  const sourcePlan = compileZhixuHookPlan(baseZhixu, demoManifest);
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
  const sourcePlan = compileZhixuHookPlan(baseZhixu, demoManifest);

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
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));

  assert.deepEqual(
    validateOnchainHookPlanArtifact({ ...onchain, schemaVersion: "wrong" }),
    ["schemaVersion must be uvp.onchainHookPlan.v3"],
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

test("collects dock commitment shape violations as issues instead of throwing or pinning defaults", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));

  const strip = (field: string): Record<string, unknown> => {
    const { [field]: _removed, ...rest } = {
      ...onchain,
    } as Record<string, unknown>;
    return rest;
  };

  const badRoutesIssues = validateOnchainHookPlanArtifact({
    ...onchain,
    dockRoutes: { "0x50": [] },
  } as unknown as OnchainHookPlanArtifact);
  assert.ok(
    badRoutesIssues.includes("dockRoutes must be an array"),
    `expected dockRoutes shape issue, got: ${badRoutesIssues.join("; ")}`,
  );

  const missingRoutesRootIssues = validateOnchainHookPlanArtifact(
    strip("dockRoutesRoot"),
  );
  assert.ok(
    missingRoutesRootIssues.includes(
      "dockRoutesRoot must be a lowercase 32-byte hex hash",
    ),
  );
  assert.ok(
    !missingRoutesRootIssues.includes(
      "planHash must match the canonical on-chain HookPlan payload",
    ),
    "planHash must not be recomputed while dockRoutesRoot is missing",
  );

  assert.ok(
    validateOnchainHookPlanArtifact({
      ...onchain,
      dockInterfaceRoot: "0xdeadbeef",
    }).includes("dockInterfaceRoot must be a lowercase 32-byte hex hash"),
  );

  const missingInterfaceIssues = validateOnchainHookPlanArtifact(
    strip("dockInterface"),
  );
  assert.ok(
    missingInterfaceIssues.includes(
      "artifact.dockInterface must be an object or null",
    ),
  );
  assert.ok(
    !missingInterfaceIssues.includes(
      "planHash must match the canonical on-chain HookPlan payload",
    ),
  );
});

test("rejects non-birth subscription receive hooks with the typed compilation error", () => {
  for (const [hookName, expression] of [
    ["START", "::ANCHOR(@buyer::assign.executor_selected)"]
  ] as const) {
    const zhixu: ZhixuDefinition = {
      ...baseZhixu,
      spec: {
        ...baseZhixu.spec,
        stages: baseZhixu.spec.stages.map((stage) =>
          stage.name === "main"
            ? {
                ...stage,
                receiveSignals: { [hookName]: expression },
                executor: {
                  supplierType: "organization",
                  supplierID: "execution-org"
                }
              }
            : stage
        )
      }
    };

    assert.throws(
      () => compileOnchainHookPlan(compileZhixuHookPlan(zhixu, demoManifest)),
      (error: unknown) =>
        error instanceof HookPlanCompilationError &&
        error.issues.some(
          (issue) =>
            /only supports subscription entries on order-trigger hooks/.test(issue) &&
            /subscription-mint-spec\.md/.test(issue)
        )
    );
  }
});

test("compiles mint birth subscriptions into order-trigger SIGNAL hooks", () => {
  const zhixu: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: [
        ...baseZhixu.spec.stages,
        {
          name: "post",
          source: "buyer",
          receiveSignals: {
            PUBLISH: "buyer::post.seed",
          },
          sendSignals: [{ name: "posted" }, { name: "seed" }],
          executor: {
            supplierType: "organization",
            supplierID: "intake-exec",
          },
        },
        {
          name: "birth",
          source: "fulfiller",
          mint: "per-fact",
          receiveSignals: {
            BIRTH: "::ANCHOR(@buyer::post.posted)",
          },
          sendSignals: [{ name: "str" }, { name: "cmp" }, { name: "err" }],
          executor: {
            supplierType: "organization",
            supplierID: "fulfiller-exec",
          },
        }],
    },
  };

  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(zhixu, demoManifest));
  const hook = onchain.compiledHooks.find((item) => item.hookName === "BIRTH");
  assert.ok(hook, "birth hook missing from compiled plan");
  assert.equal(hook.orderTriggerKind, "mint");
  assert.equal(hook.emitReady, true);
  assert.equal(hook.instructions.length, 1);
  const birth = hook.instructions[0] as OnchainSignalInstruction;
  assert.equal(birth.op, "SIGNAL");
  assert.equal(birth.sourceId, onchainSourceId("buyer"));
  assert.equal(birth.signalId, onchainSignalId("post.posted"));
});

test("rejects empty instructions the way the contract reverts InvalidHook", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));
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
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));
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
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));
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
    () => compileOnchainHookPlan(compileZhixuHookPlan(sharedZhixu, demoManifest)),
    (error: unknown) =>
      error instanceof HookPlanCompilationError &&
      error.issues.some((issue) => /shared across stages/.test(issue))
  );
});

test("flags stages whose hooks can never materialize on-chain", () => {
  const materializationIssues = (issues: readonly string[]): readonly string[] =>
    issues.filter((issue) => /no order-trigger or EMIT_READY hook/.test(issue));

  const mintZhixu: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: [
        ...baseZhixu.spec.stages,
        {
          name: "post",
          source: "buyer",
          receiveSignals: {
            PUBLISH: "buyer::post.seed",
          },
          sendSignals: [{ name: "posted" }, { name: "seed" }],
          executor: {
            supplierType: "organization",
            supplierID: "intake-exec",
          },
        },
        {
          name: "birth",
          source: "fulfiller",
          mint: "per-fact",
          receiveSignals: {
            BIRTH: "::ANCHOR(@buyer::post.posted)",
          },
          sendSignals: [{ name: "str" }, { name: "cmp" }, { name: "err" }],
          executor: {
            supplierType: "organization",
            supplierID: "fulfiller-exec",
          },
        }],
    },
  };
  const mintOnchain = compileOnchainHookPlan(
    compileZhixuHookPlan(mintZhixu, demoManifest),
  );
  assert.deepEqual(materializationIssues(validateOnchainHookPlanArtifact(mintOnchain)), []);

  const baseOnchain = compileOnchainHookPlan(
    compileZhixuHookPlan(baseZhixu, demoManifest),
  );
  assert.deepEqual(materializationIssues(validateOnchainHookPlanArtifact(baseOnchain)), []);

  const dockOnchain: OnchainHookPlanArtifact = {
    ...baseOnchain,
    compiledHooks: baseOnchain.compiledHooks.map((hook) =>
      hook.stageIdentifier === "main"
        ? { ...hook, orderTriggerKind: "dock" as const }
        : hook,
    ),
  };
  assert.deepEqual(materializationIssues(validateOnchainHookPlanArtifact(dockOnchain)), []);

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

  const watcherSourcePlan = compileZhixuHookPlan(baseZhixu, demoManifest);
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
  const sourcePlan = compileZhixuHookPlan(baseZhixu, demoManifest);
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
      /^stage assign declares no receiveSignals and compiles to zero hooks: the stage can never materialize on-chain \(materialization only happens via this stage's own order-trigger\/EMIT_READY hooks\) and its sendSignals have no hook to hang on — submitSignal requires the source stage to be materialized and reverts UnknownHook forever \(deadlock, no recovery path\); declare receiveSignals carrying a mint\/dock entrance or a static executor$/.test(
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

test("dock entrance hooks materialize their stage (CORE-8 materialization gate)", () => {
  const materializationIssues = (issues: readonly string[]): readonly string[] =>
    issues.filter((issue) =>
      /no order-trigger or EMIT_READY hook|compiles to zero hooks/.test(issue),
    );

  const targetOnchain = compileZhixuOnchainHookPlan(
    dockProductionTargetDefinition(),
  );
  const entranceHook = targetOnchain.compiledHooks.find(
    (hook) => hook.stageIdentifier === "intake",
  );
  assert.equal(entranceHook?.hookName, "EXECUTE");
  assert.equal(entranceHook?.orderTriggerKind, "dock");
  assert.equal(entranceHook?.emitReady, true);
  assert.deepEqual(
    materializationIssues(validateOnchainHookPlanArtifact(targetOnchain)),
    [],
  );
});

function dynamicExistingZhixu(target: { zhixu: string } | null): ZhixuDefinition {
  return {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: baseZhixu.spec.stages.map((stage) =>
        stage.name !== "main"
          ? stage
          : {
              ...stage,
              receiveSignals: {
                START: "buyer::assign.executor_selected",
              },
              executor: {
                supplierType: "zhixu" as const,
                zhixuExecutorConfig: {
                  target,
                  interface: "production_evidence",
                  order: { mode: "existing" as const },
                  signalMap: { cmp: "scrap_declared" },
                },
              },
            },
      ),
    },
  };
}

test("carries existing-mode dock routes on the on-chain track (UVPDockingModule 4.4)", () => {
  const existingZhixu = dynamicExistingZhixu({ zhixu: dockDemoTargetUid() });

  const onchain = compileZhixuOnchainHookPlan(existingZhixu, demoManifest);
  assert.equal(onchain.dockRoutes.length, 1);
  const route = onchain.dockRoutes[0]!;
  assert.equal(route.orderMode, "existing");
  assert.equal(route.inputBindings.length, 0);
  assert.equal(route.inputBindingsRoot, EMPTY_MERKLE_ROOT);
  assert.deepEqual(validateOnchainHookPlanArtifact(onchain), []);
  assert.doesNotThrow(() => toSolidityRegisterPlanArgs(onchain));

  assert.notEqual(
    routeHash({
      localDefinitionRefHash: route.local.definitionRefHash,
      targetDefinitionRefHash: route.target.definitionRefHash,
      targetPlanId: route.target.chainPlanId,
      interfaceName: route.target.interfaceName,
      orderMode: "new",
      inputBindingsRoot: route.inputBindingsRoot,
      outputBindingsRoot: route.outputBindingsRoot,
    }),
    route.routeHash,
  );
  assert.equal(route.routeHash, onchain.dockRoutesRoot);
});

test("dynamic (null-target) routes never ride in dockRoutes (smuggling gate)", () => {
  const onchain = compileOnchainHookPlan(
    compileZhixuHookPlan(baseZhixu, demoManifest),
  );
  const unresolved = structuredClone(onchain) as OnchainHookPlanArtifact & {
    dockRoutes: Array<Record<string, unknown>>;
  };
  (unresolved.dockRoutes[0] as Record<string, unknown>).target = null;
  const { planHash: _stale, ...payload } = unresolved;
  void _stale;
  const issues = validateOnchainHookPlanArtifact({
    ...payload,
    planHash: hashOnchainPlanPayload(payload as never),
  } as unknown as OnchainHookPlanArtifact);
  assert.ok(
    issues.some((issue) =>
      /no statically linked target block/.test(issue) &&
      /must be carried in unresolvedDockRoutes/.test(issue),
    ),
    issues.join("; "),
  );
});

test("carries dynamic-selection (target:null) routes as unresolvedDockRoutes with candidate commitments", () => {
  const dynamicZhixu = dynamicExistingZhixu(null);
  const onchain = compileZhixuOnchainHookPlan(dynamicZhixu, demoManifest);
  assert.equal(onchain.dockRoutes.length, 0);
  const unresolved = onchain.unresolvedDockRoutes ?? [];
  assert.equal(unresolved.length, 1);
  const route = unresolved[0]!;
  assert.equal(route.schemaVersion, "uvp.dockRoute.unresolved.v1");
  assert.equal(route.stageIdentifier, "main");
  assert.equal(route.orderMode, "existing");
  assert.equal(route.interfaceName, "production_evidence");
  assert.deepEqual(
    route.outputBindings.map((binding) => [binding.signal, binding.port]),
    [["cmp", "scrap_declared"]],
  );

  const manifestEntry = demoManifest.definitions[0]!;
  assert.equal(route.candidates.length, 1);
  assert.equal(route.candidates[0]?.zhixuName, manifestEntry.definition.metadata.name);
  assert.equal(route.candidates[0]?.zhixuUid, manifestEntry.zhixu);
  assert.equal(route.candidates[0]?.definitionRefHash, manifestEntry.definitionRefHash);

  const expectedRouteId = dockRouteId(
    route.localDefinitionRefHash,
    stageKey("main"),
  );
  assert.equal(route.routeId, expectedRouteId);
  const expectedCandidatesRoot = merkleRoot([
    dockCandidateLeaf({
      routeId: expectedRouteId,
      targetDefinitionRefHash: manifestEntry.definitionRefHash,
      targetPlanId: manifestEntry.chainPlanId!,
      interfaceName: "production_evidence",
    }),
  ]);
  assert.equal(route.candidatesRoot, expectedCandidatesRoot);
  assert.equal(
    route.routeHash,
    routeHash({
      localDefinitionRefHash: route.localDefinitionRefHash,
      targetDefinitionRefHash: expectedCandidatesRoot,
      targetPlanId: ZERO_WORD,
      interfaceName: "production_evidence",
      orderMode: "existing",
      inputBindingsRoot: EMPTY_MERKLE_ROOT,
      outputBindingsRoot: EMPTY_MERKLE_ROOT,
    }),
  );

  assert.equal(onchain.dockRoutesRoot, merkleRoot([route.routeHash]));
  assert.deepEqual(validateOnchainHookPlanArtifact(onchain), []);
  assert.doesNotThrow(() => toSolidityRegisterPlanArgs(onchain));
});

test("rejects dynamic-selection routes declaring order mode new (chain terminal state)", () => {
  const dynamicNew = structuredClone(baseZhixu) as ZhixuDefinition & {
    spec: { stages: Array<{ executor?: { zhixuExecutorConfig?: { target: { zhixu: string } | null } } }> };
  };
  dynamicNew.spec.stages[1]!.executor!.zhixuExecutorConfig!.target = null;
  assert.throws(
    () => compileZhixuOnchainHookPlan(dynamicNew as unknown as ZhixuDefinition, demoManifest),
    (error: unknown) => {
      assert.ok(error instanceof HookPlanCompilationError);
      const issues = error.issues.join("; ");
      assert.match(issues, /UNRESOLVED_DOCK_MODE/);
      assert.match(issues, /main/);
      assert.match(issues, /order mode "new"/);
      return true;
    },
  );

  const accepted = compileZhixuOnchainHookPlan(
    dynamicExistingZhixu(null),
    demoManifest,
  );
  const entry = accepted.unresolvedDockRoutes![0]!;
  const forgedRouteHash = routeHash({
    localDefinitionRefHash: entry.localDefinitionRefHash,
    targetDefinitionRefHash: entry.candidatesRoot,
    targetPlanId: ZERO_WORD,
    interfaceName: entry.interfaceName,
    orderMode: "new",
    inputBindingsRoot: EMPTY_MERKLE_ROOT,
    outputBindingsRoot: EMPTY_MERKLE_ROOT,
  });
  const forged = {
    ...accepted,
    unresolvedDockRoutes: [
      { ...entry, orderMode: "new" as const, routeHash: forgedRouteHash },
    ],
    dockRoutesRoot: merkleRoot([forgedRouteHash]),
  };
  const { planHash: _staleHash, ...forgedPayload } = forged;
  void _staleHash;
  const issues = validateOnchainHookPlanArtifact({
    ...forgedPayload,
    planHash: hashOnchainPlanPayload(forgedPayload as never),
  } as unknown as OnchainHookPlanArtifact);
  assert.ok(
    issues.some((issue) => /UNRESOLVED_DOCK_MODE/.test(issue)),
    issues.join("; "),
  );
});

test("rejects forged candidate lists and swapped dynamic leaves at the artifact boundary", () => {
  const onchain = compileZhixuOnchainHookPlan(
    dynamicExistingZhixu(null),
    demoManifest,
  );

  const forgedCandidate = structuredClone(onchain);
  (forgedCandidate.unresolvedDockRoutes![0]!.candidates[0] as {
    definitionRefHash: `0x${string}`;
  }).definitionRefHash = `0x${"ab".repeat(32)}`;
  const candidateIssues = validateOnchainHookPlanArtifact(forgedCandidate);
  assert.ok(
    candidateIssues.some((issue) =>
      /candidatesRoot must match the recomputed merkle root over candidate leaves/.test(
        issue,
      ),
    ),
    candidateIssues.join("; "),
  );

  const swappedLeaf = structuredClone(onchain);
  (swappedLeaf.unresolvedDockRoutes![0] as { routeHash: `0x${string}` })
    .routeHash = `0x${"cd".repeat(32)}`;
  const leafIssues = validateOnchainHookPlanArtifact(swappedLeaf);
  assert.ok(
    leafIssues.some((issue) =>
      /routeHash must match the recomputed dynamic-route preimage/.test(issue),
    ),
    leafIssues.join("; "),
  );
  assert.ok(
    leafIssues.some((issue) =>
      /dockRoutesRoot must match the recomputed root over dock route hashes/.test(
        issue,
      ),
    ),
    leafIssues.join("; "),
  );
});

test("rejects an explicit empty unresolvedDockRoutes list (closed field set)", () => {
  const onchain = compileZhixuOnchainHookPlan(
    dynamicExistingZhixu(null),
    demoManifest,
  );
  assert.ok(onchain.unresolvedDockRoutes?.length === 1);
  const emptied = { ...onchain, unresolvedDockRoutes: [] };
  const { planHash: _staleHash, ...payload } = emptied;
  void _staleHash;
  const issues = validateOnchainHookPlanArtifact({
    ...payload,
    planHash: hashOnchainPlanPayload(payload as never),
  } as unknown as OnchainHookPlanArtifact);
  assert.ok(
    issues.some((issue) =>
      /unresolvedDockRoutes must not be an empty array/.test(issue),
    ),
    issues.join("; "),
  );
});

test("rejects silent order-trigger hooks (trigger without emitReady)", () => {
  const silentTriggerIssues = (issues: readonly string[]): readonly string[] =>
    issues.filter((issue) => /order trigger without emitReady/.test(issue));

  const baseOnchain = compileOnchainHookPlan(
    compileZhixuHookPlan(baseZhixu, demoManifest),
  );
  assert.deepEqual(silentTriggerIssues(validateOnchainHookPlanArtifact(baseOnchain)), []);

  const silentMint: OnchainHookPlanArtifact = {
    ...baseOnchain,
    compiledHooks: baseOnchain.compiledHooks.map((hook) =>
      hook.stageIdentifier === "main" && hook.hookName === "START"
        ? { ...hook, orderTriggerKind: "mint" as const, emitReady: false }
        : hook,
    ),
  };
  const mintIssues = silentTriggerIssues(validateOnchainHookPlanArtifact(silentMint));
  assert.ok(mintIssues.length >= 1, "silent mint trigger must be flagged");
  for (const issue of mintIssues) {
    assert.match(
      issue,
      /hook main#.+ is an order trigger without emitReady; UVPStateMachine\.commitPlan reverts SilentOrderTriggerHook — the Rust compiler must always emit trigger flags with EMIT_READY$/,
    );
  }

  const silentDock: OnchainHookPlanArtifact = {
    ...baseOnchain,
    compiledHooks: baseOnchain.compiledHooks.map((hook) =>
      hook.stageIdentifier === "main" && hook.hookName === "START"
        ? { ...hook, orderTriggerKind: "dock" as const, emitReady: false }
        : hook,
    ),
  };
  assert.ok(
    silentTriggerIssues(validateOnchainHookPlanArtifact(silentDock)).length >= 1,
    "silent dock trigger must be flagged",
  );

  const silentSourcePlan = compileZhixuHookPlan(baseZhixu, demoManifest);
  const mutatedSilentPlan = resign({
    ...silentSourcePlan,
    compiledHooks: silentSourcePlan.compiledHooks.map((hook) =>
      hook.stageIdentifier === "main" && hook.hookName === "START"
        ? { ...hook, orderTriggerKind: "mint" as const, emitReady: false }
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
    compileZhixuHookPlan(baseZhixu, demoManifest),
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
    () => ({ orderTriggerKind: "mint" as const }),
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
    compileZhixuHookPlan(baseZhixu, demoManifest),
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

  const onchain = compileZhixuOnchainHookPlan(vetoZhixu, demoManifest);
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
  const targetPlan = compileZhixuHookPlan(
    dockProductionTargetDefinition(),
    demoManifest,
  );
  const triggerHook = targetPlan.compiledHooks.find(
    (hook) => hook.stageIdentifier === "intake" && hook.hookName === "EXECUTE",
  );
  assert.ok(triggerHook, "target fixture must expose the dock entrance trigger hook");
  assert.equal(triggerHook.orderTriggerKind, "dock");
  const delayed = resign({
    ...targetPlan,
    compiledHooks: targetPlan.compiledHooks.map((hook) =>
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
    ) as typeof targetPlan.compiledHooks,
  });
  assert.throws(
    () => compileOnchainHookPlan(delayed),
    (error: unknown) => {
      assert.ok(error instanceof HookPlanCompilationError);
      assert.match(
        error.issues.join("; "),
        /order-trigger hook \(dock\) must not contain DELAY/,
      );
      return true;
    },
  );
});

test("rejects supplierType outside the closed enum at the on-chain compile boundary", () => {
  const hookPlan = compileZhixuHookPlanWithManifest(baseZhixu);
  const mutated = resign({
    ...hookPlan,
    executorRoutes: {
      ...hookPlan.executorRoutes,
      "assign": {
        ...hookPlan.executorRoutes["assign"]!,
        executor: {
          ...hookPlan.executorRoutes["assign"]!.executor,
          supplierType: "Organization",
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
        /supplierType must be one of individual\|organization\|zhixu \(case-sensitive\), received "Organization"/,
      );
      return true;
    },
  );
});

test("rejects whitespace-padded supplierType at the on-chain compile boundary", () => {
  const hookPlan = compileZhixuHookPlanWithManifest(baseZhixu);
  for (const supplierType of [" organization ", "zhixu ", "\tindividual"]) {
    const mutated = resign({
      ...hookPlan,
      executorRoutes: {
        ...hookPlan.executorRoutes,
        "assign": {
          ...hookPlan.executorRoutes["assign"]!,
          executor: {
            ...hookPlan.executorRoutes["assign"]!.executor,
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
            `supplierType must be one of individual\\|organization\\|zhixu \\(case-sensitive\\), received ${JSON.stringify(supplierType).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`,
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
  compileOnchainHookPlan(compileZhixuHookPlanWithManifest(withSelectableZhixu));

  const hookPlan = compileZhixuHookPlanWithManifest(baseZhixu);
  for (const fileType of ["tx_cloud", " local", "http "]) {
    const mutated = resign({
      ...hookPlan,
      executorRoutes: {
        ...hookPlan.executorRoutes,
        "assign": {
          ...hookPlan.executorRoutes["assign"]!,
          executor: {
            ...hookPlan.executorRoutes["assign"]!.executor,
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
  const hookPlan = compileZhixuHookPlanWithManifest(baseZhixu);
  const route = hookPlan.executorRoutes["assign"]!;
  const mutated = resign({
    ...hookPlan,
    executorRoutes: {
      ...hookPlan.executorRoutes,
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
  const hookPlan = compileZhixuHookPlanWithManifest(baseZhixu);
  const mutateExecutor = (
    selectableResource: unknown,
  ): Parameters<typeof compileOnchainHookPlan>[0] =>
    resign({
      ...hookPlan,
      executorRoutes: {
        ...hookPlan.executorRoutes,
        "assign": {
          ...hookPlan.executorRoutes["assign"]!,
          executor: {
            ...hookPlan.executorRoutes["assign"]!.executor,
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
      executorRoutes: {
        ...hookPlan.executorRoutes,
        "assign": {
          ...hookPlan.executorRoutes["assign"]!,
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

test("artifact boundary enforces the executorType closed enum and non-empty executorId", () => {
  const onchain = compileOnchainHookPlan(
    compileZhixuHookPlanWithManifest(baseZhixu),
  );
  const route = onchain.executorRoutes[0]!;
  const rehashed = (mutated: OnchainHookPlanArtifact): OnchainHookPlanArtifact => {
    const { planHash: _drop, ...payload } = mutated;
    void _drop;
    return {
      ...mutated,
      planHash: hashOnchainPlanPayload(payload as never),
    } as OnchainHookPlanArtifact;
  };
  const mutateRoute = (
    patch: Partial<(typeof onchain.executorRoutes)[number]>,
  ): OnchainHookPlanArtifact =>
    rehashed({
      ...onchain,
      executorRoutes: onchain.executorRoutes.map((candidate) =>
        candidate === route ? { ...candidate, ...patch } : candidate,
      ),
    } as OnchainHookPlanArtifact);

  const issues = validateOnchainHookPlanArtifact(
    mutateRoute({ executorType: "Vendor" }),
  );
  assert.ok(
    issues.some((issue) =>
      /executorType must be one of individual\|organization\|zhixu \(case-sensitive\), received "Vendor"/.test(
        issue,
      ),
    ),
    issues.join("; "),
  );
  for (const executorType of [" organization ", "zhixu ", "\tindividual"]) {
    const paddedIssues = validateOnchainHookPlanArtifact(
      mutateRoute({ executorType }),
    );
    assert.ok(
      paddedIssues.some((issue) =>
        new RegExp(
          `executorType must be one of individual\\|organization\\|zhixu \\(case-sensitive\\), received ${JSON.stringify(executorType).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`,
        ).test(issue),
      ),
      `executorType=${JSON.stringify(executorType)}: ${paddedIssues.join("; ")}`,
    );
  }
  for (const executorId of ["", "   "]) {
    const idIssues = validateOnchainHookPlanArtifact(
      mutateRoute({ executorId }),
    );
    assert.ok(
      idIssues.some((issue) =>
        /executorId must be a non-empty executor id/.test(issue),
      ),
      `executorId=${JSON.stringify(executorId)}: ${idIssues.join("; ")}`,
    );
  }
  assert.deepEqual(
    validateOnchainHookPlanArtifact(
      rehashed(structuredClone(onchain) as OnchainHookPlanArtifact),
    ),
    [],
  );
});

test("compile boundary rejects whitespace-only executor.supplierID", () => {
  const hookPlan = compileZhixuHookPlanWithManifest(baseZhixu);
  const mutated = resign({
    ...hookPlan,
    executorRoutes: {
      ...hookPlan.executorRoutes,
      "assign": {
        ...hookPlan.executorRoutes["assign"]!,
        executor: {
          ...hookPlan.executorRoutes["assign"]!.executor,
          supplierID: "   ",
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
        /is missing a non-empty executor\.supplierID/,
      );
      return true;
    },
  );
});

test("compile boundary mirrors _validateHook shape gates before producing artifacts", () => {
  const hookPlan = compileZhixuHookPlanWithManifest(baseZhixu);
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
    executorRoutes: {},
    dockRoutes: [],
    dockRoutesRoot: EMPTY_MERKLE_ROOT,
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
    compileZhixuHookPlanWithManifest(baseZhixu),
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
    compileZhixuHookPlan(baseZhixu, demoManifest),
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
    compileZhixuHookPlan(baseZhixu, demoManifest),
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
    compileZhixuHookPlan(zhixu, demoManifest),
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
    issuesOf((a) => a.executorRoutes[0]).includes(closureIssue("executorRoutes[0]")),
  );
  assert.ok(
    issuesOf((a) => a.selectorBindings[0]).includes(closureIssue("selectorBindings[0]")),
  );
  assert.ok(
    issuesOf((a) => a.signalCapabilities[0]).includes(closureIssue("signalCapabilities[0]")),
  );

  assert.deepEqual(
    validateOnchainHookPlanArtifact(rehashed(structuredClone(onchain))),
    [],
  );
});

test("rejects mint birth stages without their own static executor route", () => {
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
          name: "post",
          source: "buyer",
          receiveSignals: { PUBLISH: "buyer::post.seed" },
          sendSignals: [{ name: "posted" }, { name: "seed" }],
          executor: { supplierType: "organization", supplierID: "intake-exec" },
        },
        {
          name: "birth",
          source: "fulfiller",
          mint: "per-fact",
          receiveSignals: {
            BIRTH: "::ANCHOR(@buyer::post.posted)",
          },
          sendSignals: [{ name: "str" }, { name: "cmp" }, { name: "err" }],
          executor: { supplierType: "organization", supplierID: "fulfiller-exec" },
        },
        {
          name: "routing",
          source: "buyer",
          selectedStages: ["birth"],
          receiveSignals: { PLACE: "buyer::routing.seed" },
          sendSignals: [{ name: "picked" }, { name: "seed" }],
          executor: { supplierType: "organization", supplierID: "routing-org" },
        }],
    },
  };

  const ir = compileZhixuHookPlan(zhixu, demoManifest);
  const onchain = compileOnchainHookPlan(ir);
  const birthHook = onchain.compiledHooks.find(
    (hook) => hook.stageIdentifier === "birth",
  );
  assert.ok(birthHook, "birth hook missing from compiled plan");
  assert.equal(birthHook.orderTriggerKind, "mint");
  assert.ok(
    onchain.selectorBindings.some(
      (binding) => binding.targetStageIdentifier === "birth",
    ),
    "fixture must anchor the birth stage through selectedStages",
  );
  assert.deepEqual(validateOnchainHookPlanArtifact(onchain), []);

  const strippedIr = resign({
    ...ir,
    executorRoutes: Object.fromEntries(
      Object.entries(ir.executorRoutes).filter(
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
        /birth is a subscription\/birth stage \(mint order-trigger\) and requires its own static executor route/.test(
          issue,
        )
      ),
    "compile preflight must reject a mint birth stage without its own executor route",
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
    executorRoutes: onchain.executorRoutes.filter(
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
      /birth is a subscription\/birth stage \(mint order-trigger\) and requires its own static executor route/.test(
        issue,
      )
    ),
    "artifact boundary must reject a mint birth stage without its own executor route",
  );
});
test("duplicate birth-channel key is rejected at compile and deserialization boundaries (U2 mirror)", () => {
  const sourcePlan = compileZhixuHookPlan(baseZhixu, demoManifest);
  const startHook = sourcePlan.compiledHooks.find(
    (hook) => hook.hookName === "START",
  );
  const placeHook = sourcePlan.compiledHooks.find(
    (hook) => hook.hookName === "PLACE",
  );
  assert.ok(startHook && placeHook, "demo IR must expose START and PLACE hooks");
  const sharedSignalName = startHook.dependencies[0]!.signalName;
  const sharedSource = startHook.dependencies[0]!.source;
  const mutatedHooks = sourcePlan.compiledHooks.map((hook) => {
    if (hook !== startHook && hook !== placeHook) {
      return hook;
    }
    if (hook === placeHook) {
      return {
        ...hook,
        orderTriggerKind: "dock" as const,
        emitReady: true,
        ast: {
          ...hook.ast,
          condition: {
            kind: "signal" as const,
            source: sharedSource,
            signalName: sharedSignalName,
          },
        },
        dependencies: [
          { ...hook.dependencies[0]!, source: sharedSource, signalName: sharedSignalName },
        ],
      };
    }
    return { ...hook, orderTriggerKind: "mint" as const, emitReady: true };
  });
  const resignd = resign({
    ...sourcePlan,
    compiledHooks: mutatedHooks,
    dependencyIndex: rebuildDependencyIndex(mutatedHooks),
  });
  assert.throws(
    () => compileOnchainHookPlan(resignd),
    (error: unknown) =>
      error instanceof HookPlanCompilationError &&
      error.issues.some((issue) => /duplicate birth-channel key/.test(issue)),
    "compile preflight must reject two order-trigger hooks sharing a birth key",
  );

  const onchain = compileOnchainHookPlan(sourcePlan);
  const stageA = "0x" + "01".repeat(32);
  const stageB = "0x" + "02".repeat(32);
  const sharedKey = onchainSignalKey(
    onchainSourceId("buyer"),
    onchainSignalId("buyer::shared.birth"),
  );
  const dep = {
    kind: "positive",
    source: "buyer",
    signalName: "buyer::shared.birth",
    sourceId: onchainSourceId("buyer"),
    signalId: onchainSignalId("buyer::shared.birth"),
    signalKey: sharedKey,
  };
  const instructionOf = () => [
    {
      op: "SIGNAL",
      source: "buyer",
      signalName: "buyer::shared.birth",
      sourceId: dep.sourceId,
      signalId: dep.signalId,
      signalKey: sharedKey,
    },
  ];
  const hookOf = (
    name: string,
    stageIdentifier: string,
    stageId: string,
    orderTriggerKind: "mint" | "dock" | "none",
  ) => ({
    hookId: keccak256Hex(`${stageIdentifier}#${name}`),
    stageId,
    stageIdentifier,
    hookName: name,
    kind: "receive",
    orderTriggerKind,
    emitReady: orderTriggerKind !== "none",
    instructions: instructionOf(),
    dependencies: [dep],
  });
  const birthHooks = [
    hookOf("mint_line", "a", stageA, "mint"),
    hookOf("dock_line", "b", stageB, "dock"),
    hookOf("watcher", "a", stageA, "none"),
  ];
  const issues = validateOnchainHookPlanArtifact({
    ...onchain,
    compiledHooks: birthHooks,
    dependencyIndex: { [sharedKey]: birthHooks.map((hook) => hook.hookId) },
  });
  assert.equal(
    issues.filter((issue) => /duplicate birth-channel key/.test(issue)).length,
    1,
    `expected exactly one birth-channel issue, got: ${issues.join("; ")}`,
  );

  const fanOutHooks = [
    hookOf("mint_line", "a", stageA, "mint"),
    hookOf("mint_line_2", "b", stageB, "mint"),
  ];
  const fanOutIssues = validateOnchainHookPlanArtifact({
    ...onchain,
    compiledHooks: fanOutHooks,
    dependencyIndex: { [sharedKey]: fanOutHooks.map((hook) => hook.hookId) },
  });
  assert.deepEqual(
    fanOutIssues.filter((issue) => /duplicate birth-channel key/.test(issue)),
    [],
  );
});

test("hook dependencies must mirror the SIGNAL atom key set (contract mirror)", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));
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
    compileZhixuHookPlan(baseZhixu, demoManifest),
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
      demoManifest,
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

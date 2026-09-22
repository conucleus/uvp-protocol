import assert from "node:assert/strict";
import {
  dockDemoResolutionManifest,
  dockDemoTargetName,
  dockProductionTargetDefinition,
} from "./dock-demo.js";
import {
  EMPTY_MERKLE_ROOT,
  verifyMerkleProof,
  dockCandidateLeaf,
  dockRouteId,
  merkleRoot,
  routeHash,
  stageKey,
} from "../src/dock.js";
import test from "node:test";
import {
  encodeAbiParameters,
  keccak256,
  parseAbiParameters,
  stringToHex,
} from "viem";
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
  type SolidityRegisterPlanArgs,
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

const demoManifest = dockDemoResolutionManifest();

/** 变异 hook plan 制品后按载荷重签 planHash（承诺重算由专门的篡改测试覆盖）。 */
function resign<A extends { planHash: string }>(artifact: A): A {
  return {
    ...artifact,
    planHash: hookPlanHashOf(artifact as unknown as HookPlanArtifact),
  };
}

/** 深克隆 AST 并把所有 delay 节点的 durationSeconds 改写为给定秒数。 */
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

/** 从 hook 列表按 IR 口径（source::signalName 键）重建 dependencyIndex。 */
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
    taskPatterns: [
      {
        name: "selector",
        stages: [
          {
            name: "assign",
            source: "buyer",
            selectedStages: ["execution.main"],
            // PLACE 为自发种子入口钩子（uvp-core 阶段物化门：零 hook
            // 阶段在链上永不可物化、sendSignals 无钩子可挂）。
            receiveSignals: {
              PLACE: "buyer::selector.assign.seed",
            },
            sendSignals: ["executor_selected", "seed"],
            executor: {
              supplierType: "organization",
              supplierID: "selector-org",
            },
          },
        ],
      },
      {
        name: "execution",
        stages: [
          {
            name: "main",
            source: "buyer",
            receiveSignals: {
              START: "buyer::selector.assign.executor_selected",
              TIMEOUT:
                "buyer::(selector.assign.executor_selected +5s) & ~execution.main.cmp",
            },
            sendSignals: ["str", "cmp", "err"],
            executor: {
              supplierType: "zhixu",
              // mode=new 恰好一条 input 绑定（出生锚）；TIMEOUT 是本地
              // receiveSignals 通道但不参与 inputMap。
              zhixuExecutorConfig: {
                target: { zhixu: dockDemoTargetName },
                interface: "production_service",
                order: { mode: "new" },
                inputMap: { START: "execute" },
                signalMap: { str: "started", cmp: "completed" },
              },
            },
          },
        ],
      },
    ],
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
  // 父定义 target.zhixu 携带目标 name 引用（DSL 壳不携带派生身份），
  // sourcePlanHash/planHash preimage 随定义内容变化；承诺公式本身冻结不变。
  assert.equal(
    onchain.planHash,
    "0x36369c30724fafbd88a1796ba9b3a7b6355eaf5379789753b619064185cc120f",
  );
  // capabilitiesRoot 是两表叶子的唯一承诺形态（v3 新增字段，随 planHash
  // 一同钉死防漂移）：与生产公式 capabilitiesRootOf 逐字节一致。
  assert.equal(
    onchain.capabilitiesRoot,
    "0x4b7926cdf597ce56cca5dc87d9c39270ef9fb95ebb59a81c3b6afb078c4357dd",
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
      selectorStageIdentifier: "selector.assign",
      targetStageIdentifier: "execution.main",
      selectorStageId: keccak256Hex("selector.assign"),
      targetStageId: keccak256Hex("execution.main"),
      bindingHash: onchainSelectorBindingHash(
        keccak256Hex("selector.assign"),
        keccak256Hex("execution.main"),
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
      ["execution.main", "buyer", "execution.main.cmp", "current"],
      ["execution.main", "buyer", "execution.main.err", "current"],
      ["execution.main", "buyer", "execution.main.str", "current"],
      [
        "selector.assign",
        "buyer",
        "selector.assign.executor_selected",
        "current",
      ],
      ["selector.assign", "buyer", "selector.assign.seed", "current"],
    ],
  );
  assert.deepEqual(
    onchain.compiledHooks.map((hook) => hook.hookId),
    [
      "0x07fec9e5326c8025bd807a2d26a55476168f38f6b9b1d3ef3af9df18f758da96",
      "0x2a799fd6d3c55a26d5b940bc8fedc135a5feae293bce3e0c6cd375c4a946fc89",
      "0x9ca6abf270eaace38c6f86f21c09e9fa9a81346c198a54de2b4927ebf82e5f52",
    ],
  );
  assert.equal(
    onchain.compiledHooks[0]?.hookId,
    keccak256Hex("execution.main#START"),
  );
  assert.equal(
    onchain.compiledHooks[0]?.stageId,
    keccak256Hex("execution.main"),
  );

  const startSignal = onchain.compiledHooks[0]
    ?.instructions[0] as OnchainSignalInstruction;
  assert.equal(startSignal.sourceId, keccak256Hex("buyer"));
  assert.equal(
    startSignal.signalId,
    keccak256Hex("selector.assign.executor_selected"),
  );
  assert.equal(
    startSignal.signalKey,
    "0xcf7c8f26d55e2223a316d1220b6f7c902d1654622e82b458a98871bdf4c4e433",
  );

  assert.deepEqual(validateOnchainHookPlanArtifact(onchain), []);
  assert.doesNotThrow(() => assertOnchainHookPlanArtifact(onchain));
});

test("serializes trigger-origin signal capabilities to Solidity relation 1", () => {
  const onchain = compileZhixuOnchainHookPlanWithManifest({
    ...baseZhixu,
    metadata: {
      name: "trigger_origin_signal_demo",
    },
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        {
          name: "settlement",
          stages: [
            {
              name: "close",
              source: "trade",
              receiveSignals: {
                START: "trade::settlement.close.start",
              },
              sendSignals: ["start", "book::book.settlement_wait.cmp"],
              executor: {
                supplierType: "organization",
                supplierID: "settlement-operator",
              },
            },
          ],
        },
      ],
    },
  });
  const args = toSolidityRegisterPlanArgs(onchain);

  const triggerOriginCapabilities = onchain.signalCapabilities.filter(
    (capability) => capability.targetOrderRelation === "triggerOrigin",
  );
  assert.deepEqual(
    triggerOriginCapabilities.map((capability) => [
      capability.targetSource,
      capability.targetSignalName,
      capability.targetOrderRelation,
    ]),
    [["book", "book.settlement_wait.cmp", "triggerOrigin"]],
  );
  assert.deepEqual(
    args.signalCapabilities
      .filter((capability) => capability.targetOrderRelation === 1)
      .map((capability) => capability.targetOrderRelation),
    [1],
  );
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
      signalName: "selector.assign.executor_selected",
      sourceId:
        "0x9c1bfc34ea7e295ac684c026c6d4de765734cb6b37fa07330bcfc241743ebbaf",
      signalId:
        "0xa0756ea7615d348df1d40db5b1f47a5dbf14775409e8340b067202afb9c95bab",
      signalKey:
        "0xcf7c8f26d55e2223a316d1220b6f7c902d1654622e82b458a98871bdf4c4e433",
    },
    {
      op: "DELAY",
      delaySeconds: 5,
    },
    {
      op: "SIGNAL",
      source: "buyer",
      signalName: "execution.main.cmp",
      sourceId:
        "0x9c1bfc34ea7e295ac684c026c6d4de765734cb6b37fa07330bcfc241743ebbaf",
      signalId:
        "0x7aac3bcb090fc9f71f030794082ffa827a686948f2bef40b5452cd121a82eee7",
      signalKey:
        "0x1845455a34645910fcbc7220c18dcb6661ad3f045893d3694d22a99a1a5dcc11",
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
      taskPatterns: baseZhixu.spec.taskPatterns.map((task) =>
        task.name !== "execution"
          ? task
          : {
              ...task,
              stages: task.stages.map((stage) => ({
                ...stage,
                receiveSignals: {
                  ...stage.receiveSignals,
                  ALT: "buyer::execution.main.str | execution.main.err",
                },
              })),
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
    "0x1845455a34645910fcbc7220c18dcb6661ad3f045893d3694d22a99a1a5dcc11": [
      "0x2a799fd6d3c55a26d5b940bc8fedc135a5feae293bce3e0c6cd375c4a946fc89",
    ],
    // 种子入口钩子的自引用依赖（buyer::selector.assign.seed → PLACE）。
    "0x92101349c0a8769bf471123524c5e6130565d09bb781684372b1c5d07fbe1081": [
      "0x9ca6abf270eaace38c6f86f21c09e9fa9a81346c198a54de2b4927ebf82e5f52",
    ],
    "0xcf7c8f26d55e2223a316d1220b6f7c902d1654622e82b458a98871bdf4c4e433": [
      "0x07fec9e5326c8025bd807a2d26a55476168f38f6b9b1d3ef3af9df18f758da96",
      "0x2a799fd6d3c55a26d5b940bc8fedc135a5feae293bce3e0c6cd375c4a946fc89",
    ],
  });

  assert.deepEqual(
    onchain.executorRoutes.map((route) => route.routeId),
    ["0x50a98fb0b72e21bff21f57c8269a01953f1400a33ee2a92483825ea897feb09a"],
  );
  // zhixu 委托 stage 不挂静态 executor route（routeRef 只属于静态执行者）。
  assert.equal(
    onchain.compiledHooks.find((hook) => hook.hookName === "START")?.routeRef,
    undefined,
  );
});

test("dependencyIndex hookIds follow calldata order, not keccak order (oracle pairing)", () => {
  // 同键双 hook：合约 _registerPlanHook 按 commitPlan calldata（=
  // compiledHooks 的 stage/hookName 序）逐个 push hookId，回放 oracle 按
  // 数组序逐位配对。本 fixture 里 keccak 序（0x2cb2… SECOND < 0xe460…
  // FIRST）与名字序（FIRST < SECOND）分叉——artifact 每键 hookIds 必须按
  // calldata 序生成，按 hookId 排序会让同键同阶段双 hook 同轮就绪时以
  // ~50% 概率产生假 mismatch。
  const zhixu: ZhixuDefinition = {
    ...baseZhixu,
    metadata: {
      name: "shared_key_order_demo",
    },
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        {
          name: "watch",
          stages: [
            {
              name: "stage",
              source: "buyer",
              receiveSignals: {
                FIRST: "buyer::watch.stage.seed",
                SECOND: "buyer::watch.stage.seed",
              },
              sendSignals: ["seed"],
              executor: {
                supplierType: "organization",
                supplierID: "watcher-org",
              },
            },
          ],
        },
      ],
    },
  };
  const onchain = compileZhixuOnchainHookPlanWithManifest(zhixu);
  const seedKey = onchainSignalKey(
    onchainSourceId("buyer"),
    onchainSignalId("watch.stage.seed"),
  );
  const calldataOrder = onchain.compiledHooks.map((hook) => hook.hookId);
  assert.deepEqual(
    onchain.compiledHooks.map((hook) => hook.hookName),
    ["FIRST", "SECOND"],
  );
  // 前置守卫：本 fixture 的 keccak 序确实与 calldata 序不同（否则测试退化）。
  assert.notDeepEqual([...calldataOrder].sort(), calldataOrder);
  assert.deepEqual(onchain.dependencyIndex[seedKey], calldataOrder);

  // Solidity 参数与 artifact 逐位一致：commitPlan calldata 与
  // dependencyIndex 由同一顺序喂入。
  const args = toSolidityRegisterPlanArgs(onchain);
  assert.deepEqual(
    args.dependencyIndex.find((entry) => entry.signalKey === seedKey)?.hookIds,
    calldataOrder,
  );

  // keccak 序的 dependencyIndex 在反序列化边界必须被拒绝。
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

  // 篡改 root 后重签 planHash：planHash 承诺对拍照常通过，而登记边界
  // （toSolidityRegisterPlanArgs）按两表重算并覆盖 root——带着错误 root
  // 的制品必须在 artifact 边界被拒绝，不得静默改写成重算值。
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

  // 对照组：原样制品两表与 root 一致，登记照常取制品 root（与重算值
  // 逐字节一致，无覆盖分歧）。
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
  // 真比较：artifactHash 用 artifact 载荷公式独立重算，planHash 用 PlanCommit
  // runtime 公式独立重算——两边各自从原始字段推导，不再是同源引用恒等。
  const { planHash: _storedPlanHash, ...artifactPayload } = onchain;
  assert.equal(args.artifactHash, hashOnchainPlanPayload(artifactPayload));
  assert.equal(
    args.planHash,
    keccak256(
      encodeAbiParameters(
        parseAbiParameters(
          "bytes32 domain, bytes32 hooksHash, bytes32 capabilitiesRoot, bytes32 dockRoutesRoot, bytes32 dockInterfaceRoot",
        ),
        [
          keccak256(stringToHex("uvp.plan.runtime.v3")),
          args.hooksHash,
          args.capabilitiesRoot,
          args.dockRoutesRoot,
          args.dockInterfaceRoot,
        ],
      ),
    ),
  );
  assert.notEqual(args.planHash, args.artifactHash);
  assert.equal(args.hooksHash, hashSolidityRegisterHooks(args.hooks));
  assert.match(args.hooksHash, /^0x[0-9a-f]{64}$/);
  assert.match(args.capabilitiesRoot, /^0x[0-9a-f]{64}$/);
  assert.equal(args.hooks[1]?.hookName, keccak256Hex("TIMEOUT"));
  assert.deepEqual(
    args.hooks[1]?.instructions.map((instruction) => instruction.op),
    ["SIGNAL", "DELAY", "SIGNAL", "NOT", "AND"],
  );
  assert.deepEqual(args.hooks[1]?.dependencyKeys, [
    "0x1845455a34645910fcbc7220c18dcb6661ad3f045893d3694d22a99a1a5dcc11",
    "0xcf7c8f26d55e2223a316d1220b6f7c902d1654622e82b458a98871bdf4c4e433",
  ]);
  assert.equal(args.dependencyIndex.length, 3);
  // zhixu 委托 stage 不产生静态 executor route：executorRoutes 只含
  // 静态执行者（selector-org），不含目标 Zhixu 身份。
  assert.deepEqual(
    args.executorRoutes.map((route) => route.executorId),
    ["selector-org"],
  );
  assert.match(args.dockRoutesRoot, /^0x[0-9a-f]{64}$/);
  assert.notEqual(args.dockRoutesRoot, EMPTY_MERKLE_ROOT);
  assert.deepEqual(args.selectorBindings, [
    {
      selectorStageId: keccak256Hex("selector.assign"),
      targetStageId: keccak256Hex("execution.main"),
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
      taskPatterns: baseZhixu.spec.taskPatterns.map((task) =>
        task.name !== "selector"
          ? task
          : {
              ...task,
              stages: task.stages.map((stage) => ({
                ...stage,
                selectedStages: [],
              })),
            },
      ),
    },
  };
  const withoutBinding = compileOnchainHookPlan(
    compileZhixuHookPlan(withoutSelectedStages, demoManifest),
  );

  assert.deepEqual(withoutBinding.selectorBindings, []);
  assert.notEqual(withBinding.planHash, withoutBinding.planHash);
});

test("capability tables feed the capabilitiesRoot and the runtime plan hash", () => {
  // PlanCommit runtime hash 以 capabilitiesRoot 承诺两表（域分隔叶混编
  // Merkle 树）——selectorBindings 变化必须穿透 args.capabilitiesRoot 与
  // runtime planHash，否则 finalize 边的承诺对拍必然失配。
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
            taskPatterns: baseZhixu.spec.taskPatterns.map((task) =>
              task.name !== "selector"
                ? task
                : {
                    ...task,
                    stages: task.stages.map((stage) => ({
                      ...stage,
                      selectedStages: [],
                    })),
                  },
            ),
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
  // 生产公式独立重算：根 = 两表全部域分隔叶的排序配对 Merkle 根（叶子
  // 公式逐字节对齐 UVPPlanMetadataModule），成员资格由 proof 验证。
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
  // 能力侧叶子同样混编进同一棵树（relation=0 深叶抽验）。
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
  // 根随表内容变化：同一张能力表换一个绑定叶子，根必须不同。
  assert.notEqual(
    withBinding.capabilitiesRoot,
    capabilitiesRootOf(
      withoutBinding.selectorBindings,
      withBinding.signalCapabilities,
    ),
  );
});

test("hooksHash frozen vector pins the zero-word instruction fill cross-language", () => {
  // 与 UVPStateMachine.t.sol 的同名冻结向量逐字节一致：非 SIGNAL 指令的
  // sourceId/signalId 填 Solidity 零字，arity/delaySeconds 未用位填 0。
  // 任何一方（TS compiler / uvp-deploy 驱动 / Rust）在填充位引入别的字
  // 节（例如 keccak256("")）都会让含 NOT/AND/OR/DELAY 的计划在 commitPlan
  // 处 HooksHashMismatch 必然 revert。
  const hooks = [
    {
      hookId: "0x0000000000000000000000000000000000000000000000000000000000001001",
      stageId: "0x0000000000000000000000000000000000000000000000000000000000002001",
      hookName: "0x0000000000000000000000000000000000000000000000000000000000003001",
      kind: "receive",
      flags: 5,
      instructions: [
        {
          op: "SIGNAL",
          sourceId: "0x0000000000000000000000000000000000000000000000000000000000004001",
          signalId: "0x0000000000000000000000000000000000000000000000000000000000005001",
          signalKey: "0x0000000000000000000000000000000000000000000000000000000000006001",
        },
        { op: "NOT" },
        { op: "DELAY", delaySeconds: 30 },
      ],
      dependencyKeys: [
        "0x0000000000000000000000000000000000000000000000000000000000006001",
      ],
    },
    {
      hookId: "0x0000000000000000000000000000000000000000000000000000000000001002",
      stageId: "0x0000000000000000000000000000000000000000000000000000000000002002",
      hookName: "0x0000000000000000000000000000000000000000000000000000000000003002",
      kind: "receive",
      flags: 0,
      instructions: [
        {
          op: "SIGNAL",
          sourceId: "0x0000000000000000000000000000000000000000000000000000000000004002",
          signalId: "0x0000000000000000000000000000000000000000000000000000000000005002",
          signalKey: "0x0000000000000000000000000000000000000000000000000000000000006002",
        },
        {
          op: "SIGNAL",
          sourceId: "0x0000000000000000000000000000000000000000000000000000000000004001",
          signalId: "0x0000000000000000000000000000000000000000000000000000000000005001",
          signalKey: "0x0000000000000000000000000000000000000000000000000000000000006001",
        },
        { op: "AND", arity: 2 },
        { op: "OR", arity: 2 },
      ],
      dependencyKeys: [
        "0x0000000000000000000000000000000000000000000000000000000000006002",
        "0x0000000000000000000000000000000000000000000000000000000000006001",
      ],
    },
  ];

  assert.equal(
    hashSolidityRegisterHooks(hooks as SolidityRegisterPlanArgs["hooks"]),
    "0xe71cb5f3a4e16b4498c9d0ccd126cfcc63b6275039635cb94190bf5dcec486df",
  );
});

test("cross-stage dependency guard fires on deserialized artifacts and follows contract order", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));

  // (1) 反序列化边界（0300 M-7）：守卫读 orderTriggerKind 派生 trigger 位。
  // 把一个 watcher 挪到外阶段（保持 hookId/stageId 自洽）后，共享键上的
  // 跨阶段非 trigger watcher 必须在 validateOnchainHookPlanArtifact 报错。
  const sharedKey = onchain.compiledHooks.find((hook) => hook.orderTriggerKind === "none")
    ?.dependencies[0]?.signalKey;
  assert.ok(sharedKey, "base artifact must expose a watcher dependency");
  const watchesSharedKey = (hook: (typeof onchain.compiledHooks)[number]) =>
    hook.orderTriggerKind === "none" &&
    hook.dependencies.some((dependency) => dependency.signalKey === sharedKey);
  const watcherIndex = onchain.compiledHooks.findIndex(watchesSharedKey);
  const laterWatcherIndex = onchain.compiledHooks.findIndex(
    (hook, index) => index > watcherIndex && watchesSharedKey(hook),
  );
  // 基线工件里共享键上至少要有两个 watcher（不同 hook），后者保持原阶段——
  // 否则"挪走一个、留下一个"的跨阶段形态不成立。
  assert.ok(watcherIndex >= 0 && laterWatcherIndex > watcherIndex, "need two shared-key watchers");
  const foreignStageIdentifier = "foreign.stage";
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

  // (2) 逐 hook 顺序语义：trigger(A) → trigger(B) → watcher(A)
  // 共享一键时合约接受（seenStages 只记首个 watcher 的阶段，且 trigger 位
  // AND 累积仍为真；watcher 回到首阶段不触发 CrossStageDependency）——
  // 集合判定会误杀该形态，顺序仿真必须放行。
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
      hookOf("t1", "stage.a", stageA, "mint"),
      hookOf("t2", "stage.b", stageB, "mint"),
      hookOf("w1", "stage.a", stageA, "none"),
    ],
    rejected: [
      hookOf("w1", "stage.a", stageA, "none"),
      hookOf("t1", "stage.b", stageB, "mint"),
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

  // (3) 顺序反过来（watcher(A) → trigger(B)）则合约拒绝——首个 watcher 非
  // trigger，跨阶段 trigger 也过不去。
  const rejectedIssues = validateOnchainHookPlanArtifact(sequentialArtifact(sequentialHookLists.rejected)).filter(
    (issue) => /is shared across stages/.test(issue),
  );
  assert.equal(rejectedIssues.length, 1);
});

test("compiles capability tables beyond gas caps into a verifiable capabilitiesRoot", () => {
  // 两表无 256/128 规模上限（链上只承诺 root，finalize 与表规模脱钩）：
  // 400 绑定 + 400 能力必须可编译出根，且深叶成员资格可由 proof 验证。
  // stageId/sourceId 直接按 32 字节词构造（假身份）：本测试的对象是承诺
  // 公式本身，不经过 DSL 编译（IR 层仍有 Rust 侧规模闸）。
  const tableBindings = Array.from({ length: 400 }, (_, index) => ({
    selectorStageId: keccak256Hex(`capability.selector-${index}`),
    targetStageId: keccak256Hex(`capability.target-${index}`),
  }));
  const tableCapabilities = Array.from({ length: 400 }, (_, index) => ({
    stageId: keccak256Hex(`capability.stage-${index}`),
    targetSourceId: keccak256Hex(`capability.source-${index}`),
    signalId: keccak256Hex(`task.stage.signal-${index}`),
    targetOrderRelation: (index % 2 === 0 ? 0 : 1) as 0 | 1,
  }));
  const root = capabilitiesRootOf(tableBindings, tableCapabilities);
  assert.notEqual(root, EMPTY_MERKLE_ROOT);
  assert.match(root, /^0x[0-9a-f]{64}$/);

  // 深叶抽验：800 叶的树深度为 10，取中部能力叶与首尾绑定叶验证
  // signalCapabilityProof / selectorBindingProof + verifyMerkleProof。
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
  // 反例：同一词序换个 relation 词（0→1）即另一片叶子，原 proof 不得通过。
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

  // 编译边界同口径：制品的能力表扩到 400 条（假 sourceId/信号名）后按载荷
  // 重签 planHash，artifact 边界不再有规模拒绝（旧 256 上限的镜像已删），
  // toSolidityRegisterPlanArgs 对 400 条能力照常编译出同一根。
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));
  const template = onchain.signalCapabilities[0];
  assert.ok(template);
  const expanded = Array.from({ length: 400 }, (_, index) => {
    const targetSource = `bulk-source-${index}`;
    const targetSignalName = `execution.main.bulk-${index}`;
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
    targetOrderRelation: capability.targetOrderRelation === "current" ? (0 as const) : (1 as const),
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
  // 同一事实键 (targetSourceId, signalId) 挂到两个阶段、relation=current：
  // 属主不再唯一，携证解析（事实键 → 属主阶段）出现二义性——编译期预检
  // 必须拒绝，不让歧义属主进承诺。
  const fact = sourcePlan.signalCapabilities[0]!;
  const otherStage =
    sourcePlan.signalCapabilities.find(
      (capability) => capability.stageIdentifier !== fact.stageIdentifier,
    )?.stageIdentifier ?? "zz.other";
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
  // 反例：同一阶段重复声明同一事实键合法（属主未变），且 relation≠0 的
  // 事实键不受 E16 约束。
  assert.doesNotThrow(() =>
    compileOnchainHookPlan(
      resign({
        ...sourcePlan,
        signalCapabilities: sourcePlan.signalCapabilities.map((capability) =>
          capability === fact
            ? { ...capability, targetOrderRelation: "triggerOrigin" as const }
            : capability,
        ),
      }),
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
        // 重签 planHash：让拦截者聚焦在 selector binding 查重本身
        // （篡改不重签的形态由 hook-plan 边界的承诺重算测试覆盖）。
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
});

test("collects dock commitment shape violations as issues instead of throwing or pinning defaults", () => {
  // 0348 发现1+发现3 / 0524 C12：dock 字段缺失/畸形不得 fail-open——
  // 既不能落进 planHash 重算的 ?? 兜底（缺失被钉成 []/null 后照常通过），
  // 也不能让 canonicalize 抛未类型化 TypeError（破坏"返回 issues"契约）。
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));

  const strip = (field: string): Record<string, unknown> => {
    const { [field]: _removed, ...rest } = {
      ...onchain,
    } as Record<string, unknown>;
    return rest;
  };

  // dockRoutes 非数组 → 形状 issue，不抛异常。
  const badRoutesIssues = validateOnchainHookPlanArtifact({
    ...onchain,
    dockRoutes: { "0x50": [] },
  } as unknown as OnchainHookPlanArtifact);
  assert.ok(
    badRoutesIssues.includes("dockRoutes must be an array"),
    `expected dockRoutes shape issue, got: ${badRoutesIssues.join("; ")}`,
  );

  // dockRoutesRoot 缺失 → hex issue（而非重算路径的裸 TypeError）。
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

  // dockInterfaceRoot 非法 hex → hex issue。
  assert.ok(
    validateOnchainHookPlanArtifact({
      ...onchain,
      dockInterfaceRoot: "0xdeadbeef",
    }).includes("dockInterfaceRoot must be a lowercase 32-byte hex hash"),
  );

  // dockInterface 缺失 → 承诺校验报 issue，planHash 不重算。
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
    ["START", "::ANCHOR(@buyer::selector.assign.executor_selected)"]
  ] as const) {
    const zhixu: ZhixuDefinition = {
      ...baseZhixu,
      spec: {
        ...baseZhixu.spec,
        taskPatterns: baseZhixu.spec.taskPatterns.map((pattern) => ({
          ...pattern,
          stages: pattern.stages.map((stage) =>
            stage.name === "main"
              ? {
                  ...stage,
                  receiveSignals: { [hookName]: expression },
                  // 普通静态执行者：zhixu 委托 + 订阅会被 Rust 侧
                  // validate_subscription_delegation 先行拒绝，这里专门
                  // 验证 TS 侧"非出生订阅不上链"的类型化错误。
                  executor: {
                    supplierType: "organization",
                    supplierID: "execution-org"
                  }
                }
              : stage
          )
        }))
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
  // 出生订阅上链 = 提交事实本身即出生信号：编译为一条 SIGNAL 指令，
  // 带 order-trigger flag（triggerOrderFrom* 的硬门槛），提交者按
  // "现实成立后任意持有人签名提交"开放。
  const zhixu: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        ...baseZhixu.spec.taskPatterns,
        {
          // 出生订阅的信号必须只被出生钩子监视（链上守卫：非出生钩子在
          // 未物化阶段监视同一信号会让提交交易永久 revert）。
          name: "intake",
          stages: [
            {
              name: "post",
              source: "buyer",
              // PUBLISH 为自发种子入口钩子（uvp-core 阶段物化门：零
              // hook 阶段在链上永不可物化、sendSignals 无钩子可挂）。
              receiveSignals: {
                PUBLISH: "buyer::intake.post.seed",
              },
              sendSignals: ["posted", "seed"],
              executor: {
                supplierType: "organization",
                supplierID: "intake-exec",
              },
            },
          ],
        },
        {
          name: "fulfillment",
          stages: [
            {
              name: "birth",
              source: "fulfiller",
              mint: "per-fact",
              receiveSignals: {
                BIRTH: "::ANCHOR(@buyer::intake.post.posted)",
              },
              sendSignals: ["str", "cmp", "err"],
              executor: {
                supplierType: "organization",
                supplierID: "fulfiller-exec",
              },
            },
          ],
        },
      ],
    },
  };

  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(zhixu, demoManifest));
  const hook = onchain.compiledHooks.find((item) => item.hookName === "BIRTH");
  assert.ok(hook, "birth hook missing from compiled plan");
  assert.equal(hook.orderTriggerKind, "mint");
  assert.equal(hook.emitReady, true);
  assert.equal(hook.instructions.length, 1);
  // 出生订阅编译为一条 SIGNAL 指令：提交的 (sourceId, signalId) 即出生事实。
  const birth = hook.instructions[0] as OnchainSignalInstruction;
  assert.equal(birth.op, "SIGNAL");
  assert.equal(birth.sourceId, onchainSourceId("buyer"));
  assert.equal(birth.signalId, onchainSignalId("intake.post.posted"));
});

test("rejects empty instructions the way the contract reverts InvalidHook", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));
  // 正例：现状（每条 hook 至少一条指令）仍全量通过预检。
  assert.deepEqual(validateOnchainHookPlanArtifact(onchain), []);

  // 反例：instructions 为空在链上等价于 hook.instructions.length == 0 的
  // InvalidHook revert，预检必须同样拒绝（而不是被 length > 0 前置条件吞掉）。
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
  // 正例：带依赖的 hook 仍通过预检与 Solidity 参数转换。
  assert.doesNotThrow(() => toSolidityRegisterPlanArgs(onchain));

  const withEmptyDependencies = {
    ...onchain,
    compiledHooks: [
      { ...onchain.compiledHooks[0]!, dependencies: [] },
      ...onchain.compiledHooks.slice(1),
    ],
  };
  // 反例：dependencyKeys 为空在链上等价于 hook.dependencyKeys.length == 0
  // 的 InvalidHook revert；制品校验与 Solidity 参数转换都要拒绝。
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

  // 反例：> 30 天在链上触发 HookDelayTooLong，预检必须先行拒绝。
  assert.match(
    validateOnchainHookPlanArtifact(withDelay(2_592_001)).join("; "),
    /delaySeconds must not exceed 2592000.*HookDelayTooLong/,
  );

  // 正例：恰好 30 天（MAX_HOOK_DELAY_SECONDS）仍是合法制品。
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
      taskPatterns: baseZhixu.spec.taskPatterns.map((pattern) => ({
        ...pattern,
        stages: pattern.stages.map((stage) =>
          stage.name === "assign"
            ? {
                ...stage,
                receiveSignals: {
                  ECHO: "buyer::selector.assign.executor_selected"
                }
              }
            : stage
        )
      }))
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

  // 正例 1（mint trigger 形态）：出生订阅编译为 orderTriggerKind=mint、
  // emitReady=true 的 hook——阶段可物化，零 issue（口径对照 Rust
  // validate_onchain_stage_materialization：有出生边的阶段不受限）。
  const mintZhixu: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        ...baseZhixu.spec.taskPatterns,
        {
          name: "intake",
          stages: [
            {
              name: "post",
              source: "buyer",
              // PUBLISH 为自发种子入口钩子（uvp-core 阶段物化门：零
              // hook 阶段在链上永不可物化、sendSignals 无钩子可挂）。
              receiveSignals: {
                PUBLISH: "buyer::intake.post.seed",
              },
              sendSignals: ["posted", "seed"],
              executor: {
                supplierType: "organization",
                supplierID: "intake-exec",
              },
            },
          ],
        },
        {
          name: "fulfillment",
          stages: [
            {
              name: "birth",
              source: "fulfiller",
              mint: "per-fact",
              receiveSignals: {
                BIRTH: "::ANCHOR(@buyer::intake.post.posted)",
              },
              sendSignals: ["str", "cmp", "err"],
              executor: {
                supplierType: "organization",
                supplierID: "fulfiller-exec",
              },
            },
          ],
        },
      ],
    },
  };
  const mintOnchain = compileOnchainHookPlan(
    compileZhixuHookPlan(mintZhixu, demoManifest),
  );
  assert.deepEqual(materializationIssues(validateOnchainHookPlanArtifact(mintOnchain)), []);

  // 正例 2（EMIT_READY receive hook 形态）：有静态 executor 的阶段其
  // receive hook 恒 emitReady=true（executor dispatch 边），同样可物化。
  const baseOnchain = compileOnchainHookPlan(
    compileZhixuHookPlan(baseZhixu, demoManifest),
  );
  assert.deepEqual(materializationIssues(validateOnchainHookPlanArtifact(baseOnchain)), []);

  // 正例 3（dock trigger 形态）：dock 出生边 orderTriggerKind=dock 同样
  // 是合法物化者。
  const dockOnchain: OnchainHookPlanArtifact = {
    ...baseOnchain,
    compiledHooks: baseOnchain.compiledHooks.map((hook) =>
      hook.stageIdentifier === "execution.main"
        ? { ...hook, orderTriggerKind: "dock" as const }
        : hook,
    ),
  };
  assert.deepEqual(materializationIssues(validateOnchainHookPlanArtifact(dockOnchain)), []);

  // 反例（纯 receive hook 形态）：把 execution.main 的全部 hook 压成
  // orderTriggerKind=none、emitReady=false 的 flags=0 纯 watcher——该阶段
  // 永不可物化，正是 Rust validate_onchain_stage_materialization 在定义层
  // 拒绝的形态；artifact 边界（第二道门）必须同样拒绝。
  const watcherOnly: OnchainHookPlanArtifact = {
    ...baseOnchain,
    compiledHooks: baseOnchain.compiledHooks.map((hook) =>
      hook.stageIdentifier === "execution.main"
        ? { ...hook, orderTriggerKind: "none" as const, emitReady: false }
        : hook,
    ),
  };
  const watcherIssues = materializationIssues(
    validateOnchainHookPlanArtifact(watcherOnly),
  );
  // 阶段内每条 hook 各报一条（START/TIMEOUT 两条），其余校验零噪声。
  assert.equal(watcherIssues.length, 2);
  for (const issue of watcherIssues) {
    assert.match(
      issue,
      /^stage execution\.main has no order-trigger or EMIT_READY hook; its hooks compile to flags=0 watchers which can never materialize the stage on-chain \(deadlock, no recovery path\) — the Rust compiler must reject this shape$/,
    );
  }

  // 编译入口同口径：该形态在 compileOnchainHookPlan 预检即抛
  // HookPlanCompilationError，不产出制品。（变异后重签 planHash，让拦截
  // 者聚焦在物化门本身。）
  const watcherSourcePlan = compileZhixuHookPlan(baseZhixu, demoManifest);
  const mutatedSourcePlan = {
    ...watcherSourcePlan,
    compiledHooks: watcherSourcePlan.compiledHooks.map((hook) =>
      hook.stageIdentifier === "execution.main"
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
        /stage execution\.main has no order-trigger or EMIT_READY hook/.test(issue),
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

  // 正例：带物化位的阶段放行——selector.assign 的种子入口钩子靠静态
  // executor 得到 emitReady=true（flags=4），全计划零物化 issue。
  const placeHook = onchain.compiledHooks.find(
    (hook) => hook.hookName === "PLACE",
  );
  assert.equal(placeHook?.stageIdentifier, "selector.assign");
  assert.equal(placeHook?.orderTriggerKind, "none");
  assert.equal(placeHook?.emitReady, true);
  assert.deepEqual(zeroHookIssues(validateOnchainHookPlanArtifact(onchain)), []);

  // 反例（编译入口）：把 selector.assign 的钩子全部剥掉，阶段仅剩
  // sendSignals/executor 声明投影——零 hook 阶段永不可物化、信号没有
  // 钩子可挂，compileOnchainHookPlan 预检即抛，不产出制品。
  // （dependencyIndex 同步剔除被剥钩子，让形状校验先行通过，确保
  // 拦截者就是物化门本身；能力表/绑定表对 selector.assign 的引用同步
  // 剥离——剥离后即悬空引用，会被 IR 校验的阶段存在性镜像先拒，
  // 抢在本测试要钉的物化门之前。）
  const strippedHookIds = new Set(
    sourcePlan.compiledHooks
      .filter((hook) => hook.stageIdentifier === "selector.assign")
      .map((hook) => hook.hookId),
  );
  const zeroHookSourcePlan = {
    ...sourcePlan,
    compiledHooks: sourcePlan.compiledHooks.filter(
      (hook) => hook.stageIdentifier !== "selector.assign",
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
      (binding) => binding.selectorStageIdentifier !== "selector.assign",
    ),
    signalCapabilities: sourcePlan.signalCapabilities.filter(
      (capability) => capability.stageIdentifier !== "selector.assign",
    ),
  };
  // 重签 planHash：让拦截者聚焦在物化门本身（承诺重算由 hook-plan 边界
  // 的专门测试覆盖）。
  const unsignedZeroHookPlan = {
    ...zeroHookSourcePlan,
    planHash: hookPlanHashOf(zeroHookSourcePlan),
  };
  assert.throws(
    () => compileOnchainHookPlan(unsignedZeroHookPlan),
    (error: unknown) =>
      error instanceof HookPlanCompilationError &&
      zeroHookIssues(error.issues).length === 1 &&
      /^stage selector\.assign declares no receiveSignals and compiles to zero hooks: the stage can never materialize on-chain \(materialization only happens via this stage's own order-trigger\/EMIT_READY hooks\) and its sendSignals have no hook to hang on — submitSignal requires the source stage to be materialized and reverts UnknownHook forever \(deadlock, no recovery path\); declare receiveSignals carrying a mint\/dock entrance or a static executor$/.test(
        zeroHookIssues(error.issues)[0] ?? "",
      ),
  );

  // 反例（反序列化边界）：同一守卫作用于 onchain artifact 校验边界。
  const zeroHookOnchain: OnchainHookPlanArtifact = {
    ...onchain,
    compiledHooks: onchain.compiledHooks.filter(
      (hook) => hook.stageIdentifier !== "selector.assign",
    ),
  };
  const boundaryIssues = zeroHookIssues(
    validateOnchainHookPlanArtifact(zeroHookOnchain),
  );
  assert.equal(boundaryIssues.length, 1);
  assert.match(
    boundaryIssues[0] ?? "",
    /^stage selector\.assign declares no receiveSignals and compiles to zero hooks/,
  );
});

test("dock entrance hooks materialize their stage (CORE-8 materialization gate)", () => {
  const materializationIssues = (issues: readonly string[]): readonly string[] =>
    issues.filter((issue) =>
      /no order-trigger or EMIT_READY hook|compiles to zero hooks/.test(issue),
    );

  // 真实 dockInterface input 端口：目标定义的 manufacturing.intake#EXECUTE
  // 编译为 dock|emitReady（flags=6）——Rust dock_entrance_hook_ids
  // 豁免的产物投影，artifact 层按编译后物化位放行，不按 watcher 误拒。
  const targetOnchain = compileZhixuOnchainHookPlan(
    dockProductionTargetDefinition(),
  );
  const entranceHook = targetOnchain.compiledHooks.find(
    (hook) => hook.stageIdentifier === "manufacturing.intake",
  );
  assert.equal(entranceHook?.hookName, "EXECUTE");
  assert.equal(entranceHook?.orderTriggerKind, "dock");
  assert.equal(entranceHook?.emitReady, true);
  assert.deepEqual(
    materializationIssues(validateOnchainHookPlanArtifact(targetOnchain)),
    [],
  );
});

/** execution.main 的 existing 挂接形态：production_evidence（只读既有
 * 事实，无 input 端口）。target 传 null 即动态选择。 */
function dynamicExistingZhixu(target: { zhixu: string } | null): ZhixuDefinition {
  return {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      taskPatterns: baseZhixu.spec.taskPatterns.map((task) =>
        task.name !== "execution"
          ? task
          : {
              ...task,
              stages: task.stages.map((stage) => ({
                ...stage,
                receiveSignals: {
                  START: "buyer::selector.assign.executor_selected",
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
              })),
            },
      ),
    },
  };
}

test("carries existing-mode dock routes on the on-chain track (UVPDockingModule 4.4)", () => {
  // 合约终态（attachDockedOrder）：existing 路由对等挂接既有目标单——
  // modeWord=existing 进 routeHash 与 dockInstanceId 双 preimage，与 new
  // 不可互冒。链轨编译不再拒绝，产物原样承载（旧拒绝闸直接删除，无
  // 兼容轨）；编译入口与反序列化边界同口径接受。
  const existingZhixu = dynamicExistingZhixu({ zhixu: dockDemoTargetName });

  const onchain = compileZhixuOnchainHookPlan(existingZhixu, demoManifest);
  assert.equal(onchain.dockRoutes.length, 1);
  const route = onchain.dockRoutes[0]!;
  assert.equal(route.orderMode, "existing");
  // existing 无出生锚：0 条 input 绑定（new 模式"恰 1 条"闸不适用）。
  assert.equal(route.inputBindings.length, 0);
  assert.equal(route.inputBindingsRoot, EMPTY_MERKLE_ROOT);
  assert.deepEqual(validateOnchainHookPlanArtifact(onchain), []);
  assert.doesNotThrow(() => toSolidityRegisterPlanArgs(onchain));

  // modeWord 槽钉 existing：同字段按 new 重算必失配（模式不可互冒的
  // 产物面证据）。
  assert.notEqual(
    routeHash({
      localDefinitionRefHash: route.local.definitionRefHash,
      targetDefinitionRefHash: route.target.definitionRefHash,
      interfaceName: route.target.interfaceName,
      orderMode: "new",
      inputBindingsRoot: route.inputBindingsRoot,
      outputBindingsRoot: route.outputBindingsRoot,
    }),
    route.routeHash,
  );
  assert.equal(route.routeHash, onchain.dockRoutesRoot); // 单叶树：根即叶
});

test("dynamic (null-target) routes never ride in dockRoutes (smuggling gate)", () => {
  // 动态路由的唯一承载面是 unresolvedDockRoutes（其叶已随 dockRoutesRoot
  // 经候选集根目标槽冻结）；把空 target 塞进 dockRoutes 是形态走私，两个
  // 边界都必须响亮拒绝。
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
  // target:null（§8.8 / UVPDockingModule 4.4）：候选集 root 占据 routeHash
  // 目标槽，随 dockRoutesRoot 在 finalize 冻结；attach 携候选叶 membership
  // proof 选定。候选清单是 manifest 派生的选择宇宙（DSL 壳不声明候选，
  // Rust 声明面也不携带——resolution manifest 是唯一既有发布面）。
  const dynamicZhixu = dynamicExistingZhixu(null);
  const onchain = compileZhixuOnchainHookPlan(dynamicZhixu, demoManifest);
  assert.equal(onchain.dockRoutes.length, 0);
  const unresolved = onchain.unresolvedDockRoutes ?? [];
  assert.equal(unresolved.length, 1);
  const route = unresolved[0]!;
  assert.equal(route.schemaVersion, "uvp.dockRoute.unresolved.v1");
  assert.equal(route.stageIdentifier, "execution.main");
  assert.equal(route.orderMode, "existing");
  assert.equal(route.interfaceName, "production_evidence");
  assert.deepEqual(
    route.outputBindings.map((binding) => [binding.signal, binding.port]),
    [["cmp", "scrap_declared"]],
  );

  // 候选面：demo manifest 唯一定义发布 production_evidence[existing]。
  const manifestEntry = demoManifest.definitions[0]!;
  assert.equal(route.candidates.length, 1);
  assert.equal(route.candidates[0]?.zhixuName, manifestEntry.definition.metadata.name);
  assert.equal(route.candidates[0]?.zhixuUid, manifestEntry.zhixu);
  assert.equal(route.candidates[0]?.definitionRefHash, manifestEntry.definitionRefHash);

  // 本地承诺逐项重算（与 validateDockCommitments 同公式，显式钉产物口径）。
  const expectedRouteId = dockRouteId(
    route.localDefinitionRefHash,
    stageKey("execution.main"),
  );
  assert.equal(route.routeId, expectedRouteId);
  const expectedCandidatesRoot = merkleRoot([
    dockCandidateLeaf({
      routeId: expectedRouteId,
      targetDefinitionRefHash: manifestEntry.definitionRefHash,
      interfaceName: "production_evidence",
    }),
  ]);
  assert.equal(route.candidatesRoot, expectedCandidatesRoot);
  assert.equal(
    route.routeHash,
    routeHash({
      localDefinitionRefHash: route.localDefinitionRefHash,
      targetDefinitionRefHash: expectedCandidatesRoot,
      interfaceName: "production_evidence",
      orderMode: "existing",
      inputBindingsRoot: EMPTY_MERKLE_ROOT,
      outputBindingsRoot: EMPTY_MERKLE_ROOT,
    }),
  );

  // dockRoutesRoot 是 finalize 冻结的最终根：静态叶 ∪ 动态叶。
  assert.equal(onchain.dockRoutesRoot, merkleRoot([route.routeHash]));
  assert.deepEqual(validateOnchainHookPlanArtifact(onchain), []);
  assert.doesNotThrow(() => toSolidityRegisterPlanArgs(onchain));
});

test("rejects dynamic-selection routes declaring order mode new (chain terminal state)", () => {
  // 合约终态没有 new 模式动态路由的消费方：openDockedOrder 只按静态目标
  // 槽重算 routeHash（无候选集回退），attachDockedOrder——唯一的动态路
  // 径——钉 existing。new 模式动态路由上链即永不可开的死路由，编译边界
  // 响亮拒绝。
  const dynamicNew = structuredClone(baseZhixu) as ZhixuDefinition & {
    spec: { taskPatterns: Array<{ stages: Array<{ executor?: { zhixuExecutorConfig?: { target: { zhixu: string } | null } } }> }> };
  };
  dynamicNew.spec.taskPatterns[1]!.stages[0]!.executor!.zhixuExecutorConfig!.target = null;
  assert.throws(
    () => compileZhixuOnchainHookPlan(dynamicNew as unknown as ZhixuDefinition, demoManifest),
    (error: unknown) => {
      assert.ok(error instanceof HookPlanCompilationError);
      const issues = error.issues.join("; ");
      assert.match(issues, /UNRESOLVED_DOCK_MODE/);
      assert.match(issues, /execution\.main/);
      assert.match(issues, /order mode "new"/);
      return true;
    },
  );

  // 反序列化边界同口径：把已接受的动态条目改成 new 并重签全部承诺
  // （routeHash/dockRoutesRoot/planHash 都按 new 重算，承诺自洽），只剩
  // 接受域门可拦——校验器必须拒绝。
  const accepted = compileZhixuOnchainHookPlan(
    dynamicExistingZhixu(null),
    demoManifest,
  );
  const entry = accepted.unresolvedDockRoutes![0]!;
  const forgedRouteHash = routeHash({
    localDefinitionRefHash: entry.localDefinitionRefHash,
    targetDefinitionRefHash: entry.candidatesRoot,
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

  // 伪造候选（换 definitionRefHash）：candidatesRoot 是候选叶 merkle，
  // 换叶即失配——伪造的候选宇宙进不了冻结承诺。
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

  // 换叶（routeHash 改值）：动态叶与 dockRoutesRoot 的对拍双双失配。
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

test("rejects silent order-trigger hooks (trigger without emitReady)", () => {
  const silentTriggerIssues = (issues: readonly string[]): readonly string[] =>
    issues.filter((issue) => /order trigger without emitReady/.test(issue));

  // 正例：编译器产物口径（mint trigger + emitReady=true，flags=5）零 issue。
  const baseOnchain = compileOnchainHookPlan(
    compileZhixuHookPlan(baseZhixu, demoManifest),
  );
  assert.deepEqual(silentTriggerIssues(validateOnchainHookPlanArtifact(baseOnchain)), []);

  // 反例 1（沉默 mint trigger）：orderTriggerKind=mint、emitReady=false 的
  // 形态——UVPStateMachine.commitPlan 对 flags=1 恒 revert
  // SilentOrderTriggerHook，artifact 边界同口径拒绝。只改出生锚通道钩子
  // START（裸 SIGNAL 条件）；watcher（TIMEOUT 的 DELAY 条件）保持原样，
  // trigger×DELAY 是另一条拒绝面（_validateHook），不混入本测试载体。
  const silentMint: OnchainHookPlanArtifact = {
    ...baseOnchain,
    compiledHooks: baseOnchain.compiledHooks.map((hook) =>
      hook.stageIdentifier === "execution.main" && hook.hookName === "START"
        ? { ...hook, orderTriggerKind: "mint" as const, emitReady: false }
        : hook,
    ),
  };
  const mintIssues = silentTriggerIssues(validateOnchainHookPlanArtifact(silentMint));
  assert.ok(mintIssues.length >= 1, "silent mint trigger must be flagged");
  for (const issue of mintIssues) {
    assert.match(
      issue,
      /hook execution\.main#.+ is an order trigger without emitReady; UVPStateMachine\.commitPlan reverts SilentOrderTriggerHook — the Rust compiler must always emit trigger flags with EMIT_READY$/,
    );
  }

  // 反例 2（沉默 dock trigger）：orderTriggerKind=dock、emitReady=false
  // 同样拒绝（flags=2 口径）。
  const silentDock: OnchainHookPlanArtifact = {
    ...baseOnchain,
    compiledHooks: baseOnchain.compiledHooks.map((hook) =>
      hook.stageIdentifier === "execution.main" && hook.hookName === "START"
        ? { ...hook, orderTriggerKind: "dock" as const, emitReady: false }
        : hook,
    ),
  };
  assert.ok(
    silentTriggerIssues(validateOnchainHookPlanArtifact(silentDock)).length >= 1,
    "silent dock trigger must be flagged",
  );

  // 编译入口同口径：沉默 trigger 形态在 compileOnchainHookPlan 预检即抛
  // HookPlanCompilationError，不产出制品。（重签 planHash，让拦截者聚焦在
  // 静默 trigger 门本身。）
  const silentSourcePlan = compileZhixuHookPlan(baseZhixu, demoManifest);
  const mutatedSilentPlan = resign({
    ...silentSourcePlan,
    compiledHooks: silentSourcePlan.compiledHooks.map((hook) =>
      hook.stageIdentifier === "execution.main" && hook.hookName === "START"
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

  // 触发条件主体：order-trigger hook 内出现 DELAY，制品边界必须
  // 镜像合约 InvalidInstruction（毒制品过验证即 commitPlan 必 revert）。
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

  // DELAY 缺正锚：~A 后延时（操作数无正向信号锚点）→ 合约镜像拒绝。
  const anchorFreeDelay = mutateHookInstructions("TIMEOUT", [
    timeoutInstructions[0], // SIGNAL
    { op: "NOT" },
    { op: "DELAY", delaySeconds: 5 },
    timeoutInstructions[2], // SIGNAL（补齐栈，聚焦单条拒绝面）
    { op: "AND", arity: 2 },
  ]);
  assert.ok(
    validateOnchainHookPlanArtifact(anchorFreeDelay).some((issue) =>
      /DELAY requires an operand with a positive signal anchor/.test(issue),
    ),
  );

  // NOT 非裸操作数（合约侧镜像缺口）：~(A&B) 形态。
  const notOverAnd = mutateHookInstructions("TIMEOUT", [
    timeoutInstructions[0], // SIGNAL
    timeoutInstructions[2], // SIGNAL
    { op: "AND", arity: 2 },
    { op: "NOT" },
  ]);
  assert.ok(
    validateOnchainHookPlanArtifact(notOverAnd).some((issue) =>
      /requires a bare SIGNAL operand/.test(issue),
    ),
  );

  // 整体纯否定（合约侧镜像缺口）：~A 单钩。
  const pureNegative = mutateHookInstructions("TIMEOUT", [
    timeoutInstructions[0], // SIGNAL
    { op: "NOT" },
  ]);
  assert.ok(
    validateOnchainHookPlanArtifact(pureNegative).some((issue) =>
      /at least one positive signal anchor/.test(issue),
    ),
  );

  // 正例：合法 TIMEOUT（SIGNAL,DELAY,SIGNAL,NOT,AND——DELAY 操作数含正锚、
  // NOT 操作数裸 SIGNAL、整体含正锚）零镜像 issue。
  assert.deepEqual(
    validateOnchainHookPlanArtifact(rehashed(structuredClone(baseOnchain) as OnchainHookPlanArtifact)),
    [],
  );
});

test("rejects DELAY on order-trigger conditions at the compile boundary (producer side)", () => {
  // core 的 D013 在 DSL 层已拒绝 input-port 钩子带延时；这里是第二道门：
  // 手工/漂移的 HookPlanArtifact（trigger 钩子 + delay AST）在 on-chain
  // 编译入口以合约 _validateHook 同口径拒绝，不产出毒制品。
  const targetPlan = compileZhixuHookPlan(
    dockProductionTargetDefinition(),
    demoManifest,
  );
  const triggerHook = targetPlan.compiledHooks.find(
    (hook) => hook.stageIdentifier === "manufacturing.intake" && hook.hookName === "EXECUTE",
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

// ---------------------------------------------------------------------------
// supplierType/fileType 闭集 + 制品规范序
// ---------------------------------------------------------------------------

test("rejects supplierType outside the closed enum at the on-chain compile boundary", () => {
  // 大小写变体在云侧曾是历史绕过面（"Zhixu"）；核心线闭集先拒，这里是
  // 链轨组装（executorHash 进链上承诺）对漂移/手工 HookPlanArtifact 的
  // 第二道门。
  const hookPlan = compileZhixuHookPlanWithManifest(baseZhixu);
  const mutated = resign({
    ...hookPlan,
    executorRoutes: {
      ...hookPlan.executorRoutes,
      "selector.assign": {
        ...hookPlan.executorRoutes["selector.assign"]!,
        executor: {
          ...hookPlan.executorRoutes["selector.assign"]!.executor,
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
  // 精确匹配、不 trim（与 Rust 编译入口同口径）：executorHash 哈希的是
  // executor 原文，trim 后匹配会放行 " organization " 这类原文——匹配面
  // 放行、承诺面按原文分叉，同一值既被宽容又被严格。
  const hookPlan = compileZhixuHookPlanWithManifest(baseZhixu);
  for (const supplierType of [" organization ", "zhixu ", "\tindividual"]) {
    const mutated = resign({
      ...hookPlan,
      executorRoutes: {
        ...hookPlan.executorRoutes,
        "selector.assign": {
          ...hookPlan.executorRoutes["selector.assign"]!,
          executor: {
            ...hookPlan.executorRoutes["selector.assign"]!.executor,
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
  // executor.selectableResource 整体经 executorHash 进链上承诺：词表外
  // fileType（含带空白变体）与 fileResources 同口径拒绝——同为
  // FileResource 面，不因挂在 executor 下而逃过闭集。
  // 合法形态走定义级全量编译（native 权威面同样校验该闭集，两侧同集）。
  const selectorStage = baseZhixu.spec.taskPatterns[0]!.stages[0]!;
  const withSelectableZhixu: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        {
          ...baseZhixu.spec.taskPatterns[0]!,
          stages: [
            {
              ...selectorStage,
              executor: {
                ...selectorStage.executor!,
                selectableResource: {
                  dataset: { fileType: "plain_text", plainText: { content: "x" } },
                },
              },
            },
          ],
        },
        ...baseZhixu.spec.taskPatterns.slice(1),
      ],
    },
  };
  compileOnchainHookPlan(compileZhixuHookPlanWithManifest(withSelectableZhixu));

  // 词表外形态在链轨编译入口拒绝（手工/漂移 HookPlanArtifact 的第二道门，
  // 先于 routeRef 承诺一致性检查）。
  const hookPlan = compileZhixuHookPlanWithManifest(baseZhixu);
  for (const fileType of ["tx_cloud", " local", "http "]) {
    const mutated = resign({
      ...hookPlan,
      executorRoutes: {
        ...hookPlan.executorRoutes,
        "selector.assign": {
          ...hookPlan.executorRoutes["selector.assign"]!,
          executor: {
            ...hookPlan.executorRoutes["selector.assign"]!.executor,
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
  const route = hookPlan.executorRoutes["selector.assign"]!;
  const mutated = resign({
    ...hookPlan,
    executorRoutes: {
      ...hookPlan.executorRoutes,
      "selector.assign": {
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
  // 与 Rust validate 的 "must be a map of file resources" 同口径：非 map 的
  // selectableResource（字符串/数字/数组）不得静默跳过 fileType 闭集检查
  // 后把原文烧进 executorHash；null 的 fileResources 不得让 Object.entries
  // 抛裸 TypeError 逃出编译入口——承诺面拒绝一律 HookPlanCompilationError。
  // selectableResource 为 null 例外：Rust Option<Value> 把 JSON null 解成
  // 缺席（serde 口径），两侧同放行。
  const hookPlan = compileZhixuHookPlanWithManifest(baseZhixu);
  const mutateExecutor = (
    selectableResource: unknown,
  ): Parameters<typeof compileOnchainHookPlan>[0] =>
    resign({
      ...hookPlan,
      executorRoutes: {
        ...hookPlan.executorRoutes,
        "selector.assign": {
          ...hookPlan.executorRoutes["selector.assign"]!,
          executor: {
            ...hookPlan.executorRoutes["selector.assign"]!.executor,
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
  // null 与缺失同为缺席（Rust Option<Value> 的 serde 口径）：形状门放行。
  // 变异后制品的 routeRef 承诺一致性另报——恰好证明 null 没撞上形状门。
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
        "selector.assign": {
          ...hookPlan.executorRoutes["selector.assign"]!,
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
  // 词表闸的第一道在编译入口（compileExecutorRoute，与 rust/go 同口径），
  // 但制品边界不得放行词表外/空白 id 的自洽制品（重签 planHash）：手工/
  // 第三方制品绕过 Rust 编译门后，闭集外 executorType/空 executorId 会经
  // executorHash 烧进链上承诺且再无合约守卫可拦。
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

  // 词表外 executorType（含大小写变体）→ 与编译入口同集同文案拒绝。
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
  // 带空白变体同拒：制品边界的 executorType 就是 executorHash 承诺的分类型
  // 投影，精确匹配（不 trim）与编译入口/Rust 权威面同口径。
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
  // 空 executorId / 空白 executorId → 拒绝（镜像编译入口 supplierID 门）。
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
  // 编译产物的原样制品（未变异）仍零 issue：闭集与编译入口同集，不收紧
  // 合法产物。
  assert.deepEqual(
    validateOnchainHookPlanArtifact(
      rehashed(structuredClone(onchain) as OnchainHookPlanArtifact),
    ),
    [],
  );
});

test("compile boundary rejects whitespace-only executor.supplierID", () => {
  // 只拒空串不够：空白 supplierID 是"有值"的假形态，过门即烧进
  // executorHash，消费侧永远无法寻址执行者。与 Rust 编译入口同口径拒绝。
  const hookPlan = compileZhixuHookPlanWithManifest(baseZhixu);
  const mutated = resign({
    ...hookPlan,
    executorRoutes: {
      ...hookPlan.executorRoutes,
      "selector.assign": {
        ...hookPlan.executorRoutes["selector.assign"]!,
        executor: {
          ...hookPlan.executorRoutes["selector.assign"]!.executor,
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
  // MAX_ONCHAIN_HOOK_DELAY_SECONDS 等常量自述"fail-closed 预检必须拒绝同样
  // 输入"：30 天延时上限/空指令栈形状/空依赖/EmptyPlan 不能只在反序列化
  // 边界生效——否则手工/漂移的 IR 制品（过 IR 校验）会在编译入口静默
  // 产出毒制品，交由 commitPlan revert。编译 preflight 必须同口径拒绝。
  const hookPlan = compileZhixuHookPlanWithManifest(baseZhixu);
  const timeoutHook = hookPlan.compiledHooks.find(
    (hook) => hook.hookName === "TIMEOUT",
  );
  assert.ok(timeoutHook, "base fixture exposes the TIMEOUT watcher hook");

  // 30 天延时上限（contract reverts HookDelayTooLong）。
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

  // 空依赖（contract reverts InvalidHook for empty dependencyKeys）：IR 校验
  // 不拒绝空依赖数组，毒制品须在编译 preflight 拦下，不得留到
  // toSolidityRegisterPlanArgs 才炸。
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

  // EmptyPlan（contract reverts EmptyPlan）：零 hook 且无阶段声明投影的
  // IR 制品过 IR 校验，编译入口必须拒绝。
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
  // 重排 + 重建 dependencyIndex（per-key hookIds 跟随制品序）+ 重签
  // planHash：承诺面全部自洽，唯一缺口是数组序——规范序是同一 plan 的
  // 唯一形态（内容寻址前提），不得放行。
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
  // 2609100741 L8：顶层形状门（isPlanHashRecomputable）不检深层值——负载
  // 携带非 JSON 值（bigint）时旧口径让 canonicalize 的裸 TypeError 逃出，
  // 违反"校验器返回 issues"契约（姊妹实现 hook-plan.ts 有 try/catch）。
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
  // 不抛裸异常：validateOnchainHookPlanArtifact 对毒负载整体返回 issues。
  assert.doesNotThrow(() => validateOnchainHookPlanArtifact(poisoned));
});

test("rejects undeclared extra fields on on-chain HookPlan artifacts (L9)", () => {
  // planHash 只覆盖声明字段：多余字段不进哈希，放行会让"同一 plan 唯一
  // 字节数组形态"承诺失效（2609100741 L9）。
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
test("duplicate birth-channel key is rejected at compile and deserialization boundaries (U2 mirror)", () => {
  const sourcePlan = compileZhixuHookPlan(baseZhixu, demoManifest);
  // (1) 编译入口：两个 order-trigger hook（mint∪dock）共享出生键——IR 层
  // 把 PLACE 的种子事实改写为 START 的订阅事实，START 升为 mint、PLACE
  // 升为 dock entrance。
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

  // (2) 反序列化边界：mint 出生键 == dock entrance 键同样拒绝；同键
  // watcher（非出生通道）不受限。
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
    hookOf("mint_line", "stage.a", stageA, "mint"),
    hookOf("dock_line", "stage.b", stageB, "dock"),
    hookOf("watcher", "stage.a", stageA, "none"),
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
  // watcher 与出生键同阶段共享：不触发出生通道守卫（上一步唯一 issue 已证）。

  // (3) mint∪mint 扇出（customs 基准 plan 形态）放行。
  const fanOutHooks = [
    hookOf("mint_line", "stage.a", stageA, "mint"),
    hookOf("mint_line_2", "stage.b", stageB, "mint"),
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

  // 依赖键换成 ghost 信号（sourceId/signalId/signalKey 三元组自洽）：
  // 声明的键不是任何 SIGNAL 原子，且原 SIGNAL 原子未声明——两个方向同报。
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
  // selector-binding 无 128 上限：表内容由 capabilitiesRoot 承诺——
  // 空表钉 EMPTY_MERKLE_ROOT，任何叶子变化都改根。
  assert.equal(capabilitiesRootOf([], []), EMPTY_MERKLE_ROOT);

  // 绑定侧：同一能力表增删一个绑定叶，根随之变化（真实编译产物）。
  const withBinding = compileOnchainHookPlan(
    compileZhixuHookPlan(baseZhixu, demoManifest),
  );
  const withoutBinding = compileOnchainHookPlan(
    compileZhixuHookPlan(
      {
        ...baseZhixu,
        spec: {
          ...baseZhixu.spec,
          taskPatterns: baseZhixu.spec.taskPatterns.map((task) =>
            task.name !== "selector"
              ? task
              : {
                  ...task,
                  stages: task.stages.map((stage) => ({
                    ...stage,
                    selectedStages: [],
                  })),
                },
          ),
        },
      },
      demoManifest,
    ),
  );
  assert.deepEqual(withoutBinding.selectorBindings, []);
  assert.deepEqual(withBinding.signalCapabilities, withoutBinding.signalCapabilities);
  assert.notEqual(withBinding.capabilitiesRoot, withoutBinding.capabilitiesRoot);
  assert.notEqual(withoutBinding.capabilitiesRoot, EMPTY_MERKLE_ROOT);

  // 能力侧：同一绑定表换一片能力叶（relation 翻转），根随之变化。
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

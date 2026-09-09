import assert from "node:assert/strict";
import {
  dockDemoResolutionManifest,
  dockDemoTargetName,
  dockProductionTargetDefinition,
} from "./dock-demo.js";
import { EMPTY_MERKLE_ROOT } from "../src/dock.js";
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
import { compileZhixuHookPlan, HookPlanCompilationError } from "../src/hook-plan.js";
import { hookPlanHashOf } from "../src/dock-commitments.js";
import {
  compileOnchainHookPlan,
  hashOnchainPlanPayload,
  onchainSignalId,
  onchainSignalKey,
  onchainSourceId,
} from "../src/onchain-hook-plan.js";
import type { HookPlanArtifact } from "../src/types/index.js";

const demoManifest = dockDemoResolutionManifest();

/** 变异 hook plan 制品后按载荷重签 planHash（承诺重算由专门的篡改测试覆盖）。 */
function resign<A extends { planHash: string }>(artifact: A): A {
  return {
    ...artifact,
    planHash: hookPlanHashOf(artifact as unknown as HookPlanArtifact),
  };
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
            // PLACE 为自发种子入口钩子（uvp-core 659a388 物化门：零 hook
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
  assert.equal(onchain.schemaVersion, "uvp.onchainHookPlan.v2");
  assert.equal(onchain.planId, sourcePlan.planId);
  assert.deepEqual(onchain.platform, sourcePlan.platform);
  assert.equal(onchain.sourcePlanHash, sourcePlan.planHash);
  // 父定义 target.zhixu 携带目标 name 引用（DSL 壳不携带派生身份），
  // sourcePlanHash/planHash preimage 随定义内容变化；承诺公式本身冻结不变。
  assert.equal(
    onchain.planHash,
    "0x9692f1889aa59810b9cff28d225dce9ed22e7bcecbf5c0e5ddcb9d2896dc293f",
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

test("maps on-chain artifacts to Solidity register-plan argument shape", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));
  const args = toSolidityRegisterPlanArgs(onchain);

  assert.equal(args.schemaVersion, "uvp.onchainHookPlan.v2");
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
          "bytes32 domain, bytes32 hooksHash, bytes32 metadataHash, bytes32 dockRoutesRoot, bytes32 dockInterfaceRoot",
        ),
        [
          keccak256(stringToHex("uvp.plan.runtime.v2")),
          args.hooksHash,
          args.metadataHash,
          args.dockRoutesRoot,
          args.dockInterfaceRoot,
        ],
      ),
    ),
  );
  assert.notEqual(args.planHash, args.artifactHash);
  assert.equal(args.hooksHash, hashSolidityRegisterHooks(args.hooks));
  assert.match(args.hooksHash, /^0x[0-9a-f]{64}$/);
  assert.match(args.metadataHash, /^0x[0-9a-f]{64}$/);
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

test("selector bindings feed the Solidity metadata hash and runtime plan hash", () => {
  // finalizePlan 以 keccak256(abi.encode(selectorBindings, signalCapabilities))
  // 重算 metadataHash——selectorBindings 变化必须穿透 args.metadataHash 与
  // PlanCommit runtime planHash，否则两步注册在 finalize 边 revert。
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
  assert.notEqual(withBinding.metadataHash, withoutBinding.metadataHash);
  assert.notEqual(withBinding.planHash, withoutBinding.planHash);
  assert.equal(
    withBinding.metadataHash,
    keccak256(
      encodeAbiParameters(
        parseAbiParameters(
          "(bytes32 selectorStageId,bytes32 targetStageId)[] selectorBindings,(bytes32 stageId,bytes32 targetSourceId,bytes32 signalId,uint8 targetOrderRelation)[] signalCapabilities",
        ),
        [withBinding.selectorBindings, withBinding.signalCapabilities],
      ),
    ),
  );
});

test("hooksHash frozen vector pins the zero-word instruction fill cross-language", () => {
  // 与 UVPStateMachine.t.sol 的同名冻结向量逐字节一致：非 SIGNAL 指令的
  // sourceId/signalId 填 Solidity 零字，arity/delaySeconds 未用位填 0。
  // 任何一方（TS compiler / uvp-deploy 驱动 / Rust）在填充位引入别的字
  // 节（例如 keccak256("")）都会让含 NOT/AND/OR/DELAY 的计划在 commitPlan
  // 处 PlanMetadataHashMismatch 必然 revert。
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

  // (2) 逐 hook 顺序语义（0212 P3-1）：trigger(A) → trigger(B) → watcher(A)
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

test("rejects plans whose sendSignals vocabulary exceeds the gas-bounded capability cap", () => {
  // G-18：sendSignals 总量编译为 signalCapabilities；超上限在编译与反序列
  // 化两个边界同口径拒绝（_signalStageId 每次信号提交线性扫描 capabilities）。
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));
  const template = onchain.signalCapabilities[0];
  assert.ok(template);
  assert.equal(
    validateOnchainHookPlanArtifact({
      ...onchain,
      signalCapabilities: Array.from({ length: 257 }, (_, index) => ({
        ...template,
        targetSource: `buyer-${index}`,
        targetSourceId: onchainSourceId(`buyer-${index}`),
      })),
    }).some((issue) => /signal capabilities 257 exceed the documented limit 256/.test(issue)),
    true,
  );
});

test("rejects cross-stage current-order fact key duplication (E16 mirror)", () => {
  const sourcePlan = compileZhixuHookPlan(baseZhixu, demoManifest);
  // 同一事实键 (targetSourceId, signalId) 挂到两个阶段、relation=current：
  // commitPlan 可过、finalizePlan 恒 revert DuplicateCurrentOrderSignalCapability
  // （planId 烧毁）——编译期预检必须拒绝，不等链上。
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
        /current-order fact key .* already owned by stage .*DuplicateCurrentOrderSignalCapability/.test(issue),
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
    ["schemaVersion must be uvp.onchainHookPlan.v2"],
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
              // PUBLISH 为自发种子入口钩子（uvp-core 659a388 物化门：零
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
              // PUBLISH 为自发种子入口钩子（uvp-core 659a388 物化门：零
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

test("rejects stages that compile to zero hooks (P0-4 materialization gate)", () => {
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
  // 拦截者就是物化门本身。）
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

test("rejects existing-mode dock routes on the on-chain track (explicit rejection)", () => {
  // Rust 两个编译 profile 都放行 existing（云轨运行时语义）；on-chain 编译
  // 必须显式拒绝，不静默降级。编译入口与反序列化边界同口径。
  const existingZhixu: ZhixuDefinition = {
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
                    target: { zhixu: dockDemoTargetName },
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

  assert.throws(
    () => compileZhixuOnchainHookPlan(existingZhixu, demoManifest),
    (error: unknown) => {
      assert.ok(error instanceof HookPlanCompilationError);
      assert.ok(
        error.issues.some(
          (issue) =>
            /order mode "existing"/.test(issue) &&
            /on-chain targets do not support/.test(issue) &&
            /explicit rejection instead of a silent fallback/.test(issue),
        ),
        error.issues.join("; "),
      );
      return true;
    },
  );

  // 反序列化边界：云轨 hook_plan 产物合法携带 existing route，但喂给
  // onchain 校验器必须被同一道门拒绝。compileOnchainHookPlan 的 preflight
  // 会先抛，这里从 base 计划（new 模式合法产物）换挂 existing routes 后
  // 重算 planHash，模拟反序列化视角。
  const cloudPlan = compileZhixuHookPlan(existingZhixu, demoManifest);
  assert.equal(cloudPlan.dockRoutes[0]?.orderMode, "existing");
  const onchainBase = compileOnchainHookPlan(
    compileZhixuHookPlan(baseZhixu, demoManifest),
  );
  const swapped = {
    ...onchainBase,
    dockRoutes: cloudPlan.dockRoutes,
  };
  const { planHash: _staleHash, ...swappedPayload } = swapped;
  void _staleHash;
  const boundaryIssues = validateOnchainHookPlanArtifact({
    ...swappedPayload,
    planHash: hashOnchainPlanPayload(swappedPayload as never),
  } as unknown as OnchainHookPlanArtifact);
  assert.ok(
    boundaryIssues.some(
      (issue) =>
        /on-chain targets do not support/.test(issue) &&
        /existing/.test(issue),
    ),
    boundaryIssues.join("; "),
  );
});

test("rejects unresolved dock targets on the on-chain track (UNRESOLVED_DOCK_TARGET)", () => {
  const onchain = compileOnchainHookPlan(
    compileZhixuHookPlan(baseZhixu, demoManifest),
  );
  // target:null 的动态选择 route：on-chain 没有运行时选择面，按
  // UNRESOLVED_DOCK_TARGET 口径拒绝（与 Rust 无 manifest 编译错误同锚点）。
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
    issues.some(
      (issue) =>
        /UNRESOLVED_DOCK_TARGET/.test(issue) &&
        /no statically linked target/.test(issue),
    ),
    issues.join("; "),
  );
});

test("rejects unresolvedDockRoutes at the on-chain compile boundary (UNRESOLVED_DOCK_TARGET)", () => {
  // Wave3-E4（§8.8）：Rust hook_plan 对 target:null 放行并携带
  // unresolvedDockRoutes 声明面；on-chain 编译入口必须响亮拒绝，不静默
  // 丢弃未解析 route。
  const dynamicTarget = structuredClone(baseZhixu) as ZhixuDefinition & {
    spec: { taskPatterns: Array<{ stages: Array<{ executor?: { zhixuExecutorConfig?: { target: { zhixu: string } | null } } }> }> };
  };
  dynamicTarget.spec.taskPatterns[1]!.stages[0]!.executor!.zhixuExecutorConfig!.target = null;
  const cloudPlan = compileZhixuHookPlan(
    dynamicTarget as unknown as ZhixuDefinition,
    demoManifest,
  );
  assert.equal(cloudPlan.unresolvedDockRoutes?.length, 1);
  assert.throws(
    () => compileOnchainHookPlan(cloudPlan),
    (error: unknown) => {
      assert.ok(error instanceof HookPlanCompilationError);
      const issues = error.issues.join("; ");
      assert.match(issues, /UNRESOLVED_DOCK_TARGET/);
      assert.match(issues, /execution\.main/);
      assert.match(issues, /unresolved route/);
      return true;
    },
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

test("artifact boundary stays vocabulary-neutral on executorType", () => {
  // 词表闸在编译入口（compileExecutorRoute，与 rust/go 同口径）；制品边界
  // 与 rust 权威面同构——只校验结构一致性与承诺摘要重算，不自造词表层。
  // 词表外 executorType 的自洽制品（重签 planHash）在边界放行，责任在
  // 产出侧的编译入口。
  const onchain = compileOnchainHookPlan(
    compileZhixuHookPlanWithManifest(baseZhixu),
  );
  const route = onchain.executorRoutes[0]!;
  const mutated = {
    ...onchain,
    executorRoutes: onchain.executorRoutes.map((candidate) =>
      candidate === route
        ? { ...candidate, executorType: "Vendor" }
        : candidate,
    ),
  };
  const { planHash: _drop, ...payload } = mutated;
  void _drop;
  const issues = validateOnchainHookPlanArtifact({
    ...mutated,
    planHash: hashOnchainPlanPayload(payload),
  });
  assert.deepEqual(
    issues.filter((issue) => issue.includes("executorType must be one of")),
    [],
    `制品边界不应校验 executorType 词表，实际 issues：${JSON.stringify(issues)}`,
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

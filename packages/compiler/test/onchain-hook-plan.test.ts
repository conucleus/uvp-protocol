import assert from "node:assert/strict";
import { dockDemoResolutionManifest } from "./dock-demo.js";
import { EMPTY_MERKLE_ROOT } from "../src/dock.js";
import test from "node:test";
import {
  assertOnchainHookPlanArtifact,
  compileZhixuOnchainHookPlan,
  keccak256Hex,
  onchainSelectorBindingHash,
  OnchainHookPlanArtifactValidationError,
  toSolidityRegisterPlanArgs,
  validateOnchainHookPlanArtifact,
  type OnchainHookPlanArtifact,
  type OnchainSignalInstruction,
  type ZhixuDefinition,
} from "../src/index.js";
import { compileZhixuHookPlan, HookPlanCompilationError } from "../src/hook-plan.js";
import { compileOnchainHookPlan, hashOnchainPlanPayload, onchainSignalId, onchainSourceId } from "../src/onchain-hook-plan.js";
import type { HookPlanArtifact } from "../src/types/index.js";

const demoManifest = dockDemoResolutionManifest();

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
    uid: "zhixu-demo-001",
    annotations: {
      version: "7",
    },
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
            sendSignals: ["executor_selected"],
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
              zhixuExecutorConfig: {
                schemaVersion: "uvp.dock.v1",
                target: { zhixu: "payment-zhixu", version: "1.2.0" },
                order: { idPolicy: "derived-v1" },
                inputMap: { START: "execute", TIMEOUT: "cancel" },
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
  assert.equal(
    onchain.planHash,
    "0x9b5f1fbd3af5c982dcba9c2cf8145a90d91804e789cc7e76a214e7aed07dcc12",
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
    ],
  );
  assert.deepEqual(
    onchain.compiledHooks.map((hook) => hook.hookId),
    [
      "0x07fec9e5326c8025bd807a2d26a55476168f38f6b9b1d3ef3af9df18f758da96",
      "0x2a799fd6d3c55a26d5b940bc8fedc135a5feae293bce3e0c6cd375c4a946fc89",
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
      annotations: {
        version: "7"
      },
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


    "0xcf7c8f26d55e2223a316d1220b6f7c902d1654622e82b458a98871bdf4c4e433": [
      "0x07fec9e5326c8025bd807a2d26a55476168f38f6b9b1d3ef3af9df18f758da96",
      "0x2a799fd6d3c55a26d5b940bc8fedc135a5feae293bce3e0c6cd375c4a946fc89",
    ],
  });

  assert.deepEqual(
    onchain.executorRoutes.map((route) => route.routeId),
    ["0x50a98fb0b72e21bff21f57c8269a01953f1400a33ee2a92483825ea897feb09a"],
  );
  // zhixu 委托 stage 不再挂静态 executor route（routeRef 只属于静态执行者）。
  assert.equal(
    onchain.compiledHooks.find((hook) => hook.hookName === "START")?.routeRef,
    undefined,
  );
});

test("maps on-chain artifacts to Solidity register-plan argument shape", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu, demoManifest));
  const args = toSolidityRegisterPlanArgs(onchain);

  assert.equal(args.schemaVersion, "uvp.onchainHookPlan.v2");
  assert.equal(args.sourcePlanId, onchain.planId);
  assert.equal(args.artifactHash, onchain.planHash);
  assert.notEqual(args.planHash, args.artifactHash);
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
  assert.equal(args.dependencyIndex.length, 2);
  assert.equal(
    args.executorRoutes.every((route) => route.executorId !== "payment-zhixu"),
    true,
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
    [0, 0, 0, 0],
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

test("rejects duplicate on-chain selector bindings", () => {
  const sourcePlan = compileZhixuHookPlan(baseZhixu, demoManifest);

  assert.throws(
    () =>
      compileOnchainHookPlan({
        ...sourcePlan,
        selectedStageBindings: [
          ...sourcePlan.selectedStageBindings,
          sourcePlan.selectedStageBindings[0]!,
        ],
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

test("compiles mint birth subscriptions into isTrigger SIGNAL hooks", () => {
  // 出生订阅上链 = 提交事实本身即出生信号：编译为一条 SIGNAL 指令，
  // isTrigger=true（triggerOrderFrom* 的硬门槛），提交者按
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
              sendSignals: ["posted"],
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

test("rejects retired cross-source headers at hook-plan compilation", () => {
  const withReceive = (expression: string): ZhixuDefinition => ({
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      taskPatterns: baseZhixu.spec.taskPatterns.map((pattern) => ({
        ...pattern,
        stages: pattern.stages.map((stage) =>
          stage.name === "main"
            ? {
                ...stage,
                receiveSignals: { START: expression },
                executor: {
                  supplierType: "zhixu",
                  zhixuExecutorConfig: {
                    schemaVersion: "uvp.dock.v1",
                    target: { zhixu: "payment-zhixu", version: "1.2.0" },
                    order: { idPolicy: "derived-v1" },
                    inputMap: { START: "execute" },
                    signalMap: { str: "started", cmp: "completed" }
                  }
                }
              }
            : stage
        )
      }))
    }
  });

  assert.throws(
    () => compileZhixuHookPlanWithManifest(withReceive("::MERGE@(buyer::selector.assign.executor_selected, buyer::execution.main.cmp)")),
    (error: unknown) =>
      error instanceof HookPlanCompilationError &&
      error.issues.some((issue) => /retired in uvp\.semantic\.v1/.test(issue))
  );
  assert.throws(
    () => compileZhixuHookPlanWithManifest(withReceive("::ANCHOR@(execution.main.cmp)")),
    (error: unknown) =>
      error instanceof HookPlanCompilationError &&
      error.issues.some((issue) => /retired in uvp\.semantic\.v1/.test(issue))
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
              sendSignals: ["posted"],
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
  // HookPlanCompilationError，不产出制品。
  const watcherSourcePlan = compileZhixuHookPlan(baseZhixu, demoManifest);
  const mutatedSourcePlan = {
    ...watcherSourcePlan,
    compiledHooks: watcherSourcePlan.compiledHooks.map((hook) =>
      hook.stageIdentifier === "execution.main"
        ? { ...hook, orderTriggerKind: "none" as const, emitReady: false }
        : hook,
    ),
  };
  assert.throws(
    () => compileOnchainHookPlan(mutatedSourcePlan),
    (error: unknown) =>
      error instanceof HookPlanCompilationError &&
      error.issues.some((issue) =>
        /stage execution\.main has no order-trigger or EMIT_READY hook/.test(issue),
      ),
  );
});

import assert from "node:assert/strict";
import test from "node:test";
import {
  assertOnchainHookPlanArtifact,
  compileOnchainHookPlan,
  compileZhixuHookPlan,
  keccak256Hex,
  onchainSelectorBindingHash,
  OnchainHookPlanArtifactValidationError,
  toSolidityRegisterPlanArgs,
  validateOnchainHookPlanArtifact,
  type OnchainSignalInstruction,
  type ZhixuDefinition
} from "../src/index.js";

const baseZhixu: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: {
    name: "demo_zhixu",
    uid: "zhixu-demo-001",
    annotations: {
      version: "7"
    }
  },
  spec: {
    platform: {
      type: "cloud"
    },
    nucleation: {
      id: "core"
    },
    taskPatterns: [
      {
        name: "selector",
        stages: [
          {
            name: "assign",
            source: "buyer",
            trigger: ["TRIGGER"],
            receiveSignals: {
              TRIGGER: "::OUTSIDE"
            },
            selectedStages: ["execution.main"],
            sendSignals: ["executor_selected"],
            executor: {
              supplierType: "organization",
              supplierID: "selector-org"
            }
          }
        ]
      },
      {
        name: "execution",
        stages: [
          {
            name: "main",
            source: "buyer",
            trigger: ["START"],
            receiveSignals: {
              START: "buyer::selector.assign.executor_selected",
              TIMEOUT: "buyer::(selector.assign.executor_selected +5s) & ~execution.main.cmp"
            },
            sendSignals: ["str", "cmp", "err"],
            executor: {
              supplierType: "zhixu",
              supplierID: "payment-zhixu",
              zhixuExecutorConfig: {
                signalMap: {
                  str: "payment::payment_flow.init.str",
                  cmp: "payment::payment_flow.settle.cmp"
                }
              }
            }
          }
        ]
      }
    ]
  }
};

test("compiles a stable compact on-chain HookPlan artifact", () => {
  const sourcePlan = compileZhixuHookPlan(baseZhixu);
  const onchain = compileOnchainHookPlan(sourcePlan);
  const again = compileOnchainHookPlan(sourcePlan);

  assert.deepEqual(onchain, again);
  assert.equal(onchain.schemaVersion, "uvp.onchainHookPlan.v1");
  assert.equal(onchain.planId, sourcePlan.planId);
  assert.deepEqual(onchain.platform, sourcePlan.platform);
  assert.equal(onchain.sourcePlanHash, sourcePlan.planHash);
  assert.equal(onchain.planHash, "0xb148ee139eb4865bc13e0d4ab32a885e9add80be3b1173006a2ca176c3bc78c6");
  assert.deepEqual(onchain.selectorBindings, [
    {
      selectorStageIdentifier: "selector.assign",
      targetStageIdentifier: "execution.main",
      selectorStageId: keccak256Hex("selector.assign"),
      targetStageId: keccak256Hex("execution.main"),
      bindingHash: onchainSelectorBindingHash(
        keccak256Hex("selector.assign"),
        keccak256Hex("execution.main")
      )
    }
  ]);
  assert.deepEqual(onchain.compiledHooks.map((hook) => hook.hookId), [
    "0x4192cb3bc76e04ab3c8f9a95ead3b20e86b5af753ac911791d20249e19a81e5a",
    "0x1c89ab49405588dd2aa212acd1bdcccbf18ed9828e3cb14fa678aeb3509f02d3",
    "0x07fec9e5326c8025bd807a2d26a55476168f38f6b9b1d3ef3af9df18f758da96",
    "0x2a799fd6d3c55a26d5b940bc8fedc135a5feae293bce3e0c6cd375c4a946fc89",
    "0xdbddf4f61e7e055756d4138cf06773730c4f2b9d9663ff4729c87e1a0e743784"
  ]);
  assert.equal(
    onchain.compiledHooks[2]?.hookId,
    keccak256Hex("execution.main#START")
  );
  assert.equal(
    onchain.compiledHooks[2]?.stageId,
    keccak256Hex("execution.main")
  );

  const startSignal = onchain.compiledHooks[2]?.instructions[0] as OnchainSignalInstruction;
  assert.equal(startSignal.sourceId, keccak256Hex("buyer"));
  assert.equal(startSignal.signalId, keccak256Hex("selector.assign.executor_selected"));
  assert.equal(startSignal.signalKey, "0xcf7c8f26d55e2223a316d1220b6f7c902d1654622e82b458a98871bdf4c4e433");

  assert.deepEqual(validateOnchainHookPlanArtifact(onchain), []);
  assert.doesNotThrow(() => assertOnchainHookPlanArtifact(onchain));
});

test("compiles Hook AST nodes to stable on-chain instruction arrays", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu));
  const timeoutHook = onchain.compiledHooks.find((hook) => hook.hookName === "TIMEOUT");

  assert.deepEqual(timeoutHook?.instructions, [
    {
      op: "SIGNAL",
      source: "buyer",
      signalName: "selector.assign.executor_selected",
      sourceId: "0x9c1bfc34ea7e295ac684c026c6d4de765734cb6b37fa07330bcfc241743ebbaf",
      signalId: "0xa0756ea7615d348df1d40db5b1f47a5dbf14775409e8340b067202afb9c95bab",
      signalKey: "0xcf7c8f26d55e2223a316d1220b6f7c902d1654622e82b458a98871bdf4c4e433"
    },
    {
      op: "DELAY",
      delaySeconds: 5
    },
    {
      op: "SIGNAL",
      source: "buyer",
      signalName: "execution.main.cmp",
      sourceId: "0x9c1bfc34ea7e295ac684c026c6d4de765734cb6b37fa07330bcfc241743ebbaf",
      signalId: "0x7aac3bcb090fc9f71f030794082ffa827a686948f2bef40b5452cd121a82eee7",
      signalKey: "0x1845455a34645910fcbc7220c18dcb6661ad3f045893d3694d22a99a1a5dcc11"
    },
    {
      op: "NOT"
    },
    {
      op: "AND",
      arity: 2
    }
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
                  ALT: "buyer::execution.main.str | execution.main.err"
                }
              }))
            }
      )
    }
  };
  const orHook = compileOnchainHookPlan(compileZhixuHookPlan(orZhixu)).compiledHooks.find(
    (hook) => hook.hookName === "ALT"
  );

  assert.deepEqual(orHook?.instructions.map((instruction) => instruction.op), [
    "SIGNAL",
    "SIGNAL",
    "OR"
  ]);
  assert.deepEqual(orHook?.instructions[2], { op: "OR", arity: 2 });
});

test("builds a stable on-chain dependency index and route references", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu));

  assert.deepEqual(onchain.dependencyIndex, {
    "0x1845455a34645910fcbc7220c18dcb6661ad3f045893d3694d22a99a1a5dcc11": [
      "0x2a799fd6d3c55a26d5b940bc8fedc135a5feae293bce3e0c6cd375c4a946fc89"
    ],
    "0x61cb81a7548a6a2edd47b3311aa31001794ad214e42ed5448a5e628b68d94ad8": [
      "0xdbddf4f61e7e055756d4138cf06773730c4f2b9d9663ff4729c87e1a0e743784"
    ],
    "0x8553bcf44b2604c2d6ba8083e354d082f7e91254eba8a3034e5ac6930923a957": [
      "0x1c89ab49405588dd2aa212acd1bdcccbf18ed9828e3cb14fa678aeb3509f02d3"
    ],
    "0xcc82a6048b0604736991482236464a3565da6e76b077288386298d4420134a8b": [
      "0x4192cb3bc76e04ab3c8f9a95ead3b20e86b5af753ac911791d20249e19a81e5a"
    ],
    "0xcf7c8f26d55e2223a316d1220b6f7c902d1654622e82b458a98871bdf4c4e433": [
      "0x07fec9e5326c8025bd807a2d26a55476168f38f6b9b1d3ef3af9df18f758da96",
      "0x2a799fd6d3c55a26d5b940bc8fedc135a5feae293bce3e0c6cd375c4a946fc89"
    ]
  });

  assert.deepEqual(onchain.executorRoutes.map((route) => route.routeId), [
    "0x24e3b5a8ab000691a715e1ee367fc5fa8136fbe55b342008c62527e0dccea4a4",
    "0x50a98fb0b72e21bff21f57c8269a01953f1400a33ee2a92483825ea897feb09a"
  ]);
  assert.equal(
    onchain.compiledHooks.find((hook) => hook.hookName === "START")?.routeRef?.routeId,
    "0x24e3b5a8ab000691a715e1ee367fc5fa8136fbe55b342008c62527e0dccea4a4"
  );
});

test("maps on-chain artifacts to Solidity register-plan argument shape", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu));
  const args = toSolidityRegisterPlanArgs(onchain);

  assert.equal(args.schemaVersion, "uvp.onchainHookPlan.v1");
  assert.equal(args.planId, onchain.planId);
  assert.equal(args.planHash, onchain.planHash);
  assert.equal(args.hooks[3]?.hookName, keccak256Hex("TIMEOUT"));
  assert.deepEqual(args.hooks[3]?.instructions.map((instruction) => instruction.op), [
    "SIGNAL",
    "DELAY",
    "SIGNAL",
    "NOT",
    "AND"
  ]);
  assert.deepEqual(args.hooks[3]?.dependencyKeys, [
    "0x1845455a34645910fcbc7220c18dcb6661ad3f045893d3694d22a99a1a5dcc11",
    "0xcf7c8f26d55e2223a316d1220b6f7c902d1654622e82b458a98871bdf4c4e433"
  ]);
  assert.equal(args.dependencyIndex.length, 5);
  assert.equal(args.executorRoutes[0]?.executorId, "payment-zhixu");
  assert.deepEqual(args.selectorBindings, [
    {
      selectorStageId: keccak256Hex("selector.assign"),
      targetStageId: keccak256Hex("execution.main")
    }
  ]);
});

test("includes selector bindings in on-chain plan hash", () => {
  const withBinding = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu));
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
                selectedStages: []
              }))
            }
      )
    }
  };
  const withoutBinding = compileOnchainHookPlan(compileZhixuHookPlan(withoutSelectedStages));

  assert.deepEqual(withoutBinding.selectorBindings, []);
  assert.notEqual(withBinding.planHash, withoutBinding.planHash);
});

test("rejects duplicate on-chain selector bindings", () => {
  const sourcePlan = compileZhixuHookPlan(baseZhixu);

  assert.throws(
    () =>
      compileOnchainHookPlan({
        ...sourcePlan,
        selectedStageBindings: [
          ...sourcePlan.selectedStageBindings,
          sourcePlan.selectedStageBindings[0]!
        ]
      }),
    OnchainHookPlanArtifactValidationError
  );
});

test("rejects invalid on-chain HookPlan artifact shapes", () => {
  const onchain = compileOnchainHookPlan(compileZhixuHookPlan(baseZhixu));

  assert.deepEqual(validateOnchainHookPlanArtifact({ ...onchain, schemaVersion: "wrong" }), [
    "schemaVersion must be uvp.onchainHookPlan.v1"
  ]);
  assert.match(
    validateOnchainHookPlanArtifact({
      ...onchain,
      compiledHooks: [
        {
          ...onchain.compiledHooks[0]!,
          hookId: "0x0000000000000000000000000000000000000000000000000000000000000000"
        },
        ...onchain.compiledHooks.slice(1)
      ]
    }).join("; "),
    /hookId must be keccak256/
  );
  assert.throws(
    () =>
      assertOnchainHookPlanArtifact({
        ...onchain,
        dependencyIndex: {}
      }),
    OnchainHookPlanArtifactValidationError
  );
});

import assert from "node:assert/strict";
import test from "node:test";
import {
  assertHookPlanArtifact,
  compileZhixuHookPlan,
  HookPlanCompilationError,
  HookPlanArtifactValidationError,
  validateHookPlanArtifact
} from "../src/hook-plan.js";
import {
  type ZhixuDefinition,
  type ZhixuStage
} from "../src/types/index.js";
import { dockDemoResolutionManifest } from "./dock-demo.js";
import { merkleRoot } from "../src/dock.js";

const demoManifest = dockDemoResolutionManifest();

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
            selectedStages: ["execution.main"],
            // PLACE 为自发种子入口钩子（uvp-core 659a388 物化门：零 hook
            // 阶段在链上永不可物化、sendSignals 无钩子可挂）。
            receiveSignals: {
              PLACE: "buyer::selector.assign.seed"
            },
            sendSignals: ["executor_selected", "seed"],
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
            receiveSignals: {
              START: "buyer::selector.assign.executor_selected",
              TIMEOUT: "buyer::(selector.assign.executor_selected +5s) & ~execution.main.cmp"
            },
            sendSignals: ["str", "cmp", "err"],
            executor: {
              supplierType: "zhixu",
              zhixuExecutorConfig: {
                schemaVersion: "uvp.dock.v1",
                target: { zhixu: "payment-zhixu", version: "1.2.0" },
                order: { idPolicy: "derived-v1" },
                inputMap: { START: "execute", TIMEOUT: "cancel" },
                signalMap: { str: "started", cmp: "completed" }
              }
            }
          }
        ]
      }
    ]
  }
};

function assertCompilationIssues(
  definition: ZhixuDefinition,
  expectedIssues: readonly RegExp[]
): void {
  try {
    compileZhixuHookPlan(definition, demoManifest);
  } catch (error) {
    assert.ok(error instanceof HookPlanCompilationError);
    const message = error.issues.join("; ");
    for (const expectedIssue of expectedIssues) {
      assert.match(message, expectedIssue);
    }
    return;
  }

  assert.fail("expected HookPlanCompilationError");
}

function compileZhixuHookPlanWithManifest(
  definition: ZhixuDefinition,
): ReturnType<typeof compileZhixuHookPlan> {
  return compileZhixuHookPlan(definition, demoManifest);
}

function topologyZhixu(stages: readonly ZhixuStage[]): ZhixuDefinition {
  return {
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: {
      name: "topology_zhixu",
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
          name: "flow",
          stages
        }
      ]
    }
  };
}

test("compiles internal HookPlan IR", () => {
  const plan = compileZhixuHookPlan(baseZhixu, demoManifest);
  const again = compileZhixuHookPlan(baseZhixu, demoManifest);

  assert.equal(plan.schemaVersion, "uvp.hookPlan.v2");
  assert.equal(plan.zhixuId, "zhixu-demo-001");
  assert.equal(plan.version, "7");
  assert.deepEqual(plan.platform, { type: "cloud" });
  assert.match(plan.planId, /^0x[0-9a-f]{64}$/);
  assert.match(plan.planHash, /^0x[0-9a-f]{64}$/);
  assert.equal(plan.planHash, again.planHash);
  assert.match(plan.planHash, /^0x[0-9a-f]{64}$/);
  assert.equal(plan.compiledHooks.length, 3);
  assert.deepEqual(plan.compiledHooks.map((hook) => hook.hookId), [
    "selector.assign#PLACE",
    "execution.main#START",
    "execution.main#TIMEOUT"
  ]);
  assert.deepEqual(plan.dependencyIndex["buyer::selector.assign.executor_selected"], [
    "execution.main#START",
    "execution.main#TIMEOUT"
  ]);
  assert.deepEqual(plan.dependencyIndex["buyer::execution.main.cmp"], [
    "execution.main#TIMEOUT"
  ]);
  // 种子入口钩子的自引用依赖（uvp-core 659a388 物化门语料对齐）。
  assert.deepEqual(plan.dependencyIndex["buyer::selector.assign.seed"], [
    "selector.assign#PLACE"
  ]);
  assert.deepEqual(plan.selectedStageBindings, [
    {
      selectorStageIdentifier: "selector.assign",
      targetStageIdentifier: "execution.main"
    }
  ]);
  assert.deepEqual(plan.signalCapabilities.map((capability) => [
    capability.stageIdentifier,
    capability.targetSource,
    capability.targetSignalName,
    capability.targetOrderRelation
  ]), [
    ["execution.main", "buyer", "execution.main.cmp", "current"],
    ["execution.main", "buyer", "execution.main.err", "current"],
    ["execution.main", "buyer", "execution.main.str", "current"],
    ["selector.assign", "buyer", "selector.assign.executor_selected", "current"],
    ["selector.assign", "buyer", "selector.assign.seed", "current"]
  ]);
  assert.equal(plan.executorRoutes["execution.main"], undefined);
  assert.equal(plan.dockRoutes.length, 1);
  assert.equal(plan.dockRoutes[0]?.local.stageIdentifier, "execution.main");
  assert.equal(plan.dockRoutes[0]?.entrance.localHookName, "START");
  assert.equal(plan.dockRoutes[0]?.entrance.targetPort, "execute");
  assert.equal(plan.dockRoutes[0]?.sourceSeam, "payment");
  assert.equal(
    plan.dockRoutesRoot,
    merkleRoot(plan.dockRoutes.map((route) => route.routeHash)),
  );
  assert.deepEqual(validateHookPlanArtifact(plan), []);
  assert.doesNotThrow(() => assertHookPlanArtifact(plan));
});

test("compiles source-qualified sendSignals as trigger-origin capabilities", () => {
  const plan = compileZhixuHookPlanWithManifest({
    ...baseZhixu,
    metadata: {
      name: "trigger_origin_signal_demo",
      annotations: {
        version: "7"
      }
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
              sendSignals: ["book::book.settlement_wait.cmp"],
              executor: {
                supplierType: "organization",
                supplierID: "settlement-operator"
              }
            }
          ]
        }
      ]
    }
  });

  assert.deepEqual(plan.signalCapabilities.map((capability) => [
    capability.stageIdentifier,
    capability.targetSource,
    capability.targetSignalName,
    capability.targetOrderRelation
  ]), [
    ["settlement.close", "book", "book.settlement_wait.cmp", "triggerOrigin"]
  ]);
});

test("preserves opaque platform metadata for future target schemas at the internal IR boundary", () => {
  const platform = {
    type: "blockchain",
    provider: "solana",
    network: "devnet",
    version: "todo",
    params: {
      programId: "future-program-placeholder"
    }
  };
  const plan = compileZhixuHookPlanWithManifest({
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      platform
    }
  });

  assert.deepEqual(plan.platform, platform);
  assert.deepEqual(validateHookPlanArtifact(plan), []);
});

test("validates HookPlan IR artifacts at the internal boundary", () => {
  const plan = compileZhixuHookPlan(baseZhixu, demoManifest);

  assert.deepEqual(validateHookPlanArtifact({ ...plan, schemaVersion: "wrong" }), [
    "schemaVersion must be uvp.hookPlan.v2"
  ]);
  assert.deepEqual(validateHookPlanArtifact({ ...plan, compiledHooks: [] }), [
    "dependencyIndex must match compiled hook dependencies"
  ]);
  assert.throws(
    () =>
      assertHookPlanArtifact({
        ...plan,
        dependencyIndex: {
          ...plan.dependencyIndex,
          "buyer::selector.assign.executor_selected": ["execution.main#START"]
        }
      }),
    HookPlanArtifactValidationError
  );
});

test("rejects invalid mint declarations", () => {
  const invalid: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        {
          name: "broken",
          stages: [
            {
              name: "main",
              source: "buyer",
              mint: "per-order" as unknown as "per-fact",
              executor: {
                supplierType: "organization",
                supplierID: "executor"
              }
            }
          ]
        }
      ]
    }
  };

  assertCompilationIssues(invalid, [
    /broken\.main\.mint only supports per-fact: per-order/
  ]);
});

test("mint stages accept single ANCHOR birth subscriptions and mark them order-trigger", () => {
  // 出生入口 hook：ANCHOR 订阅（出生事实由 registrar 命名空间提交，本身即判定），
  // 订阅编译为单条 SIGNAL 指令，链上带 order-trigger flag。
  const valid: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        {
          // 出生事实的发出方：buyer 域的 feeder 阶段（订阅类必须等于目标
          // 阶段的 source，且不得等于接收阶段自身的 source）。
          name: "feeder",
          stages: [
            {
              name: "gate",
              source: "buyer",
              sendSignals: ["ready"],
              executor: {
                supplierType: "organization",
                supplierID: "feeder-org"
              }
            }
          ]
        },
        {
          name: "broken",
          stages: [
            {
              name: "main",
              source: "runner",
              mint: "per-fact",
              receiveSignals: {
                START: "::ANCHOR(@buyer::feeder.gate.ready)"
              },
              sendSignals: ["str", "cmp"],
              executor: {
                supplierType: "organization",
                supplierID: "executor"
              }
            }
          ]
        }
      ]
    }
  };

  const plan = compileZhixuHookPlan(valid, demoManifest);
  const hook = plan.compiledHooks.find((item) => item.hookName === "START");
  assert.ok(hook, "birth entry hook missing");
  assert.equal(hook.orderTriggerKind, "mint");
  assert.equal(hook.emitReady, true);
});

test("rejects plain birth entries on mint stages (subscription only)", () => {
  const invalid: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        {
          name: "broken",
          stages: [
            {
              name: "main",
              source: "buyer",
              mint: "per-fact",
              receiveSignals: {
                START: "buyer::(broken.main.ready & broken.main.ack)"
              },
              sendSignals: ["ready", "ack"],
              executor: {
                supplierType: "organization",
                supplierID: "executor"
              }
            }
          ]
        }
      ]
    }
  };

  assertCompilationIssues(invalid, [
    /broken\.main\.receiveSignals\.START: mint stage accepts ANCHOR\(@…\) subscription entries only; plain birth-entry hooks are retired/
  ]);
});

test("accepts multi-anchor receive stages without an entry table", () => {
  const plan = compileZhixuHookPlanWithManifest({
    ...baseZhixu,
    metadata: {
      name: "orderbook_match",
      uid: "orderbook-match",
      annotations: {
        version: "7"
      }
    },
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        {
          // source 类是 zhixu 局部命名空间：hook 引用的 seller/buyer 必须有
          // 声明阶段承载（引用存在性 + 本域 source 校验）。
          name: "feed",
          stages: [
            {
              name: "quote",
              source: "seller",
              sendSignals: ["updated"],
              executor: {
                supplierType: "organization",
                supplierID: "seller-feed"
              }
            },
            {
              name: "bid",
              source: "buyer",
              sendSignals: ["updated"],
              executor: {
                supplierType: "organization",
                supplierID: "buyer-feed"
              }
            }
          ]
        },
        {
          name: "market",
          stages: [
            {
              name: "match",
              source: "orderbook",
              receiveSignals: {
                SELLER_UPDATED: "seller::feed.quote.updated",
                BUYER_UPDATED: "buyer::feed.bid.updated"
              },
              sendSignals: ["matched"],
              executor: {
                supplierType: "organization",
                supplierID: "matching-engine"
              }
            }
          ]
        }
      ]
    }
  });

  assert.deepEqual(
    plan.compiledHooks.map((hook) => [hook.hookName, hook.orderTriggerKind, hook.emitReady]),
    [
      ["BUYER_UPDATED", "none", true],
      ["SELLER_UPDATED", "none", true]
    ],
  );
  assert.deepEqual(
    plan.compiledHooks.flatMap((hook) => hook.dependencies.map((dependency) => `${dependency.source}::${dependency.signalName}`)).sort(),
    ["buyer::feed.bid.updated", "seller::feed.quote.updated"]
  );
});

test("accepts same-source hook expressions with the full hook DSL", () => {
  const plan = compileZhixuHookPlanWithManifest({
    ...baseZhixu,
    metadata: {
      name: "same_source_trigger_condition",
      uid: "same-source-trigger-condition",
      annotations: {
        version: "7"
      }
    },
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        ...baseZhixu.spec.taskPatterns,
        {
          name: "buyer",
          stages: [
            {
              name: "close",
              source: "buyer",
              receiveSignals: {
                ALL_DONE: "buyer::((selector.assign.executor_selected +5s) & ~execution.main.err) | execution.main.cmp"
              },
              sendSignals: ["allDone"],
              executor: {
                supplierType: "organization",
                supplierID: "buyer-executor"
              }
            }
          ]
        }
      ]
    }
  });

  const hook = plan.compiledHooks.find((item) => item.stageIdentifier === "buyer.close" && item.hookName === "ALL_DONE");
  assert.equal(hook?.orderTriggerKind, "none");
  assert.equal(hook?.emitReady, true);
  assert.deepEqual(
    hook?.dependencies.map((dependency) => `${dependency.kind}:${dependency.source}::${dependency.signalName}${dependency.delaySeconds ? `+${dependency.delaySeconds}` : ""}`).sort(),
    [
      "negative:buyer::execution.main.err",
      "positive:buyer::execution.main.cmp",
      "positive:buyer::selector.assign.executor_selected",
      "timer:buyer::selector.assign.executor_selected+5"
    ]
  );
});

test("rejects unbound stages", () => {
  const invalid: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        {
          name: "unbound",
          stages: [
            {
              name: "main",
              source: "buyer",
            }
          ]
        }
      ]
    }
  };

  assertCompilationIssues(invalid, [
    /unbound\.main has no static executor and is not reachable from a static executor through selectedStages/
  ]);
});

test("accepts executor-less selected-stage chains anchored by a static executor", () => {
  const plan = compileZhixuHookPlan(
    topologyZhixu([
      {
        name: "a",
        source: "buyer",
        selectedStages: ["flow.b"],
        executor: {
          supplierType: "organization",
          supplierID: "anchor-org"
        }
      },
      {
        name: "b",
        source: "buyer",
        selectedStages: ["flow.c"]
      },
      {
        name: "c",
        source: "buyer",
      }
    ])
  );

  assert.deepEqual(plan.selectedStageBindings, [
    {
      selectorStageIdentifier: "flow.a",
      targetStageIdentifier: "flow.b"
    },
    {
      selectorStageIdentifier: "flow.b",
      targetStageIdentifier: "flow.c"
    }
  ]);
  assert.equal(plan.executorRoutes["flow.a"]?.executor.supplierID, "anchor-org");
  assert.equal(plan.executorRoutes["flow.b"], undefined);
  assert.equal(plan.executorRoutes["flow.c"], undefined);
});

test("rejects executor-less selected cycles without a static anchor", () => {
  assertCompilationIssues(
    topologyZhixu([
      {
        name: "a",
        source: "buyer",
        selectedStages: ["flow.b"]
      },
      {
        name: "b",
        source: "buyer",
        selectedStages: ["flow.a"]
      }
    ]),
    [
      /flow\.a has no static executor and is not reachable from a static executor through selectedStages/,
      /flow\.b has no static executor and is not reachable from a static executor through selectedStages/
    ]
  );
});

test("rejects executor-less stages reached only through non-anchored selector chains", () => {
  assertCompilationIssues(
    topologyZhixu([
      {
        name: "a",
        source: "buyer",
        selectedStages: ["flow.b"]
      },
      {
        name: "b",
        source: "buyer",
      }
    ]),
    [
      /flow\.b has no static executor and is not reachable from a static executor through selectedStages/
    ]
  );
});

test("rejects unknown or duplicate selected stages", () => {
  const unknownSelected: ZhixuDefinition = {
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
                selectedStages: ["missing.stage"]
              }))
            }
      )
    }
  };
  const duplicateSelected: ZhixuDefinition = {
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
                selectedStages: ["execution.main", "execution.main"]
              }))
            }
      )
    }
  };

  assertCompilationIssues(unknownSelected, [
    /selector\.assign\.selectedStages references unknown stage missing\.stage/
  ]);
  assertCompilationIssues(duplicateSelected, [
    /selector\.assign\.selectedStages contains duplicate target execution\.main/
  ]);
});

test("rejects local hook references to unknown stages or signals", () => {
  const unknownStage: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        {
          name: "flow",
          stages: [
            {
              name: "start",
              source: "buyer",
              sendSignals: ["cmp"],
              executor: {
                supplierType: "organization",
                supplierID: "executor"
              }
            },
            {
              name: "wait",
              source: "buyer",
              receiveSignals: {
                READY: "buyer::flow.missing.cmp"
              },
              executor: {
                supplierType: "organization",
                supplierID: "executor"
              }
            }
          ]
        }
      ]
    }
  };
  const unknownSignal: ZhixuDefinition = {
    ...unknownStage,
    spec: {
      ...unknownStage.spec,
      taskPatterns: [
        {
          name: "flow",
          stages: [
            {
              name: "start",
              source: "buyer",
              sendSignals: ["cmp"],
              executor: {
                supplierType: "organization",
                supplierID: "executor"
              }
            },
            {
              name: "wait",
              source: "buyer",
              receiveSignals: {
                READY: "buyer::flow.start.err"
              },
              executor: {
                supplierType: "organization",
                supplierID: "executor"
              }
            }
          ]
        }
      ]
    }
  };

  assertCompilationIssues(unknownStage, [
    /flow\.wait\.receiveSignals\.READY references unknown stage flow\.missing/
  ]);
  assertCompilationIssues(unknownSignal, [
    /flow\.wait\.receiveSignals\.READY references unknown signal flow\.start\.err/
  ]);
});

test("rejects non-canonical zhixu executor config shapes", () => {
  // triggerEntrance 不是合法字段；signalMap 值必须是目标 signal 名而非
  // hook DSL 表达式；zhixu 类型 supplierID 不得指向另一个 Zhixu。
  const entranceConfig: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        {
          name: "peer",
          stages: [
            {
              name: "main",
              source: "buyer",
              executor: {
                supplierType: "zhixu",
                zhixuExecutorConfig: {
                  triggerEntrance: "flow.init"
                } as never
              }
            }
          ]
        }
      ]
    }
  };
  assertCompilationIssues(entranceConfig, [/D002.*triggerEntrance/]);

  const hookDslSignalMap: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        {
          name: "peer",
          stages: [
            {
              name: "main",
              source: "buyer",
              executor: {
                supplierType: "zhixu",
                zhixuExecutorConfig: {
                  schemaVersion: "uvp.dock.v1",
                  target: { zhixu: "payment-zhixu", version: "1.2.0" },
                  order: { idPolicy: "derived-v1" },
                  inputMap: { START: "execute" },
                  signalMap: {
                    str: "payment::payment_flow.init.str",
                    cmp: "completed"
                  }
                }
              }
            }
          ]
        }
      ]
    }
  };
  assertCompilationIssues(hookDslSignalMap, [/D006.*signalMap\.str/]);

  const crossZhixuSupplierId: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        {
          name: "peer",
          stages: [
            {
              name: "main",
              source: "buyer",
              executor: {
                supplierType: "zhixu",
                supplierID: "peer-zhixu",
                zhixuExecutorConfig: {
                  schemaVersion: "uvp.dock.v1",
                  target: { zhixu: "payment-zhixu", version: "1.2.0" },
                  order: { idPolicy: "derived-v1" },
                  inputMap: { START: "execute" },
                  signalMap: { str: "started", cmp: "completed" }
                }
              }
            }
          ]
        }
      ]
    }
  };
  assertCompilationIssues(crossZhixuSupplierId, [/D001/]);
});

test("rejects locally invalid dock executor configs", () => {
  const missingInputMap: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        {
          name: "peer",
          stages: [
            {
              name: "main",
              source: "buyer",
              sendSignals: ["str", "cmp"],
              executor: {
                supplierType: "zhixu",
                zhixuExecutorConfig: {
                  schemaVersion: "uvp.dock.v1",
                  target: { zhixu: "payment-zhixu", version: "1.2.0" },
                  order: { idPolicy: "derived-v1" },
                  signalMap: { str: "started", cmp: "completed" }
                } as never
              }
            }
          ]
        }
      ]
    }
  };
  assertCompilationIssues(missingInputMap, [/D005/]);

  const missingRequiredSignals: ZhixuDefinition = {
    ...missingInputMap,
    spec: {
      ...missingInputMap.spec,
      taskPatterns: [
        {
          name: "peer",
          stages: [
            {
              name: "main",
              source: "buyer",
              sendSignals: ["str", "cmp"],
              executor: {
                supplierType: "zhixu",
                zhixuExecutorConfig: {
                  schemaVersion: "uvp.dock.v1",
                  target: { zhixu: "payment-zhixu", version: "1.2.0" },
                  order: { idPolicy: "derived-v1" },
                  inputMap: { START: "execute" },
                  signalMap: { str: "started" }
                }
              }
            }
          ]
        }
      ]
    }
  };
  assertCompilationIssues(missingRequiredSignals, [/D007/]);

  const unknownLocalHook: ZhixuDefinition = {
    ...missingInputMap,
    spec: {
      ...missingInputMap.spec,
      taskPatterns: [
        {
          name: "peer",
          stages: [
            {
              name: "main",
              source: "buyer",
              receiveSignals: {
                START: "buyer::selector.assign.executor_selected"
              },
              sendSignals: ["str", "cmp"],
              executor: {
                supplierType: "zhixu",
                zhixuExecutorConfig: {
                  schemaVersion: "uvp.dock.v1",
                  target: { zhixu: "payment-zhixu", version: "1.2.0" },
                  order: { idPolicy: "derived-v1" },
                  inputMap: { MISSING: "execute" },
                  signalMap: { str: "started", cmp: "completed" }
                }
              }
            }
          ]
        }
      ]
    }
  };
  assertCompilationIssues(unknownLocalHook, [/D005.*inputMap\.MISSING/]);
});

test("rejects unresolved dock targets without a manifest", () => {
  assert.throws(
    () => compileZhixuHookPlan(baseZhixu),
    (error: unknown) => {
      assert.ok(error instanceof HookPlanCompilationError);
      assert.match(error.issues.join("; "), /UNRESOLVED_DOCK_TARGET/);
      return true;
    },
  );
});

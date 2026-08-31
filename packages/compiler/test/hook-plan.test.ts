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

function assertCompilationIssues(
  definition: ZhixuDefinition,
  expectedIssues: readonly RegExp[]
): void {
  try {
    compileZhixuHookPlan(definition);
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
  const plan = compileZhixuHookPlan(baseZhixu);
  const again = compileZhixuHookPlan(baseZhixu);

  assert.equal(plan.schemaVersion, "uvp.hookPlan.v1");
  assert.equal(plan.zhixuId, "zhixu-demo-001");
  assert.equal(plan.version, "7");
  assert.deepEqual(plan.platform, { type: "cloud" });
  assert.equal(plan.planId, "0x472081189619bb006814fed697f3d53ff187b5a852131ba1924bde825b0b9d6d");
  assert.equal(plan.planHash, "0x8ce322fcd43821fffe3f0144838d0b23e657a7d20acf6ee6de7bdb071a340752");
  assert.equal(plan.planHash, again.planHash);
  assert.match(plan.planHash, /^0x[0-9a-f]{64}$/);
  assert.equal(plan.compiledHooks.length, 4);
  assert.deepEqual(plan.compiledHooks.map((hook) => hook.hookId), [
    "execution.main#signalMap.cmp",
    "execution.main#signalMap.str",
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
    ["selector.assign", "buyer", "selector.assign.executor_selected", "current"]
  ]);
  assert.equal(plan.executorRoutes["execution.main"]?.executor.supplierID, "payment-zhixu");
  assert.deepEqual(validateHookPlanArtifact(plan), []);
  assert.doesNotThrow(() => assertHookPlanArtifact(plan));
});

test("compiles source-qualified sendSignals as trigger-origin capabilities", () => {
  const plan = compileZhixuHookPlan({
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
  const plan = compileZhixuHookPlan({
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
  const plan = compileZhixuHookPlan(baseZhixu);

  assert.deepEqual(validateHookPlanArtifact({ ...plan, schemaVersion: "wrong" }), [
    "schemaVersion must be uvp.hookPlan.v1"
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

test("mint stages accept single ANCHOR birth subscriptions and isTrigger them", () => {
  // 出生入口 hook：ANCHOR 订阅（出生事实由 registrar 命名空间提交，本身即判定），
  // 订阅编译为单条 SIGNAL 指令，链上 isTrigger=true。
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

  const plan = compileZhixuHookPlan(valid);
  const hook = plan.compiledHooks.find((item) => item.hookName === "START");
  assert.ok(hook, "birth entry hook missing");
  assert.equal(hook.isTrigger, true);
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
  const plan = compileZhixuHookPlan({
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

  assert.deepEqual(plan.compiledHooks.map((hook) => [hook.hookName, hook.isTrigger]), [
    ["BUYER_UPDATED", false],
    ["SELLER_UPDATED", false]
  ]);
  assert.deepEqual(
    plan.compiledHooks.flatMap((hook) => hook.dependencies.map((dependency) => `${dependency.source}::${dependency.signalName}`)).sort(),
    ["buyer::feed.bid.updated", "seller::feed.quote.updated"]
  );
});

test("accepts same-source hook expressions with the full hook DSL", () => {
  const plan = compileZhixuHookPlan({
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
  assert.equal(hook?.isTrigger, false);
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

test("rejects zhixu signal maps without one source", () => {
  const invalid: ZhixuDefinition = {
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
                  signalMap: {
                    str: "remote_a::init.main.str",
                    cmp: "remote_b::settle.main.cmp"
                  }
                }
              }
            }
          ]
        }
      ]
    }
  };

  assertCompilationIssues(invalid, [
    /peer\.main\.signalMap must reference one source/
  ]);
});

test("rejects missing or locally invalid zhixu signal maps", () => {
  const missingMap: ZhixuDefinition = {
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
                supplierID: "peer-zhixu"
              }
            }
          ]
        }
      ]
    }
  };
  const missingRequiredSignals: ZhixuDefinition = {
    ...missingMap,
    spec: {
      ...missingMap.spec,
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
                  signalMap: {
                    str: "remote::flow.main.str"
                  }
                }
              }
            }
          ]
        }
      ]
    }
  };
  const unknownLocalStage: ZhixuDefinition = {
    ...missingMap,
    spec: {
      ...missingMap.spec,
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
                  signalMap: {
                    str: "buyer::peer.missing.str",
                    cmp: "buyer::peer.missing.cmp"
                  }
                }
              }
            }
          ]
        }
      ]
    }
  };

  assertCompilationIssues(missingMap, [
    /peer\.main\.executor\.zhixuExecutorConfig\.signalMap is required/
  ]);
  assertCompilationIssues(missingRequiredSignals, [
    /peer\.main\.signalMap must contain str and cmp/
  ]);
  assertCompilationIssues(unknownLocalStage, [
    /peer\.main\.executor\.zhixuExecutorConfig\.signalMap\.str references unknown stage peer\.missing/
  ]);
});

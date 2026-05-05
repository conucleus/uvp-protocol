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
      name: "topology_zhixu"
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
  assert.equal(plan.planHash, "0x4964b6a9999d90aca565c1c555db99d428a606868439ecad7b4d8debde338a64");
  assert.equal(plan.planHash, again.planHash);
  assert.match(plan.planHash, /^0x[0-9a-f]{64}$/);
  assert.equal(plan.compiledHooks.length, 5);
  assert.deepEqual(plan.compiledHooks.map((hook) => hook.hookId), [
    "selector.assign#TRIGGER",
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

test("rejects missing trigger hook references", () => {
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
              trigger: ["MISSING"],
              receiveSignals: {
                TRIGGER: "::OUTSIDE"
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

  assertCompilationIssues(invalid, [
    /broken\.main\.trigger references missing receiveSignals key MISSING/
  ]);
});

test("rejects string trigger shorthand at runtime boundary", () => {
  const invalid = {
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
              trigger: "TRIGGER",
              receiveSignals: {
                TRIGGER: "::OUTSIDE"
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
  } as unknown as ZhixuDefinition;

  assertCompilationIssues(invalid, [
    /broken\.main\.trigger must be a non-empty receiveSignals key array/
  ]);
});

test("accepts trigger key list with multiple wake anchors", () => {
  const plan = compileZhixuHookPlan({
    ...baseZhixu,
    metadata: {
      name: "orderbook_match",
      uid: "orderbook-match"
    },
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        {
          name: "market",
          stages: [
            {
              name: "match",
              source: "orderbook",
              trigger: ["SELLER_UPDATED", "BUYER_UPDATED"],
              receiveSignals: {
                SELLER_UPDATED: "seller::order.quote.updated",
                BUYER_UPDATED: "buyer::order.bid.updated"
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
    ["BUYER_UPDATED", true],
    ["SELLER_UPDATED", true]
  ]);
  assert.deepEqual(
    plan.compiledHooks.flatMap((hook) => hook.dependencies.map((dependency) => `${dependency.source}::${dependency.signalName}`)).sort(),
    ["buyer::order.bid.updated", "seller::order.quote.updated"]
  );
});

test("accepts same-source trigger hook expressions with the full hook DSL", () => {
  const plan = compileZhixuHookPlan({
    ...baseZhixu,
    metadata: {
      name: "same_source_trigger_condition",
      uid: "same-source-trigger-condition"
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
              trigger: ["ALL_DONE"],
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
  assert.equal(hook?.isTrigger, true);
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
              trigger: ["TRIGGER"],
              receiveSignals: {
                TRIGGER: "::OUTSIDE"
              }
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
        trigger: ["TRIGGER"],
        receiveSignals: {
          TRIGGER: "::OUTSIDE"
        },
        selectedStages: ["flow.b"],
        executor: {
          supplierType: "organization",
          supplierID: "anchor-org"
        }
      },
      {
        name: "b",
        source: "buyer",
        trigger: ["TRIGGER"],
        receiveSignals: {
          TRIGGER: "::OUTSIDE"
        },
        selectedStages: ["flow.c"]
      },
      {
        name: "c",
        source: "buyer",
        trigger: ["TRIGGER"],
        receiveSignals: {
          TRIGGER: "::OUTSIDE"
        }
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
        trigger: ["TRIGGER"],
        receiveSignals: {
          TRIGGER: "::OUTSIDE"
        },
        selectedStages: ["flow.b"]
      },
      {
        name: "b",
        source: "buyer",
        trigger: ["TRIGGER"],
        receiveSignals: {
          TRIGGER: "::OUTSIDE"
        },
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
        trigger: ["TRIGGER"],
        receiveSignals: {
          TRIGGER: "::OUTSIDE"
        },
        selectedStages: ["flow.b"]
      },
      {
        name: "b",
        source: "buyer",
        trigger: ["TRIGGER"],
        receiveSignals: {
          TRIGGER: "::OUTSIDE"
        }
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
              trigger: ["TRIGGER"],
              receiveSignals: {
                TRIGGER: "::OUTSIDE"
              },
              sendSignals: ["cmp"],
              executor: {
                supplierType: "organization",
                supplierID: "executor"
              }
            },
            {
              name: "wait",
              source: "buyer",
              trigger: ["READY"],
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
              trigger: ["TRIGGER"],
              receiveSignals: {
                TRIGGER: "::OUTSIDE"
              },
              sendSignals: ["cmp"],
              executor: {
                supplierType: "organization",
                supplierID: "executor"
              }
            },
            {
              name: "wait",
              source: "buyer",
              trigger: ["READY"],
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
              trigger: ["TRIGGER"],
              receiveSignals: {
                TRIGGER: "::OUTSIDE"
              },
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
              trigger: ["TRIGGER"],
              receiveSignals: {
                TRIGGER: "::OUTSIDE"
              },
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
              trigger: ["TRIGGER"],
              receiveSignals: {
                TRIGGER: "::OUTSIDE"
              },
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
              trigger: ["TRIGGER"],
              receiveSignals: {
                TRIGGER: "::OUTSIDE"
              },
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

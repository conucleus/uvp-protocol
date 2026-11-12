import assert from "node:assert/strict";
import test from "node:test";
import {
  assertHookPlanArtifact,
  compileZhixuHookPlan,
  compareCanonicalKey,
  HookPlanCompilationError,
  HookPlanArtifactValidationError,
  validateHookPlanArtifact,
} from "../src/hook-plan.js";
import { hookPlanHashOf, planIdOf } from "../src/hook-plan/assemble.js";
import type {
  HookPlanArtifact,
  ZhixuDefinition,
  ZhixuStage,
} from "../src/types/index.js";

function resign<A extends { planHash: string }>(artifact: A): A {
  return {
    ...artifact,
    planHash: hookPlanHashOf(artifact as unknown as HookPlanArtifact),
  };
}

const baseZhixu: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: {
    name: "demo_zhixu"
  },
  spec: {
    platform: {
      type: "cloud"
    },
    nucleation: {
      id: "core"
    },
    stages: [
      {
        name: "assign",
        source: "buyer",
        selectedStages: ["main"],
        receiveSignals: {
          PLACE: "buyer::assign.seed"
        },
        sendSignals: [{ name: "executor_selected" }, { name: "seed" }],
        executor: {
          supplierType: "organization",
          supplierID: "selector-org"
        }
      },
      {
        name: "main",
        source: "buyer",
        receiveSignals: {
          START: "buyer::assign.executor_selected",
          TIMEOUT: "buyer::(assign.executor_selected +5s) & ~main.cmp"
        },
        sendSignals: [{ name: "str" }, { name: "cmp" }, { name: "err" }],
        executor: {
          supplierType: "organization",
          supplierID: "work-org"
        }
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
      stages
    }
  };
}

test("compiles internal HookPlan IR", () => {
  const plan = compileZhixuHookPlan(baseZhixu);

  assert.equal(plan.schemaVersion, "uvp.hookPlan.v7");
  assert.match(plan.zhixuId, /^zx-[0-9a-f]{32}$/);
  assert.deepEqual(plan.platform, { type: "cloud" });
  assert.match(plan.planId, /^0x[0-9a-f]{64}$/);
  assert.match(plan.planHash, /^0x[0-9a-f]{64}$/);
  assert.equal(plan.compiledHooks.length, 3);
  assert.deepEqual(plan.compiledHooks.map((hook) => hook.hookId), [
    "assign#PLACE",
    "main#START",
    "main#TIMEOUT"
  ]);
  assert.deepEqual(
    plan.compiledHooks.map((hook) => hook.dockExecutor),
    [false, false, false],
  );
  assert.deepEqual(plan.dependencyIndex["buyer::assign.executor_selected"], [
    "main#START",
    "main#TIMEOUT"
  ]);
  assert.deepEqual(plan.dependencyIndex["buyer::main.cmp"], [
    "main#TIMEOUT"
  ]);
  assert.deepEqual(plan.dependencyIndex["buyer::assign.seed"], [
    "assign#PLACE"
  ]);
  assert.deepEqual(plan.selectedStageBindings, [
    {
      selectorStageIdentifier: "assign",
      targetStageIdentifier: "main"
    }
  ]);
  assert.deepEqual(plan.signalCapabilities.map((capability) => [
    capability.stageIdentifier,
    capability.targetSource,
    capability.targetSignalName,
    capability.targetOrderRelation
  ]), [
    ["assign", "buyer", "assign.executor_selected", "current"],
    ["assign", "buyer", "assign.seed", "current"],
    ["main", "buyer", "main.cmp", "current"],
    ["main", "buyer", "main.err", "current"],
    ["main", "buyer", "main.str", "current"]
  ]);
  assert.equal(plan.executorRoutes["main"]?.stageIdentifier, "main");
  assert.equal(plan.executorRoutes["assign"]?.stageIdentifier, "assign");
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

test("planId preimage drops empty platform params across compile/validate calibers", () => {
  const withoutParams = compileZhixuHookPlan(baseZhixu);
  const withEmptyParams = compileZhixuHookPlan({
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      platform: { ...baseZhixu.spec.platform, params: {} },
    },
  });
  assert.deepEqual(withEmptyParams.platform, withoutParams.platform);
  assert.notEqual(withEmptyParams.zhixuId, withoutParams.zhixuId);
  assert.equal(
    planIdOf(withEmptyParams.zhixuId, withEmptyParams.zhixuName, {
      ...withEmptyParams.platform,
      params: {},
    }),
    withEmptyParams.planId,
  );

  const carryingEmptyParams: HookPlanArtifact = {
    ...withoutParams,
    platform: { ...withoutParams.platform, params: {} },
  };
  assert.deepEqual(validateHookPlanArtifact(resign(carryingEmptyParams)), []);
});

test("validates HookPlan IR artifacts at the internal boundary", () => {
  const plan = compileZhixuHookPlan(baseZhixu);

  assert.deepEqual(
    validateHookPlanArtifact(resign({ ...plan, schemaVersion: "wrong" })),
    ["schemaVersion must be uvp.hookPlan.v7"]
  );
  assert.deepEqual(
    validateHookPlanArtifact(
      resign({ ...plan, compiledHooks: [], signalCapabilities: [], selectedStageBindings: [] }),
    ),
    ["dependencyIndex must match compiled hook dependencies"]
  );
  assert.throws(
    () =>
      assertHookPlanArtifact({
        ...plan,
        dependencyIndex: {
          ...plan.dependencyIndex,
          "buyer::assign.executor_selected": ["main#START"]
        }
      }),
    HookPlanArtifactValidationError
  );
});

test("rejects artifacts tampering compiledHooks/planId/source against the carried commitments", () => {
  const plan = compileZhixuHookPlan(baseZhixu);

  const tampered = {
    ...plan,
    compiledHooks: plan.compiledHooks.map((hook) =>
      hook.hookId === plan.compiledHooks[0]!.hookId
        ? { ...hook, rawExpression: "tampered" }
        : hook,
    ),
  };
  assert.deepEqual(validateHookPlanArtifact(tampered), [
    "planHash must match the recomputed H(uvp:hook-plan-artifact:v1; payload) over the carried fields",
  ]);
  assert.deepEqual(validateHookPlanArtifact(resign(tampered)), []);

  const tamperedPlanId = { ...plan, planId: `0x${"11".repeat(32)}` };
  assert.ok(
    validateHookPlanArtifact(tamperedPlanId).includes(
      "planId must match the recomputed H(uvp:hook-plan-id:v1; compiler/platform/zhixuId/zhixuName)",
    ),
  );

  assert.deepEqual(validateHookPlanArtifact({ ...plan, source: undefined }), [
    "source is required (the canonical annotation-stripped definition snapshot in the planHash preimage)",
  ]);
});

test("rejects metadata stage references outside the hooks stage set (stage existence mirror)", () => {
  const plan = compileZhixuHookPlan(baseZhixu);
  const danglingStageIssues = (issues: readonly string[]): readonly string[] =>
    issues.filter((issue) => /references stage .* which has no compiled hooks/.test(issue));

  assert.deepEqual(danglingStageIssues(validateHookPlanArtifact(plan)), []);

  const danglingCapability = resign({
    ...plan,
    signalCapabilities: [
      ...plan.signalCapabilities,
      {
        stageIdentifier: "stage",
        source: "ghost",
        declaredSignal: "g",
        targetSource: "buyer",
        targetSignalName: "main.cmp",
        targetOrderRelation: "current",
      },
    ],
  });
  assert.deepEqual(danglingStageIssues(validateHookPlanArtifact(danglingCapability)), [
    "signalCapabilities[" + plan.signalCapabilities.length + "].stageIdentifier references stage stage "
      + "which has no compiled hooks; on-chain stage existence is established solely by hook registration, "
      + "so capability and binding leaves anchored to this stage can never be materialized or proven — "
      + "reference a stage declared by at least one hook",
  ]);

  const danglingBinding = resign({
    ...plan,
    selectedStageBindings: [
      ...plan.selectedStageBindings,
      {
        selectorStageIdentifier: "assign",
        targetStageIdentifier: "target",
      },
    ],
  });
  assert.deepEqual(danglingStageIssues(validateHookPlanArtifact(danglingBinding)), [
    "selectedStageBindings[" + plan.selectedStageBindings.length + "].targetStageIdentifier references stage target "
      + "which has no compiled hooks; on-chain stage existence is established solely by hook registration, "
      + "so capability and binding leaves anchored to this stage can never be materialized or proven — "
      + "reference a stage declared by at least one hook",
  ]);
});

test("dependencyIndex ordering follows code-point (Rust byte) order for astral-plane hooks", () => {
  const astralStage = "\u{1F600}";
  const bmpStage = "\u{FFFD}";
  const astralHook = `${astralStage}#W`;
  const bmpHook = `${bmpStage}#W`;
  assert.ok(astralHook < bmpHook, "fixture guard: UTF-16 order must differ here");

  const plan = compileZhixuHookPlan(baseZhixu);
  const hookWith = (
    hookId: string,
    stageIdentifier: string,
    dependencies: readonly object[],
  ) => {
    const { route: _route, ...template } = plan.compiledHooks[0]!;
    return {
      ...template,
      hookId,
      stageIdentifier,
      hookName: "W",
      dependencies,
    };
  };
  const artifact = {
    ...plan,
    signalCapabilities: [],
    selectedStageBindings: [],
    compiledHooks: [
      hookWith(bmpHook, bmpStage, [
        { kind: "positive", source: "buyer", signalName: "shared.sig" },
        { kind: "positive", source: "\u{FFFD}", signalName: "sig" },
      ]),
      hookWith(astralHook, astralStage, [
        { kind: "positive", source: "buyer", signalName: "shared.sig" },
        { kind: "positive", source: "\u{1F600}", signalName: "sig" },
      ]),
    ],
  };
  const dependencyKey = (source: string, signalName: string) =>
    `${source}::${signalName}`;

  assert.doesNotThrow(() =>
    assertHookPlanArtifact(
      resign({
        ...artifact,
        dependencyIndex: {
          [dependencyKey("buyer", "shared.sig")]: [bmpHook, astralHook],
          [dependencyKey("\u{FFFD}", "sig")]: [bmpHook],
          [dependencyKey("\u{1F600}", "sig")]: [astralHook],
        },
      })
    )
  );

  assert.ok(
    validateHookPlanArtifact({
      ...artifact,
      dependencyIndex: {
        [dependencyKey("buyer", "shared.sig")]: [astralHook, bmpHook],
        [dependencyKey("\u{FFFD}", "sig")]: [bmpHook],
        [dependencyKey("\u{1F600}", "sig")]: [astralHook],
      },
    }).includes("dependencyIndex must match compiled hook dependencies")
  );

  assert.ok(
    validateHookPlanArtifact({
      ...artifact,
      dependencyIndex: {
        [dependencyKey("buyer", "shared.sig")]: [bmpHook, astralHook],
        [dependencyKey("\u{1F600}", "sig")]: [astralHook],
        [dependencyKey("\u{FFFD}", "sig")]: [bmpHook],
      },
    }).includes("dependencyIndex must match compiled hook dependencies")
  );
});

test("accepts multi-anchor receive stages without an entry table", () => {
  const plan = compileZhixuHookPlan({
    ...baseZhixu,
    metadata: {
      name: "orderbook_match"
    },
    spec: {
      ...baseZhixu.spec,
      stages: [
        {
          name: "quote",
          source: "seller",
          receiveSignals: {
            PLACE: "seller::quote.seed"
          },
          sendSignals: [{ name: "updated" }, { name: "seed" }],
          executor: {
            supplierType: "organization",
            supplierID: "seller-feed"
          }
        },
        {
          name: "bid",
          source: "buyer",
          receiveSignals: {
            PLACE: "buyer::bid.seed"
          },
          sendSignals: [{ name: "updated" }, { name: "seed" }],
          executor: {
            supplierType: "organization",
            supplierID: "buyer-feed"
          }
        },
        {
          name: "match",
          source: "orderbook",
          receiveSignals: {
            SELLER_UPDATED: "seller::quote.updated",
            BUYER_UPDATED: "buyer::bid.updated"
          },
          sendSignals: [{ name: "matched" }],
          executor: {
            supplierType: "organization",
            supplierID: "matching-engine"
          }
        }
      ]
    }
  });

  const matchHooks = plan.compiledHooks.filter(
    (hook) => hook.stageIdentifier === "match"
  );
  assert.deepEqual(
    matchHooks.map((hook) => [hook.hookName, hook.orderTriggerKind, hook.emitReady]),
    [
      ["BUYER_UPDATED", "none", true],
      ["SELLER_UPDATED", "none", true]
    ],
  );
  assert.deepEqual(
    matchHooks.flatMap((hook) => hook.dependencies.map((dependency) => `${dependency.source}::${dependency.signalName}`)).sort(),
    ["buyer::bid.updated", "seller::quote.updated"]
  );
});

test("accepts same-source hook expressions with the full hook DSL", () => {
  const plan = compileZhixuHookPlan({
    ...baseZhixu,
    metadata: {
      name: "same_source_trigger_condition"
    },
    spec: {
      ...baseZhixu.spec,
      stages: [
        ...baseZhixu.spec.stages,
        {
          name: "close",
              source: "buyer",
              receiveSignals: {
                ALL_DONE: "buyer::((assign.executor_selected +5s) & ~main.err) | main.cmp"
              },
              sendSignals: [{ name: "allDone" }],
              executor: {
                supplierType: "organization",
                supplierID: "buyer-executor"
              }
            }]
    }
  });

  const hook = plan.compiledHooks.find((item) => item.stageIdentifier === "close" && item.hookName === "ALL_DONE");
  assert.equal(hook?.orderTriggerKind, "none");
  assert.equal(hook?.emitReady, true);
  assert.deepEqual(
    hook?.dependencies.map((dependency) => `${dependency.kind}:${dependency.source}::${dependency.signalName}${dependency.delaySeconds ? `+${dependency.delaySeconds}` : ""}`).sort(),
    [
      "negative:buyer::main.err",
      "positive:buyer::assign.executor_selected",
      "positive:buyer::main.cmp",
      "timer:buyer::assign.executor_selected+5"
    ]
  );
});

test("rejects unbound stages", () => {
  const invalid: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: [{
              name: "main",
              source: "buyer",
            }]
    }
  };

  assertCompilationIssues(invalid, [
    /main has no static executor and is not reachable from a static executor through selectedStages/
  ]);
});

test("rejects executor-less selected-stage chains at the materialization gate", () => {
  assertCompilationIssues(
    topologyZhixu([
      {
        name: "a",
        source: "buyer",
        selectedStages: ["b"],
        executor: {
          supplierType: "organization",
          supplierID: "anchor-org"
        }
      },
      {
        name: "b",
        source: "buyer",
        selectedStages: ["c"]
      },
      {
        name: "c",
        source: "buyer",
      }
    ]),
    [
      /a declares no receiveSignals and no trigger and compiles to zero hooks/,
      /b declares no receiveSignals and no trigger and compiles to zero hooks/,
      /c declares no receiveSignals and no trigger and compiles to zero hooks/,
    ]
  );

  const plan = compileZhixuHookPlan(
    topologyZhixu([
      {
        name: "a",
        source: "buyer",
        selectedStages: ["b"],
        receiveSignals: { PLACE: "buyer::a.seed" },
        sendSignals: [{ name: "seed" }],
        executor: {
          supplierType: "organization",
          supplierID: "anchor-org"
        }
      },
      {
        name: "b",
        source: "buyer",
        selectedStages: ["c"],
        receiveSignals: { PLACE: "buyer::b.seed" },
        sendSignals: [{ name: "seed" }],
        executor: {
          supplierType: "organization",
          supplierID: "b-org"
        }
      },
      {
        name: "c",
        source: "buyer",
        receiveSignals: { PLACE: "buyer::c.seed" },
        sendSignals: [{ name: "seed" }],
        executor: {
          supplierType: "organization",
          supplierID: "c-org"
        }
      }
    ])
  );

  assert.deepEqual(plan.selectedStageBindings, [
    {
      selectorStageIdentifier: "a",
      targetStageIdentifier: "b"
    },
    {
      selectorStageIdentifier: "b",
      targetStageIdentifier: "c"
    }
  ]);
  assert.equal(plan.executorRoutes["a"]?.executor.supplierID, "anchor-org");
  assert.ok(plan.executorRoutes["b"]);
  assert.ok(plan.executorRoutes["c"]);
});

test("rejects executor-less selected cycles without a static anchor", () => {
  assertCompilationIssues(
    topologyZhixu([
      {
        name: "a",
        source: "buyer",
        selectedStages: ["b"]
      },
      {
        name: "b",
        source: "buyer",
        selectedStages: ["a"]
      }
    ]),
    [
      /a has no static executor and is not reachable from a static executor through selectedStages/,
      /b has no static executor and is not reachable from a static executor through selectedStages/
    ]
  );
});

test("rejects executor-less stages reached only through non-anchored selector chains", () => {
  assertCompilationIssues(
    topologyZhixu([
      {
        name: "a",
        source: "buyer",
        selectedStages: ["b"]
      },
      {
        name: "b",
        source: "buyer",
      }
    ]),
    [
      /b has no static executor and is not reachable from a static executor through selectedStages/
    ]
  );
});

test("rejects unknown or duplicate selected stages", () => {
  const unknownSelected: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: baseZhixu.spec.stages.map((stage) => ({
        ...stage,
        selectedStages: ["stage"]
      }))
    }
  };
  const duplicateSelected: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: baseZhixu.spec.stages.map((stage) => ({
        ...stage,
        selectedStages: ["main", "main"]
      }))
    }
  };

  assertCompilationIssues(unknownSelected, [
    /assign.selectedStages references unknown stage stage/
  ]);
  assertCompilationIssues(duplicateSelected, [
    /assign.selectedStages contains duplicate target main/
  ]);
});

test("rejects local hook references to unknown stages or signals", () => {
  const unknownStage: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: [{
              name: "start",
              source: "buyer",
              sendSignals: [{ name: "cmp" }],
              executor: {
                supplierType: "organization",
                supplierID: "executor"
              }
            },
            {
              name: "wait",
              source: "buyer",
              receiveSignals: {
                READY: "buyer::missing.cmp"
              },
              executor: {
                supplierType: "organization",
                supplierID: "executor"
              }
            }]
    }
  };
  const unknownSignal: ZhixuDefinition = {
    ...unknownStage,
    spec: {
      ...unknownStage.spec,
      stages: [{
              name: "start",
              source: "buyer",
              sendSignals: [{ name: "cmp" }],
              executor: {
                supplierType: "organization",
                supplierID: "executor"
              }
            },
            {
              name: "wait",
              source: "buyer",
              receiveSignals: {
                READY: "buyer::start.err"
              },
              executor: {
                supplierType: "organization",
                supplierID: "executor"
              }
            }]
    }
  };

  assertCompilationIssues(unknownStage, [
    /wait.receiveSignals.READY references unknown stage missing/
  ]);
  assertCompilationIssues(unknownSignal, [
    /wait.receiveSignals.READY references unknown signal start.err/
  ]);
});


test("rejects undeclared extra fields on HookPlan artifacts", () => {
  const plan = compileZhixuHookPlan(baseZhixu);
  const withExtra = resign({ ...plan, note: "hand-added" });
  assert.deepEqual(validateHookPlanArtifact(withExtra), [
    "unknown field `note` on the artifact — planHash does not cover undeclared fields, so the artifact would not be the plan's unique byte form; remove it or recompile",
  ]);
});

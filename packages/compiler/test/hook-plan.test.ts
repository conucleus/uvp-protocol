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
  hookPlanHashOf,
  prepareDockResolution,
} from "../src/dock-commitments.js";
import {
  type DockResolutionManifest,
  type HookPlanArtifact,
  type ZhixuDefinition,
  type ZhixuStage
} from "../src/types/index.js";
import {
  dockDemoResolutionManifest,
  dockDemoTargetName,
  dockSourcingParentDefinition,
} from "./dock-demo.js";
import {
  definitionRefHash,
  definitionUid,
  EMPTY_MERKLE_ROOT,
  merkleRoot,
} from "../src/dock.js";

const demoManifest = dockDemoResolutionManifest();

/** 变异制品后按载荷重签 planHash（承诺重算测试之外的形状测试需要）。 */
function resign(artifact: HookPlanArtifact): HookPlanArtifact {
  return { ...artifact, planHash: hookPlanHashOf(artifact) };
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
                // mode=new 恰好一条 input 绑定（出生锚）；TIMEOUT 是本地
                // receiveSignals 通道但不参与 inputMap。
                target: { zhixu: dockDemoTargetName },
                interface: "production_service",
                order: { mode: "new" },
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
  const plan = compileZhixuHookPlan(baseZhixu, demoManifest);
  const again = compileZhixuHookPlan(baseZhixu, demoManifest);

  assert.equal(plan.schemaVersion, "uvp.hookPlan.v2");
  // zhixuId = 定义内容派生身份（PRD_102 §5），不再有作者手写 uid。
  assert.match(plan.zhixuId, /^zx-[0-9a-f]{32}$/);
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
  assert.equal(plan.dockRoutes[0]?.orderMode, "new");
  assert.equal(plan.dockRoutes[0]?.target.interfaceName, "production_service");
  assert.equal(plan.dockRoutes[0]?.inputBindings[0]?.localHookName, "START");
  assert.equal(plan.dockRoutes[0]?.inputBindings[0]?.targetPort, "execute");
  assert.equal(plan.dockRoutes[0]?.sourceSeam, "factory");
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
      name: "trigger_origin_signal_demo"
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
              // PLACE 为自发种子入口钩子（uvp-core 物化门：零 hook 阶段
              // 永不可物化、sendSignals 无钩子可挂）。
              receiveSignals: {
                PLACE: "trade::settlement.close.seed"
              },
              sendSignals: ["seed", "book::book.settlement_wait.cmp"],
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

  // 种子 capability 是物化门的伴随产物，断言聚焦 triggerOrigin 投影。
  assert.deepEqual(
    plan.signalCapabilities
      .filter((capability) => capability.targetOrderRelation === "triggerOrigin")
      .map((capability) => [
        capability.stageIdentifier,
        capability.targetSource,
        capability.targetSignalName,
        capability.targetOrderRelation
      ]),
    [
      ["settlement.close", "book", "book.settlement_wait.cmp", "triggerOrigin"]
    ],
  );
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

  // 变异后按载荷重签 planHash，让断言聚焦在字段本身的形状问题上
  // （planHash 不重签的篡改形态在下方专门的承诺重算测试里）。
  assert.deepEqual(
    validateHookPlanArtifact(resign({ ...plan, schemaVersion: "wrong" })),
    ["schemaVersion must be uvp.hookPlan.v2"]
  );
  assert.deepEqual(
    validateHookPlanArtifact(resign({ ...plan, compiledHooks: [] })),
    ["dependencyIndex must match compiled hook dependencies"]
  );
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

test("rejects artifacts tampering compiledHooks/planId/source against the carried commitments", () => {
  const plan = compileZhixuHookPlan(baseZhixu, demoManifest);

  // 篡改 compiledHooks 保留旧 planHash → 载荷重算不匹配，反序列化边界即拒，
  // 不等链上（0318BUG-3）。
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
  // 同一篡改按载荷重签 → 零 issue：重算装配（hookPlanPayloadForHash）与
  // 产出侧逐字段同构，hashCanonical 幂等。
  assert.deepEqual(validateHookPlanArtifact(resign(tampered)), []);

  // 篡改 planId → planId 重算不匹配（且载荷变化连带 planHash 不匹配）。
  const tamperedPlanId = { ...plan, planId: `0x${"11".repeat(32)}` };
  assert.ok(
    validateHookPlanArtifact(tamperedPlanId).includes(
      "planId must match the recomputed H(uvp:hook-plan-id:v1; compiler/platform/zhixuId/zhixuName)",
    ),
  );

  // 缺 source（旧版制品形状）→ 显式拒绝，且不做 planHash 重算。
  assert.deepEqual(validateHookPlanArtifact({ ...plan, source: undefined }), [
    "source is required (the canonical annotation-stripped definition snapshot in the planHash preimage)",
  ]);
});

function resolutionEntryWithStaticEdge(withEdges: boolean) {
  // 内嵌定义静态引用 dockDemoTargetName（zhixu 执行器），manifest 声明面
  // 必须等价携带该出边，否则 core D015 的启动图环检测被绕过（0830F5）。
  const definition: ZhixuDefinition = {
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: { name: "edge_intermediary" },
    spec: {
      platform: { type: "cloud" },
      nucleation: { id: "edge-core" },
      taskPatterns: [
        {
          name: "relay",
          stages: [
            {
              name: "forward",
              source: "operator",
              receiveSignals: { GO: "operator::relay.forward.go" },
              sendSignals: ["done"],
              executor: {
                supplierType: "zhixu",
                zhixuExecutorConfig: {
                  target: { zhixu: dockDemoTargetName },
                  interface: "production_evidence",
                  order: { mode: "existing" },
                  signalMap: { cmp: "scrap_declared" },
                },
              },
            },
          ],
        },
      ],
    },
  };
  const uid = definitionUid(definition);
  return {
    zhixu: uid,
    definition,
    definitionRefHash: definitionRefHash(uid),
    artifactHash: `0x${"ab".repeat(32)}` as `0x${string}`,
    published: true,
    interfaces: [],
    ...(withEdges ? { dockEdges: [{ target: dockDemoTargetName }] } : {}),
  };
}

test("rejects resolution manifests whose dockEdges diverge from the embedded definition", () => {
  const manifest = (withEdges: boolean): DockResolutionManifest => ({
    schemaVersion: "uvp.dock.resolution.v2",
    definitions: [resolutionEntryWithStaticEdge(withEdges)],
  });

  // 漏报出边 = 绕过 D015 环检测的形态，编译期拒绝。
  assert.throws(
    () => prepareDockResolution(manifest(false)),
    /dockEdges must declare static target "friction_wheel_production"/,
  );
  // 等价声明 → 放行。
  assert.doesNotThrow(() => prepareDockResolution(manifest(true)));
  // 多声明（定义未静态引用的出边）同样拒绝。
  assert.throws(
    () =>
      prepareDockResolution({
        schemaVersion: "uvp.dock.resolution.v2",
        definitions: [
          {
            ...resolutionEntryWithStaticEdge(true),
            dockEdges: [
              { target: dockDemoTargetName },
              { target: "phantom_target" },
            ],
          },
        ],
      }),
    /dockEdges declares target "phantom_target" which the embedded definition never statically references/,
  );
  // 重复出边拒绝。
  assert.throws(
    () =>
      prepareDockResolution({
        schemaVersion: "uvp.dock.resolution.v2",
        definitions: [
          {
            ...resolutionEntryWithStaticEdge(true),
            dockEdges: [
              { target: dockDemoTargetName },
              { target: dockDemoTargetName },
            ],
          },
        ],
      }),
    /duplicates target "friction_wheel_production"/,
  );
});

test("rejects resolution manifests whose evmPlanId diverges from the embedded definition", () => {
  assert.throws(
    () =>
      prepareDockResolution({
        schemaVersion: "uvp.dock.resolution.v2",
        definitions: [
          {
            ...resolutionEntryWithStaticEdge(true),
            evmPlanId: `0x${"cd".repeat(32)}` as `0x${string}`,
          },
        ],
      }),
    /evmPlanId does not match the recomputed/,
  );
});

test("dock route commitment recomputation fails closed on missing identity fields", () => {
  const plan = compileZhixuHookPlan(
    dockSourcingParentDefinition(dockDemoTargetName),
    demoManifest,
  );
  const stripped = {
    ...plan,
    dockRoutes: plan.dockRoutes.map((route, index) =>
      index === 0
        ? {
            ...route,
            local: { ...route.local, definitionRefHash: undefined as unknown as string },
          }
        : route,
    ),
  };
  const issues = validateHookPlanArtifact(stripped);
  assert.ok(
    issues.includes(
      "artifact.dockRoutes[0].local.definitionRefHash must be a lowercase 32-byte hex hash",
    ),
    `expected explicit fail-closed issue, got: ${JSON.stringify(issues)}`,
  );
});

test("dependencyIndex ordering follows code-point (Rust byte) order for astral-plane hooks", () => {
  // Rust 权威 build_dependency_index 用 BTreeMap<String, BTreeSet<String>>
  // （字节序 = 码点序）。U+FFFD（高 BMP）按码点小于 U+1F600（星面），但
  // UTF-16 码元序会把代理对排到前面——按默认 .sort()/compareByCodeUnit
  // 重算会把合法 Rust 产物误判为 dependencyIndex 不匹配。
  const astralStage = "\u{1F600}.stage";
  const bmpStage = "\u{FFFD}.stage";
  const astralHook = `${astralStage}#W`;
  const bmpHook = `${bmpStage}#W`;
  assert.ok(astralHook < bmpHook, "fixture guard: UTF-16 order must differ here");

  const plan = compileZhixuHookPlan(baseZhixu, demoManifest);
  const hookWith = (
    hookId: string,
    stageIdentifier: string,
    dependencies: readonly object[],
  ) => {
    // 模板钩子的 route 绑定原阶段名，改写阶段后剥离（route 与本测试无关）。
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

  // 码点序（Rust BTreeMap/BTreeSet 产物）：键与每键 hookIds 都按码点排，
  // 高 BMP 键在前、星面键在后 → 通过。（compiledHooks 已被重写，planHash
  // 按载荷重签以聚焦 dependencyIndex 排序本身。）
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

  // UTF-16 码元序变体 1（hookIds 代理对在前）→ 必须被拒绝。
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

  // UTF-16 码元序变体 2（键序代理对在前）→ 同样必须被拒绝。
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
          // 阶段的 source，且不得等于接收阶段自身的 source）。PLACE 种子
          // 入口钩子满足物化门（零 hook 阶段在链上永不可物化）。
          name: "feeder",
          stages: [
            {
              name: "gate",
              source: "buyer",
              receiveSignals: {
                PLACE: "buyer::feeder.gate.seed"
              },
              sendSignals: ["ready", "seed"],
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
      name: "orderbook_match"
    },
    spec: {
      ...baseZhixu.spec,
      taskPatterns: [
        {
          // source 类是 zhixu 局部命名空间：hook 引用的 seller/buyer 必须有
          // 声明阶段承载（引用存在性 + 本域 source 校验）。PLACE 种子入口
          // 钩子满足物化门（零 hook 阶段在链上永不可物化）。
          name: "feed",
          stages: [
            {
              name: "quote",
              source: "seller",
              receiveSignals: {
                PLACE: "seller::feed.quote.seed"
              },
              sendSignals: ["updated", "seed"],
              executor: {
                supplierType: "organization",
                supplierID: "seller-feed"
              }
            },
            {
              name: "bid",
              source: "buyer",
              receiveSignals: {
                PLACE: "buyer::feed.bid.seed"
              },
              sendSignals: ["updated", "seed"],
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

  // 断言聚焦 market.match 的多锚接收钩子（feed 阶段的 PLACE 种子钩子是
  // 物化门伴随产物）。
  const matchHooks = plan.compiledHooks.filter(
    (hook) => hook.stageIdentifier === "market.match"
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
    ["buyer::feed.bid.updated", "seller::feed.quote.updated"]
  );
});

test("accepts same-source hook expressions with the full hook DSL", () => {
  const plan = compileZhixuHookPlanWithManifest({
    ...baseZhixu,
    metadata: {
      name: "same_source_trigger_condition"
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

test("rejects executor-less selected-stage chains at the materialization gate", () => {
  // 物化门（P0-4）后 Rust 权威：每个阶段声明都必须自带物化位（order-trigger
  // mint/dock 入口或静态 executor 的 receive hook）——仅靠 selectedStages
  // 锚定静态执行者不再让 executor-less 阶段合法（链上阶段只能由本阶段的
  // hook 物化，submitSignal 要求源阶段已物化，零 hook 阶段恒 UnknownHook）。
  // 以 Rust 为准：该形态从"接受"改为拒绝。
  assertCompilationIssues(
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
    ]),
    [
      /flow\.a declares no receiveSignals and compiles to zero hooks/,
      /flow\.b declares no receiveSignals and compiles to zero hooks/,
      /flow\.c declares no receiveSignals and compiles to zero hooks/,
    ]
  );

  // 正例：同一拓扑每阶段自带 receive hook + 静态 executor——selectedStages
  // 绑定照常编译，executorRoutes 只落在声明了 executor 的阶段。
  const plan = compileZhixuHookPlan(
    topologyZhixu([
      {
        name: "a",
        source: "buyer",
        selectedStages: ["flow.b"],
        receiveSignals: { PLACE: "buyer::flow.a.seed" },
        sendSignals: ["seed"],
        executor: {
          supplierType: "organization",
          supplierID: "anchor-org"
        }
      },
      {
        name: "b",
        source: "buyer",
        selectedStages: ["flow.c"],
        receiveSignals: { PLACE: "buyer::flow.b.seed" },
        sendSignals: ["seed"],
        executor: {
          supplierType: "organization",
          supplierID: "b-org"
        }
      },
      {
        name: "c",
        source: "buyer",
        receiveSignals: { PLACE: "buyer::flow.c.seed" },
        sendSignals: ["seed"],
        executor: {
          supplierType: "organization",
          supplierID: "c-org"
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
  assert.ok(plan.executorRoutes["flow.b"]);
  assert.ok(plan.executorRoutes["flow.c"]);
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
  // triggerEntrance 不是合法字段；signalMap 值必须是目标端口名而非
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
                  target: { zhixu: dockDemoTargetName },
                  interface: "production_service",
                  order: { mode: "new" },
                  inputMap: { START: "execute" },
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
              receiveSignals: { START: "buyer::selector.assign.executor_selected" },
              sendSignals: ["str", "cmp"],
              executor: {
                supplierType: "zhixu",
                zhixuExecutorConfig: {
                  target: { zhixu: dockDemoTargetName },
                  interface: "production_service",
                  order: { mode: "new" },
                  inputMap: { START: "execute" },
                  signalMap: {
                    str: "factory::manufacturing.intake.str",
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
                  target: { zhixu: dockDemoTargetName },
                  interface: "production_service",
                  order: { mode: "new" },
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
              receiveSignals: { START: "buyer::selector.assign.executor_selected" },
              sendSignals: ["str", "cmp"],
              executor: {
                supplierType: "zhixu",
                zhixuExecutorConfig: {
                  target: { zhixu: dockDemoTargetName },
                  interface: "production_service",
                  order: { mode: "new" },
                  signalMap: { str: "started", cmp: "completed" }
                }
              }
            }
          ]
        }
      ]
    }
  };
  // mode=new 恰好一条 input 绑定（出生锚）：0 条即 D010。
  assertCompilationIssues(missingInputMap, [/D010/]);

  // D004：order.mode 闭集 {new, existing}。
  const badMode = structuredClone(missingInputMap) as ZhixuDefinition & {
    spec: { taskPatterns: Array<{ stages: Array<{ executor?: { zhixuExecutorConfig?: { order: { mode: string } } } }> }> };
  };
  (badMode.spec.taskPatterns[0]!.stages[0]!.executor!.zhixuExecutorConfig!.order as { mode: string }).mode = "derived-v1";
  assertCompilationIssues(badMode as unknown as ZhixuDefinition, [/D004/]);

  // D003：target.zhixu 必须是目标定义 metadata.name（slug 形态）。
  const badTarget = structuredClone(missingInputMap) as ZhixuDefinition & {
    spec: { taskPatterns: Array<{ stages: Array<{ executor?: { zhixuExecutorConfig?: { target: { zhixu: string } } } }> }> };
  };
  badTarget.spec.taskPatterns[0]!.stages[0]!.executor!.zhixuExecutorConfig!.target.zhixu = "Payment-Zhixu";
  assertCompilationIssues(badTarget as unknown as ZhixuDefinition, [/D003/]);

  // D019：至少声明一项输入或输出映射（str/cmp 不再强制）。
  const noMappings = structuredClone(missingInputMap) as ZhixuDefinition & {
    spec: { taskPatterns: Array<{ stages: Array<{ executor?: { zhixuExecutorConfig?: { signalMap?: Record<string, string> } } }> }> };
  };
  delete noMappings.spec.taskPatterns[0]!.stages[0]!.executor!.zhixuExecutorConfig!.signalMap;
  assertCompilationIssues(noMappings as unknown as ZhixuDefinition, [/D019/]);

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
                  target: { zhixu: dockDemoTargetName },
                  interface: "production_service",
                  order: { mode: "new" },
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

test("demo sourcing parent links both demo interfaces (new + existing)", () => {
  // 对齐 gen_dock_fixtures 的父定义形状：production_service[new] +
  // production_evidence[existing] 两条 route 在 demo manifest 上解析。
  const plan = compileZhixuHookPlan(
    dockSourcingParentDefinition(dockDemoTargetName),
    demoManifest,
  );
  assert.deepEqual(
    plan.dockRoutes.map((route) => [
      route.local.stageIdentifier,
      route.target.interfaceName,
      route.orderMode,
    ]),
    [
      ["sourcing.manufacture", "production_service", "new"],
      ["sourcing.source_evidence", "production_evidence", "existing"],
    ],
  );
  assert.deepEqual(validateHookPlanArtifact(plan), []);
});

test("carries null (dynamic-selection) targets as unresolved routes (§8.8)", () => {
  // target:null 不再整体拒绝（Wave3-E4）：hook plan 产物保留未解析 route 的
  // 声明面（manifest 在场时不进 link、不报 D008），云轨运行时才由选择记录
  // 补齐（PRD_100 §10.3）；链轨拒绝在 onchain 边界（见 onchain 测试）。
  const dynamicTarget = structuredClone(baseZhixu) as ZhixuDefinition & {
    spec: { taskPatterns: Array<{ stages: Array<{ executor?: { zhixuExecutorConfig?: { target: { zhixu: string } | null } } }> }> };
  };
  dynamicTarget.spec.taskPatterns[1]!.stages[0]!.executor!.zhixuExecutorConfig!.target = null;
  const plan = compileZhixuHookPlan(
    dynamicTarget as unknown as ZhixuDefinition,
    demoManifest,
  );
  assert.deepEqual(plan.dockRoutes, []);
  const unresolved = plan.unresolvedDockRoutes ?? [];
  assert.equal(unresolved.length, 1);
  const route = unresolved[0]!;
  assert.equal(route.schemaVersion, "uvp.dockRoute.unresolved.v1");
  assert.equal(route.stageIdentifier, "execution.main");
  assert.equal(route.localSource, "buyer");
  assert.equal(route.interfaceName, "production_service");
  assert.equal(route.orderMode, "new");
  assert.deepEqual(
    route.inputBindings.map((binding) => [binding.hookId, binding.port]),
    [["execution.main#START", "execute"]],
  );
  assert.deepEqual(
    route.outputBindings
      .map((binding) => [binding.signal, binding.port])
      .sort(),
    [["cmp", "completed"], ["str", "started"]],
  );
  assert.equal(route.localPlanId, plan.planId);
  // 声明面校验零 issue；无未解析 route 的产物不落字段。
  assert.deepEqual(validateHookPlanArtifact(plan), []);
  const staticPlan = compileZhixuHookPlan(baseZhixu, demoManifest);
  assert.equal(staticPlan.unresolvedDockRoutes, undefined);
});

test("compiles existing-mode routes on the cloud-facing hook plan profile", () => {
  // Rust 两个 profile 都放行 existing（云轨语义）；链轨拒绝在
  // onchain-hook-plan 测试显式断言。existing 型接口只有 signalMap。
  const plan = compileZhixuHookPlan(
    {
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
                  executor: {
                    supplierType: "zhixu" as const,
                    zhixuExecutorConfig: {
                      target: { zhixu: dockDemoTargetName },
                      interface: "production_evidence",
                      order: { mode: "existing" as const },
                      signalMap: { cmp: "scrap_declared" }
                    }
                  }
                }))
              }
        )
      }
    },
    demoManifest,
  );
  assert.equal(plan.dockRoutes.length, 1);
  assert.equal(plan.dockRoutes[0]?.orderMode, "existing");
  assert.equal(plan.dockRoutes[0]?.inputBindings.length, 0);
  assert.equal(plan.dockRoutes[0]?.inputBindingsRoot, EMPTY_MERKLE_ROOT);
  assert.equal(plan.dockRoutes[0]?.outputBindings[0]?.targetPort, "scrap_declared");
  assert.deepEqual(validateHookPlanArtifact(plan), []);
});

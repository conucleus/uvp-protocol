import assert from "node:assert/strict";
import test from "node:test";
import {
  assertHookPlanArtifact,
  compileZhixuHookPlan,
  compareCanonicalKey,
  HookPlanCompilationError,
  HookPlanArtifactValidationError,
  validateHookPlanArtifact
} from "../src/hook-plan.js";
import {
  buildDockInterfaceArtifact,
  buildDockRoute,
  hookPlanHashOf,
  planIdOf,
  prepareDockResolution,
} from "../src/dock-commitments.js";
import { validateDockCommitments } from "../src/dock-validation.js";
import {
  type DockResolutionManifest,
  type DockResolutionTarget,
  type HookPlanArtifact,
  type ZhixuDefinition,
  type ZhixuStage
} from "../src/types/index.js";
import {
  dockDemoResolutionManifest,
  dockDemoTargetUid,
  dockProductionTargetDefinition,
  dockSourcingParentDefinition,
  resolutionManifestFor,
} from "./dock-demo.js";
import { commitmentGoldenCase } from "./commitment-golden.js";
import {
  definitionRefHash,
  definitionUid,
  dockCandidateLeaf,
  dockRouteId,
  EMPTY_MERKLE_ROOT,
  inputPortLeaf,
  interfaceLeaf,
  merkleRoot,
  outputPortLeaf,
  routeHash,
  stageKey,
  ZERO_WORD,
} from "../src/dock.js";

const demoManifest = dockDemoResolutionManifest();
const demoTargetUid = dockDemoTargetUid();

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
          supplierType: "zhixu",
          zhixuExecutorConfig: {
            target: { zhixu: demoTargetUid },
            interface: "production_service",
            order: { mode: "new" },
            inputMap: { START: "execute" },
            signalMap: { str: "started", cmp: "completed" }
          }
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
      stages
    }
  };
}

test("compiles internal HookPlan IR", () => {
  const plan = compileZhixuHookPlan(baseZhixu, demoManifest);

  assert.equal(plan.schemaVersion, "uvp.hookPlan.v4");
  const golden = commitmentGoldenCase("demo_zhixu_production_dock");
  assert.match(plan.zhixuId, /^zx-[0-9a-f]{32}$/);
  assert.equal(plan.zhixuId, golden.expected.uid);
  assert.deepEqual(plan.platform, { type: "cloud" });
  assert.match(plan.planId, /^0x[0-9a-f]{64}$/);
  assert.match(plan.planHash, /^0x[0-9a-f]{64}$/);
  assert.equal(plan.planHash, golden.expected.hookPlanHash);
  assert.equal(plan.compiledHooks.length, 3);
  assert.deepEqual(plan.compiledHooks.map((hook) => hook.hookId), [
    "assign#PLACE",
    "main#START",
    "main#TIMEOUT"
  ]);
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
  assert.equal(plan.executorRoutes["main"], undefined);
  assert.equal(plan.dockRoutes.length, 1);
  assert.equal(plan.dockRoutes[0]?.local.stageIdentifier, "main");
  assert.equal(plan.dockRoutes[0]?.orderMode, "new");
  assert.equal(plan.dockRoutes[0]?.target.interfaceName, "production_service");
  assert.equal(plan.dockRoutes[0]?.inputBindings[0]?.localHookName, "START");
  assert.equal(plan.dockRoutes[0]?.inputBindings[0]?.targetPort, "execute");
  assert.equal(plan.dockRoutes[0]?.sourceSeam, "factory");
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

test("planId preimage drops empty platform params across compile/validate calibers", () => {
  const withoutParams = compileZhixuHookPlanWithManifest(baseZhixu);
  const withEmptyParams = compileZhixuHookPlanWithManifest({
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

  const embeddedDefinition: ZhixuDefinition = {
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: { name: "empty_params_target" },
    spec: {
      platform: { type: "cloud", params: {} },
      nucleation: { id: "core" },
      stages: [{
              name: "forward",
              source: "operator",
              receiveSignals: { GO: "operator::forward.go" },
              sendSignals: [{ name: "cmp" }, { name: "go" }],
              executor: {
                supplierType: "zhixu",
                zhixuExecutorConfig: {
                  target: { zhixu: demoTargetUid },
                  interface: "production_evidence",
                  order: { mode: "existing" },
                  signalMap: { cmp: "scrap_declared" },
                },
              },
            }],
    },
  };
  const embeddedUid = definitionUid(embeddedDefinition);
  const embeddedPlan = compileZhixuHookPlan(embeddedDefinition, demoManifest);
  assert.doesNotThrow(() =>
    prepareDockResolution({
      schemaVersion: "uvp.dock.resolution.v2",
      definitions: [
        {
          zhixu: embeddedUid,
          definition: embeddedDefinition,
          definitionRefHash: definitionRefHash(embeddedUid),
          artifactHash: `0x${"ab".repeat(32)}` as `0x${string}`,
          published: true,
          interfaces: [],
          dockEdges: [{ target: demoTargetUid }],
          evmPlanId: embeddedPlan.planId,
        },
      ],
    }),
  );
});

test("validates HookPlan IR artifacts at the internal boundary", () => {
  const plan = compileZhixuHookPlan(baseZhixu, demoManifest);

  assert.deepEqual(
    validateHookPlanArtifact(resign({ ...plan, schemaVersion: "wrong" })),
    ["schemaVersion must be uvp.hookPlan.v4"]
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
  const plan = compileZhixuHookPlan(baseZhixu, demoManifest);

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
  const plan = compileZhixuHookPlan(baseZhixu, demoManifest);
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

function resolutionEntryWithStaticEdge(withEdges: boolean) {
  const definition: ZhixuDefinition = {
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: { name: "edge_intermediary" },
    spec: {
      platform: { type: "cloud" },
      nucleation: { id: "edge-core" },
      stages: [{
              name: "forward",
              source: "operator",
              receiveSignals: { GO: "operator::forward.go" },
              sendSignals: [{ name: "done" }],
              executor: {
                supplierType: "zhixu",
                zhixuExecutorConfig: {
                  target: { zhixu: demoTargetUid },
                  interface: "production_evidence",
                  order: { mode: "existing" },
                  signalMap: { cmp: "scrap_declared" },
                },
              },
            }],
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
    ...(withEdges ? { dockEdges: [{ target: demoTargetUid }] } : {}),
  };
}

test("rejects resolution manifests whose dockEdges diverge from the embedded definition", () => {
  const manifest = (withEdges: boolean): DockResolutionManifest => ({
    schemaVersion: "uvp.dock.resolution.v2",
    definitions: [resolutionEntryWithStaticEdge(withEdges)],
  });

  assert.throws(
    () => prepareDockResolution(manifest(false)),
    /dockEdges must declare static target "zx-/,
  );
  assert.doesNotThrow(() => prepareDockResolution(manifest(true)));
  assert.throws(
    () =>
      prepareDockResolution({
        schemaVersion: "uvp.dock.resolution.v2",
        definitions: [
          {
            ...resolutionEntryWithStaticEdge(true),
            dockEdges: [
              { target: demoTargetUid },
              { target: "phantom_target" },
            ],
          },
        ],
      }),
    /dockEdges declares target "phantom_target" which the embedded definition never statically references/,
  );
  assert.throws(
    () =>
      prepareDockResolution({
        schemaVersion: "uvp.dock.resolution.v2",
        definitions: [
          {
            ...resolutionEntryWithStaticEdge(true),
            dockEdges: [
              { target: demoTargetUid },
              { target: demoTargetUid },
            ],
          },
        ],
      }),
    /duplicates target "zx-/,
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

test("rejects manifests carrying the same uid under two names (uid is the resolution key)", () => {
  const renamed = structuredClone(resolutionEntryWithStaticEdge(true)) as DockResolutionTarget & {
    definition: ZhixuDefinition;
    zhixu: string;
    definitionRefHash: `0x${string}`;
    evmPlanId?: `0x${string}`;
  };
  renamed.definition = {
    ...renamed.definition,
    metadata: { ...renamed.definition.metadata, name: "edge_intermediary_alias" },
  };
  const uid = definitionUid(renamed.definition);
  assert.equal(uid, resolutionEntryWithStaticEdge(true).zhixu);
  renamed.zhixu = uid;
  renamed.definitionRefHash = definitionRefHash(uid);
  delete renamed.evmPlanId;
  assert.throws(
    () =>
      prepareDockResolution({
        schemaVersion: "uvp.dock.resolution.v2",
        definitions: [resolutionEntryWithStaticEdge(true), renamed],
      }),
    /duplicate definition uid "zx-[0-9a-f]{32}" — uid is the resolution key and must be unique in the manifest/,
  );
});

test("neutral dock target registry embeds the definition verbatim; core owns the input-port source face", () => {
  const prepared = prepareDockResolution(demoManifest);
  assert.deepEqual(prepared.neutral, [
    { uid: demoTargetUid, definition: demoManifest.definitions[0]!.definition },
  ]);
  const targetPlan = compileZhixuHookPlan(
    demoManifest.definitions[0]!.definition,
  );
  const service = targetPlan.dockInterface?.interfaces.find(
    (entry) => entry.name === "production_service",
  );
  assert.ok(service, "demo target publishes production_service");
  assert.deepEqual(
    service.inputs.map((port) => [port.port, port.source, port.hookId]),
    [
      ["amend", "factory", "produce#DOCK_AMEND"],
      ["execute", "factory", "intake#EXECUTE"],
    ],
  );
  const evidence = targetPlan.dockInterface?.interfaces.find(
    (entry) => entry.name === "production_evidence",
  );
  assert.ok(evidence, "demo target publishes production_evidence");
  assert.deepEqual(evidence.inputs, []);
});

interface MutableInterfaceEntry {
  readonly name: string;
  readonly orderModes: readonly string[];
  readonly inputs: readonly {
    readonly port: string;
    readonly hookId: string;
    readonly leafHash: `0x${string}`;
  }[];
  readonly outputs: readonly {
    readonly port: string;
    readonly canonicalOutputSignal: string;
    readonly leafHash: `0x${string}`;
  }[];
  inputsRoot: `0x${string}`;
  outputsRoot: `0x${string}`;
  interfaceRoot: `0x${string}`;
}

function readdress(entry: DockResolutionTarget): void {
  const uid = definitionUid(entry.definition);
  const mutable = entry as {
    zhixu: string;
    definitionRefHash: `0x${string}`;
    evmPlanId?: `0x${string}`;
  };
  mutable.zhixu = uid;
  mutable.definitionRefHash = definitionRefHash(uid);
  delete mutable.evmPlanId;
  for (const iface of entry.interfaces as readonly MutableInterfaceEntry[]) {
    const ports = iface as unknown as {
      inputs: { leafHash: `0x${string}` }[];
      outputs: { leafHash: `0x${string}` }[];
    };
    for (const [index, port] of iface.inputs.entries()) {
      ports.inputs[index]!.leafHash = inputPortLeaf({
        uid,
        interfaceName: iface.name,
        portName: port.port,
        hookId: port.hookId,
      });
    }
    for (const [index, port] of iface.outputs.entries()) {
      ports.outputs[index]!.leafHash = outputPortLeaf({
        uid,
        interfaceName: iface.name,
        portName: port.port,
        canonicalSignal: port.canonicalOutputSignal,
      });
    }
    iface.inputsRoot = merkleRoot(iface.inputs.map((port) => port.leafHash));
    iface.outputsRoot = merkleRoot(iface.outputs.map((port) => port.leafHash));
    iface.interfaceRoot = interfaceLeaf({
      uid,
      interfaceName: iface.name,
      orderModes: iface.orderModes,
      inputsRoot: iface.inputsRoot,
      outputsRoot: iface.outputsRoot,
    });
  }
}

test("core extraction of dock targets fails loud, no fallback", () => {
  const missingStageEntry = structuredClone(
    demoManifest.definitions[0],
  ) as (typeof demoManifest.definitions)[number];
  (missingStageEntry.definition.spec as unknown as { stages: ZhixuStage[] }).stages =
    missingStageEntry.definition.spec.stages.filter(
      (stage) => stage.name !== "intake",
    );
  readdress(missingStageEntry);
  const missingStageManifest = {
    schemaVersion: "uvp.dock.resolution.v2",
    definitions: [missingStageEntry],
  } as const;
  const missingStageUid = prepareDockResolution(
    missingStageManifest,
  ).neutral[0]!.uid;
  assert.throws(
    () =>
      compileZhixuHookPlan(
        dockSourcingParentDefinition(missingStageUid),
        missingStageManifest,
      ),
    /D008 dockTargets\[0\]\.definition\.spec\.dockInterface\.production_service\.inputs\.execute\.hook: hook "intake#EXECUTE" references stage "intake" which does not exist in the target definition/,
  );

  const blankSourceEntry = structuredClone(
    demoManifest.definitions[0],
  ) as (typeof demoManifest.definitions)[number];
  (
    blankSourceEntry.definition.spec.stages.find(
      (stage) => stage.name === "intake",
    ) as unknown as { source: string }
  ).source = "   ";
  readdress(blankSourceEntry);
  const blankSourceManifest = {
    schemaVersion: "uvp.dock.resolution.v2",
    definitions: [blankSourceEntry],
  } as const;
  const blankSourceUid = prepareDockResolution(
    blankSourceManifest,
  ).neutral[0]!.uid;
  assert.throws(
    () =>
      compileZhixuHookPlan(
        dockSourcingParentDefinition(blankSourceUid),
        blankSourceManifest,
      ),
    /D012 .*single target source seam.*found \{"   ", "factory"\}/,
  );
});

test("artifact validators require a non-empty source on input ports", () => {
  const target = compileZhixuHookPlan(
    structuredClone(demoManifest.definitions[0]!.definition),
  );
  const dockInterface = structuredClone(target.dockInterface!);
  const executePort = dockInterface.interfaces
    .find((entry) => entry.name === "production_service")!
    .inputs.find((port) => port.port === "execute")! as unknown as Record<
    string,
    unknown
  >;
  delete executePort.source;
  const issues = validateDockCommitments({
    dockRoutes: [],
    dockRoutesRoot: EMPTY_MERKLE_ROOT,
    dockInterface,
    dockInterfaceRoot: dockInterface.interfaceRoot,
  });
  assert.ok(
    issues.some((issue) =>
      /inputs\[\d+\]\.source must be a non-empty string/.test(issue),
    ),
    issues.join("; "),
  );
  executePort.source = "  ";
  const blankIssues = validateDockCommitments({
    dockRoutes: [],
    dockRoutesRoot: EMPTY_MERKLE_ROOT,
    dockInterface,
    dockInterfaceRoot: dockInterface.interfaceRoot,
  });
  assert.ok(
    blankIssues.some((issue) =>
      /inputs\[\d+\]\.source must be a non-empty string/.test(issue),
    ),
    blankIssues.join("; "),
  );
});

test("dock route commitment recomputation fails closed on missing identity fields", () => {
  const plan = compileZhixuHookPlan(
    dockSourcingParentDefinition(demoTargetUid),
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
  const astralStage = "\u{1F600}";
  const bmpStage = "\u{FFFD}";
  const astralHook = `${astralStage}#W`;
  const bmpHook = `${bmpStage}#W`;
  assert.ok(astralHook < bmpHook, "fixture guard: UTF-16 order must differ here");

  const plan = compileZhixuHookPlan(baseZhixu, demoManifest);
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

test("rejects invalid mint declarations", () => {
  const invalid: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: [{
              name: "main",
              source: "buyer",
              mint: "per-order" as unknown as "per-fact",
              executor: {
                supplierType: "organization",
                supplierID: "executor"
              }
            }]
    }
  };

  assertCompilationIssues(invalid, [
    /main.mint only supports per-fact: per-order/
  ]);
});

test("mint stages accept single ANCHOR birth subscriptions and mark them order-trigger", () => {
  const valid: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: [
        {
          name: "gate",
          source: "buyer",
          receiveSignals: {
            PLACE: "buyer::gate.seed"
          },
          sendSignals: [{ name: "ready" }, { name: "seed" }],
          executor: {
            supplierType: "organization",
            supplierID: "feeder-org"
          }
        },
        {
          name: "main",
          source: "runner",
          mint: "per-fact",
          receiveSignals: {
            START: "::ANCHOR(@buyer::gate.ready)"
          },
          sendSignals: [{ name: "str" }, { name: "cmp" }],
          executor: {
            supplierType: "organization",
            supplierID: "executor"
          }
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
      stages: [{
              name: "main",
              source: "buyer",
              mint: "per-fact",
              receiveSignals: {
                START: "buyer::(main.ready & main.ack)"
              },
              sendSignals: [{ name: "ready" }, { name: "ack" }],
              executor: {
                supplierType: "organization",
                supplierID: "executor"
              }
            }]
    }
  };

  assertCompilationIssues(invalid, [
    /main.receiveSignals.START: mint stage accepts ANCHOR\(@…\) subscription entries only; plain birth-entry hooks are retired/
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
  const plan = compileZhixuHookPlanWithManifest({
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
      /a declares no receiveSignals and compiles to zero hooks/,
      /b declares no receiveSignals and compiles to zero hooks/,
      /c declares no receiveSignals and compiles to zero hooks/,
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

test("rejects non-canonical zhixu executor config shapes", () => {
  const entranceConfig: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: [{
              name: "main",
              source: "buyer",
              executor: {
                supplierType: "zhixu",
                zhixuExecutorConfig: {
                  target: { zhixu: demoTargetUid },
                  interface: "production_service",
                  order: { mode: "new" },
                  inputMap: { START: "execute" },
                  triggerEntrance: "init"
                } as never
              }
            }]
    }
  };
  assertCompilationIssues(entranceConfig, [/D002.*triggerEntrance/]);

  const hookDslSignalMap: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: [{
              name: "main",
              source: "buyer",
              receiveSignals: { START: "buyer::assign.executor_selected" },
              sendSignals: [{ name: "str" }, { name: "cmp" }],
              executor: {
                supplierType: "zhixu",
                zhixuExecutorConfig: {
                  target: { zhixu: demoTargetUid },
                  interface: "production_service",
                  order: { mode: "new" },
                  inputMap: { START: "execute" },
                  signalMap: {
                    str: "factory::intake.str",
                    cmp: "completed"
                  }
                }
              }
            }]
    }
  };
  assertCompilationIssues(hookDslSignalMap, [/D006.*signalMap\.str/]);

  const crossZhixuSupplierId: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: [{
              name: "main",
              source: "buyer",
              executor: {
                supplierType: "zhixu",
                supplierID: "peer-zhixu",
                zhixuExecutorConfig: {
                  target: { zhixu: demoTargetUid },
                  interface: "production_service",
                  order: { mode: "new" },
                  inputMap: { START: "execute" },
                  signalMap: { str: "started", cmp: "completed" }
                }
              }
            }]
    }
  };
  assertCompilationIssues(crossZhixuSupplierId, [/D001/]);
});

test("rejects locally invalid dock executor configs", () => {
  const missingInputMap: ZhixuDefinition = {
    ...baseZhixu,
    spec: {
      ...baseZhixu.spec,
      stages: [{
              name: "main",
              source: "buyer",
              receiveSignals: { START: "buyer::assign.executor_selected" },
              sendSignals: [{ name: "str" }, { name: "cmp" }],
              executor: {
                supplierType: "zhixu",
                zhixuExecutorConfig: {
                  target: { zhixu: demoTargetUid },
                  interface: "production_service",
                  order: { mode: "new" },
                  signalMap: { str: "started", cmp: "completed" }
                }
              }
            }]
    }
  };
  assertCompilationIssues(missingInputMap, [/D010/]);

  const badMode = structuredClone(missingInputMap) as ZhixuDefinition & {
    spec: { stages: Array<{ executor?: { zhixuExecutorConfig?: { order: { mode: string } } } }> };
  };
  (badMode.spec.stages[0]!.executor!.zhixuExecutorConfig!.order as { mode: string }).mode = "derived-v1";
  assertCompilationIssues(badMode as unknown as ZhixuDefinition, [/D004/]);

  for (const badTargetValue of ["Payment-Zhixu", "payment-zhixu"]) {
    const badTarget = structuredClone(missingInputMap) as ZhixuDefinition & {
      spec: { stages: Array<{ executor?: { zhixuExecutorConfig?: { target: { zhixu: string } } } }> };
    };
    badTarget.spec.stages[0]!.executor!.zhixuExecutorConfig!.target.zhixu = badTargetValue;
    assertCompilationIssues(badTarget as unknown as ZhixuDefinition, [/D003/]);
  }

  const noMappings = structuredClone(missingInputMap) as ZhixuDefinition & {
    spec: { stages: Array<{ executor?: { zhixuExecutorConfig?: { signalMap?: Record<string, string> } } }> };
  };
  delete noMappings.spec.stages[0]!.executor!.zhixuExecutorConfig!.signalMap;
  assertCompilationIssues(noMappings as unknown as ZhixuDefinition, [/D019/]);

  const unknownLocalHook: ZhixuDefinition = {
    ...missingInputMap,
    spec: {
      ...missingInputMap.spec,
      stages: [{
              name: "main",
              source: "buyer",
              receiveSignals: {
                START: "buyer::assign.executor_selected"
              },
              sendSignals: [{ name: "str" }, { name: "cmp" }],
              executor: {
                supplierType: "zhixu",
                zhixuExecutorConfig: {
                  target: { zhixu: demoTargetUid },
                  interface: "production_service",
                  order: { mode: "new" },
                  inputMap: { MISSING: "execute" },
                  signalMap: { str: "started", cmp: "completed" }
                }
              }
            }]
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
  const plan = compileZhixuHookPlan(
    dockSourcingParentDefinition(demoTargetUid),
    demoManifest,
  );
  assert.deepEqual(
    plan.dockRoutes.map((route) => [
      route.local.stageIdentifier,
      route.target.interfaceName,
      route.orderMode,
    ]),
    [
      ["manufacture", "production_service", "new"],
      ["source_evidence", "production_evidence", "existing"],
    ],
  );
  assert.deepEqual(validateHookPlanArtifact(plan), []);
});

test("carries null (dynamic-selection) targets as unresolved routes (§8.8)", () => {
  const dynamicTarget = structuredClone(baseZhixu) as ZhixuDefinition & {
    spec: { stages: Array<{ executor?: { zhixuExecutorConfig?: { target: { zhixu: string } | null } } }> };
  };
  dynamicTarget.spec.stages[1]!.executor!.zhixuExecutorConfig!.target = null;
  const plan = compileZhixuHookPlan(
    dynamicTarget as unknown as ZhixuDefinition,
    demoManifest,
  );
  assert.deepEqual(plan.dockRoutes, []);
  const unresolved = plan.unresolvedDockRoutes ?? [];
  assert.equal(unresolved.length, 1);
  const route = unresolved[0]!;
  assert.equal(route.schemaVersion, "uvp.dockRoute.unresolved.v1");
  assert.equal(route.stageIdentifier, "main");
  assert.equal(route.localSource, "buyer");
  assert.equal(route.interfaceName, "production_service");
  assert.equal(route.orderMode, "new");
  assert.deepEqual(
    route.inputBindings.map((binding) => [binding.hookId, binding.port]),
    [["main#START", "execute"]],
  );
  assert.deepEqual(
    route.outputBindings
      .map((binding) => [binding.signal, binding.port])
      .sort(),
    [["cmp", "completed"], ["str", "started"]],
  );
  assert.equal(route.localPlanId, plan.planId);

  const manifestEntry = demoManifest.definitions[0]!;
  assert.equal(route.candidates.length, 1);
  assert.equal(route.candidates[0]?.zhixuUid, manifestEntry.zhixu);
  assert.equal(route.candidates[0]?.definitionRefHash, manifestEntry.definitionRefHash);
  assert.equal(
    route.candidates[0]?.evmPlanId,
    manifestEntry.evmPlanId,
  );

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
      interfaceName: "production_service",
    }),
  ]);
  assert.equal(route.candidatesRoot, expectedCandidatesRoot);
  assert.equal(
    route.routeHash,
    routeHash({
      localDefinitionRefHash: route.localDefinitionRefHash,
      targetDefinitionRefHash: expectedCandidatesRoot,
      targetPlanId: ZERO_WORD,
      interfaceName: "production_service",
      orderMode: "new",
      inputBindingsRoot: EMPTY_MERKLE_ROOT,
      outputBindingsRoot: EMPTY_MERKLE_ROOT,
    }),
  );
  assert.equal(plan.dockRoutesRoot, route.routeHash);

  assert.deepEqual(validateHookPlanArtifact(plan), []);
  const staticPlan = compileZhixuHookPlan(baseZhixu, demoManifest);
  assert.equal(staticPlan.unresolvedDockRoutes, undefined);
});

test("rejects an explicit empty unresolvedDockRoutes list (closed field set)", () => {
  const dynamicTarget = structuredClone(baseZhixu) as ZhixuDefinition & {
    spec: { stages: Array<{ executor?: { zhixuExecutorConfig?: { target: { zhixu: string } | null } } }> };
  };
  dynamicTarget.spec.stages[1]!.executor!.zhixuExecutorConfig!.target = null;
  const plan = compileZhixuHookPlan(
    dynamicTarget as unknown as ZhixuDefinition,
    demoManifest,
  );
  assert.ok(plan.unresolvedDockRoutes?.length === 1);
  const issues = validateHookPlanArtifact(
    resign({ ...plan, unresolvedDockRoutes: [] }),
  );
  assert.ok(
    issues.some((issue) =>
      /unresolvedDockRoutes must not be an empty array/.test(issue),
    ),
    issues.join("; "),
  );
});

test("rejects dynamic targets without a manifest (no candidate universe to freeze)", () => {
  const dynamicOnly = structuredClone(baseZhixu) as ZhixuDefinition & {
    spec: { stages: Array<{ executor?: { zhixuExecutorConfig?: { target: { zhixu: string } | null } } }> };
  };
  dynamicOnly.spec.stages[1]!.executor!.zhixuExecutorConfig!.target = null;
  assert.throws(
    () => compileZhixuHookPlan(dynamicOnly as unknown as ZhixuDefinition),
    /unresolved dock route main declares a dynamic \(null\) target but no resolution manifest was prepared/,
  );
});

test("rejects dynamic targets whose interface is published in no candidate's mode (empty candidate set)", () => {
  const wrongMode = structuredClone(baseZhixu) as ZhixuDefinition & {
    spec: {
      stages: Array<{
        executor?: {
          zhixuExecutorConfig?: {
            target: { zhixu: string } | null;
            interface?: string;
            order?: { mode?: string };
          };
        };
      }>;
    };
  };
  const config =
    wrongMode.spec.stages[1]!.executor!.zhixuExecutorConfig!;
  config.target = null;
  config.interface = "production_evidence";
  config.order = { mode: "new" };
  assert.throws(
    () => compileZhixuHookPlan(wrongMode as unknown as ZhixuDefinition, demoManifest),
    /unresolved dock route main has an empty candidate set.*production_evidence.*"new"/s,
  );
});

test("compiles existing-mode routes on the cloud-facing hook plan profile", () => {
  const plan = compileZhixuHookPlan(
    {
      ...baseZhixu,
      spec: {
        ...baseZhixu.spec,
        stages: baseZhixu.spec.stages.map((stage) =>
          stage.name !== "main"
            ? stage
            : {
                ...stage,
                executor: {
                  supplierType: "zhixu" as const,
                  zhixuExecutorConfig: {
                    target: { zhixu: demoTargetUid },
                    interface: "production_evidence",
                    order: { mode: "existing" as const },
                    signalMap: { cmp: "scrap_declared" }
                  }
                }
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

test("rejects output bindings mapping one local fact key onto multiple ports", () => {
  const resolution = prepareDockResolution(demoManifest);
  const neutral = {
    schemaVersion: "uvp.dockRoute.v4" as const,
    local: { stageIdentifier: "manufacture" },
    target: { uid: demoTargetUid, interfaceName: "production_service" },
    orderMode: "new" as const,
    inputBindings: [
      { hookId: "manufacture#EXECUTE", port: "execute" },
    ],
    outputBindings: [
      { signal: "str", port: "started" },
      { signal: "str", port: "completed" },
    ],
  };
  const context = {
    localDefinitionRefHash: `0x${"11".repeat(32)}` as `0x${string}`,
    localPlanId: `0x${"22".repeat(32)}` as `0x${string}`,
    localStageSources: new Map([["manufacture", "purchaser"]]),
    resolution,
  };
  assert.throws(
    () => buildDockRoute(neutral, context),
    /maps local signal "str" onto multiple output ports.*SignalAlreadyExists/s,
  );
});

test("unbound cross-source interface ports do not join the D012 seam", () => {
  const crossSeamTarget = dockProductionTargetDefinition();
  crossSeamTarget.spec.dockInterface!.production_service!.inputs!.audit_check = {
    hook: "audit#CHECK",
  };
  (crossSeamTarget.spec.stages as ZhixuStage[]).push({
    name: "audit",
    source: "auditor",
    receiveSignals: { CHECK: "auditor::audit.check" },
    sendSignals: [{ name: "report" }],
    executor: { supplierType: "organization", supplierID: "audit-org" },
  });
  const plan = compileZhixuHookPlan(
    dockSourcingParentDefinition(definitionUid(crossSeamTarget)),
    resolutionManifestFor(crossSeamTarget),
  );
  const manufactureRoute = plan.dockRoutes.find(
    (route) => route.local.stageIdentifier === "manufacture",
  );
  assert.ok(manufactureRoute !== undefined);
  assert.equal(manufactureRoute.sourceSeam, "factory");
  assert.deepEqual(validateHookPlanArtifact(plan), []);
});

test("route-bound cross-source ports are rejected as HookPlanCompilationError, never a bare RangeError", () => {
  const crossSeamTarget = dockProductionTargetDefinition();
  crossSeamTarget.spec.dockInterface!.production_service!.inputs!.audit_check = {
    hook: "audit#CHECK",
  };
  (crossSeamTarget.spec.stages as ZhixuStage[]).push({
    name: "audit",
    source: "auditor",
    receiveSignals: { CHECK: "auditor::audit.check" },
    sendSignals: [{ name: "report" }],
    executor: { supplierType: "organization", supplierID: "audit-org" },
  });
  const crossSeamTargetUid = definitionUid(crossSeamTarget);
  const parent: ZhixuDefinition = {
    ...dockSourcingParentDefinition(crossSeamTargetUid),
    spec: {
      ...dockSourcingParentDefinition(crossSeamTargetUid).spec,
      stages: dockSourcingParentDefinition(crossSeamTargetUid).spec.stages.map(
        (stage) =>
          stage.name !== "manufacture"
            ? stage
            : {
                ...stage,
                receiveSignals: {
                  ...stage.receiveSignals,
                  CHECK: "purchaser::confirm.seed",
                },
                executor: {
                  supplierType: "zhixu" as const,
                  zhixuExecutorConfig: {
                    target: { zhixu: crossSeamTargetUid },
                    interface: "production_service",
                    order: { mode: "new" as const },
                    inputMap: { CHECK: "audit_check" },
                    signalMap: { str: "started" },
                  },
                },
              },
      ),
    },
  };
  assert.throws(
    () => compileZhixuHookPlan(parent, resolutionManifestFor(crossSeamTarget)),
    (error: unknown) => {
      assert.ok(
        error instanceof HookPlanCompilationError,
        `期望 HookPlanCompilationError，实际 ${String(error)}`,
      );
      assert.match(error.issues.join("; "), /single target source seam/);
      return true;
    },
  );
});

test("dockInterface input ports require the hook to be exactly one positive atom", () => {
  const declaration = {
    name: "production_service",
    orderModes: ["new"],
    inputs: {
      execute: { source: "factory", hook: "intake#EXECUTE" },
    },
    outputs: {},
  };
  const hooksById = new Map([
    [
      "intake#EXECUTE",
      {
        hookId: "intake#EXECUTE",
        stageIdentifier: "intake",
        dependencies: [
          { kind: "positive", source: "factory", signalName: "intake.execute" },
          { kind: "negative", source: "factory", signalName: "produce.cmp" },
        ],
      },
    ],
  ]) as unknown as Parameters<typeof buildDockInterfaceArtifact>[2];
  assert.throws(
    () => buildDockInterfaceArtifact([declaration], "zx-test", hooksById),
    /exactly one positive canonical signal atom/,
  );

  const singleAtom = new Map([
    [
      "intake#EXECUTE",
      {
        hookId: "intake#EXECUTE",
        stageIdentifier: "intake",
        dependencies: [
          { kind: "positive", source: "factory", signalName: "intake.execute" },
        ],
      },
    ],
  ]) as unknown as Parameters<typeof buildDockInterfaceArtifact>[2];
  const artifact = buildDockInterfaceArtifact(
    [declaration],
    "zx-test",
    singleAtom,
  );
  assert.equal(artifact.interfaces[0]!.inputs[0]!.canonicalInputSignal, "factory::intake.execute");
});

test("compareCanonicalKey orders by Rust byte order, not UTF-16 code units", () => {
  assert.ok(compareCanonicalKey("\uFFFD", "\u{1F600}") < 0);
  assert.ok(compareCanonicalKey("\u{1F600}", "\uFFFD") > 0);
  assert.equal(compareCanonicalKey("abc", "abd"), -1);
  assert.equal(compareCanonicalKey("prefix", "prefixlonger"), -1);
});

test("dock commitment validation fails closed on incomplete shapes", () => {
  const local = {
    definitionRefHash: `0x${"aa".repeat(32)}` as `0x${string}`,
    stageIdentifier: "stage",
  };
  const routeId = `0x${"bb".repeat(32)}` as `0x${string}`;
  const missingBindings = validateDockCommitments({
    dockRoutes: [
      {
        schemaVersion: "uvp.dockRoute.v4",
        routeId,
        local,
        target: { interfaceName: "svc" },
        orderMode: "new",
        inputBindings: "not-an-array",
        outputBindings: [],
        inputBindingsRoot: EMPTY_MERKLE_ROOT,
        outputBindingsRoot: EMPTY_MERKLE_ROOT,
        routeHash: `0x${"cc".repeat(32)}`,
      },
    ],
    dockRoutesRoot: EMPTY_MERKLE_ROOT,
    dockInterface: null,
    dockInterfaceRoot: EMPTY_MERKLE_ROOT,
  });
  assert.ok(
    missingBindings.some((issue) =>
      issue.endsWith(".inputBindings must be an array"),
    ),
    `非数组 inputBindings 应显式报 issue，实际：${JSON.stringify(missingBindings)}`,
  );

  const malformedBinding = validateDockCommitments({
    dockRoutes: [
      {
        schemaVersion: "uvp.dockRoute.v4",
        routeId,
        local,
        target: { interfaceName: "svc" },
        orderMode: "new",
        inputBindings: [{ port: "execute" }],
        outputBindings: [],
        inputBindingsRoot: EMPTY_MERKLE_ROOT,
        outputBindingsRoot: EMPTY_MERKLE_ROOT,
        routeHash: `0x${"cc".repeat(32)}`,
      },
    ],
    dockRoutesRoot: EMPTY_MERKLE_ROOT,
    dockInterface: null,
    dockInterfaceRoot: EMPTY_MERKLE_ROOT,
  });
  assert.ok(
    malformedBinding.some((issue) =>
      issue.includes("must carry bindingHash, localHookName, targetPort, targetSourceId and targetSignalId"),
    ),
    `形状坏绑定应显式报 issue，实际：${JSON.stringify(malformedBinding)}`,
  );

  const namelessInterface = validateDockCommitments({
    dockRoutes: [],
    dockRoutesRoot: EMPTY_MERKLE_ROOT,
    dockInterface: {
      schemaVersion: "uvp.dockInterfaceArtifact.v2",
      definition: {
        uid: "zx-nameless",
        definitionRefHash: definitionRefHash("zx-nameless"),
      },
      interfaces: [
        {
          name: "",
          orderModes: ["new"],
          inputs: [],
          outputs: [],
          inputsRoot: EMPTY_MERKLE_ROOT,
          outputsRoot: EMPTY_MERKLE_ROOT,
          interfaceRoot: `0x${"dd".repeat(32)}`,
        },
      ],
      interfaceRoot: `0x${"ee".repeat(32)}`,
    },
    dockInterfaceRoot: `0x${"ee".repeat(32)}`,
  });
  assert.ok(
    namelessInterface.some((issue) =>
      issue.endsWith(".name must be a non-empty string"),
    ),
    `无名接口应显式报 issue，实际：${JSON.stringify(namelessInterface)}`,
  );
});

test("dock commitment recomputation fails closed on garbage/missing route-level roots (I-4)", () => {
  const plan = compileZhixuHookPlan(baseZhixu, demoManifest);

  const mutateRoute = (
    mutate: (route: Record<string, unknown>) => void,
  ): readonly string[] => {
    const mutated = structuredClone(plan) as unknown as {
      dockRoutes: Record<string, unknown>[];
    };
    mutate(mutated.dockRoutes[0]!);
    return validateDockCommitments(mutated);
  };

  const garbageIssues = mutateRoute((route) => {
    route.inputBindingsRoot = "0xzz-garbage";
  });
  assert.ok(
    garbageIssues.includes(
      "artifact.dockRoutes[0].inputBindingsRoot must be a lowercase 32-byte hex hash",
    ),
    `expected explicit shape issue, got: ${JSON.stringify(garbageIssues)}`,
  );
  assert.ok(
    garbageIssues.includes(
      "artifact.dockRoutes[0].inputBindingsRoot must match the recomputed root over input binding hashes",
    ),
    `expected root comparison issue, got: ${JSON.stringify(garbageIssues)}`,
  );

  const missingIssues = mutateRoute((route) => {
    delete route.inputBindingsRoot;
  });
  assert.ok(
    missingIssues.includes(
      "artifact.dockRoutes[0].inputBindingsRoot must be a lowercase 32-byte hex hash",
    ) &&
      missingIssues.includes(
        "artifact.dockRoutes[0].inputBindingsRoot must match the recomputed root over input binding hashes",
      ),
    `missing field must produce explicit issues, got: ${JSON.stringify(missingIssues)}`,
  );

  const targetIssues = mutateRoute((route) => {
    (route.target as Record<string, unknown>).definitionRefHash = "0xzz";
  });
  assert.ok(
    targetIssues.includes(
      "artifact.dockRoutes[0].target.definitionRefHash must be a lowercase 32-byte hex hash",
    ),
    `expected target.definitionRefHash shape issue, got: ${JSON.stringify(targetIssues)}`,
  );

  const garbagePlan = structuredClone(plan) as unknown as {
    dockRoutes: Record<string, unknown>[];
  };
  garbagePlan.dockRoutes[0]!.inputBindingsRoot = "0xzz-garbage";
  assert.ok(
    validateHookPlanArtifact(garbagePlan).includes(
      "artifact.dockRoutes[0].inputBindingsRoot must be a lowercase 32-byte hex hash",
    ),
  );
});

test("interface commitment recomputation fails closed on garbage roots (I-4)", () => {
  const target = compileZhixuHookPlan(
    structuredClone(demoManifest.definitions[0]!.definition),
  );
  const base = structuredClone(target.dockInterface!);
  const entryIndex = base.interfaces.findIndex(
    (entry) => entry.name === "production_service",
  );
  assert.ok(entryIndex >= 0, "fixture guard: production_service must exist");
  const run = (
    mutate: (iface: typeof base) => void,
  ): readonly string[] => {
    const iface = structuredClone(base);
    mutate(iface);
    return validateDockCommitments({
      dockRoutes: [],
      dockRoutesRoot: EMPTY_MERKLE_ROOT,
      dockInterface: iface,
      dockInterfaceRoot: iface.interfaceRoot,
    });
  };

  const inputsRootIssues = run((iface) => {
    (iface.interfaces[entryIndex!] as unknown as Record<string, unknown>).inputsRoot = "0xzz";
  });
  assert.ok(
    inputsRootIssues.includes(
      `artifact.dockInterface.interfaces[${entryIndex}].inputsRoot must be a lowercase 32-byte hex hash`,
    ) &&
      inputsRootIssues.includes(
        `artifact.dockInterface.interfaces[${entryIndex}].inputsRoot must match the recomputed root over input-port leaves`,
      ),
    `expected explicit inputsRoot issues, got: ${JSON.stringify(inputsRootIssues)}`,
  );

  const entryRootIssues = run((iface) => {
    (iface.interfaces[entryIndex!] as unknown as Record<string, unknown>).interfaceRoot = "0xzz";
  });
  assert.ok(
    entryRootIssues.includes(
      `artifact.dockInterface.interfaces[${entryIndex}].interfaceRoot must be a lowercase 32-byte hex hash`,
    ),
    `expected explicit interfaceRoot issue, got: ${JSON.stringify(entryRootIssues)}`,
  );

  const definitionRootIssues = run((iface) => {
    (iface as unknown as Record<string, unknown>).interfaceRoot = "0xzz";
  });
  assert.ok(
    definitionRootIssues.includes(
      "artifact.dockInterface.interfaceRoot must be a lowercase 32-byte hex hash",
    ),
    `expected explicit definition-level interfaceRoot issue, got: ${JSON.stringify(definitionRootIssues)}`,
  );
});

test("rejects undeclared extra fields on HookPlan artifacts", () => {
  const plan = compileZhixuHookPlan(baseZhixu, demoManifest);
  const withExtra = resign({ ...plan, note: "hand-added" });
  assert.deepEqual(validateHookPlanArtifact(withExtra), [
    "unknown field `note` on the artifact — planHash does not cover undeclared fields, so the artifact would not be the plan's unique byte form; remove it or recompile",
  ]);
});

#!/usr/bin/env tsx
/**
 * 生成 dock v2 兼容性 golden（链轨 TS 权威实现）：
 * - `fixtures/dock/v1/manifest.json`：冻结常量、目标/父定义、resolution
 *   manifest（链轨发布面）、全部 leaf/root/hash/ID/envelope/permit golden
 *   向量；
 * - 样本定义/向量形状移植自 uvp-core 292c536 版 gen_dock_fixtures.rs
 *   （父定义 target.zhixu 随 v2 契约改为目标 name 引用），期望值由
 *   `@uvp-eth/compiler`（TS 权威承诺层）计算。
 *
 * 运行：`pnpm --filter @uvp-eth/compiler generate:dock-fixtures`（幂等重生成）。
 * TS parity/freeze、Foundry DockManifestParity、uvp-deploy verify-stack 都
 * 从同一份 manifest 消费。
 */
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { compileZhixuHookPlan } from "../src/hook-plan.js";
import {
  canonicalSignalHash,
  cloudRuntimeDomain,
  dockInputIdempotencyKey,
  dockInputPayloadHash,
  dockInstanceId,
  dockOutputIdempotencyKey,
  eip712PermitDigest,
  evmRuntimeDomain,
  hookKey,
  interfaceNameKey,
  linkedOrderId,
  localOrderKey,
  merkleProof,
  signalKey,
  sourceFactSetHash,
  DEFINITION_UID_DOMAIN,
  DOMAIN_DEFINITION_REF,
  DOMAIN_DOCK_INSTANCE,
  DOMAIN_DOCK_ORDER,
  DOMAIN_INTERFACE,
  DOMAIN_INTERFACE_INPUT,
  DOMAIN_INTERFACE_OUTPUT,
  DOMAIN_INPUT_BINDING,
  DOMAIN_INPUT_IDEMPOTENCY,
  DOMAIN_INPUT_PAYLOAD,
  DOMAIN_OUTPUT_BINDING,
  DOMAIN_OUTPUT_IDEMPOTENCY,
  DOMAIN_ROUTE,
  DOMAIN_ROUTE_ID,
  DOMAIN_RUNTIME_CLOUD,
  DOMAIN_RUNTIME_EIP155,
  DOMAIN_SOURCE_FACT_SET,
  EMPTY_MERKLE_ROOT,
  MAX_DOCK_DEPTH,
  MAX_DOCK_INPUTS,
  MAX_DOCK_OUTPUTS,
  MAX_PORT_NAME_BYTES,
  PERMIT_DOMAIN_VERSION,
  PERMIT_TYPEHASH,
} from "../src/dock.js";
import {
  DOCK_INTERFACE_ARTIFACT_SCHEMA_VERSION,
  DOCK_RESOLUTION_SCHEMA_VERSION,
  DOCK_ROUTE_SCHEMA_VERSION,
  type DockResolutionManifest,
  type DockRouteV2,
  type HexString,
  type ZhixuDefinition,
} from "../src/types/index.js";

/** 目标定义：两个具名接口——production_service[new]（建单型服务）与 production_evidence[existing]（只读既有事实）。 */
function targetProductionDefinition(): ZhixuDefinition {
  return {
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: { name: "friction_wheel_production" },
    spec: {
      platform: { type: "cloud" },
      nucleation: { id: "production-core" },
      dockInterface: {
        production_service: {
          orderModes: ["new"],
          inputs: {
            execute: { hook: "manufacturing.intake#EXECUTE" },
            amend: { hook: "manufacturing.produce#DOCK_AMEND" },
          },
          outputs: {
            started: { signal: "factory::manufacturing.intake.str" },
            completed: { signal: "factory::manufacturing.produce.cmp" },
          },
        },
        production_evidence: {
          orderModes: ["existing"],
          outputs: {
            scrap_declared: {
              signal: "factory::manufacturing.produce.scrap_created",
            },
          },
        },
      },
      taskPatterns: [
        {
          name: "manufacturing",
          stages: [
            {
              name: "intake",
              source: "factory",
              receiveSignals: {
                EXECUTE: "factory::manufacturing.intake.execute",
              },
              sendSignals: ["str"],
              executor: {
                supplierType: "organization",
                supplierID: "friction-factory",
              },
            },
            {
              name: "produce",
              source: "factory",
              receiveSignals: {
                RUN: "factory::manufacturing.intake.str",
                DOCK_AMEND: "factory::manufacturing.produce.amend",
              },
              sendSignals: ["cmp", "scrap_created"],
              executor: {
                supplierType: "organization",
                supplierID: "friction-factory",
              },
            },
          ],
        },
      ],
    },
  };
}

/** 调用方定义：new 模式生产委托（建单型委托）+ existing 模式既有事实引用（只读引用）。目标按 name 引用（v2 契约：DSL 壳不携带派生身份）。 */
function parentSourcingDefinition(targetName: string): ZhixuDefinition {
  return {
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: { name: "sourcing" },
    spec: {
      platform: { type: "cloud" },
      nucleation: { id: "sourcing-core" },
      taskPatterns: [
        {
          name: "procurement",
          stages: [
            {
              name: "confirm",
              source: "purchaser",
              // 物化门：零 hook 阶段在链上永不可物化、信号没有
              // 钩子可挂；seed 是执行者自发入口信号。
              receiveSignals: { ORDER: "purchaser::procurement.confirm.seed" },
              sendSignals: ["cmp", "seed"],
              executor: {
                supplierType: "organization",
                supplierID: "purchaser-app",
              },
            },
          ],
        },
        {
          name: "sourcing",
          stages: [
            {
              name: "manufacture",
              source: "purchaser",
              receiveSignals: {
                EXECUTE: "purchaser::procurement.confirm.cmp",
              },
              sendSignals: ["str", "cmp"],
              executor: {
                supplierType: "zhixu",
                zhixuExecutorConfig: {
                  target: { zhixu: targetName },
                  interface: "production_service",
                  order: { mode: "new" },
                  inputMap: { EXECUTE: "execute" },
                  signalMap: { str: "started", cmp: "completed" },
                },
              },
            },
            {
              name: "source_evidence",
              source: "recycler",
              receiveSignals: {
                READ: "recycler::sourcing.source_evidence.seed",
              },
              sendSignals: ["cmp", "seed"],
              executor: {
                supplierType: "zhixu",
                zhixuExecutorConfig: {
                  target: { zhixu: targetName },
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
}

function buildManifest(
  target: ZhixuDefinition,
  targetPlan: ReturnType<typeof compileZhixuHookPlan>,
): DockResolutionManifest {
  const interfaceArtifact = targetPlan.dockInterface;
  if (interfaceArtifact === null) {
    throw new Error("dock golden target must publish a dockInterface");
  }
  return {
    schemaVersion: DOCK_RESOLUTION_SCHEMA_VERSION,
    definitions: [
      {
        zhixu: targetPlan.zhixuId,
        definition: target,
        definitionRefHash: interfaceArtifact.definition.definitionRefHash,
        artifactHash: targetPlan.planHash,
        published: true,
        interfaces: interfaceArtifact.interfaces,
        evmPlanId: targetPlan.planId,
        cloudArtifactId: `artifact://${targetPlan.planHash}`,
      },
    ],
  };
}

function findRoute(
  routes: readonly DockRouteV2[],
  interfaceName: string,
): DockRouteV2 {
  const route = routes.find(
    (candidate) => candidate.target.interfaceName === interfaceName,
  );
  if (route === undefined) {
    throw new Error(`dock golden parent must expose a route on ${interfaceName}`);
  }
  return route;
}

async function main(): Promise<void> {
  const target = targetProductionDefinition();
  const parent = parentSourcingDefinition(target.metadata.name);

  const targetPlan = compileZhixuHookPlan(target);
  const manifest = buildManifest(target, targetPlan);
  const parentPlan = compileZhixuHookPlan(parent, manifest);
  const routes = parentPlan.dockRoutes;
  const serviceRoute = findRoute(routes, "production_service");
  const evidenceRoute = findRoute(routes, "production_evidence");
  const targetInterface = targetPlan.dockInterface;
  if (targetInterface === null) {
    throw new Error("unreachable: target interface artifact checked in buildManifest");
  }
  const serviceInterface = targetInterface.interfaces.find(
    (entry) => entry.name === "production_service",
  )!;
  void serviceInterface;

  // ---- runtime domains & identity vectors ----
  const chainId = 31337;
  const stateMachine = "0x5FbDB2315678afecb367f032d93F642f64180aa3";
  const dockingModule = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512";
  const permitDomainVersion = PERMIT_DOMAIN_VERSION;
  const evmDomain = evmRuntimeDomain(chainId, stateMachine);
  const cloudDomain = cloudRuntimeDomain(
    "uvp-cloud-deployment-fixture",
    "uvp-cloud-security-fixture",
  );
  const parentOrderKey = localOrderKey("order-fixture-001");
  // new 模式：route 身份 + 本地单（幂等建单锚，A06）+ targetPlanId（实例
  // 身份绑定对接目标 plan）。合成向量必须与产物 route.local.planId 同源，
  // 否则消费方会在生产推导里得到不同实例。
  const dockInstance = dockInstanceId({
    runtimeDomain: evmDomain,
    localPlanId: parentPlan.planId,
    localDefinitionRefHash: serviceRoute.local.definitionRefHash,
    localOrderKey: parentOrderKey,
    routeId: serviceRoute.routeId,
    routeHash: serviceRoute.routeHash,
    orderMode: "new",
    interfaceName: "production_service",
    targetPlanId: targetPlan.planId,
  });
  const linkedOrder = linkedOrderId(
    dockInstance,
    serviceRoute.target.definitionRefHash,
  );
  // existing 模式：派生加入 target order 引用（A07；云轨运行时语义）。
  const existingDockInstance = dockInstanceId({
    runtimeDomain: cloudDomain,
    localPlanId: parentPlan.planId,
    localDefinitionRefHash: evidenceRoute.local.definitionRefHash,
    localOrderKey: parentOrderKey,
    routeId: evidenceRoute.routeId,
    routeHash: evidenceRoute.routeHash,
    orderMode: "existing",
    interfaceName: "production_evidence",
    targetPlanId: targetPlan.planId,
    targetOrderRef: "factory-a/P001",
  });

  // ---- input envelope（new 模式：唯一 input 绑定即出生锚）----
  const birthBinding = serviceRoute.inputBindings.find(
    (binding) => binding.targetPort === "execute",
  )!;
  const sourceFactSet = sourceFactSetHash([
    canonicalSignalHash("purchaser::procurement.confirm.cmp"),
  ]);
  const inputPayload = dockInputPayloadHash({
    dockInstanceId: dockInstance,
    routeHash: serviceRoute.routeHash,
    localPlanId: parentPlan.planId,
    localOrderId: parentOrderKey,
    localStageId: serviceRoute.local.stageKey,
    localHookId: hookKey("sourcing.manufacture#EXECUTE"),
    targetPlanId: targetPlan.planId,
    linkedOrderId: linkedOrder,
    targetPort: "execute",
    targetSignalId: birthBinding.targetSignalId,
    sequence: 0,
  });
  const inputIdempotency = dockInputIdempotencyKey({
    dockInstanceId: dockInstance,
    inputBindingHash: birthBinding.bindingHash,
    localHookReadyOccurrence: 0n,
  });

  // ---- output envelope ----
  const completedOutput = serviceRoute.outputBindings.find(
    (binding) => binding.localSignalName === "cmp",
  )!;
  const targetFactId = signalKey(
    interfaceNameKey("factory") as HexString,
    interfaceNameKey("manufacturing.produce.cmp") as HexString,
  );
  const outputIdempotency = dockOutputIdempotencyKey({
    dockInstanceId: dockInstance,
    outputBindingHash: completedOutput.bindingHash,
    targetFactId,
  });

  // ---- entrance permit digest ----
  const permitDigest = eip712PermitDigest({
    chainId,
    verifyingContract: dockingModule,
    version: permitDomainVersion,
    targetPlanId: targetPlan.planId,
    targetEntrancePortId: interfaceNameKey("execute"),
    interfaceNameId: interfaceNameKey("production_service"),
    localPlanId: parentPlan.planId,
    routeHash: serviceRoute.routeHash,
    dockInstanceId: dockInstance,
    linkedOrderId: linkedOrder,
    nonce: 1,
    deadline: 2000000000,
  });

  // ---- merkle proofs（供 Foundry/TS 测试对齐）----
  const routeLeafProof = merkleProof(
    routes.map((route) => route.routeHash),
    serviceRoute.routeHash,
  )!;
  const interfaceLeafProof = merkleProof(
    targetInterface.interfaces.map((entry) => entry.interfaceRoot),
    serviceInterface.interfaceRoot,
  )!;
  const executeLeaf = serviceInterface.inputs.find(
    (port) => port.port === "execute",
  )!.leafHash;
  const inputPortLeafProof = merkleProof(
    serviceInterface.inputs.map((port) => port.leafHash),
    executeLeaf,
  )!;

  const compat = {
    schemaVersion: "uvp.dock.compat.v1",
    constants: {
      schemaVersions: {
        dockInterfaceArtifact: DOCK_INTERFACE_ARTIFACT_SCHEMA_VERSION,
        dockRoute: DOCK_ROUTE_SCHEMA_VERSION,
        resolution: DOCK_RESOLUTION_SCHEMA_VERSION,
      },
      domains: {
        definitionUid: DEFINITION_UID_DOMAIN,
        definitionRef: DOMAIN_DEFINITION_REF,
        dockInterface: DOMAIN_INTERFACE,
        interfaceInput: DOMAIN_INTERFACE_INPUT,
        interfaceOutput: DOMAIN_INTERFACE_OUTPUT,
        routeId: DOMAIN_ROUTE_ID,
        inputBinding: DOMAIN_INPUT_BINDING,
        outputBinding: DOMAIN_OUTPUT_BINDING,
        route: DOMAIN_ROUTE,
        dockInstance: DOMAIN_DOCK_INSTANCE,
        dockOrder: DOMAIN_DOCK_ORDER,
        runtimeEip155: DOMAIN_RUNTIME_EIP155,
        runtimeCloud: DOMAIN_RUNTIME_CLOUD,
        inputPayload: DOMAIN_INPUT_PAYLOAD,
        inputIdempotency: DOMAIN_INPUT_IDEMPOTENCY,
        outputIdempotency: DOMAIN_OUTPUT_IDEMPOTENCY,
        sourceFactSet: DOMAIN_SOURCE_FACT_SET,
      },
      limits: {
        maxDockInputs: MAX_DOCK_INPUTS,
        maxDockOutputs: MAX_DOCK_OUTPUTS,
        maxDockDepth: MAX_DOCK_DEPTH,
        maxPortNameBytes: MAX_PORT_NAME_BYTES,
      },
      merkle: {
        emptyRoot: EMPTY_MERKLE_ROOT,
        pairRule: "keccak256(min(a,b) || max(a,b)) bytewise",
        leafOrder: "sorted-unique leaves, odd tail promoted",
      },
      enumWords: {
        orderMode: { new: 0, existing: 1 },
        orderModesMask: { new: 1, existing: 2 },
      },
      permitTypeHash: PERMIT_TYPEHASH,
      permitDomainVersion,
    },
    inputs: {
      chainId,
      stateMachineAddress: stateMachine,
      dockingModuleAddress: dockingModule,
      cloudDeploymentId: "uvp-cloud-deployment-fixture",
      cloudSecurityDomain: "uvp-cloud-security-fixture",
      localOrderId: "order-fixture-001",
      existingTargetOrderRef: "factory-a/P001",
      parentPlanIdWord: parentPlan.planId,
    },
    identities: {
      targetUid: targetPlan.zhixuId,
      parentUid: parentPlan.zhixuId,
    },
    targetDefinition: target,
    parentDefinition: parent,
    resolutionManifest: manifest,
    expected: {
      targetDefinitionRefHash: targetPlan.dockInterface!.definition.definitionRefHash,
      parentDefinitionRefHash: serviceRoute.local.definitionRefHash,
      targetPlanId: targetPlan.planId,
      targetArtifactHash: targetPlan.planHash,
      interfaceArtifact: targetInterface,
      interfaceNameIds: {
        production_service: interfaceNameKey("production_service"),
        production_evidence: interfaceNameKey("production_evidence"),
      },
      dockRoutes: routes,
      dockRoutesRoot: parentPlan.dockRoutesRoot,
      dockInterfaceRoot: parentPlan.dockInterfaceRoot,
      evmRuntimeDomain: evmDomain,
      cloudRuntimeDomain: cloudDomain,
      localOrderKey: parentOrderKey,
      dockInstanceId: dockInstance,
      linkedOrderId: linkedOrder,
      existingDockInstanceId: existingDockInstance,
      sourceFactSetHash: sourceFactSet,
      inputPayloadHash: inputPayload,
      inputIdempotencyKey: inputIdempotency,
      outputIdempotencyKey: outputIdempotency,
      permitDigest,
      routeLeafProof,
      interfaceLeafProof,
      inputPortLeafProof,
    },
  };

  const fixtureDir = resolve(
    dirname(fileURLToPath(import.meta.url)),
    "../fixtures/dock/v1",
  );
  await mkdir(fixtureDir, { recursive: true });
  await writeFile(
    resolve(fixtureDir, "manifest.json"),
    `${JSON.stringify(compat, null, 2)}\n`,
    "utf8",
  );
  console.log(`dock fixtures regenerated at ${fixtureDir}`);
}

await main();

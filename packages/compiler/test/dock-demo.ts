import { compileZhixuHookPlan } from "../src/hook-plan.js";
import type {
  DockResolutionManifest,
  ZhixuDefinition,
} from "../src/types/index.js";

/**
 * 测试用 dock 目标/manifest 构造器：镜像 uvp-core gen_dock_fixtures 的
 * 样本形状，把目标编译产物组装成 resolution manifest v2 供父定义 link。
 */

export function dockProductionTargetDefinition(): ZhixuDefinition {
  return {
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: {
      name: "friction_wheel_production",
    },
    spec: {
      platform: { type: "cloud" },
      nucleation: { id: "production-core" },
      dockInterface: {
        production_service: {
          orderModes: ["new"],
          inputs: {
            execute: { hook: "intake#EXECUTE" },
            amend: { hook: "produce#DOCK_AMEND" },
          },
          outputs: {
            started: { signal: "factory::intake.str" },
            completed: { signal: "factory::produce.cmp" },
          },
        },
        production_evidence: {
          orderModes: ["existing"],
          outputs: {
            scrap_declared: {
              signal: "factory::produce.scrap_created",
            },
          },
        },
      },
      stages: [
        {
          name: "intake",
          source: "factory",
          receiveSignals: {
            EXECUTE: "factory::intake.execute",
          },
          sendSignals: [{ name: "str" }],
          executor: {
            supplierType: "organization",
            supplierID: "friction-factory",
          },
        },
        {
          name: "produce",
          source: "factory",
          receiveSignals: {
            RUN: "factory::intake.str",
            DOCK_AMEND: "factory::produce.amend",
          },
          sendSignals: [{ name: "cmp" }, { name: "scrap_created" }],
          executor: {
            supplierType: "organization",
            supplierID: "friction-factory",
          },
        },
      ],
    },
  };
}

export const dockDemoTargetName = "friction_wheel_production";

export function dockDemoTargetUid(): string {
  return dockDemoResolutionManifest().definitions[0]!.zhixu;
}

export function dockSourcingParentDefinition(targetUid: string): ZhixuDefinition {
  return {
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: {
      name: "sourcing",
    },
    spec: {
      platform: { type: "cloud" },
      nucleation: { id: "sourcing-core" },
      stages: [
        {
          name: "confirm",
          source: "purchaser",
          receiveSignals: { ORDER: "purchaser::confirm.seed" },
          sendSignals: [{ name: "cmp" }, { name: "seed" }],
          executor: {
            supplierType: "organization",
            supplierID: "purchaser-app",
          },
        },
        {
          name: "manufacture",
          source: "purchaser",
          receiveSignals: {
            EXECUTE: "purchaser::confirm.cmp",
          },
          sendSignals: [{ name: "str" }, { name: "cmp" }],
          executor: {
            supplierType: "zhixu",
            zhixuExecutorConfig: {
              target: { zhixu: targetUid },
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
            READ: "recycler::source_evidence.seed",
          },
          sendSignals: [{ name: "cmp" }, { name: "seed" }],
          executor: {
            supplierType: "zhixu",
            zhixuExecutorConfig: {
              target: { zhixu: targetUid },
              interface: "production_evidence",
              order: { mode: "existing" },
              signalMap: { cmp: "scrap_declared" },
            },
          },
        },
      ],
    },
  };
}

export function dockDemoResolutionManifest(): DockResolutionManifest {
  return resolutionManifestFor(dockProductionTargetDefinition());
}

export function resolutionManifestFor(
  targetDefinition: ZhixuDefinition,
): DockResolutionManifest {
  const target = compileZhixuHookPlan(targetDefinition);
  if (target.dockInterface === null) {
    throw new Error("dock demo target must publish a dockInterface");
  }
  return {
    schemaVersion: "uvp.dock.resolution.v2",
    definitions: [
      {
        zhixu: target.zhixuId,
        definition: targetDefinition,
        definitionRefHash: target.dockInterface.definition.definitionRefHash,
        artifactHash: target.planHash,
        published: true,
        interfaces: target.dockInterface.interfaces,
        evmPlanId: target.planId,
        chainPlanId: target.planId,
        cloudArtifactId: `artifact://${target.planHash}`,
      },
    ],
  };
}

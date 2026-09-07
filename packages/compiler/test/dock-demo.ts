import { compileZhixuHookPlan } from "../src/hook-plan.js";
import type {
  DockResolutionManifest,
  ZhixuDefinition,
} from "../src/types/index.js";

/**
 * 测试用 dock 目标/manifest 构造器（镜像 Store/发布系统流程与
 * uvp-core `gen_dock_fixtures` 的样本形状）：先编译目标定义（含双具名接口
 * dockInterface、无 zhixu executor），再把其产物组装成 resolution
 * manifest v2 供父定义 link。
 */

/** 目标定义：两个具名接口——production_service[new]（建单型服务）与 production_evidence[existing]（只读既有事实）。 */
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

/** 调用方定义：new 模式生产委托 + existing 模式既有事实引用，各一条 route。 */
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
      taskPatterns: [
        {
          name: "procurement",
          stages: [
            {
              name: "confirm",
              source: "purchaser",
              // P0-4 物化门：零 hook 阶段在链上永不可物化；seed 是执行者
              // 自发入口信号。
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
                READ: "recycler::sourcing.source_evidence.seed",
              },
              sendSignals: ["cmp", "seed"],
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
      ],
    },
  };
}

/**
 * 组装 resolution manifest v2：zhixu/definitionRefHash/interfaces 直接取自
 * 目标编译产物（zhixuId 即内容派生 uid），并内嵌目标定义全文（内容寻址，
 * linker 重算 uid 三方一致校验）。
 */
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
        cloudArtifactId: `artifact://${target.planHash}`,
      },
    ],
  };
}

/** demo 目标的内容派生身份（zx-<32hex>），供调用方定义的 target.zhixu 引用。 */
export function dockDemoTargetUid(): string {
  return dockDemoResolutionManifest().definitions[0]!.zhixu;
}

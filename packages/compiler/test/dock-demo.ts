import { compileZhixuHookPlan } from "../src/hook-plan.js";
import type {
  DockResolutionManifest,
  ZhixuDefinition,
} from "../src/types/index.js";

/**
 * 测试用 dock 目标/manifest 构造器（镜像 Store/发布系统流程）：
 * 先编译目标定义（含 dockInterface、无 zhixu executor），再把其产物
 * 组装成 resolution manifest 供父定义 link。
 */

export function dockPaymentTargetDefinition(): ZhixuDefinition {
  return {
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: {
      name: "payment_execution",
      uid: "payment-zhixu",
      annotations: { version: "1.2.0" },
    },
    spec: {
      platform: { type: "cloud" },
      nucleation: { id: "payment-core" },
      dockInterface: {
        schemaVersion: "uvp.dock.v1",
        inputs: {
          execute: {
            kind: "entrance",
            hook: "payment_flow.init#DOCK_EXECUTE",
            access: { policy: "open" },
          },
          cancel: {
            kind: "signal",
            hook: "payment_flow.control#DOCK_CANCEL",
            access: { policy: "linked" },
          },
        },
        outputs: {
          started: { signal: "payment::payment_flow.init.str" },
          completed: {
            signal: "payment::payment_flow.settle.cmp",
            terminal: "success",
          },
          failed: {
            signal: "payment::payment_flow.settle.err",
            terminal: "failure",
          },
        },
      },
      taskPatterns: [
        {
          name: "payment_flow",
          stages: [
            {
              name: "init",
              source: "payment",
              receiveSignals: {
                DOCK_EXECUTE: "payment::payment_flow.init.execute",
              },
              sendSignals: ["str"],
              executor: {
                supplierType: "organization",
                supplierID: "payment-gateway",
              },
            },
            {
              name: "control",
              source: "payment",
              receiveSignals: {
                DOCK_CANCEL: "payment::payment_flow.control.cancel",
              },
              sendSignals: ["cxl"],
              executor: {
                supplierType: "organization",
                supplierID: "payment-gateway",
              },
            },
            {
              name: "settle",
              source: "payment",
              receiveSignals: {
                SETTLE: "payment::payment_flow.init.str",
              },
              sendSignals: ["cmp", "err"],
              executor: {
                supplierType: "organization",
                supplierID: "payment-gateway",
              },
            },
          ],
        },
      ],
    },
  };
}

export function dockDemoResolutionManifest(): DockResolutionManifest {
  const target = compileZhixuHookPlan(dockPaymentTargetDefinition());
  if (target.dockInterface === null) {
    throw new Error("payment target must publish a dockInterface");
  }
  return {
    schemaVersion: "uvp.dock.resolution.v1",
    definitions: [
      {
        zhixu: "payment-zhixu",
        version: "1.2.0",
        definitionRefHash:
          target.dockInterface.definition.definitionRefHash,
        artifactHash: target.planHash,
        published: true,
        interface: target.dockInterface,
        evmPlanId: target.planId,
        cloudArtifactId: `artifact://${target.planHash}`,
      },
    ],
  };
}

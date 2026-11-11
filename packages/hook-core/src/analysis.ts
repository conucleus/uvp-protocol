import type { HookDependency, HookExpressionAst } from "./types.js";

/**
 * 中立分析（uvp.zhixuAnalysis.v2）请求/响应类型：uvp-core 只做共享 DSL 校验与
 * hook 解析，chain hook 装饰与 hook_plan shell 总装归链轨编译器。
 */

export const ZHIXU_ANALYSIS_SCHEMA_VERSION = "uvp.zhixuAnalysis.v2" as const;

export interface ZhixuAnalysisRequest {
  readonly definition: unknown;
  readonly dockTargets?: unknown;
  readonly allowUnresolved?: boolean;
}

export interface ZhixuAnalysisSendSignal {
  readonly name: string;
  readonly validWhen: readonly string[] | null;
}

export interface ZhixuAnalysisHook {
  readonly hookName: string;
  readonly rawExpression: string;
  readonly normalizedExpression: string;
  readonly ast: HookExpressionAst;
  readonly dependencies: readonly HookDependency[];
}

export interface ZhixuAnalysisStage {
  readonly stageIdentifier: string;
  readonly source: string;
  readonly triggers: readonly string[];
  readonly executor: unknown;
  readonly selectedStages: readonly string[];
  readonly fileWriters: readonly string[];
  readonly fileResources: Readonly<Record<string, unknown>>;
  readonly sendSignals: readonly ZhixuAnalysisSendSignal[];
  readonly hooks: readonly ZhixuAnalysisHook[];
}

export interface ZhixuAnalysis {
  readonly schemaVersion: typeof ZHIXU_ANALYSIS_SCHEMA_VERSION;
  readonly zhixuName: string;
  readonly platform: unknown;
  readonly stages: readonly ZhixuAnalysisStage[];
  readonly dockEntranceHookIds: readonly string[];
  readonly selectedStageBindings: readonly unknown[];
  readonly dockInterface: unknown;
  readonly dockRoutes: readonly unknown[];
  readonly unresolvedDockRoutes: readonly unknown[];
  readonly signalCapabilities: readonly unknown[];
  readonly admissions: readonly unknown[];
}

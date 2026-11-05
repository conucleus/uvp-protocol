import { compareByCodePoint } from "@uvp-eth/canonical-json";
import type {
  HookDependency,
  HookExpressionAst,
  ZhixuAnalysis,
  ZhixuAnalysisHook,
  ZhixuAnalysisStage,
} from "@uvp-eth/hook-core";
import type { HookPlanShell } from "../dock-commitments.js";
import {
  HOOK_PLAN_SCHEMA_VERSION,
  type CompiledHookPlanAdmission,
  type CompiledHookPlanHook,
  type ExecuteConfigs,
  type FileResourceLike,
  type HookPlanExecutorRoute,
  type NeutralDockRoute,
  type NeutralInterfaceDeclaration,
  type NeutralUnresolvedDockRoute,
  type OrderTriggerKind,
  type SelectedStageBinding,
  type SignalCapability,
} from "../types/index.js";

/**
 * Chain hook_plan shell 总装：analyze 只给共享校验与 hook 解析结果，本模块补
 * order-trigger/emit-ready/route 装饰与 dependencyIndex/executorRoutes，输出
 * 既有的 hookPlan.v4 shell 形态。
 */

const IMPLICIT_ENTRY_HOOK_NAME = "str";

export interface LoweredHookPlanShell extends HookPlanShell {
  readonly compiledHooks: readonly CompiledHookPlanHook[];
  readonly executorRoutes: Record<string, HookPlanExecutorRoute>;
  readonly dockRoutes: readonly NeutralDockRoute[];
  readonly dockInterface?: readonly NeutralInterfaceDeclaration[];
  readonly unresolvedDockRoutes?: readonly NeutralUnresolvedDockRoute[];
  readonly selectedStageBindings: readonly SelectedStageBinding[];
  readonly signalCapabilities: readonly SignalCapability[];
  readonly admissions: readonly CompiledHookPlanAdmission[];
}

interface HookDecoration {
  readonly hookName: string;
  readonly rawExpression: string;
  readonly normalizedExpression: string;
  readonly ast: HookExpressionAst;
  readonly dependencies: readonly HookDependency[];
  readonly orderTriggerKind: OrderTriggerKind;
  readonly emitReady: boolean;
}

export function lowerHookPlanShell(
  analysis: ZhixuAnalysis,
): LoweredHookPlanShell {
  const entryHook = analysis.entryHook;
  if (analysis.implicitEntry !== null && entryHook === null) {
    throw new Error(
      "uvp-core analyze returned an implicit entry stage without its parsed entry hook",
    );
  }

  const compiledHooks: CompiledHookPlanHook[] = [];
  const executorRoutes: Record<string, HookPlanExecutorRoute> = {};
  const dependencyHookIds = new Map<string, Set<string>>();

  for (const stage of analysis.stages) {
    const route = executorRouteOf(stage);
    const stageHooks: CompiledHookPlanHook[] = [];
    if (analysis.implicitEntry === stage.stageIdentifier && entryHook !== null) {
      stageHooks.push(
        compileHook(stage, route, {
          hookName: IMPLICIT_ENTRY_HOOK_NAME,
          ...entryHook,
          orderTriggerKind: "mint",
          emitReady: true,
        }),
      );
    }
    for (const hook of orderedStageHooks(stage)) {
      const hookId = stageHookId(stage, hook);
      const orderTriggerKind: OrderTriggerKind =
        stage.mint !== null
          ? "mint"
          : analysis.dockEntranceHookIds.includes(hookId)
            ? "dock"
            : "none";
      stageHooks.push(
        compileHook(stage, route, {
          ...hook,
          orderTriggerKind,
          emitReady:
            orderTriggerKind !== "none" ||
            stage.executor !== null,
        }),
      );
    }
    for (const hook of stageHooks) {
      compiledHooks.push(hook);
      for (const dependency of hook.dependencies) {
        const key = `${dependency.source}::${dependency.signalName}`;
        const hookIds = dependencyHookIds.get(key) ?? new Set<string>();
        hookIds.add(hook.hookId);
        dependencyHookIds.set(key, hookIds);
      }
    }
    if (route !== undefined) {
      executorRoutes[stage.stageIdentifier] = route;
    }
  }

  const dependencyIndex = Object.fromEntries(
    [...dependencyHookIds.entries()]
      .sort(([left], [right]) => compareByCodePoint(left, right))
      .map(([key, hookIds]) => [
        key,
        [...hookIds].sort(compareByCodePoint),
      ]),
  );

  return {
    schemaVersion: HOOK_PLAN_SCHEMA_VERSION,
    zhixuName: analysis.zhixuName,
    platform: analysis.platform,
    compiledHooks,
    dependencyIndex,
    executorRoutes,
    ...(analysis.dockInterface === null ||
    analysis.dockInterface === undefined
      ? {}
      : {
          dockInterface:
            analysis.dockInterface as readonly NeutralInterfaceDeclaration[],
        }),
    dockRoutes: analysis.dockRoutes as readonly NeutralDockRoute[],
    ...(analysis.unresolvedDockRoutes === undefined ||
    analysis.unresolvedDockRoutes.length === 0
      ? {}
      : {
          unresolvedDockRoutes:
            analysis.unresolvedDockRoutes as readonly NeutralUnresolvedDockRoute[],
        }),
    selectedStageBindings:
      analysis.selectedStageBindings as readonly SelectedStageBinding[],
    signalCapabilities:
      analysis.signalCapabilities as readonly SignalCapability[],
    admissions: analysis.admissions as readonly CompiledHookPlanAdmission[],
  };
}

function orderedStageHooks(
  stage: ZhixuAnalysisStage,
): readonly ZhixuAnalysisHook[] {
  return [...stage.hooks].sort((left, right) =>
    compareByCodePoint(
      stageHookId(stage, left).toLowerCase(),
      stageHookId(stage, right).toLowerCase(),
    ),
  );
}

function stageHookId(stage: ZhixuAnalysisStage, hook: ZhixuAnalysisHook): string {
  return `${stage.stageIdentifier}#${hook.hookName}`;
}

function compileHook(
  stage: ZhixuAnalysisStage,
  route: HookPlanExecutorRoute | undefined,
  decoration: HookDecoration,
): CompiledHookPlanHook {
  return {
    hookId: `${stage.stageIdentifier}#${decoration.hookName}`,
    kind: "receive",
    stageIdentifier: stage.stageIdentifier,
    hookName: decoration.hookName,
    orderTriggerKind: decoration.orderTriggerKind,
    emitReady: decoration.emitReady,
    rawExpression: decoration.rawExpression,
    normalizedExpression: decoration.normalizedExpression,
    ast: decoration.ast,
    dependencies: decoration.dependencies,
    ...(route === undefined ? {} : { route }),
  };
}

function executorRouteOf(
  stage: ZhixuAnalysisStage,
): HookPlanExecutorRoute | undefined {
  const executor = stage.executor;
  if (executor === null || executor === undefined) {
    return undefined;
  }
  if (isZhixuExecutor(executor)) {
    return undefined;
  }
  const fileResources = stage.fileResources;
  return {
    stageIdentifier: stage.stageIdentifier,
    executor: executor as ExecuteConfigs,
    ...(Object.keys(fileResources).length === 0
      ? {}
      : { fileResources: fileResources as Record<string, FileResourceLike> }),
  };
}

function isZhixuExecutor(executor: unknown): boolean {
  return (
    typeof executor === "object" &&
    executor !== null &&
    (executor as { readonly supplierType?: unknown }).supplierType === "zhixu"
  );
}

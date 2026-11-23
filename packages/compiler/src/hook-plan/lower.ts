import { compareByCodePoint } from "@uvp-eth/canonical-json";
import type {
  HookDependency,
  HookExpressionAst,
  ZhixuAnalysis,
  ZhixuAnalysisHook,
  ZhixuAnalysisStage,
} from "@uvp-eth/hook-core";
import type { HookPlanShell } from "./assemble.js";
import {
  HOOK_PLAN_SCHEMA_VERSION,
  type CompiledHookPlanAdmission,
  type CompiledHookPlanHook,
  type ExecuteConfigs,
  type FileResourceLike,
  type HookPlanSupplierRoute,
  type OrderTriggerKind,
  type SelectedStageBinding,
  type SignalCapability,
} from "../types/index.js";

/**
 * Chain hook_plan shell 总装：analyze 只给共享校验与 hook 解析结果，本模块按
 * stage.triggers 的每个信号合成一条 order-trigger hook，并补 emit-ready/route/
 * dock/dynamic executor 装饰与 dependencyIndex/supplierRoutes，输出 hookPlan.v1
 * shell 形态。
 */

export interface LoweredHookPlanShell extends HookPlanShell {
  readonly compiledHooks: readonly CompiledHookPlanHook[];
  readonly supplierRoutes: Record<string, HookPlanSupplierRoute>;
  readonly selectedStageBindings: readonly SelectedStageBinding[];
  readonly signalCapabilities: readonly SignalCapability[];
  readonly admissions: readonly CompiledHookPlanAdmission[];
}

export function lowerHookPlanShell(
  analysis: ZhixuAnalysis,
): LoweredHookPlanShell {
  const compiledHooks: CompiledHookPlanHook[] = [];
  const supplierRoutes: Record<string, HookPlanSupplierRoute> = {};
  const dependencyHookIds = new Map<string, Set<string>>();

  for (const stage of analysis.stages) {
    const route = supplierRouteOf(stage);
    const receiveHooks = orderedStageHooks(stage).map((hook) =>
      compileReceiveHook(stage, route, hook),
    );
    const receiveHookNames = new Set(
      receiveHooks.map((hook) => hook.hookName),
    );
    const triggerHooks = stage.triggers.map((trigger) =>
      compileTriggerHook(stage, route, trigger, receiveHookNames),
    );
    for (const hook of [...triggerHooks, ...receiveHooks]) {
      compiledHooks.push(hook);
      for (const dependency of hook.dependencies) {
        const key = `${dependency.source}::${dependency.signalName}`;
        const hookIds = dependencyHookIds.get(key) ?? new Set<string>();
        hookIds.add(hook.hookId);
        dependencyHookIds.set(key, hookIds);
      }
    }
    if (route !== undefined) {
      supplierRoutes[stage.stageIdentifier] = route;
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
    supplierRoutes,
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

function compileReceiveHook(
  stage: ZhixuAnalysisStage,
  route: HookPlanSupplierRoute | undefined,
  hook: ZhixuAnalysisHook,
): CompiledHookPlanHook {
  const orderTriggerKind: OrderTriggerKind = "none";
  return {
    hookId: stageHookId(stage, hook),
    kind: "receive",
    stageIdentifier: stage.stageIdentifier,
    hookName: hook.hookName,
    orderTriggerKind,
    emitReady: true,
    dockExecutor: isDockSupplier(stage.executor),
    dynamicExecutor: stage.executor === null || stage.executor === undefined,
    rawExpression: hook.rawExpression,
    normalizedExpression: hook.normalizedExpression,
    ast: hook.ast,
    dependencies: hook.dependencies,
    ...(route === undefined ? {} : { route }),
  };
}

function compileTriggerHook(
  stage: ZhixuAnalysisStage,
  route: HookPlanSupplierRoute | undefined,
  trigger: string,
  receiveHookNames: ReadonlySet<string>,
): CompiledHookPlanHook {
  const hookName = triggeredHookName(stage, trigger);
  if (receiveHookNames.has(hookName)) {
    throw new Error(
      `trigger signal ${trigger} of stage ${stage.stageIdentifier} collides with the `
        + `receiveSignals channel "${hookName}": the synthesized order-trigger hook and the `
        + "receive hook would share hookId <stage>#<channel>, and artifact hook ids are unique",
    );
  }
  const rawExpression = `${stage.source}::${trigger}`;
  const ast: HookExpressionAst = {
    raw: rawExpression,
    source: stage.source,
    condition: { kind: "signal", signalName: trigger },
  };
  const dependencies: readonly HookDependency[] = [
    { kind: "positive", source: stage.source, signalName: trigger },
  ];
  return {
    hookId: `${stage.stageIdentifier}#${hookName}`,
    kind: "receive",
    stageIdentifier: stage.stageIdentifier,
    hookName,
    orderTriggerKind: "trigger",
    emitReady: true,
    dockExecutor: false,
    dynamicExecutor: false,
    rawExpression,
    normalizedExpression: rawExpression,
    ast,
    dependencies,
    ...(route === undefined ? {} : { route }),
  };
}

function triggeredHookName(
  stage: ZhixuAnalysisStage,
  trigger: string,
): string {
  const prefix = `${stage.stageIdentifier}.`;
  const hookName = trigger.startsWith(prefix)
    ? trigger.slice(prefix.length)
    : undefined;
  if (hookName === undefined || hookName.length === 0) {
    throw new Error(
      `uvp-core analyze returned trigger ${JSON.stringify(trigger)} for stage `
        + `${stage.stageIdentifier}: analyze triggers must be normalized two-part `
        + "<stageIdentifier>.<signal> names",
    );
  }
  return hookName;
}

function supplierRouteOf(
  stage: ZhixuAnalysisStage,
): HookPlanSupplierRoute | undefined {
  const executor = stage.executor;
  if (executor === null || executor === undefined) {
    return undefined;
  }
  if (isDockSupplier(executor)) {
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

function isDockSupplier(executor: unknown): boolean {
  return (
    typeof executor === "object" &&
    executor !== null &&
    (executor as { readonly supplierType?: unknown }).supplierType === "dock"
  );
}

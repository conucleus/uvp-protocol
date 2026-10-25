import type {
  HookConditionAst,
  HookExpressionAst,
} from "@uvp-eth/hook-core";
import { HookPlanCompilationError } from "../../hook-plan.js";
import { OnchainHookPlanArtifactValidationError } from "../validate/artifact.js";
import {
  FILE_TYPES,
  selectorBindingKey,
  SUPPLIER_TYPES,
} from "../validate/capabilities.js";
import {
  compareSelectorBindings,
  compareSignalCapabilities,
} from "../canonical/ordering.js";
import {
  ZERO_HASH,
  opaqueContentHash,
  onchainRouteHash,
  onchainRouteId,
  onchainSelectorBindingHash,
  onchainSignalCapabilityHash,
  onchainSignalId,
  onchainSignalKey,
  onchainSourceId,
  onchainStageId,
  routeHashFromDigests,
} from "../hash/route.js";
import { assertNever, isRecord } from "../shape.js";
import type {
  HookPlanExecutorRoute,
  OnchainExecutorRoute,
  OnchainExecutorRouteRef,
  OnchainHookInstruction,
  OnchainSignalCapability,
  OnchainStageSelectorBinding,
  OrderTriggerKind,
  SelectedStageBinding,
  SignalCapability,
} from "../../types/index.js";

/**
 * hook 编译转换：条件 AST → 栈机指令，hook 周边声明（executor route /
 * selector binding / signal capability）→ 链轨形态。
 */

function compileHookInstructions(
  ast: HookExpressionAst,
  stageIdentifier: string,
  options: { readonly orderTriggerKind: OrderTriggerKind },
): readonly OnchainHookInstruction[] {
  return compileConditionInstructions(ast.condition, ast.source, stageIdentifier, options);
}

function compileConditionInstructions(
  condition: HookConditionAst,
  source: string,
  stageIdentifier: string,
  options: { readonly orderTriggerKind: OrderTriggerKind },
): readonly OnchainHookInstruction[] {
  switch (condition.kind) {
    case "signal":
      return [signalInstruction(source, condition.signalName)];
    case "subscription":
      if (options.orderTriggerKind === "none") {
        throw new HookPlanCompilationError([
          `on-chain HookPlan only supports subscription entries on order-trigger hooks `
          + `(::ANCHOR(@${condition.source}::${condition.signal}) in stage "${source}"); `
          + "non-birth subscriptions are cloud-side runtime deliveries "
          + "(see uvp-core docs/specs/subscription-mint-spec.md)"
        ]);
      }
      return [signalInstruction(condition.source, condition.signal)];
    case "not":
      return [
        ...compileConditionInstructions(condition.expr, source, stageIdentifier, options),
        { op: "NOT" },
      ];
    case "and":
      return [
        ...condition.terms.flatMap((term) =>
          compileConditionInstructions(term, source, stageIdentifier, options),
        ),
        { op: "AND", arity: condition.terms.length },
      ];
    case "or":
      return [
        ...condition.terms.flatMap((term) =>
          compileConditionInstructions(term, source, stageIdentifier, options),
        ),
        { op: "OR", arity: condition.terms.length },
      ];
    case "delay":
      if (options.orderTriggerKind !== "none") {
        throw new HookPlanCompilationError([
          `on-chain order-trigger hook (${options.orderTriggerKind}) must not contain DELAY `
          + `(@${source}::…+${condition.durationSeconds}s); birth facts settle at order creation `
          + "(contract _validateHook reverts InvalidInstruction)",
        ]);
      }
      return [
        ...compileConditionInstructions(condition.expr, source, stageIdentifier, options),
        { op: "DELAY", delaySeconds: condition.durationSeconds },
      ];
    default:
      assertNever(condition);
  }
}

function signalInstruction(
  source: string,
  signalName: string,
): OnchainHookInstruction {
  const sourceId = onchainSourceId(source);
  const signalId = onchainSignalId(signalName);
  return {
    op: "SIGNAL",
    source,
    signalName,
    sourceId,
    signalId,
    signalKey: onchainSignalKey(sourceId, signalId),
  };
}

function compileExecutorRoute(
  route: HookPlanExecutorRoute,
): OnchainExecutorRoute {
  if (
    route.executor.supplierID === undefined ||
    route.executor.supplierID.trim().length === 0
  ) {
    throw new HookPlanCompilationError([
      `executor route "${route.stageIdentifier}" (supplierType=${String(route.executor.supplierType)}) is missing a non-empty executor.supplierID`,
    ]);
  }
  const supplierType = String(route.executor.supplierType);
  if (!SUPPLIER_TYPES.includes(supplierType)) {
    throw new HookPlanCompilationError([
      `executor route "${route.stageIdentifier}" supplierType must be one of ${SUPPLIER_TYPES.join("|")} (case-sensitive), received ${JSON.stringify(supplierType)}`,
    ]);
  }
  const assertFileResources = (
    resources: unknown,
    label: string,
  ): void => {
    if (resources === undefined) {
      return;
    }
    if (!isRecord(resources)) {
      throw new HookPlanCompilationError([
        `executor route "${route.stageIdentifier}" ${label} must be a map of file resources`,
      ]);
    }
    for (const [key, resource] of Object.entries(resources)) {
      const fileType =
        typeof resource === "object" && resource !== null
          ? (resource as { readonly fileType?: unknown }).fileType
          : undefined;
      if (typeof fileType !== "string" || !FILE_TYPES.includes(fileType)) {
        throw new HookPlanCompilationError([
          `executor route "${route.stageIdentifier}" ${label}[${JSON.stringify(key)}].fileType must be one of ${FILE_TYPES.join("|")}, received ${JSON.stringify(fileType)}`,
        ]);
      }
    }
  };
  const selectable = route.executor.selectableResource;
  if (selectable !== undefined && selectable !== null) {
    assertFileResources(selectable, "executor.selectableResource");
  }
  assertFileResources(route.fileResources, "fileResources");
  const executorHash = opaqueContentHash(route.executor);
  const resourcesHash =
    route.fileResources === undefined ? ZERO_HASH : opaqueContentHash(route.fileResources);
  return {
    routeId: onchainRouteId(route.stageIdentifier),
    stageId: onchainStageId(route.stageIdentifier),
    stageIdentifier: route.stageIdentifier,
    executorType: String(route.executor.supplierType),
    executorId: route.executor.supplierID,
    executorHash,
    resourcesHash,
    routeHash: routeHashFromDigests(
      onchainStageId(route.stageIdentifier),
      route.stageIdentifier,
      executorHash,
      resourcesHash,
    ),
  };
}

function compileSelectorBindings(
  bindings: readonly SelectedStageBinding[],
): readonly OnchainStageSelectorBinding[] {
  const issues: string[] = [];
  const seen = new Set<string>();
  const compiled: OnchainStageSelectorBinding[] = [];

  for (const binding of bindings) {
    const selectorStageId = onchainStageId(binding.selectorStageIdentifier);
    const targetStageId = onchainStageId(binding.targetStageIdentifier);
    const bindingKey = selectorBindingKey(selectorStageId, targetStageId);
    if (seen.has(bindingKey)) {
      issues.push(
        `duplicate selector binding ${binding.selectorStageIdentifier}->${binding.targetStageIdentifier}`,
      );
      continue;
    }
    seen.add(bindingKey);
    compiled.push({
      selectorStageIdentifier: binding.selectorStageIdentifier,
      targetStageIdentifier: binding.targetStageIdentifier,
      selectorStageId,
      targetStageId,
      bindingHash: onchainSelectorBindingHash(selectorStageId, targetStageId),
    });
  }

  if (issues.length > 0) {
    throw new OnchainHookPlanArtifactValidationError(issues);
  }

  return compiled.sort(compareSelectorBindings);
}

function compileSignalCapabilities(
  capabilities: readonly SignalCapability[],
): readonly OnchainSignalCapability[] {
  const issues: string[] = [];
  const seen = new Set<string>();
  const compiled: OnchainSignalCapability[] = [];
  for (const capability of capabilities) {
    const stageId = onchainStageId(capability.stageIdentifier);
    const targetSourceId = onchainSourceId(capability.targetSource);
    const signalId = onchainSignalId(capability.targetSignalName);
    const key = [
      stageId,
      targetSourceId,
      signalId,
      capability.targetOrderRelation,
    ].join("\u0000");
    if (seen.has(key)) {
      issues.push(
        `duplicate signal capability ${capability.stageIdentifier}->${capability.targetSource}::${capability.targetSignalName}`,
      );
      continue;
    }
    seen.add(key);
    compiled.push({
      stageIdentifier: capability.stageIdentifier,
      stageId,
      source: capability.source,
      declaredSignal: capability.declaredSignal,
      targetSource: capability.targetSource,
      targetSourceId,
      targetSignalName: capability.targetSignalName,
      signalId,
      targetOrderRelation: capability.targetOrderRelation,
      capabilityHash: onchainSignalCapabilityHash(
        stageId,
        targetSourceId,
        signalId,
        capability.targetOrderRelation,
      ),
    });
  }
  if (issues.length > 0) {
    throw new OnchainHookPlanArtifactValidationError(issues);
  }
  return compiled.sort(compareSignalCapabilities);
}

function routeRefForRoute(
  route: HookPlanExecutorRoute,
): OnchainExecutorRouteRef {
  return {
    routeId: onchainRouteId(route.stageIdentifier),
    stageId: onchainStageId(route.stageIdentifier),
    routeHash: onchainRouteHash(route),
  };
}

export {
  compileHookInstructions,
  compileExecutorRoute,
  compileSelectorBindings,
  compileSignalCapabilities,
  routeRefForRoute,
};

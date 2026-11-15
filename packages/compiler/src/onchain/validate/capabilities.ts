import {
  EXECUTOR_BINDING_KIND_CANDIDATE,
  EXECUTOR_BINDING_KIND_DEFAULT,
  MAX_EXECUTOR_BINDINGS,
} from "../executor-bindings.js";
import {
  onchainSelectorBindingHash,
  onchainSignalCapabilityHash,
  onchainSignalId,
  onchainRouteId,
  onchainSourceId,
  onchainStageId,
  routeHashFromDigests,
} from "../hash/route.js";
import {
  expectClosedKeySet,
  expectHexHash,
  expectLiteral,
  expectNonEmptyString,
  isHexHash,
  isRecord,
} from "../shape.js";
import type { ExecutorBinding, ExecutorBindingKind, HexString } from "../../types/index.js";

/**
 * 能力声明族校验：executorRoutes / executorBindings / selectorBindings /
 * signalCapabilities 的形状与承诺重算，事实键唯一属主镜像，
 * supplierType/fileType/executor-kind 闭集词表。
 */

const EXECUTOR_ROUTE_FIELDS: readonly string[] = [
  "routeId",
  "stageId",
  "stageIdentifier",
  "executorType",
  "executorId",
  "executorHash",
  "resourcesHash",
  "routeHash",
];
const SELECTOR_BINDING_FIELDS: readonly string[] = [
  "selectorStageIdentifier",
  "targetStageIdentifier",
  "selectorStageId",
  "targetStageId",
  "bindingHash",
];
const EXECUTOR_BINDING_FIELDS: readonly string[] = [
  "stageIdentifier",
  "stageId",
  "supplierId",
  "kind",
];
const EXECUTOR_BINDING_KINDS: readonly number[] = [
  EXECUTOR_BINDING_KIND_DEFAULT,
  EXECUTOR_BINDING_KIND_CANDIDATE,
];
const SIGNAL_CAPABILITY_FIELDS: readonly string[] = [
  "stageIdentifier",
  "stageId",
  "source",
  "declaredSignal",
  "targetSource",
  "targetSourceId",
  "targetSignalName",
  "signalId",
  "targetOrderRelation",
  "capabilityHash",
];

const SUPPLIER_TYPES: readonly string[] = ["individual", "organization", "dock"];

const PLAN_EXECUTOR_TYPES: readonly string[] = ["individual", "organization"];

const FILE_TYPES: readonly string[] = ["local", "http", "txcloud", "plain_text"];

export { SUPPLIER_TYPES, PLAN_EXECUTOR_TYPES, FILE_TYPES };

function duplicateCurrentOrderFactKeyIssues(
  capabilities: readonly {
    readonly stage: string;
    readonly sourceId: string;
    readonly signalId: string;
  }[],
): readonly string[] {
  const issues: string[] = [];
  const owners = new Map<string, string>();
  for (const capability of capabilities) {
    const factKey = `${capability.sourceId}:${capability.signalId}`;
    const owner = owners.get(factKey);
    if (owner === undefined) {
      owners.set(factKey, capability.stage);
      continue;
    }
    if (owner !== capability.stage) {
      issues.push(
        `stage ${capability.stage} declares the current-order fact key `
          + `(${capability.sourceId}, ${capability.signalId}) already owned by stage ${owner}; `
          + "current-order fact keys must resolve to exactly one owner stage "
          + "for proof-carrying attribution to be unambiguous",
      );
    }
  }
  return issues;
}

export interface OnchainExecutorBindingRecord extends ExecutorBinding {}

function validateOnchainExecutorBindings(
  bindings: readonly unknown[],
): {
  readonly records: readonly OnchainExecutorBindingRecord[];
  readonly issues: readonly string[];
} {
  const issues: string[] = [];
  const records: OnchainExecutorBindingRecord[] = [];
  if (bindings.length > MAX_EXECUTOR_BINDINGS) {
    issues.push(
      `executorBindings must not exceed ${MAX_EXECUTOR_BINDINGS} entries; UVPStateMachine.commitPlan reverts TooManyExecutorBindings`,
    );
  }
  const seen = new Set<string>();
  for (const [index, binding] of bindings.entries()) {
    const prefix = `executorBindings[${index}]`;
    if (!isRecord(binding)) {
      issues.push(`${prefix} must be an object`);
      continue;
    }
    expectClosedKeySet(binding, EXECUTOR_BINDING_FIELDS, prefix, issues);
    expectNonEmptyString(
      binding.stageIdentifier,
      `${prefix}.stageIdentifier`,
      issues,
    );
    expectHexHash(binding.stageId, `${prefix}.stageId`, issues);
    expectHexHash(binding.supplierId, `${prefix}.supplierId`, issues);
    if (
      typeof binding.stageIdentifier === "string" &&
      typeof binding.stageId === "string" &&
      binding.stageId !== onchainStageId(binding.stageIdentifier)
    ) {
      issues.push(`${prefix}.stageId must be keccak256(stageIdentifier)`);
    }
    if (
      typeof binding.kind !== "number" ||
      !EXECUTOR_BINDING_KINDS.includes(binding.kind)
    ) {
      issues.push(
        `${prefix}.kind must be ${EXECUTOR_BINDING_KIND_DEFAULT} (default) or ${EXECUTOR_BINDING_KIND_CANDIDATE} (candidate), received ${JSON.stringify(binding.kind)}`,
      );
      continue;
    }
    const kind = binding.kind as ExecutorBindingKind;
    if (
      typeof binding.stageIdentifier === "string" &&
      isHexHash(binding.stageId) &&
      isHexHash(binding.supplierId)
    ) {
      const key = `${binding.stageId}:${binding.supplierId}:${kind}`;
      if (seen.has(key)) {
        issues.push(
          `duplicate executor binding for stage ${binding.stageIdentifier} (supplierId ${binding.supplierId}, kind ${kind}); `
            + "UVPStateMachine.commitPlan reverts DuplicateExecutorBinding and the Merkle tree must not absorb the duplicate",
        );
      }
      seen.add(key);
      records.push({
        stageIdentifier: binding.stageIdentifier,
        stageId: binding.stageId,
        supplierId: binding.supplierId,
        kind,
      });
    }
  }
  return { records, issues };
}

function validateOnchainExecutorRoutes(
  routes: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  const routeIds = new Set<string>();
  for (const [index, route] of routes.entries()) {
    if (!isRecord(route)) {
      issues.push(`executorRoutes[${index}] must be an object`);
      continue;
    }

    const prefix = `executorRoutes[${index}]`;
    expectClosedKeySet(route, EXECUTOR_ROUTE_FIELDS, prefix, issues);
    expectHexHash(route.routeId, `${prefix}.routeId`, issues);
    expectHexHash(route.stageId, `${prefix}.stageId`, issues);
    expectNonEmptyString(
      route.stageIdentifier,
      `${prefix}.stageIdentifier`,
      issues,
    );
    expectNonEmptyString(route.executorType, `${prefix}.executorType`, issues);
    if (
      typeof route.executorType === "string" &&
      !PLAN_EXECUTOR_TYPES.includes(route.executorType)
    ) {
      issues.push(
        `${prefix}.executorType must be one of ${PLAN_EXECUTOR_TYPES.join("|")} (case-sensitive), received ${JSON.stringify(route.executorType)}; `
          + "a dock stage's executor is selected once through the stage executor patch (dkid) and never becomes a plan route",
      );
    }
    if (typeof route.executorId === "string" && route.executorId.trim().length === 0) {
      issues.push(
        `${prefix}.executorId must be a non-empty executor id (whitespace-only ids are rejected at the compile entry already)`,
      );
    }
    expectHexHash(route.executorHash, `${prefix}.executorHash`, issues);
    expectHexHash(route.resourcesHash, `${prefix}.resourcesHash`, issues);
    expectHexHash(route.routeHash, `${prefix}.routeHash`, issues);
    if (
      typeof route.routeHash === "string" &&
      typeof route.stageId === "string" &&
      typeof route.stageIdentifier === "string" &&
      typeof route.executorHash === "string" &&
      typeof route.resourcesHash === "string"
    ) {
      const recomputedRouteHash = routeHashFromDigests(
        route.stageId as HexString,
        route.stageIdentifier,
        route.executorHash as HexString,
        route.resourcesHash as HexString,
      );
      if (route.routeHash !== recomputedRouteHash) {
        issues.push(`${prefix}.routeHash must match the committed content digests`);
      }
    }
    if (
      typeof route.stageIdentifier === "string" &&
      typeof route.stageId === "string" &&
      route.stageId !== onchainStageId(route.stageIdentifier)
    ) {
      issues.push(`${prefix}.stageId must be keccak256(stageIdentifier)`);
    }
    if (
      typeof route.stageIdentifier === "string" &&
      typeof route.routeId === "string" &&
      route.routeId !== onchainRouteId(route.stageIdentifier)
    ) {
      issues.push(
        `${prefix}.routeId must be keccak256(stageIdentifier#executorRoute)`,
      );
    }
    if (typeof route.routeId === "string") {
      if (routeIds.has(route.routeId)) {
        issues.push(`duplicate routeId ${route.routeId}`);
      }
      routeIds.add(route.routeId);
    }
  }
  return issues;
}

function validateOnchainSelectorBindings(
  bindings: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  const seen = new Set<string>();
  for (const [index, binding] of bindings.entries()) {
    if (!isRecord(binding)) {
      issues.push(`selectorBindings[${index}] must be an object`);
      continue;
    }

    const prefix = `selectorBindings[${index}]`;
    expectClosedKeySet(binding, SELECTOR_BINDING_FIELDS, prefix, issues);
    expectNonEmptyString(
      binding.selectorStageIdentifier,
      `${prefix}.selectorStageIdentifier`,
      issues,
    );
    expectNonEmptyString(
      binding.targetStageIdentifier,
      `${prefix}.targetStageIdentifier`,
      issues,
    );
    expectHexHash(binding.selectorStageId, `${prefix}.selectorStageId`, issues);
    expectHexHash(binding.targetStageId, `${prefix}.targetStageId`, issues);
    expectHexHash(binding.bindingHash, `${prefix}.bindingHash`, issues);

    if (
      typeof binding.selectorStageIdentifier === "string" &&
      typeof binding.selectorStageId === "string" &&
      binding.selectorStageId !==
        onchainStageId(binding.selectorStageIdentifier)
    ) {
      issues.push(
        `${prefix}.selectorStageId must be keccak256(selectorStageIdentifier)`,
      );
    }
    if (
      typeof binding.targetStageIdentifier === "string" &&
      typeof binding.targetStageId === "string" &&
      binding.targetStageId !== onchainStageId(binding.targetStageIdentifier)
    ) {
      issues.push(
        `${prefix}.targetStageId must be keccak256(targetStageIdentifier)`,
      );
    }
    if (
      isHexHash(binding.selectorStageId) &&
      isHexHash(binding.targetStageId) &&
      binding.bindingHash !==
        onchainSelectorBindingHash(
          binding.selectorStageId,
          binding.targetStageId,
        )
    ) {
      issues.push(
        `${prefix}.bindingHash must match selectorStageId and targetStageId`,
      );
    }

    if (
      isHexHash(binding.selectorStageId) &&
      isHexHash(binding.targetStageId)
    ) {
      const key = selectorBindingKey(
        binding.selectorStageId,
        binding.targetStageId,
      );
      if (seen.has(key)) {
        issues.push(`duplicate selector binding ${key}`);
      }
      seen.add(key);
    }
  }
  return issues;
}

function validateOnchainSignalCapabilities(
  capabilities: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  const seen = new Set<string>();
  for (const [index, capability] of capabilities.entries()) {
    if (!isRecord(capability)) {
      issues.push(`signalCapabilities[${index}] must be an object`);
      continue;
    }
    const prefix = `signalCapabilities[${index}]`;
    expectClosedKeySet(capability, SIGNAL_CAPABILITY_FIELDS, prefix, issues);
    expectNonEmptyString(
      capability.stageIdentifier,
      `${prefix}.stageIdentifier`,
      issues,
    );
    expectHexHash(capability.stageId, `${prefix}.stageId`, issues);
    expectNonEmptyString(capability.source, `${prefix}.source`, issues);
    expectNonEmptyString(
      capability.declaredSignal,
      `${prefix}.declaredSignal`,
      issues,
    );
    expectNonEmptyString(
      capability.targetSource,
      `${prefix}.targetSource`,
      issues,
    );
    expectHexHash(
      capability.targetSourceId,
      `${prefix}.targetSourceId`,
      issues,
    );
    expectNonEmptyString(
      capability.targetSignalName,
      `${prefix}.targetSignalName`,
      issues,
    );
    expectHexHash(capability.signalId, `${prefix}.signalId`, issues);
    expectLiteral(
      capability.targetOrderRelation,
      "current",
      `${prefix}.targetOrderRelation`,
      issues,
    );
    expectHexHash(
      capability.capabilityHash,
      `${prefix}.capabilityHash`,
      issues,
    );

    if (
      typeof capability.stageIdentifier === "string" &&
      typeof capability.stageId === "string" &&
      capability.stageId !== onchainStageId(capability.stageIdentifier)
    ) {
      issues.push(`${prefix}.stageId must be keccak256(stageIdentifier)`);
    }
    if (
      typeof capability.targetSource === "string" &&
      typeof capability.targetSourceId === "string" &&
      capability.targetSourceId !== onchainSourceId(capability.targetSource)
    ) {
      issues.push(`${prefix}.targetSourceId must be keccak256(targetSource)`);
    }
    if (
      typeof capability.targetSignalName === "string" &&
      typeof capability.signalId === "string" &&
      capability.signalId !== onchainSignalId(capability.targetSignalName)
    ) {
      issues.push(`${prefix}.signalId must be keccak256(targetSignalName)`);
    }
    if (
      isHexHash(capability.stageId) &&
      isHexHash(capability.targetSourceId) &&
      isHexHash(capability.signalId) &&
      capability.targetOrderRelation === "current"
    ) {
      const expectedHash = onchainSignalCapabilityHash(
        capability.stageId,
        capability.targetSourceId,
        capability.signalId,
        capability.targetOrderRelation,
      );
      if (capability.capabilityHash !== expectedHash) {
        issues.push(`${prefix}.capabilityHash must match capability fields`);
      }
      const key = [
        capability.stageId,
        capability.targetSourceId,
        capability.signalId,
        capability.targetOrderRelation,
      ].join("\u0000");
      if (seen.has(key)) {
        issues.push(`duplicate signal capability ${key}`);
      }
      seen.add(key);
    }
  }
  return issues;
}

function selectorBindingKey(
  selectorStageId: HexString,
  targetStageId: HexString,
): string {
  return `${selectorStageId}->${targetStageId}`;
}

export {
  duplicateCurrentOrderFactKeyIssues,
  validateOnchainExecutorBindings,
  validateOnchainExecutorRoutes,
  validateOnchainSelectorBindings,
  validateOnchainSignalCapabilities,
  selectorBindingKey,
};

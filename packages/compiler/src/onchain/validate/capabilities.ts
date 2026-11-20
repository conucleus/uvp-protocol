import {
  MAX_SUPPLIER_BINDINGS,
  SUPPLIER_BINDING_KIND_CANDIDATE,
  SUPPLIER_BINDING_KIND_DEFAULT,
  supplierIdFromUuid,
} from "../supplier-bindings.js";
import {
  onchainRouteId,
  onchainSelectorBindingHash,
  onchainSignalCapabilityHash,
  onchainSignalId,
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
import type {
  HexString,
  StageSupplierBinding,
  SupplierBindingKind,
} from "../../types/index.js";

/**
 * 能力声明族校验：supplierRoutes / supplierBindings / selectorBindings /
 * signalCapabilities 的形状与承诺重算，事实键唯一属主镜像，
 * supplierType / supplier-binding-kind 闭集词表（fileType 值域开放，不在编译期收窄）。
 */

const SUPPLIER_ROUTE_FIELDS: readonly string[] = [
  "routeId",
  "stageId",
  "stageIdentifier",
  "supplierType",
  "supplierID",
  "supplierHash",
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
const SUPPLIER_BINDING_FIELDS: readonly string[] = [
  "stageIdentifier",
  "stageId",
  "supplierID",
  "supplierId",
  "kind",
];
const SUPPLIER_BINDING_KINDS: readonly number[] = [
  SUPPLIER_BINDING_KIND_DEFAULT,
  SUPPLIER_BINDING_KIND_CANDIDATE,
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

const PLAN_SUPPLIER_TYPES: readonly string[] = ["individual", "organization"];

export { SUPPLIER_TYPES, PLAN_SUPPLIER_TYPES };

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

export interface OnchainSupplierBindingRecord extends StageSupplierBinding {}

function validateOnchainSupplierBindings(
  bindings: readonly unknown[],
): {
  readonly records: readonly OnchainSupplierBindingRecord[];
  readonly issues: readonly string[];
} {
  const issues: string[] = [];
  const records: OnchainSupplierBindingRecord[] = [];
  if (bindings.length > MAX_SUPPLIER_BINDINGS) {
    issues.push(
      `supplierBindings must not exceed ${MAX_SUPPLIER_BINDINGS} entries; UVPStateMachine.commitPlan reverts TooManySupplierBindings`,
    );
  }
  const seen = new Set<string>();
  for (const [index, binding] of bindings.entries()) {
    const prefix = `supplierBindings[${index}]`;
    if (!isRecord(binding)) {
      issues.push(`${prefix} must be an object`);
      continue;
    }
    expectClosedKeySet(binding, SUPPLIER_BINDING_FIELDS, prefix, issues);
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
    let decodedSupplierId: HexString | undefined;
    if (typeof binding.supplierID !== "string") {
      issues.push(
        `${prefix}.supplierID must be a canonical 8-4-4-4-12 UUID string`,
      );
    } else {
      try {
        decodedSupplierId = supplierIdFromUuid(binding.supplierID);
      } catch (error) {
        issues.push(
          `${prefix}.supplierID: `
            + (error instanceof Error ? error.message : String(error)),
        );
      }
      if (binding.supplierID !== binding.supplierID.toLowerCase()) {
        issues.push(
          `${prefix}.supplierID must be normalized to lowercase`,
        );
      }
    }
    if (
      decodedSupplierId !== undefined &&
      isHexHash(binding.supplierId) &&
      binding.supplierId !== decodedSupplierId
    ) {
      issues.push(
        `${prefix}.supplierId must decode ${JSON.stringify(binding.supplierID)} to raw UUID bytes in the low 16 bytes of a zero-padded bytes32 (the chain never hashes the identity)`,
      );
    }
    if (
      typeof binding.kind !== "number" ||
      !SUPPLIER_BINDING_KINDS.includes(binding.kind)
    ) {
      issues.push(
        `${prefix}.kind must be ${SUPPLIER_BINDING_KIND_DEFAULT} (default) or ${SUPPLIER_BINDING_KIND_CANDIDATE} (candidate), received ${JSON.stringify(binding.kind)}`,
      );
      continue;
    }
    const kind = binding.kind as SupplierBindingKind;
    if (
      typeof binding.stageIdentifier === "string" &&
      typeof binding.supplierID === "string" &&
      isHexHash(binding.stageId) &&
      isHexHash(binding.supplierId) &&
      decodedSupplierId !== undefined
    ) {
      const key = `${binding.stageId}:${binding.supplierId}:${kind}`;
      if (seen.has(key)) {
        issues.push(
          `duplicate supplier binding for stage ${binding.stageIdentifier} (supplierId ${binding.supplierId}, kind ${kind}); `
            + "UVPStateMachine.commitPlan reverts DuplicateSupplierBinding and the Merkle tree must not absorb the duplicate",
        );
      }
      seen.add(key);
      records.push({
        stageIdentifier: binding.stageIdentifier,
        stageId: binding.stageId,
        supplierID: binding.supplierID,
        supplierId: binding.supplierId,
        kind,
      });
    }
  }
  return { records, issues };
}

function validateOnchainSupplierRoutes(
  routes: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  const routeIds = new Set<string>();
  for (const [index, route] of routes.entries()) {
    if (!isRecord(route)) {
      issues.push(`supplierRoutes[${index}] must be an object`);
      continue;
    }

    const prefix = `supplierRoutes[${index}]`;
    expectClosedKeySet(route, SUPPLIER_ROUTE_FIELDS, prefix, issues);
    expectHexHash(route.routeId, `${prefix}.routeId`, issues);
    expectHexHash(route.stageId, `${prefix}.stageId`, issues);
    expectNonEmptyString(
      route.stageIdentifier,
      `${prefix}.stageIdentifier`,
      issues,
    );
    expectNonEmptyString(route.supplierType, `${prefix}.supplierType`, issues);
    if (
      typeof route.supplierType === "string" &&
      !PLAN_SUPPLIER_TYPES.includes(route.supplierType)
    ) {
      issues.push(
        `${prefix}.supplierType must be one of ${PLAN_SUPPLIER_TYPES.join("|")} (case-sensitive), received ${JSON.stringify(route.supplierType)}; `
          + "a dock stage's supplier is selected once through the stage supplier patch (dkid) and never becomes a plan route",
      );
    }
    if (typeof route.supplierID === "string" && route.supplierID.trim().length === 0) {
      issues.push(
        `${prefix}.supplierID must be a non-empty supplier UUID (whitespace-only ids are rejected at the compile entry already)`,
      );
    }
    if (typeof route.supplierID === "string" && route.supplierID.trim().length > 0) {
      try {
        supplierIdFromUuid(route.supplierID);
      } catch (error) {
        issues.push(
          `${prefix}.supplierID: `
            + (error instanceof Error ? error.message : String(error)),
        );
      }
      if (route.supplierID !== route.supplierID.toLowerCase()) {
        issues.push(`${prefix}.supplierID must be normalized to lowercase`);
      }
    }
    expectHexHash(route.supplierHash, `${prefix}.supplierHash`, issues);
    expectHexHash(route.resourcesHash, `${prefix}.resourcesHash`, issues);
    expectHexHash(route.routeHash, `${prefix}.routeHash`, issues);
    if (
      typeof route.routeHash === "string" &&
      typeof route.stageId === "string" &&
      typeof route.stageIdentifier === "string" &&
      typeof route.supplierHash === "string" &&
      typeof route.resourcesHash === "string"
    ) {
      const recomputedRouteHash = routeHashFromDigests(
        route.stageId as HexString,
        route.stageIdentifier,
        route.supplierHash as HexString,
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
        `${prefix}.routeId must be keccak256(stageIdentifier#supplierRoute)`,
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
  validateOnchainSupplierBindings,
  validateOnchainSupplierRoutes,
  validateOnchainSelectorBindings,
  validateOnchainSignalCapabilities,
  selectorBindingKey,
};

// Runtime validation for the chain read wire contract: guards, field decoders,
// and response-envelope parsers. Structural mismatch throws
// ChainReadContractError with the JSON path of the first invalid field.
import { ChainReadContractError } from "./errors.js";
import type {
  ChainContractGovernanceProjection,
  ChainDeploymentProjection,
  ChainDockInputDelivery,
  ChainDockOutputDelivery,
  ChainDockProjection,
  ChainDerivedSignal,
  ChainExecutorCandidate,
  ChainHook,
  ChainHookStatus,
  ChainModuleProjection,
  ChainOrderFork,
  ChainOrderProjection,
  ChainOrderStatus,
  ChainOrderTriggerLink,
  ChainPlanProjection,
  ChainProjectionSnapshot,
  ChainProof,
  ChainProvenance,
  ChainRebuildMetadata,
  ChainRebuildStatus,
  ChainSignal,
  ChainSignalAuthorization,
  ChainSignalCapability,
  ChainSignalTargetRelation,
  ChainStageExecutorOverlay,
  ChainStageExecutorPatchMode,
  ChainStageMaterialization,
  ChainStageResourceOverlay,
  ChainStageSelectorBinding,
  ChainSubmitSignal,
  ChainSyncDiagnosticsCounts,
  ChainSyncState,
  ChainSyncStatus,
  ChainTaskProjection,
  ChainTaskStatus,
  ChainTimelineEvent,
  ChainDeploymentStatus,
  ChainDockMode,
} from "./projections.js";

type WireRecord = Record<string, unknown>;

const ORDER_STATUSES: readonly ChainOrderStatus[] = ["registered", "unknown"];
const TASK_STATUSES: readonly ChainTaskStatus[] = ["ready", "submitted", "cancelled", "unknown"];
const HOOK_STATUSES: readonly ChainHookStatus[] = ["init", "waiting", "ready", "cancelled", "unknown"];
const EXECUTOR_PATCH_MODES: readonly ChainStageExecutorPatchMode[] = ["assign", "handoff"];
const SIGNAL_TARGET_RELATIONS: readonly ChainSignalTargetRelation[] = ["current", "triggerOrigin", "unknown"];
const DEPLOYMENT_STATUSES: readonly ChainDeploymentStatus[] = [
  "candidate",
  "canary",
  "active",
  "deprecated",
  "retired",
  "unknown"
];
const DOCK_MODES: readonly ChainDockMode[] = ["new", "existing"];
const SYNC_STATUSES: readonly ChainSyncStatus[] = ["indexed", "syncing", "stale", "rebuilding", "degraded"];
const REBUILD_STATUSES: readonly ChainRebuildStatus[] = ["idle", "running", "completed", "failed"];
const SUBMIT_SIGNAL_SOURCES: readonly ChainSubmitSignal["source"][] = ["plan_capability", "authorization"];

export function decodeProvenanceWire(value: unknown, path = "provenance"): ChainProvenance {
  const record = wireRecord(value, path);
  requireNumber(record, "chainId", path);
  requireString(record, "contractAddress", path);
  requireDecimalString(record, "blockNumber", path);
  optionalNumber(record, "transactionIndex", path);
  requireString(record, "transactionHash", path);
  requireNumber(record, "logIndex", path);
  return value as ChainProvenance;
}

export function decodeProofWire(value: unknown, path = "proof"): ChainProof {
  decodeProvenanceWire(value, path);
  const record = wireRecord(value, path);
  requireString(record, "eventId", path);
  requireString(record, "eventName", path);
  decodeProofArgs(record["args"], `${path}.args`);
  optionalString(record, "blockHash", path);
  optionalString(record, "orderId", path);
  optionalString(record, "planId", path);
  optionalString(record, "planHash", path);
  optionalString(record, "submitter", path);
  return value as ChainProof;
}

export function decodeTimelineEventWire(value: unknown, path = "timelineEvent"): ChainTimelineEvent {
  const record = wireRecord(value, path);
  requireString(record, "timelineId", path);
  optionalString(record, "orderId", path);
  optionalString(record, "planId", path);
  requireString(record, "eventName", path);
  requireString(record, "text", path);
  requireString(record, "time", path);
  decodeProofWire(record["proof"], `${path}.proof`);
  return value as ChainTimelineEvent;
}

export function decodeSignalAuthorizationWire(
  value: unknown,
  path = "signalAuthorization"
): ChainSignalAuthorization {
  const record = wireRecord(value, path);
  for (const field of ["orderId", "sourceId", "signalId", "submitter", "role", "metadataHash"] as const) {
    requireString(record, field, path);
  }
  decodeProvenanceWire(record["authorizedAt"], `${path}.authorizedAt`);
  decodeProofWire(record["proof"], `${path}.proof`);
  return value as ChainSignalAuthorization;
}

export function decodeSignalWire(value: unknown, path = "signal"): ChainSignal {
  const record = wireRecord(value, path);
  for (const field of [
    "orderId",
    "sourceId",
    "signalId",
    "payloadHash",
    "idempotencyKey",
    "submitter"
  ] as const) {
    requireString(record, field, path);
  }
  optionalString(record, "factStageId", path);
  optionalBoolean(record, "replayedFromFork", path);
  decodeProvenanceWire(record["submittedAt"], `${path}.submittedAt`);
  decodeProofWire(record["proof"], `${path}.proof`);
  return value as ChainSignal;
}

export function decodeDerivedSignalWire(value: unknown, path = "derivedSignal"): ChainDerivedSignal {
  const record = wireRecord(value, path);
  for (const field of [
    "targetOrderId",
    "fromPlanId",
    "fromOrderId",
    "fromStageId",
    "targetSourceId",
    "signalId",
    "payloadHash",
    "idempotencyKey"
  ] as const) {
    requireString(record, field, path);
  }
  optionalString(record, "submitter", path);
  optionalString(record, "relation", path);
  decodeProvenanceWire(record["submittedAt"], `${path}.submittedAt`);
  decodeProofWire(record["proof"], `${path}.proof`);
  return value as ChainDerivedSignal;
}

export function decodeStageMaterializationWire(
  value: unknown,
  path = "stageMaterialization"
): ChainStageMaterialization {
  const record = wireRecord(value, path);
  requireString(record, "orderId", path);
  requireString(record, "stageId", path);
  optionalString(record, "triggerHookId", path);
  optionalString(record, "sourceId", path);
  optionalString(record, "signalId", path);
  decodeProvenanceWire(record["materializedAt"], `${path}.materializedAt`);
  decodeProofWire(record["proof"], `${path}.proof`);
  return value as ChainStageMaterialization;
}

export function decodeStageExecutorOverlayWire(
  value: unknown,
  path = "stageExecutorOverlay"
): ChainStageExecutorOverlay {
  const record = wireRecord(value, path);
  for (const field of [
    "orderId",
    "selectorStageId",
    "targetStageId",
    "selectorWallet",
    "activeExecutorWallet",
    "roleHash",
    "executorMetadataHash",
    "patchHash",
    "patchNonce",
    "metadataURI"
  ] as const) {
    requireString(record, field, path);
  }
  requireEnum(record, "mode", path, EXECUTOR_PATCH_MODES);
  optionalString(record, "modeHash", path);
  optionalString(record, "previousExecutor", path);
  optionalString(record, "authorizationsHash", path);
  decodeProvenanceWire(record["updatedAt"], `${path}.updatedAt`);
  optionalProvenance(record, "activatedAt", path);
  decodeProofWire(record["proof"], `${path}.proof`);
  if (record["activationProof"] !== undefined) {
    decodeProofWire(record["activationProof"], `${path}.activationProof`);
  }
  return value as ChainStageExecutorOverlay;
}

export function decodeStageResourceOverlayWire(
  value: unknown,
  path = "stageResourceOverlay"
): ChainStageResourceOverlay {
  const record = wireRecord(value, path);
  for (const field of [
    "orderId",
    "selectorStageId",
    "targetStageId",
    "resourceKey",
    "selectorWallet",
    "manifestHash",
    "policyHash",
    "patchHash",
    "patchNonce",
    "manifestURI"
  ] as const) {
    requireString(record, field, path);
  }
  decodeProvenanceWire(record["updatedAt"], `${path}.updatedAt`);
  decodeProofWire(record["proof"], `${path}.proof`);
  return value as ChainStageResourceOverlay;
}

export function decodeHookWire(value: unknown, path = "hook"): ChainHook {
  const record = wireRecord(value, path);
  requireString(record, "orderId", path);
  requireString(record, "hookId", path);
  optionalString(record, "stageIdentifier", path);
  optionalString(record, "hookName", path);
  requireEnum(record, "status", path, HOOK_STATUSES);
  optionalEnum(record, "previousStatus", path, HOOK_STATUSES);
  optionalString(record, "dueAt", path);
  decodeProvenanceWire(record["updatedAt"], `${path}.updatedAt`);
  optionalProvenance(record, "readyAt", path);
  decodeProofWire(record["proof"], `${path}.proof`);
  return value as ChainHook;
}

export function decodeTaskSubmitSignalWire(
  value: unknown,
  path = "submitSignal"
): ChainSubmitSignal {
  const record = wireRecord(value, path);
  requireString(record, "sourceId", path);
  requireString(record, "signalId", path);
  requireEnum(record, "source", path, SUBMIT_SIGNAL_SOURCES);
  return value as ChainSubmitSignal;
}

export function decodeTaskWire(value: unknown, path = "task"): ChainTaskProjection {
  const record = wireRecord(value, path);
  for (const field of [
    "taskId",
    "orderId",
    "stateMachineAddress",
    "hookId",
    "stageIdentifier",
    "hookName",
    "assigneeRole"
  ] as const) {
    requireString(record, field, path);
  }
  optionalString(record, "planId", path);
  optionalString(record, "deploymentId", path);
  optionalString(record, "assigneeWallet", path);
  optionalString(record, "assigneeRoleHash", path);
  optionalString(record, "authorizationMetadataHash", path);
  requireEnum(record, "status", path, TASK_STATUSES);
  if (record["submitSignals"] !== undefined) {
    decodeArray(record["submitSignals"], `${path}.submitSignals`).forEach((signal, index) => {
      decodeTaskSubmitSignalWire(signal, `${path}.submitSignals[${index}]`);
    });
  }
  decodeProvenanceWire(record["createdAt"], `${path}.createdAt`);
  decodeProvenanceWire(record["updatedAt"], `${path}.updatedAt`);
  decodeProofWire(record["proof"], `${path}.proof`);
  return value as ChainTaskProjection;
}

export function decodeOrderTriggerLinkWire(
  value: unknown,
  path = "triggerLink"
): ChainOrderTriggerLink {
  const record = wireRecord(value, path);
  for (const field of [
    "triggeredOrderId",
    "triggerOriginOrderId",
    "triggerStageId",
    "originSourceId",
    "originSignalId"
  ] as const) {
    requireString(record, field, path);
  }
  optionalString(record, "originPlanId", path);
  decodeProvenanceWire(record["linkedAt"], `${path}.linkedAt`);
  decodeProofWire(record["proof"], `${path}.proof`);
  return value as ChainOrderTriggerLink;
}

export function decodeOrderForkWire(value: unknown, path = "forkLineage"): ChainOrderFork {
  const record = wireRecord(value, path);
  for (const field of [
    "orderId",
    "parentOrderId",
    "approvalSourceId",
    "approvalSignalId",
    "initiator"
  ] as const) {
    requireString(record, field, path);
  }
  optionalString(record, "forkPayloadHash", path);
  if (record["replayedFactKeys"] !== undefined) {
    decodeArray(record["replayedFactKeys"], `${path}.replayedFactKeys`).forEach((key, index) => {
      if (typeof key !== "string") {
        throw new ChainReadContractError(`${path}.replayedFactKeys[${index}]`, "must be a string");
      }
    });
  }
  decodeProvenanceWire(record["forkedAt"], `${path}.forkedAt`);
  decodeProofWire(record["proof"], `${path}.proof`);
  return value as ChainOrderFork;
}

export function decodeOrderWire(value: unknown, path = "order"): ChainOrderProjection {
  const record = wireRecord(value, path);
  requireString(record, "orderId", path);
  requireNumber(record, "chainId", path);
  requireString(record, "contractAddress", path);
  optionalString(record, "deploymentId", path);
  requireString(record, "planId", path);
  optionalString(record, "planHash", path);
  requireEnum(record, "status", path, ORDER_STATUSES);
  optionalString(record, "currentStage", path);
  optionalString(record, "relayer", path);
  optionalString(record, "creator", path);
  decodeRecordMap(record["authorizations"], `${path}.authorizations`, decodeSignalAuthorizationWire);
  decodeRecordMap(record["signals"], `${path}.signals`, decodeSignalWire);
  decodeRecordMap(record["derivedSignals"], `${path}.derivedSignals`, decodeDerivedSignalWire);
  decodeRecordMap(record["stageMaterializations"], `${path}.stageMaterializations`, decodeStageMaterializationWire);
  decodeRecordMap(record["stageExecutorOverlays"], `${path}.stageExecutorOverlays`, decodeStageExecutorOverlayWire);
  decodeRecordMap(record["stageResourceOverlays"], `${path}.stageResourceOverlays`, decodeStageResourceOverlayWire);
  decodeRecordMap(record["hooks"], `${path}.hooks`, decodeHookWire);
  decodeRecordMap(record["tasks"], `${path}.tasks`, decodeTaskWire);
  decodeArray(record["timeline"], `${path}.timeline`).forEach((event, index) => {
    decodeTimelineEventWire(event, `${path}.timeline[${index}]`);
  });
  decodeArray(record["proof"], `${path}.proof`).forEach((proof, index) => {
    decodeProofWire(proof, `${path}.proof[${index}]`);
  });
  optionalProvenance(record, "registeredAt", path);
  decodeProvenanceWire(record["updatedAt"], `${path}.updatedAt`);
  if (record["triggerLink"] !== undefined) {
    decodeOrderTriggerLinkWire(record["triggerLink"], `${path}.triggerLink`);
  }
  if (record["forkLineage"] !== undefined) {
    decodeOrderForkWire(record["forkLineage"], `${path}.forkLineage`);
  }
  return value as ChainOrderProjection;
}

export function decodeModuleWire(value: unknown, path = "module"): ChainModuleProjection {
  const record = wireRecord(value, path);
  requireNumber(record, "chainId", path);
  for (const field of [
    "stateMachineAddress",
    "moduleId",
    "previousModule",
    "moduleAddress"
  ] as const) {
    requireString(record, field, path);
  }
  decodeProvenanceWire(record["updatedAt"], `${path}.updatedAt`);
  decodeProofWire(record["proof"], `${path}.proof`);
  return value as ChainModuleProjection;
}

export function decodeStageSelectorBindingWire(
  value: unknown,
  path = "selectorBinding"
): ChainStageSelectorBinding {
  const record = wireRecord(value, path);
  optionalString(record, "selectorStageIdentifier", path);
  optionalString(record, "targetStageIdentifier", path);
  requireString(record, "selectorStageId", path);
  requireString(record, "targetStageId", path);
  optionalString(record, "bindingHash", path);
  return value as ChainStageSelectorBinding;
}

export function decodeExecutorCandidateWire(
  value: unknown,
  path = "executorCandidate"
): ChainExecutorCandidate {
  const record = wireRecord(value, path);
  requireString(record, "stageId", path);
  requireString(record, "executor", path);
  return value as ChainExecutorCandidate;
}

export function decodeSignalCapabilityWire(
  value: unknown,
  path = "signalCapability"
): ChainSignalCapability {
  const record = wireRecord(value, path);
  requireString(record, "stageId", path);
  requireString(record, "targetSourceId", path);
  requireString(record, "signalId", path);
  requireEnum(record, "targetOrderRelation", path, SIGNAL_TARGET_RELATIONS);
  decodeProvenanceWire(record["registeredAt"], `${path}.registeredAt`);
  decodeProofWire(record["proof"], `${path}.proof`);
  return value as ChainSignalCapability;
}

export const PLAN_ENRICHMENT_STATUSES = ["enriched", "failed"] as const;

export function decodePlanWire(value: unknown, path = "plan"): ChainPlanProjection {
  const record = wireRecord(value, path);
  requireString(record, "planId", path);
  optionalString(record, "deploymentId", path);
  requireString(record, "stateMachineAddress", path);
  requireString(record, "planHash", path);
  requireString(record, "hookCount", path);
  optionalString(record, "publisher", path);
  optionalString(record, "hooksHash", path);
  optionalString(record, "capabilitiesRoot", path);
  optionalString(record, "dockRoutesRoot", path);
  optionalString(record, "dockInterfaceRoot", path);
  optionalString(record, "executorCandidatesRoot", path);
  optionalString(record, "birthAuthorizer", path);
  optionalProvenance(record, "committedAt", path);
  optionalProvenance(record, "finalizedAt", path);
  decodeArray(record["selectorBindings"], `${path}.selectorBindings`).forEach((binding, index) => {
    decodeStageSelectorBindingWire(binding, `${path}.selectorBindings[${index}]`);
  });
  decodeArray(record["signalCapabilities"], `${path}.signalCapabilities`).forEach((capability, index) => {
    decodeSignalCapabilityWire(capability, `${path}.signalCapabilities[${index}]`);
  });
  decodeArray(record["executorCandidates"], `${path}.executorCandidates`).forEach((candidate, index) => {
    decodeExecutorCandidateWire(candidate, `${path}.executorCandidates[${index}]`);
  });
  if (record["capabilityEnrichment"] !== undefined) {
    requireEnum(record, "capabilityEnrichment", path, PLAN_ENRICHMENT_STATUSES);
  }
  decodeProvenanceWire(record["registeredAt"], `${path}.registeredAt`);
  optionalProvenance(record, "publisherRecordedAt", path);
  decodeProvenanceWire(record["updatedAt"], `${path}.updatedAt`);
  decodeProofWire(record["proof"], `${path}.proof`);
  if (record["publisherProof"] !== undefined) {
    decodeProofWire(record["publisherProof"], `${path}.publisherProof`);
  }
  if (record["commitProof"] !== undefined) {
    decodeProofWire(record["commitProof"], `${path}.commitProof`);
  }
  if (record["finalizationProof"] !== undefined) {
    decodeProofWire(record["finalizationProof"], `${path}.finalizationProof`);
  }
  return value as ChainPlanProjection;
}


export function decodeDeploymentWire(
  value: unknown,
  path = "deployment"
): ChainDeploymentProjection {
  const record = wireRecord(value, path);
  requireString(record, "deploymentId", path);
  requireString(record, "stateMachineAddress", path);
  requireString(record, "artifactHash", path);
  requireString(record, "abiHash", path);
  requireDecimalString(record, "deploymentBlock", path);
  if (record["activatedAtBlock"] !== undefined) {
    requireDecimalString(record, "activatedAtBlock", path);
  }
  optionalString(record, "evidenceHash", path);
  requireString(record, "metadataURI", path);
  requireEnum(record, "status", path, DEPLOYMENT_STATUSES);
  decodeProvenanceWire(record["registeredAt"], `${path}.registeredAt`);
  decodeProvenanceWire(record["updatedAt"], `${path}.updatedAt`);
  decodeProofWire(record["proof"], `${path}.proof`);
  return value as ChainDeploymentProjection;
}

export function decodeContractGovernanceWire(
  value: unknown,
  path = "contractGovernance"
): ChainContractGovernanceProjection {
  const record = wireRecord(value, path);
  requireNumber(record, "chainId", path);
  requireString(record, "contractAddress", path);
  requireString(record, "owner", path);
  decodeProvenanceWire(record["ownerUpdatedAt"], `${path}.ownerUpdatedAt`);
  decodeProofWire(record["ownerProof"], `${path}.ownerProof`);
  optionalBoolean(record, "modulesFrozen", path);
  optionalString(record, "moduleSetHash", path);
  optionalProvenance(record, "frozenAt", path);
  if (record["frozenProof"] !== undefined) {
    decodeProofWire(record["frozenProof"], `${path}.frozenProof`);
  }
  return value as ChainContractGovernanceProjection;
}

export function decodeDockInputDeliveryWire(
  value: unknown,
  path = "dockInputDelivery"
): ChainDockInputDelivery {
  const record = wireRecord(value, path);
  for (const field of [
    "inputBindingHash",
    "localPlanId",
    "localOrderId",
    "targetPlanId",
    "linkedOrderId",
    "targetSignalId",
    "payloadHash",
    "submitter"
  ] as const) {
    requireString(record, field, path);
  }
  decodeProvenanceWire(record["deliveredAt"], `${path}.deliveredAt`);
  decodeProofWire(record["proof"], `${path}.proof`);
  return value as ChainDockInputDelivery;
}

export function decodeDockOutputDeliveryWire(
  value: unknown,
  path = "dockOutputDelivery"
): ChainDockOutputDelivery {
  const record = wireRecord(value, path);
  for (const field of [
    "outputBindingHash",
    "localPlanId",
    "localOrderId",
    "targetPlanId",
    "linkedOrderId",
    "targetSignalId",
    "localSignalId",
    "payloadHash",
    "submitter"
  ] as const) {
    requireString(record, field, path);
  }
  decodeProvenanceWire(record["deliveredAt"], `${path}.deliveredAt`);
  decodeProofWire(record["proof"], `${path}.proof`);
  return value as ChainDockOutputDelivery;
}

export function decodeDockWire(value: unknown, path = "dock"): ChainDockProjection {
  const record = wireRecord(value, path);
  requireString(record, "dockInstanceId", path);
  requireNumber(record, "chainId", path);
  requireString(record, "stateMachineAddress", path);
  requireEnum(record, "mode", path, DOCK_MODES);
  for (const field of [
    "localPlanId",
    "localOrderId",
    "routeId",
    "routeHash",
    "interfaceNameId",
    "targetPlanId",
    "linkedOrderId"
  ] as const) {
    requireString(record, field, path);
  }
  requireNumber(record, "depth", path);
  optionalString(record, "opener", path);
  optionalString(record, "attacher", path);
  decodeRecordMap(record["inputDeliveries"], `${path}.inputDeliveries`, decodeDockInputDeliveryWire);
  decodeRecordMap(record["outputDeliveries"], `${path}.outputDeliveries`, decodeDockOutputDeliveryWire);
  decodeProvenanceWire(record["openedAt"], `${path}.openedAt`);
  decodeProvenanceWire(record["updatedAt"], `${path}.updatedAt`);
  decodeProofWire(record["proof"], `${path}.proof`);
  return value as ChainDockProjection;
}

export function decodeSnapshotWire(
  value: unknown,
  path = "snapshot"
): ChainProjectionSnapshot {
  const record = wireRecord(value, path);
  if (record["rebuildable"] !== true) {
    throw new ChainReadContractError(`${path}.rebuildable`, "must be true");
  }
  requireNumber(record, "eventCount", path);
  optionalString(record, "activeStateMachineDeploymentId", path);
  for (const field of [
    "stateMachineDeployments",
    "stateMachineModules",
    "contractGovernance",
    "stateMachinePlans",
    "stateMachineOrders",
    "stateMachineDocks",
    "stateMachineDocksByTargetOrder",
    "stateMachineOrderDockChainDepth",
    "stateMachineTasks"
  ] as const) {
    wireRecord(record[field], `${path}.${field}`);
  }
  if (record["lastEvent"] !== undefined) {
    decodeProvenanceWire(record["lastEvent"], `${path}.lastEvent`);
  }
  for (const field of [
    "unresolvedModuleOrderEventCount",
    "unresolvedDockEventCount",
    "unresolvedStageActivationEventCount",
    "unresolvedDockTargetDeploymentCount",
    "capabilityEnrichmentMismatchCount",
    "unknownEventCount"
  ] as const) {
    optionalNumber(record, field, path);
  }
  return value as ChainProjectionSnapshot;
}

export function decodeRebuildMetadataWire(
  value: unknown,
  path = "rebuild"
): ChainRebuildMetadata {
  const record = wireRecord(value, path);
  requireEnum(record, "status", path, REBUILD_STATUSES);
  optionalString(record, "startedAt", path);
  optionalString(record, "completedAt", path);
  for (const field of ["deploymentBlock", "fromBlock", "toBlock"] as const) {
    if (record[field] !== undefined) {
      requireDecimalString(record, field, path);
    }
  }
  optionalNumber(record, "eventCount", path);
  optionalNumber(record, "activeEventCount", path);
  optionalNumber(record, "removedEventCount", path);
  optionalBoolean(record, "removedLogsFiltered", path);
  optionalBoolean(record, "projectionRebuilt", path);
  optionalNumber(record, "mismatchCount", path);
  return value as ChainRebuildMetadata;
}

export function decodeSyncDiagnosticsCountsWire(
  value: unknown,
  path = "projectionDiagnostics"
): ChainSyncDiagnosticsCounts {
  const record = wireRecord(value, path);
  for (const field of [
    "unresolvedModuleOrderEventCount",
    "unresolvedDockEventCount",
    "unresolvedStageActivationEventCount",
    "unresolvedDockTargetDeploymentCount",
    "unresolvedIdentityRevokeEventCount",
    "capabilityEnrichmentMismatchCount",
    "unknownEventCount",
    "semanticOracleMismatchCount",
    "semanticOracleCheckedPlanCount",
    "semanticOracleErrorCount",
    "semanticOracleExcludedPlanCount"
  ] as const) {
    requireNumber(record, field, path);
  }
  return value as ChainSyncDiagnosticsCounts;
}

export function decodeSyncStateWire(value: unknown, path = "syncState"): ChainSyncState {
  const record = wireRecord(value, path);
  requireNumber(record, "chainId", path);
  requireString(record, "contractAddress", path);
  requireEnum(record, "syncStatus", path, SYNC_STATUSES);
  for (const field of ["latestIndexedBlock", "finalizedBlock"] as const) {
    if (record[field] !== undefined) {
      requireDecimalString(record, field, path);
    }
  }
  requireNumber(record, "confirmationDepth", path);
  optionalString(record, "lastEventName", path);
  requireNumber(record, "eventCount", path);
  if (record["rebuild"] !== undefined) {
    decodeRebuildMetadataWire(record["rebuild"], `${path}.rebuild`);
  }
  if (record["projectionDiagnostics"] !== undefined) {
    decodeSyncDiagnosticsCountsWire(record["projectionDiagnostics"], `${path}.projectionDiagnostics`);
  }
  optionalString(record, "degradedReason", path);
  requireString(record, "updatedAt", path);
  return value as ChainSyncState;
}

export function isChainProvenance(value: unknown): value is ChainProvenance {
  return decodes(() => decodeProvenanceWire(value));
}

export function isChainProof(value: unknown): value is ChainProof {
  return decodes(() => decodeProofWire(value));
}

export function isChainOrderProjection(value: unknown): value is ChainOrderProjection {
  return decodes(() => decodeOrderWire(value));
}

export function isChainTaskProjection(value: unknown): value is ChainTaskProjection {
  return decodes(() => decodeTaskWire(value));
}

export function isChainPlanProjection(value: unknown): value is ChainPlanProjection {
  return decodes(() => decodePlanWire(value));
}


export function isChainProjectionSnapshot(value: unknown): value is ChainProjectionSnapshot {
  return decodes(() => decodeSnapshotWire(value));
}

export function isChainSyncState(value: unknown): value is ChainSyncState {
  return decodes(() => decodeSyncStateWire(value));
}

export function parseOrdersResponse(body: unknown): readonly ChainOrderProjection[] {
  const record = wireRecord(body, "response");
  const orders = decodeArray(record["orders"], "response.orders");
  return orders.map((order, index) => decodeOrderWire(order, `orders[${index}]`));
}

export function parseTasksResponse(body: unknown): readonly ChainTaskProjection[] {
  const record = wireRecord(body, "response");
  const tasks = decodeArray(record["tasks"], "response.tasks");
  return tasks.map((task, index) => decodeTaskWire(task, `tasks[${index}]`));
}

export function parseTaskResponse(body: unknown): ChainTaskProjection {
  const record = wireRecord(body, "response");
  return decodeTaskWire(record["task"], "task");
}

export function parseSyncStateResponse(body: unknown): ChainSyncState {
  const record = wireRecord(body, "response");
  return decodeSyncStateWire(record["syncState"], "syncState");
}

export function parseSnapshotResponse(body: unknown): ChainProjectionSnapshot {
  const record = wireRecord(body, "response");
  return decodeSnapshotWire(record["snapshot"], "snapshot");
}


function decodeProofArgs(value: unknown, path: string): void {
  const args = wireRecord(value, path);
  for (const [key, arg] of Object.entries(args)) {
    if (arg === null || typeof arg === "string" || typeof arg === "number" || typeof arg === "boolean") {
      continue;
    }
    throw new ChainReadContractError(`${path}.${key}`, "must be a string, number, boolean, or null");
  }
}

function decodeRecordMap<TValue>(
  value: unknown,
  path: string,
  decode: (entry: unknown, path: string) => TValue
): Readonly<Record<string, TValue>> {
  const record = wireRecord(value, path);
  return Object.fromEntries(
    Object.entries(record).map(([key, entry]) => [key, decode(entry, `${path}.${key}`)] as const)
  );
}

function wireRecord(value: unknown, path: string): WireRecord {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new ChainReadContractError(path, "must be an object");
  }
  return value as WireRecord;
}

function decodeArray(value: unknown, path: string): readonly unknown[] {
  if (!Array.isArray(value)) {
    throw new ChainReadContractError(path, "must be an array");
  }
  return value;
}

function requireString(record: WireRecord, field: string, path: string): void {
  if (typeof record[field] !== "string") {
    throw new ChainReadContractError(`${path}.${field}`, "must be a string");
  }
}

function optionalString(record: WireRecord, field: string, path: string): void {
  if (record[field] !== undefined && typeof record[field] !== "string") {
    throw new ChainReadContractError(`${path}.${field}`, "must be a string when present");
  }
}

function requireNumber(record: WireRecord, field: string, path: string): void {
  const value = record[field];
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new ChainReadContractError(`${path}.${field}`, "must be a finite number");
  }
}

function optionalNumber(record: WireRecord, field: string, path: string): void {
  const value = record[field];
  if (value !== undefined && (typeof value !== "number" || !Number.isFinite(value))) {
    throw new ChainReadContractError(`${path}.${field}`, "must be a finite number when present");
  }
}

function optionalBoolean(record: WireRecord, field: string, path: string): void {
  if (record[field] !== undefined && typeof record[field] !== "boolean") {
    throw new ChainReadContractError(`${path}.${field}`, "must be a boolean when present");
  }
}

function requireDecimalString(record: WireRecord, field: string, path: string): void {
  const value = record[field];
  if (typeof value !== "string" || !/^[0-9]+$/u.test(value)) {
    throw new ChainReadContractError(`${path}.${field}`, "must be a decimal string");
  }
}

function optionalProvenance(record: WireRecord, field: string, path: string): void {
  if (record[field] !== undefined) {
    decodeProvenanceWire(record[field], `${path}.${field}`);
  }
}

function requireEnum<TValue extends string>(
  record: WireRecord,
  field: string,
  path: string,
  values: readonly TValue[]
): void {
  if (!values.includes(record[field] as TValue)) {
    throw new ChainReadContractError(
      `${path}.${field}`,
      `must be one of ${values.join(", ")}`
    );
  }
}

function optionalEnum<TValue extends string>(
  record: WireRecord,
  field: string,
  path: string,
  values: readonly TValue[]
): void {
  if (record[field] !== undefined) {
    requireEnum(record, field, path, values);
  }
}

function decodes(decode: () => unknown): boolean {
  try {
    decode();
    return true;
  } catch {
    return false;
  }
}

// Neutral HTTP wire contract for chain-services' anonymous `/chain/*` reads:
// the single owner of projection field names and JSON value types. Bigint
// fields (block numbers, uint counters) are decimal strings on the wire; hex
// and address fields are `0x`-prefixed strings. Internal indexer projection
// types stay in chain-services; the app backend derives revived forms from
// these wire types.
import type { Address, Hex } from "viem";

/** Chain position of one emitted event; `blockNumber` is a decimal string. */
export interface ChainProvenance {
  readonly chainId: number;
  readonly contractAddress: Address;
  readonly blockNumber: string;
  readonly transactionIndex?: number;
  readonly transactionHash: Hex;
  readonly logIndex: number;
}

export type ChainProofArg = string | number | boolean | null;

export interface ChainProof extends ChainProvenance {
  readonly eventId: string;
  readonly eventName: string;
  readonly args: Readonly<Record<string, ChainProofArg>>;
  readonly blockHash?: Hex;
  readonly orderId?: Hex;
  readonly planId?: Hex;
  readonly planHash?: Hex;
  readonly submitter?: Address;
}

export interface ChainTimelineEvent {
  readonly timelineId: string;
  readonly orderId?: Hex;
  readonly planId?: Hex;
  readonly eventName: string;
  readonly text: string;
  readonly time: string;
  readonly proof: ChainProof;
}

export interface ChainSignalAuthorization {
  readonly orderId: Hex;
  readonly sourceId: Hex;
  readonly signalId: Hex;
  readonly submitter: Address;
  readonly role: Hex;
  readonly metadataHash: Hex;
  readonly authorizedAt: ChainProvenance;
  readonly proof: ChainProof;
}

export interface ChainSignal {
  readonly orderId: Hex;
  readonly sourceId: Hex;
  readonly signalId: Hex;
  readonly payloadHash: Hex;
  readonly idempotencyKey: Hex;
  readonly submitter: Address;
  readonly factStageId?: Hex;
  readonly replayedFromFork?: boolean;
  readonly submittedAt: ChainProvenance;
  readonly proof: ChainProof;
}

export interface ChainDerivedSignal {
  readonly targetOrderId: Hex;
  readonly fromPlanId: Hex;
  readonly fromOrderId: Hex;
  readonly fromStageId: Hex;
  readonly targetSourceId: Hex;
  readonly signalId: Hex;
  readonly payloadHash: Hex;
  readonly idempotencyKey: Hex;
  readonly submitter?: Address;
  readonly relation?: string;
  readonly submittedAt: ChainProvenance;
  readonly proof: ChainProof;
}

export interface ChainStageMaterialization {
  readonly orderId: Hex;
  readonly stageId: Hex;
  readonly triggerHookId?: Hex;
  readonly sourceId?: Hex;
  readonly signalId?: Hex;
  readonly materializedAt: ChainProvenance;
  readonly proof: ChainProof;
}

export type ChainStageExecutorPatchMode = "assign" | "handoff";

export interface ChainStageExecutorOverlay {
  readonly orderId: Hex;
  readonly selectorStageId: Hex;
  readonly targetStageId: Hex;
  readonly selectorWallet: Address;
  readonly activeExecutorWallet: Address;
  readonly mode: ChainStageExecutorPatchMode;
  readonly modeHash?: Hex;
  readonly previousExecutor?: Address;
  readonly authorizationsHash?: Hex;
  readonly roleHash: Hex;
  readonly executorMetadataHash: Hex;
  readonly patchHash: Hex;
  readonly patchNonce: string;
  readonly metadataURI: string;
  readonly updatedAt: ChainProvenance;
  readonly activatedAt?: ChainProvenance;
  readonly proof: ChainProof;
  readonly activationProof?: ChainProof;
}

export interface ChainStageResourceOverlay {
  readonly orderId: Hex;
  readonly selectorStageId: Hex;
  readonly targetStageId: Hex;
  readonly resourceKey: Hex;
  readonly selectorWallet: Address;
  readonly manifestHash: Hex;
  readonly policyHash: Hex;
  readonly patchHash: Hex;
  readonly patchNonce: string;
  readonly manifestURI: string;
  readonly updatedAt: ChainProvenance;
  readonly proof: ChainProof;
}

export type ChainHookStatus = "init" | "waiting" | "ready" | "cancelled" | "unknown";

export interface ChainHook {
  readonly orderId: Hex;
  readonly hookId: Hex;
  readonly stageIdentifier?: Hex;
  readonly hookName?: Hex;
  readonly status: ChainHookStatus;
  readonly previousStatus?: ChainHookStatus;
  readonly dueAt?: string;
  readonly updatedAt: ChainProvenance;
  readonly readyAt?: ChainProvenance;
  readonly proof: ChainProof;
}

export type ChainTaskStatus = "ready" | "submitted" | "cancelled" | "unknown";

export interface ChainSubmitSignal {
  readonly sourceId: Hex;
  readonly signalId: Hex;
  readonly source: "plan_capability" | "authorization";
}

export interface ChainTaskProjection {
  readonly taskId: string;
  readonly orderId: Hex;
  readonly stateMachineAddress: Address;
  readonly planId?: Hex;
  readonly deploymentId?: Hex;
  readonly hookId: Hex;
  readonly stageIdentifier: Hex;
  readonly hookName: Hex;
  readonly assigneeRole: string;
  readonly assigneeWallet?: Address;
  readonly assigneeRoleHash?: Hex;
  readonly authorizationMetadataHash?: Hex;
  readonly status: ChainTaskStatus;
  readonly submitSignals?: readonly ChainSubmitSignal[];
  readonly createdAt: ChainProvenance;
  readonly updatedAt: ChainProvenance;
  readonly proof: ChainProof;
}

export interface ChainOrderTriggerLink {
  readonly triggeredOrderId: Hex;
  readonly triggerOriginOrderId: Hex;
  readonly triggerStageId: Hex;
  readonly originPlanId?: Hex;
  readonly originSourceId: Hex;
  readonly originSignalId: Hex;
  readonly linkedAt: ChainProvenance;
  readonly proof: ChainProof;
}

export interface ChainOrderFork {
  readonly orderId: Hex;
  readonly parentOrderId: Hex;
  readonly approvalSourceId: Hex;
  readonly approvalSignalId: Hex;
  readonly initiator: Address;
  readonly forkPayloadHash?: Hex;
  readonly replayedFactKeys?: readonly Hex[];
  readonly forkedAt: ChainProvenance;
  readonly proof: ChainProof;
}

export type ChainOrderStatus = "registered" | "unknown";

export interface ChainOrderProjection {
  readonly orderId: Hex;
  readonly chainId: number;
  readonly contractAddress: Address;
  readonly deploymentId?: Hex;
  readonly planId: Hex;
  readonly planHash?: Hex;
  readonly status: ChainOrderStatus;
  readonly currentStage?: Hex;
  readonly relayer?: Address;
  readonly creator?: Address;
  readonly authorizations: Readonly<Record<string, ChainSignalAuthorization>>;
  readonly signals: Readonly<Record<string, ChainSignal>>;
  readonly derivedSignals: Readonly<Record<string, ChainDerivedSignal>>;
  readonly stageMaterializations: Readonly<Record<string, ChainStageMaterialization>>;
  readonly stageExecutorOverlays: Readonly<Record<string, ChainStageExecutorOverlay>>;
  readonly stageResourceOverlays: Readonly<Record<string, ChainStageResourceOverlay>>;
  readonly triggerLink?: ChainOrderTriggerLink;
  readonly forkLineage?: ChainOrderFork;
  readonly hooks: Readonly<Record<string, ChainHook>>;
  readonly tasks: Readonly<Record<string, ChainTaskProjection>>;
  readonly timeline: readonly ChainTimelineEvent[];
  readonly proof: readonly ChainProof[];
  readonly registeredAt?: ChainProvenance;
  readonly updatedAt: ChainProvenance;
}

export interface ChainModuleProjection {
  readonly chainId: number;
  readonly stateMachineAddress: Address;
  readonly moduleId: Hex;
  readonly previousModule: Address;
  readonly moduleAddress: Address;
  readonly updatedAt: ChainProvenance;
  readonly proof: ChainProof;
}

export type ChainPlanCapabilityEnrichmentStatus = "enriched" | "failed";

export type ChainSignalTargetRelation = "current" | "triggerOrigin" | "unknown";

export interface ChainStageSelectorBinding {
  readonly selectorStageIdentifier?: string;
  readonly targetStageIdentifier?: string;
  readonly selectorStageId: Hex;
  readonly targetStageId: Hex;
  readonly bindingHash?: Hex;
}

export interface ChainExecutorCandidate {
  readonly stageId: Hex;
  readonly executor: Address;
}

export interface ChainSignalCapability {
  readonly stageId: Hex;
  readonly targetSourceId: Hex;
  readonly signalId: Hex;
  readonly targetOrderRelation: ChainSignalTargetRelation;
  readonly registeredAt: ChainProvenance;
  readonly proof: ChainProof;
}

export interface ChainPlanProjection {
  readonly planId: Hex;
  readonly deploymentId?: Hex;
  readonly stateMachineAddress: Address;
  readonly planHash: Hex;
  readonly hookCount: string;
  readonly publisher?: Address;
  readonly hooksHash?: Hex;
  readonly capabilitiesRoot?: Hex;
  readonly dockRoutesRoot?: Hex;
  readonly dockInterfaceRoot?: Hex;
  readonly executorCandidatesRoot?: Hex;
  readonly birthAuthorizer?: Address;
  readonly committedAt?: ChainProvenance;
  readonly finalizedAt?: ChainProvenance;
  readonly selectorBindings: readonly ChainStageSelectorBinding[];
  readonly signalCapabilities: readonly ChainSignalCapability[];
  readonly executorCandidates: readonly ChainExecutorCandidate[];
  readonly capabilityEnrichment?: ChainPlanCapabilityEnrichmentStatus;
  readonly registeredAt: ChainProvenance;
  readonly publisherRecordedAt?: ChainProvenance;
  readonly updatedAt: ChainProvenance;
  readonly proof: ChainProof;
  readonly publisherProof?: ChainProof;
  readonly commitProof?: ChainProof;
  readonly finalizationProof?: ChainProof;
}

export type ChainDeploymentStatus =
  | "candidate"
  | "canary"
  | "active"
  | "deprecated"
  | "retired"
  | "unknown";

export interface ChainDeploymentProjection {
  readonly deploymentId: Hex;
  readonly stateMachineAddress: Address;
  readonly artifactHash: Hex;
  readonly abiHash: Hex;
  /** Decimal block number string. */
  readonly deploymentBlock: string;
  readonly activatedAtBlock?: string;
  readonly evidenceHash?: Hex;
  readonly metadataURI: string;
  readonly status: ChainDeploymentStatus;
  readonly registeredAt: ChainProvenance;
  readonly updatedAt: ChainProvenance;
  readonly proof: ChainProof;
}

export interface ChainContractGovernanceProjection {
  readonly chainId: number;
  readonly contractAddress: Address;
  readonly owner: Address;
  readonly ownerUpdatedAt: ChainProvenance;
  readonly ownerProof: ChainProof;
  readonly modulesFrozen?: boolean;
  readonly moduleSetHash?: Hex;
  readonly frozenAt?: ChainProvenance;
  readonly frozenProof?: ChainProof;
}

export type ChainDockMode = "new" | "existing";

export interface ChainDockInputDelivery {
  readonly inputBindingHash: Hex;
  readonly localPlanId: Hex;
  readonly localOrderId: Hex;
  readonly targetPlanId: Hex;
  readonly linkedOrderId: Hex;
  readonly targetSignalId: Hex;
  readonly payloadHash: Hex;
  readonly submitter: Address;
  readonly deliveredAt: ChainProvenance;
  readonly proof: ChainProof;
}

export interface ChainDockOutputDelivery {
  readonly outputBindingHash: Hex;
  readonly localPlanId: Hex;
  readonly localOrderId: Hex;
  readonly targetPlanId: Hex;
  readonly linkedOrderId: Hex;
  readonly targetSignalId: Hex;
  readonly localSignalId: Hex;
  readonly payloadHash: Hex;
  readonly submitter: Address;
  readonly deliveredAt: ChainProvenance;
  readonly proof: ChainProof;
}

export interface ChainDockProjection {
  readonly dockInstanceId: Hex;
  readonly chainId: number;
  readonly stateMachineAddress: Address;
  readonly mode: ChainDockMode;
  readonly localPlanId: Hex;
  readonly localOrderId: Hex;
  readonly routeId: Hex;
  readonly routeHash: Hex;
  readonly interfaceNameId: Hex;
  readonly targetPlanId: Hex;
  readonly linkedOrderId: Hex;
  readonly depth: number;
  readonly opener?: Address;
  readonly attacher?: Address;
  readonly inputDeliveries: Readonly<Record<string, ChainDockInputDelivery>>;
  readonly outputDeliveries: Readonly<Record<string, ChainDockOutputDelivery>>;
  readonly openedAt: ChainProvenance;
  readonly updatedAt: ChainProvenance;
  readonly proof: ChainProof;
}

/** Complete rebuildable order projection snapshot; every nested block number is a decimal string. */
export interface ChainProjectionSnapshot {
  readonly rebuildable: true;
  readonly eventCount: number;
  readonly activeStateMachineDeploymentId?: Hex;
  readonly stateMachineDeployments: Readonly<Record<string, ChainDeploymentProjection>>;
  readonly stateMachineModules: Readonly<Record<string, ChainModuleProjection>>;
  readonly contractGovernance: Readonly<Record<string, ChainContractGovernanceProjection>>;
  readonly stateMachinePlans: Readonly<Record<string, ChainPlanProjection>>;
  readonly stateMachineOrders: Readonly<Record<string, ChainOrderProjection>>;
  readonly stateMachineDocks: Readonly<Record<string, ChainDockProjection>>;
  readonly stateMachineDocksByTargetOrder: Readonly<Record<string, readonly string[]>>;
  readonly stateMachineOrderDockChainDepth: Readonly<Record<string, number>>;
  readonly stateMachineTasks: Readonly<Record<string, ChainTaskProjection>>;
  readonly lastEvent?: ChainProvenance;
  readonly unresolvedModuleOrderEventCount?: number;
  readonly unresolvedDockEventCount?: number;
  readonly unresolvedStageActivationEventCount?: number;
  readonly unresolvedDockTargetDeploymentCount?: number;
  readonly capabilityEnrichmentMismatchCount?: number;
  readonly unknownEventCount?: number;
}

export type ChainSyncStatus = "indexed" | "syncing" | "stale" | "rebuilding" | "degraded";

export type ChainRebuildStatus = "idle" | "running" | "completed" | "failed";

export interface ChainRebuildMetadata {
  readonly status: ChainRebuildStatus;
  readonly startedAt?: string;
  readonly completedAt?: string;
  /** Decimal block number strings. */
  readonly deploymentBlock?: string;
  readonly fromBlock?: string;
  readonly toBlock?: string;
  readonly eventCount?: number;
  readonly activeEventCount?: number;
  readonly removedEventCount?: number;
  readonly removedLogsFiltered?: boolean;
  readonly projectionRebuilt?: boolean;
  readonly mismatchCount?: number;
}

export interface ChainSyncDiagnosticsCounts {
  readonly unresolvedModuleOrderEventCount: number;
  readonly unresolvedDockEventCount: number;
  readonly unresolvedStageActivationEventCount: number;
  readonly unresolvedDockTargetDeploymentCount: number;
  readonly unresolvedIdentityRevokeEventCount: number;
  readonly capabilityEnrichmentMismatchCount: number;
  readonly unknownEventCount: number;
  readonly semanticOracleMismatchCount: number;
  readonly semanticOracleCheckedPlanCount: number;
  readonly semanticOracleErrorCount: number;
  readonly semanticOracleExcludedPlanCount: number;
}

export interface ChainSyncState {
  readonly chainId: number;
  readonly contractAddress: Address;
  readonly syncStatus: ChainSyncStatus;
  /** Decimal block number string. */
  readonly latestIndexedBlock?: string;
  /** Decimal block number string. */
  readonly finalizedBlock?: string;
  readonly confirmationDepth: number;
  readonly lastEventName?: string;
  readonly eventCount: number;
  readonly rebuild?: ChainRebuildMetadata;
  readonly projectionDiagnostics?: ChainSyncDiagnosticsCounts;
  readonly degradedReason?: string;
  readonly updatedAt: string;
}

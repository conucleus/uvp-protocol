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

export interface ChainSignal {
  readonly orderId: Hex;
  readonly sourceId: Hex;
  readonly signalId: Hex;
  readonly payloadHash: Hex;
  readonly idempotencyKey: Hex;
  readonly submitter: Address;
  /** 代付交易的钱包；业务签名者始终是 submitter。 */
  readonly relayer?: Address;
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

export interface ChainStageExecutorOverlay {
  readonly orderId: Hex;
  readonly selectorStageId?: Hex;
  readonly targetStageId: Hex;
  readonly selector?: Address;
  readonly supplierId: Hex;
  readonly previousSupplierId?: Hex;
  readonly patchNonce: string;
  readonly dockId?: Hex;
  readonly fromPlanId?: Hex;
  /** SupplierRegistry 在投影时点解析的 executorOf(supplierId)；供应商已撤销时缺省。 */
  readonly effectiveExecutor?: Address;
  readonly updatedAt: ChainProvenance;
  readonly activatedAt?: ChainProvenance;
  readonly proof: ChainProof;
  readonly activationProof?: ChainProof;
}

export interface ChainStageFileEntry {
  readonly key: Hex;
  readonly contentHash: Hex;
  readonly handle: string;
  readonly patchHash: Hex;
  readonly updatedAt: ChainProvenance;
  readonly proof: ChainProof;
}

export interface ChainStageFileMap {
  readonly planId: Hex;
  readonly orderId: Hex;
  readonly targetStageId: Hex;
  readonly filesHash: Hex;
  readonly files: Readonly<Record<string, ChainStageFileEntry>>;
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
  readonly assigneeSupplierId?: Hex;
  readonly assigneeExecutor?: Address;
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
  readonly signals: Readonly<Record<string, ChainSignal>>;
  readonly derivedSignals: Readonly<Record<string, ChainDerivedSignal>>;
  readonly stageMaterializations: Readonly<Record<string, ChainStageMaterialization>>;
  readonly stageExecutorOverlays: Readonly<Record<string, ChainStageExecutorOverlay>>;
  readonly stageFiles: Readonly<Record<string, ChainStageFileMap>>;
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
  readonly selectorStageId?: Hex;
  readonly targetStageId: Hex;
  readonly bindingHash?: Hex;
}

export type ChainExecutorBindingKind = "default" | "candidate";

export interface ChainExecutorBinding {
  readonly stageId: Hex;
  readonly supplierId: Hex;
  readonly kind: ChainExecutorBindingKind;
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
  readonly executorBindingsRoot?: Hex;
  readonly birthAuthorizer?: Address;
  readonly committedAt?: ChainProvenance;
  readonly finalizedAt?: ChainProvenance;
  readonly selectorBindings: readonly ChainStageSelectorBinding[];
  readonly signalCapabilities: readonly ChainSignalCapability[];
  readonly executorBindings: readonly ChainExecutorBinding[];
  readonly dynamicExecutorStages?: readonly Hex[];
  readonly capabilityEnrichment?: ChainPlanCapabilityEnrichmentStatus;
  readonly registeredAt: ChainProvenance;
  readonly publisherRecordedAt?: ChainProvenance;
  readonly updatedAt: ChainProvenance;
  readonly proof: ChainProof;
  readonly publisherProof?: ChainProof;
  readonly commitProof?: ChainProof;
  readonly finalizationProof?: ChainProof;
}

export interface ChainPlanAdmission {
  readonly admissionId: Hex;
  readonly stageId: Hex;
  readonly stageIdentifier: string;
  readonly signalName: string;
  readonly signalId: Hex;
  readonly sourceId: Hex;
}

export interface ChainPlanAdmissionsResponse {
  readonly chainId: number;
  readonly planId: Hex;
  readonly planHash: Hex;
  readonly admissions: readonly ChainPlanAdmission[];
}

export type ChainPlanTriggerKind = "trigger";

/** One order-trigger hook of the recorded plan artifact; `trigger` is the external birth line. */
export interface ChainPlanTrigger {
  readonly hookId: Hex;
  readonly stageIdentifier: string;
  readonly stageId: Hex;
  readonly hookName: string;
  readonly orderTriggerKind: ChainPlanTriggerKind;
  readonly source: string;
  readonly signalName: string;
  readonly sourceId: Hex;
  readonly signalId: Hex;
}

export interface ChainPlanTriggersResponse {
  readonly chainId: number;
  readonly planId: Hex;
  readonly planHash: Hex;
  readonly triggers: readonly ChainPlanTrigger[];
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

/** Wire schema label for the static Dock projection (`uvp.dock.v1`). */
export const DOCK_SCHEMA_VERSION = "uvp.dock.v1" as const;

/**
 * Wire schema label for the binding read face (`uvp.dockBinding.v1`): a binding
 * is derived from the selected dkid, the `dock_link` payload file record, and
 * the poke evaluation; there is no link status row.
 */
export const DOCK_BINDING_SCHEMA_VERSION = "uvp.dockBinding.v1" as const;

export interface ChainDockAtom {
  readonly source: string;
  readonly sourceId: Hex;
  readonly stage: string;
  readonly stageId: Hex;
  readonly signal: string;
  readonly signalId: Hex;
  readonly targetOrderRelation: ChainSignalTargetRelation;
}

export type ChainDockConditionAst =
  | { readonly kind: "signal"; readonly signalName: string }
  | { readonly kind: "not"; readonly expr: ChainDockConditionAst }
  | { readonly kind: "and"; readonly terms: readonly ChainDockConditionAst[] }
  | { readonly kind: "or"; readonly terms: readonly ChainDockConditionAst[] }
  | {
      readonly kind: "delay";
      readonly expr: ChainDockConditionAst;
      readonly durationSeconds: number;
      readonly rawDuration: string;
    };

export interface ChainDockExpressionAst {
  readonly raw: string;
  readonly source: string;
  readonly condition: ChainDockConditionAst;
}

export interface ChainDockDependency {
  readonly kind: "positive" | "negative" | "timer";
  readonly source: string;
  readonly signalName: string;
  readonly delaySeconds?: number;
}

export interface ChainDockOutput {
  readonly signal: string;
  readonly signalId: Hex;
  readonly sourceId: Hex;
  readonly stageId: Hex;
  readonly targetOrderRelation: ChainSignalTargetRelation;
  readonly rawExpression: string;
  readonly ast: ChainDockExpressionAst;
  readonly dependencies: readonly ChainDockDependency[];
  readonly atoms: readonly ChainDockAtom[];
}

export interface ChainDock {
  readonly dkid: string;
  readonly docHash: Hex;
  readonly from: {
    readonly zhixu: string;
    readonly source: string;
    readonly sourceId: Hex;
  };
  readonly to: {
    readonly zhixu: string;
    readonly stage: string;
    readonly stageId: Hex;
    readonly source: string;
    readonly sourceId: Hex;
  };
  readonly signalMap: readonly ChainDockOutput[];
  readonly registeredAt: ChainProvenance;
  readonly proof: ChainProof;
}

export interface ChainDockFactRef {
  readonly order_id?: Hex;
  readonly source?: string;
  readonly stage_identifier?: string;
  readonly signal?: string;
  readonly label?: string;
}

export type ChainDockBindingRef = ChainProvenance | ChainDockFactRef;

export interface ChainDockBindingWindow {
  readonly satisfied: boolean;
  readonly opened_by?: ChainDockBindingRef | null;
  readonly closed_by?: ChainDockBindingRef | null;
  readonly delay_seconds?: number;
}

export interface ChainDockBindingOutput {
  readonly signal: string;
  readonly a_window?: ChainDockBindingWindow | null;
  readonly b_window?: ChainDockBindingWindow | null;
  readonly emitted: boolean;
  readonly emitted_by?: ChainDockBindingRef | null;
  readonly emitted_binding_id?: Hex;
}

export interface ChainDockBinding {
  readonly binding_id: Hex;
  readonly dkid: string;
  readonly from_zhixu_id: string;
  readonly from_source: string;
  readonly from_order_id: Hex;
  readonly to_zhixu_id: string;
  readonly to_stage_identifier: string;
  readonly to_order_id: Hex;
  readonly selected_by?: ChainDockBindingRef | null;
  readonly pending?: boolean;
  readonly outputs: readonly ChainDockBindingOutput[];
  readonly proof?: ChainProof;
}

/** SupplierRegistry binding at projection time; revoked suppliers keep their last executor and revocation proof. */
export interface ChainSupplier {
  readonly supplierId: Hex;
  readonly executor: Address;
  readonly registeredAt: ChainProvenance;
  readonly updatedAt: ChainProvenance;
  readonly proof: ChainProof;
  readonly rotatedAt?: ChainProvenance;
  readonly rotationProof?: ChainProof;
  readonly revokedAt?: ChainProvenance;
  readonly revocationProof?: ChainProof;
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
  readonly stateMachineDocks: Readonly<Record<string, ChainDock>>;
  readonly stateMachineDockBindings: Readonly<Record<string, ChainDockBinding>>;
  readonly stateMachineTasks: Readonly<Record<string, ChainTaskProjection>>;
  readonly stateMachineSuppliers: Readonly<Record<string, ChainSupplier>>;
  readonly lastEvent?: ChainProvenance;
  readonly unresolvedModuleOrderEventCount?: number;
  readonly unresolvedStageActivationEventCount?: number;
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
  readonly unresolvedStageActivationEventCount: number;
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

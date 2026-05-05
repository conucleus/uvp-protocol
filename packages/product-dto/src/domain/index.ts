export type ProductTone = "ok" | "warn" | "info" | "neutral";

export type ReviewStatus = "approved" | "restricted" | "rejected" | "revoked" | "unreviewed";
export type ChainAttestationStatus = "attested" | "revoked" | "not_found";
export type StageStatus = "done" | "active" | "pending";
export type ParticipantStatus = "joined" | "invited" | "pending_confirmation" | "assigned" | "not_started";
export type RoleSlotStatus = "required" | "connected" | "optional";
export type DockableModuleStatus = "connected" | "available" | "planned";
export type OrderStatus = "draft" | "pending_participants" | "active" | "in_dispute" | "completed";
export type TaskStatus = "open" | "submitted" | "blocked" | "done";
export type PermissionPayloadPolicy = "required" | "optional";
export type FulfillmentPluginKind =
  | "payment_placeholder"
  | "evidence_submission"
  | "delivery_update"
  | "validation_confirm"
  | "dispute_material";
export type ProductStageKind = "control" | "business";
export type ProductStageExecutorAssignment = "static" | "selected";
export type ParticipantAddOnManifestSchemaVersion = "participant-addon-manifest.v1";
export type StageExecutorActionKind =
  | "submit_signal"
  | "stage_executor_patch"
  | "stage_resource_patch";
export type ParticipantAddOnManifestActionKind = StageExecutorActionKind;
/** @deprecated Use StageExecutorActionKind. */
export type ParticipantAddOnKind = StageExecutorActionKind;
export type ParticipantAddOnManifestSignalIntent =
  | "confirm_stage"
  | "reject_stage"
  | "raise_dispute"
  | "resolve_dispute";
export type ParticipantAddOnManifestComponentKind =
  | "text"
  | "textarea"
  | "wallet"
  | "uri"
  | "hash"
  | "select"
  | "confirmation"
  | "stage_select"
  | "evidence_refs"
  | "resource_requirements"
  | "proof_rows";
export type ProductExecutorPatchMode = "assign" | "handoff" | "replacement";
export type ProductResourceRequirementSource = "plan_default" | "resource_patch" | "participant_input";
export type ProductFileResourceSource = ProductResourceRequirementSource | "stage_patch";
export type ProductResourceType = "document" | "image" | "metadata" | "uri" | "other";
export type ProductFileResourceType = ProductResourceType;
export type ProductResourceVisibility = "public" | "protected" | "private";
export type ProductResourcePolicyPrincipalKind = "wallet" | "role" | "stage" | "participant";
export type ProductResourceAccessState = "available" | "locked" | "request_required" | "not_authorized" | "unknown";
export type ProductDockedZhixuRuntimeStatus =
  | "draft_map"
  | "linked_order_required"
  | "linked_order_registered"
  | "linked_order_active"
  | "signal_map_waiting"
  | "signal_map_satisfied"
  | "blocked"
  | "not_modeled";
export type ProductizationConvergenceTrack =
  | "product_schema_v1"
  | "dynamic_executor_authorization"
  | "docked_zhixu_runtime"
  | "resource_manifest_access"
  | "store_schema_authoring"
  | "proof_read_model"
  | "identity_audit_ops"
  | "signal_container_producer";
export type ProductizationConvergenceStatus = "closed" | "partial" | "prototype" | "open";
export type CapabilityPluginSource = "explicit" | "legacy_inferred" | "missing";
export type StoreCapabilityReviewStatus = "explicit" | "inferred" | "missing";
export type StoreProductSchemaVersion = "store-product-schema.v1";
export type StoreSearchType = "all" | "zhixu" | "order" | "supplier";
export type StoreSearchResultType = "zhixu" | "order" | "supplier";
export type StoreSearchSourceOfTruth = "chain" | "chain-and-store-metadata" | "store-metadata";
export type StoreProjectionSyncStatus = "indexed" | "syncing" | "stale" | "rebuilding" | "degraded";
export type StoreZhixuLifecycleStatus =
  | "draft"
  | "compiled"
  | "submitted_for_review"
  | "approved_for_broadcast"
  | "attested"
  | "active"
  | "deprecated"
  | "rejected"
  | "revoked";
export type StoreSupplierReviewStatus = "draft" | "submitted" | "approved_for_broadcast" | "rejected" | "revoked";
export type StoreSupplierTrustStatus = ChainAttestationStatus;
export type StoreSupplierCapabilityTag =
  | "logistics"
  | "customs"
  | "inspection"
  | "payment"
  | "dispute-review"
  | "document-verification";

export const STORE_SUPPLIER_CAPABILITY_TAGS: readonly StoreSupplierCapabilityTag[] = [
  "logistics",
  "customs",
  "inspection",
  "payment",
  "dispute-review",
  "document-verification"
] as const;

export const STORE_PRODUCT_SCHEMA_V1_REQUIRED_FIELDS = [
  "schemaVersion",
  "version",
  "title",
  "maintainer",
  "planId",
  "planHash",
  "artifactHash",
  "roleSlots",
  "orderPermissionTable",
  "capabilityPlugins",
  "businessPersonaLabels",
  "stages",
  "schemaHash",
  "validation",
  "createdAt",
  "updatedAt"
] as const;

export const PARTICIPANT_ADDON_MANIFEST_V1_ACTION_KINDS = [
  "submit_signal",
  "stage_executor_patch",
  "stage_resource_patch"
] as const;

export interface MoneyDTO {
  readonly amount: string;
  readonly currency: string;
  readonly display: string;
}

export interface ChainProofRowDTO {
  readonly label: string;
  readonly value: string;
}

export interface ChainAttestationDTO {
  readonly status: ChainAttestationStatus;
  readonly label: string;
  readonly domainLabel: string;
  readonly planId: string;
  readonly planHash: string;
  readonly artifactHash?: string;
  readonly metadataURI?: string;
  readonly txHash?: string;
  readonly blockNumber?: string;
  readonly revokedReasonURI?: string;
}

export interface ProductExecutorOverlayDTO {
  readonly orderId: string;
  readonly selectorStageId: string;
  readonly targetStageId: string;
  readonly mode?: ProductExecutorPatchMode;
  readonly modeLabel?: string;
  readonly selectorWallet: string;
  readonly previousExecutor?: string;
  readonly previousExecutorWallet?: string;
  readonly previousExecutorLabel?: string;
  readonly activeExecutorWallet: string;
  readonly activeExecutorLabel?: string;
  readonly newExecutorWallet?: string;
  readonly newExecutorLabel?: string;
  readonly roleHash: string;
  readonly executorMetadataHash: string;
  readonly approvalSourceId?: string;
  readonly approvalSignalId?: string;
  readonly approvalSignalLabel?: string;
  readonly approvalSignal?: ProductExecutorPatchApprovalSignalDTO;
  readonly priorAuthorityLabel?: string;
  readonly futureAuthorityLabel?: string;
  readonly authorityNotice?: string;
  readonly patchHash: string;
  readonly patchNonce: string;
  readonly metadataURI?: string;
  readonly proofRows: readonly ChainProofRowDTO[];
}

export interface ProductExecutorPatchApprovalSignalDTO {
  readonly approvalSourceId: string;
  readonly approvalSignalId: string;
  readonly label?: string;
  readonly txHash?: string;
  readonly blockNumber?: string;
  readonly proofRows?: readonly ChainProofRowDTO[];
}

export interface ProductExecutorPatchRequirementDTO {
  readonly mode: ProductExecutorPatchMode;
  readonly modeLabel: string;
  readonly targetStageId?: string;
  readonly allowed: boolean;
  readonly workStarted: boolean;
  readonly requiresSelectorSignature: boolean;
  readonly requiresPreviousExecutorSignature: boolean;
  readonly requiresApprovalSignal: boolean;
  readonly previousExecutor?: string;
  readonly previousExecutorWallet?: string;
  readonly previousExecutorLabel?: string;
  readonly approvalSourceId?: string;
  readonly approvalSignalId?: string;
  readonly approvalSignalLabel?: string;
  readonly approvalSignal?: ProductExecutorPatchApprovalSignalDTO;
  readonly priorAuthorityLabel?: string;
  readonly futureAuthorityLabel?: string;
  readonly guidanceLabel?: string;
  readonly disabledReason?: string;
  readonly proofRows?: readonly ChainProofRowDTO[];
}

export interface ProductDockedSignalMapEntryDTO {
  readonly entryId: string;
  readonly localStageId: string;
  readonly localSignalLabel: string;
  readonly linkedStageId: string;
  readonly linkedSignalLabel: string;
  readonly satisfied: boolean;
  readonly proofRows?: readonly ChainProofRowDTO[];
}

export interface ProductDockedZhixuRuntimeDTO {
  readonly dockingId: string;
  readonly localOrderId: string;
  readonly localStageId: string;
  readonly linkedZhixuId: string;
  readonly linkedPlanId?: string;
  readonly linkedPlanHash?: string;
  readonly linkedOrderId?: string;
  readonly status: ProductDockedZhixuRuntimeStatus;
  readonly statusLabel: string;
  readonly signalMap: readonly ProductDockedSignalMapEntryDTO[];
  readonly privacyNotice?: string;
  readonly proofRows: readonly ChainProofRowDTO[];
}

export interface ProductizationConvergenceItemDTO {
  readonly track: ProductizationConvergenceTrack;
  readonly status: ProductizationConvergenceStatus;
  readonly ownerModule: string;
  readonly publicClaim: string;
  readonly nextAction: string;
}

export interface ProductizationConvergenceSummaryDTO {
  readonly schemaVersion: "productization-convergence.v1";
  readonly generatedAt: string;
  readonly items: readonly ProductizationConvergenceItemDTO[];
}

export interface ProductResourcePolicyPrincipalDTO {
  readonly kind: ProductResourcePolicyPrincipalKind;
  readonly label: string;
  readonly value?: string;
}

export interface ProductResourceAccessPolicyDTO {
  readonly visibility: ProductResourceVisibility;
  readonly readers: readonly ProductResourcePolicyPrincipalDTO[];
  readonly writers: readonly ProductResourcePolicyPrincipalDTO[];
  readonly controllers: readonly ProductResourcePolicyPrincipalDTO[];
  readonly policyHash?: string;
}

export interface ProductResourceAccessStatusDTO {
  readonly state: ProductResourceAccessState;
  readonly label: string;
  readonly canRead: boolean;
  readonly canWrite?: boolean;
  readonly canControl?: boolean;
  readonly reason?: string;
}

export interface ProductResourceManifestDTO {
  readonly schemaVersion: "uvp-resource-manifest-v1";
  readonly orderId: string;
  readonly targetStageId: string;
  readonly resourceKey: string;
  readonly visibility: ProductResourceVisibility;
  readonly manifestURI: string;
  readonly manifestHash: string;
  readonly policyHash: string;
  readonly contentHash?: string;
  readonly ciphertextHash?: string;
  readonly storageCID?: string;
  readonly recipientEnvelopeRoot?: string;
  readonly createdBy: string;
  readonly createdAt: string;
  readonly supersedes?: string;
}

export interface ProductResourceOverlayDTO {
  readonly orderId: string;
  readonly selectorStageId: string;
  readonly targetStageId: string;
  readonly resourceKey: string;
  readonly writerWallet: string;
  readonly manifestURI: string;
  readonly manifestHash: string;
  readonly policyHash: string;
  readonly patchHash: string;
  readonly patchNonce: string;
  readonly visibility: ProductResourceVisibility;
  readonly proofRows: readonly ChainProofRowDTO[];
}

export interface ProductResourceRequirementDTO {
  readonly resourceId: string;
  readonly resourceKey?: string;
  readonly label: string;
  readonly required: boolean;
  readonly source: ProductResourceRequirementSource;
  readonly resourceType?: ProductResourceType;
  readonly description?: string;
  readonly visibility?: ProductResourceVisibility;
  readonly manifestURI?: string;
  readonly manifestHash?: string;
  readonly manifest?: ProductResourceManifestDTO;
  readonly accessPolicy?: ProductResourceAccessPolicyDTO;
  readonly accessStatus?: ProductResourceAccessStatusDTO;
  readonly metadataURI?: string;
  readonly contentHash?: string;
  readonly ciphertextHash?: string;
  readonly storageCID?: string;
  readonly sourceStageId?: string;
  readonly sourcePatchHash?: string;
  readonly proofRows?: readonly ChainProofRowDTO[];
}

/** @deprecated Use ProductResourceRequirementDTO. */
export interface ProductFileResourceDTO extends Omit<ProductResourceRequirementDTO, "source"> {
  readonly source: ProductFileResourceSource;
  readonly handle?: string;
}

export interface ProductSelectableTargetDTO {
  readonly targetStageId: string;
  readonly targetStageName: string;
  readonly allowed: boolean;
  readonly selectorStageId?: string;
  readonly workStarted?: boolean;
  readonly stageSignalCount?: number;
  readonly currentExecutorWallet?: string;
  readonly currentExecutorLabel?: string;
  readonly previousExecutor?: string;
  readonly previousExecutorWallet?: string;
  readonly previousExecutorLabel?: string;
  readonly executorPatchMode?: ProductExecutorPatchMode;
  readonly executorPatchModes?: readonly ProductExecutorPatchRequirementDTO[];
  readonly approvalSourceId?: string;
  readonly approvalSignalId?: string;
  readonly approvalSignalLabel?: string;
  readonly approvalSignal?: ProductExecutorPatchApprovalSignalDTO;
  readonly priorAuthorityLabel?: string;
  readonly futureAuthorityLabel?: string;
  readonly disabledReason?: string;
  readonly executorOverlay?: ProductExecutorOverlayDTO;
  readonly resourceRequirements?: readonly ProductResourceRequirementDTO[];
  readonly resourceOverlays?: readonly ProductResourceOverlayDTO[];
  /** @deprecated Use resourceRequirements. */
  readonly effectiveFileResources?: readonly ProductFileResourceDTO[];
}

export interface ParticipantAddOnManifestSelectOptionDTO {
  readonly value: string;
  readonly label: string;
  readonly disabled?: boolean;
}

export interface ParticipantAddOnManifestComponentDTO {
  readonly componentId: string;
  readonly componentKind: ParticipantAddOnManifestComponentKind;
  readonly inputId?: string;
  readonly label: string;
  readonly description?: string;
  readonly placeholder?: string;
  readonly required?: boolean;
  readonly defaultValue?: string;
  readonly options?: readonly ParticipantAddOnManifestSelectOptionDTO[];
}

export interface ParticipantAddOnManifestSectionDTO {
  readonly sectionId: string;
  readonly title: string;
  readonly summary?: string;
  readonly components: readonly ParticipantAddOnManifestComponentDTO[];
}

export interface ParticipantAddOnManifestPageDTO {
  readonly pageId: string;
  readonly title: string;
  readonly summary?: string;
  readonly sections: readonly ParticipantAddOnManifestSectionDTO[];
}

export interface ParticipantAddOnManifestActionDTO {
  readonly actionId: string;
  readonly actionKind: ParticipantAddOnManifestActionKind;
  readonly label: string;
  readonly primary?: boolean;
  readonly intent?: ParticipantAddOnManifestSignalIntent;
  readonly inputBindings: Readonly<Record<string, string>>;
}

export interface ParticipantAddOnManifestDTO {
  readonly schemaVersion: ParticipantAddOnManifestSchemaVersion;
  readonly manifestId: string;
  readonly roleSlotId: string;
  readonly addOnKind: ParticipantAddOnKind;
  readonly title: string;
  readonly summary: string;
  readonly stageBindings: readonly string[];
  readonly pages: readonly ParticipantAddOnManifestPageDTO[];
  readonly actions: readonly ParticipantAddOnManifestActionDTO[];
}

export interface ZhixuStageDTO {
  readonly stageId: string;
  readonly index: number;
  readonly name: string;
  readonly evidence: readonly string[];
  readonly ownerRole: string;
  readonly status: StageStatus;
  readonly updatedAt?: string;
  readonly stageKind?: ProductStageKind;
  readonly executorAssignment?: ProductStageExecutorAssignment;
  readonly staticExecutorRoleSlotId?: string;
  readonly selectedStageTargets?: readonly string[];
  readonly addOnKind?: ParticipantAddOnKind;
  readonly selectableTargets?: readonly ProductSelectableTargetDTO[];
  readonly executorPatchModes?: readonly ProductExecutorPatchRequirementDTO[];
  readonly executorOverlay?: ProductExecutorOverlayDTO;
  readonly resourceRequirements?: readonly ProductResourceRequirementDTO[];
  readonly resourceOverlays?: readonly ProductResourceOverlayDTO[];
  /** @deprecated Use resourceRequirements. */
  readonly effectiveFileResources?: readonly ProductFileResourceDTO[];
}

export interface RoleSlotDTO {
  readonly slotId: string;
  readonly title: string;
  readonly label: string;
  readonly duty: string;
  readonly evidence: readonly string[];
  readonly status: RoleSlotStatus;
  readonly tone: ProductTone;
  readonly required: boolean;
  readonly performanceSlotLabel?: string;
  readonly businessPersonaLabels?: readonly string[];
  readonly capabilityPlugins?: readonly SlotCapabilityPluginDTO[];
  readonly addOnManifest?: ParticipantAddOnManifestDTO;
}

export interface DockableZhixuModuleDTO {
  readonly moduleId: string;
  readonly title: string;
  readonly desc: string;
  readonly ports: readonly string[];
  readonly status: DockableModuleStatus;
}

export interface OrderPermissionTableEntryDTO {
  readonly permissionId: string;
  readonly roleSlotId: string;
  readonly stageId: string;
  readonly source: string;
  readonly signalName: string;
  readonly payloadPolicy: PermissionPayloadPolicy;
  readonly requiredEvidence: readonly string[];
}

export interface StoreProductCreateOrderTriggerDTO {
  readonly source: string;
  readonly signalName: string;
  readonly triggerHookId: string;
  readonly triggerStageId: string;
}

export interface ZhixuSummaryDTO {
  readonly zhixuId: string;
  readonly title: string;
  readonly subtitle: string;
  readonly reviewStatus: ReviewStatus;
  readonly reviewLabel: string;
  readonly riskLevel: string;
  readonly applicableBusiness: readonly string[];
  readonly excludedBusiness: readonly string[];
  readonly stageCount: number;
  readonly roleSlotCount: number;
  readonly supportedPaymentMethods: readonly string[];
  readonly maintainer: string;
  readonly updatedAt: string;
  readonly chainAttestation: ChainAttestationDTO;
}

export interface ZhixuDetailDTO extends ZhixuSummaryDTO {
  readonly roleSlots: readonly RoleSlotDTO[];
  readonly dockableModules: readonly DockableZhixuModuleDTO[];
  readonly stages: readonly ZhixuStageDTO[];
  readonly orderPermissionTable: readonly OrderPermissionTableEntryDTO[];
  readonly createOrderTrigger?: StoreProductCreateOrderTriggerDTO;
  readonly proofRows: readonly ChainProofRowDTO[];
  readonly createOrderHint: string;
}

export interface ParticipantDTO {
  readonly participantId: string;
  readonly role: string;
  readonly duty: string;
  readonly evidence: readonly string[];
  readonly status: ParticipantStatus;
  readonly tone: ProductTone;
  readonly addOnKind?: ParticipantAddOnKind;
}

export interface ProductOrderDTO {
  readonly orderId: string;
  readonly stateMachineAddress?: string;
  readonly deploymentId?: string;
  readonly zhixuId: string;
  readonly title: string;
  readonly status: OrderStatus;
  readonly statusLabel: string;
  readonly totalAmount: MoneyDTO;
  readonly fundingStatus: string;
  readonly currentStageId: string;
  readonly currentStageName: string;
  readonly currentTaskId?: string;
  readonly currentTaskTitle: string;
  readonly currentTaskSummary: string;
  readonly stages: readonly ZhixuStageDTO[];
  readonly executorOverlays?: Readonly<Record<string, ProductExecutorOverlayDTO>>;
  readonly resourceOverlays?: Readonly<Record<string, readonly ProductResourceOverlayDTO[]>>;
  readonly resourceRequirements?: Readonly<Record<string, readonly ProductResourceRequirementDTO[]>>;
  /** @deprecated Use resourceRequirements. */
  readonly effectiveFileResources?: Readonly<Record<string, readonly ProductFileResourceDTO[]>>;
  readonly selectableTargets?: readonly ProductSelectableTargetDTO[];
  readonly participants: readonly ParticipantDTO[];
  readonly recentEvents: readonly ProductTimelineEventDTO[];
  readonly dockedZhixuRuntimes?: readonly ProductDockedZhixuRuntimeDTO[];
  readonly proofRows: readonly ChainProofRowDTO[];
}

export interface ProductTimelineEventDTO {
  readonly eventId: string;
  readonly text: string;
  readonly time: string;
  readonly executorOverlay?: ProductExecutorOverlayDTO;
  readonly resourceOverlays?: readonly ProductResourceOverlayDTO[];
  readonly proofRows?: readonly ChainProofRowDTO[];
}

export interface ProductTaskDTO {
  readonly taskId: string;
  readonly orderId: string;
  readonly stateMachineAddress?: string;
  readonly deploymentId?: string;
  readonly orderTitle: string;
  readonly zhixuId: string;
  readonly title: string;
  readonly subtitle: string;
  readonly assigneeRole: string;
  readonly assigneeWallet?: string;
  readonly supplierSubjectId?: string;
  readonly supplierTrustStatus?: ChainAttestationStatus;
  readonly stageId: string;
  readonly stageName: string;
  readonly deadline: string;
  readonly fundingImpact: string;
  readonly requiredEvidence: readonly string[];
  readonly status: TaskStatus;
  readonly addOnKind?: ParticipantAddOnKind;
  readonly selectableTargets?: readonly ProductSelectableTargetDTO[];
  readonly executorPatchModes?: readonly ProductExecutorPatchRequirementDTO[];
  readonly executorOverlay?: ProductExecutorOverlayDTO;
  readonly resourceRequirements?: readonly ProductResourceRequirementDTO[];
  readonly resourceOverlays?: readonly ProductResourceOverlayDTO[];
  /** @deprecated Use resourceRequirements. */
  readonly effectiveFileResources?: readonly ProductFileResourceDTO[];
  readonly fulfillmentKind?: FulfillmentPluginKind;
  readonly performanceSlotId?: string;
  readonly performanceSlotLabel?: string;
  readonly businessPersonaLabels?: readonly string[];
  readonly capabilityPlugin?: ProductTaskCapabilityPluginDTO;
  readonly addOnManifest?: ParticipantAddOnManifestDTO;
  readonly primaryActionLabel?: string;
  readonly requiredInputs?: readonly FulfillmentRequiredInputDTO[];
  readonly blockedReason?: string;
  readonly settlementPreview?: SettlementPreviewDTO;
  readonly participantRoleLabel?: string;
  readonly participantWallet?: string;
  readonly canSubmit?: boolean;
  readonly proofSummary?: ParticipantProofSummaryDTO;
  readonly responsibilityStatements: readonly ProductResponsibilityStatementDTO[];
  readonly proofRows: readonly ChainProofRowDTO[];
}

export interface SlotCapabilityPluginDTO {
  readonly pluginKind: FulfillmentPluginKind;
  readonly source: CapabilityPluginSource;
  readonly stageIds: readonly string[];
  readonly title?: string;
  readonly summary?: string;
  readonly primaryActionLabel?: string;
  readonly requiredEvidence: readonly string[];
  readonly inputPolicy?: readonly FulfillmentRequiredInputDTO[];
}

export type StoreProductSchemaValidationSeverity = "error" | "warning";

export type StoreProductSchemaValidationIssueCode =
  | "plan_identity_mismatch"
  | "missing_role_slot"
  | "permission_role_slot_not_found"
  | "unsupported_system_permission"
  | "stage_not_covered"
  | "slot_missing_capability_plugin"
  | "capability_plugin_not_explicit"
  | "addon_manifest_invalid"
  | "addon_manifest_stage_not_bound"
  | "addon_manifest_input_not_found"
  | "stage_executor_selection_invalid"
  | "duplicate_stage_capability";

export interface StoreProductSchemaValidationIssueDTO {
  readonly code: StoreProductSchemaValidationIssueCode;
  readonly severity: StoreProductSchemaValidationSeverity;
  readonly message: string;
  readonly path?: string;
  readonly stageId?: string;
  readonly roleSlotId?: string;
}

export interface StoreProductSchemaValidationDTO {
  readonly ok: boolean;
  readonly status: StoreCapabilityReviewStatus;
  readonly issues: readonly StoreProductSchemaValidationIssueDTO[];
  readonly checkedAt?: string;
}

export interface StoreProductSchemaSelectorBindingDTO {
  readonly selectorStageIdentifier: string;
  readonly targetStageIdentifier: string;
  readonly selectorStageId?: string;
  readonly targetStageId?: string;
  readonly bindingHash?: string;
}

export interface StoreProductSchemaDTO {
  readonly schemaVersion: StoreProductSchemaVersion;
  readonly version: number;
  readonly zhixuId?: string;
  readonly title: string;
  readonly maintainer: string;
  readonly planId: string;
  readonly planHash: string;
  readonly artifactHash: string;
  readonly onchainHookPlanArtifact?: unknown;
  readonly createOrderTrigger?: StoreProductCreateOrderTriggerDTO;
  readonly roleSlots: readonly RoleSlotDTO[];
  readonly orderPermissionTable: readonly OrderPermissionTableEntryDTO[];
  readonly capabilityPlugins: readonly SlotCapabilityPluginDTO[];
  readonly businessPersonaLabels: readonly string[];
  readonly stages: readonly ZhixuStageDTO[];
  readonly selectorBindings?: readonly StoreProductSchemaSelectorBindingDTO[];
  readonly schemaHash: string;
  readonly validation: StoreProductSchemaValidationDTO;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly attestedAt?: string;
  readonly deprecatedAt?: string;
}

export interface ProductTaskCapabilityPluginDTO {
  readonly pluginKind: FulfillmentPluginKind;
  readonly source: CapabilityPluginSource;
  readonly roleSlotId?: string;
  readonly title?: string;
  readonly summary?: string;
  readonly primaryActionLabel?: string;
  readonly requiredEvidence: readonly string[];
  readonly inputPolicy?: readonly FulfillmentRequiredInputDTO[];
}

export interface ProductResponsibilityStatementDTO {
  readonly title: string;
  readonly desc: string;
}

export interface FulfillmentRequiredInputDTO {
  readonly inputId: string;
  readonly label: string;
  readonly inputType: "evidence" | "text" | "confirmation" | "payment_placeholder";
  readonly required: boolean;
  readonly completed: boolean;
}

export interface SettlementPreviewDTO {
  readonly label: string;
  readonly statusLabel: string;
  readonly adapterStatus: "placeholder" | "planned" | "unavailable";
  readonly disclaimer: string;
}

export interface ParticipantProofSummaryDTO {
  readonly label: string;
  readonly txHash?: string;
  readonly blockNumber?: string;
  readonly payloadHash?: string;
}

export interface ProductParticipantProfileDTO {
  readonly participantId: string;
  readonly displayName: string;
  readonly walletAddress?: string;
  readonly roleLabels: readonly string[];
  readonly source: "wallet" | "mock" | "anonymous";
}

export interface ProductCatalogDTO {
  readonly zhixus: readonly ZhixuDetailDTO[];
  readonly orders: readonly ProductOrderDTO[];
  readonly tasks: readonly ProductTaskDTO[];
}

export interface StoreZhixuConsoleDTO {
  readonly zhixuId: string;
  readonly title: string;
  readonly subtitle: string;
  readonly maintainer: string;
  readonly versionLabel: string;
  readonly lifecycleStatus: StoreZhixuLifecycleStatus;
  readonly lifecycleLabel: string;
  readonly reviewStatus: ReviewStatus;
  readonly reviewLabel: string;
  readonly riskLevel: string;
  readonly stageCount: number;
  readonly roleSlotCount: number;
  readonly orderCount: number;
  readonly openTaskCount: number;
  readonly supplierCount: number;
  readonly planId: string;
  readonly planHash: string;
  readonly artifactHash?: string;
  readonly chainAttestation: ChainAttestationDTO;
  readonly nextAction: string;
  readonly updatedAt: string;
  readonly proofRows: readonly ChainProofRowDTO[];
}

export interface StoreProjectionStatusDTO {
  readonly syncStatus: StoreProjectionSyncStatus;
  readonly label: string;
  readonly isCatchingUp: boolean;
  readonly updatedAt?: string;
  readonly latestIndexedBlock?: string;
  readonly finalizedBlock?: string;
  readonly confirmationDepth?: number;
  readonly eventCount?: number;
  readonly rebuildStatus?: string;
  readonly degradedReason?: string;
}

export interface StoreSearchResponseDTO {
  readonly sourceOfTruth: "contracts-and-chain-events";
  readonly query: string;
  readonly normalizedQuery: string;
  readonly resultCount: number;
  readonly results: readonly StoreSearchResultDTO[];
  readonly projectionStatus?: StoreProjectionStatusDTO;
}

export interface StoreSearchResultDTO {
  readonly resultType: StoreSearchResultType;
  readonly id: string;
  readonly title: string;
  readonly subtitle: string;
  readonly badgeLabel: string;
  readonly statusLabel: string;
  readonly matchedFields: readonly string[];
  readonly primaryHref: string;
  readonly sourceOfTruth: StoreSearchSourceOfTruth;
  readonly proofHint?: string;
  readonly updatedAt?: string;
}

export interface StoreOrderCandidateDTO {
  readonly orderId: string;
  readonly title: string;
  readonly statusLabel: string;
  readonly zhixuId: string;
  readonly primaryHref: string;
  readonly sourceOfTruth: "chain";
  readonly chainId?: number;
  readonly stateMachineAddress?: string;
  readonly deploymentId?: string;
  readonly proofHint?: string;
  readonly updatedAt?: string;
}

export interface StoreOrderCandidatesResponseDTO {
  readonly sourceOfTruth: "contracts-and-chain-events";
  readonly orderId: string;
  readonly normalizedOrderId: string;
  readonly candidateCount: number;
  readonly candidates: readonly StoreOrderCandidateDTO[];
  readonly projectionStatus?: StoreProjectionStatusDTO;
}

export interface StoreZhixuStageDTO {
  readonly stageId: string;
  readonly title: string;
  readonly description: string;
  readonly responsibleRoleSlotId?: string;
  readonly expectedSupplierTags: readonly string[];
  readonly triggerSummary: string;
  readonly outputSummary: string;
  readonly statusInSampleOrder?: string;
}

export interface StoreRoleSlotCapabilityPluginDTO {
  readonly pluginKind: FulfillmentPluginKind;
  readonly source: CapabilityPluginSource;
  readonly stageIds: readonly string[];
  readonly title: string;
  readonly summary: string;
  readonly primaryActionLabel?: string;
  readonly requiredEvidence: readonly string[];
}

export interface StoreRoleSlotDTO {
  readonly roleSlotId: string;
  readonly title: string;
  readonly description: string;
  readonly required: boolean;
  readonly expectedEvidence: readonly string[];
  readonly statusLabel: string;
  readonly performanceSlotLabel: string;
  readonly businessPersonaLabels: readonly string[];
  readonly capabilityPlugins: readonly StoreRoleSlotCapabilityPluginDTO[];
  readonly addOnManifest?: ParticipantAddOnManifestDTO;
  readonly capabilityReviewStatus: StoreCapabilityReviewStatus;
  readonly capabilityReviewLabel: string;
}

export interface StoreSupplierRequirementDTO {
  readonly requirementId: string;
  readonly title: string;
  readonly description: string;
  readonly requiredTags: readonly string[];
  readonly trustExpectation: string;
}

export interface StoreProofRowDTO extends ChainProofRowDTO {
  readonly kind?: "lifecycle" | "plan" | "attestation" | "projection" | "usage";
  readonly copyable?: boolean;
}

export interface StoreProofSectionDTO {
  readonly sectionId: string;
  readonly title: string;
  readonly summary: string;
  readonly sourceOfTruth: StoreSearchSourceOfTruth;
  readonly collapsedByDefault: boolean;
  readonly rows: readonly StoreProofRowDTO[];
}

export interface StoreZhixuActionDTO {
  readonly actionId: "create_order" | "broadcast_attestation" | "submit_review" | "observe_orders" | "view_proof" | "repair_metadata";
  readonly label: string;
  readonly enabled: boolean;
  readonly primary: boolean;
  readonly href?: string;
  readonly reason?: string;
}

export interface StoreZhixuDetailDTO extends StoreZhixuConsoleDTO {
  readonly description: string;
  readonly lifecycleReason: string;
  readonly usageGuidance: string;
  readonly stages: readonly StoreZhixuStageDTO[];
  readonly roleSlots: readonly StoreRoleSlotDTO[];
  readonly supplierRequirements: readonly StoreSupplierRequirementDTO[];
  readonly riskTags: readonly string[];
  readonly versionHistory: readonly StoreZhixuVersionSummaryDTO[];
  readonly proofSections: readonly StoreProofSectionDTO[];
  readonly allowedActions: readonly StoreZhixuActionDTO[];
}

export interface StoreSupplierDTO {
  readonly supplierId: string;
  readonly supplierSubjectId: string;
  readonly displayName: string;
  readonly wallet?: string;
  readonly notificationProfile?: unknown;
  readonly notificationProfileHash?: string;
  readonly notificationUpdatedAt?: string;
  readonly trustStatus: StoreSupplierTrustStatus;
  readonly trustLabel: string;
  readonly capabilityTags: readonly string[];
  readonly supportedRoleSlotIds: readonly string[];
  readonly supportedStageIds: readonly string[];
  readonly registryAddresses: readonly string[];
  readonly recentOrderCount: number;
  readonly openTaskCount: number;
  readonly reviewStatus: StoreSupplierReviewStatus;
  readonly metadataURI?: string;
  readonly proofRows: readonly ChainProofRowDTO[];
  readonly nextAction: string;
  readonly updatedAt: string;
}

export interface StoreConsoleSummaryDTO {
  readonly totalZhixus: number;
  readonly activeZhixus: number;
  readonly needsReview: number;
  readonly revokedZhixus: number;
  readonly runningOrders: number;
  readonly openTasks: number;
  readonly trustedSuppliers: number;
}

export type StoreIndexerStatus = "ready" | "syncing" | "rebuilding" | "degraded";
export type StoreOrderReplayStatus = "replayable" | "syncing" | "rebuild_required" | "not_found";
export type StoreZhixuVersionStatus = "candidate" | "active" | "deprecated" | "revoked" | "rejected";

export interface StoreRuntimeSummaryDTO {
  readonly sourceOfTruth: "contracts-and-chain-events";
  readonly activeZhixuCount: number;
  readonly runningOrderCount: number;
  readonly openTaskCount: number;
  readonly blockedOrderCount: number;
  readonly revokedPlanOrderCount: number;
  readonly revokedSupplierOpenTaskCount: number;
  readonly indexerStatus: StoreIndexerStatus;
  readonly updatedAt: string;
}

export interface StoreOrderStageObservationDTO {
  readonly stageId: string;
  readonly index: number;
  readonly name: string;
  readonly status: StageStatus;
  readonly updatedAt?: string;
  readonly addOnKind?: ParticipantAddOnKind;
  readonly selectableTargets?: readonly ProductSelectableTargetDTO[];
  readonly executorPatchModes?: readonly ProductExecutorPatchRequirementDTO[];
  readonly executorOverlay?: ProductExecutorOverlayDTO;
  readonly resourceRequirements?: readonly ProductResourceRequirementDTO[];
  readonly resourceOverlays?: readonly ProductResourceOverlayDTO[];
  /** @deprecated Use resourceRequirements. */
  readonly effectiveFileResources?: readonly ProductFileResourceDTO[];
  readonly proofRows: readonly ChainProofRowDTO[];
}

export interface StoreOrderSupplierObservationDTO {
  readonly supplierSubjectId?: string;
  readonly wallet?: string;
  readonly trustStatus: ChainAttestationStatus;
  readonly metadataURI?: string;
  readonly revokedReasonURI?: string;
}

export interface StoreOrderObservationDTO {
  readonly orderId: string;
  readonly zhixuId: string;
  readonly title: string;
  readonly status: string;
  readonly planId: string;
  readonly planHash: string;
  readonly lifecycleWarnings: readonly string[];
  readonly stages: readonly StoreOrderStageObservationDTO[];
  readonly executorOverlays?: Readonly<Record<string, ProductExecutorOverlayDTO>>;
  readonly resourceOverlays?: Readonly<Record<string, readonly ProductResourceOverlayDTO[]>>;
  readonly resourceRequirements?: Readonly<Record<string, readonly ProductResourceRequirementDTO[]>>;
  /** @deprecated Use resourceRequirements. */
  readonly effectiveFileResources?: Readonly<Record<string, readonly ProductFileResourceDTO[]>>;
  readonly selectableTargets?: readonly ProductSelectableTargetDTO[];
  readonly tasks: readonly ProductTaskDTO[];
  readonly dockedZhixuRuntimes?: readonly ProductDockedZhixuRuntimeDTO[];
  readonly suppliers: readonly StoreOrderSupplierObservationDTO[];
  readonly timeline: readonly ProductTimelineEventDTO[];
  readonly proofRows: readonly ChainProofRowDTO[];
  readonly replayStatus: StoreOrderReplayStatus;
}

export interface StoreOrderAuditSummaryDTO {
  readonly sourceOfTruth: "contracts-and-chain-events";
  readonly orderId: string;
  readonly zhixuId: string;
  readonly title: string;
  readonly status: string;
  readonly planId: string;
  readonly planHash: string;
  readonly lifecycleWarnings: readonly string[];
  readonly stageSummary: readonly string[];
  readonly taskSummary: readonly string[];
  readonly supplierSummary: readonly string[];
  readonly timelineSummary: readonly ProductTimelineEventDTO[];
  readonly proofRows: readonly ChainProofRowDTO[];
  readonly redactionNotice: string;
  readonly generatedAt: string;
}

export interface StoreZhixuVersionSummaryDTO {
  readonly versionId: string;
  readonly zhixuId: string;
  readonly seriesId: string;
  readonly versionLabel: string;
  readonly status: StoreZhixuVersionStatus;
  readonly planId: string;
  readonly planHash: string;
  readonly artifactHash?: string;
  readonly attestationStatus: ChainAttestationStatus;
  readonly orderCount: number;
  readonly createdAt: string;
  readonly cutoverAt?: string;
  readonly cutoverReason?: string;
}

export interface StoreZhixuConsoleMetrics {
  readonly orderCount?: number;
  readonly openTaskCount?: number;
  readonly supplierCount?: number;
  readonly versionLabel?: string;
  readonly lifecycleStatus?: StoreZhixuLifecycleStatus;
  readonly nextAction?: string;
  readonly updatedAt?: string;
}

export interface StoreZhixuDetailOptions {
  readonly description?: string;
  readonly lifecycleReason?: string;
  readonly usageGuidance?: string;
  readonly riskTags?: readonly string[];
  readonly versionHistory?: readonly StoreZhixuVersionSummaryDTO[];
  readonly proofSections?: readonly StoreProofSectionDTO[];
  readonly allowedActions?: readonly StoreZhixuActionDTO[];
}

export function toStoreZhixuConsoleDTO(
  zhixu: ZhixuSummaryDTO,
  metrics: StoreZhixuConsoleMetrics = {}
): StoreZhixuConsoleDTO {
  const lifecycleStatus = metrics.lifecycleStatus ?? lifecycleStatusForZhixu(zhixu);
  const planId = zhixu.chainAttestation.planId;
  const planHash = zhixu.chainAttestation.planHash;
  return {
    zhixuId: zhixu.zhixuId,
    title: zhixu.title,
    subtitle: zhixu.subtitle,
    maintainer: zhixu.maintainer,
    versionLabel: metrics.versionLabel ?? "当前版本",
    lifecycleStatus,
    lifecycleLabel: lifecycleLabel(lifecycleStatus),
    reviewStatus: zhixu.reviewStatus,
    reviewLabel: zhixu.reviewLabel,
    riskLevel: zhixu.riskLevel,
    stageCount: zhixu.stageCount,
    roleSlotCount: zhixu.roleSlotCount,
    orderCount: metrics.orderCount ?? 0,
    openTaskCount: metrics.openTaskCount ?? 0,
    supplierCount: metrics.supplierCount ?? 0,
    planId,
    planHash,
    ...(zhixu.chainAttestation.artifactHash ? { artifactHash: zhixu.chainAttestation.artifactHash } : {}),
    chainAttestation: zhixu.chainAttestation,
    nextAction: metrics.nextAction ?? nextActionForLifecycle(lifecycleStatus),
    updatedAt: metrics.updatedAt ?? zhixu.updatedAt,
    proofRows: [
      { label: "秩序编号", value: zhixu.zhixuId },
      { label: "生命周期", value: lifecycleLabel(lifecycleStatus) },
      { label: "背书状态", value: zhixu.chainAttestation.label },
      { label: "Plan ID", value: planId },
      { label: "Plan Hash", value: planHash }
    ]
  };
}

export function storeConsoleSummary(zhixus: readonly StoreZhixuConsoleDTO[]): StoreConsoleSummaryDTO {
  return {
    totalZhixus: zhixus.length,
    activeZhixus: zhixus.filter((zhixu) => zhixu.lifecycleStatus === "active").length,
    needsReview: zhixus.filter((zhixu) =>
      zhixu.lifecycleStatus === "draft" ||
      zhixu.lifecycleStatus === "compiled" ||
      zhixu.lifecycleStatus === "submitted_for_review" ||
      zhixu.lifecycleStatus === "approved_for_broadcast"
    ).length,
    revokedZhixus: zhixus.filter((zhixu) => zhixu.lifecycleStatus === "revoked").length,
    runningOrders: zhixus.reduce((sum, zhixu) => sum + zhixu.orderCount, 0),
    openTasks: zhixus.reduce((sum, zhixu) => sum + zhixu.openTaskCount, 0),
    trustedSuppliers: Math.max(0, ...zhixus.map((zhixu) => zhixu.supplierCount))
  };
}

export function toStoreZhixuDetailDTO(
  row: StoreZhixuConsoleDTO,
  zhixu: ZhixuDetailDTO,
  options: StoreZhixuDetailOptions = {}
): StoreZhixuDetailDTO {
  return {
    ...row,
    description: options.description ?? zhixu.subtitle,
    lifecycleReason: options.lifecycleReason ?? lifecycleReasonForStoreZhixu(row),
    usageGuidance: options.usageGuidance ?? usageGuidanceForStoreZhixu(row, zhixu),
    stages: zhixu.stages.map((stage) => storeStageFromZhixuStage(stage, zhixu)),
    roleSlots: zhixu.roleSlots.map(storeRoleSlotFromZhixuSlot),
    supplierRequirements: zhixu.roleSlots
      .filter((slot) => slot.required)
      .map((slot) => ({
        requirementId: `role:${slot.slotId}`,
        title: `${slot.title}供应能力`,
        description: slot.duty,
        requiredTags: [slot.label, ...slot.evidence],
        trustExpectation: "需要订单级授权；正式供应商可由官方信任域背书。"
      })),
    riskTags: options.riskTags ?? defaultRiskTags(zhixu),
    versionHistory: options.versionHistory ?? [versionSummaryFromStoreRow(row)],
    proofSections: options.proofSections ?? defaultProofSections(row),
    allowedActions: options.allowedActions ?? allowedActionsForStoreZhixu(row)
  };
}

export function lifecycleStatusForZhixu(
  zhixu: Pick<ZhixuSummaryDTO, "reviewStatus" | "chainAttestation">
): StoreZhixuLifecycleStatus {
  if (zhixu.chainAttestation.status === "revoked" || zhixu.reviewStatus === "revoked") {
    return "revoked";
  }
  if (zhixu.reviewStatus === "rejected") {
    return "rejected";
  }
  if (zhixu.chainAttestation.status === "attested" && zhixu.reviewStatus === "approved") {
    return "active";
  }
  if (zhixu.chainAttestation.status === "attested") {
    return "attested";
  }
  if (zhixu.reviewStatus === "approved" || zhixu.reviewStatus === "restricted") {
    return "approved_for_broadcast";
  }
  return "draft";
}

export function projectionStatusLabel(status: StoreProjectionSyncStatus): string {
  switch (status) {
    case "indexed":
      return "投影已同步";
    case "syncing":
      return "投影同步中";
    case "stale":
      return "投影可能滞后";
    case "rebuilding":
      return "投影重建中";
    case "degraded":
      return "投影降级可用";
  }
}

export function lifecycleLabel(status: StoreZhixuLifecycleStatus): string {
  switch (status) {
    case "draft":
      return "设计草稿";
    case "compiled":
      return "已编译";
    case "submitted_for_review":
      return "待审核";
    case "approved_for_broadcast":
      return "待链上背书";
    case "attested":
      return "已链上背书";
    case "active":
      return "可创建订单";
    case "deprecated":
      return "旧版本保留";
    case "rejected":
      return "审核拒绝";
    case "revoked":
      return "已撤销";
  }
}

function nextActionForLifecycle(status: StoreZhixuLifecycleStatus): string {
  switch (status) {
    case "draft":
      return "补全秩序定义并提交治理审核";
    case "compiled":
      return "提交审核并生成公开说明";
    case "submitted_for_review":
      return "等待治理方审核";
    case "approved_for_broadcast":
      return "广播 Trust Registry 背书交易";
    case "attested":
      return "设置为可用并观察订单创建";
    case "active":
      return "持续观察订单、待办和供应商状态";
    case "deprecated":
      return "保留历史订单回放，推荐使用新版本";
    case "rejected":
      return "修改风险项后重新提交审核";
    case "revoked":
      return "禁止新订单，保留历史证明链";
  }
}

function lifecycleReasonForStoreZhixu(row: StoreZhixuConsoleDTO): string {
  switch (row.lifecycleStatus) {
    case "active":
      return "该秩序已通过 Store 审核，并且官方信任域链上背书有效，可用于创建新订单。";
    case "attested":
      return "该秩序已有链上背书，但 Store 仍需要完成可用性确认后再推荐创建新订单。";
    case "approved_for_broadcast":
      return "Store 审核已通过，但尚未写入官方信任域链上背书；审核状态不能替代链上背书。";
    case "submitted_for_review":
      return "该秩序已提交治理审核，当前还不能作为官方可用版本创建新订单。";
    case "compiled":
      return "该秩序已经编译出候选产物，还需要提交治理审核和链上背书。";
    case "draft":
      return "该秩序仍是展示或设计草稿，当前没有可依赖的官方链上背书。";
    case "deprecated":
      return "该版本仅用于历史订单回放和审计，不建议继续创建新订单。";
    case "rejected":
      return "该秩序未通过 Store 审核，需要修正风险项后重新提交。";
    case "revoked":
      return "该秩序的审核状态或链上背书已撤销，不能创建新订单，但历史证明仍可查看。";
  }
}

function usageGuidanceForStoreZhixu(row: StoreZhixuConsoleDTO, zhixu: ZhixuDetailDTO): string {
  switch (row.lifecycleStatus) {
    case "active":
      return zhixu.createOrderHint;
    case "revoked":
      return "不要用该版本创建新订单；仅用于查看历史订单、版本记录和撤销证明。";
    case "rejected":
      return "先处理审核拒绝原因，再重新编译、审核和背书。";
    case "approved_for_broadcast":
      return "下一步是广播官方信任域背书交易；在背书确认前不要把它作为链上官方版本对外承诺。";
    default:
      return "用于 Store 内部评估、补充说明和验证证明；正式使用前需要完成审核与链上背书。";
  }
}

function storeStageFromZhixuStage(stage: ZhixuStageDTO, zhixu: ZhixuDetailDTO): StoreZhixuStageDTO {
  const permission = zhixu.orderPermissionTable.find((entry) =>
    entry.stageId === stage.stageId
  );
  const roleSlot = zhixu.roleSlots.find((slot) =>
    slot.slotId === permission?.roleSlotId || slot.title === stage.ownerRole || slot.label === stage.ownerRole
  );
  const evidenceText = stage.evidence.length > 0 ? `需要 ${stage.evidence.join("、")}。` : "按业务约定提交确认。";
  return {
    stageId: stage.stageId,
    title: stage.name,
    description: `${stage.ownerRole}负责该阶段。${evidenceText}`,
    ...(roleSlot ? { responsibleRoleSlotId: roleSlot.slotId } : {}),
    expectedSupplierTags: roleSlot ? [roleSlot.label, ...roleSlot.evidence] : stage.evidence,
    triggerSummary: stage.index === 1 ? "订单创建后进入该阶段。" : "前序阶段完成后进入该阶段。",
    outputSummary: stage.evidence.length > 0 ? `输出 ${stage.evidence.join("、")} 等证明。` : "输出阶段确认结果。",
    statusInSampleOrder: stage.status
  };
}

function roleSlotStatusLabel(status: RoleSlotStatus): string {
  switch (status) {
    case "required":
      return "必需";
    case "connected":
      return "已连接";
    case "optional":
      return "可选";
  }
}

function storeRoleSlotFromZhixuSlot(slot: RoleSlotDTO): StoreRoleSlotDTO {
  const capabilityPlugins: readonly StoreRoleSlotCapabilityPluginDTO[] = (slot.capabilityPlugins ?? []).map((plugin) => ({
    pluginKind: plugin.pluginKind,
    source: plugin.source,
    stageIds: plugin.stageIds,
    title: plugin.title ?? capabilityPluginKindLabel(plugin.pluginKind),
    summary: plugin.summary ?? "该能力由 Store 操作员审核，用于说明该履约插槽可执行的阶段动作。",
    ...(plugin.primaryActionLabel ? { primaryActionLabel: plugin.primaryActionLabel } : {}),
    requiredEvidence: plugin.requiredEvidence
  }));
  const capabilityReviewStatus = capabilityReviewStatusForPlugins(capabilityPlugins);
  return {
    roleSlotId: slot.slotId,
    title: slot.title,
    description: slot.duty,
    required: slot.required,
    expectedEvidence: slot.evidence,
    statusLabel: roleSlotStatusLabel(slot.status),
    performanceSlotLabel: slot.performanceSlotLabel ?? slot.title,
    businessPersonaLabels: slot.businessPersonaLabels && slot.businessPersonaLabels.length > 0
      ? slot.businessPersonaLabels
      : [slot.label],
    capabilityPlugins,
    ...(slot.addOnManifest ? { addOnManifest: slot.addOnManifest } : {}),
    capabilityReviewStatus,
    capabilityReviewLabel: capabilityReviewLabel(capabilityReviewStatus)
  };
}

function capabilityReviewStatusForPlugins(
  capabilityPlugins: readonly StoreRoleSlotCapabilityPluginDTO[]
): StoreCapabilityReviewStatus {
  if (capabilityPlugins.length === 0 || capabilityPlugins.some((plugin) => plugin.source === "missing")) {
    return "missing";
  }
  if (capabilityPlugins.some((plugin) => plugin.source === "legacy_inferred")) {
    return "inferred";
  }
  return "explicit";
}

function capabilityReviewLabel(status: StoreCapabilityReviewStatus): string {
  switch (status) {
    case "explicit":
      return "显式配置";
    case "inferred":
      return "推断待确认";
    case "missing":
      return "缺少能力配置";
  }
}

function capabilityPluginKindLabel(kind: FulfillmentPluginKind): string {
  switch (kind) {
    case "payment_placeholder":
      return "资金动作占位";
    case "evidence_submission":
      return "提交履约凭证";
    case "delivery_update":
      return "更新交付状态";
    case "validation_confirm":
      return "确认验收结果";
    case "dispute_material":
      return "提交争议材料";
  }
}

function defaultRiskTags(zhixu: ZhixuDetailDTO): readonly string[] {
  return [...new Set([zhixu.riskLevel, ...zhixu.excludedBusiness].filter((tag) => tag.length > 0))];
}

function versionSummaryFromStoreRow(row: StoreZhixuConsoleDTO): StoreZhixuVersionSummaryDTO {
  return {
    versionId: `${row.zhixuId}:${row.planHash}`,
    zhixuId: row.zhixuId,
    seriesId: row.zhixuId,
    versionLabel: row.versionLabel,
    status: versionStatusFromLifecycle(row.lifecycleStatus),
    planId: row.planId,
    planHash: row.planHash,
    ...(row.artifactHash ? { artifactHash: row.artifactHash } : {}),
    attestationStatus: row.chainAttestation.status,
    orderCount: row.orderCount,
    createdAt: row.updatedAt,
    ...(row.chainAttestation.status === "revoked" ? { cutoverReason: "链上背书或 Store 审核已撤销" } : {})
  };
}

function versionStatusFromLifecycle(status: StoreZhixuLifecycleStatus): StoreZhixuVersionStatus {
  switch (status) {
    case "active":
    case "attested":
      return "active";
    case "deprecated":
      return "deprecated";
    case "rejected":
      return "rejected";
    case "revoked":
      return "revoked";
    case "draft":
    case "compiled":
    case "submitted_for_review":
    case "approved_for_broadcast":
      return "candidate";
  }
}

function defaultProofSections(row: StoreZhixuConsoleDTO): readonly StoreProofSectionDTO[] {
  const attestationRows: StoreProofRowDTO[] = [
    { label: "Plan ID", value: row.planId, kind: "plan", copyable: true },
    { label: "Plan Hash", value: row.planHash, kind: "plan", copyable: true },
    ...(row.artifactHash ? [{ label: "Artifact Hash", value: row.artifactHash, kind: "plan" as const, copyable: true }] : []),
    { label: "背书状态", value: row.chainAttestation.label, kind: "attestation" },
    ...(row.chainAttestation.txHash
      ? [{ label: "背书交易", value: row.chainAttestation.txHash, kind: "attestation" as const, copyable: true }]
      : []),
    ...(row.chainAttestation.blockNumber
      ? [{ label: "背书区块", value: row.chainAttestation.blockNumber, kind: "attestation" as const }]
      : []),
    ...(row.chainAttestation.status !== "not_found"
      ? [{ label: "链上事件", value: row.chainAttestation.status === "revoked" ? "PlanRevoked" : "PlanAttested", kind: "attestation" as const }]
      : [])
  ];

  return [
    {
      sectionId: "lifecycle",
      title: "生命周期证明",
      summary: row.lifecycleLabel,
      sourceOfTruth: row.chainAttestation.status === "not_found" ? "store-metadata" : "chain-and-store-metadata",
      collapsedByDefault: false,
      rows: row.proofRows.map((proofRow): StoreProofRowDTO => ({ ...proofRow, kind: proofKindForLabel(proofRow.label) }))
    },
    {
      sectionId: "chain-attestation",
      title: "链上背书证明",
      summary: row.chainAttestation.label,
      sourceOfTruth: row.chainAttestation.status === "not_found" ? "store-metadata" : "chain",
      collapsedByDefault: true,
      rows: attestationRows
    }
  ];
}

function proofKindForLabel(label: string): NonNullable<StoreProofRowDTO["kind"]> {
  if (label.includes("Plan")) {
    return "plan";
  }
  if (label.includes("背书")) {
    return "attestation";
  }
  return "lifecycle";
}

function allowedActionsForStoreZhixu(row: StoreZhixuConsoleDTO): readonly StoreZhixuActionDTO[] {
  const proofAction: StoreZhixuActionDTO = {
    actionId: "view_proof",
    label: "查看证明",
    enabled: true,
    primary: false,
    href: `/store/zhixus/${encodeURIComponent(row.zhixuId)}#proof`
  };
  switch (row.lifecycleStatus) {
    case "active":
      return [
        {
          actionId: "create_order",
          label: "创建订单",
          enabled: true,
          primary: true,
          href: `/product/orders/new?zhixuId=${encodeURIComponent(row.zhixuId)}`
        },
        {
          actionId: "observe_orders",
          label: "查看运行订单",
          enabled: true,
          primary: false,
          href: `/store/search?q=${encodeURIComponent(row.zhixuId)}&type=order`
        },
        proofAction
      ];
    case "approved_for_broadcast":
    case "attested":
      return [
        {
          actionId: "broadcast_attestation",
          label: row.lifecycleStatus === "attested" ? "确认可用性" : "广播背书",
          enabled: true,
          primary: true,
          reason: row.nextAction
        },
        proofAction
      ];
    case "draft":
    case "compiled":
    case "submitted_for_review":
      return [
        {
          actionId: "submit_review",
          label: "推进审核",
          enabled: true,
          primary: true,
          reason: row.nextAction
        },
        proofAction
      ];
    case "deprecated":
    case "rejected":
    case "revoked":
      return [proofAction];
  }
}

export function summarizeZhixu(zhixu: ZhixuDetailDTO): ZhixuSummaryDTO {
  const {
    roleSlots: _roleSlots,
    dockableModules: _dockableModules,
    stages: _stages,
    orderPermissionTable: _orderPermissionTable,
    proofRows: _proofRows,
    createOrderHint: _createOrderHint,
    ...summary
  } = zhixu;
  return summary;
}

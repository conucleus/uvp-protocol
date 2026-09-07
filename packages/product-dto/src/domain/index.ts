export type ProductTone = "ok" | "warn" | "info" | "neutral";

export type ReviewStatus =
  | "approved"
  | "restricted"
  | "rejected"
  | "revoked"
  | "unreviewed";
export type PlanPublicationStatus = "published" | "not_found";
export type StageStatus = "done" | "active" | "pending";
export type ParticipantStatus =
  | "joined"
  | "invited"
  | "pending_confirmation"
  | "assigned"
  | "not_started";
export type RoleSlotStatus = "required" | "connected" | "optional";
export type DockableModuleStatus = "connected" | "available" | "planned";
/** dock 接口开放的下单模式（PRD_100：{new, existing} 子集）。 */
export type ProductDockOrderMode = "new" | "existing";
export type OrderStatus = "registered";
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
export type ParticipantAddOnManifestSchemaVersion =
  "participant-addon-manifest.v1";
export type StageExecutorActionKind =
  | "submit_signal"
  | "stage_executor_patch"
  | "stage_resource_patch";
export type ParticipantAddOnManifestActionKind = StageExecutorActionKind;
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
export type ProductResourceRequirementSource =
  | "plan_default"
  | "resource_patch"
  | "participant_input";
export type ProductResourceType =
  | "document"
  | "image"
  | "metadata"
  | "uri"
  | "other";
export type ProductResourceVisibility = "public" | "protected" | "private";
export type ProductResourcePolicyPrincipalKind =
  | "wallet"
  | "role"
  | "stage"
  | "participant";
export type ProductResourceAccessState =
  | "available"
  | "locked"
  | "request_required"
  | "not_authorized"
  | "unknown";
export type ProductDockedZhixuRuntimeStatus =
  | "draft_map"
  | "linked_order_required"
  | "linked_order_registered"
  | "linked_order_active"
  | "signal_map_waiting"
  | "signal_map_satisfied"
  | "blocked"
  | "not_modeled";
export type CapabilityPluginSource = "explicit" | "inferred" | "missing";
export type StoreCapabilityReviewStatus = "explicit" | "inferred" | "missing";
export type StoreProductSchemaVersion = "store-product-schema.v1";
export type StoreSearchType = "all" | "zhixu" | "order" | "supplier";
export type StoreSearchResultType = "zhixu" | "order" | "supplier";
export type StoreSearchSourceOfTruth =
  | "chain"
  | "chain-and-store-metadata"
  | "store-metadata";
export type StoreProjectionSyncStatus =
  | "indexed"
  | "syncing"
  | "stale"
  | "rebuilding"
  | "degraded";
export type StoreZhixuLifecycleStatus =
  | "draft"
  | "compiled"
  | "submitted_for_review"
  | "approved_for_broadcast"
  | "active"
  | "deprecated"
  | "rejected"
  | "revoked";
export type StoreSupplierReviewStatus =
  | "draft"
  | "submitted"
  | "approved_for_broadcast"
  | "rejected"
  | "revoked";
export type StoreSupplierIdentityStatus = "active" | "revoked" | "not_found";

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
  "updatedAt",
] as const;

export const PARTICIPANT_ADDON_MANIFEST_V1_ACTION_KINDS = [
  "submit_signal",
  "stage_executor_patch",
  "stage_resource_patch",
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

export interface PlanPublicationDTO {
  readonly status: PlanPublicationStatus;
  readonly label: string;
  readonly stateMachineLabel: string;
  readonly planId: string;
  readonly planHash: string;
  readonly artifactHash?: string;
  readonly txHash?: string;
  readonly blockNumber?: string;
  readonly publisher?: string;
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

export interface DockableZhixuModulePortDTO {
  readonly portName: string;
  readonly label: string;
  /** input 端口的目标侧 hook 引用（`<task>.<stage>#<channel>`）。 */
  readonly hook?: string;
  /** output 端口的目标侧 canonical signal（`<source>::<task>.<stage>.<signal>`）。 */
  readonly signal?: string;
}

/**
 * 目标定义发布的具名 dock 接口（uvp.dockInterfaceArtifact.v2 的展示面）。
 * 接口名/端口名遵循协议命名规则（`^[a-z][a-z0-9_]{0,31}$`）。
 */
export interface DockableZhixuModuleDTO {
  readonly interfaceName: string;
  /** 接口开放的下单模式（{new, existing} 非空子集）。 */
  readonly orderModes: readonly ProductDockOrderMode[];
  readonly title: string;
  readonly desc: string;
  readonly inputs: readonly DockableZhixuModulePortDTO[];
  readonly outputs: readonly DockableZhixuModulePortDTO[];
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
  readonly submitterRoleSlotId?: string;
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
  readonly planPublication: PlanPublicationDTO;
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
  readonly executorOverlays?: Readonly<
    Record<string, ProductExecutorOverlayDTO>
  >;
  readonly resourceOverlays?: Readonly<
    Record<string, readonly ProductResourceOverlayDTO[]>
  >;
  readonly resourceRequirements?: Readonly<
    Record<string, readonly ProductResourceRequirementDTO[]>
  >;
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

export type TaskEvidenceInputKind = "file" | "text" | "date";

/**
 * Structured, publisher-owned evidence requirement for one task slot.
 * Sole source of task evidence rules: when the publisher carries no spec the
 * task has no evidence slots (field-only confirmation or offline submission
 * by business convention), so consumers must not synthesize generic slots.
 * Store surfaces must stay generic and must never hardcode business-specific
 * labels, document types, or file formats.
 */
export interface TaskEvidenceSpecDTO {
  /** Stable identifier; becomes the evidence documentType when uploaded. */
  readonly key: string;
  /** Publisher-provided display label. */
  readonly label: string;
  /** How the slot is collected. Defaults to "file". */
  readonly inputKind?: TaskEvidenceInputKind;
  /** Accepted file types (MIME types or extensions) for file inputs. */
  readonly accept?: readonly string[];
  /** Whether the slot must be satisfied. Defaults to true. */
  readonly required?: boolean;
  /** Optional publisher-provided explanation shown next to the slot. */
  readonly description?: string;
}

export type TaskEvidenceSpecIssueCode =
  | "empty_spec"
  | "empty_key"
  | "empty_label"
  | "duplicate_key"
  | "invalid_input_kind"
  | "accept_on_non_file_input"
  | "invalid_accept_entry";

export interface TaskEvidenceSpecIssueDTO {
  readonly code: TaskEvidenceSpecIssueCode;
  readonly message: string;
  readonly index?: number;
}

/**
 * Validates an optional task evidence spec. An absent spec is valid; an
 * empty array is not (either declare nothing or declare slots). Validation
 * is structural only — it must never encode business-specific expectations.
 */
export function validateTaskEvidenceSpec(
  spec: readonly TaskEvidenceSpecDTO[] | undefined | null,
): readonly TaskEvidenceSpecIssueDTO[] {
  if (spec === undefined || spec === null) {
    return [];
  }
  if (!Array.isArray(spec)) {
    return [
      {
        code: "empty_spec",
        message: "evidenceSpec must be an array when present",
      },
    ];
  }
  if (spec.length === 0) {
    return [
      {
        code: "empty_spec",
        message: "evidenceSpec must declare at least one slot when present",
      },
    ];
  }
  const issues: TaskEvidenceSpecIssueDTO[] = [];
  const seenKeys = new Set<string>();
  spec.forEach((entry, index) => {
    const key = typeof entry?.key === "string" ? entry.key.trim() : "";
    if (key.length === 0) {
      issues.push({
        code: "empty_key",
        message: `evidenceSpec[${index}].key must be a non-empty string`,
        index,
      });
    } else if (seenKeys.has(key)) {
      issues.push({
        code: "duplicate_key",
        message: `evidenceSpec[${index}].key "${key}" is duplicated`,
        index,
      });
    }
    if (key.length > 0) {
      seenKeys.add(key);
    }
    const label = typeof entry?.label === "string" ? entry.label.trim() : "";
    if (label.length === 0) {
      issues.push({
        code: "empty_label",
        message: `evidenceSpec[${index}].label must be a non-empty string`,
        index,
      });
    }
    const inputKind = entry?.inputKind ?? "file";
    if (inputKind !== "file" && inputKind !== "text" && inputKind !== "date") {
      issues.push({
        code: "invalid_input_kind",
        message: `evidenceSpec[${index}].inputKind must be "file", "text", or "date"`,
        index,
      });
    }
    const accept = entry?.accept;
    if (accept !== undefined) {
      if (!Array.isArray(accept)) {
        issues.push({
          code: "invalid_accept_entry",
          message: `evidenceSpec[${index}].accept must be an array of strings`,
          index,
        });
      } else {
        if (inputKind !== "file") {
          issues.push({
            code: "accept_on_non_file_input",
            message: `evidenceSpec[${index}].accept only applies to file inputs`,
            index,
          });
        }
        accept.forEach((acceptEntry: unknown, acceptIndex: number) => {
          if (typeof acceptEntry !== "string" || acceptEntry.trim().length === 0) {
            issues.push({
              code: "invalid_accept_entry",
              message: `evidenceSpec[${index}].accept[${acceptIndex}] must be a non-empty string`,
              index,
            });
          }
        });
      }
    }
  });
  return issues;
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
  readonly stageId: string;
  readonly stageName: string;
  readonly deadline: string;
  readonly fundingImpact: string;
  /**
   * Optional publisher-configured structured evidence requirements; the sole
   * authority for task evidence slots. When absent the task has no evidence
   * slots — consumers must not synthesize generic slots nor reject.
   */
  readonly evidenceSpec?: readonly TaskEvidenceSpecDTO[];
  readonly status: TaskStatus;
  readonly addOnKind?: ParticipantAddOnKind;
  readonly selectableTargets?: readonly ProductSelectableTargetDTO[];
  readonly executorPatchModes?: readonly ProductExecutorPatchRequirementDTO[];
  readonly executorOverlay?: ProductExecutorOverlayDTO;
  readonly resourceRequirements?: readonly ProductResourceRequirementDTO[];
  readonly resourceOverlays?: readonly ProductResourceOverlayDTO[];
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
  | "create_order_trigger_invalid"
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
  readonly publishedAt?: string;
  readonly deprecatedAt?: string;
}

export interface ProductTaskCapabilityPluginDTO {
  readonly pluginKind: FulfillmentPluginKind;
  readonly source: CapabilityPluginSource;
  readonly roleSlotId?: string;
  readonly title?: string;
  readonly summary?: string;
  readonly primaryActionLabel?: string;
  readonly inputPolicy?: readonly FulfillmentRequiredInputDTO[];
}

export interface ProductResponsibilityStatementDTO {
  readonly title: string;
  readonly desc: string;
}

export interface FulfillmentRequiredInputDTO {
  readonly inputId: string;
  readonly label: string;
  readonly inputType:
    | "evidence"
    | "text"
    | "confirmation"
    | "payment_placeholder";
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
  /**
   * Explicit availability marker for the metric fields above and for
   * versionLabel: "unknown" means they were not supplied by the caller and
   * must be displayed as unknown, never read as real observations.
   */
  readonly metricsStatus: StoreConsoleMetricsStatus;
  readonly planId: string;
  readonly planHash: string;
  readonly artifactHash?: string;
  readonly planPublication: PlanPublicationDTO;
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
  readonly selectionGuidance: string;
}

export interface StoreProofRowDTO extends ChainProofRowDTO {
  readonly kind?: "lifecycle" | "plan" | "projection" | "usage";
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
  readonly actionId:
    | "create_order"
    | "publish_plan"
    | "submit_review"
    | "observe_orders"
    | "view_proof"
    | "repair_metadata";
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
  readonly identityStatus: StoreSupplierIdentityStatus;
  readonly identityLabel: string;
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
  readonly runningOrders: number;
  readonly openTasks: number;
  readonly registeredSuppliers: number;
}

export type StoreIndexerStatus =
  | "ready"
  | "syncing"
  | "rebuilding"
  | "degraded";
export type StoreOrderReplayStatus =
  | "replayable"
  | "syncing"
  | "rebuild_required"
  | "not_found";
export type StoreZhixuVersionStatus =
  | "candidate"
  | "active"
  | "deprecated"
  | "rejected";

export interface StoreRuntimeSummaryDTO {
  readonly sourceOfTruth: "contracts-and-chain-events";
  readonly activeZhixuCount: number;
  readonly runningOrderCount: number;
  readonly openTaskCount: number;
  readonly blockedOrderCount: number;
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
  readonly proofRows: readonly ChainProofRowDTO[];
}

export interface StoreOrderSupplierObservationDTO {
  readonly supplierSubjectId?: string;
  readonly wallet?: string;
  readonly identityStatus: StoreSupplierIdentityStatus;
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
  readonly executorOverlays?: Readonly<
    Record<string, ProductExecutorOverlayDTO>
  >;
  readonly resourceOverlays?: Readonly<
    Record<string, readonly ProductResourceOverlayDTO[]>
  >;
  readonly resourceRequirements?: Readonly<
    Record<string, readonly ProductResourceRequirementDTO[]>
  >;
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
  readonly publicationStatus: PlanPublicationStatus;
  readonly orderCount: number;
  readonly createdAt: string;
  readonly cutoverAt?: string;
  readonly cutoverReason?: string;
}

export type StoreConsoleMetricsStatus = "observed" | "unknown";

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
  metrics: StoreZhixuConsoleMetrics = {},
): StoreZhixuConsoleDTO {
  const lifecycleStatus =
    metrics.lifecycleStatus ?? lifecycleStatusForZhixu(zhixu);
  const planId = zhixu.planPublication.planId;
  const planHash = zhixu.planPublication.planHash;
  // Metrics are either fully observed or explicitly unknown: a partial
  // supply must not silently substitute zeros / "当前版本" for the missing
  // fields while claiming the rest are real observations.
  const metricsStatus: StoreConsoleMetricsStatus =
    metrics.orderCount !== undefined &&
    metrics.openTaskCount !== undefined &&
    metrics.supplierCount !== undefined
      ? "observed"
      : "unknown";
  return {
    zhixuId: zhixu.zhixuId,
    title: zhixu.title,
    subtitle: zhixu.subtitle,
    maintainer: zhixu.maintainer,
    versionLabel: metrics.versionLabel ?? "当前版本",
    metricsStatus,
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
    ...(zhixu.planPublication.artifactHash
      ? { artifactHash: zhixu.planPublication.artifactHash }
      : {}),
    planPublication: zhixu.planPublication,
    nextAction: metrics.nextAction ?? nextActionForLifecycle(lifecycleStatus),
    updatedAt: metrics.updatedAt ?? zhixu.updatedAt,
    proofRows: [
      { label: "秩序编号", value: zhixu.zhixuId },
      { label: "生命周期", value: lifecycleLabel(lifecycleStatus) },
      { label: "Plan 发布", value: "以 StateMachine commit/finalize 事件为准" },
      { label: "Plan ID", value: planId },
      { label: "Plan Hash", value: planHash },
    ],
  };
}

export function storeConsoleSummary(
  zhixus: readonly StoreZhixuConsoleDTO[],
): StoreConsoleSummaryDTO {
  return {
    totalZhixus: zhixus.length,
    activeZhixus: zhixus.filter((zhixu) => zhixu.lifecycleStatus === "active")
      .length,
    needsReview: zhixus.filter(
      (zhixu) =>
        zhixu.lifecycleStatus === "draft" ||
        zhixu.lifecycleStatus === "compiled" ||
        zhixu.lifecycleStatus === "submitted_for_review" ||
        zhixu.lifecycleStatus === "approved_for_broadcast",
    ).length,
    runningOrders: zhixus.reduce((sum, zhixu) => sum + zhixu.orderCount, 0),
    openTasks: zhixus.reduce((sum, zhixu) => sum + zhixu.openTaskCount, 0),
    registeredSuppliers: Math.max(
      0,
      ...zhixus.map((zhixu) => zhixu.supplierCount),
    ),
  };
}

export function toStoreZhixuDetailDTO(
  row: StoreZhixuConsoleDTO,
  zhixu: ZhixuDetailDTO,
  options: StoreZhixuDetailOptions = {},
): StoreZhixuDetailDTO {
  return {
    ...row,
    description: options.description ?? zhixu.subtitle,
    lifecycleReason:
      options.lifecycleReason ?? lifecycleReasonForStoreZhixu(row),
    usageGuidance:
      options.usageGuidance ?? usageGuidanceForStoreZhixu(row, zhixu),
    stages: zhixu.stages.map((stage) => storeStageFromZhixuStage(stage, zhixu)),
    roleSlots: zhixu.roleSlots.map(storeRoleSlotFromZhixuSlot),
    supplierRequirements: zhixu.roleSlots
      .filter((slot) => slot.required)
      .map((slot) => ({
        requirementId: `role:${slot.slotId}`,
        title: `${slot.title}供应能力`,
        description: slot.duty,
        requiredTags: [slot.label, ...slot.evidence],
        selectionGuidance: "需要订单级授权；身份目录只解析主体与钱包，能力与匹配由 Store 自行判断。",
      })),
    riskTags: options.riskTags ?? defaultRiskTags(zhixu),
    versionHistory: options.versionHistory ?? [versionSummaryFromStoreRow(row)],
    proofSections: options.proofSections ?? defaultProofSections(row),
    allowedActions: options.allowedActions ?? allowedActionsForStoreZhixu(row),
  };
}

export function lifecycleStatusForZhixu(
  zhixu: Pick<ZhixuSummaryDTO, "reviewStatus" | "planPublication">,
): StoreZhixuLifecycleStatus {
  if (zhixu.reviewStatus === "revoked") {
    return "revoked";
  }
  if (zhixu.reviewStatus === "rejected") {
    return "rejected";
  }
  if (zhixu.reviewStatus === "approved" || zhixu.reviewStatus === "restricted") {
    return zhixu.planPublication.status === "published"
      ? "active"
      : "approved_for_broadcast";
  }
  return "draft";
}

export function projectionStatusLabel(
  status: StoreProjectionSyncStatus,
): string {
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
      return "待发布签名";
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
      return "由 publisher 签名提交并 finalize Plan";
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
      return "该秩序已通过 Store 审核；链上是否可创建订单以 StateMachine 中的 finalized Plan 为准。";
    case "approved_for_broadcast":
      return "Store 审核已通过，下一步是取得 publisher 签名并提交、冻结 Plan。";
    case "submitted_for_review":
      return "该秩序已提交治理审核，当前还不能作为官方可用版本创建新订单。";
    case "compiled":
      return "该秩序已经编译出候选产物，还需要审核并取得 publisher 签名。";
    case "draft":
      return "该秩序仍是展示或设计草稿，尚未形成可验证的 finalized Plan。";
    case "deprecated":
      return "该版本仅用于历史订单回放和审计，不建议继续创建新订单。";
    case "rejected":
      return "该秩序未通过 Store 审核，需要修正风险项后重新提交。";
    case "revoked":
      return "该秩序的 Store 审核状态已撤销，不再由本 Store 推荐；历史证明仍可查看。";
  }
}

function usageGuidanceForStoreZhixu(
  row: StoreZhixuConsoleDTO,
  zhixu: ZhixuDetailDTO,
): string {
  switch (row.lifecycleStatus) {
    case "active":
      return zhixu.createOrderHint;
    case "revoked":
      return "不要用该版本创建新订单；仅用于查看历史订单、版本记录和撤销证明。";
    case "rejected":
      return "先处理审核拒绝原因，再重新编译、审核和签名发布。";
    case "approved_for_broadcast":
      return "下一步是由 publisher 签名提交 Plan，并一次 finalize metadata。";
    default:
      return "用于 Store 内部评估、补充说明和验证证明；正式使用前需要形成 finalized Plan。";
  }
}

function storeStageFromZhixuStage(
  stage: ZhixuStageDTO,
  zhixu: ZhixuDetailDTO,
): StoreZhixuStageDTO {
  const permission = zhixu.orderPermissionTable.find(
    (entry) => entry.stageId === stage.stageId,
  );
  const roleSlot = zhixu.roleSlots.find(
    (slot) =>
      slot.slotId === permission?.roleSlotId ||
      slot.title === stage.ownerRole ||
      slot.label === stage.ownerRole,
  );
  const evidenceText =
    stage.evidence.length > 0
      ? `需要 ${stage.evidence.join("、")}。`
      : "按业务约定提交确认。";
  return {
    stageId: stage.stageId,
    title: stage.name,
    description: `${stage.ownerRole}负责该阶段。${evidenceText}`,
    ...(roleSlot ? { responsibleRoleSlotId: roleSlot.slotId } : {}),
    expectedSupplierTags: roleSlot
      ? [roleSlot.label, ...roleSlot.evidence]
      : stage.evidence,
    triggerSummary:
      stage.index === 1
        ? "订单创建后进入该阶段。"
        : "前序阶段完成后进入该阶段。",
    outputSummary:
      stage.evidence.length > 0
        ? `输出 ${stage.evidence.join("、")} 等证明。`
        : "输出阶段确认结果。",
    statusInSampleOrder: stage.status,
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
  const capabilityPlugins: readonly StoreRoleSlotCapabilityPluginDTO[] = (
    slot.capabilityPlugins ?? []
  ).map((plugin) => ({
    pluginKind: plugin.pluginKind,
    source: plugin.source,
    stageIds: plugin.stageIds,
    title: plugin.title ?? capabilityPluginKindLabel(plugin.pluginKind),
    summary:
      plugin.summary ??
      "该能力由 Store 操作员审核，用于说明该履约插槽可执行的阶段动作。",
    ...(plugin.primaryActionLabel
      ? { primaryActionLabel: plugin.primaryActionLabel }
      : {}),
    requiredEvidence: plugin.requiredEvidence,
  }));
  const capabilityReviewStatus =
    capabilityReviewStatusForPlugins(capabilityPlugins);
  return {
    roleSlotId: slot.slotId,
    title: slot.title,
    description: slot.duty,
    required: slot.required,
    expectedEvidence: slot.evidence,
    statusLabel: roleSlotStatusLabel(slot.status),
    performanceSlotLabel: slot.performanceSlotLabel ?? slot.title,
    businessPersonaLabels:
      slot.businessPersonaLabels && slot.businessPersonaLabels.length > 0
        ? slot.businessPersonaLabels
        : [slot.label],
    capabilityPlugins,
    ...(slot.addOnManifest ? { addOnManifest: slot.addOnManifest } : {}),
    capabilityReviewStatus,
    capabilityReviewLabel: capabilityReviewLabel(capabilityReviewStatus),
  };
}

function capabilityReviewStatusForPlugins(
  capabilityPlugins: readonly StoreRoleSlotCapabilityPluginDTO[],
): StoreCapabilityReviewStatus {
  if (
    capabilityPlugins.length === 0 ||
    capabilityPlugins.some((plugin) => plugin.source === "missing")
  ) {
    return "missing";
  }
  if (capabilityPlugins.some((plugin) => plugin.source === "inferred")) {
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
  return [
    ...new Set(
      [zhixu.riskLevel, ...zhixu.excludedBusiness].filter(
        (tag) => tag.length > 0,
      ),
    ),
  ];
}

function versionSummaryFromStoreRow(
  row: StoreZhixuConsoleDTO,
): StoreZhixuVersionSummaryDTO {
  return {
    versionId: `${row.zhixuId}:${row.planHash}`,
    zhixuId: row.zhixuId,
    seriesId: row.zhixuId,
    versionLabel: row.versionLabel,
    status: versionStatusFromLifecycle(row.lifecycleStatus),
    planId: row.planId,
    planHash: row.planHash,
    ...(row.artifactHash ? { artifactHash: row.artifactHash } : {}),
    publicationStatus: row.planPublication.status,
    orderCount: row.orderCount,
    createdAt: row.updatedAt,
    ...(row.reviewStatus === "revoked" ? { cutoverReason: "Store 审核已撤销" } : {}),
  };
}

function versionStatusFromLifecycle(
  status: StoreZhixuLifecycleStatus,
): StoreZhixuVersionStatus {
  switch (status) {
    case "active":
      return "active";
    case "deprecated":
      return "deprecated";
    case "rejected":
      return "rejected";
    case "revoked":
      return "deprecated";
    case "draft":
    case "compiled":
    case "submitted_for_review":
    case "approved_for_broadcast":
      return "candidate";
  }
}

function defaultProofSections(
  row: StoreZhixuConsoleDTO,
): readonly StoreProofSectionDTO[] {
  const planRows: StoreProofRowDTO[] = [
    { label: "Plan ID", value: row.planId, kind: "plan", copyable: true },
    { label: "Plan Hash", value: row.planHash, kind: "plan", copyable: true },
    ...(row.artifactHash
      ? [
          {
            label: "Artifact Hash",
            value: row.artifactHash,
            kind: "plan" as const,
            copyable: true,
          },
        ]
      : []),
  ];

  return [
    {
      sectionId: "lifecycle",
      title: "生命周期证明",
      summary: row.lifecycleLabel,
      sourceOfTruth:
        row.planPublication.status === "not_found"
          ? "store-metadata"
          : "chain-and-store-metadata",
      collapsedByDefault: false,
      rows: row.proofRows.map(
        (proofRow): StoreProofRowDTO => ({
          ...proofRow,
          kind: proofKindForLabel(proofRow.label),
        }),
      ),
    },
    {
      sectionId: "plan-publication",
      title: "Plan 发布信息",
      summary: "Plan 可用性以 StateMachine commit/finalize 事件为准",
      sourceOfTruth: "chain-and-store-metadata",
      collapsedByDefault: true,
      rows: planRows,
    },
  ];
}

function proofKindForLabel(
  label: string,
): NonNullable<StoreProofRowDTO["kind"]> {
  if (label.includes("Plan")) {
    return "plan";
  }
  return "lifecycle";
}

function allowedActionsForStoreZhixu(
  row: StoreZhixuConsoleDTO,
): readonly StoreZhixuActionDTO[] {
  const proofAction: StoreZhixuActionDTO = {
    actionId: "view_proof",
    label: "查看证明",
    enabled: true,
    primary: false,
    href: `/store/zhixus/${encodeURIComponent(row.zhixuId)}#proof`,
  };
  switch (row.lifecycleStatus) {
    case "active":
      return [
        {
          actionId: "create_order",
          label: "创建订单",
          enabled: true,
          primary: true,
          href: `/product/orders/new?zhixuId=${encodeURIComponent(row.zhixuId)}`,
        },
        {
          actionId: "observe_orders",
          label: "查看运行订单",
          enabled: true,
          primary: false,
          href: `/store/search?q=${encodeURIComponent(row.zhixuId)}&type=order`,
        },
        proofAction,
      ];
    case "approved_for_broadcast":
      return [
        {
          actionId: "publish_plan",
          label: "签名发布 Plan",
          enabled: true,
          primary: true,
          reason: row.nextAction,
        },
        proofAction,
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
          reason: row.nextAction,
        },
        proofAction,
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

import {
  decodeEventLog,
  encodeAbiParameters,
  encodeFunctionData,
  getAddress,
  isAddress,
  isHex,
  keccak256,
  parseAbi,
  parseAbiParameters,
  recoverTypedDataAddress,
  stringToBytes,
  stringToHex,
  type Address,
  type Hex,
} from "viem";
import { encodeTypedDataFields } from "./order-book.js";
import {
  SUPPLIER_BINDING_KIND_CANDIDATE,
  SUPPLIER_BINDING_KIND_DEFAULT,
  type SupplierBindingKind,
} from "@uvp-eth/compiler/browser";
import { signalCapabilityProofFor } from "./capabilities-root.js";
import type {
  SignalCapabilityTableEntry,
  SignalCapabilityTableEntryInput,
  StageSelectorBindingTableEntry,
} from "./capabilities-root.js";

export const STATE_MACHINE_ABI = [
  ...parseAbi([
  "event OwnershipTransferred(address indexed previousOwner,address indexed newOwner)",
  "event StateMachineModuleSet(bytes32 indexed moduleId,address indexed previousModule,address indexed newModule)",
  "event StateMachineModulesFrozen(bytes32 indexed moduleSetHash)",
  "event HookReady(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed hookId,bytes32 stageId,bytes32 hookName)",
  "event HookStatusChanged(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed hookId,uint8 previousStatus,uint8 newStatus,uint64 dueAt)",
  "event TimerPoked(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed hookId,uint64 dueAt)",
  "event SignalSubmitted(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,address relayer,bytes32 factStageId)",
  "event PlanCommitted(bytes32 indexed planId,bytes32 indexed planHash,address indexed publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,uint256 hookCount,bytes32 supplierBindingsRoot)",
  "event PlanFinalized(bytes32 indexed planId,bytes32 indexed planHash,bytes32 capabilitiesRoot)",
  "event PlanRegistered(bytes32 indexed planId,bytes32 planHash,uint256 hookCount)",
  "event PlanPublisherRecorded(bytes32 indexed planId,address indexed publisher)",
  "event OrderRegistered(bytes32 indexed orderId,bytes32 indexed planId)",
  "event OrderMaterialized(bytes32 indexed orderId,bytes32 indexed planId,bytes32 indexed stageId)",
  "event OrderRelayerRecorded(bytes32 indexed planId,bytes32 orderId,address indexed relayer)",
  "event StageMaterialized(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed stageId,bytes32 triggerHookId,bytes32 sourceId,bytes32 signalId)",
  "event OrderTriggered(bytes32 indexed orderId,bytes32 indexed planId,bytes32 indexed triggerStageId,bytes32 triggerHookId,bytes32 sourceId,bytes32 signalId,address submitter)",
  "event StageSupplierAssigned(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed targetStageId,bytes32 supplierId,uint256 patchNonce)",
  "function owner() view returns (address)",
  "function stagePatchModule() view returns (address)",
  "function derivedSignalModule() view returns (address)",
  "function planMetadataModule() view returns (address)",
  "function fileResourceModule() view returns (address)",
  "function identityRegistry() view returns (address)",
  "function modulesFrozen() view returns (bool)",
  "function moduleSetHash() view returns (bytes32)",
  "function transferOwnership(address newOwner)",
  "function setStagePatchModule(address moduleAddress)",
  "function setDerivedSignalModule(address moduleAddress)",
  "function setPlanMetadataModule(address moduleAddress)",
  "function setFileResourceModule(address moduleAddress)",
  "function setIdentityRegistry(address moduleAddress)",
  "function freezeModules()",
  "function commitPlan((address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 supplierBindingsRoot,uint256 deadline) commit,(bytes32 hookId,bytes32 stageId,bytes32 hookName,uint8 flags,(uint8 op,bytes32 sourceId,bytes32 signalId,uint16 arity,uint64 delaySeconds)[] instructions,bytes32[] dependencyKeys)[] hooks,(bytes32 stageId,bytes32 supplierId,uint8 kind)[] bindings,bytes signature) returns (bytes32 planId)",
  "function finalizePlan(bytes32 planId)",
  "function planRuntimeHash(bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 supplierBindingsRoot) pure returns (bytes32)",
  "function planIdFor(address publisher,bytes32 runtimePlanHash) pure returns (bytes32)",
  "function stageHasOrderTriggerHook(bytes32 planId,bytes32 stageId) view returns (bool)",
  "function submitSignal((bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof) attribution,bytes32 targetStageId,(string key,bytes payload)[] files,address submitter,uint256 deadline) submission,bytes signature) returns (bytes32 orderId,bool inserted)",
  "function submitDerivedSignalFromModule(bytes32 planId,bytes32 orderId,bytes32 fromPlanId,bytes32 fromOrderId,bytes32 stageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter) returns (bool inserted)",
  "function planHookFlags(bytes32 planId,bytes32 hookId) view returns (uint8)",
  "function planHookStageId(bytes32 planId,bytes32 hookId) view returns (bytes32)",
  "function activateStageSupplierFromModule(bytes32 planId,bytes32 orderId,bytes32 targetStageId,bytes32 supplierId,uint256 patchNonce)",
  "function stageSignalState(bytes32 planId,bytes32 orderId,bytes32 stageId) view returns (uint256 count,address lastSubmitter,uint64 lastAt,bool ambiguous)",
  "function planSupplierBindingsRoot(bytes32 planId) view returns (bytes32)",
  "function planStageDefaultSupplier(bytes32 planId,bytes32 stageId) view returns (bytes32)",
  "function planStageHasDynamicSupplier(bytes32 planId,bytes32 stageId) view returns (bool)",
  "function planStageIsCandidate(bytes32 planId,bytes32 stageId) view returns (bool)",
  "function isAuthorizedFileWriter(bytes32 planId,bytes32 orderId,bytes32 targetStageId,address account) view returns (bool)",
  "function isPlanStage(bytes32 planId,bytes32 stageId) view returns (bool)",
  "function effectiveStageSupplier(bytes32 planId,bytes32 orderId,bytes32 stageId) view returns (bytes32)",
  "function effectiveStageAccount(bytes32 planId,bytes32 orderId,bytes32 stageId) view returns (address)",
  "function isEffectiveStageAccount(bytes32 planId,bytes32 orderId,bytes32 stageId,address account) view returns (bool)",
  "function stageSupplierAssignment(bytes32 planId,bytes32 orderId,bytes32 targetStageId) view returns (bytes32 supplierId,uint256 patchNonce)",
  "function SIGNAL_TARGET_CURRENT_ORDER() view returns (uint8)",
  "function DERIVED_SIGNAL_MODULE_ID() view returns (bytes32)",
  "function FILE_RESOURCE_MODULE_ID() view returns (bytes32)",
  "function HOOK_FLAG_ADMISSION() view returns (uint8)",
  "function HOOK_FLAG_DYNAMIC_EXECUTOR() view returns (uint8)",
  "function HOOK_FLAG_EMIT_READY() view returns (uint8)",
  "function HOOK_FLAG_ORDER_TRIGGER_MINT() view returns (uint8)",
  "function MAX_SUPPLIER_BINDINGS() view returns (uint256)",
  "function MAX_HOOK_DELAY_SECONDS() view returns (uint64)",
  "function MAX_PLAN_DEPENDENCIES() view returns (uint256)",
  "function PLAN_METADATA_MODULE_ID() view returns (bytes32)",
  "function STAGE_PATCH_MODULE_ID() view returns (bytes32)",
  "function IDENTITY_REGISTRY_MODULE_ID() view returns (bytes32)",
  "function sourceSignalCount(bytes32 planId,bytes32 orderId,bytes32 sourceId) view returns (uint256)",
  "function lastSignalSubmitter(bytes32 planId,bytes32 orderId,bytes32 sourceId) view returns (address)",
  "function hasSourceSignal(bytes32 planId,bytes32 orderId,bytes32 sourceId) view returns (bool)",
  "function isSignalAdmissionSatisfied(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId) view returns (bool)",
  "function signalAdmissionVerdict(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId) view returns (uint8 verdict,uint64 dueAt)",
  "function DOMAIN_SEPARATOR() view returns (bytes32)",
  "function planExists(bytes32 planId) view returns (bool)",
  "function planCommitted(bytes32 planId) view returns (bool)",
  "function planFinalized(bytes32 planId) view returns (bool)",
  "function planHash(bytes32 planId) view returns (bytes32)",
  "function planPublisher(bytes32 planId) view returns (address)",
  "function orderRelayer(bytes32 planId,bytes32 orderId) view returns (address)",
  "function orderExists(bytes32 planId,bytes32 orderId) view returns (bool)",
  "function hasSignal(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId) view returns (bool)",
  "function getSignal(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId) view returns (bool exists,bytes32 payloadHash,bytes32 idempotencyKey,uint64 submittedAt,address submitter)",
  "function getHookStatus(bytes32 planId,bytes32 orderId,bytes32 hookId) view returns (uint8 status,uint64 dueAt,bool readyEmitted)",
  "function pokeTimer(bytes32 planId,bytes32 orderId,bytes32 hookId)",
  "function planHookDependsOn(bytes32 planId,bytes32 hookId,bytes32 sourceId,bytes32 signalId) view returns (bool)",
  ]),
] as const;

const APPLY_STAGE_SUPPLIER_PATCH_FOR_ABI_ENTRY = [
  {
    type: "function",
    name: "applyStageSupplierPatchFor",
    stateMutability: "nonpayable",
    inputs: [
      { name: "planId", type: "bytes32" },
      { name: "orderId", type: "bytes32" },
      {
        name: "patch",
        type: "tuple",
        components: [
          { name: "selectorStageId", type: "bytes32" },
          { name: "targetStageId", type: "bytes32" },
          { name: "supplierId", type: "bytes32" },
          { name: "previousSupplierId", type: "bytes32" },
          { name: "patchNonce", type: "uint256" },
        ],
      },
      { name: "selector", type: "address" },
      { name: "deadline", type: "uint256" },
      { name: "selectorSignature", type: "bytes" },
      { name: "previousSupplierSignature", type: "bytes" },
      {
        name: "bindingProof",
        type: "tuple",
        components: [
          { name: "selectorStageId", type: "bytes32" },
          { name: "proof", type: "bytes32[]" },
        ],
      },
      { name: "candidateProof", type: "bytes32[]" },
    ],
  },
] as const;

export const STAGE_PATCH_MODULE_ABI = [
  ...parseAbi([
  "event StageSupplierPatchApplied(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed selectorStageId,bytes32 targetStageId,address selector,bytes32 supplierId,bytes32 previousSupplierId,uint256 patchNonce)",
  "function applyStageSupplierPatch(bytes32 planId,bytes32 orderId,(bytes32 selectorStageId,bytes32 targetStageId,bytes32 supplierId,bytes32 previousSupplierId,uint256 patchNonce) patch,(bytes32 selectorStageId,bytes32[] proof) bindingProof,bytes32[] candidateProof)",
  "function stageSupplierPatchDigest(bytes32 planId,bytes32 orderId,(bytes32 selectorStageId,bytes32 targetStageId,bytes32 supplierId,bytes32 previousSupplierId,uint256 patchNonce) patch,address selector,uint256 deadline) view returns (bytes32)",
  ]),
  ...APPLY_STAGE_SUPPLIER_PATCH_FOR_ABI_ENTRY,
] as const;

export const DERIVED_SIGNAL_MODULE_ABI = parseAbi([
  "event DerivedSignalSubmitted(bytes32 indexed fromOrderId,bytes32 indexed targetOrderId,bytes32 indexed signalId,bytes32 fromPlanId,bytes32 targetPlanId,bytes32 fromStageId,bytes32 targetSourceId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint8 relation)",
  "struct DerivedSignalRequest {bytes32 fromPlanId;bytes32 fromOrderId;bytes32 fromStageId;bytes32 targetPlanId;bytes32 targetOrderId;bytes32 targetSourceId;bytes32 signalId;bytes32 payloadHash;bytes32 idempotencyKey}",
  "function submitDerivedSignal(DerivedSignalRequest request,address submitter,(bytes32[] fromCapabilityProof) proofs)",
  "function submitDerivedSignalFor(DerivedSignalRequest request,address submitter,uint256 deadline,bytes signature,(bytes32[] fromCapabilityProof) proofs)",
  "function derivedSignalDigest(DerivedSignalRequest request,address submitter,uint256 deadline) view returns (bytes32)",
]);

export const PLAN_METADATA_MODULE_ABI = parseAbi([
  "function stateMachine() view returns (address)",
  "function capabilitiesRoot(bytes32 planId) view returns (bytes32)",
  "function hasCapabilityVocabulary(bytes32 planId) view returns (bool)",
  "function verifySignalCapability(bytes32 planId,bytes32 stageId,bytes32 targetSourceId,bytes32 signalId,uint8 relation,bytes32[] proof) view returns (bool)",
  "function verifyStageSelectorBinding(bytes32 planId,bytes32 selectorStageId,bytes32 targetStageId,bytes32[] proof) view returns (bool)",
  "function verifyFileWriterBinding(bytes32 planId,bytes32 writerStageId,bytes32 targetStageId,bytes32[] proof) view returns (bool)",
]);

export const PRODUCT_SUBMIT_DOMAIN_NAME = "UVPStateMachine";
export const PRODUCT_SUBMIT_DOMAIN_VERSION = "1";
export const SIGNAL_SUBMISSION_PRIMARY_TYPE =
  "UVPStateMachineSignalSubmission";
export const PLAN_COMMIT_PRIMARY_TYPE = "UVPStateMachinePlanCommit";
export const DERIVED_SIGNAL_DOMAIN_NAME = "UVPDerivedSignalModule";
export const DERIVED_SIGNAL_DOMAIN_VERSION = "1";
export const DERIVED_SIGNAL_PRIMARY_TYPE = "UVPDerivedSignalModuleSignal";
export const STAGE_PATCH_MODULE_DOMAIN_NAME = "UVPStagePatchModule";
export const STAGE_PATCH_MODULE_DOMAIN_VERSION = "1";
export const STAGE_SUPPLIER_PATCH_PRIMARY_TYPE =
  "UVPStagePatchModuleStageSupplierPatch";
export const STAGE_SUPPLIER_PATCH_PAYLOAD_HASH_DOMAIN =
  "uvp:stage-supplier-patch-payload:v1";
import {
  HOOK_FLAG_DYNAMIC_EXECUTOR,
  HOOK_FLAG_EMIT_READY,
  HOOK_FLAG_ORDER_TRIGGER_MINT,
} from "./artifact-abis.js";
export {
  FILE_RESOURCE_MODULE_ABI,
  HOOK_FLAG_ADMISSION,
  HOOK_FLAG_DYNAMIC_EXECUTOR,
  HOOK_FLAG_EMIT_READY,
  HOOK_FLAG_ORDER_TRIGGER_MINT,
  SIGNAL_SUBMITTED_ABI,
  SIGNAL_SUBMITTED_TOPIC,
  IDENTITY_REGISTRY_ABI,
  IDENTITY_REGISTRY_CONTRACT_NAME,
  UVP_STATE_MACHINE_ARTIFACT_ABI,
} from "./artifact-abis.js";

export type OrderTriggerKind = "none" | "trigger";

export interface CompactHookFlagsInput {
  /** 出生语义：trigger=trigger 信号出生钩子（SIGNAL 指令）。 */
  readonly orderTriggerKind?: OrderTriggerKind | null;
  /** Ready 事件外发口径：dynamic 阶段必须携带，order-trigger hook 必须携带。 */
  readonly emitReady?: boolean;
  /** dock stage 标记：链上 stage patch 用它判断该 stage 允许 dock 执行者。 */
  /** dynamic 执行者阶段标记：无 plan binding，selector 运行期指派。 */
  readonly dynamicExecutor?: boolean;
}

// CompactHook.flags 位标志口径：1=ORDER_TRIGGER_MINT（trigger 出生钩子复用），
// 合约常量，trigger 缺 EMIT_READY 由 SilentOrderTriggerHook 拒绝。
export function buildCompactHookFlags(
  input: CompactHookFlagsInput = {},
): number {
  let flags = 0;
  if (input.orderTriggerKind === "trigger") {
    flags |= HOOK_FLAG_ORDER_TRIGGER_MINT;
  }
  if (input.emitReady) {
    flags |= HOOK_FLAG_EMIT_READY;
  }
  if (input.dynamicExecutor) {
    flags |= HOOK_FLAG_DYNAMIC_EXECUTOR;
  }
  return flags;
}

export interface ProductSubmitTypedDataField {
  readonly name: string;
  readonly type: string;
}

export const PLAN_COMMIT_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] =
  [
    { name: "publisher", type: "address" },
    { name: "hooksHash", type: "bytes32" },
    { name: "capabilitiesRoot", type: "bytes32" },
    { name: "supplierBindingsRoot", type: "bytes32" },
    { name: "deadline", type: "uint256" },
  ];

export const SIGNAL_SUBMISSION_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] =
  [
    { name: "planId", type: "bytes32" },
    { name: "orderId", type: "bytes32" },
    { name: "sourceId", type: "bytes32" },
    { name: "signalId", type: "bytes32" },
    { name: "payloadHash", type: "bytes32" },
    { name: "idempotencyKey", type: "bytes32" },
    { name: "targetStageId", type: "bytes32" },
    { name: "filesHash", type: "bytes32" },
    { name: "attributionHash", type: "bytes32" },
    { name: "submitter", type: "address" },
    { name: "deadline", type: "uint256" },
  ];

// 与 UVPDerivedSignalModule._DERIVED_SIGNAL_TYPEHASH 逐字段一致。
export const DERIVED_SIGNAL_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] =
  [
    { name: "fromPlanId", type: "bytes32" },
    { name: "fromOrderId", type: "bytes32" },
    { name: "fromStageId", type: "bytes32" },
    { name: "targetPlanId", type: "bytes32" },
    { name: "targetOrderId", type: "bytes32" },
    { name: "targetSourceId", type: "bytes32" },
    { name: "signalId", type: "bytes32" },
    { name: "payloadHash", type: "bytes32" },
    { name: "idempotencyKey", type: "bytes32" },
    { name: "submitter", type: "address" },
    { name: "deadline", type: "uint256" },
  ];

export const STAGE_SUPPLIER_PATCH_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] =
  [
    { name: "planId", type: "bytes32" },
    { name: "orderId", type: "bytes32" },
    { name: "selectorStageId", type: "bytes32" },
    { name: "targetStageId", type: "bytes32" },
    { name: "supplierId", type: "bytes32" },
    { name: "previousSupplierId", type: "bytes32" },
    { name: "patchNonce", type: "uint256" },
    { name: "selector", type: "address" },
    { name: "deadline", type: "uint256" },
  ];

export interface StageFile {
  readonly key: string;
  readonly payload: Hex | string;
}

export interface StageFileCallStruct {
  readonly key: string;
  readonly payload: Hex;
}

export const STAGE_FILES_LIMIT = 16;

export function stageFilesHash(files: readonly StageFile[]): Hex {
  const normalized = files.map((file, index) => ({
    key: file.key,
    payload: normalizeHex(file.payload, `files[${index}].payload`),
  }));
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters("(string key,bytes payload)[] files"),
      [normalized] as never,
    ),
  );
}

export interface SignalSubmissionTypedData {
  readonly domain: {
    readonly name: typeof PRODUCT_SUBMIT_DOMAIN_NAME;
    readonly version: typeof PRODUCT_SUBMIT_DOMAIN_VERSION;
    readonly chainId: number;
    readonly verifyingContract: Address;
  };
  readonly types: {
    readonly UVPStateMachineSignalSubmission: readonly ProductSubmitTypedDataField[];
  };
  readonly primaryType: typeof SIGNAL_SUBMISSION_PRIMARY_TYPE;
  readonly message: {
    readonly planId: Hex;
    readonly orderId: Hex;
    readonly sourceId: Hex;
    readonly signalId: Hex;
    readonly payloadHash: Hex;
    readonly idempotencyKey: Hex;
    readonly targetStageId: Hex;
    readonly filesHash: Hex;
    readonly attributionHash: Hex;
    readonly submitter: Address;
    readonly deadline: string;
  };
}

export type ProductSubmitTypedData = SignalSubmissionTypedData;

export interface SignalSubmissionPayload {
  readonly planId: Hex | string;
  readonly orderId?: Hex | string;
  readonly sourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly payloadHash: Hex | string;
  readonly idempotencyKey: Hex | string;
  readonly targetStageId?: Hex | string;
  readonly files?: readonly StageFile[];
  readonly attribution: SignalAttributionPayload;
  readonly submitter: Address | string;
  readonly deadline: bigint | number | string;
}

// PlanCommit 的能力承诺面是 capabilitiesRoot（空表归一化为
// EMPTY_CAPABILITIES_ROOT，见 capabilities-root.ts）：两表 Merkle 化形态下只有
// 树根进入发布者签名，表内容按使用方"重算叶 + 携 proof"验证。
export interface PlanCommitPayload {
  readonly publisher: Address | string;
  readonly hooksHash: Hex | string;
  readonly capabilitiesRoot: Hex | string;
  /** supplier 绑定树根（default/candidate 叶，空集归一化为 EMPTY_ROOT）。 */
  readonly supplierBindingsRoot: Hex | string;
  /** fileWriters 阶段名单的运行期哈希（不进入 capabilitiesRoot）。 */
  readonly deadline: bigint | number | string;
}

export interface PlanCommitTypedData {
  readonly domain: ProductSubmitTypedData["domain"];
  readonly types: {
    readonly UVPStateMachinePlanCommit: readonly ProductSubmitTypedDataField[];
  };
  readonly primaryType: typeof PLAN_COMMIT_PRIMARY_TYPE;
  readonly message: {
    readonly publisher: Address;
    readonly hooksHash: Hex;
    readonly capabilitiesRoot: Hex;
    readonly supplierBindingsRoot: Hex;
    readonly deadline: string;
  };
}

export interface StageSupplierBinding {
  readonly stageId: Hex | string;
  readonly supplierId: Hex | string;
  readonly kind: SupplierBindingKind;
}

export interface DerivedSignalPayload {
  readonly fromPlanId: Hex | string;
  readonly fromOrderId: Hex | string;
  readonly fromStageId: Hex | string;
  readonly targetPlanId: Hex | string;
  readonly targetOrderId: Hex | string;
  readonly targetSourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly payloadHash: Hex | string;
  readonly idempotencyKey: Hex | string;
  readonly submitter: Address | string;
  readonly deadline: bigint | number | string;
}

export interface DerivedSignalTypedData {
  readonly domain: {
    readonly name: typeof DERIVED_SIGNAL_DOMAIN_NAME;
    readonly version: typeof DERIVED_SIGNAL_DOMAIN_VERSION;
    readonly chainId: number;
    readonly verifyingContract: Address;
  };
  readonly types: {
    readonly UVPDerivedSignalModuleSignal: readonly ProductSubmitTypedDataField[];
  };
  readonly primaryType: typeof DERIVED_SIGNAL_PRIMARY_TYPE;
  readonly message: {
    readonly fromPlanId: Hex;
    readonly fromOrderId: Hex;
    readonly fromStageId: Hex;
    readonly targetPlanId: Hex;
    readonly targetOrderId: Hex;
    readonly targetSourceId: Hex;
    readonly signalId: Hex;
    readonly payloadHash: Hex;
    readonly idempotencyKey: Hex;
    readonly submitter: Address;
    readonly deadline: string;
  };
}

export interface StageSupplierPatchPayload {
  readonly selectorStageId: Hex | string;
  readonly targetStageId: Hex | string;
  readonly supplierId: Hex | string;
  readonly previousSupplierId: Hex | string;
  readonly patchNonce: bigint | number | string;
}

export type StageSupplierPatchCallPatch = StageSupplierPatchPayload;

export interface StageSupplierPatchTypedData {
  readonly domain: {
    readonly name: typeof STAGE_PATCH_MODULE_DOMAIN_NAME;
    readonly version: typeof STAGE_PATCH_MODULE_DOMAIN_VERSION;
    readonly chainId: number;
    readonly verifyingContract: Address;
  };
  readonly types: {
    readonly UVPStagePatchModuleStageSupplierPatch: readonly ProductSubmitTypedDataField[];
  };
  readonly primaryType: typeof STAGE_SUPPLIER_PATCH_PRIMARY_TYPE;
  readonly message: {
    readonly planId: Hex;
    readonly orderId: Hex;
    readonly selectorStageId: Hex;
    readonly targetStageId: Hex;
    readonly supplierId: Hex;
    readonly previousSupplierId: Hex;
    readonly patchNonce: string;
    readonly selector: Address;
    readonly deadline: string;
  };
}


export interface BuildPlanCommitTypedDataInput extends PlanCommitPayload {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
}

export interface BuildDerivedSignalTypedDataInput
  extends DerivedSignalPayload {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
}

export interface BuildSignalSubmissionTypedDataInput
  extends SignalSubmissionPayload {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
}

export interface BuildStageSupplierPatchTypedDataInput
  extends StageSupplierPatchCallPatch {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
  readonly planId: Hex | string;
  readonly orderId: Hex | string;
  readonly selector: Address | string;
  readonly deadline: bigint | number | string;
}


// 事实属主自证材料（submitSignal 族 attribution 参数）：sourceId/signalId
// 须与顶层事实键一致，stageId=0 表示不主张属主（合约按词表回退解析）。
export interface SignalAttributionPayload {
  readonly sourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly stageId: Hex | string;
  readonly capabilityProof: readonly (Hex | string)[];
}

export interface SignalAttributionCallStruct {
  readonly sourceId: Hex;
  readonly signalId: Hex;
  readonly stageId: Hex;
  readonly capabilityProof: readonly Hex[];
}

// 阶段 selector 绑定证明（stage patch 族的 bindingProof 参数）：
// selectorStageId=0 表示目标阶段未被 selector 绑定（无需证明）。
export interface SelectorBindingPayload {
  readonly selectorStageId: Hex | string;
  readonly proof: readonly (Hex | string)[];
}

export interface SelectorBindingCallStruct {
  readonly selectorStageId: Hex;
  readonly proof: readonly Hex[];
}

function normalizeSignalAttribution(
  attribution: SignalAttributionPayload,
): SignalAttributionCallStruct {
  return {
    sourceId: normalizeBytes32(attribution.sourceId, "attribution.sourceId"),
    signalId: normalizeBytes32(attribution.signalId, "attribution.signalId"),
    stageId: normalizeBytes32(attribution.stageId, "attribution.stageId"),
    capabilityProof: attribution.capabilityProof.map((word, index) =>
      normalizeBytes32(word, `attribution.capabilityProof[${index}]`),
    ),
  };
}

function normalizeSelectorBinding(
  selectorBinding: SelectorBindingPayload,
): SelectorBindingCallStruct {
  return {
    selectorStageId: normalizeBytes32(
      selectorBinding.selectorStageId,
      "selectorBinding.selectorStageId",
    ),
    proof: selectorBinding.proof.map((word, index) =>
      normalizeBytes32(word, `selectorBinding.proof[${index}]`),
    ),
  };
}


export interface DerivedSignalRequestCallStruct {
  readonly fromPlanId: Hex;
  readonly fromOrderId: Hex;
  readonly fromStageId: Hex;
  readonly targetPlanId: Hex;
  readonly targetOrderId: Hex;
  readonly targetSourceId: Hex;
  readonly signalId: Hex;
  readonly payloadHash: Hex;
  readonly idempotencyKey: Hex;
}

export type DerivedSignalRequestCallTuple = readonly [
  Hex,
  Hex,
  Hex,
  Hex,
  Hex,
  Hex,
  Hex,
  Hex,
  Hex,
];

export interface SubmitDerivedSignalForCallArgs {
  readonly fromPlanId: Hex | string;
  readonly fromOrderId: Hex | string;
  readonly fromStageId: Hex | string;
  readonly targetPlanId: Hex | string;
  readonly targetOrderId: Hex | string;
  readonly targetSourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly payloadHash: Hex | string;
  readonly idempotencyKey: Hex | string;
  readonly submitter: Address | string;
  readonly deadline: bigint | number | string;
  readonly signature: Hex | string;
  readonly proofs: DerivedSignalProofsPayload;
}

export interface DerivedSignalProofsPayload {
  readonly fromCapabilityProof: readonly (Hex | string)[];
}

export interface DerivedSignalProofsCallStruct {
  readonly fromCapabilityProof: readonly Hex[];
}

function normalizeDerivedSignalProofs(
  proofs: DerivedSignalProofsPayload,
): DerivedSignalProofsCallStruct {
  return {
    fromCapabilityProof: proofs.fromCapabilityProof.map((word, index) =>
      normalizeBytes32(word, `proofs.fromCapabilityProof[${index}]`),
    ),
  };
}

export interface ApplyStageSupplierPatchForCallArgs {
  readonly planId: Hex | string;
  readonly orderId: Hex | string;
  readonly patch: StageSupplierPatchCallPatch;
  readonly selector: Address | string;
  readonly deadline: bigint | number | string;
  readonly selectorSignature: Hex | string;
  readonly previousSupplierSignature: Hex | string;
  readonly bindingProof: SelectorBindingPayload;
  /** 候选集成员证明（candidate 阶段可用；dynamic 阶段空数组）。 */
  readonly candidateProof: readonly (Hex | string)[];
}

export interface SubmitSignalCallArgs {
  readonly planId: Hex | string;
  readonly orderId?: Hex | string;
  readonly sourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly payloadHash: Hex | string;
  readonly idempotencyKey: Hex | string;
  readonly attribution: SignalAttributionPayload;
  readonly targetStageId?: Hex | string;
  readonly files?: readonly StageFile[];
  readonly submitter: Address | string;
  readonly deadline: bigint | number | string;
  readonly signature?: Hex | string;
}


export type SubmitSignalCallConfig = StateMachineCallConfig;

export interface StagePatchModuleCallConfig {
  readonly stagePatchModuleAddress: Address | string;
  readonly chainId?: number;
}

export interface DerivedSignalModuleCallConfig {
  readonly derivedSignalModuleAddress: Address | string;
  readonly chainId?: number;
}


export type ApplyStageSupplierPatchForCallConfig = StagePatchModuleCallConfig;
export type SubmitDerivedSignalForCallConfig = DerivedSignalModuleCallConfig;


export interface SubmitDerivedSignalForCall {
  readonly address: Address;
  readonly abi: typeof DERIVED_SIGNAL_MODULE_ABI;
  readonly functionName: "submitDerivedSignalFor";
  readonly args: readonly [
    DerivedSignalRequestCallStruct,
    Address,
    bigint,
    Hex,
    DerivedSignalProofsCallStruct,
  ];
  readonly data: Hex;
  readonly chainId?: number;
}

export interface SignalSubmissionCallStruct {
  readonly planId: Hex;
  readonly orderId: Hex;
  readonly sourceId: Hex;
  readonly signalId: Hex;
  readonly payloadHash: Hex;
  readonly idempotencyKey: Hex;
  readonly attribution: SignalAttributionCallStruct;
  readonly targetStageId: Hex;
  readonly files: readonly StageFileCallStruct[];
  readonly submitter: Address;
  readonly deadline: bigint;
}

export interface SubmitSignalCall {
  readonly address: Address;
  readonly abi: typeof STATE_MACHINE_ABI;
  readonly functionName: "submitSignal";
  readonly args: readonly [SignalSubmissionCallStruct, Hex];
  readonly data: Hex;
  readonly chainId?: number;
}

export type StageSupplierPatchCallTuple = readonly [
  Hex,
  Hex,
  Hex,
  Hex,
  bigint,
];

export interface ApplyStageSupplierPatchForCall {
  readonly address: Address;
  readonly abi: typeof STAGE_PATCH_MODULE_ABI;
  readonly functionName: "applyStageSupplierPatchFor";
  readonly args: readonly [
    Hex,
    Hex,
    StageSupplierPatchCallTuple,
    Address,
    bigint,
    Hex,
    Hex,
    SelectorBindingCallStruct,
    readonly Hex[],
  ];
  readonly data: Hex;
  readonly chainId?: number;
}




const BYTES32_RE = /^0x[a-fA-F0-9]{64}$/;
const ZERO_BYTES32 = `0x${"0".repeat(64)}` as Hex;

function normalizeStageFiles(files: readonly StageFile[]): readonly StageFileCallStruct[] {
  if (!Array.isArray(files)) {
    throw new Error("files must be an array");
  }
  return files.map((file, index) => {
    if (typeof file.key !== "string") {
      throw new Error(`files[${index}].key must be a string`);
    }
    return {
      key: file.key,
      payload: normalizeHex(file.payload, `files[${index}].payload`),
    };
  });
}

export function buildPlanCommitTypedData(
  input: BuildPlanCommitTypedDataInput,
): PlanCommitTypedData {
  return {
    domain: {
      name: PRODUCT_SUBMIT_DOMAIN_NAME,
      version: PRODUCT_SUBMIT_DOMAIN_VERSION,
      chainId: normalizeChainId(input.chainId),
      verifyingContract: normalizeAddress(
        input.verifyingContract,
        "verifyingContract",
      ),
    },
    types: {
      UVPStateMachinePlanCommit: PLAN_COMMIT_TYPED_DATA_FIELDS,
    },
    primaryType: PLAN_COMMIT_PRIMARY_TYPE,
    message: {
      publisher: normalizeAddress(input.publisher, "publisher"),
      hooksHash: normalizeBytes32(input.hooksHash, "hooksHash"),
      capabilitiesRoot: normalizeBytes32(
        input.capabilitiesRoot,
        "capabilitiesRoot",
      ),
      supplierBindingsRoot: normalizeBytes32(
        input.supplierBindingsRoot,
        "supplierBindingsRoot",
      ),
      deadline: normalizeUintString(input.deadline, "deadline"),
    },
  };
}

export const FACT_ATTRIBUTION_TYPEHASH = keccak256(
  stringToHex(
    "FactAttribution(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof)",
  ),
);

export function factAttributionHash(
  attribution: SignalAttributionPayload,
): Hex {
  const normalized = normalizeSignalAttribution(attribution);
  return keccak256(
    encodeAbiParameters(
      [
        { name: "typehash", type: "bytes32" },
        { name: "sourceId", type: "bytes32" },
        { name: "signalId", type: "bytes32" },
        { name: "stageId", type: "bytes32" },
        { name: "capabilityProofHash", type: "bytes32" },
      ],
      [
        FACT_ATTRIBUTION_TYPEHASH,
        normalized.sourceId,
        normalized.signalId,
        normalized.stageId,
        keccak256(
          encodeAbiParameters(
            [{ name: "capabilityProof", type: "bytes32[]" }],
            [normalized.capabilityProof],
          ),
        ),
      ],
    ),
  );
}

export function buildSignalSubmissionTypedData(
  input: BuildSignalSubmissionTypedDataInput,
): SignalSubmissionTypedData {
  return {
    domain: {
      name: PRODUCT_SUBMIT_DOMAIN_NAME,
      version: PRODUCT_SUBMIT_DOMAIN_VERSION,
      chainId: normalizeChainId(input.chainId),
      verifyingContract: normalizeAddress(
        input.verifyingContract,
        "verifyingContract",
      ),
    },
    types: {
      UVPStateMachineSignalSubmission: SIGNAL_SUBMISSION_TYPED_DATA_FIELDS,
    },
    primaryType: SIGNAL_SUBMISSION_PRIMARY_TYPE,
    message: {
      planId: normalizeBytes32(input.planId, "planId"),
      orderId: normalizeBytes32(input.orderId ?? ZERO_BYTES32, "orderId"),
      sourceId: normalizeBytes32(input.sourceId, "sourceId"),
      signalId: normalizeBytes32(input.signalId, "signalId"),
      payloadHash: normalizeBytes32(input.payloadHash, "payloadHash"),
      idempotencyKey: normalizeBytes32(input.idempotencyKey, "idempotencyKey"),
      targetStageId: normalizeBytes32(
        input.targetStageId ?? ZERO_BYTES32,
        "targetStageId",
      ),
      filesHash: stageFilesHash(input.files ?? []),
      attributionHash: factAttributionHash(input.attribution),
      submitter: normalizeAddress(input.submitter, "submitter"),
      deadline: normalizeUintString(input.deadline, "deadline"),
    },
  };
}

export function buildDerivedSignalTypedData(
  input: BuildDerivedSignalTypedDataInput,
): DerivedSignalTypedData {
  return {
    domain: {
      name: DERIVED_SIGNAL_DOMAIN_NAME,
      version: DERIVED_SIGNAL_DOMAIN_VERSION,
      chainId: normalizeChainId(input.chainId),
      verifyingContract: normalizeAddress(
        input.verifyingContract,
        "verifyingContract",
      ),
    },
    types: {
      UVPDerivedSignalModuleSignal: DERIVED_SIGNAL_TYPED_DATA_FIELDS,
    },
    primaryType: DERIVED_SIGNAL_PRIMARY_TYPE,
    message: {
      fromPlanId: normalizeBytes32(input.fromPlanId, "fromPlanId"),
      fromOrderId: normalizeBytes32(input.fromOrderId, "fromOrderId"),
      fromStageId: normalizeBytes32(input.fromStageId, "fromStageId"),
      targetPlanId: normalizeBytes32(input.targetPlanId, "targetPlanId"),
      targetOrderId: normalizeBytes32(input.targetOrderId, "targetOrderId"),
      targetSourceId: normalizeBytes32(input.targetSourceId, "targetSourceId"),
      signalId: normalizeBytes32(input.signalId, "signalId"),
      payloadHash: normalizeBytes32(input.payloadHash, "payloadHash"),
      idempotencyKey: normalizeBytes32(input.idempotencyKey, "idempotencyKey"),
      submitter: normalizeAddress(input.submitter, "submitter"),
      deadline: normalizeUintString(input.deadline, "deadline"),
    },
  };
}

export function buildStageSupplierPatchTypedData(
  input: BuildStageSupplierPatchTypedDataInput,
): StageSupplierPatchTypedData {
  const patch = normalizeStageSupplierPatch(input);
  return {
    domain: {
      name: STAGE_PATCH_MODULE_DOMAIN_NAME,
      version: STAGE_PATCH_MODULE_DOMAIN_VERSION,
      chainId: normalizeChainId(input.chainId),
      verifyingContract: normalizeAddress(
        input.verifyingContract,
        "verifyingContract",
      ),
    },
    types: {
      UVPStagePatchModuleStageSupplierPatch:
        STAGE_SUPPLIER_PATCH_TYPED_DATA_FIELDS,
    },
    primaryType: STAGE_SUPPLIER_PATCH_PRIMARY_TYPE,
    message: {
      planId: normalizeBytes32(input.planId, "planId"),
      orderId: normalizeBytes32(input.orderId, "orderId"),
      selectorStageId: patch[0],
      targetStageId: patch[1],
      supplierId: patch[2],
      previousSupplierId: patch[3],
      patchNonce: patch[4].toString(10),
      selector: normalizeAddress(input.selector, "selector"),
      deadline: normalizeUintString(input.deadline, "deadline"),
    },
  };
}


export async function recoverPlanCommitSigner(
  typedData: PlanCommitTypedData,
  signature: Hex | string,
): Promise<Address> {
  const recovered = await recoverTypedDataAddress({
    domain: typedData.domain,
    types: typedData.types,
    primaryType: typedData.primaryType,
    message: typedData.message,
    signature: normalizeHex(signature, "signature"),
  } as unknown as Parameters<typeof recoverTypedDataAddress>[0]);
  return normalizeAddress(recovered, "recoveredPublisher");
}

export async function recoverDerivedSignalSigner(
  typedData: DerivedSignalTypedData,
  signature: Hex | string,
): Promise<Address> {
  const recovered = await recoverTypedDataAddress({
    domain: typedData.domain,
    types: typedData.types,
    primaryType: typedData.primaryType,
    message: typedData.message,
    signature: normalizeHex(signature, "signature"),
  } as unknown as Parameters<typeof recoverTypedDataAddress>[0]);
  return normalizeAddress(recovered, "recoveredDerivedSignalSigner");
}

export async function recoverStageSupplierPatchSigner(
  typedData: StageSupplierPatchTypedData,
  signature: Hex | string,
): Promise<Address> {
  const recovered = await recoverTypedDataAddress({
    domain: typedData.domain,
    types: typedData.types,
    primaryType: typedData.primaryType,
    message: typedData.message,
    signature: normalizeHex(signature, "signature"),
  } as unknown as Parameters<typeof recoverTypedDataAddress>[0]);
  return normalizeAddress(recovered, "recoveredStageSupplierPatchSigner");
}

export async function recoverSignalSubmissionSigner(
  typedData: SignalSubmissionTypedData,
  signature: Hex | string,
): Promise<Address> {
  const recovered = await recoverTypedDataAddress({
    domain: typedData.domain,
    types: typedData.types,
    primaryType: typedData.primaryType,
    message: typedData.message,
    signature: normalizeHex(signature, "signature"),
  } as unknown as Parameters<typeof recoverTypedDataAddress>[0]);
  return normalizeAddress(recovered, "recoveredSignalSubmitter");
}


export function buildSubmitDerivedSignalForCall(
  config: SubmitDerivedSignalForCallConfig,
  args: SubmitDerivedSignalForCallArgs,
): SubmitDerivedSignalForCall {
  const normalizedArgs = [
    normalizeDerivedSignalRequest(args),
    normalizeAddress(args.submitter, "submitter"),
    normalizeUintBigInt(args.deadline, "deadline"),
    normalizeHex(args.signature, "signature"),
    normalizeDerivedSignalProofs(args.proofs),
  ] as const satisfies readonly [
    DerivedSignalRequestCallStruct,
    Address,
    bigint,
    Hex,
    DerivedSignalProofsCallStruct,
  ];

  return {
    address: normalizeAddress(
      config.derivedSignalModuleAddress,
      "derivedSignalModuleAddress",
    ),
    abi: DERIVED_SIGNAL_MODULE_ABI,
    functionName: "submitDerivedSignalFor",
    args: normalizedArgs,
    data: encodeFunctionData({
      abi: DERIVED_SIGNAL_MODULE_ABI,
      functionName: "submitDerivedSignalFor",
      args: normalizedArgs as never,
    }),
    ...(config.chainId !== undefined
      ? { chainId: normalizeChainId(config.chainId) }
      : {}),
  };
}

export function buildApplyStageSupplierPatchForCall(
  config: ApplyStageSupplierPatchForCallConfig,
  args: ApplyStageSupplierPatchForCallArgs,
): ApplyStageSupplierPatchForCall {
  const normalizedArgs = [
    normalizeBytes32(args.planId, "planId"),
    normalizeBytes32(args.orderId, "orderId"),
    normalizeStageSupplierPatch(args.patch),
    normalizeAddress(args.selector, "selector"),
    normalizeUintBigInt(args.deadline, "deadline"),
    normalizeHex(args.selectorSignature, "selectorSignature"),
    normalizeHex(args.previousSupplierSignature, "previousSupplierSignature"),
    normalizeSelectorBinding(args.bindingProof),
    args.candidateProof.map((word, index) =>
      normalizeBytes32(word, `candidateProof[${index}]`),
    ),
  ] as const;

  return {
    address: normalizeAddress(
      config.stagePatchModuleAddress,
      "stagePatchModuleAddress",
    ),
    abi: STAGE_PATCH_MODULE_ABI,
    functionName: "applyStageSupplierPatchFor",
    args: normalizedArgs,
    data: encodeFunctionData({
      abi: STAGE_PATCH_MODULE_ABI,
      functionName: "applyStageSupplierPatchFor",
      args: normalizedArgs as never,
    }),
    ...(config.chainId !== undefined
      ? { chainId: normalizeChainId(config.chainId) }
      : {}),
  };
}

export function buildSubmitSignalCall(
  config: SubmitSignalCallConfig,
  args: SubmitSignalCallArgs,
): SubmitSignalCall {
  const submission: SignalSubmissionCallStruct = {
    planId: normalizeBytes32(args.planId, "planId"),
    orderId: normalizeBytes32(args.orderId ?? ZERO_BYTES32, "orderId"),
    sourceId: normalizeBytes32(args.sourceId, "sourceId"),
    signalId: normalizeBytes32(args.signalId, "signalId"),
    payloadHash: normalizeBytes32(args.payloadHash, "payloadHash"),
    idempotencyKey: normalizeBytes32(args.idempotencyKey, "idempotencyKey"),
    attribution: normalizeSignalAttribution(args.attribution),
    targetStageId: normalizeBytes32(
      args.targetStageId ?? ZERO_BYTES32,
      "targetStageId",
    ),
    files: normalizeStageFiles(args.files ?? []),
    submitter: normalizeAddress(args.submitter, "submitter"),
    deadline: normalizeUintBigInt(args.deadline, "deadline"),
  };
  const signature =
    args.signature === undefined
      ? ("0x" as Hex)
      : normalizeHex(args.signature, "signature");
  const normalizedArgs = [submission, signature] as const;
  return {
    address: normalizeAddress(
      config.stateMachineAddress,
      "stateMachineAddress",
    ),
    abi: STATE_MACHINE_ABI,
    functionName: "submitSignal",
    args: normalizedArgs,
    data: encodeFunctionData({
      abi: STATE_MACHINE_ABI,
      functionName: "submitSignal",
      args: normalizedArgs as never,
    }),
    ...(config.chainId !== undefined
      ? { chainId: normalizeChainId(config.chainId) }
      : {}),
  };
}

export function hashStageSupplierPatchPayload(
  payload: StageSupplierPatchPayload,
): Hex {
  const normalized = normalizeStageSupplierPatchPayload(payload);
  // 域分离：payload 哈希以 keccak256(STAGE_SUPPLIER_PATCH_PAYLOAD_HASH_DOMAIN)
  // 开头——域常量必须真正进入 preimage，只在定义处引用等于没有分域。
  return keccak256(
    encodeAbiParameters(
      [
        { name: "domain", type: "bytes32" },
        { name: "selectorStageId", type: "bytes32" },
        { name: "targetStageId", type: "bytes32" },
        { name: "supplierId", type: "bytes32" },
        { name: "previousSupplierId", type: "bytes32" },
        { name: "patchNonce", type: "uint256" },
      ],
      [
        keccak256(stringToHex(STAGE_SUPPLIER_PATCH_PAYLOAD_HASH_DOMAIN)),
        normalized.selectorStageId,
        normalized.targetStageId,
        normalized.supplierId,
        normalized.previousSupplierId,
        BigInt(normalized.patchNonce),
      ],
    ),
  );
}

// 地址/字节规范化双形态（下游比较键与展示/签名场景的单源）：
// - normalizeAddress：宽松 40-hex 校验 + 统一小写输出——比较键/存储键的
//   权威形态（viem getAddress 先小写再重算 EIP-55、不验证输入大小写，
//   混合大小写坏 checksum 的输入也按 20 字节身份接受并归一为小写）；
// - normalizeAddressChecksummed：严格 EIP-55 checksum 校验 + checksummed
//   输出——展示/签名等拼写敏感场景（错拼地址在入口即拒）。
export function normalizeAddress(
  value: Address | string,
  fieldName = "address",
): Address {
  if (!isAddress(value, { strict: false })) {
    throw new Error(`${fieldName} must be a valid EVM address`);
  }

  return getAddress(value).toLowerCase() as Address;
}

export function normalizeAddressChecksummed(
  value: Address | string,
  fieldName = "address",
): Address {
  if (!isAddress(value)) {
    throw new Error(
      `${fieldName} must be a valid EIP-55 checksummed EVM address`,
    );
  }

  return getAddress(value);
}

export function normalizeBytes32(
  value: Hex | string,
  fieldName = "bytes32",
): Hex {
  if (!isHex(value) || !BYTES32_RE.test(value)) {
    throw new Error(`${fieldName} must be a 32-byte hex value`);
  }

  return value.toLowerCase() as Hex;
}

function normalizeHex(value: Hex | string, fieldName: string): Hex {
  if (!isHex(value)) {
    throw new Error(`${fieldName} must be a 0x-prefixed hex string`);
  }
  return value as Hex;
}

function normalizeDerivedSignalRequest(
  args: SubmitDerivedSignalForCallArgs,
): DerivedSignalRequestCallStruct {
  return {
    fromPlanId: normalizeNonZeroBytes32(args.fromPlanId, "fromPlanId"),
    fromOrderId: normalizeNonZeroBytes32(args.fromOrderId, "fromOrderId"),
    fromStageId: normalizeNonZeroBytes32(args.fromStageId, "fromStageId"),
    targetPlanId: normalizeNonZeroBytes32(args.targetPlanId, "targetPlanId"),
    targetOrderId: normalizeNonZeroBytes32(args.targetOrderId, "targetOrderId"),
    targetSourceId: normalizeNonZeroBytes32(
      args.targetSourceId,
      "targetSourceId",
    ),
    signalId: normalizeNonZeroBytes32(args.signalId, "signalId"),
    payloadHash: normalizeBytes32(args.payloadHash, "payloadHash"),
    idempotencyKey: normalizeBytes32(args.idempotencyKey, "idempotencyKey"),
  };
}

function normalizeStageSupplierPatch(
  patch: StageSupplierPatchCallPatch,
): StageSupplierPatchCallTuple {
  return [
    normalizeNonZeroBytes32(patch.selectorStageId, "selectorStageId"),
    normalizeNonZeroBytes32(patch.targetStageId, "targetStageId"),
    normalizeNonZeroBytes32(patch.supplierId, "supplierId"),
    normalizeBytes32(patch.previousSupplierId, "previousSupplierId"),
    normalizeUintBigInt(patch.patchNonce, "patchNonce"),
  ] as const;
}

function normalizeStageSupplierPatchPayload(
  payload: StageSupplierPatchPayload,
): {
  readonly selectorStageId: Hex;
  readonly targetStageId: Hex;
  readonly supplierId: Hex;
  readonly previousSupplierId: Hex;
  readonly patchNonce: string;
} {
  return {
    selectorStageId: normalizeNonZeroBytes32(
      payload.selectorStageId,
      "selectorStageId",
    ),
    targetStageId: normalizeNonZeroBytes32(
      payload.targetStageId,
      "targetStageId",
    ),
    supplierId: normalizeNonZeroBytes32(payload.supplierId, "supplierId"),
    previousSupplierId: normalizeBytes32(
      payload.previousSupplierId,
      "previousSupplierId",
    ),
    patchNonce: normalizeUintString(payload.patchNonce, "patchNonce"),
  };
}


function normalizeNonZeroBytes32(value: Hex | string, fieldName: string): Hex {
  const normalized = normalizeBytes32(value, fieldName);
  if (normalized === ZERO_BYTES32) {
    throw new Error(`${fieldName} must be non-zero`);
  }
  return normalized;
}

/**
 * chainId 入口校验：跨运行时域的 FFI 字段保持 64 位，
 * ≥ 2^64 / 负数 / 非整数在 typed-data/EIP-712 入口显式拒绝；2^53 以上的
 * number 无法精确表示，同样拦截（不得静默取整）。
 */
const MAX_CHAIN_ID = 2 ** 64; // exactly representable double (power of two)

function normalizeChainId(value: number): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value <= 0) {
    throw new Error(
      "chainId must be a positive integer (negative, zero, fractional, and non-number values are rejected)",
    );
  }
  if (value >= MAX_CHAIN_ID) {
    throw new Error(
      `chainId must be < 2^64 (${MAX_CHAIN_ID}): the cross-runtime domain FFI field stays 64-bit and overflow is rejected explicitly, received ${value}`,
    );
  }
  if (!Number.isSafeInteger(value)) {
    throw new Error(
      `chainId must be a safe integer (numbers beyond 2^53 cannot be represented exactly), received ${value}`,
    );
  }
  return value;
}

function normalizeUintString(
  value: bigint | number | string,
  fieldName: string,
): string {
  if (typeof value === "bigint") {
    if (value < 0n) {
      throw new Error(`${fieldName} must be a non-negative integer`);
    }
    return value.toString(10);
  }

  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new Error(`${fieldName} must be a non-negative safe integer`);
    }
    return BigInt(value).toString(10);
  }

  if (!/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error(`${fieldName} must be a base-10 uint string`);
  }
  return BigInt(value).toString(10);
}

function normalizeUintBigInt(
  value: bigint | number | string,
  fieldName: string,
): bigint {
  if (typeof value === "bigint") {
    if (value < 0n) {
      throw new Error(`${fieldName} must be a non-negative integer`);
    }
    return value;
  }

  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new Error(`${fieldName} must be a non-negative safe integer`);
    }
    return BigInt(value);
  }

  return BigInt(normalizeUintString(value, fieldName));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// Plan registration transaction builders: encode the two-step Solidity
// registration flow (commitPlan + finalizePlan) from precompiled register
// arguments. Pure calldata only — no signer, network, or compiler import; the
// typed-data digest is PlanCommit above and the ABI is STATE_MACHINE_ABI.
export type PlanInstructionOp = "SIGNAL" | "NOT" | "AND" | "OR" | "DELAY";

export const PLAN_INSTRUCTION_OP_CODES: Readonly<Record<PlanInstructionOp, number>> = {
  SIGNAL: 0,
  NOT: 1,
  AND: 2,
  OR: 3,
  DELAY: 4,
};

export type PlanRegistrationInstruction =
  | {
      readonly op: "SIGNAL";
      readonly sourceId: Hex | string;
      readonly signalId: Hex | string;
      readonly signalKey?: Hex | string;
    }
  | { readonly op: "NOT" }
  | { readonly op: "AND" | "OR"; readonly arity: number }
  | { readonly op: "DELAY"; readonly delaySeconds: number | string };

export interface PlanRegistrationHook {
  readonly hookId: Hex | string;
  readonly stageId: Hex | string;
  readonly hookName: Hex | string;
  readonly kind?: "receive" | "admission";
  readonly flags: number;
  readonly instructions: readonly PlanRegistrationInstruction[];
  readonly dependencyKeys: readonly (Hex | string)[];
  readonly routeId?: Hex | string;
}

export interface PlanRegistrationArgs {
  readonly planId: Hex | string;
  readonly planHash: Hex | string;
  readonly hooksHash: Hex | string;
  readonly capabilitiesRoot: Hex | string;
  readonly supplierBindingsRoot: Hex | string;
  readonly hooks: readonly PlanRegistrationHook[];
  readonly supplierBindings: readonly StageSupplierBinding[];
}

export interface PlanRegistrationSource {
  readonly planHash: Hex | string;
  readonly hooksHash: Hex | string;
  readonly capabilitiesRoot: Hex | string;
  readonly supplierBindingsRoot: Hex | string;
  readonly hooks: readonly PlanRegistrationHook[];
  readonly supplierBindings: readonly StageSupplierBinding[];
}

export interface StateMachineCallConfig {
  readonly stateMachineAddress: Address | string;
  readonly chainId?: number;
}

export interface PlanTransactionCall {
  readonly address: Address;
  readonly functionName: "commitPlan" | "finalizePlan";
  readonly data: Hex;
  readonly chainId?: number;
}

/** Cut a PlanRegistrationArgs out of compiler register args plus the derived planId. */
export function planRegistrationArgs(
  source: PlanRegistrationSource,
  planId: Hex | string,
): PlanRegistrationArgs {
  return {
    planId,
    planHash: source.planHash,
    hooksHash: source.hooksHash,
    capabilitiesRoot: source.capabilitiesRoot,
    supplierBindingsRoot: source.supplierBindingsRoot,
    hooks: source.hooks,
    supplierBindings: source.supplierBindings,
  };
}

export interface PlanCommitCallArgs {
  readonly publisher: Address | string;
  readonly deadline: bigint | number | string;
  readonly registration: PlanRegistrationArgs;
  readonly signature: Hex | string;
}

export interface PlanRegistrationBuild {
  readonly typedData: PlanCommitTypedData;
  readonly commitCall: PlanTransactionCall;
  readonly finalizeCall: PlanTransactionCall;
}

interface PlanCommitTuple {
  readonly publisher: Address;
  readonly hooksHash: Hex;
  readonly capabilitiesRoot: Hex;
  readonly supplierBindingsRoot: Hex;
  readonly deadline: bigint;
}

interface SupplierBindingCallStruct {
  readonly stageId: Hex;
  readonly supplierId: Hex;
  readonly kind: SupplierBindingKind;
}

interface PlanCommitHookTuple {
  readonly hookId: Hex;
  readonly stageId: Hex;
  readonly hookName: Hex;
  readonly flags: number;
  readonly instructions: readonly CompactInstructionTuple[];
  readonly dependencyKeys: readonly Hex[];
}

interface CompactInstructionTuple {
  readonly op: number;
  readonly sourceId: Hex;
  readonly signalId: Hex;
  readonly arity: number;
  readonly delaySeconds: bigint;
}

export function buildPlanCommitTypedDataFor(
  config: Pick<StateMachineCallConfig, "stateMachineAddress" | "chainId">,
  args: Pick<PlanCommitCallArgs, "publisher" | "deadline" | "registration">,
): PlanCommitTypedData {
  const commit = planCommitTuple(config, args);
  return buildPlanCommitTypedData({
    chainId: planTypedDataChainId(config.chainId),
    verifyingContract: normalizeAddressChecksummed(config.stateMachineAddress, "stateMachineAddress"),
    publisher: commit.publisher,
    hooksHash: commit.hooksHash,
    capabilitiesRoot: commit.capabilitiesRoot,
    supplierBindingsRoot: commit.supplierBindingsRoot,
    deadline: commit.deadline,
  });
}

export function buildPlanCommitCall(
  config: StateMachineCallConfig,
  args: PlanCommitCallArgs,
): PlanTransactionCall {
  const address = normalizeAddressChecksummed(config.stateMachineAddress, "stateMachineAddress");
  const commit = planCommitTuple(config, args);
  const signature = normalizePlanSignature(args.signature);
  const hooks = encodePlanRegistrationHooks(args.registration.hooks);
  const bindings = args.registration.supplierBindings.map((binding) => ({
    stageId: normalizeBytes32(binding.stageId, "supplierBindings[].stageId"),
    supplierId: normalizeBytes32(
      binding.supplierId,
      "supplierBindings[].supplierId",
    ),
    kind: normalizeSupplierBindingKind(binding.kind),
  }));
  const data = encodeFunctionData({
    abi: STATE_MACHINE_ABI,
    functionName: "commitPlan",
    args: [commit, hooks, bindings, signature],
  });
  return planCallObject(address, "commitPlan", data, config.chainId);
}

export function buildPlanFinalizeCall(
  config: StateMachineCallConfig,
  planId: Hex | string,
): PlanTransactionCall {
  const address = normalizeAddressChecksummed(config.stateMachineAddress, "stateMachineAddress");
  const data = encodeFunctionData({
    abi: STATE_MACHINE_ABI,
    functionName: "finalizePlan",
    args: [normalizeBytes32(planId, "planId")],
  });
  return planCallObject(address, "finalizePlan", data, config.chainId);
}

export function buildPlanRegistration(
  config: StateMachineCallConfig,
  args: PlanCommitCallArgs,
): PlanRegistrationBuild {
  return {
    typedData: buildPlanCommitTypedDataFor(config, args),
    commitCall: buildPlanCommitCall(config, args),
    finalizeCall: buildPlanFinalizeCall(config, args.registration.planId),
  };
}

export function encodePlanRegistrationHooks(
  hooks: readonly PlanRegistrationHook[],
): readonly PlanCommitHookTuple[] {
  if (hooks.length === 0) {
    throw new Error("plan registration requires at least one hook");
  }
  return hooks.map((hook) => ({
    hookId: normalizeBytes32(hook.hookId, "hooks[].hookId"),
    stageId: normalizeBytes32(hook.stageId, "hooks[].stageId"),
    hookName: normalizeBytes32(hook.hookName, "hooks[].hookName"),
    flags: normalizePlanFlags(hook.flags),
    instructions: hook.instructions.map(encodePlanInstruction),
    dependencyKeys: hook.dependencyKeys.map((key, index) =>
      normalizeBytes32(key, `hooks[].dependencyKeys[${index}]`)),
  }));
}

function planCommitTuple(
  config: StateMachineCallConfig,
  args: Pick<PlanCommitCallArgs, "publisher" | "deadline" | "registration">,
): PlanCommitTuple {
  const publisher = normalizeAddressChecksummed(args.publisher, "publisher");
  return {
    publisher,
    hooksHash: normalizeBytes32(args.registration.hooksHash, "hooksHash"),
    capabilitiesRoot: normalizeBytes32(args.registration.capabilitiesRoot, "capabilitiesRoot"),
    supplierBindingsRoot: normalizeBytes32(
      args.registration.supplierBindingsRoot,
      "supplierBindingsRoot",
    ),
    deadline: normalizeUintBigInt(args.deadline, "deadline"),
  };
}

function encodePlanInstruction(
  instruction: PlanRegistrationInstruction,
): CompactInstructionTuple {
  switch (instruction.op) {
    case "SIGNAL":
      return {
        op: PLAN_INSTRUCTION_OP_CODES.SIGNAL,
        sourceId: normalizeBytes32(instruction.sourceId, "instructions[].sourceId"),
        signalId: normalizeBytes32(instruction.signalId, "instructions[].signalId"),
        arity: 0,
        delaySeconds: 0n,
      };
    case "NOT":
      return {
        op: PLAN_INSTRUCTION_OP_CODES.NOT,
        sourceId: ZERO_BYTES32,
        signalId: ZERO_BYTES32,
        arity: 0,
        delaySeconds: 0n,
      };
    case "AND":
    case "OR":
      return {
        op: PLAN_INSTRUCTION_OP_CODES[instruction.op],
        sourceId: ZERO_BYTES32,
        signalId: ZERO_BYTES32,
        arity: normalizePlanArity(instruction.arity),
        delaySeconds: 0n,
      };
    case "DELAY":
      return {
        op: PLAN_INSTRUCTION_OP_CODES.DELAY,
        sourceId: ZERO_BYTES32,
        signalId: ZERO_BYTES32,
        arity: 0,
        delaySeconds: normalizeUintBigInt(instruction.delaySeconds, "instructions[].delaySeconds"),
      };
  }
}

function planTypedDataChainId(chainId: number | undefined): number {
  if (chainId === undefined) {
    throw new Error("chainId must be a positive integer for typed data");
  }
  return normalizeChainId(chainId);
}

function normalizePlanArity(value: number): number {
  if (!Number.isSafeInteger(value) || value < 0 || value > 0xffff) {
    throw new Error("instructions[].arity must be a uint16-safe integer");
  }
  return value;
}

function normalizeSupplierBindingKind(value: number): SupplierBindingKind {
  if (
    value !== SUPPLIER_BINDING_KIND_DEFAULT &&
    value !== SUPPLIER_BINDING_KIND_CANDIDATE
  ) {
    throw new Error("supplierBindings[].kind must be 0 (default) or 1 (candidate)");
  }
  return value;
}

function normalizePlanFlags(value: number): number {
  if (!Number.isSafeInteger(value) || value < 0 || value > 0xff) {
    throw new Error("hooks[].flags must be a uint8-safe integer");
  }
  return value;
}

function normalizePlanSignature(signature: Hex | string): Hex {
  if (typeof signature !== "string" || !/^0x[0-9a-fA-F]{130}$/.test(signature)) {
    throw new Error("signature must be a 65-byte hex string");
  }
  return signature as Hex;
}

function planCallObject(
  address: Address,
  functionName: PlanTransactionCall["functionName"],
  data: Hex,
  chainId: number | undefined,
): PlanTransactionCall {
  return {
    address,
    functionName,
    data,
    ...(chainId !== undefined ? { chainId } : {}),
  };
}

// HookReady event surface: the topic and decoder for the state machine's
// ready emission. The ABI/event shape is STATE_MACHINE_ABI above; consumers
// (watcher, deploy driver, order app) must not re-derive the topic locally.
export const HOOK_READY_TOPIC = keccak256(
  stringToBytes("HookReady(bytes32,bytes32,bytes32,bytes32,bytes32)"),
);

export interface StateMachineRawLog {
  readonly data: Hex;
  readonly topics: readonly Hex[];
  readonly address?: Address | string;
  readonly blockNumber?: bigint | null;
  readonly transactionHash?: Hex | null;
  readonly logIndex?: number | bigint | null;
}

export interface StateMachineHookReady {
  readonly type: "HookReady";
  readonly eventId: Hex;
  readonly stateMachineAddress?: Address;
  readonly planId: Hex;
  readonly orderId: Hex;
  readonly hookId: Hex;
  readonly stageId: Hex;
  readonly hookNameId: Hex;
  readonly stageIdentifier?: string;
  readonly hookName?: string;
  readonly blockNumber?: bigint;
  readonly transactionHash?: Hex;
  readonly logIndex?: bigint;
  readonly raw?: StateMachineRawLog;
}

export interface StateMachineArtifactIndex {
  readonly hooksByHookId?: Readonly<Record<string, StateMachineHookMetadata>>;
  readonly signals?: Readonly<Record<string, StateMachineSignalMetadata>>;
  readonly selectorBindings?: readonly StageSelectorBindingTableEntry[];
  readonly signalCapabilities?: readonly SignalCapabilityTableEntry[];
}

export interface StateMachineHookMetadata {
  readonly stageIdentifier: string;
  readonly hookName: string;
}

export interface StateMachineSignalMetadata {
  readonly sourceId: Hex | string;
  readonly signalId: Hex | string;
}

export function decodeHookReadyLog(
  log: StateMachineRawLog,
  artifact?: StateMachineArtifactIndex,
): StateMachineHookReady | undefined {
  if (log.topics[0] !== HOOK_READY_TOPIC) {
    return undefined;
  }

  let decoded: unknown;
  try {
    decoded = decodeEventLog({
      abi: STATE_MACHINE_ABI,
      eventName: "HookReady",
      data: log.data,
      topics: log.topics as [Hex, ...Hex[]],
    });
  } catch (error) {
    throw new Error(`failed to decode HookReady log data: ${describeHookDecodeError(error)}`);
  }

  const args = (decoded as { readonly args?: unknown }).args as {
    readonly planId?: unknown;
    readonly orderId?: unknown;
    readonly hookId?: unknown;
    readonly stageId?: unknown;
    readonly hookName?: unknown;
  };
  const blockNumber = log.blockNumber ?? undefined;
  const transactionHash = log.transactionHash ?? undefined;
  const logIndex = normalizeHookLogIndex(log.logIndex);
  const hookId = normalizeBytes32(hookStringField(args.hookId, "hookId"), "hookId");
  const metadata = artifact?.hooksByHookId?.[hookId];
  const stateMachineAddress = log.address
    ? normalizeAddressChecksummed(log.address, "log.address")
    : undefined;

  return {
    type: "HookReady",
    eventId: hookReadyEventId(log),
    ...(stateMachineAddress ? { stateMachineAddress } : {}),
    planId: normalizeBytes32(hookStringField(args.planId, "planId"), "planId"),
    orderId: normalizeBytes32(hookStringField(args.orderId, "orderId"), "orderId"),
    hookId,
    stageId: normalizeBytes32(hookStringField(args.stageId, "stageId"), "stageId"),
    hookNameId: normalizeBytes32(hookStringField(args.hookName, "hookName"), "hookName"),
    ...(metadata?.stageIdentifier ? { stageIdentifier: metadata.stageIdentifier } : {}),
    ...(metadata?.hookName ? { hookName: metadata.hookName } : {}),
    ...(blockNumber !== undefined ? { blockNumber } : {}),
    ...(transactionHash ? { transactionHash } : {}),
    ...(logIndex !== undefined ? { logIndex } : {}),
    raw: log,
  };
}

export function hookReadyEventId(log: Pick<StateMachineRawLog, "transactionHash" | "logIndex">): Hex {
  if (!log.transactionHash) {
    throw new Error(
      "HookReady log is missing transactionHash; refusing to derive an event id from zero values",
    );
  }
  const logIndex = normalizeHookLogIndex(log.logIndex);
  if (logIndex === undefined) {
    throw new Error(
      "HookReady log is missing logIndex; refusing to derive an event id from zero values",
    );
  }
  return keccak256(encodeAbiParameters(
    [
      { type: "bytes32" },
      { type: "uint256" },
    ],
    [normalizeBytes32(log.transactionHash, "transactionHash"), logIndex],
  ));
}

export function tryHookReadyEventId(log: StateMachineRawLog): Hex | undefined {
  try {
    return hookReadyEventId(log);
  } catch {
    return undefined;
  }
}

export function tryNormalizeStateMachineAddress(
  address: Address | string | undefined,
): Address | undefined {
  if (address === undefined) {
    return undefined;
  }
  try {
    return normalizeAddressChecksummed(address, "log.address");
  } catch {
    return undefined;
  }
}

function normalizeHookLogIndex(value: number | bigint | null | undefined): bigint | undefined {
  if (value === null || value === undefined) {
    return undefined;
  }
  if (typeof value === "bigint") {
    return value;
  }
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error("logIndex must be a non-negative safe integer");
  }
  return BigInt(value);
}

function hookStringField(value: unknown, fieldName: string): string {
  if (typeof value !== "string") {
    throw new Error(`${fieldName} must be a string`);
  }
  return value;
}

function describeHookDecodeError(error: unknown): string {
  return error instanceof Error ? `${error.name}: ${error.message}` : String(error);
}

export const HOOK_STATUS_VOCABULARY = {
  Init: "init",
  Wait: "wait",
  Ready: "ready",
  Cancelled: "cancelled",
} as const;

export type HookStatusContractName = keyof typeof HOOK_STATUS_VOCABULARY;
export type HookStatusWireValue = (typeof HOOK_STATUS_VOCABULARY)[HookStatusContractName];

// UUID SID 编解码单源在 @uvp-eth/compiler/browser（onchain/supplier-bindings.ts）。
export { supplierIdFromUuid, uuidFromSupplierId } from "@uvp-eth/compiler/browser";
export type { SupplierBindingKind };

// 签名闸门单源（三端签名前校验与用户拒绝判定的最强集），见 signing-gate.ts。
export {
  isUserRejectedRequestError,
  validateTypedDataForSigning,
  type TypedDataSigningCheck,
  type TypedDataSigningExpectation,
  type TypedDataSigningMismatchReason,
  type TypedDataSignerField,
} from "./signing-gate.js";

// 能力树造证工具（capabilitiesRoot 叶公式 / Merkle 根 / 成员证明）。
export {
  EMPTY_CAPABILITIES_ROOT,
  SIGNAL_CAPABILITY_RELATION_CURRENT_ORDER,
  UVP_SELECTOR_BINDING_V1,
  UVP_SIGNAL_CAPABILITY_V1,
  capabilitiesRootOf,
  factAttribution,
  selectorBindingLeaf,
  selectorBindingProofFor,
  signalCapabilityLeaf,
  signalCapabilityProofFor,
  type CompilerSignalCapabilityTableEntry,
  type SignalCapabilityTableEntry,
  type SignalCapabilityTableEntryInput,
  type StageSelectorBindingTableEntry,
} from "./capabilities-root.js";

export * from "./order-book.js";
export * from "./registry.js";

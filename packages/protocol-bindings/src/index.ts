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
  toHex,
  type Address,
  type Hex,
} from "viem";
import { encodeTypedDataFields } from "./order-book.js";
import type {
  FileWriterTableEntry,
  SignalCapabilityTableEntry,
  StageSelectorBindingTableEntry,
} from "./capabilities-root.js";

// 部分签名的嵌套深度超出 viem parseAbi 的类型级解析预算
// （运行时解析正常，tsc 下落入 Error 分支），这几条以等价的 JSON const
// 条目手写；条目形状与 forge 产物一致，由 artifact-abis 测试钉为产物子集。
const TRIGGER_ORDER_FROM_OUTSIDE_FOR_ABI_ENTRY = [
  {
    type: "function",
    name: "triggerOrderFromOutsideFor",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "trigger",
        type: "tuple",
        components: [
          { name: "planId", type: "bytes32" },
          { name: "creator", type: "address" },
          { name: "triggerHookId", type: "bytes32" },
          { name: "triggerStageId", type: "bytes32" },
          { name: "sourceId", type: "bytes32" },
          { name: "signalId", type: "bytes32" },
          { name: "payloadHash", type: "bytes32" },
          { name: "idempotencyKey", type: "bytes32" },
          { name: "submitter", type: "address" },
          { name: "deadline", type: "uint256" },
        ],
      },
      {
        name: "authorizations",
        type: "tuple[]",
        components: [
          { name: "sourceId", type: "bytes32" },
          { name: "signalId", type: "bytes32" },
          { name: "submitter", type: "address" },
          { name: "role", type: "bytes32" },
          { name: "metadataHash", type: "bytes32" },
        ],
      },
      { name: "signature", type: "bytes" },
      {
        name: "birthFactAttribution",
        type: "tuple",
        components: [
          { name: "sourceId", type: "bytes32" },
          { name: "signalId", type: "bytes32" },
          { name: "stageId", type: "bytes32" },
          { name: "capabilityProof", type: "bytes32[]" },
        ],
      },
    ],
  },
] as const;

const TRIGGER_ORDER_FROM_OUTSIDE_BY_AUTHORIZER_ABI_ENTRY = [
  {
    type: "function",
    name: "triggerOrderFromOutsideByAuthorizer",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "trigger",
        type: "tuple",
        components: [
          { name: "planId", type: "bytes32" },
          { name: "creator", type: "address" },
          { name: "triggerHookId", type: "bytes32" },
          { name: "triggerStageId", type: "bytes32" },
          { name: "sourceId", type: "bytes32" },
          { name: "signalId", type: "bytes32" },
          { name: "payloadHash", type: "bytes32" },
          { name: "idempotencyKey", type: "bytes32" },
          { name: "deadline", type: "uint256" },
        ],
      },
      {
        name: "authorizations",
        type: "tuple[]",
        components: [
          { name: "sourceId", type: "bytes32" },
          { name: "signalId", type: "bytes32" },
          { name: "submitter", type: "address" },
          { name: "role", type: "bytes32" },
          { name: "metadataHash", type: "bytes32" },
        ],
      },
      {
        name: "birthFactAttribution",
        type: "tuple",
        components: [
          { name: "sourceId", type: "bytes32" },
          { name: "signalId", type: "bytes32" },
          { name: "stageId", type: "bytes32" },
          { name: "capabilityProof", type: "bytes32[]" },
        ],
      },
    ],
  },
] as const;

const TRIGGER_ORDER_FROM_SIGNAL_FROM_MODULE_ABI_ENTRY = [
  {
    type: "function",
    name: "triggerOrderFromSignalFromModule",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "trigger",
        type: "tuple",
        components: [
          { name: "orderId", type: "bytes32" },
          { name: "planId", type: "bytes32" },
          { name: "creator", type: "address" },
          { name: "triggerOriginOrderId", type: "bytes32" },
          { name: "originPlanId", type: "bytes32" },
          { name: "triggerHookId", type: "bytes32" },
          { name: "triggerStageId", type: "bytes32" },
          { name: "originSourceId", type: "bytes32" },
          { name: "originSignalId", type: "bytes32" },
          { name: "payloadHash", type: "bytes32" },
          { name: "idempotencyKey", type: "bytes32" },
          { name: "submitter", type: "address" },
          { name: "deadline", type: "uint256" },
        ],
      },
      {
        name: "authorizations",
        type: "tuple[]",
        components: [
          { name: "sourceId", type: "bytes32" },
          { name: "signalId", type: "bytes32" },
          { name: "submitter", type: "address" },
          { name: "role", type: "bytes32" },
          { name: "metadataHash", type: "bytes32" },
        ],
      },
      { name: "relayer", type: "address" },
      {
        name: "originFactAttributions",
        type: "tuple[]",
        components: [
          { name: "sourceId", type: "bytes32" },
          { name: "signalId", type: "bytes32" },
          { name: "stageId", type: "bytes32" },
          { name: "capabilityProof", type: "bytes32[]" },
        ],
      },
    ],
  },
] as const;

export const STATE_MACHINE_ABI = [
  ...parseAbi([
  "event OwnershipTransferred(address indexed previousOwner,address indexed newOwner)",
  "event StateMachineModuleSet(bytes32 indexed moduleId,address indexed previousModule,address indexed newModule)",
  "event StateMachineModulesFrozen(bytes32 indexed moduleSetHash)",
  "event HookReady(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed hookId,bytes32 stageId,bytes32 hookName)",
  "event HookStatusChanged(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed hookId,uint8 previousStatus,uint8 newStatus,uint64 dueAt)",
  "event TimerPoked(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed hookId,uint64 dueAt)",
  "event SignalSubmitted(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,bytes32 factStageId)",
  "event PlanCommitted(bytes32 indexed planId,bytes32 indexed planHash,address indexed publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,uint256 hookCount,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,bytes32 executorCandidatesRoot,address birthAuthorizer)",
  "event PlanFinalized(bytes32 indexed planId,bytes32 indexed planHash,bytes32 capabilitiesRoot)",
  "event PlanRegistered(bytes32 indexed planId,bytes32 planHash,uint256 hookCount)",
  "event PlanPublisherRecorded(bytes32 indexed planId,address indexed publisher)",
  "event OrderRegistered(bytes32 indexed orderId,bytes32 indexed planId)",
  "event OrderMaterialized(bytes32 indexed orderId,bytes32 indexed planId,bytes32 indexed stageId)",
  "event OrderRelayerRecorded(bytes32 indexed planId,bytes32 orderId,address indexed relayer,address creator)",
  "event SignalSubmitterAuthorized(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)",
  "event SignalSubmitterRevoked(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed sourceId,bytes32 signalId,address submitter)",
  "event StageMaterialized(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed stageId,bytes32 triggerHookId,bytes32 sourceId,bytes32 signalId)",
  "event OrderTriggered(bytes32 indexed orderId,bytes32 indexed planId,bytes32 indexed triggerStageId,bytes32 triggerHookId,bytes32 sourceId,bytes32 signalId,address submitter)",
  "event StageExecutorActivated(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed targetStageId,address executor,bytes32 role,bytes32 metadataHash,uint256 patchNonce,string metadataURI)",
  "event OrderForked(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed parentOrderId,bytes32 approvalSourceId,bytes32 approvalSignalId,address initiator,bytes32 forkPayloadHash,bytes32[] replayedFactKeys)",
  "function owner() view returns (address)",
  "function stagePatchModule() view returns (address)",
  "function derivedSignalModule() view returns (address)",
  "function dockingModule() view returns (address)",
  "function planMetadataModule() view returns (address)",
  "function orderLinkModule() view returns (address)",
  "function fileResourceModule() view returns (address)",
  "function lens() view returns (address)",
  "function modulesFrozen() view returns (bool)",
  "function moduleSetHash() view returns (bytes32)",
  "function transferOwnership(address newOwner)",
  "function setStagePatchModule(address moduleAddress)",
  "function setDerivedSignalModule(address moduleAddress)",
  "function setDockingModule(address moduleAddress)",
  "function setPlanMetadataModule(address moduleAddress)",
  "function setOrderLinkModule(address moduleAddress)",
  "function setLens(address moduleAddress)",
  "function setFileResourceModule(address moduleAddress)",
  "function freezeModules()",
  "function commitPlan((address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,bytes32 executorCandidatesRoot,address birthAuthorizer,uint256 deadline) commit,(bytes32 hookId,bytes32 stageId,bytes32 hookName,uint8 flags,(uint8 op,bytes32 sourceId,bytes32 signalId,uint16 arity,uint64 delaySeconds)[] instructions,bytes32[] dependencyKeys)[] hooks,(bytes32 stageId,address executor)[] executorCandidates,bytes signature) returns (bytes32 planId)",
  "function finalizePlan(bytes32 planId)",
  "function planRuntimeHash(bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,bytes32 executorCandidatesRoot) pure returns (bytes32)",
  "function planIdFor(address publisher,bytes32 planHash) pure returns (bytes32)",
  "function triggerOrderIdFor(bytes32 planId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash) pure returns (bytes32)",
  "function orderLinkOrderIdFor(bytes32 planId,bytes32 originPlanId,bytes32 triggerOriginOrderId,bytes32 originSourceId,bytes32 originSignalId,bytes32 payloadHash) pure returns (bytes32)",
  "function stageHasOrderTriggerHook(bytes32 planId,bytes32 stageId) view returns (bool)",
  "function submitSignal(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof) attribution)",
  "function submitSignalFor(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline,bytes signature,(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof) attribution,bytes32 filesDigest,(bytes32 targetStageId,bytes32 baseHash,bytes32 writerStageId,bytes32[] writerProof,(uint8 kind,bytes32 key,bytes32 contentHash,string handle)[] ops) filePatch)",
  "function submitSignalFromModule(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof) attribution)",
  "function submitDerivedSignalFromModule(bytes32 planId,bytes32 orderId,bytes32 fromPlanId,bytes32 fromOrderId,bytes32 stageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter)",
  "function createDockedOrderFromModule((bytes32 targetPlanId,bytes32 linkedOrderId,address creator,address relayer,bytes32 entranceHookId,bytes32 entranceStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,(bytes32 sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)[] authorizations,(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof) entranceAttribution) request)",
  "function recordDockedInputFromModule((bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof) attribution) fact)",
  "function planHookFlags(bytes32 planId,bytes32 hookId) view returns (uint8)",
  "function planHookStageId(bytes32 planId,bytes32 hookId) view returns (bytes32)",
  "function planBirthAuthorizer(bytes32 planId) view returns (address)",
  "function planDockRoots(bytes32 planId) view returns (bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot)",
  "function activateStageExecutorFromModule(bytes32 planId,bytes32 orderId,bytes32 targetStageId,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 patchHash,uint256 patchNonce,string metadataURI)",
  "function forkOrder(bytes32 planId,bytes32 parentOrderId,bytes32 forkPayloadHash,bytes32 approvalSourceId,bytes32 approvalSignalId,(bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey)[] birthFacts,(bytes32 sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)[] authorizations) returns (bytes32 forkedOrderId)",
  "function forkOrderIdFor(bytes32 planId,bytes32 parentOrderId,bytes32 forkPayloadHash) pure returns (bytes32)",
  "function authorizeSignalSubmittersFromModule(bytes32 planId,bytes32 orderId,(bytes32 sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)[] authorizations)",
  "function authorizeDockedSignalsFromModule(bytes32 planId,bytes32 orderId,(bytes32 sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)[] authorizations)",
  "function stageSignalState(bytes32 planId,bytes32 orderId,bytes32 stageId) view returns (uint256 count,address lastSubmitter,uint64 lastAt,bool ambiguous)",
  "function orderParent(bytes32 planId,bytes32 orderId) view returns (bytes32)",
  "function planExecutorCandidatesRoot(bytes32 planId) view returns (bytes32)",
  "function SIGNAL_TARGET_CURRENT_ORDER() view returns (uint8)",
  "function SIGNAL_TARGET_TRIGGER_ORIGIN() view returns (uint8)",
  "function DOCK_ORDER_NAMESPACE_MASK() view returns (bytes32)",
  "function DERIVED_SIGNAL_MODULE_ID() view returns (bytes32)",
  "function DOCKING_MODULE_ID() view returns (bytes32)",
  "function FILE_RESOURCE_MODULE_ID() view returns (bytes32)",
  "function HOOK_FLAG_EMIT_READY() view returns (uint8)",
  "function HOOK_FLAG_ORDER_TRIGGER_DOCK() view returns (uint8)",
  "function HOOK_FLAG_ORDER_TRIGGER_MINT() view returns (uint8)",
  "function LENS_MODULE_ID() view returns (bytes32)",
  "function MAX_HOOK_DELAY_SECONDS() view returns (uint64)",
  "function MAX_PLAN_DEPENDENCIES() view returns (uint256)",
  "function ORDER_LINK_MODULE_ID() view returns (bytes32)",
  "function PLAN_METADATA_MODULE_ID() view returns (bytes32)",
  "function STAGE_PATCH_MODULE_ID() view returns (bytes32)",
  "function sourceSignalCount(bytes32 planId,bytes32 orderId,bytes32 sourceId) view returns (uint256 count)",
  "function lastSignalSubmitter(bytes32 planId,bytes32 orderId,bytes32 sourceId) view returns (address submitter)",
  "function hasSourceSignal(bytes32 planId,bytes32 orderId,bytes32 sourceId) view returns (bool)",
  "function hasTriggerOriginConsent(bytes32 originPlanId,bytes32 originOrderId,bytes32 originSourceId,bytes32 originSignalId,address party,(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof) originAttribution) view returns (bool)",
  "function DOMAIN_SEPARATOR() view returns (bytes32)",
  "function planExists(bytes32 planId) view returns (bool)",
  "function planCommitted(bytes32 planId) view returns (bool)",
  "function planFinalized(bytes32 planId) view returns (bool)",
  "function planHash(bytes32 planId) view returns (bytes32)",
  "function planPublisher(bytes32 planId) view returns (address)",
  "function orderRelayer(bytes32 planId,bytes32 orderId) view returns (address)",
  "function orderCreator(bytes32 planId,bytes32 orderId) view returns (address)",
  "function orderExists(bytes32 planId,bytes32 orderId) view returns (bool)",
  "function hasExplicitSignalAuthorization(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,address submitter) view returns (bool)",
  "function isSignalSubmitterAuthorized(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,address submitter) view returns (bool)",
  "function getSignalAuthorization(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,address submitter) view returns (bool exists,bytes32 role,bytes32 metadataHash)",
  "function hasSignal(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId) view returns (bool)",
  "function getSignal(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId) view returns (bool exists,bytes32 payloadHash,bytes32 idempotencyKey,uint64 submittedAt,address submitter)",
  "function getHookStatus(bytes32 planId,bytes32 orderId,bytes32 hookId) view returns (uint8 status,uint64 dueAt,bool readyEmitted)",
  "function activeStageExecutor(bytes32 planId,bytes32 orderId,bytes32 targetStageId) view returns (address)",
  "function pokeTimer(bytes32 planId,bytes32 orderId,bytes32 hookId)",
  "function planHookDependsOn(bytes32 planId,bytes32 hookId,bytes32 sourceId,bytes32 signalId) view returns (bool)",
  ]),
  ...TRIGGER_ORDER_FROM_OUTSIDE_FOR_ABI_ENTRY,
  ...TRIGGER_ORDER_FROM_OUTSIDE_BY_AUTHORIZER_ABI_ENTRY,
  ...TRIGGER_ORDER_FROM_SIGNAL_FROM_MODULE_ABI_ENTRY,
] as const;

const TRIGGER_ORDER_FROM_SIGNAL_FOR_ABI_ENTRY = [
  {
    type: "function",
    name: "triggerOrderFromSignalFor",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "trigger",
        type: "tuple",
        components: [
          { name: "orderId", type: "bytes32" },
          { name: "planId", type: "bytes32" },
          { name: "creator", type: "address" },
          { name: "triggerOriginOrderId", type: "bytes32" },
          { name: "originPlanId", type: "bytes32" },
          { name: "triggerHookId", type: "bytes32" },
          { name: "triggerStageId", type: "bytes32" },
          { name: "originSourceId", type: "bytes32" },
          { name: "originSignalId", type: "bytes32" },
          { name: "payloadHash", type: "bytes32" },
          { name: "idempotencyKey", type: "bytes32" },
          { name: "submitter", type: "address" },
          { name: "deadline", type: "uint256" },
        ],
      },
      {
        name: "authorizations",
        type: "tuple[]",
        components: [
          { name: "sourceId", type: "bytes32" },
          { name: "signalId", type: "bytes32" },
          { name: "submitter", type: "address" },
          { name: "role", type: "bytes32" },
          { name: "metadataHash", type: "bytes32" },
        ],
      },
      { name: "signature", type: "bytes" },
      {
        name: "originFactAttributions",
        type: "tuple[]",
        components: [
          { name: "sourceId", type: "bytes32" },
          { name: "signalId", type: "bytes32" },
          { name: "stageId", type: "bytes32" },
          { name: "capabilityProof", type: "bytes32[]" },
        ],
      },
    ],
  },
] as const;

export const ORDER_LINK_MODULE_ABI = [
  ...parseAbi([
  "event OrderLinked(bytes32 indexed triggeredOrderId,bytes32 indexed triggerOriginOrderId,bytes32 indexed triggerStageId,bytes32 planId,bytes32 originPlanId,bytes32 originSourceId,bytes32 originSignalId)",
  "function targetOrderRelation(bytes32 fromPlanId,bytes32 fromOrderId,bytes32 targetPlanId,bytes32 targetOrderId) view returns (uint8)",
  "function getTriggerOriginLink(bytes32 planId,bytes32 triggeredOrderId) view returns (bool exists,bytes32 triggerOriginOrderId,bytes32 triggerOriginPlanId,bytes32 originSourceId,bytes32 originSignalId,bytes32 triggerStageId)",
  "function signalAuthorizationsHash((bytes32 sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)[] authorizations) pure returns (bytes32)",
  "function triggerOrderFromSignalDigest((bytes32 orderId,bytes32 planId,address creator,bytes32 triggerOriginOrderId,bytes32 originPlanId,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 originSourceId,bytes32 originSignalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline) trigger,bytes32 authorizationsHash) view returns (bytes32)",
  ]),
  ...TRIGGER_ORDER_FROM_SIGNAL_FOR_ABI_ENTRY,
] as const;

const APPLY_STAGE_EXECUTOR_PATCH_FOR_ABI_ENTRY = [
  {
    type: "function",
    name: "applyStageExecutorPatchFor",
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
          { name: "executor", type: "address" },
          { name: "role", type: "bytes32" },
          { name: "executorMetadataHash", type: "bytes32" },
          { name: "mode", type: "bytes32" },
          { name: "previousExecutor", type: "address" },
          { name: "authorizationsHash", type: "bytes32" },
          { name: "patchHash", type: "bytes32" },
          { name: "patchNonce", type: "uint256" },
          { name: "metadataURI", type: "string" },
        ],
      },
      { name: "selector", type: "address" },
      { name: "deadline", type: "uint256" },
      { name: "selectorSignature", type: "bytes" },
      { name: "previousExecutorSignature", type: "bytes" },
      {
        name: "bindingProof",
        type: "tuple",
        components: [
          { name: "selectorStageId", type: "bytes32" },
          { name: "proof", type: "bytes32[]" },
        ],
      },
      { name: "candidateProof", type: "bytes32[]" },
      {
        name: "executorAuthorizations",
        type: "tuple[]",
        components: [
          { name: "sourceId", type: "bytes32" },
          { name: "signalId", type: "bytes32" },
          { name: "submitter", type: "address" },
          { name: "role", type: "bytes32" },
          { name: "metadataHash", type: "bytes32" },
        ],
      },
    ],
  },
] as const;

export const STAGE_PATCH_MODULE_ABI = [
  ...parseAbi([
  "event StageExecutorPatchApplied(bytes32 indexed orderId,bytes32 indexed selectorStageId,bytes32 indexed targetStageId,bytes32 planId,address selector,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 mode,address previousExecutor,bytes32 authorizationsHash,bytes32 patchHash,uint256 patchNonce,string metadataURI)",
  "function EXECUTOR_PATCH_SIGNAL_ID() view returns (bytes32)",
  "function EXECUTOR_PATCH_MODE_ASSIGN() view returns (bytes32)",
  "function EXECUTOR_PATCH_MODE_HANDOFF() view returns (bytes32)",
  "function applyStageExecutorPatch(bytes32 planId,bytes32 orderId,(bytes32 selectorStageId,bytes32 targetStageId,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 mode,address previousExecutor,bytes32 authorizationsHash,bytes32 patchHash,uint256 patchNonce,string metadataURI) patch,(bytes32 selectorStageId,bytes32[] proof) bindingProof,bytes32[] candidateProof,(bytes32 sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)[] executorAuthorizations)",
  "function stageExecutorPatchDigest(bytes32 planId,bytes32 orderId,(bytes32 selectorStageId,bytes32 targetStageId,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 mode,address previousExecutor,bytes32 authorizationsHash,bytes32 patchHash,uint256 patchNonce,string metadataURI) patch,address selector,uint256 deadline) view returns (bytes32)",
  "function getActiveStageExecutorPatch(bytes32 planId,bytes32 orderId,bytes32 targetStageId) view returns (bool exists,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 patchHash,uint256 patchNonce,string metadataURI)",
  ]),
  ...APPLY_STAGE_EXECUTOR_PATCH_FOR_ABI_ENTRY,
] as const;

export const DERIVED_SIGNAL_MODULE_ABI = parseAbi([
  "event DerivedSignalSubmitted(bytes32 indexed fromOrderId,bytes32 indexed targetOrderId,bytes32 indexed signalId,bytes32 fromPlanId,bytes32 targetPlanId,bytes32 fromStageId,bytes32 targetSourceId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint8 relation)",
  "struct DerivedSignalRequest {bytes32 fromPlanId;bytes32 fromOrderId;bytes32 fromStageId;bytes32 targetPlanId;bytes32 targetOrderId;bytes32 targetSourceId;bytes32 signalId;bytes32 payloadHash;bytes32 idempotencyKey}",
  "function submitDerivedSignal(DerivedSignalRequest request,address submitter,(bytes32[] fromCapabilityProof,bytes32[] targetCapabilityProof) proofs)",
  "function submitDerivedSignalFor(DerivedSignalRequest request,address submitter,uint256 deadline,bytes signature,(bytes32[] fromCapabilityProof,bytes32[] targetCapabilityProof) proofs)",
  "function derivedSignalDigest(DerivedSignalRequest request,address submitter,uint256 deadline) view returns (bytes32)",
]);

export const DOCKING_MODULE_ABI = parseAbi([
  "event DockOpened(bytes32 indexed dockInstanceId,bytes32 indexed localOrderId,bytes32 indexed linkedOrderId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 targetPlanId,bytes32 routeId,bytes32 routeHash,uint8 depth,address opener)",
  "event DockAttached(bytes32 indexed dockInstanceId,bytes32 indexed localOrderId,bytes32 indexed linkedOrderId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 targetPlanId,bytes32 routeId,bytes32 routeHash,uint8 depth,address attacher)",
  "event DockInputSubmitted(bytes32 indexed dockInstanceId,bytes32 indexed linkedOrderId,bytes32 indexed inputBindingHash,bytes32 localPlanId,bytes32 localOrderId,bytes32 targetPlanId,bytes32 targetSignalId,bytes32 payloadHash,address submitter)",
  "event DockOutputSubmitted(bytes32 indexed dockInstanceId,bytes32 indexed linkedOrderId,bytes32 indexed outputBindingHash,bytes32 localPlanId,bytes32 localOrderId,bytes32 targetPlanId,bytes32 targetSignalId,bytes32 localSignalId,bytes32 payloadHash,address submitter)",
  "event DockOutputSatisfied(bytes32 indexed dockInstanceId,bytes32 indexed linkedOrderId,bytes32 indexed outputBindingHash,bytes32 localPlanId,bytes32 localOrderId,bytes32 targetPlanId,bytes32 targetSignalId,bytes32 localSignalId,bytes32 payloadHash,address submitter)",
  "event DockOrderSignalsAuthorized(bytes32 indexed dockInstanceId,bytes32 indexed targetPlanId,bytes32 indexed linkedOrderId,uint256 count,bytes32 authorizationHash)",
  "function openDockedOrder(((bytes32 dockInstanceId,bytes32 localPlanId,bytes32 localOrderId,bytes32 localStageId,bytes32 localHookId,bytes32 localDefinitionRefHash,bytes32 routeId,bytes32 routeHash,bytes32 interfaceNameId,bytes32 targetUidId,bytes32 targetDefinitionRefHash,bytes32 targetPlanId,bytes32 linkedOrderId,bytes32 targetStageId,bytes32 targetHookId,uint8 parentDepth) request,bytes32[] routeProof,((bytes32 leafHash,bytes32 portKey,bytes32 hookKey) entranceLeaf,bytes32[] portProof,(uint8 orderModesWord,bytes32 inputsRoot,bytes32 outputsRoot) commitment,bytes32[] interfaceProof) interfaceProof,(bytes32 localHookId,bytes32 portKey,bytes32 targetSourceId,bytes32 targetSignalId,bytes32 bindingHash)[] inputs,(bytes32 localSourceId,bytes32 localSignalId,bytes32 portKey,bytes32 targetSourceId,bytes32 targetSignalId,bytes32 bindingHash,bytes32[] portProof)[] outputs,((uint256 nonce,uint256 deadline,bytes signature) permit,(uint256 nonce,uint256 deadline,bytes signature) consent) authorization,(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof)[] outputAttributions,(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof) entranceAttribution) call) returns (bool opened)",
  "function attachDockedOrder((bytes32 dockInstanceId,bytes32 localPlanId,bytes32 localOrderId,bytes32 localStageId,bytes32 localDefinitionRefHash,bytes32 routeId,bytes32 routeHash,bytes32 interfaceNameId,bytes32 targetUidId,bytes32 targetDefinitionRefHash,bytes32 targetPlanId,bytes32 linkedOrderId,bytes32 targetStageId,uint8 parentDepth,bytes32 targetCandidatesRoot) request,bytes32[] routeProof,((uint8 orderModesWord,bytes32 inputsRoot,bytes32 outputsRoot) commitment,bytes32[] interfaceProof,bytes32[] candidateProof) attachProof,(bytes32 localHookId,bytes32 portKey,bytes32 targetSourceId,bytes32 targetSignalId,bytes32 bindingHash,bytes32 targetHookId,bytes32[] portProof)[] inputs,(bytes32 localSourceId,bytes32 localSignalId,bytes32 portKey,bytes32 targetSourceId,bytes32 targetSignalId,bytes32 bindingHash,bytes32[] portProof)[] outputs,(uint256 nonce,uint256 deadline,bytes signature) permit,(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof)[] outputAttributions) returns (bool attached)",
  "function submitDockedInput(bytes32 dockInstanceId,bytes32 localHookId,bytes32 inputBindingHash,(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof) attribution) returns (bool submitted)",
  "function submitDockedSignal(bytes32 dockInstanceId,bytes32 outputBindingHash,(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof) attribution) returns (bool submitted)",
  "function authorizeDockedOrderSignals(bytes32 dockInstanceId,(bytes32 sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)[] authorizations)",
  "function getActiveDock(bytes32 dockInstanceId) view returns (bytes32 localPlanId,bytes32 localOrderId,bytes32 localStageId,bytes32 routeId,bytes32 routeHash,bytes32 targetPlanId,bytes32 linkedOrderId,bytes32 interfaceNameId,uint8 depth,bool exists)",
  "function getDockInputBinding(bytes32 dockInstanceId,bytes32 inputBindingHash) view returns (bytes32 localHookId,bytes32 portKey,bytes32 targetSourceId,bytes32 targetSignalId,bool exists)",
  "function getDockOutputBinding(bytes32 dockInstanceId,bytes32 outputBindingHash) view returns (bytes32 localSourceId,bytes32 localSignalId,bytes32 portKey,bytes32 targetSourceId,bytes32 targetSignalId,bool exists)",
  "function dockInputDelivered(bytes32 dockInstanceId,bytes32 inputBindingHash) view returns (bool)",
  "function dockOutputDelivered(bytes32 dockInstanceId,bytes32 outputBindingHash) view returns (bool)",
  "function dockByLocalRoute(bytes32 localRouteInstanceKey) view returns (bytes32)",
  "function dockByTargetOrder(bytes32 targetEndpointKey) view returns (bytes32)",
  "function dockEdgeCountOfOrder(bytes32 planId,bytes32 orderId) view returns (uint8)",
  "function dockParentOfOrder(bytes32 planId,bytes32 orderId) view returns (bytes32)",
  "function usedOpenConsentNonce(bytes32 dockInstanceId) view returns (uint256)",
  "function usedEntrancePermitNonce(bytes32 dockInstanceId) view returns (uint256)",
  "function DOCK_MODE_NEW() view returns (uint8)",
  "function DOCK_MODE_EXISTING() view returns (uint8)",
  "function DOCK_INTERFACE_ORDER_MODE_NEW() view returns (uint8)",
  "function DOCK_INTERFACE_ORDER_MODE_EXISTING() view returns (uint8)",
  "function MAX_DOCK_OUTPUTS() view returns (uint8)",
  "function MAX_DOCK_EDGES() view returns (uint8)",
  "function entrancePermitDigest(bytes32 targetPlanId,bytes32 targetEntrancePortId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 routeHash,bytes32 dockInstanceId,bytes32 linkedOrderId,uint256 nonce,uint256 deadline) view returns (bytes32)",
  "function attachPermitDigest(bytes32 targetPlanId,bytes32 targetOrderId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 routeHash,bytes32 dockInstanceId,uint256 nonce,uint256 deadline) view returns (bytes32)",
  "function openConsentDigest(bytes32 targetPlanId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 localOrderId,bytes32 routeId,bytes32 routeHash,bytes32 dockInstanceId,bytes32 linkedOrderId,uint256 nonce,uint256 deadline) view returns (bytes32)",
  "function DOMAIN_SEPARATOR() view returns (bytes32)",
  "function stateMachine() view returns (address)",
  "function planMetadataModule() view returns (address)",
]);

export const STATE_MACHINE_LENS_ABI = parseAbi([
  "function stateMachine() view returns (address)",
  "function getActiveStageExecutorPatch(bytes32 planId,bytes32 orderId,bytes32 targetStageId) view returns (bool exists,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 patchHash,uint256 patchNonce,string metadataURI)",
  "function getActiveDock(bytes32 dockInstanceId) view returns (bytes32 localPlanId,bytes32 localOrderId,bytes32 localStageId,bytes32 routeId,bytes32 routeHash,bytes32 targetPlanId,bytes32 linkedOrderId,bytes32 interfaceNameId,uint8 depth,bool exists)",
  "function getDockInputBinding(bytes32 dockInstanceId,bytes32 inputBindingHash) view returns (bytes32 localHookId,bytes32 portKey,bytes32 targetSourceId,bytes32 targetSignalId,bool exists)",
  "function getDockOutputBinding(bytes32 dockInstanceId,bytes32 outputBindingHash) view returns (bytes32 localSourceId,bytes32 localSignalId,bytes32 portKey,bytes32 targetSourceId,bytes32 targetSignalId,bool exists)",
  "function dockInputDelivered(bytes32 dockInstanceId,bytes32 inputBindingHash) view returns (bool)",
  "function dockOutputDelivered(bytes32 dockInstanceId,bytes32 outputBindingHash) view returns (bool)",
  "function planCapabilitiesRoot(bytes32 planId) view returns (bytes32)",
  "function planHasCapabilityVocabulary(bytes32 planId) view returns (bool)",
  "function verifySignalCapability(bytes32 planId,bytes32 stageId,bytes32 targetSourceId,bytes32 signalId,uint8 relation,bytes32[] proof) view returns (bool)",
  "function verifyStageSelectorBinding(bytes32 planId,bytes32 selectorStageId,bytes32 targetStageId,bytes32[] proof) view returns (bool)",
  "function targetOrderRelation(bytes32 fromPlanId,bytes32 fromOrderId,bytes32 targetPlanId,bytes32 targetOrderId) view returns (uint8)",
  "function getTriggerOriginLink(bytes32 planId,bytes32 triggeredOrderId) view returns (bool exists,bytes32 triggerOriginOrderId,bytes32 triggerOriginPlanId,bytes32 originSourceId,bytes32 originSignalId,bytes32 triggerStageId)",
]);

export const PRODUCT_SUBMIT_DOMAIN_NAME = "UVPStateMachine";
export const PRODUCT_SUBMIT_DOMAIN_VERSION = "0.16";
export const PRODUCT_SUBMIT_PRIMARY_TYPE = "UVPStateMachineSignal";
export const PLAN_COMMIT_PRIMARY_TYPE = "UVPStateMachinePlanCommit";
export const TRIGGER_ORDER_FROM_OUTSIDE_PRIMARY_TYPE =
  "UVPStateMachineTriggerOrderFromOutside";
export const ORDER_LINK_DOMAIN_NAME = "UVPOrderLinkModule";
export const ORDER_LINK_DOMAIN_VERSION = "0.8";
export const TRIGGER_ORDER_FROM_SIGNAL_PRIMARY_TYPE =
  "UVPOrderLinkModuleTriggerOrderFromSignal";
export const DERIVED_SIGNAL_DOMAIN_NAME = "UVPDerivedSignalModule";
export const DERIVED_SIGNAL_DOMAIN_VERSION = "0.6";
export const DERIVED_SIGNAL_PRIMARY_TYPE = "UVPDerivedSignalModuleSignal";
export const STAGE_EXECUTOR_PATCH_DOMAIN_NAME = "UVPStagePatchModule";
export const STAGE_EXECUTOR_PATCH_DOMAIN_VERSION = "0.2";
export const STAGE_EXECUTOR_PATCH_PRIMARY_TYPE =
  "UVPStagePatchModuleStageExecutorPatch";
export const STAGE_EXECUTOR_PATCH_PAYLOAD_HASH_DOMAIN =
  "uvp:stage-executor-patch-payload:v1";
import {
  HOOK_FLAG_EMIT_READY,
  HOOK_FLAG_ORDER_TRIGGER_DOCK,
  HOOK_FLAG_ORDER_TRIGGER_MINT,
} from "./artifact-abis.js";
export {
  FILE_RESOURCE_MODULE_ABI,
  HOOK_FLAG_EMIT_READY,
  HOOK_FLAG_ORDER_TRIGGER_DOCK,
  HOOK_FLAG_ORDER_TRIGGER_MINT,
  SIGNAL_SUBMITTED_ABI,
  SIGNAL_SUBMITTED_TOPIC,
  UVP_STATE_MACHINE_ARTIFACT_ABI,
} from "./artifact-abis.js";

export type OrderTriggerKind = "mint" | "dock";

export interface CompactHookFlagsInput {
  /** 出生订阅语义：mint=出生订阅上链（SIGNAL 指令），dock=docking 入口。 */
  readonly orderTriggerKind?: OrderTriggerKind | null;
  /** Ready 事件外发口径：order-trigger hook 必须携带，watcher 可选。 */
  readonly emitReady?: boolean;
}

// CompactHook.flags 位标志口径：1=ORDER_TRIGGER_MINT，2=ORDER_TRIGGER_DOCK，
// 4=EMIT_READY；位值由生成代码钉住合约常量，MINT/DOCK 互斥由合约注册边界
// 校验（InvalidHook），trigger 缺 EMIT_READY 由 SilentOrderTriggerHook 拒绝。
export function buildCompactHookFlags(
  input: CompactHookFlagsInput = {},
): number {
  let flags = 0;
  if (input.orderTriggerKind === "mint") {
    flags |= HOOK_FLAG_ORDER_TRIGGER_MINT;
  }
  if (input.orderTriggerKind === "dock") {
    flags |= HOOK_FLAG_ORDER_TRIGGER_DOCK;
  }
  if (input.emitReady) {
    flags |= HOOK_FLAG_EMIT_READY;
  }
  return flags;
}
export const EXECUTOR_PATCH_MODE_ASSIGN = stringToHex("assign", {
  size: 32,
}) as Hex;
export const EXECUTOR_PATCH_MODE_HANDOFF = stringToHex("handoff", {
  size: 32,
}) as Hex;

export interface ProductSubmitTypedDataField {
  readonly name: string;
  readonly type: string;
}

// UVPStateMachineSignal 签名绑定 (planId, orderId)。
export const PRODUCT_SUBMIT_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] =
  [
    { name: "planId", type: "bytes32" },
    { name: "orderId", type: "bytes32" },
    { name: "sourceId", type: "bytes32" },
    { name: "signalId", type: "bytes32" },
    { name: "payloadHash", type: "bytes32" },
    { name: "idempotencyKey", type: "bytes32" },
    { name: "submitter", type: "address" },
    { name: "deadline", type: "uint256" },
    { name: "filesDigest", type: "bytes32" },
  ];

export const PRODUCT_SUBMIT_TYPE_HASH: Hex = keccak256(
  stringToHex(
    encodeTypedDataFields(
      PRODUCT_SUBMIT_PRIMARY_TYPE,
      PRODUCT_SUBMIT_TYPED_DATA_FIELDS,
    ),
  ),
);

export const PLAN_COMMIT_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] =
  [
    { name: "publisher", type: "address" },
    { name: "hooksHash", type: "bytes32" },
    { name: "capabilitiesRoot", type: "bytes32" },
    { name: "dockRoutesRoot", type: "bytes32" },
    { name: "dockInterfaceRoot", type: "bytes32" },
    { name: "executorCandidatesRoot", type: "bytes32" },
    { name: "birthAuthorizer", type: "address" },
    { name: "deadline", type: "uint256" },
  ];

export const TRIGGER_ORDER_FROM_OUTSIDE_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] =
  [
    { name: "planId", type: "bytes32" },
    { name: "creator", type: "address" },
    { name: "triggerHookId", type: "bytes32" },
    { name: "triggerStageId", type: "bytes32" },
    { name: "sourceId", type: "bytes32" },
    { name: "signalId", type: "bytes32" },
    { name: "payloadHash", type: "bytes32" },
    { name: "idempotencyKey", type: "bytes32" },
    { name: "authorizationsHash", type: "bytes32" },
    { name: "submitter", type: "address" },
    { name: "deadline", type: "uint256" },
  ];

export const TRIGGER_ORDER_FROM_SIGNAL_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] =
  [
    { name: "orderId", type: "bytes32" },
    { name: "planId", type: "bytes32" },
    { name: "creator", type: "address" },
    { name: "triggerOriginOrderId", type: "bytes32" },
    { name: "originPlanId", type: "bytes32" },
    { name: "triggerHookId", type: "bytes32" },
    { name: "triggerStageId", type: "bytes32" },
    { name: "originSourceId", type: "bytes32" },
    { name: "originSignalId", type: "bytes32" },
    { name: "payloadHash", type: "bytes32" },
    { name: "idempotencyKey", type: "bytes32" },
    { name: "authorizationsHash", type: "bytes32" },
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

export const STAGE_EXECUTOR_PATCH_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] =
  [
    { name: "planId", type: "bytes32" },
    { name: "orderId", type: "bytes32" },
    { name: "selectorStageId", type: "bytes32" },
    { name: "targetStageId", type: "bytes32" },
    { name: "executor", type: "address" },
    { name: "role", type: "bytes32" },
    { name: "executorMetadataHash", type: "bytes32" },
    { name: "mode", type: "bytes32" },
    { name: "previousExecutor", type: "address" },
    { name: "authorizationsHash", type: "bytes32" },
    { name: "patchHash", type: "bytes32" },
    { name: "patchNonce", type: "uint256" },
    { name: "metadataURI", type: "string" },
    { name: "selector", type: "address" },
    { name: "deadline", type: "uint256" },
  ];

export const FILE_PATCH_DIGEST_DOMAIN = "UVP_FILE_PATCH_V1";

export type FileOpKind = 0 | 1 | 2;

export const FILE_OP_KIND = {
  add: 0,
  replace: 1,
  remove: 2,
} as const;

export interface FileOp {
  readonly kind: FileOpKind;
  readonly key: Hex;
  readonly contentHash: Hex;
  readonly handle: string;
}

export interface FilePatch {
  readonly targetStageId: Hex;
  readonly baseHash: Hex;
  readonly writerStageId: Hex;
  readonly writerProof: readonly Hex[];
  readonly ops: readonly FileOp[];
}

export interface FileOpCallStruct {
  readonly kind: FileOpKind;
  readonly key: Hex;
  readonly contentHash: Hex;
  readonly handle: string;
}

export interface FilePatchCallStruct {
  readonly targetStageId: Hex;
  readonly baseHash: Hex;
  readonly writerStageId: Hex;
  readonly writerProof: readonly Hex[];
  readonly ops: readonly FileOpCallStruct[];
}

export const FILE_OPS_LIMIT = 16;
export const FILE_HANDLE_MAX_BYTES = 512;

export function filePatchDigest(
  planId: Hex | string,
  orderId: Hex | string,
  filePatch: FilePatch,
): Hex {
  const patch = normalizeFilePatchCallStruct(filePatch);
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters(
        "bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,(uint8,bytes32,bytes32,string)[]",
      ),
      [
        keccak256(stringToHex(FILE_PATCH_DIGEST_DOMAIN)),
        normalizeBytes32(planId, "planId"),
        normalizeBytes32(orderId, "orderId"),
        patch.targetStageId,
        patch.baseHash,
        patch.writerStageId,
        patch.ops.map((op) => [op.kind, op.key, op.contentHash, op.handle]),
      ] as never,
    ),
  );
}

export interface ProductSubmitTypedData {
  readonly domain: {
    readonly name: typeof PRODUCT_SUBMIT_DOMAIN_NAME;
    readonly version: typeof PRODUCT_SUBMIT_DOMAIN_VERSION;
    readonly chainId: number;
    readonly verifyingContract: Address;
  };
  readonly types: {
    readonly UVPStateMachineSignal: readonly ProductSubmitTypedDataField[];
  };
  readonly primaryType: typeof PRODUCT_SUBMIT_PRIMARY_TYPE;
  readonly message: {
    readonly planId: Hex;
    readonly orderId: Hex;
    readonly sourceId: Hex;
    readonly signalId: Hex;
    readonly payloadHash: Hex;
    readonly idempotencyKey: Hex;
    readonly submitter: Address;
    readonly deadline: string;
    readonly filesDigest: Hex;
  };
}

// PlanCommit 的能力承诺面是 capabilitiesRoot（空表归一化为
// EMPTY_CAPABILITIES_ROOT，见 capabilities-root.ts）：两表 Merkle 化形态下只有
// 树根进入发布者签名，表内容按使用方"重算叶 + 携 proof"验证。
export interface PlanCommitPayload {
  readonly publisher: Address | string;
  readonly hooksHash: Hex | string;
  readonly capabilitiesRoot: Hex | string;
  readonly dockRoutesRoot: Hex | string;
  readonly dockInterfaceRoot: Hex | string;
  /** 执行者候选集树根（UB-36②③）：空集归一化为 EMPTY_ROOT。 */
  readonly executorCandidatesRoot: Hex | string;
  /**
   * 出生授权者（0.15 承诺域）：outside 出生提交的唯一被授权 submitter，
   * 只进 commit digest 与存储，不进 planRuntimeHash。零地址 = 关闭 outside
   * 出生通道。
   */
  readonly birthAuthorizer: Address | string;
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
    readonly dockRoutesRoot: Hex;
    readonly dockInterfaceRoot: Hex;
    readonly executorCandidatesRoot: Hex;
    readonly birthAuthorizer: Address;
    readonly deadline: string;
  };
}

export interface SignalAuthorizationPayload {
  readonly sourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly submitter: Address | string;
  readonly role: Hex | string;
  readonly metadataHash: Hex | string;
}

// 一事一单：orderId 由合约 triggerOrderIdFor(planId, sourceId,
// signalId, payloadHash) 纯函数派生（本包导出同公式镜像 deriveTriggerOrderId）。
export interface TriggerOrderFromOutsidePayload {
  readonly planId: Hex | string;
  readonly creator: Address | string;
  readonly triggerHookId: Hex | string;
  readonly triggerStageId: Hex | string;
  readonly sourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly payloadHash: Hex | string;
  readonly idempotencyKey: Hex | string;
  readonly submitter: Address | string;
  readonly deadline: bigint | number | string;
}

export interface TriggerOrderFromOutsideByAuthorizerPayload {
  readonly planId: Hex | string;
  readonly creator: Address | string;
  readonly triggerHookId: Hex | string;
  readonly triggerStageId: Hex | string;
  readonly sourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly payloadHash: Hex | string;
  readonly idempotencyKey: Hex | string;
  readonly deadline: bigint | number | string;
}

export interface TriggerOrderFromSignalPayload {
  readonly orderId: Hex | string;
  readonly planId: Hex | string;
  readonly creator: Address | string;
  readonly triggerOriginOrderId: Hex | string;
  readonly originPlanId: Hex | string;
  readonly triggerHookId: Hex | string;
  readonly triggerStageId: Hex | string;
  readonly originSourceId: Hex | string;
  readonly originSignalId: Hex | string;
  readonly payloadHash: Hex | string;
  readonly idempotencyKey: Hex | string;
  readonly submitter: Address | string;
  readonly deadline: bigint | number | string;
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

export interface TriggerOrderFromOutsideTypedData {
  readonly domain: ProductSubmitTypedData["domain"];
  readonly types: {
    readonly UVPStateMachineTriggerOrderFromOutside: readonly ProductSubmitTypedDataField[];
  };
  readonly primaryType: typeof TRIGGER_ORDER_FROM_OUTSIDE_PRIMARY_TYPE;
  readonly message: {
    readonly planId: Hex;
    readonly creator: Address;
    readonly triggerHookId: Hex;
    readonly triggerStageId: Hex;
    readonly sourceId: Hex;
    readonly signalId: Hex;
    readonly payloadHash: Hex;
    readonly idempotencyKey: Hex;
    readonly authorizationsHash: Hex;
    readonly submitter: Address;
    readonly deadline: string;
  };
}

export interface TriggerOrderFromSignalTypedData {
  readonly domain: {
    readonly name: typeof ORDER_LINK_DOMAIN_NAME;
    readonly version: typeof ORDER_LINK_DOMAIN_VERSION;
    readonly chainId: number;
    readonly verifyingContract: Address;
  };
  readonly types: {
    readonly UVPOrderLinkModuleTriggerOrderFromSignal: readonly ProductSubmitTypedDataField[];
  };
  readonly primaryType: typeof TRIGGER_ORDER_FROM_SIGNAL_PRIMARY_TYPE;
  readonly message: {
    readonly orderId: Hex;
    readonly planId: Hex;
    readonly creator: Address;
    readonly triggerOriginOrderId: Hex;
    readonly originPlanId: Hex;
    readonly triggerHookId: Hex;
    readonly triggerStageId: Hex;
    readonly originSourceId: Hex;
    readonly originSignalId: Hex;
    readonly payloadHash: Hex;
    readonly idempotencyKey: Hex;
    readonly authorizationsHash: Hex;
    readonly submitter: Address;
    readonly deadline: string;
  };
}

export interface StageExecutorPatchPayload {
  readonly selectorStageId: Hex | string;
  readonly targetStageId: Hex | string;
  readonly executor: Address | string;
  readonly role: Hex | string;
  readonly executorMetadataHash: Hex | string;
  readonly mode: Hex | string;
  readonly previousExecutor: Address | string;
  /** patch 生效时对新城执行者写入的授权集哈希（UB-36①，进 EIP-712 摘要）。 */
  readonly authorizationsHash: Hex | string;
  readonly patchNonce: bigint | number | string;
  readonly metadataURI: string;
}

export interface StageExecutorPatchCallPatch extends StageExecutorPatchPayload {
  readonly patchHash: Hex | string;
}

export interface StageExecutorPatchTypedData {
  readonly domain: {
    readonly name: typeof STAGE_EXECUTOR_PATCH_DOMAIN_NAME;
    readonly version: typeof STAGE_EXECUTOR_PATCH_DOMAIN_VERSION;
    readonly chainId: number;
    readonly verifyingContract: Address;
  };
  readonly types: {
    readonly UVPStagePatchModuleStageExecutorPatch: readonly ProductSubmitTypedDataField[];
  };
  readonly primaryType: typeof STAGE_EXECUTOR_PATCH_PRIMARY_TYPE;
  readonly message: {
    readonly planId: Hex;
    readonly orderId: Hex;
    readonly selectorStageId: Hex;
    readonly targetStageId: Hex;
    readonly executor: Address;
    readonly role: Hex;
    readonly executorMetadataHash: Hex;
    readonly mode: Hex;
    readonly previousExecutor: Address;
    readonly authorizationsHash: Hex;
    readonly patchHash: Hex;
    readonly patchNonce: string;
    readonly metadataURI: string;
    readonly selector: Address;
    readonly deadline: string;
  };
}

export interface BuildProductSubmitTypedDataInput {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
  /**
   * 签名域并入 planId：submitSignal 按 (planId, orderId) 复合键锚定订单，
   * 缺 planId 的签名过不了链上存在性校验，没有可接受的缺省形态。
   */
  readonly planId: Hex | string;
  readonly orderId: Hex | string;
  readonly sourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly payloadHash: Hex | string;
  readonly idempotencyKey: Hex | string;
  readonly submitter: Address | string;
  readonly deadline: string;
  readonly filesDigest?: Hex | string;
}

export interface BuildPlanCommitTypedDataInput extends PlanCommitPayload {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
}

export interface BuildTriggerOrderFromOutsideTypedDataInput
  extends TriggerOrderFromOutsidePayload {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
  readonly authorizations: readonly SignalAuthorizationPayload[];
}

export interface BuildTriggerOrderFromSignalTypedDataInput
  extends TriggerOrderFromSignalPayload {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
  readonly authorizations: readonly SignalAuthorizationPayload[];
}

export interface BuildDerivedSignalTypedDataInput
  extends DerivedSignalPayload {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
}

export interface BuildStageExecutorPatchTypedDataInput
  extends StageExecutorPatchCallPatch {
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
// submitSignal 族与 docked/derived 提交面已收敛为 anchored 词表语义，
// 不再随交易携带 selector 绑定证明。
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

export interface SubmitSignalForCallArgs {
  readonly planId: Hex | string;
  readonly orderId: Hex | string;
  readonly sourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly payloadHash: Hex | string;
  readonly idempotencyKey: Hex | string;
  readonly submitter: Address | string;
  readonly deadline: bigint | number | string;
  readonly signature: Hex | string;
  readonly attribution: SignalAttributionPayload;
  readonly filesDigest?: Hex | string;
  readonly filePatch?: FilePatch;
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

// 派生信号提交的两端能力证明（target 侧仅 relation!=0 时需要）。
export interface DerivedSignalProofsPayload {
  readonly fromCapabilityProof: readonly (Hex | string)[];
  readonly targetCapabilityProof: readonly (Hex | string)[];
}

export interface DerivedSignalProofsCallStruct {
  readonly fromCapabilityProof: readonly Hex[];
  readonly targetCapabilityProof: readonly Hex[];
}

function normalizeDerivedSignalProofs(
  proofs: DerivedSignalProofsPayload,
): DerivedSignalProofsCallStruct {
  return {
    fromCapabilityProof: proofs.fromCapabilityProof.map((word, index) =>
      normalizeBytes32(word, `proofs.fromCapabilityProof[${index}]`),
    ),
    targetCapabilityProof: proofs.targetCapabilityProof.map((word, index) =>
      normalizeBytes32(word, `proofs.targetCapabilityProof[${index}]`),
    ),
  };
}

export interface TriggerOrderFromOutsideForCallArgs
  extends TriggerOrderFromOutsidePayload {
  readonly authorizations: readonly SignalAuthorizationPayload[];
  readonly signature: Hex | string;
  /** 出生事实的属主自证（stageId=0 表示不主张，由合约按词表回退解析）。 */
  readonly birthFactAttribution: SignalAttributionPayload;
}

export interface TriggerOrderFromOutsideByAuthorizerCallArgs
  extends TriggerOrderFromOutsideByAuthorizerPayload {
  readonly authorizations: readonly SignalAuthorizationPayload[];
  readonly birthFactAttribution: SignalAttributionPayload;
}

export interface TriggerOrderFromSignalForCallArgs
  extends TriggerOrderFromSignalPayload {
  readonly authorizations: readonly SignalAuthorizationPayload[];
  readonly signature: Hex | string;
  /** 触发源单事实的属主自证列表（stageId=0 项表示不主张）。 */
  readonly originFactAttributions: readonly SignalAttributionPayload[];
}

export interface ApplyStageExecutorPatchForCallArgs {
  readonly planId: Hex | string;
  readonly orderId: Hex | string;
  readonly patch: StageExecutorPatchCallPatch;
  readonly selector: Address | string;
  readonly deadline: bigint | number | string;
  readonly selectorSignature: Hex | string;
  readonly previousExecutorSignature: Hex | string;
  readonly bindingProof: SelectorBindingPayload;
  /** 候选集成员证明（UB-36②③）。 */
  readonly candidateProof: readonly (Hex | string)[];
  /** patch 生效时对新城执行者写入的显式授权集（UB-36①）。 */
  readonly executorAuthorizations: readonly SignalAuthorizationPayload[];
}


export interface SubmitSignalForCallConfig {
  readonly stateMachineAddress: Address | string;
  readonly chainId?: number;
}

export interface StagePatchModuleCallConfig {
  readonly stagePatchModuleAddress: Address | string;
  readonly chainId?: number;
}

export interface DerivedSignalModuleCallConfig {
  readonly derivedSignalModuleAddress: Address | string;
  readonly chainId?: number;
}

export interface OrderLinkModuleCallConfig {
  readonly orderLinkModuleAddress: Address | string;
  readonly chainId?: number;
}

export type ApplyStageExecutorPatchForCallConfig = StagePatchModuleCallConfig;
export type SubmitDerivedSignalForCallConfig = DerivedSignalModuleCallConfig;
export type TriggerOrderFromOutsideForCallConfig = SubmitSignalForCallConfig;
export type TriggerOrderFromOutsideByAuthorizerCallConfig =
  SubmitSignalForCallConfig;
export type TriggerOrderFromSignalForCallConfig = OrderLinkModuleCallConfig;

export interface SubmitSignalForCall {
  readonly address: Address;
  readonly abi: typeof STATE_MACHINE_ABI;
  readonly functionName: "submitSignalFor";
  readonly args: readonly [
    Hex,
    Hex,
    Hex,
    Hex,
    Hex,
    Hex,
    Address,
    bigint,
    Hex,
    SignalAttributionCallStruct,
    Hex,
    FilePatchCallStruct,
  ];
  readonly data: Hex;
  readonly chainId?: number;
}

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

export type SignalAuthorizationCallTuple = readonly [
  Hex,
  Hex,
  Address,
  Hex,
  Hex,
];

export interface SignalAuthorizationCallStruct {
  readonly sourceId: Hex;
  readonly signalId: Hex;
  readonly submitter: Address;
  readonly role: Hex;
  readonly metadataHash: Hex;
}

export type TriggerOrderFromOutsideCallTuple = readonly [
  Hex,
  Address,
  Hex,
  Hex,
  Hex,
  Hex,
  Hex,
  Hex,
  Address,
  bigint,
];

export type TriggerOrderFromOutsideByAuthorizerCallTuple = readonly [
  Hex,
  Address,
  Hex,
  Hex,
  Hex,
  Hex,
  Hex,
  Hex,
  bigint,
];

export type TriggerOrderFromSignalCallTuple = readonly [
  Hex,
  Hex,
  Address,
  Hex,
  Hex,
  Hex,
  Hex,
  Hex,
  Hex,
  Hex,
  Hex,
  Address,
  bigint,
];

export interface TriggerOrderFromSignalCallStruct {
  readonly orderId: Hex;
  readonly planId: Hex;
  readonly creator: Address;
  readonly triggerOriginOrderId: Hex;
  readonly originPlanId: Hex;
  readonly triggerHookId: Hex;
  readonly triggerStageId: Hex;
  readonly originSourceId: Hex;
  readonly originSignalId: Hex;
  readonly payloadHash: Hex;
  readonly idempotencyKey: Hex;
  readonly submitter: Address;
  readonly deadline: bigint;
}

export interface TriggerOrderFromOutsideForCall {
  readonly address: Address;
  readonly abi: typeof STATE_MACHINE_ABI;
  readonly functionName: "triggerOrderFromOutsideFor";
  readonly args: readonly [
    TriggerOrderFromOutsideCallTuple,
    readonly SignalAuthorizationCallTuple[],
    Hex,
    SignalAttributionCallStruct,
  ];
  readonly data: Hex;
  readonly chainId?: number;
}

export interface TriggerOrderFromOutsideByAuthorizerCall {
  readonly address: Address;
  readonly abi: typeof STATE_MACHINE_ABI;
  readonly functionName: "triggerOrderFromOutsideByAuthorizer";
  readonly args: readonly [
    TriggerOrderFromOutsideByAuthorizerCallTuple,
    readonly SignalAuthorizationCallTuple[],
    SignalAttributionCallStruct,
  ];
  readonly data: Hex;
  readonly chainId?: number;
}

export interface TriggerOrderFromSignalForCall {
  readonly address: Address;
  readonly abi: typeof ORDER_LINK_MODULE_ABI;
  readonly functionName: "triggerOrderFromSignalFor";
  readonly args: readonly [
    TriggerOrderFromSignalCallStruct,
    readonly SignalAuthorizationCallStruct[],
    Hex,
    readonly SignalAttributionCallStruct[],
  ];
  readonly data: Hex;
  readonly chainId?: number;
}

export type StageExecutorPatchCallTuple = readonly [
  Hex,
  Hex,
  Address,
  Hex,
  Hex,
  Hex,
  Address,
  Hex,
  Hex,
  bigint,
  string,
];

export interface ApplyStageExecutorPatchForCall {
  readonly address: Address;
  readonly abi: typeof STAGE_PATCH_MODULE_ABI;
  readonly functionName: "applyStageExecutorPatchFor";
  readonly args: readonly [
    Hex,
    Hex,
    StageExecutorPatchCallTuple,
    Address,
    bigint,
    Hex,
    Hex,
    SelectorBindingCallStruct,
    readonly Hex[],
    readonly SignalAuthorizationCallStruct[],
  ];
  readonly data: Hex;
  readonly chainId?: number;
}




const BYTES32_RE = /^0x[a-fA-F0-9]{64}$/;
const ZERO_BYTES32 = `0x${"0".repeat(64)}` as Hex;
const ZERO_ADDRESS = `0x${"0".repeat(40)}` as Address;

export const EMPTY_FILE_PATCH: FilePatch = {
  targetStageId: ZERO_BYTES32,
  baseHash: ZERO_BYTES32,
  writerStageId: ZERO_BYTES32,
  writerProof: [],
  ops: [],
};

function normalizeFileOpCallStruct(op: FileOp): FileOpCallStruct {
  if (op.kind !== FILE_OP_KIND.add && op.kind !== FILE_OP_KIND.replace && op.kind !== FILE_OP_KIND.remove) {
    throw new Error("filePatch.ops[].kind must be 0 (add), 1 (replace), or 2 (remove)");
  }
  if (typeof op.handle !== "string") {
    throw new Error("filePatch.ops[].handle must be a string");
  }
  return {
    kind: op.kind,
    key: normalizeBytes32(op.key, "filePatch.ops[].key"),
    contentHash: normalizeBytes32(op.contentHash, "filePatch.ops[].contentHash"),
    handle: op.handle,
  };
}

function normalizeFilePatchCallStruct(
  filePatch: FilePatch,
): FilePatchCallStruct {
  if (!Array.isArray(filePatch.ops)) {
    throw new Error("filePatch.ops must be an array");
  }
  if (!Array.isArray(filePatch.writerProof)) {
    throw new Error("filePatch.writerProof must be an array");
  }
  return {
    targetStageId: normalizeBytes32(filePatch.targetStageId, "filePatch.targetStageId"),
    baseHash: normalizeBytes32(filePatch.baseHash, "filePatch.baseHash"),
    writerStageId: normalizeBytes32(filePatch.writerStageId, "filePatch.writerStageId"),
    writerProof: filePatch.writerProof.map((word, index) =>
      normalizeBytes32(word, `filePatch.writerProof[${index}]`),
    ),
    ops: filePatch.ops.map(normalizeFileOpCallStruct),
  };
}

function normalizeSubmitFiles(
  planId: Hex,
  orderId: Hex,
  filesDigest: Hex | string | undefined,
  filePatch: FilePatch | undefined,
): readonly [Hex, FilePatchCallStruct] {
  const patch = normalizeFilePatchCallStruct(filePatch ?? EMPTY_FILE_PATCH);
  if (patch.ops.length === 0) {
    const digest =
      filesDigest === undefined
        ? ZERO_BYTES32
        : normalizeBytes32(filesDigest, "filesDigest");
    if (digest !== ZERO_BYTES32) {
      throw new Error("filesDigest must be zero when filePatch carries no ops");
    }
    return [ZERO_BYTES32, patch];
  }
  if (filesDigest === undefined) {
    throw new Error("filesDigest is required when filePatch carries ops");
  }
  const digest = normalizeBytes32(filesDigest, "filesDigest");
  const expected = filePatchDigest(planId, orderId, {
    targetStageId: patch.targetStageId,
    baseHash: patch.baseHash,
    writerStageId: patch.writerStageId,
    writerProof: patch.writerProof,
    ops: patch.ops,
  });
  if (digest !== expected) {
    throw new Error(
      "filesDigest must equal filePatchDigest(planId, orderId, filePatch)",
    );
  }
  return [digest, patch];
}

const EXECUTOR_PATCH_MODE_BY_NAME: Readonly<Record<string, Hex>> = {
  assign: EXECUTOR_PATCH_MODE_ASSIGN,
  handoff: EXECUTOR_PATCH_MODE_HANDOFF,
};
const EXECUTOR_PATCH_MODE_VALUE_SET = new Set<Hex>([
  EXECUTOR_PATCH_MODE_ASSIGN,
  EXECUTOR_PATCH_MODE_HANDOFF,
]);

export function buildProductSubmitTypedData(
  input: BuildProductSubmitTypedDataInput,
): ProductSubmitTypedData {
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
      UVPStateMachineSignal: PRODUCT_SUBMIT_TYPED_DATA_FIELDS,
    },
    primaryType: PRODUCT_SUBMIT_PRIMARY_TYPE,
    message: {
      planId: normalizeBytes32(input.planId, "planId"),
      orderId: normalizeBytes32(input.orderId, "orderId"),
      sourceId: normalizeBytes32(input.sourceId, "sourceId"),
      signalId: normalizeBytes32(input.signalId, "signalId"),
      payloadHash: normalizeBytes32(input.payloadHash, "payloadHash"),
      idempotencyKey: normalizeBytes32(input.idempotencyKey, "idempotencyKey"),
      submitter: normalizeAddress(input.submitter, "submitter"),
      deadline: normalizeUintString(input.deadline, "deadline"),
      filesDigest:
        input.filesDigest === undefined
          ? ZERO_BYTES32
          : normalizeBytes32(input.filesDigest, "filesDigest"),
    },
  };
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
      dockRoutesRoot: normalizeBytes32(input.dockRoutesRoot, "dockRoutesRoot"),
      dockInterfaceRoot: normalizeBytes32(input.dockInterfaceRoot, "dockInterfaceRoot"),
      executorCandidatesRoot: normalizeBytes32(input.executorCandidatesRoot, "executorCandidatesRoot"),
      birthAuthorizer: normalizeAddress(input.birthAuthorizer, "birthAuthorizer"),
      deadline: normalizeUintString(input.deadline, "deadline"),
    },
  };
}

export function buildTriggerOrderFromOutsideTypedData(
  input: BuildTriggerOrderFromOutsideTypedDataInput,
): TriggerOrderFromOutsideTypedData {
  const trigger = normalizeTriggerOrderFromOutside(input);
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
      UVPStateMachineTriggerOrderFromOutside:
        TRIGGER_ORDER_FROM_OUTSIDE_TYPED_DATA_FIELDS,
    },
    primaryType: TRIGGER_ORDER_FROM_OUTSIDE_PRIMARY_TYPE,
    message: {
      planId: trigger[0],
      creator: trigger[1],
      triggerHookId: trigger[2],
      triggerStageId: trigger[3],
      sourceId: trigger[4],
      signalId: trigger[5],
      payloadHash: trigger[6],
      idempotencyKey: trigger[7],
      authorizationsHash: hashSignalAuthorizations(input.authorizations),
      submitter: trigger[8],
      deadline: trigger[9].toString(10),
    },
  };
}

export function buildTriggerOrderFromSignalTypedData(
  input: BuildTriggerOrderFromSignalTypedDataInput,
): TriggerOrderFromSignalTypedData {
  const trigger = normalizeTriggerOrderFromSignal(input);
  return {
    domain: {
      name: ORDER_LINK_DOMAIN_NAME,
      version: ORDER_LINK_DOMAIN_VERSION,
      chainId: normalizeChainId(input.chainId),
      verifyingContract: normalizeAddress(
        input.verifyingContract,
        "verifyingContract",
      ),
    },
    types: {
      UVPOrderLinkModuleTriggerOrderFromSignal:
        TRIGGER_ORDER_FROM_SIGNAL_TYPED_DATA_FIELDS,
    },
    primaryType: TRIGGER_ORDER_FROM_SIGNAL_PRIMARY_TYPE,
    message: {
      orderId: trigger[0],
      planId: trigger[1],
      creator: trigger[2],
      triggerOriginOrderId: trigger[3],
      originPlanId: trigger[4],
      triggerHookId: trigger[5],
      triggerStageId: trigger[6],
      originSourceId: trigger[7],
      originSignalId: trigger[8],
      payloadHash: trigger[9],
      idempotencyKey: trigger[10],
      authorizationsHash: hashSignalAuthorizations(input.authorizations),
      submitter: trigger[11],
      deadline: trigger[12].toString(10),
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

export function buildStageExecutorPatchTypedData(
  input: BuildStageExecutorPatchTypedDataInput,
): StageExecutorPatchTypedData {
  const patch = normalizeStageExecutorPatch(input);
  return {
    domain: {
      name: STAGE_EXECUTOR_PATCH_DOMAIN_NAME,
      version: STAGE_EXECUTOR_PATCH_DOMAIN_VERSION,
      chainId: normalizeChainId(input.chainId),
      verifyingContract: normalizeAddress(
        input.verifyingContract,
        "verifyingContract",
      ),
    },
    types: {
      UVPStagePatchModuleStageExecutorPatch:
        STAGE_EXECUTOR_PATCH_TYPED_DATA_FIELDS,
    },
    primaryType: STAGE_EXECUTOR_PATCH_PRIMARY_TYPE,
    message: {
      planId: normalizeBytes32(input.planId, "planId"),
      orderId: normalizeBytes32(input.orderId, "orderId"),
      selectorStageId: patch[0],
      targetStageId: patch[1],
      executor: patch[2],
      role: patch[3],
      executorMetadataHash: patch[4],
      mode: patch[5],
      previousExecutor: patch[6],
      authorizationsHash: patch[7],
      patchHash: patch[8],
      patchNonce: patch[9].toString(10),
      metadataURI: patch[10],
      selector: normalizeAddress(input.selector, "selector"),
      deadline: normalizeUintString(input.deadline, "deadline"),
    },
  };
}


export async function recoverProductSubmitSigner(
  typedData: ProductSubmitTypedData,
  signature: Hex | string,
): Promise<Address> {
  const recovered = await recoverTypedDataAddress({
    domain: typedData.domain,
    types: typedData.types,
    primaryType: typedData.primaryType,
    message: typedData.message,
    signature: normalizeHex(signature, "signature"),
  } as unknown as Parameters<typeof recoverTypedDataAddress>[0]);
  return normalizeAddress(recovered, "recoveredSubmitter");
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

export async function recoverTriggerOrderFromOutsideSigner(
  typedData: TriggerOrderFromOutsideTypedData,
  signature: Hex | string,
): Promise<Address> {
  const recovered = await recoverTypedDataAddress({
    domain: typedData.domain,
    types: typedData.types,
    primaryType: typedData.primaryType,
    message: typedData.message,
    signature: normalizeHex(signature, "signature"),
  } as unknown as Parameters<typeof recoverTypedDataAddress>[0]);
  return normalizeAddress(recovered, "recoveredTriggerOrderSigner");
}

export async function recoverTriggerOrderFromSignalSigner(
  typedData: TriggerOrderFromSignalTypedData,
  signature: Hex | string,
): Promise<Address> {
  const recovered = await recoverTypedDataAddress({
    domain: typedData.domain,
    types: typedData.types,
    primaryType: typedData.primaryType,
    message: typedData.message,
    signature: normalizeHex(signature, "signature"),
  } as unknown as Parameters<typeof recoverTypedDataAddress>[0]);
  return normalizeAddress(recovered, "recoveredTriggerOrderSigner");
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

export async function recoverStageExecutorPatchSigner(
  typedData: StageExecutorPatchTypedData,
  signature: Hex | string,
): Promise<Address> {
  const recovered = await recoverTypedDataAddress({
    domain: typedData.domain,
    types: typedData.types,
    primaryType: typedData.primaryType,
    message: typedData.message,
    signature: normalizeHex(signature, "signature"),
  } as unknown as Parameters<typeof recoverTypedDataAddress>[0]);
  return normalizeAddress(recovered, "recoveredStageExecutorPatchSigner");
}


export function buildSubmitSignalForCall(
  config: SubmitSignalForCallConfig,
  args: SubmitSignalForCallArgs,
): SubmitSignalForCall {
  const planId = normalizeBytes32(args.planId, "planId");
  const orderId = normalizeBytes32(args.orderId, "orderId");
  const normalizedArgs = [
    planId,
    orderId,
    normalizeBytes32(args.sourceId, "sourceId"),
    normalizeBytes32(args.signalId, "signalId"),
    normalizeBytes32(args.payloadHash, "payloadHash"),
    normalizeBytes32(args.idempotencyKey, "idempotencyKey"),
    normalizeAddress(args.submitter, "submitter"),
    normalizeUintBigInt(args.deadline, "deadline"),
    normalizeHex(args.signature, "signature"),
    normalizeSignalAttribution(args.attribution),
    ...normalizeSubmitFiles(planId, orderId, args.filesDigest, args.filePatch),
  ] as const satisfies readonly [
    Hex,
    Hex,
    Hex,
    Hex,
    Hex,
    Hex,
    Address,
    bigint,
    Hex,
    SignalAttributionCallStruct,
    Hex,
    FilePatchCallStruct,
  ];

  return {
    address: normalizeAddress(
      config.stateMachineAddress,
      "stateMachineAddress",
    ),
    abi: STATE_MACHINE_ABI,
    functionName: "submitSignalFor",
    args: normalizedArgs,
    data: encodeFunctionData({
      abi: STATE_MACHINE_ABI,
      functionName: "submitSignalFor",
      args: normalizedArgs,
    }),
    ...(config.chainId !== undefined
      ? { chainId: normalizeChainId(config.chainId) }
      : {}),
  };
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

export function buildTriggerOrderFromOutsideForCall(
  config: TriggerOrderFromOutsideForCallConfig,
  args: TriggerOrderFromOutsideForCallArgs,
): TriggerOrderFromOutsideForCall {
  const normalizedArgs = [
    normalizeTriggerOrderFromOutside(args),
    args.authorizations.map(normalizeSignalAuthorization),
    normalizeHex(args.signature, "signature"),
    normalizeSignalAttribution(args.birthFactAttribution),
  ] as const;

  return {
    address: normalizeAddress(
      config.stateMachineAddress,
      "stateMachineAddress",
    ),
    abi: STATE_MACHINE_ABI,
    functionName: "triggerOrderFromOutsideFor",
    args: normalizedArgs,
    data: encodeFunctionData({
      abi: STATE_MACHINE_ABI,
      functionName: "triggerOrderFromOutsideFor",
      args: normalizedArgs,
    }),
    ...(config.chainId !== undefined
      ? { chainId: normalizeChainId(config.chainId) }
      : {}),
  };
}

export function buildTriggerOrderFromOutsideByAuthorizerCall(
  config: TriggerOrderFromOutsideByAuthorizerCallConfig,
  args: TriggerOrderFromOutsideByAuthorizerCallArgs,
): TriggerOrderFromOutsideByAuthorizerCall {
  const normalizedArgs = [
    normalizeTriggerOrderFromOutsideByAuthorizer(args),
    args.authorizations.map(normalizeSignalAuthorization),
    normalizeSignalAttribution(args.birthFactAttribution),
  ] as const;

  return {
    address: normalizeAddress(
      config.stateMachineAddress,
      "stateMachineAddress",
    ),
    abi: STATE_MACHINE_ABI,
    functionName: "triggerOrderFromOutsideByAuthorizer",
    args: normalizedArgs,
    data: encodeFunctionData({
      abi: STATE_MACHINE_ABI,
      functionName: "triggerOrderFromOutsideByAuthorizer",
      args: normalizedArgs,
    }),
    ...(config.chainId !== undefined
      ? { chainId: normalizeChainId(config.chainId) }
      : {}),
  };
}

export function buildTriggerOrderFromSignalForCall(
  config: TriggerOrderFromSignalForCallConfig,
  args: TriggerOrderFromSignalForCallArgs,
): TriggerOrderFromSignalForCall {
  const trigger = normalizeTriggerOrderFromSignalStruct(args);
  const normalizedArgs = [
    trigger,
    args.authorizations.map(normalizeSignalAuthorizationStruct),
    normalizeHex(args.signature, "signature"),
    args.originFactAttributions.map(normalizeSignalAttribution),
  ] as const;

  return {
    address: normalizeAddress(
      config.orderLinkModuleAddress,
      "orderLinkModuleAddress",
    ),
    abi: ORDER_LINK_MODULE_ABI,
    functionName: "triggerOrderFromSignalFor",
    args: normalizedArgs,
    data: encodeFunctionData({
      abi: ORDER_LINK_MODULE_ABI,
      functionName: "triggerOrderFromSignalFor",
      args: normalizedArgs,
    }),
    ...(config.chainId !== undefined
      ? { chainId: normalizeChainId(config.chainId) }
      : {}),
  };
}

export function buildApplyStageExecutorPatchForCall(
  config: ApplyStageExecutorPatchForCallConfig,
  args: ApplyStageExecutorPatchForCallArgs,
): ApplyStageExecutorPatchForCall {
  const normalizedArgs = [
    normalizeBytes32(args.planId, "planId"),
    normalizeBytes32(args.orderId, "orderId"),
    normalizeStageExecutorPatch(args.patch),
    normalizeAddress(args.selector, "selector"),
    normalizeUintBigInt(args.deadline, "deadline"),
    normalizeHex(args.selectorSignature, "selectorSignature"),
    normalizeHex(args.previousExecutorSignature, "previousExecutorSignature"),
    normalizeSelectorBinding(args.bindingProof),
    args.candidateProof.map((word, index) =>
      normalizeBytes32(word, `candidateProof[${index}]`),
    ),
    args.executorAuthorizations.map(normalizeSignalAuthorizationStruct),
  ] as const;

  return {
    address: normalizeAddress(
      config.stagePatchModuleAddress,
      "stagePatchModuleAddress",
    ),
    abi: STAGE_PATCH_MODULE_ABI,
    functionName: "applyStageExecutorPatchFor",
    args: normalizedArgs,
    data: encodeFunctionData({
      abi: STAGE_PATCH_MODULE_ABI,
      functionName: "applyStageExecutorPatchFor",
      args: normalizedArgs as never,
    }),
    ...(config.chainId !== undefined
      ? { chainId: normalizeChainId(config.chainId) }
      : {}),
  };
}

export function hashStageExecutorPatchPayload(
  payload: StageExecutorPatchPayload,
): Hex {
  const normalized = normalizeStageExecutorPatchPayload(payload);
  // 域分离：payload 哈希以 keccak256(STAGE_EXECUTOR_PATCH_PAYLOAD_HASH_DOMAIN)
  // 开头——域常量必须真正进入 preimage，只在定义处引用等于没有分域。
  return keccak256(
    encodeAbiParameters(
      [
        { name: "domain", type: "bytes32" },
        { name: "selectorStageId", type: "bytes32" },
        { name: "targetStageId", type: "bytes32" },
        { name: "executor", type: "address" },
        { name: "role", type: "bytes32" },
        { name: "executorMetadataHash", type: "bytes32" },
        { name: "mode", type: "bytes32" },
        { name: "previousExecutor", type: "address" },
        { name: "authorizationsHash", type: "bytes32" },
        { name: "patchNonce", type: "uint256" },
        { name: "metadataURI", type: "string" },
      ],
      [
        keccak256(stringToHex(STAGE_EXECUTOR_PATCH_PAYLOAD_HASH_DOMAIN)),
        normalized.selectorStageId,
        normalized.targetStageId,
        normalized.executor,
        normalized.role,
        normalized.executorMetadataHash,
        normalized.mode,
        normalized.previousExecutor,
        normalized.authorizationsHash,
        BigInt(normalized.patchNonce),
        normalized.metadataURI,
      ],
    ),
  );
}



/**
 * 一事一单：outside 触发订单 id 的派生公式——镜像
 * UVPStateMachine.triggerOrderIdFor。keccak256(abi.encode(planId, sourceId,
 * signalId, payloadHash)) 并清除 dock 子单命名空间保留位（最高位）。
 */
export function deriveTriggerOrderId(
  planId: Hex | string,
  sourceId: Hex | string,
  signalId: Hex | string,
  payloadHash: Hex | string,
): Hex {
  const digest = keccak256(
    encodeAbiParameters(
      parseAbiParameters("bytes32, bytes32, bytes32, bytes32"),
      [
        normalizeBytes32(planId, "planId"),
        normalizeBytes32(sourceId, "sourceId"),
        normalizeBytes32(signalId, "signalId"),
        normalizeBytes32(payloadHash, "payloadHash"),
      ],
    ),
  );
  const DOCK_ORDER_NAMESPACE_MASK = 1n << 255n;
  const derived = BigInt(digest) & ~DOCK_ORDER_NAMESPACE_MASK;
  return toHex(derived, { size: 32 }) as Hex;
}

/**
 * 一事一单：order-link 派生订单 id 的派生公式——镜像
 * UVPStateMachine.orderLinkOrderIdFor。独立哈希域
 * keccak256("uvp.order_link.order_id.v1") 前置 keccak256(abi.encode(planId,
 * originPlanId, triggerOriginOrderId, originSourceId, originSignalId,
 * payloadHash))，并清除 dock 子单命名空间保留位（最高位）；trigger 单的
 * 自报 orderId 与派生值不一致即 revert InvalidOrderLinkOrderId。
 */
export function deriveOrderLinkOrderId(
  planId: Hex | string,
  originPlanId: Hex | string,
  triggerOriginOrderId: Hex | string,
  originSourceId: Hex | string,
  originSignalId: Hex | string,
  payloadHash: Hex | string,
): Hex {
  const digest = keccak256(
    encodeAbiParameters(
      parseAbiParameters(
        "bytes32, bytes32, bytes32, bytes32, bytes32, bytes32, bytes32",
      ),
      [
        keccak256(stringToHex("uvp.order_link.order_id.v1")),
        normalizeBytes32(planId, "planId"),
        normalizeBytes32(originPlanId, "originPlanId"),
        normalizeBytes32(triggerOriginOrderId, "triggerOriginOrderId"),
        normalizeBytes32(originSourceId, "originSourceId"),
        normalizeBytes32(originSignalId, "originSignalId"),
        normalizeBytes32(payloadHash, "payloadHash"),
      ],
    ),
  );
  const DOCK_ORDER_NAMESPACE_MASK = 1n << 255n;
  const derived = BigInt(digest) & ~DOCK_ORDER_NAMESPACE_MASK;
  return toHex(derived, { size: 32 }) as Hex;
}

export function hashSignalAuthorizations(
  authorizations: readonly SignalAuthorizationPayload[],
): Hex {
  let rollingHash = keccak256(
    encodeAbiParameters(
      [{ name: "length", type: "uint256" }],
      [BigInt(authorizations.length)],
    ),
  );
  for (const authorization of authorizations) {
    const normalized = normalizeSignalAuthorization(authorization);
    rollingHash = keccak256(
      encodeAbiParameters(
        [
          { name: "rollingHash", type: "bytes32" },
          { name: "sourceId", type: "bytes32" },
          { name: "signalId", type: "bytes32" },
          { name: "submitter", type: "address" },
          { name: "role", type: "bytes32" },
          { name: "metadataHash", type: "bytes32" },
        ],
        [
          rollingHash,
          normalized[0],
          normalized[1],
          normalized[2],
          normalized[3],
          normalized[4],
        ],
      ),
    );
  }
  return rollingHash;
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

function normalizeStageExecutorPatchMode(value: Hex | string): Hex {
  if (typeof value === "string") {
    const namedMode = EXECUTOR_PATCH_MODE_BY_NAME[value.trim().toLowerCase()];
    if (namedMode !== undefined) {
      return namedMode;
    }
  }

  const normalized = normalizeBytes32(value, "mode");
  if (!EXECUTOR_PATCH_MODE_VALUE_SET.has(normalized)) {
    throw new Error("mode must be assign or handoff");
  }
  return normalized;
}

function normalizeSignalAuthorization(
  authorization: SignalAuthorizationPayload,
): SignalAuthorizationCallTuple {
  return [
    // 零字闸镜像：UVPStateMachine._authorizeSignalSubmitter 对
    // sourceId==0 revert ZeroSourceId（sourceId==0 的事实键绕过
    // _signalStageId，等于签出一扇永久豁免门）——与 signalId 同口径拒绝。
    normalizeNonZeroBytes32(authorization.sourceId, "authorization.sourceId"),
    normalizeNonZeroBytes32(authorization.signalId, "authorization.signalId"),
    normalizeAddress(authorization.submitter, "authorization.submitter"),
    normalizeBytes32(authorization.role, "authorization.role"),
    normalizeBytes32(authorization.metadataHash, "authorization.metadataHash"),
  ] as const;
}

function normalizeSignalAuthorizationStruct(
  authorization: SignalAuthorizationPayload,
): SignalAuthorizationCallStruct {
  const tuple = normalizeSignalAuthorization(authorization);
  return {
    sourceId: tuple[0],
    signalId: tuple[1],
    submitter: tuple[2],
    role: tuple[3],
    metadataHash: tuple[4],
  };
}

function normalizeTriggerOrderFromOutside(
  trigger: TriggerOrderFromOutsidePayload,
): TriggerOrderFromOutsideCallTuple {
  return [
    normalizeNonZeroBytes32(trigger.planId, "planId"),
    normalizeAddress(trigger.creator, "creator"),
    normalizeNonZeroBytes32(trigger.triggerHookId, "triggerHookId"),
    normalizeNonZeroBytes32(trigger.triggerStageId, "triggerStageId"),
    // 零字闸镜像：triggerOrderFromOutsideFor 对 sourceId==0 revert
    // ZeroSourceId（零字出生事实是 stage 物化与 executor 门的永久豁免键）。
    normalizeNonZeroBytes32(trigger.sourceId, "sourceId"),
    normalizeNonZeroBytes32(trigger.signalId, "signalId"),
    normalizeBytes32(trigger.payloadHash, "payloadHash"),
    normalizeBytes32(trigger.idempotencyKey, "idempotencyKey"),
    normalizeAddress(trigger.submitter, "submitter"),
    normalizeUintBigInt(trigger.deadline, "deadline"),
  ] as const;
}

function normalizeTriggerOrderFromOutsideByAuthorizer(
  trigger: TriggerOrderFromOutsideByAuthorizerPayload,
): TriggerOrderFromOutsideByAuthorizerCallTuple {
  return [
    normalizeNonZeroBytes32(trigger.planId, "planId"),
    normalizeAddress(trigger.creator, "creator"),
    normalizeNonZeroBytes32(trigger.triggerHookId, "triggerHookId"),
    normalizeNonZeroBytes32(trigger.triggerStageId, "triggerStageId"),
    normalizeNonZeroBytes32(trigger.sourceId, "sourceId"),
    normalizeNonZeroBytes32(trigger.signalId, "signalId"),
    normalizeBytes32(trigger.payloadHash, "payloadHash"),
    normalizeBytes32(trigger.idempotencyKey, "idempotencyKey"),
    normalizeUintBigInt(trigger.deadline, "deadline"),
  ] as const;
}

function normalizeTriggerOrderFromSignal(
  trigger: TriggerOrderFromSignalPayload,
): TriggerOrderFromSignalCallTuple {
  return [
    normalizeNonZeroBytes32(trigger.orderId, "orderId"),
    normalizeNonZeroBytes32(trigger.planId, "planId"),
    normalizeAddress(trigger.creator, "creator"),
    normalizeNonZeroBytes32(
      trigger.triggerOriginOrderId,
      "triggerOriginOrderId",
    ),
    normalizeNonZeroBytes32(trigger.originPlanId, "originPlanId"),
    normalizeNonZeroBytes32(trigger.triggerHookId, "triggerHookId"),
    normalizeNonZeroBytes32(trigger.triggerStageId, "triggerStageId"),
    normalizeBytes32(trigger.originSourceId, "originSourceId"),
    normalizeNonZeroBytes32(trigger.originSignalId, "originSignalId"),
    normalizeBytes32(trigger.payloadHash, "payloadHash"),
    normalizeBytes32(trigger.idempotencyKey, "idempotencyKey"),
    normalizeAddress(trigger.submitter, "submitter"),
    normalizeUintBigInt(trigger.deadline, "deadline"),
  ] as const;
}

function normalizeTriggerOrderFromSignalStruct(
  trigger: TriggerOrderFromSignalPayload,
): TriggerOrderFromSignalCallStruct {
  const tuple = normalizeTriggerOrderFromSignal(trigger);
  return {
    orderId: tuple[0],
    planId: tuple[1],
    creator: tuple[2],
    triggerOriginOrderId: tuple[3],
    originPlanId: tuple[4],
    triggerHookId: tuple[5],
    triggerStageId: tuple[6],
    originSourceId: tuple[7],
    originSignalId: tuple[8],
    payloadHash: tuple[9],
    idempotencyKey: tuple[10],
    submitter: tuple[11],
    deadline: tuple[12],
  };
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

function normalizeStageExecutorPatch(
  patch: StageExecutorPatchCallPatch,
): StageExecutorPatchCallTuple {
  if (typeof patch.metadataURI !== "string") {
    throw new Error("metadataURI must be a string");
  }
  const executor = normalizeAddress(patch.executor, "executor");
  if (executor === ZERO_ADDRESS) {
    throw new Error("executor must be non-zero");
  }
  return [
    normalizeNonZeroBytes32(patch.selectorStageId, "selectorStageId"),
    normalizeNonZeroBytes32(patch.targetStageId, "targetStageId"),
    executor,
    normalizeBytes32(patch.role, "role"),
    normalizeBytes32(patch.executorMetadataHash, "executorMetadataHash"),
    normalizeStageExecutorPatchMode(patch.mode),
    normalizeAddress(patch.previousExecutor, "previousExecutor"),
    normalizeBytes32(patch.authorizationsHash, "authorizationsHash"),
    normalizeNonZeroBytes32(patch.patchHash, "patchHash"),
    normalizeUintBigInt(patch.patchNonce, "patchNonce"),
    patch.metadataURI,
  ] as const;
}

function normalizeStageExecutorPatchPayload(
  payload: StageExecutorPatchPayload,
): {
  readonly selectorStageId: Hex;
  readonly targetStageId: Hex;
  readonly executor: Address;
  readonly role: Hex;
  readonly executorMetadataHash: Hex;
  readonly mode: Hex;
  readonly previousExecutor: Address;
  readonly authorizationsHash: Hex;
  readonly patchNonce: string;
  readonly metadataURI: string;
} {
  if (typeof payload.metadataURI !== "string") {
    throw new Error("metadataURI must be a string");
  }
  const executor = normalizeAddress(payload.executor, "executor");
  if (executor === ZERO_ADDRESS) {
    throw new Error("executor must be non-zero");
  }
  return {
    selectorStageId: normalizeNonZeroBytes32(
      payload.selectorStageId,
      "selectorStageId",
    ),
    targetStageId: normalizeNonZeroBytes32(
      payload.targetStageId,
      "targetStageId",
    ),
    executor,
    role: normalizeBytes32(payload.role, "role"),
    executorMetadataHash: normalizeBytes32(
      payload.executorMetadataHash,
      "executorMetadataHash",
    ),
    mode: normalizeStageExecutorPatchMode(payload.mode),
    previousExecutor: normalizeAddress(
      payload.previousExecutor,
      "previousExecutor",
    ),
    authorizationsHash: normalizeBytes32(
      payload.authorizationsHash,
      "authorizationsHash",
    ),
    patchNonce: normalizeUintString(payload.patchNonce, "patchNonce"),
    metadataURI: payload.metadataURI,
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

export interface PlanRegistrationExecutorCandidate {
  readonly stageId: Hex | string;
  readonly executor: Address | string;
}

export interface PlanRegistrationArgs {
  readonly planId: Hex | string;
  readonly planHash: Hex | string;
  readonly hooksHash: Hex | string;
  readonly capabilitiesRoot: Hex | string;
  readonly dockRoutesRoot: Hex | string;
  readonly dockInterfaceRoot: Hex | string;
  readonly executorCandidatesRoot: Hex | string;
  readonly hooks: readonly PlanRegistrationHook[];
  readonly executorCandidates: readonly PlanRegistrationExecutorCandidate[];
}

export interface PlanRegistrationSource {
  readonly planHash: Hex | string;
  readonly hooksHash: Hex | string;
  readonly capabilitiesRoot: Hex | string;
  readonly dockRoutesRoot: Hex | string;
  readonly dockInterfaceRoot: Hex | string;
  readonly executorCandidatesRoot: Hex | string;
  readonly hooks: readonly PlanRegistrationHook[];
  readonly executorCandidates: readonly PlanRegistrationExecutorCandidate[];
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
    dockRoutesRoot: source.dockRoutesRoot,
    dockInterfaceRoot: source.dockInterfaceRoot,
    executorCandidatesRoot: source.executorCandidatesRoot,
    hooks: source.hooks,
    executorCandidates: source.executorCandidates,
  };
}

export interface PlanCommitCallArgs {
  readonly publisher: Address | string;
  readonly birthAuthorizer?: Address | string;
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
  readonly dockRoutesRoot: Hex;
  readonly dockInterfaceRoot: Hex;
  readonly executorCandidatesRoot: Hex;
  readonly birthAuthorizer: Address;
  readonly deadline: bigint;
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
  args: Pick<PlanCommitCallArgs, "publisher" | "birthAuthorizer" | "deadline" | "registration">,
): PlanCommitTypedData {
  const commit = planCommitTuple(config, args);
  return buildPlanCommitTypedData({
    chainId: planTypedDataChainId(config.chainId),
    verifyingContract: normalizeAddressChecksummed(config.stateMachineAddress, "stateMachineAddress"),
    publisher: commit.publisher,
    hooksHash: commit.hooksHash,
    capabilitiesRoot: commit.capabilitiesRoot,
    dockRoutesRoot: commit.dockRoutesRoot,
    dockInterfaceRoot: commit.dockInterfaceRoot,
    executorCandidatesRoot: commit.executorCandidatesRoot,
    birthAuthorizer: commit.birthAuthorizer,
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
  const executorCandidates = args.registration.executorCandidates.map((candidate) => ({
    stageId: normalizeBytes32(candidate.stageId, "executorCandidates[].stageId"),
    executor: normalizeAddressChecksummed(candidate.executor, "executorCandidates[].executor"),
  }));
  const data = encodeFunctionData({
    abi: STATE_MACHINE_ABI,
    functionName: "commitPlan",
    args: [commit, hooks, executorCandidates, signature],
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
  args: Pick<PlanCommitCallArgs, "publisher" | "birthAuthorizer" | "deadline" | "registration">,
): PlanCommitTuple {
  const publisher = normalizeAddressChecksummed(args.publisher, "publisher");
  return {
    publisher,
    hooksHash: normalizeBytes32(args.registration.hooksHash, "hooksHash"),
    capabilitiesRoot: normalizeBytes32(args.registration.capabilitiesRoot, "capabilitiesRoot"),
    dockRoutesRoot: normalizeBytes32(args.registration.dockRoutesRoot, "dockRoutesRoot"),
    dockInterfaceRoot: normalizeBytes32(args.registration.dockInterfaceRoot, "dockInterfaceRoot"),
    executorCandidatesRoot: normalizeBytes32(
      args.registration.executorCandidatesRoot,
      "executorCandidatesRoot",
    ),
    birthAuthorizer: args.birthAuthorizer === undefined
      ? publisher
      : normalizeAddressChecksummed(args.birthAuthorizer, "birthAuthorizer"),
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
  SIGNAL_CAPABILITY_RELATION_TRIGGER_ORIGIN,
  UVP_FILE_WRITER_V1,
  UVP_SELECTOR_BINDING_V1,
  UVP_SIGNAL_CAPABILITY_V1,
  capabilitiesRootOf,
  factAttribution,
  fileWriterLeaf,
  fileWriterProofFor,
  selectorBindingLeaf,
  selectorBindingProofFor,
  signalCapabilityLeaf,
  type FileWriterTableEntry,
  type SignalCapabilityTableEntry,
  type StageSelectorBindingTableEntry,
} from "./capabilities-root.js";

export * from "./order-book.js";
export * from "./registry.js";

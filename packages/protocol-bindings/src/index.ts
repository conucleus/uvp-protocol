import {
  encodeAbiParameters,
  encodeFunctionData,
  getAddress,
  isAddress,
  isHex,
  keccak256,
  parseAbi,
  recoverTypedDataAddress,
  stringToHex,
  toHex,
  type Address,
  type Hex,
} from "viem";

export const STATE_MACHINE_ABI = parseAbi([
  "event OwnershipTransferred(address indexed previousOwner,address indexed newOwner)",
  "event StateMachineModuleSet(bytes32 indexed moduleId,address indexed previousModule,address indexed newModule)",
  "event StateMachineModulesFrozen(bytes32 indexed moduleSetHash)",
  "event HookReady(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed hookId,bytes32 stageId,bytes32 hookName)",
  "event HookStatusChanged(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed hookId,uint8 previousStatus,uint8 newStatus,uint64 dueAt)",
  "event TimerPoked(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed hookId,uint64 dueAt)",
  "event SignalSubmitted(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter)",
  "event PlanCommitted(bytes32 indexed planId,bytes32 indexed planHash,address indexed publisher,bytes32 hooksHash,bytes32 metadataHash,uint256 hookCount,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot)",
  "event PlanFinalized(bytes32 indexed planId,bytes32 indexed planHash,bytes32 metadataHash)",
  "event PlanRegistered(bytes32 indexed planId,bytes32 planHash,uint256 hookCount)",
  "event PlanPublisherRecorded(bytes32 indexed planId,address indexed publisher)",
  "event OrderRegistered(bytes32 indexed orderId,bytes32 indexed planId)",
  "event OrderMaterialized(bytes32 indexed orderId,bytes32 indexed planId,bytes32 indexed stageId)",
  "event OrderRelayerRecorded(bytes32 indexed planId,bytes32 indexed orderId,address indexed relayer,address creator)",
  "event SignalSubmitterAuthorized(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)",
  "event StageMaterialized(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed stageId,bytes32 triggerHookId,bytes32 sourceId,bytes32 signalId)",
  "event OrderTriggered(bytes32 indexed orderId,bytes32 indexed planId,bytes32 indexed triggerStageId,bytes32 sourceId,bytes32 signalId,address submitter)",
  "event StageExecutorActivated(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed targetStageId,address executor,bytes32 role,bytes32 metadataHash,uint256 patchNonce,string metadataURI)",
  "event StageExecutorSignalDelegated(bytes32 indexed planId,bytes32 indexed orderId,bytes32 indexed targetStageId,bytes32 sourceId,bytes32 signalId,address executor,bytes32 role,bytes32 metadataHash,uint256 patchNonce)",
  "function owner() view returns (address)",
  "function stagePatchModule() view returns (address)",
  "function derivedSignalModule() view returns (address)",
  "function dockingModule() view returns (address)",
  "function planMetadataModule() view returns (address)",
  "function orderLinkModule() view returns (address)",
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
  "function freezeModules()",
  "function commitPlan((address publisher,bytes32 hooksHash,bytes32 metadataHash,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,uint256 deadline) commit,(bytes32 hookId,bytes32 stageId,bytes32 hookName,uint8 flags,(uint8 op,bytes32 sourceId,bytes32 signalId,uint16 arity,uint64 delaySeconds)[] instructions,bytes32[] dependencyKeys)[] hooks,bytes signature) returns (bytes32 planId)",
  "function finalizePlan(bytes32 planId,(bytes32 selectorStageId,bytes32 targetStageId)[] selectorBindings,(bytes32 stageId,bytes32 targetSourceId,bytes32 signalId,uint8 targetOrderRelation)[] signalCapabilities)",
  "function planRuntimeHash(bytes32 hooksHash,bytes32 metadataHash,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot) pure returns (bytes32)",
  "function planIdFor(address publisher,bytes32 planHash) pure returns (bytes32)",
  "function triggerOrderFromOutsideFor((bytes32 orderId,bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline) trigger,(bytes32 sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)[] authorizations,bytes signature)",
  "function submitSignal(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey)",
  "function submitSignalFor(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline,bytes signature)",
  "function submitSignalFromModule(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter)",
  "function createDockedOrderFromModule(bytes32 targetPlanId,bytes32 linkedOrderId,address creator,address relayer,bytes32 entranceHookId,bytes32 entranceStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,(bytes32 sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)[] authorizations)",
  "function recordDockedInputFromModule(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter)",
  "function planHookFlags(bytes32 planId,bytes32 hookId) view returns (uint8)",
  "function planHookStageId(bytes32 planId,bytes32 hookId) view returns (bytes32)",
  "function planDockRoots(bytes32 planId) view returns (bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot)",
  "function triggerOrderFromSignalFromModule((bytes32 orderId,bytes32 planId,address creator,bytes32 triggerOriginOrderId,bytes32 originPlanId,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 originSourceId,bytes32 originSignalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline) trigger,(bytes32 sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)[] authorizations,address relayer)",
  "function activateStageExecutorFromModule(bytes32 planId,bytes32 orderId,bytes32 targetStageId,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 patchHash,uint256 patchNonce,string metadataURI)",
  "function delegateStageExecutorSignalFromModule(bytes32 planId,bytes32 orderId,bytes32 targetStageId,bytes32 sourceId,bytes32 signalId,address executor,bytes32 role,bytes32 metadataHash,uint256 patchNonce)",
  "function SIGNAL_TARGET_CURRENT_ORDER() view returns (uint8)",
  "function SIGNAL_TARGET_TRIGGER_ORIGIN() view returns (uint8)",
  "function sourceSignalCount(bytes32 planId,bytes32 orderId,bytes32 sourceId) view returns (uint256)",
  "function lastSignalSubmitter(bytes32 planId,bytes32 orderId,bytes32 sourceId) view returns (address)",
  "function hasTriggerOriginConsent(bytes32 originPlanId,bytes32 originOrderId,bytes32 originSourceId,bytes32 originSignalId,address party) view returns (bool)",
  "function DOMAIN_SEPARATOR() view returns (bytes32)",
  "function planExists(bytes32 planId) view returns (bool)",
  "function planCommitted(bytes32 planId) view returns (bool)",
  "function planFinalized(bytes32 planId) view returns (bool)",
  "function planHash(bytes32 planId) view returns (bytes32)",
  "function planPublisher(bytes32 planId) view returns (address)",
  "function orderRelayer(bytes32 planId,bytes32 orderId) view returns (address)",
  "function orderCreator(bytes32 planId,bytes32 orderId) view returns (address)",
  "function hasExplicitSignalAuthorization(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,address submitter) view returns (bool)",
]);

export const ORDER_LINK_MODULE_ABI = parseAbi([
  "event OrderLinked(bytes32 indexed triggeredOrderId,bytes32 indexed triggerOriginOrderId,bytes32 indexed triggerStageId,bytes32 originSourceId,bytes32 originSignalId)",
  "function triggerOrderFromSignalFor((bytes32 orderId,bytes32 planId,address creator,bytes32 triggerOriginOrderId,bytes32 originPlanId,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 originSourceId,bytes32 originSignalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline) trigger,(bytes32 sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)[] authorizations,bytes signature)",
  "function targetOrderRelation(bytes32 fromPlanId,bytes32 fromOrderId,bytes32 targetPlanId,bytes32 targetOrderId) view returns (uint8)",
  "function getTriggerOriginLink(bytes32 planId,bytes32 triggeredOrderId) view returns (bool exists,bytes32 triggerOriginOrderId,bytes32 triggerOriginPlanId,bytes32 originSourceId,bytes32 originSignalId,bytes32 triggerStageId)",
  "function signalAuthorizationsHash((bytes32 sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)[] authorizations) pure returns (bytes32)",
  "function triggerOrderFromSignalDigest((bytes32 orderId,bytes32 planId,address creator,bytes32 triggerOriginOrderId,bytes32 originPlanId,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 originSourceId,bytes32 originSignalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline) trigger,bytes32 authorizationsHash) view returns (bytes32)",
]);

export const STAGE_PATCH_MODULE_ABI = parseAbi([
  "event StageExecutorPatchApplied(bytes32 indexed orderId,bytes32 indexed selectorStageId,bytes32 indexed targetStageId,address selector,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 mode,address previousExecutor,bytes32 approvalSourceId,bytes32 approvalSignalId,bytes32 patchHash,uint256 patchNonce,string metadataURI)",
  "event StageResourcePatchApplied(bytes32 indexed orderId,bytes32 indexed selectorStageId,bytes32 indexed targetStageId,address selector,bytes32 resourceKey,bytes32 manifestHash,bytes32 policyHash,bytes32 patchHash,uint256 patchNonce,string manifestURI)",
  "function EXECUTOR_PATCH_SIGNAL_ID() view returns (bytes32)",
  "function RESOURCE_PATCH_SIGNAL_ID() view returns (bytes32)",
  "function EXECUTOR_PATCH_MODE_ASSIGN() view returns (bytes32)",
  "function EXECUTOR_PATCH_MODE_HANDOFF() view returns (bytes32)",
  "function EXECUTOR_PATCH_MODE_REPLACEMENT() view returns (bytes32)",
  "function applyStageExecutorPatch(bytes32 planId,bytes32 orderId,(bytes32 selectorStageId,bytes32 targetStageId,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 mode,address previousExecutor,bytes32 approvalSourceId,bytes32 approvalSignalId,bytes32 patchHash,uint256 patchNonce,string metadataURI) patch)",
  "function applyStageExecutorPatchFor(bytes32 planId,bytes32 orderId,(bytes32 selectorStageId,bytes32 targetStageId,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 mode,address previousExecutor,bytes32 approvalSourceId,bytes32 approvalSignalId,bytes32 patchHash,uint256 patchNonce,string metadataURI) patch,address selector,uint256 deadline,bytes selectorSignature,bytes previousExecutorSignature)",
  "function applyStageResourcePatch(bytes32 planId,bytes32 orderId,(bytes32 selectorStageId,bytes32 targetStageId,bytes32 resourceKey,bytes32 manifestHash,bytes32 policyHash,bytes32 patchHash,uint256 patchNonce,string manifestURI) patch)",
  "function applyStageResourcePatchFor(bytes32 planId,bytes32 orderId,(bytes32 selectorStageId,bytes32 targetStageId,bytes32 resourceKey,bytes32 manifestHash,bytes32 policyHash,bytes32 patchHash,uint256 patchNonce,string manifestURI) patch,address selector,uint256 deadline,bytes signature)",
  "function stageExecutorPatchDigest(bytes32 planId,bytes32 orderId,(bytes32 selectorStageId,bytes32 targetStageId,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 mode,address previousExecutor,bytes32 approvalSourceId,bytes32 approvalSignalId,bytes32 patchHash,uint256 patchNonce,string metadataURI) patch,address selector,uint256 deadline) view returns (bytes32)",
  "function stageResourcePatchDigest(bytes32 planId,bytes32 orderId,(bytes32 selectorStageId,bytes32 targetStageId,bytes32 resourceKey,bytes32 manifestHash,bytes32 policyHash,bytes32 patchHash,uint256 patchNonce,string manifestURI) patch,address selector,uint256 deadline) view returns (bytes32)",
  "function getActiveStageExecutorPatch(bytes32 planId,bytes32 orderId,bytes32 targetStageId) view returns (bool exists,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 patchHash,uint256 patchNonce,string metadataURI)",
  "function getActiveStageResourcePatch(bytes32 planId,bytes32 orderId,bytes32 targetStageId,bytes32 resourceKey) view returns (bool exists,bytes32 manifestHash,bytes32 policyHash,bytes32 patchHash,uint256 patchNonce,string manifestURI)",
]);

export const DERIVED_SIGNAL_MODULE_ABI = parseAbi([
  "event DerivedSignalSubmitted(bytes32 indexed fromOrderId,bytes32 indexed targetOrderId,bytes32 indexed signalId,bytes32 fromStageId,bytes32 targetSourceId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter)",
  "struct DerivedSignalRequest {bytes32 fromPlanId;bytes32 fromOrderId;bytes32 fromStageId;bytes32 targetPlanId;bytes32 targetOrderId;bytes32 targetSourceId;bytes32 signalId;bytes32 payloadHash;bytes32 idempotencyKey}",
  "function submitDerivedSignal(DerivedSignalRequest request,address submitter)",
  "function submitDerivedSignalFor(DerivedSignalRequest request,address submitter,uint256 deadline,bytes signature)",
  "function derivedSignalDigest(DerivedSignalRequest request,address submitter,uint256 deadline) view returns (bytes32)",
]);

export const DOCKING_MODULE_ABI = parseAbi([
  "event DockOpened(bytes32 indexed dockInstanceId,bytes32 indexed localOrderId,bytes32 indexed linkedOrderId,bytes32 localPlanId,bytes32 targetPlanId,bytes32 routeId,bytes32 routeHash,uint8 depth,address opener)",
  "event DockInputSubmitted(bytes32 indexed dockInstanceId,bytes32 indexed linkedOrderId,bytes32 indexed inputBindingHash,bytes32 localPlanId,bytes32 localOrderId,bytes32 targetPlanId,bytes32 targetSignalId,bytes32 payloadHash,address submitter)",
  "event DockOutputSubmitted(bytes32 indexed dockInstanceId,bytes32 indexed linkedOrderId,bytes32 indexed outputBindingHash,bytes32 localPlanId,bytes32 localOrderId,bytes32 targetPlanId,bytes32 targetSignalId,bytes32 localSignalId,bytes32 payloadHash,address submitter)",
  "event DockTerminal(bytes32 indexed dockInstanceId,uint8 terminal)",
  "function openDockedOrder((bytes32 dockInstanceId,bytes32 localPlanId,bytes32 localOrderId,bytes32 localStageId,bytes32 localHookId,bytes32 localDefinitionRefHash,bytes32 routeId,bytes32 routeHash,bytes32 targetDefinitionRefHash,bytes32 targetArtifactHash,bytes32 targetInterfaceRoot,bytes32 sourceSeamId,bytes32 entrancePortKey,bytes32 entranceBindingHash,uint8 accessPolicy,bytes32 inputsRoot,bytes32 outputsRoot,bytes32 targetPlanId,bytes32 linkedOrderId,bytes32 targetStageId,bytes32 targetHookId,bytes32 targetSourceId,bytes32 targetSignalId,bytes32 sourceFactSetHash,uint8 parentDepth,address creator) request,bytes32[] routeProof,(bytes32 leafHash,bytes32 portKey,uint8 kind,bytes32 hookKey,bytes32 sourceId,bytes32 signalId,uint8 accessPolicy) entranceLeaf,bytes32[] interfaceProof,(bytes32 localHookId,bytes32 portKey,bytes32 targetSourceId,bytes32 targetSignalId,uint8 kind,bytes32 bindingHash)[] inputs,(bytes32 localSourceId,bytes32 localSignalId,bytes32 portKey,bytes32 targetSourceId,bytes32 targetSignalId,uint8 terminal,bytes32 bindingHash)[] outputs,(uint256 nonce,uint256 deadline,bytes signature) permit,(bytes32 sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)[] childAuthorizations) returns (bool opened)",
  "function submitDockedInput(bytes32 dockInstanceId,bytes32 localHookId,bytes32 inputBindingHash,bytes32 sourceFactSetHash) returns (bool submitted)",
  "function submitDockedSignal(bytes32 dockInstanceId,bytes32 outputBindingHash) returns (bool submitted)",
  "function getActiveDock(bytes32 dockInstanceId) view returns (bytes32 localPlanId,bytes32 localOrderId,bytes32 localStageId,bytes32 routeId,bytes32 routeHash,bytes32 targetPlanId,bytes32 linkedOrderId,uint8 depth,uint8 status,bool exists)",
  "function getDockInputBinding(bytes32 dockInstanceId,bytes32 inputBindingHash) view returns (bytes32 localHookId,bytes32 portKey,bytes32 targetSourceId,bytes32 targetSignalId,uint8 kind,bool exists)",
  "function getDockOutputBinding(bytes32 dockInstanceId,bytes32 outputBindingHash) view returns (bytes32 localSourceId,bytes32 localSignalId,bytes32 portKey,bytes32 targetSourceId,bytes32 targetSignalId,uint8 terminal,bool exists)",
  "function dockInputDelivered(bytes32 dockInstanceId,bytes32 inputBindingHash) view returns (bool)",
  "function dockOutputDelivered(bytes32 dockInstanceId,bytes32 outputBindingHash) view returns (bool)",
  "function dockByLocalRoute(bytes32 localRouteInstanceKey) view returns (bytes32)",
  "function dockByTargetOrder(bytes32 targetEndpointKey) view returns (bytes32)",
  "function dockDepthOfOrder(bytes32 planId,bytes32 orderId) view returns (uint8)",
  "function usedEntrancePermitNonce(bytes32 dockInstanceId) view returns (uint256)",
  "function entrancePermitDigest(bytes32 targetPlanId,bytes32 targetEntrancePortId,bytes32 localPlanId,bytes32 routeHash,bytes32 dockInstanceId,bytes32 linkedOrderId,address creator,uint256 nonce,uint256 deadline) view returns (bytes32)",
  "function DOMAIN_SEPARATOR() view returns (bytes32)",
  "function stateMachine() view returns (address)",
  "function planMetadataModule() view returns (address)",
]);

export const STATE_MACHINE_LENS_ABI = parseAbi([
  "function stateMachine() view returns (address)",
  "function getActiveStageExecutorPatch(bytes32 planId,bytes32 orderId,bytes32 targetStageId) view returns (bool exists,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 patchHash,uint256 patchNonce,string metadataURI)",
  "function getActiveStageResourcePatch(bytes32 planId,bytes32 orderId,bytes32 targetStageId,bytes32 resourceKey) view returns (bool exists,bytes32 manifestHash,bytes32 policyHash,bytes32 patchHash,uint256 patchNonce,string manifestURI)",
  "function getActiveDock(bytes32 dockInstanceId) view returns (bytes32 localPlanId,bytes32 localOrderId,bytes32 localStageId,bytes32 routeId,bytes32 routeHash,bytes32 targetPlanId,bytes32 linkedOrderId,uint8 depth,uint8 status,bool exists)",
  "function getDockInputBinding(bytes32 dockInstanceId,bytes32 inputBindingHash) view returns (bytes32 localHookId,bytes32 portKey,bytes32 targetSourceId,bytes32 targetSignalId,uint8 kind,bool exists)",
  "function getDockOutputBinding(bytes32 dockInstanceId,bytes32 outputBindingHash) view returns (bytes32 localSourceId,bytes32 localSignalId,bytes32 portKey,bytes32 targetSourceId,bytes32 targetSignalId,uint8 terminal,bool exists)",
  "function dockInputDelivered(bytes32 dockInstanceId,bytes32 inputBindingHash) view returns (bool)",
  "function dockOutputDelivered(bytes32 dockInstanceId,bytes32 outputBindingHash) view returns (bool)",
  "function planSelectorBindingCount(bytes32 planId) view returns (uint256)",
  "function planSelectorBindingAt(bytes32 planId,uint256 index) view returns (bytes32 selectorStageId,bytes32 targetStageId)",
  "function planSignalCapabilityCount(bytes32 planId) view returns (uint256)",
  "function isStageSelectorBound(bytes32 planId,bytes32 selectorStageId,bytes32 targetStageId) view returns (bool)",
  "function isSelectorTargetStage(bytes32 planId,bytes32 targetStageId) view returns (bool)",
  "function isSignalCapabilityRegistered(bytes32 planId,bytes32 stageId,bytes32 targetSourceId,bytes32 signalId,uint8 targetOrderRelation) view returns (bool)",
  "function targetOrderRelation(bytes32 fromPlanId,bytes32 fromOrderId,bytes32 targetPlanId,bytes32 targetOrderId) view returns (uint8)",
  "function getTriggerOriginLink(bytes32 planId,bytes32 triggeredOrderId) view returns (bool exists,bytes32 triggerOriginOrderId,bytes32 triggerOriginPlanId,bytes32 originSourceId,bytes32 originSignalId,bytes32 triggerStageId)",
]);

export const PRODUCT_SUBMIT_DOMAIN_NAME = "UVPStateMachine";
export const PRODUCT_SUBMIT_DOMAIN_VERSION = "0.8";
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
export const STAGE_EXECUTOR_PATCH_DOMAIN_VERSION = "0.1";
export const STAGE_EXECUTOR_PATCH_PRIMARY_TYPE =
  "UVPStagePatchModuleStageExecutorPatch";
export const STAGE_RESOURCE_PATCH_DOMAIN_NAME =
  STAGE_EXECUTOR_PATCH_DOMAIN_NAME;
export const STAGE_RESOURCE_PATCH_DOMAIN_VERSION =
  STAGE_EXECUTOR_PATCH_DOMAIN_VERSION;
export const STAGE_RESOURCE_PATCH_PRIMARY_TYPE =
  "UVPStagePatchModuleStageResourcePatch";
export const STAGE_EXECUTOR_PATCH_PAYLOAD_HASH_DOMAIN =
  "uvp:stage-executor-patch-payload:v1";
export const STAGE_RESOURCE_PATCH_PAYLOAD_HASH_DOMAIN =
  "uvp:stage-resource-patch-payload:v1";
export const RESOURCE_MANIFEST_V1_SCHEMA_VERSION = "uvp-resource-manifest-v1";
export const RESOURCE_MANIFEST_HASH_DOMAIN = "uvp:resource-manifest:v1";
export const EXECUTOR_PATCH_MODE_ASSIGN = stringToHex("assign", {
  size: 32,
}) as Hex;
export const EXECUTOR_PATCH_MODE_HANDOFF = stringToHex("handoff", {
  size: 32,
}) as Hex;
export const EXECUTOR_PATCH_MODE_REPLACEMENT = stringToHex("replacement", {
  size: 32,
}) as Hex;

export interface ProductSubmitTypedDataField {
  readonly name: string;
  readonly type: string;
}

// 审计 #10：UVPStateMachineSignal 摘要并入 planId（新版本口径），签名绑定
// (planId, orderId)。
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
  ];

export const PLAN_COMMIT_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] =
  [
    { name: "publisher", type: "address" },
    { name: "hooksHash", type: "bytes32" },
    { name: "metadataHash", type: "bytes32" },
    { name: "deadline", type: "uint256" },
  ];

export const TRIGGER_ORDER_FROM_OUTSIDE_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] =
  [
    { name: "orderId", type: "bytes32" },
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
    { name: "approvalSourceId", type: "bytes32" },
    { name: "approvalSignalId", type: "bytes32" },
    { name: "patchHash", type: "bytes32" },
    { name: "patchNonce", type: "uint256" },
    { name: "metadataURI", type: "string" },
    { name: "selector", type: "address" },
    { name: "deadline", type: "uint256" },
  ];

export const STAGE_RESOURCE_PATCH_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] =
  [
    { name: "planId", type: "bytes32" },
    { name: "orderId", type: "bytes32" },
    { name: "selectorStageId", type: "bytes32" },
    { name: "targetStageId", type: "bytes32" },
    { name: "resourceKey", type: "bytes32" },
    { name: "manifestHash", type: "bytes32" },
    { name: "policyHash", type: "bytes32" },
    { name: "patchHash", type: "bytes32" },
    { name: "patchNonce", type: "uint256" },
    { name: "manifestURI", type: "string" },
    { name: "selector", type: "address" },
    { name: "deadline", type: "uint256" },
  ];


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
  };
}

export interface PlanCommitPayload {
  readonly publisher: Address | string;
  readonly hooksHash: Hex | string;
  readonly metadataHash: Hex | string;
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
    readonly metadataHash: Hex;
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

export interface TriggerOrderFromOutsidePayload {
  readonly orderId: Hex | string;
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

export interface TriggerOrderFromOutsideTypedData {
  readonly domain: ProductSubmitTypedData["domain"];
  readonly types: {
    readonly UVPStateMachineTriggerOrderFromOutside: readonly ProductSubmitTypedDataField[];
  };
  readonly primaryType: typeof TRIGGER_ORDER_FROM_OUTSIDE_PRIMARY_TYPE;
  readonly message: {
    readonly orderId: Hex;
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
  readonly approvalSourceId: Hex | string;
  readonly approvalSignalId: Hex | string;
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
    readonly approvalSourceId: Hex;
    readonly approvalSignalId: Hex;
    readonly patchHash: Hex;
    readonly patchNonce: string;
    readonly metadataURI: string;
    readonly selector: Address;
    readonly deadline: string;
  };
}

export interface StageResourcePatchPayload {
  readonly selectorStageId: Hex | string;
  readonly targetStageId: Hex | string;
  readonly resourceKey: Hex | string;
  readonly manifestHash: Hex | string;
  readonly policyHash: Hex | string;
  readonly patchNonce: bigint | number | string;
  readonly manifestURI: string;
}

export interface StageResourcePatchCallPatch extends StageResourcePatchPayload {
  readonly patchHash: Hex | string;
}

export interface StageResourcePatchTypedData {
  readonly domain: {
    readonly name: typeof STAGE_RESOURCE_PATCH_DOMAIN_NAME;
    readonly version: typeof STAGE_RESOURCE_PATCH_DOMAIN_VERSION;
    readonly chainId: number;
    readonly verifyingContract: Address;
  };
  readonly types: {
    readonly UVPStagePatchModuleStageResourcePatch: readonly ProductSubmitTypedDataField[];
  };
  readonly primaryType: typeof STAGE_RESOURCE_PATCH_PRIMARY_TYPE;
  readonly message: {
    readonly planId: Hex;
    readonly orderId: Hex;
    readonly selectorStageId: Hex;
    readonly targetStageId: Hex;
    readonly resourceKey: Hex;
    readonly manifestHash: Hex;
    readonly policyHash: Hex;
    readonly patchHash: Hex;
    readonly patchNonce: string;
    readonly manifestURI: string;
    readonly selector: Address;
    readonly deadline: string;
  };
}





export type ResourceVisibility = "public" | "protected" | "private";

export interface ResourceManifestV1 {
  readonly schemaVersion: typeof RESOURCE_MANIFEST_V1_SCHEMA_VERSION;
  readonly orderId: Hex | string;
  readonly targetStageId: Hex | string;
  readonly resourceKey: Hex | string;
  readonly visibility: ResourceVisibility;
  readonly contentHash?: Hex | string;
  readonly ciphertextHash?: Hex | string;
  readonly storageCID: string;
  readonly policyHash: Hex | string;
  readonly recipientEnvelopeRoot: Hex | string;
  readonly createdBy: Address | string;
  readonly createdAt: string;
  readonly supersedes?: Hex | string;
}

interface CanonicalResourceManifestV1 {
  readonly schemaVersion: typeof RESOURCE_MANIFEST_V1_SCHEMA_VERSION;
  readonly orderId: Hex;
  readonly targetStageId: Hex;
  readonly resourceKey: Hex;
  readonly visibility: ResourceVisibility;
  readonly contentHash?: Hex;
  readonly ciphertextHash?: Hex;
  readonly storageCID: string;
  readonly policyHash: Hex;
  readonly recipientEnvelopeRoot: Hex;
  readonly createdBy: Address;
  readonly createdAt: string;
  readonly supersedes?: Hex;
}

export interface BuildProductSubmitTypedDataInput {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
  /**
   * 审计 #10：签名域并入 planId。真实签署方必须提供订单的 planId；
   * 允许缺省（零占位）仅为兼容只校验 surface 形状的下游 gate
   * （如 uvp-deploy 的 verify-product-signal-map），零占位签名无法
   * 通过链上 (planId, orderId) 存在性校验，不构成重放面。
   */
  readonly planId?: Hex | string;
  readonly orderId: Hex | string;
  readonly sourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly payloadHash: Hex | string;
  readonly idempotencyKey: Hex | string;
  readonly submitter: Address | string;
  readonly deadline: string;
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

export interface BuildStageExecutorPatchTypedDataInput
  extends StageExecutorPatchCallPatch {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
  readonly planId: Hex | string;
  readonly orderId: Hex | string;
  readonly selector: Address | string;
  readonly deadline: bigint | number | string;
}

export interface BuildStageResourcePatchTypedDataInput
  extends StageResourcePatchCallPatch {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
  readonly planId: Hex | string;
  readonly orderId: Hex | string;
  readonly selector: Address | string;
  readonly deadline: bigint | number | string;
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
}

export interface TriggerOrderFromOutsideForCallArgs
  extends TriggerOrderFromOutsidePayload {
  readonly authorizations: readonly SignalAuthorizationPayload[];
  readonly signature: Hex | string;
}

export interface TriggerOrderFromSignalForCallArgs
  extends TriggerOrderFromSignalPayload {
  readonly authorizations: readonly SignalAuthorizationPayload[];
  readonly signature: Hex | string;
}

export interface ApplyStageExecutorPatchForCallArgs {
  readonly planId: Hex | string;
  readonly orderId: Hex | string;
  readonly patch: StageExecutorPatchCallPatch;
  readonly selector: Address | string;
  readonly deadline: bigint | number | string;
  readonly selectorSignature: Hex | string;
  readonly previousExecutorSignature: Hex | string;
}

export interface ApplyStageResourcePatchForCallArgs {
  readonly planId: Hex | string;
  readonly orderId: Hex | string;
  readonly patch: StageResourcePatchCallPatch;
  readonly selector: Address | string;
  readonly deadline: bigint | number | string;
  readonly signature: Hex | string;
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

export interface DockingModuleCallConfig {
  readonly dockingModuleAddress: Address | string;
  readonly chainId?: number;
}

export interface OrderLinkModuleCallConfig {
  readonly orderLinkModuleAddress: Address | string;
  readonly chainId?: number;
}

export type ApplyStageExecutorPatchForCallConfig = StagePatchModuleCallConfig;
export type ApplyStageResourcePatchForCallConfig = StagePatchModuleCallConfig;
export type SubmitDockedSignalCallConfig = DockingModuleCallConfig;
export type SubmitDerivedSignalForCallConfig = DerivedSignalModuleCallConfig;
export type TriggerOrderFromOutsideForCallConfig = SubmitSignalForCallConfig;
export type TriggerOrderFromSignalForCallConfig = OrderLinkModuleCallConfig;

export interface SubmitSignalForCall {
  readonly address: Address;
  readonly abi: typeof STATE_MACHINE_ABI;
  readonly functionName: "submitSignalFor";
  readonly args: readonly [Hex, Hex, Hex, Hex, Hex, Hex, Address, bigint, Hex];
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
  ];
  readonly data: Hex;
  readonly chainId?: number;
}

export type StageResourcePatchCallTuple = readonly [
  Hex,
  Hex,
  Hex,
  Hex,
  Hex,
  Hex,
  bigint,
  string,
];

export interface ApplyStageResourcePatchForCall {
  readonly address: Address;
  readonly abi: typeof STAGE_PATCH_MODULE_ABI;
  readonly functionName: "applyStageResourcePatchFor";
  readonly args: readonly [
    Hex,
    Hex,
    StageResourcePatchCallTuple,
    Address,
    bigint,
    Hex,
  ];
  readonly data: Hex;
  readonly chainId?: number;
}




export interface EvidenceHashResult {
  readonly algorithm: "keccak256";
  readonly evidenceHash: Hex;
  readonly byteLength: number;
  readonly source: "bytes" | "json" | "text";
}

const BYTES32_RE = /^0x[a-fA-F0-9]{64}$/;
const ZERO_BYTES32 = `0x${"0".repeat(64)}` as Hex;
const ZERO_ADDRESS = `0x${"0".repeat(40)}` as Address;
const EXECUTOR_PATCH_MODE_BY_NAME: Readonly<Record<string, Hex>> = {
  assign: EXECUTOR_PATCH_MODE_ASSIGN,
  handoff: EXECUTOR_PATCH_MODE_HANDOFF,
  replacement: EXECUTOR_PATCH_MODE_REPLACEMENT,
};
const EXECUTOR_PATCH_MODE_VALUE_SET = new Set<Hex>([
  EXECUTOR_PATCH_MODE_ASSIGN,
  EXECUTOR_PATCH_MODE_HANDOFF,
  EXECUTOR_PATCH_MODE_REPLACEMENT,
]);
const ALLOWED_RESOURCE_MANIFEST_KEYS = new Set([
  "schemaVersion",
  "orderId",
  "targetStageId",
  "resourceKey",
  "visibility",
  "contentHash",
  "ciphertextHash",
  "storageCID",
  "policyHash",
  "recipientEnvelopeRoot",
  "createdBy",
  "createdAt",
  "supersedes",
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
      planId: normalizeBytes32(input.planId ?? ZERO_BYTES32, "planId"),
      orderId: normalizeBytes32(input.orderId, "orderId"),
      sourceId: normalizeBytes32(input.sourceId, "sourceId"),
      signalId: normalizeBytes32(input.signalId, "signalId"),
      payloadHash: normalizeBytes32(input.payloadHash, "payloadHash"),
      idempotencyKey: normalizeBytes32(input.idempotencyKey, "idempotencyKey"),
      submitter: normalizeAddress(input.submitter, "submitter"),
      deadline: normalizeUintString(input.deadline, "deadline"),
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
      metadataHash: normalizeBytes32(input.metadataHash, "metadataHash"),
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
      orderId: trigger[0],
      planId: trigger[1],
      creator: trigger[2],
      triggerHookId: trigger[3],
      triggerStageId: trigger[4],
      sourceId: trigger[5],
      signalId: trigger[6],
      payloadHash: trigger[7],
      idempotencyKey: trigger[8],
      authorizationsHash: hashSignalAuthorizations(input.authorizations),
      submitter: trigger[9],
      deadline: trigger[10].toString(10),
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
      approvalSourceId: patch[7],
      approvalSignalId: patch[8],
      patchHash: patch[9],
      patchNonce: patch[10].toString(10),
      metadataURI: patch[11],
      selector: normalizeAddress(input.selector, "selector"),
      deadline: normalizeUintString(input.deadline, "deadline"),
    },
  };
}

export function buildStageResourcePatchTypedData(
  input: BuildStageResourcePatchTypedDataInput,
): StageResourcePatchTypedData {
  const patch = normalizeStageResourcePatch(input);
  return {
    domain: {
      name: STAGE_RESOURCE_PATCH_DOMAIN_NAME,
      version: STAGE_RESOURCE_PATCH_DOMAIN_VERSION,
      chainId: normalizeChainId(input.chainId),
      verifyingContract: normalizeAddress(
        input.verifyingContract,
        "verifyingContract",
      ),
    },
    types: {
      UVPStagePatchModuleStageResourcePatch:
        STAGE_RESOURCE_PATCH_TYPED_DATA_FIELDS,
    },
    primaryType: STAGE_RESOURCE_PATCH_PRIMARY_TYPE,
    message: {
      planId: normalizeBytes32(input.planId, "planId"),
      orderId: normalizeBytes32(input.orderId, "orderId"),
      selectorStageId: patch[0],
      targetStageId: patch[1],
      resourceKey: patch[2],
      manifestHash: patch[3],
      policyHash: patch[4],
      patchHash: patch[5],
      patchNonce: patch[6].toString(10),
      manifestURI: patch[7],
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

export async function recoverStageResourcePatchSigner(
  typedData: StageResourcePatchTypedData,
  signature: Hex | string,
): Promise<Address> {
  const recovered = await recoverTypedDataAddress({
    domain: typedData.domain,
    types: typedData.types,
    primaryType: typedData.primaryType,
    message: typedData.message,
    signature: normalizeHex(signature, "signature"),
  } as unknown as Parameters<typeof recoverTypedDataAddress>[0]);
  return normalizeAddress(recovered, "recoveredSelector");
}


export function buildSubmitSignalForCall(
  config: SubmitSignalForCallConfig,
  args: SubmitSignalForCallArgs,
): SubmitSignalForCall {
  const normalizedArgs = [
    normalizeBytes32(args.planId, "planId"),
    normalizeBytes32(args.orderId, "orderId"),
    normalizeBytes32(args.sourceId, "sourceId"),
    normalizeBytes32(args.signalId, "signalId"),
    normalizeBytes32(args.payloadHash, "payloadHash"),
    normalizeBytes32(args.idempotencyKey, "idempotencyKey"),
    normalizeAddress(args.submitter, "submitter"),
    normalizeUintBigInt(args.deadline, "deadline"),
    normalizeHex(args.signature, "signature"),
  ] as const;

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
  ] as const satisfies readonly [
    DerivedSignalRequestCallStruct,
    Address,
    bigint,
    Hex,
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

export function buildTriggerOrderFromSignalForCall(
  config: TriggerOrderFromSignalForCallConfig,
  args: TriggerOrderFromSignalForCallArgs,
): TriggerOrderFromSignalForCall {
  const trigger = normalizeTriggerOrderFromSignalStruct(args);
  const normalizedArgs = [
    trigger,
    args.authorizations.map(normalizeSignalAuthorizationStruct),
    normalizeHex(args.signature, "signature"),
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

export function buildApplyStageResourcePatchForCall(
  config: ApplyStageResourcePatchForCallConfig,
  args: ApplyStageResourcePatchForCallArgs,
): ApplyStageResourcePatchForCall {
  const normalizedArgs = [
    normalizeBytes32(args.planId, "planId"),
    normalizeBytes32(args.orderId, "orderId"),
    normalizeStageResourcePatch(args.patch),
    normalizeAddress(args.selector, "selector"),
    normalizeUintBigInt(args.deadline, "deadline"),
    normalizeHex(args.signature, "signature"),
  ] as const;

  return {
    address: normalizeAddress(
      config.stagePatchModuleAddress,
      "stagePatchModuleAddress",
    ),
    abi: STAGE_PATCH_MODULE_ABI,
    functionName: "applyStageResourcePatchFor",
    args: normalizedArgs,
    data: encodeFunctionData({
      abi: STAGE_PATCH_MODULE_ABI,
      functionName: "applyStageResourcePatchFor",
      args: normalizedArgs as never,
    }),
    ...(config.chainId !== undefined
      ? { chainId: normalizeChainId(config.chainId) }
      : {}),
  };
}

export interface SubmitDockedSignalCallArgs {
  readonly dockInstanceId: Hex | string;
  readonly outputBindingHash: Hex | string;
}

export interface SubmitDockedInputCallArgs {
  readonly dockInstanceId: Hex | string;
  readonly localHookId: Hex | string;
  readonly inputBindingHash: Hex | string;
  readonly sourceFactSetHash: Hex | string;
}

export interface SubmitDockedSignalCall {
  readonly address: Address;
  readonly abi: typeof DOCKING_MODULE_ABI;
  readonly functionName: "submitDockedSignal";
  readonly args: readonly [Hex, Hex];
  readonly data: Hex;
  readonly chainId?: number;
}

export interface SubmitDockedInputCall {
  readonly address: Address;
  readonly abi: typeof DOCKING_MODULE_ABI;
  readonly functionName: "submitDockedInput";
  readonly args: readonly [Hex, Hex, Hex, Hex];
  readonly data: Hex;
  readonly chainId?: number;
}

// openDockedOrder 的嵌套 tuple 会让 viem 对完整 DOCKING_MODULE_ABI 的类型推断
// 超过 TS 递归上限；编码层用等价的最小 ABI（selector 相同，calldata 逐字节一致）。
const DOCK_SUBMIT_SIGNAL_ABI = parseAbi([
  "function submitDockedSignal(bytes32 dockInstanceId,bytes32 outputBindingHash) returns (bool)",
]);
const DOCK_SUBMIT_INPUT_ABI = parseAbi([
  "function submitDockedInput(bytes32 dockInstanceId,bytes32 localHookId,bytes32 inputBindingHash,bytes32 sourceFactSetHash) returns (bool)",
]);

export function buildSubmitDockedSignalCall(
  config: SubmitDockedSignalCallConfig,
  args: SubmitDockedSignalCallArgs,
): SubmitDockedSignalCall {
  const normalizedArgs = [
    normalizeBytes32(args.dockInstanceId, "dockInstanceId"),
    normalizeBytes32(args.outputBindingHash, "outputBindingHash"),
  ] as const;

  const data = encodeFunctionData({
    abi: DOCK_SUBMIT_SIGNAL_ABI,
    functionName: "submitDockedSignal",
    args: normalizedArgs,
  });
  const call: SubmitDockedSignalCall = {
    address: normalizeAddress(config.dockingModuleAddress, "dockingModuleAddress"),
    abi: DOCKING_MODULE_ABI,
    functionName: "submitDockedSignal",
    args: normalizedArgs,
    data,
    ...(config.chainId !== undefined
      ? { chainId: normalizeChainId(config.chainId) }
      : {}),
  };
  return call;
}

export function buildSubmitDockedInputCall(
  config: SubmitDockedSignalCallConfig,
  args: SubmitDockedInputCallArgs,
): SubmitDockedInputCall {
  const normalizedArgs = [
    normalizeBytes32(args.dockInstanceId, "dockInstanceId"),
    normalizeBytes32(args.localHookId, "localHookId"),
    normalizeBytes32(args.inputBindingHash, "inputBindingHash"),
    normalizeBytes32(args.sourceFactSetHash, "sourceFactSetHash"),
  ] as const;

  const data = encodeFunctionData({
    abi: DOCK_SUBMIT_INPUT_ABI,
    functionName: "submitDockedInput",
    args: normalizedArgs,
  });
  const call: SubmitDockedInputCall = {
    address: normalizeAddress(config.dockingModuleAddress, "dockingModuleAddress"),
    abi: DOCKING_MODULE_ABI,
    functionName: "submitDockedInput",
    args: normalizedArgs,
    data,
    ...(config.chainId !== undefined
      ? { chainId: normalizeChainId(config.chainId) }
      : {}),
  };
  return call;
}

export function canonicalJson(value: unknown): string {
  if (value === null) {
    return "null";
  }

  if (typeof value === "string") {
    return JSON.stringify(value);
  }

  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new TypeError("canonical JSON does not support non-finite numbers");
    }
    return JSON.stringify(value);
  }

  if (typeof value === "boolean") {
    return value ? "true" : "false";
  }

  if (Array.isArray(value)) {
    return `[${value.map((item) => canonicalJson(item)).join(",")}]`;
  }

  if (typeof value === "object") {
    const record = value as Record<string, unknown>;
    const entries = Object.keys(record)
      .sort()
      .map((key) => {
        const child = record[key];
        if (typeof child === "undefined") {
          throw new TypeError(
            "canonical JSON does not support undefined object properties",
          );
        }
        return `${JSON.stringify(key)}:${canonicalJson(child)}`;
      });
    return `{${entries.join(",")}}`;
  }

  throw new TypeError(`canonical JSON does not support ${typeof value}`);
}

export function hashEvidenceBytes(bytes: Uint8Array): EvidenceHashResult {
  return {
    algorithm: "keccak256",
    evidenceHash: keccak256(toHex(bytes)),
    byteLength: bytes.byteLength,
    source: "bytes",
  };
}

export function hashEvidenceText(text: string): EvidenceHashResult {
  return {
    algorithm: "keccak256",
    evidenceHash: keccak256(stringToHex(text)),
    byteLength: new TextEncoder().encode(text).byteLength,
    source: "text",
  };
}

export function hashEvidenceJson(value: unknown): EvidenceHashResult {
  const canonical = canonicalJson(value);
  return {
    algorithm: "keccak256",
    evidenceHash: keccak256(stringToHex(canonical)),
    byteLength: new TextEncoder().encode(canonical).byteLength,
    source: "json",
  };
}

export function hashStageExecutorPatchPayload(
  payload: StageExecutorPatchPayload,
): Hex {
  const normalized = normalizeStageExecutorPatchPayload(payload);
  return keccak256(
    encodeAbiParameters(
      [
        { name: "selectorStageId", type: "bytes32" },
        { name: "targetStageId", type: "bytes32" },
        { name: "executor", type: "address" },
        { name: "role", type: "bytes32" },
        { name: "executorMetadataHash", type: "bytes32" },
        { name: "mode", type: "bytes32" },
        { name: "previousExecutor", type: "address" },
        { name: "approvalSourceId", type: "bytes32" },
        { name: "approvalSignalId", type: "bytes32" },
        { name: "patchNonce", type: "uint256" },
        { name: "metadataURI", type: "string" },
      ],
      [
        normalized.selectorStageId,
        normalized.targetStageId,
        normalized.executor,
        normalized.role,
        normalized.executorMetadataHash,
        normalized.mode,
        normalized.previousExecutor,
        normalized.approvalSourceId,
        normalized.approvalSignalId,
        BigInt(normalized.patchNonce),
        normalized.metadataURI,
      ],
    ),
  );
}

export function hashStageResourcePatchPayload(
  payload: StageResourcePatchPayload,
): Hex {
  const normalized = normalizeStageResourcePatchPayload(payload);
  return keccak256(
    encodeAbiParameters(
      [
        { name: "selectorStageId", type: "bytes32" },
        { name: "targetStageId", type: "bytes32" },
        { name: "resourceKey", type: "bytes32" },
        { name: "manifestHash", type: "bytes32" },
        { name: "policyHash", type: "bytes32" },
        { name: "patchNonce", type: "uint256" },
        { name: "manifestURI", type: "string" },
      ],
      [
        normalized.selectorStageId,
        normalized.targetStageId,
        normalized.resourceKey,
        normalized.manifestHash,
        normalized.policyHash,
        BigInt(normalized.patchNonce),
        normalized.manifestURI,
      ],
    ),
  );
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

export function hashResourceManifest(manifest: ResourceManifestV1): Hex {
  const normalized = normalizeResourceManifestV1(manifest);
  return hashCanonicalJson(RESOURCE_MANIFEST_HASH_DOMAIN, normalized);
}

export function normalizeAddress(
  value: Address | string,
  fieldName = "address",
): Address {
  if (!isAddress(value, { strict: false })) {
    throw new Error(`${fieldName} must be a valid EVM address`);
  }

  return getAddress(value).toLowerCase() as Address;
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
    throw new Error("mode must be assign, handoff, or replacement");
  }
  return normalized;
}

function normalizeSignalAuthorization(
  authorization: SignalAuthorizationPayload,
): SignalAuthorizationCallTuple {
  return [
    normalizeBytes32(authorization.sourceId, "authorization.sourceId"),
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
    normalizeNonZeroBytes32(trigger.orderId, "orderId"),
    normalizeNonZeroBytes32(trigger.planId, "planId"),
    normalizeAddress(trigger.creator, "creator"),
    normalizeNonZeroBytes32(trigger.triggerHookId, "triggerHookId"),
    normalizeNonZeroBytes32(trigger.triggerStageId, "triggerStageId"),
    normalizeBytes32(trigger.sourceId, "sourceId"),
    normalizeNonZeroBytes32(trigger.signalId, "signalId"),
    normalizeBytes32(trigger.payloadHash, "payloadHash"),
    normalizeBytes32(trigger.idempotencyKey, "idempotencyKey"),
    normalizeAddress(trigger.submitter, "submitter"),
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
    normalizeBytes32(patch.approvalSourceId, "approvalSourceId"),
    normalizeBytes32(patch.approvalSignalId, "approvalSignalId"),
    normalizeNonZeroBytes32(patch.patchHash, "patchHash"),
    normalizeUintBigInt(patch.patchNonce, "patchNonce"),
    patch.metadataURI,
  ] as const;
}

function normalizeStageResourcePatch(
  patch: StageResourcePatchCallPatch,
): StageResourcePatchCallTuple {
  if (typeof patch.manifestURI !== "string") {
    throw new Error("manifestURI must be a string");
  }
  if (patch.manifestURI.trim().length === 0) {
    throw new Error("manifestURI must be a non-empty string");
  }
  return [
    normalizeNonZeroBytes32(patch.selectorStageId, "selectorStageId"),
    normalizeNonZeroBytes32(patch.targetStageId, "targetStageId"),
    normalizeNonZeroBytes32(patch.resourceKey, "resourceKey"),
    normalizeNonZeroBytes32(patch.manifestHash, "manifestHash"),
    normalizeNonZeroBytes32(patch.policyHash, "policyHash"),
    normalizeNonZeroBytes32(patch.patchHash, "patchHash"),
    normalizeUintBigInt(patch.patchNonce, "patchNonce"),
    patch.manifestURI,
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
  readonly approvalSourceId: Hex;
  readonly approvalSignalId: Hex;
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
    approvalSourceId: normalizeBytes32(
      payload.approvalSourceId,
      "approvalSourceId",
    ),
    approvalSignalId: normalizeBytes32(
      payload.approvalSignalId,
      "approvalSignalId",
    ),
    patchNonce: normalizeUintString(payload.patchNonce, "patchNonce"),
    metadataURI: payload.metadataURI,
  };
}

function normalizeStageResourcePatchPayload(
  payload: StageResourcePatchPayload,
): {
  readonly selectorStageId: Hex;
  readonly targetStageId: Hex;
  readonly resourceKey: Hex;
  readonly manifestHash: Hex;
  readonly policyHash: Hex;
  readonly patchNonce: string;
  readonly manifestURI: string;
} {
  if (typeof payload.manifestURI !== "string") {
    throw new Error("manifestURI must be a string");
  }
  if (payload.manifestURI.trim().length === 0) {
    throw new Error("manifestURI must be a non-empty string");
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
    resourceKey: normalizeNonZeroBytes32(payload.resourceKey, "resourceKey"),
    manifestHash: normalizeNonZeroBytes32(payload.manifestHash, "manifestHash"),
    policyHash: normalizeNonZeroBytes32(payload.policyHash, "policyHash"),
    patchNonce: normalizeUintString(payload.patchNonce, "patchNonce"),
    manifestURI: payload.manifestURI,
  };
}


function normalizeResourceManifestV1(
  manifest: ResourceManifestV1,
): CanonicalResourceManifestV1 {
  if (!isRecord(manifest)) {
    throw new Error("resource manifest must be an object");
  }
  assertAllowedResourceManifestKeys(manifest);

  if (manifest.schemaVersion !== RESOURCE_MANIFEST_V1_SCHEMA_VERSION) {
    throw new Error(
      `schemaVersion must be ${RESOURCE_MANIFEST_V1_SCHEMA_VERSION}`,
    );
  }
  if (!isResourceVisibility(manifest.visibility)) {
    throw new Error("visibility must be public, protected, or private");
  }
  if (
    typeof manifest.storageCID !== "string" ||
    manifest.storageCID.trim().length === 0
  ) {
    throw new Error(
      "storageCID must be a non-empty content-addressed reference",
    );
  }
  if (/^https?:\/\//i.test(manifest.storageCID)) {
    throw new Error("storageCID must be content-addressed, not an HTTP URL");
  }
  if (
    typeof manifest.createdAt !== "string" ||
    manifest.createdAt.trim().length === 0
  ) {
    throw new Error("createdAt must be a non-empty string");
  }

  const normalizedVisibility = manifest.visibility;
  const normalizedContentHash = normalizeOptionalBytes32(
    manifest.contentHash,
    "contentHash",
  );
  const normalizedCiphertextHash = normalizeOptionalBytes32(
    manifest.ciphertextHash,
    "ciphertextHash",
  );
  const normalizedRecipientEnvelopeRoot = normalizeBytes32(
    manifest.recipientEnvelopeRoot,
    "recipientEnvelopeRoot",
  );

  if (normalizedVisibility === "public") {
    if (normalizedContentHash === undefined) {
      throw new Error("contentHash is required for public resource manifests");
    }
  } else {
    if (normalizedCiphertextHash === undefined) {
      throw new Error(
        "ciphertextHash is required for protected and private resource manifests",
      );
    }
    if (normalizedRecipientEnvelopeRoot === ZERO_BYTES32) {
      throw new Error(
        "recipientEnvelopeRoot must be non-zero for protected and private resource manifests",
      );
    }
  }

  return {
    schemaVersion: RESOURCE_MANIFEST_V1_SCHEMA_VERSION,
    orderId: normalizeNonZeroBytes32(manifest.orderId, "orderId"),
    targetStageId: normalizeNonZeroBytes32(
      manifest.targetStageId,
      "targetStageId",
    ),
    resourceKey: normalizeNonZeroBytes32(manifest.resourceKey, "resourceKey"),
    visibility: normalizedVisibility,
    ...(normalizedContentHash !== undefined
      ? { contentHash: normalizedContentHash }
      : {}),
    ...(normalizedCiphertextHash !== undefined
      ? { ciphertextHash: normalizedCiphertextHash }
      : {}),
    storageCID: manifest.storageCID,
    policyHash: normalizeNonZeroBytes32(manifest.policyHash, "policyHash"),
    recipientEnvelopeRoot: normalizedRecipientEnvelopeRoot,
    createdBy: normalizeAddress(manifest.createdBy, "createdBy"),
    createdAt: manifest.createdAt,
    ...(manifest.supersedes !== undefined
      ? {
          supersedes: normalizeNonZeroBytes32(
            manifest.supersedes,
            "supersedes",
          ),
        }
      : {}),
  };
}

function normalizeOptionalBytes32(
  value: Hex | string | undefined,
  fieldName: string,
): Hex | undefined {
  if (value === undefined) {
    return undefined;
  }
  return normalizeNonZeroBytes32(value, fieldName);
}

function normalizeNonZeroBytes32(value: Hex | string, fieldName: string): Hex {
  const normalized = normalizeBytes32(value, fieldName);
  if (normalized === ZERO_BYTES32) {
    throw new Error(`${fieldName} must be non-zero`);
  }
  return normalized;
}

function assertAllowedResourceManifestKeys(manifest: ResourceManifestV1): void {
  for (const key of Object.keys(manifest)) {
    if (!ALLOWED_RESOURCE_MANIFEST_KEYS.has(key)) {
      throw new Error(
        `resource manifest field ${key} is not part of ResourceManifestV1`,
      );
    }
  }
}

function isResourceVisibility(value: unknown): value is ResourceVisibility {
  return value === "public" || value === "protected" || value === "private";
}

function hashCanonicalJson(domain: string, payload: unknown): Hex {
  return keccak256(stringToHex(`${domain}:${canonicalJson(payload)}`));
}

function normalizeChainId(value: number): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error("chainId must be a positive safe integer");
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

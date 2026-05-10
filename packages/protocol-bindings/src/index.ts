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
} from 'viem';

export const STATE_MACHINE_ABI = parseAbi([
  'event OwnershipTransferred(address indexed previousOwner,address indexed newOwner)',
  'event StateMachineModuleSet(bytes32 indexed moduleId,address indexed previousModule,address indexed newModule)',
  'event PlanPublisherSet(address indexed publisher,bool allowed)',
  'event OrderRegistrarSet(address indexed registrar,bool allowed)',
  'event HookReady(bytes32 indexed orderId,bytes32 indexed hookId,bytes32 indexed stageId,bytes32 hookName)',
  'event SignalSubmitted(bytes32 indexed orderId,bytes32 indexed sourceId,bytes32 indexed signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter)',
  'event PlanRegistered(bytes32 indexed planId,bytes32 planHash,uint256 hookCount)',
  'event PlanPublisherRecorded(bytes32 indexed planId,address indexed publisher)',
  'event OrderRegistered(bytes32 indexed orderId,bytes32 indexed planId)',
  'event OrderMaterialized(bytes32 indexed orderId,bytes32 indexed planId,bytes32 indexed stageId)',
  'event OrderRegistrarRecorded(bytes32 indexed orderId,address indexed registrar,address indexed creator)',
  'event SignalSubmitterAuthorized(bytes32 indexed orderId,bytes32 indexed sourceId,bytes32 indexed signalId,address submitter,bytes32 role,bytes32 metadataHash)',
  'event StageMaterialized(bytes32 indexed orderId,bytes32 indexed stageId,bytes32 indexed triggerHookId,bytes32 sourceId,bytes32 signalId)',
  'event OrderTriggered(bytes32 indexed orderId,bytes32 indexed planId,bytes32 indexed triggerStageId,bytes32 sourceId,bytes32 signalId,address submitter)',
  'event StageExecutorActivated(bytes32 indexed orderId,bytes32 indexed targetStageId,address indexed executor,bytes32 role,bytes32 metadataHash,uint256 patchNonce)',
  'function owner() view returns (address)',
  'function stagePatchModule() view returns (address)',
  'function derivedSignalModule() view returns (address)',
  'function dockingModule() view returns (address)',
  'function planMetadataModule() view returns (address)',
  'function orderLinkModule() view returns (address)',
  'function lens() view returns (address)',
  'function transferOwnership(address newOwner)',
  'function setStagePatchModule(address moduleAddress)',
  'function setDerivedSignalModule(address moduleAddress)',
  'function setDockingModule(address moduleAddress)',
  'function setPlanMetadataModule(address moduleAddress)',
  'function setOrderLinkModule(address moduleAddress)',
  'function setLens(address moduleAddress)',
  'function setPlanPublisher(address publisher,bool allowed)',
  'function setOrderRegistrar(address registrar,bool allowed)',
  'function planPublishers(address publisher) view returns (bool)',
  'function orderRegistrars(address registrar) view returns (bool)',
  'function registerPlan(bytes32 planId,bytes32 planHash,(bytes32 hookId,bytes32 stageId,bytes32 hookName,bool isTrigger,(uint8 op,bytes32 sourceId,bytes32 signalId,uint16 arity,uint64 delaySeconds)[] instructions,bytes32[] dependencyKeys)[] hooks)',
  'function triggerOrderFromOutsideFor((bytes32 orderId,bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline) trigger,(bytes32 sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)[] authorizations,bytes signature)',
  'function submitSignal(bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey)',
  'function submitSignalFor(bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline,bytes signature)',
  'function submitSignalFromModule(bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter)',
  'function triggerOrderFromSignalFromModule((bytes32 orderId,bytes32 planId,address creator,bytes32 triggerOriginOrderId,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 originSourceId,bytes32 originSignalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline) trigger,(bytes32 sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)[] authorizations,address registrar)',
  'function activateStageExecutorFromModule(bytes32 orderId,bytes32 targetStageId,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 patchHash,uint256 patchNonce)',
  'function SIGNAL_TARGET_CURRENT_ORDER() view returns (uint8)',
  'function SIGNAL_TARGET_TRIGGER_ORIGIN() view returns (uint8)',
  'function sourceSignalCount(bytes32 orderId,bytes32 sourceId) view returns (uint256)',
  'function lastSignalSubmitter(bytes32 orderId,bytes32 sourceId) view returns (address)',
  'function DOMAIN_SEPARATOR() view returns (bytes32)',
  'function orderPlanId(bytes32 orderId) view returns (bytes32)',
  'function planPublisher(bytes32 planId) view returns (address)',
  'function orderRegistrar(bytes32 orderId) view returns (address)',
  'function orderCreator(bytes32 orderId) view returns (address)',
  'function hasExplicitSignalAuthorization(bytes32 orderId,bytes32 sourceId,bytes32 signalId,address submitter) view returns (bool)',
]);

export const PLAN_METADATA_MODULE_ABI = parseAbi([
  'event StageSelectorBindingRegistered(bytes32 indexed planId,bytes32 indexed selectorStageId,bytes32 indexed targetStageId)',
  'event SignalCapabilityRegistered(bytes32 indexed planId,bytes32 indexed stageId,bytes32 indexed targetSourceId,bytes32 signalId,uint8 targetOrderRelation)',
  'function registerPlanMetadata(bytes32 planId,(bytes32 selectorStageId,bytes32 targetStageId)[] selectorBindings,(bytes32 stageId,bytes32 targetSourceId,bytes32 signalId,uint8 targetOrderRelation)[] signalCapabilities)',
  'function planSelectorBindingCount(bytes32 planId) view returns (uint256)',
  'function planSelectorBindingAt(bytes32 planId,uint256 index) view returns (bytes32 selectorStageId,bytes32 targetStageId)',
  'function planSignalCapabilityCount(bytes32 planId) view returns (uint256)',
  'function isStageSelectorBound(bytes32 planId,bytes32 selectorStageId,bytes32 targetStageId) view returns (bool)',
  'function isSignalCapabilityRegistered(bytes32 planId,bytes32 stageId,bytes32 targetSourceId,bytes32 signalId,uint8 targetOrderRelation) view returns (bool)',
  'function stageSelectorBindingKey(bytes32 selectorStageId,bytes32 targetStageId) pure returns (bytes32)',
  'function signalCapabilityKey(bytes32 stageId,bytes32 targetSourceId,bytes32 signalId,uint8 targetOrderRelation) pure returns (bytes32)',
]);

export const ORDER_LINK_MODULE_ABI = parseAbi([
  'event OrderLinked(bytes32 indexed triggeredOrderId,bytes32 indexed triggerOriginOrderId,bytes32 indexed triggerStageId,bytes32 originSourceId,bytes32 originSignalId)',
  'function triggerOrderFromSignalFor((bytes32 orderId,bytes32 planId,address creator,bytes32 triggerOriginOrderId,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 originSourceId,bytes32 originSignalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline) trigger,(bytes32 sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)[] authorizations,bytes signature)',
  'function targetOrderRelation(bytes32 fromOrderId,bytes32 targetOrderId) view returns (uint8)',
  'function getTriggerOriginLink(bytes32 triggeredOrderId) view returns (bool exists,bytes32 triggerOriginOrderId,bytes32 originSourceId,bytes32 originSignalId,bytes32 triggerStageId)',
  'function signalAuthorizationsHash((bytes32 sourceId,bytes32 signalId,address submitter,bytes32 role,bytes32 metadataHash)[] authorizations) pure returns (bytes32)',
  'function triggerOrderFromSignalDigest((bytes32 orderId,bytes32 planId,address creator,bytes32 triggerOriginOrderId,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 originSourceId,bytes32 originSignalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline) trigger,bytes32 authorizationsHash) view returns (bytes32)',
]);

export const STAGE_PATCH_MODULE_ABI = parseAbi([
  'event StageExecutorPatchApplied(bytes32 indexed orderId,bytes32 indexed selectorStageId,bytes32 indexed targetStageId,address selector,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 mode,address previousExecutor,bytes32 approvalSourceId,bytes32 approvalSignalId,bytes32 patchHash,uint256 patchNonce,string metadataURI)',
  'event StageResourcePatchApplied(bytes32 indexed orderId,bytes32 indexed selectorStageId,bytes32 indexed targetStageId,address selector,bytes32 resourceKey,bytes32 manifestHash,bytes32 policyHash,bytes32 patchHash,uint256 patchNonce,string manifestURI)',
  'function EXECUTOR_PATCH_SIGNAL_ID() view returns (bytes32)',
  'function RESOURCE_PATCH_SIGNAL_ID() view returns (bytes32)',
  'function EXECUTOR_PATCH_MODE_ASSIGN() view returns (bytes32)',
  'function EXECUTOR_PATCH_MODE_HANDOFF() view returns (bytes32)',
  'function EXECUTOR_PATCH_MODE_REPLACEMENT() view returns (bytes32)',
  'function applyStageExecutorPatch(bytes32 orderId,(bytes32 selectorStageId,bytes32 targetStageId,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 mode,address previousExecutor,bytes32 approvalSourceId,bytes32 approvalSignalId,bytes32 patchHash,uint256 patchNonce,string metadataURI) patch)',
  'function applyStageExecutorPatchFor(bytes32 orderId,(bytes32 selectorStageId,bytes32 targetStageId,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 mode,address previousExecutor,bytes32 approvalSourceId,bytes32 approvalSignalId,bytes32 patchHash,uint256 patchNonce,string metadataURI) patch,address selector,uint256 deadline,bytes selectorSignature,bytes previousExecutorSignature)',
  'function applyStageResourcePatch(bytes32 orderId,(bytes32 selectorStageId,bytes32 targetStageId,bytes32 resourceKey,bytes32 manifestHash,bytes32 policyHash,bytes32 patchHash,uint256 patchNonce,string manifestURI) patch)',
  'function applyStageResourcePatchFor(bytes32 orderId,(bytes32 selectorStageId,bytes32 targetStageId,bytes32 resourceKey,bytes32 manifestHash,bytes32 policyHash,bytes32 patchHash,uint256 patchNonce,string manifestURI) patch,address selector,uint256 deadline,bytes signature)',
  'function stageExecutorPatchDigest(bytes32 orderId,(bytes32 selectorStageId,bytes32 targetStageId,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 mode,address previousExecutor,bytes32 approvalSourceId,bytes32 approvalSignalId,bytes32 patchHash,uint256 patchNonce,string metadataURI) patch,address selector,uint256 deadline) view returns (bytes32)',
  'function stageResourcePatchDigest(bytes32 orderId,(bytes32 selectorStageId,bytes32 targetStageId,bytes32 resourceKey,bytes32 manifestHash,bytes32 policyHash,bytes32 patchHash,uint256 patchNonce,string manifestURI) patch,address selector,uint256 deadline) view returns (bytes32)',
  'function getActiveStageExecutorPatch(bytes32 orderId,bytes32 targetStageId) view returns (bool exists,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 patchHash,uint256 patchNonce,string metadataURI)',
  'function getActiveStageResourcePatch(bytes32 orderId,bytes32 targetStageId,bytes32 resourceKey) view returns (bool exists,bytes32 manifestHash,bytes32 policyHash,bytes32 patchHash,uint256 patchNonce,string manifestURI)',
]);

export const DERIVED_SIGNAL_MODULE_ABI = parseAbi([
  'function submitDerivedSignal(bytes32 fromOrderId,bytes32 fromStageId,bytes32 targetOrderId,bytes32 targetSourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey)',
  'function submitDerivedSignalFor(bytes32 fromOrderId,bytes32 fromStageId,bytes32 targetOrderId,bytes32 targetSourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline,bytes signature)',
  'function derivedSignalDigest(bytes32 fromOrderId,bytes32 fromStageId,bytes32 targetOrderId,bytes32 targetSourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline) view returns (bytes32)',
]);

export const DOCKING_MODULE_ABI = parseAbi([
  'event DockedOrderLinked(bytes32 indexed localOrderId,bytes32 indexed linkedOrderId,bytes32 indexed localSourceId,bytes32 selectorStageId,bytes32 linkedPlanId,address selector,bytes32 linkHash,uint256 linkNonce,string metadataURI)',
  'event DockedSignalMapped(bytes32 indexed localOrderId,bytes32 indexed linkedOrderId,bytes32 indexed linkedSourceId,bytes32 linkedSignalId,bytes32 localSourceId,bytes32 localSignalId)',
  'event DockedSignalSubmitted(bytes32 indexed localOrderId,bytes32 indexed linkedOrderId,bytes32 indexed linkedSourceId,bytes32 linkedSignalId,bytes32 localSourceId,bytes32 localSignalId,bytes32 payloadHash,address submitter)',
  'function DOCKED_ORDER_LINK_SIGNAL_ID() view returns (bytes32)',
  'function linkDockedOrder(bytes32 localOrderId,(bytes32 selectorStageId,bytes32 localSourceId,bytes32 linkedOrderId,bytes32 linkedPlanId,bytes32 linkHash,uint256 linkNonce,string metadataURI,(bytes32 localSourceId,bytes32 localSignalId,bytes32 linkedSourceId,bytes32 linkedSignalId)[] signalBindings) link)',
  'function linkDockedOrderFor(bytes32 localOrderId,(bytes32 selectorStageId,bytes32 localSourceId,bytes32 linkedOrderId,bytes32 linkedPlanId,bytes32 linkHash,uint256 linkNonce,string metadataURI,(bytes32 localSourceId,bytes32 localSignalId,bytes32 linkedSourceId,bytes32 linkedSignalId)[] signalBindings) link,address selector,uint256 deadline,bytes signature)',
  'function submitDockedSignal(bytes32 localOrderId,bytes32 linkedOrderId,bytes32 linkedSourceId,bytes32 linkedSignalId,bytes32 idempotencyKey)',
  'function dockedOrderLinkDigest(bytes32 localOrderId,(bytes32 selectorStageId,bytes32 localSourceId,bytes32 linkedOrderId,bytes32 linkedPlanId,bytes32 linkHash,uint256 linkNonce,string metadataURI,(bytes32 localSourceId,bytes32 localSignalId,bytes32 linkedSourceId,bytes32 linkedSignalId)[] signalBindings) link,address selector,uint256 deadline) view returns (bytes32)',
  'function getActiveDockedOrderLink(bytes32 localOrderId,bytes32 linkedOrderId) view returns (bool exists,bytes32 selectorStageId,bytes32 localSourceId,bytes32 linkedPlanId,address selector,bytes32 linkHash,uint256 linkNonce,string metadataURI)',
  'function getActiveDockedSignalBinding(bytes32 localOrderId,bytes32 linkedOrderId,bytes32 linkedSourceId,bytes32 linkedSignalId) view returns (bool exists,bytes32 localSourceId,bytes32 localSignalId)',
]);

export const STATE_MACHINE_LENS_ABI = parseAbi([
  'function stateMachine() view returns (address)',
  'function getActiveStageExecutorPatch(bytes32 orderId,bytes32 targetStageId) view returns (bool exists,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 patchHash,uint256 patchNonce,string metadataURI)',
  'function getActiveStageResourcePatch(bytes32 orderId,bytes32 targetStageId,bytes32 resourceKey) view returns (bool exists,bytes32 manifestHash,bytes32 policyHash,bytes32 patchHash,uint256 patchNonce,string manifestURI)',
  'function getActiveDockedOrderLink(bytes32 localOrderId,bytes32 linkedOrderId) view returns (bool exists,bytes32 selectorStageId,bytes32 localSourceId,bytes32 linkedPlanId,address selector,bytes32 linkHash,uint256 linkNonce,string metadataURI)',
  'function getActiveDockedSignalBinding(bytes32 localOrderId,bytes32 linkedOrderId,bytes32 linkedSourceId,bytes32 linkedSignalId) view returns (bool exists,bytes32 localSourceId,bytes32 localSignalId)',
  'function planSelectorBindingCount(bytes32 planId) view returns (uint256)',
  'function planSelectorBindingAt(bytes32 planId,uint256 index) view returns (bytes32 selectorStageId,bytes32 targetStageId)',
  'function planSignalCapabilityCount(bytes32 planId) view returns (uint256)',
  'function isStageSelectorBound(bytes32 planId,bytes32 selectorStageId,bytes32 targetStageId) view returns (bool)',
  'function isSignalCapabilityRegistered(bytes32 planId,bytes32 stageId,bytes32 targetSourceId,bytes32 signalId,uint8 targetOrderRelation) view returns (bool)',
  'function targetOrderRelation(bytes32 fromOrderId,bytes32 targetOrderId) view returns (uint8)',
  'function getTriggerOriginLink(bytes32 triggeredOrderId) view returns (bool exists,bytes32 triggerOriginOrderId,bytes32 originSourceId,bytes32 originSignalId,bytes32 triggerStageId)',
]);

export const PRODUCT_SUBMIT_DOMAIN_NAME = 'UVPStateMachine';
export const PRODUCT_SUBMIT_DOMAIN_VERSION = '0.7';
export const PRODUCT_SUBMIT_PRIMARY_TYPE = 'UVPStateMachineSignal';
export const TRIGGER_ORDER_FROM_OUTSIDE_PRIMARY_TYPE = 'UVPStateMachineTriggerOrderFromOutside';
export const ORDER_LINK_DOMAIN_NAME = 'UVPOrderLinkModule';
export const ORDER_LINK_DOMAIN_VERSION = '0.7';
export const TRIGGER_ORDER_FROM_SIGNAL_PRIMARY_TYPE = 'UVPOrderLinkModuleTriggerOrderFromSignal';
export const DERIVED_SIGNAL_DOMAIN_NAME = 'UVPDerivedSignalModule';
export const DERIVED_SIGNAL_DOMAIN_VERSION = '0.6';
export const DERIVED_SIGNAL_PRIMARY_TYPE = 'UVPDerivedSignalModuleSignal';
export const STAGE_EXECUTOR_PATCH_DOMAIN_NAME = 'UVPStagePatchModule';
export const STAGE_EXECUTOR_PATCH_DOMAIN_VERSION = '0.1';
export const STAGE_EXECUTOR_PATCH_PRIMARY_TYPE = 'UVPStagePatchModuleStageExecutorPatch';
export const STAGE_RESOURCE_PATCH_DOMAIN_NAME = STAGE_EXECUTOR_PATCH_DOMAIN_NAME;
export const STAGE_RESOURCE_PATCH_DOMAIN_VERSION = STAGE_EXECUTOR_PATCH_DOMAIN_VERSION;
export const STAGE_RESOURCE_PATCH_PRIMARY_TYPE = 'UVPStagePatchModuleStageResourcePatch';
export const DOCKED_ORDER_LINK_DOMAIN_NAME = 'UVPDockingModule';
export const DOCKED_ORDER_LINK_DOMAIN_VERSION = '0.1';
export const DOCKED_ORDER_LINK_PRIMARY_TYPE = 'UVPDockingModuleDockedOrderLink';
export const STAGE_EXECUTOR_PATCH_PAYLOAD_HASH_DOMAIN = 'uvp:stage-executor-patch-payload:v1';
export const STAGE_RESOURCE_PATCH_PAYLOAD_HASH_DOMAIN = 'uvp:stage-resource-patch-payload:v1';
export const DOCKED_ORDER_LINK_PAYLOAD_HASH_DOMAIN = 'uvp:docked-order-link-payload:v1';
export const RESOURCE_MANIFEST_V1_SCHEMA_VERSION = 'uvp-resource-manifest-v1';
export const RESOURCE_MANIFEST_HASH_DOMAIN = 'uvp:resource-manifest:v1';
export const LEGACY_FILE_RESOURCE_HANDLE_TYPES = ['http', 'txcloud', 'plain_text'] as const;
export const DOCKED_ORDER_LINK_SIGNAL_ID = keccak256(stringToHex('uvp.docked_order_link.v1'));
export const EXECUTOR_PATCH_MODE_ASSIGN = stringToHex('assign', { size: 32 }) as Hex;
export const EXECUTOR_PATCH_MODE_HANDOFF = stringToHex('handoff', { size: 32 }) as Hex;
export const EXECUTOR_PATCH_MODE_REPLACEMENT = stringToHex('replacement', { size: 32 }) as Hex;

export interface ProductSubmitTypedDataField {
  readonly name: string;
  readonly type: string;
}

export const PRODUCT_SUBMIT_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] = [
  { name: 'orderId', type: 'bytes32' },
  { name: 'sourceId', type: 'bytes32' },
  { name: 'signalId', type: 'bytes32' },
  { name: 'payloadHash', type: 'bytes32' },
  { name: 'idempotencyKey', type: 'bytes32' },
  { name: 'submitter', type: 'address' },
  { name: 'deadline', type: 'uint256' },
];

export const TRIGGER_ORDER_FROM_OUTSIDE_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] = [
  { name: 'orderId', type: 'bytes32' },
  { name: 'planId', type: 'bytes32' },
  { name: 'creator', type: 'address' },
  { name: 'triggerHookId', type: 'bytes32' },
  { name: 'triggerStageId', type: 'bytes32' },
  { name: 'sourceId', type: 'bytes32' },
  { name: 'signalId', type: 'bytes32' },
  { name: 'payloadHash', type: 'bytes32' },
  { name: 'idempotencyKey', type: 'bytes32' },
  { name: 'authorizationsHash', type: 'bytes32' },
  { name: 'submitter', type: 'address' },
  { name: 'deadline', type: 'uint256' },
];

export const TRIGGER_ORDER_FROM_SIGNAL_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] = [
  { name: 'orderId', type: 'bytes32' },
  { name: 'planId', type: 'bytes32' },
  { name: 'creator', type: 'address' },
  { name: 'triggerOriginOrderId', type: 'bytes32' },
  { name: 'triggerHookId', type: 'bytes32' },
  { name: 'triggerStageId', type: 'bytes32' },
  { name: 'originSourceId', type: 'bytes32' },
  { name: 'originSignalId', type: 'bytes32' },
  { name: 'payloadHash', type: 'bytes32' },
  { name: 'idempotencyKey', type: 'bytes32' },
  { name: 'authorizationsHash', type: 'bytes32' },
  { name: 'submitter', type: 'address' },
  { name: 'deadline', type: 'uint256' },
];

export const STAGE_EXECUTOR_PATCH_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] = [
  { name: 'orderId', type: 'bytes32' },
  { name: 'selectorStageId', type: 'bytes32' },
  { name: 'targetStageId', type: 'bytes32' },
  { name: 'executor', type: 'address' },
  { name: 'role', type: 'bytes32' },
  { name: 'executorMetadataHash', type: 'bytes32' },
  { name: 'mode', type: 'bytes32' },
  { name: 'previousExecutor', type: 'address' },
  { name: 'approvalSourceId', type: 'bytes32' },
  { name: 'approvalSignalId', type: 'bytes32' },
  { name: 'patchHash', type: 'bytes32' },
  { name: 'patchNonce', type: 'uint256' },
  { name: 'metadataURI', type: 'string' },
  { name: 'selector', type: 'address' },
  { name: 'deadline', type: 'uint256' },
];

export const STAGE_RESOURCE_PATCH_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] = [
  { name: 'orderId', type: 'bytes32' },
  { name: 'selectorStageId', type: 'bytes32' },
  { name: 'targetStageId', type: 'bytes32' },
  { name: 'resourceKey', type: 'bytes32' },
  { name: 'manifestHash', type: 'bytes32' },
  { name: 'policyHash', type: 'bytes32' },
  { name: 'patchHash', type: 'bytes32' },
  { name: 'patchNonce', type: 'uint256' },
  { name: 'manifestURI', type: 'string' },
  { name: 'selector', type: 'address' },
  { name: 'deadline', type: 'uint256' },
];

export const DOCKED_ORDER_LINK_TYPED_DATA_FIELDS: readonly ProductSubmitTypedDataField[] = [
  { name: 'localOrderId', type: 'bytes32' },
  { name: 'selectorStageId', type: 'bytes32' },
  { name: 'localSourceId', type: 'bytes32' },
  { name: 'linkedOrderId', type: 'bytes32' },
  { name: 'linkedPlanId', type: 'bytes32' },
  { name: 'linkHash', type: 'bytes32' },
  { name: 'linkNonce', type: 'uint256' },
  { name: 'signalBindingsHash', type: 'bytes32' },
  { name: 'metadataURI', type: 'string' },
  { name: 'selector', type: 'address' },
  { name: 'deadline', type: 'uint256' },
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
    readonly orderId: Hex;
    readonly sourceId: Hex;
    readonly signalId: Hex;
    readonly payloadHash: Hex;
    readonly idempotencyKey: Hex;
    readonly submitter: Address;
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
  readonly domain: ProductSubmitTypedData['domain'];
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

export interface DockedSignalBindingPayload {
  readonly localSourceId: Hex | string;
  readonly localSignalId: Hex | string;
  readonly linkedSourceId: Hex | string;
  readonly linkedSignalId: Hex | string;
}

export interface DockedOrderLinkPayload {
  readonly selectorStageId: Hex | string;
  readonly localSourceId: Hex | string;
  readonly linkedOrderId: Hex | string;
  readonly linkedPlanId: Hex | string;
  readonly linkNonce: bigint | number | string;
  readonly metadataURI: string;
  readonly signalBindings: readonly DockedSignalBindingPayload[];
}

export interface DockedOrderLinkCallLink extends DockedOrderLinkPayload {
  readonly linkHash: Hex | string;
}

export interface DockedOrderLinkTypedData {
  readonly domain: {
    readonly name: typeof DOCKED_ORDER_LINK_DOMAIN_NAME;
    readonly version: typeof DOCKED_ORDER_LINK_DOMAIN_VERSION;
    readonly chainId: number;
    readonly verifyingContract: Address;
  };
  readonly types: {
    readonly UVPDockingModuleDockedOrderLink: readonly ProductSubmitTypedDataField[];
  };
  readonly primaryType: typeof DOCKED_ORDER_LINK_PRIMARY_TYPE;
  readonly message: {
    readonly localOrderId: Hex;
    readonly selectorStageId: Hex;
    readonly localSourceId: Hex;
    readonly linkedOrderId: Hex;
    readonly linkedPlanId: Hex;
    readonly linkHash: Hex;
    readonly linkNonce: string;
    readonly signalBindingsHash: Hex;
    readonly metadataURI: string;
    readonly selector: Address;
    readonly deadline: string;
  };
}

export type ResourceVisibility = 'public' | 'protected' | 'private';

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
  readonly orderId: Hex | string;
  readonly sourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly payloadHash: Hex | string;
  readonly idempotencyKey: Hex | string;
  readonly submitter: Address | string;
  readonly deadline: string;
}

export interface BuildTriggerOrderFromOutsideTypedDataInput extends TriggerOrderFromOutsidePayload {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
  readonly authorizations: readonly SignalAuthorizationPayload[];
}

export interface BuildTriggerOrderFromSignalTypedDataInput extends TriggerOrderFromSignalPayload {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
  readonly authorizations: readonly SignalAuthorizationPayload[];
}

export interface BuildStageExecutorPatchTypedDataInput extends StageExecutorPatchCallPatch {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
  readonly orderId: Hex | string;
  readonly selector: Address | string;
  readonly deadline: bigint | number | string;
}

export interface BuildStageResourcePatchTypedDataInput extends StageResourcePatchCallPatch {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
  readonly orderId: Hex | string;
  readonly selector: Address | string;
  readonly deadline: bigint | number | string;
}

export interface BuildDockedOrderLinkTypedDataInput extends DockedOrderLinkCallLink {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
  readonly localOrderId: Hex | string;
  readonly selector: Address | string;
  readonly deadline: bigint | number | string;
}

export interface SubmitSignalForCallArgs {
  readonly orderId: Hex | string;
  readonly sourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly payloadHash: Hex | string;
  readonly idempotencyKey: Hex | string;
  readonly submitter: Address | string;
  readonly deadline: bigint | number | string;
  readonly signature: Hex | string;
}

export interface SubmitDerivedSignalForCallArgs {
  readonly fromOrderId: Hex | string;
  readonly fromStageId: Hex | string;
  readonly targetOrderId: Hex | string;
  readonly targetSourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly payloadHash: Hex | string;
  readonly idempotencyKey: Hex | string;
  readonly submitter: Address | string;
  readonly deadline: bigint | number | string;
  readonly signature: Hex | string;
}

export interface TriggerOrderFromOutsideForCallArgs extends TriggerOrderFromOutsidePayload {
  readonly authorizations: readonly SignalAuthorizationPayload[];
  readonly signature: Hex | string;
}

export interface TriggerOrderFromSignalForCallArgs extends TriggerOrderFromSignalPayload {
  readonly authorizations: readonly SignalAuthorizationPayload[];
  readonly signature: Hex | string;
}

export interface ApplyStageExecutorPatchForCallArgs {
  readonly orderId: Hex | string;
  readonly patch: StageExecutorPatchCallPatch;
  readonly selector: Address | string;
  readonly deadline: bigint | number | string;
  readonly selectorSignature: Hex | string;
  readonly previousExecutorSignature: Hex | string;
}

export interface ApplyStageResourcePatchForCallArgs {
  readonly orderId: Hex | string;
  readonly patch: StageResourcePatchCallPatch;
  readonly selector: Address | string;
  readonly deadline: bigint | number | string;
  readonly signature: Hex | string;
}

export interface LinkDockedOrderForCallArgs {
  readonly localOrderId: Hex | string;
  readonly link: DockedOrderLinkCallLink;
  readonly selector: Address | string;
  readonly deadline: bigint | number | string;
  readonly signature: Hex | string;
}

export interface SubmitDockedSignalCallArgs {
  readonly localOrderId: Hex | string;
  readonly linkedOrderId: Hex | string;
  readonly linkedSourceId: Hex | string;
  readonly linkedSignalId: Hex | string;
  readonly idempotencyKey: Hex | string;
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
export type LinkDockedOrderForCallConfig = DockingModuleCallConfig;
export type SubmitDockedSignalCallConfig = DockingModuleCallConfig;
export type SubmitDerivedSignalForCallConfig = DerivedSignalModuleCallConfig;
export type TriggerOrderFromOutsideForCallConfig = SubmitSignalForCallConfig;
export type TriggerOrderFromSignalForCallConfig = OrderLinkModuleCallConfig;

export interface SubmitSignalForCall {
  readonly address: Address;
  readonly abi: typeof STATE_MACHINE_ABI;
  readonly functionName: 'submitSignalFor';
  readonly args: readonly [Hex, Hex, Hex, Hex, Hex, Address, bigint, Hex];
  readonly data: Hex;
  readonly chainId?: number;
}

export interface SubmitDerivedSignalForCall {
  readonly address: Address;
  readonly abi: typeof DERIVED_SIGNAL_MODULE_ABI;
  readonly functionName: 'submitDerivedSignalFor';
  readonly args: readonly [Hex, Hex, Hex, Hex, Hex, Hex, Hex, Address, bigint, Hex];
  readonly data: Hex;
  readonly chainId?: number;
}

export type SignalAuthorizationCallTuple = readonly [Hex, Hex, Address, Hex, Hex];

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
  Address,
  bigint,
];

export interface TriggerOrderFromSignalCallStruct {
  readonly orderId: Hex;
  readonly planId: Hex;
  readonly creator: Address;
  readonly triggerOriginOrderId: Hex;
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
  readonly functionName: 'triggerOrderFromOutsideFor';
  readonly args: readonly [TriggerOrderFromOutsideCallTuple, readonly SignalAuthorizationCallTuple[], Hex];
  readonly data: Hex;
  readonly chainId?: number;
}

export interface TriggerOrderFromSignalForCall {
  readonly address: Address;
  readonly abi: typeof ORDER_LINK_MODULE_ABI;
  readonly functionName: 'triggerOrderFromSignalFor';
  readonly args: readonly [TriggerOrderFromSignalCallStruct, readonly SignalAuthorizationCallStruct[], Hex];
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
  readonly functionName: 'applyStageExecutorPatchFor';
  readonly args: readonly [Hex, StageExecutorPatchCallTuple, Address, bigint, Hex, Hex];
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
  readonly functionName: 'applyStageResourcePatchFor';
  readonly args: readonly [Hex, StageResourcePatchCallTuple, Address, bigint, Hex];
  readonly data: Hex;
  readonly chainId?: number;
}

export type DockedSignalBindingCallTuple = readonly [Hex, Hex, Hex, Hex];

export type DockedOrderLinkCallTuple = readonly [
  Hex,
  Hex,
  Hex,
  Hex,
  Hex,
  bigint,
  string,
  readonly DockedSignalBindingCallTuple[],
];

export interface LinkDockedOrderForCall {
  readonly address: Address;
  readonly abi: typeof DOCKING_MODULE_ABI;
  readonly functionName: 'linkDockedOrderFor';
  readonly args: readonly [Hex, DockedOrderLinkCallTuple, Address, bigint, Hex];
  readonly data: Hex;
  readonly chainId?: number;
}

export interface SubmitDockedSignalCall {
  readonly address: Address;
  readonly abi: typeof DOCKING_MODULE_ABI;
  readonly functionName: 'submitDockedSignal';
  readonly args: readonly [Hex, Hex, Hex, Hex, Hex];
  readonly data: Hex;
  readonly chainId?: number;
}

export interface EvidenceHashResult {
  readonly algorithm: 'keccak256';
  readonly evidenceHash: Hex;
  readonly byteLength: number;
  readonly source: 'bytes' | 'json' | 'text';
}

const BYTES32_RE = /^0x[a-fA-F0-9]{64}$/;
const ZERO_BYTES32 = `0x${'0'.repeat(64)}` as Hex;
const ZERO_ADDRESS = `0x${'0'.repeat(40)}` as Address;
const LEGACY_FILE_RESOURCE_HANDLE_TYPE_SET = new Set<string>(LEGACY_FILE_RESOURCE_HANDLE_TYPES);
const LEGACY_HANDLE_FIELD_NAMES = new Set(['handletype', 'filetype', 'resourcetype', 'storagetype', 'type']);
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
  'schemaVersion',
  'orderId',
  'targetStageId',
  'resourceKey',
  'visibility',
  'contentHash',
  'ciphertextHash',
  'storageCID',
  'policyHash',
  'recipientEnvelopeRoot',
  'createdBy',
  'createdAt',
  'supersedes',
]);

export function buildProductSubmitTypedData(input: BuildProductSubmitTypedDataInput): ProductSubmitTypedData {
  return {
    domain: {
      name: PRODUCT_SUBMIT_DOMAIN_NAME,
      version: PRODUCT_SUBMIT_DOMAIN_VERSION,
      chainId: normalizeChainId(input.chainId),
      verifyingContract: normalizeAddress(input.verifyingContract, 'verifyingContract'),
    },
    types: {
      UVPStateMachineSignal: PRODUCT_SUBMIT_TYPED_DATA_FIELDS,
    },
    primaryType: PRODUCT_SUBMIT_PRIMARY_TYPE,
    message: {
      orderId: normalizeBytes32(input.orderId, 'orderId'),
      sourceId: normalizeBytes32(input.sourceId, 'sourceId'),
      signalId: normalizeBytes32(input.signalId, 'signalId'),
      payloadHash: normalizeBytes32(input.payloadHash, 'payloadHash'),
      idempotencyKey: normalizeBytes32(input.idempotencyKey, 'idempotencyKey'),
      submitter: normalizeAddress(input.submitter, 'submitter'),
      deadline: normalizeUintString(input.deadline, 'deadline'),
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
      verifyingContract: normalizeAddress(input.verifyingContract, 'verifyingContract'),
    },
    types: {
      UVPStateMachineTriggerOrderFromOutside: TRIGGER_ORDER_FROM_OUTSIDE_TYPED_DATA_FIELDS,
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
      verifyingContract: normalizeAddress(input.verifyingContract, 'verifyingContract'),
    },
    types: {
      UVPOrderLinkModuleTriggerOrderFromSignal: TRIGGER_ORDER_FROM_SIGNAL_TYPED_DATA_FIELDS,
    },
    primaryType: TRIGGER_ORDER_FROM_SIGNAL_PRIMARY_TYPE,
    message: {
      orderId: trigger[0],
      planId: trigger[1],
      creator: trigger[2],
      triggerOriginOrderId: trigger[3],
      triggerHookId: trigger[4],
      triggerStageId: trigger[5],
      originSourceId: trigger[6],
      originSignalId: trigger[7],
      payloadHash: trigger[8],
      idempotencyKey: trigger[9],
      authorizationsHash: hashSignalAuthorizations(input.authorizations),
      submitter: trigger[10],
      deadline: trigger[11].toString(10),
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
      verifyingContract: normalizeAddress(input.verifyingContract, 'verifyingContract'),
    },
    types: {
      UVPStagePatchModuleStageExecutorPatch: STAGE_EXECUTOR_PATCH_TYPED_DATA_FIELDS,
    },
    primaryType: STAGE_EXECUTOR_PATCH_PRIMARY_TYPE,
    message: {
      orderId: normalizeBytes32(input.orderId, 'orderId'),
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
      selector: normalizeAddress(input.selector, 'selector'),
      deadline: normalizeUintString(input.deadline, 'deadline'),
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
      verifyingContract: normalizeAddress(input.verifyingContract, 'verifyingContract'),
    },
    types: {
      UVPStagePatchModuleStageResourcePatch: STAGE_RESOURCE_PATCH_TYPED_DATA_FIELDS,
    },
    primaryType: STAGE_RESOURCE_PATCH_PRIMARY_TYPE,
    message: {
      orderId: normalizeBytes32(input.orderId, 'orderId'),
      selectorStageId: patch[0],
      targetStageId: patch[1],
      resourceKey: patch[2],
      manifestHash: patch[3],
      policyHash: patch[4],
      patchHash: patch[5],
      patchNonce: patch[6].toString(10),
      manifestURI: patch[7],
      selector: normalizeAddress(input.selector, 'selector'),
      deadline: normalizeUintString(input.deadline, 'deadline'),
    },
  };
}

export function buildDockedOrderLinkTypedData(input: BuildDockedOrderLinkTypedDataInput): DockedOrderLinkTypedData {
  const link = normalizeDockedOrderLink(input);
  return {
    domain: {
      name: DOCKED_ORDER_LINK_DOMAIN_NAME,
      version: DOCKED_ORDER_LINK_DOMAIN_VERSION,
      chainId: normalizeChainId(input.chainId),
      verifyingContract: normalizeAddress(input.verifyingContract, 'verifyingContract'),
    },
    types: {
      UVPDockingModuleDockedOrderLink: DOCKED_ORDER_LINK_TYPED_DATA_FIELDS,
    },
    primaryType: DOCKED_ORDER_LINK_PRIMARY_TYPE,
    message: {
      localOrderId: normalizeBytes32(input.localOrderId, 'localOrderId'),
      selectorStageId: link[0],
      localSourceId: link[1],
      linkedOrderId: link[2],
      linkedPlanId: link[3],
      linkHash: link[4],
      linkNonce: link[5].toString(10),
      signalBindingsHash: hashDockedSignalBindings(link[7]),
      metadataURI: link[6],
      selector: normalizeAddress(input.selector, 'selector'),
      deadline: normalizeUintString(input.deadline, 'deadline'),
    },
  };
}

export async function recoverProductSubmitSigner(typedData: ProductSubmitTypedData, signature: Hex | string): Promise<Address> {
  const recovered = await recoverTypedDataAddress({
    domain: typedData.domain,
    types: typedData.types,
    primaryType: typedData.primaryType,
    message: typedData.message,
    signature: normalizeHex(signature, 'signature'),
  } as unknown as Parameters<typeof recoverTypedDataAddress>[0]);
  return normalizeAddress(recovered, 'recoveredSubmitter');
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
    signature: normalizeHex(signature, 'signature'),
  } as unknown as Parameters<typeof recoverTypedDataAddress>[0]);
  return normalizeAddress(recovered, 'recoveredTriggerOrderSigner');
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
    signature: normalizeHex(signature, 'signature'),
  } as unknown as Parameters<typeof recoverTypedDataAddress>[0]);
  return normalizeAddress(recovered, 'recoveredTriggerOrderSigner');
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
    signature: normalizeHex(signature, 'signature'),
  } as unknown as Parameters<typeof recoverTypedDataAddress>[0]);
  return normalizeAddress(recovered, 'recoveredStageExecutorPatchSigner');
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
    signature: normalizeHex(signature, 'signature'),
  } as unknown as Parameters<typeof recoverTypedDataAddress>[0]);
  return normalizeAddress(recovered, 'recoveredSelector');
}

export async function recoverDockedOrderLinkSigner(
  typedData: DockedOrderLinkTypedData,
  signature: Hex | string,
): Promise<Address> {
  const recovered = await recoverTypedDataAddress({
    domain: typedData.domain,
    types: typedData.types,
    primaryType: typedData.primaryType,
    message: typedData.message,
    signature: normalizeHex(signature, 'signature'),
  } as unknown as Parameters<typeof recoverTypedDataAddress>[0]);
  return normalizeAddress(recovered, 'recoveredDockedOrderLinkSelector');
}

export function buildSubmitSignalForCall(config: SubmitSignalForCallConfig, args: SubmitSignalForCallArgs): SubmitSignalForCall {
  const normalizedArgs = [
    normalizeBytes32(args.orderId, 'orderId'),
    normalizeBytes32(args.sourceId, 'sourceId'),
    normalizeBytes32(args.signalId, 'signalId'),
    normalizeBytes32(args.payloadHash, 'payloadHash'),
    normalizeBytes32(args.idempotencyKey, 'idempotencyKey'),
    normalizeAddress(args.submitter, 'submitter'),
    normalizeUintBigInt(args.deadline, 'deadline'),
    normalizeHex(args.signature, 'signature'),
  ] as const;

  return {
    address: normalizeAddress(config.stateMachineAddress, 'stateMachineAddress'),
    abi: STATE_MACHINE_ABI,
    functionName: 'submitSignalFor',
    args: normalizedArgs,
    data: encodeFunctionData({
      abi: STATE_MACHINE_ABI,
      functionName: 'submitSignalFor',
      args: normalizedArgs,
    }),
    ...(config.chainId !== undefined ? { chainId: normalizeChainId(config.chainId) } : {}),
  };
}

export function buildSubmitDerivedSignalForCall(
  config: SubmitDerivedSignalForCallConfig,
  args: SubmitDerivedSignalForCallArgs,
): SubmitDerivedSignalForCall {
  const normalizedArgs = [
    normalizeBytes32(args.fromOrderId, 'fromOrderId'),
    normalizeBytes32(args.fromStageId, 'fromStageId'),
    normalizeBytes32(args.targetOrderId, 'targetOrderId'),
    normalizeBytes32(args.targetSourceId, 'targetSourceId'),
    normalizeBytes32(args.signalId, 'signalId'),
    normalizeBytes32(args.payloadHash, 'payloadHash'),
    normalizeBytes32(args.idempotencyKey, 'idempotencyKey'),
    normalizeAddress(args.submitter, 'submitter'),
    normalizeUintBigInt(args.deadline, 'deadline'),
    normalizeHex(args.signature, 'signature'),
  ] as const;

  return {
    address: normalizeAddress(config.derivedSignalModuleAddress, 'derivedSignalModuleAddress'),
    abi: DERIVED_SIGNAL_MODULE_ABI,
    functionName: 'submitDerivedSignalFor',
    args: normalizedArgs,
    data: encodeFunctionData({
      abi: DERIVED_SIGNAL_MODULE_ABI,
      functionName: 'submitDerivedSignalFor',
      args: normalizedArgs,
    }),
    ...(config.chainId !== undefined ? { chainId: normalizeChainId(config.chainId) } : {}),
  };
}

export function buildTriggerOrderFromOutsideForCall(
  config: TriggerOrderFromOutsideForCallConfig,
  args: TriggerOrderFromOutsideForCallArgs,
): TriggerOrderFromOutsideForCall {
  const normalizedArgs = [
    normalizeTriggerOrderFromOutside(args),
    args.authorizations.map(normalizeSignalAuthorization),
    normalizeHex(args.signature, 'signature'),
  ] as const;

  return {
    address: normalizeAddress(config.stateMachineAddress, 'stateMachineAddress'),
    abi: STATE_MACHINE_ABI,
    functionName: 'triggerOrderFromOutsideFor',
    args: normalizedArgs,
    data: encodeFunctionData({
      abi: STATE_MACHINE_ABI,
      functionName: 'triggerOrderFromOutsideFor',
      args: normalizedArgs,
    }),
    ...(config.chainId !== undefined ? { chainId: normalizeChainId(config.chainId) } : {}),
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
    normalizeHex(args.signature, 'signature'),
  ] as const;

  return {
    address: normalizeAddress(config.orderLinkModuleAddress, 'orderLinkModuleAddress'),
    abi: ORDER_LINK_MODULE_ABI,
    functionName: 'triggerOrderFromSignalFor',
    args: normalizedArgs,
    data: encodeFunctionData({
      abi: ORDER_LINK_MODULE_ABI,
      functionName: 'triggerOrderFromSignalFor',
      args: normalizedArgs,
    }),
    ...(config.chainId !== undefined ? { chainId: normalizeChainId(config.chainId) } : {}),
  };
}

export function buildApplyStageExecutorPatchForCall(
  config: ApplyStageExecutorPatchForCallConfig,
  args: ApplyStageExecutorPatchForCallArgs,
): ApplyStageExecutorPatchForCall {
  const normalizedArgs = [
    normalizeBytes32(args.orderId, 'orderId'),
    normalizeStageExecutorPatch(args.patch),
    normalizeAddress(args.selector, 'selector'),
    normalizeUintBigInt(args.deadline, 'deadline'),
    normalizeHex(args.selectorSignature, 'selectorSignature'),
    normalizeHex(args.previousExecutorSignature, 'previousExecutorSignature'),
  ] as const;

  return {
    address: normalizeAddress(config.stagePatchModuleAddress, 'stagePatchModuleAddress'),
    abi: STAGE_PATCH_MODULE_ABI,
    functionName: 'applyStageExecutorPatchFor',
    args: normalizedArgs,
    data: encodeFunctionData({
      abi: STAGE_PATCH_MODULE_ABI,
      functionName: 'applyStageExecutorPatchFor',
      args: normalizedArgs as never,
    }),
    ...(config.chainId !== undefined ? { chainId: normalizeChainId(config.chainId) } : {}),
  };
}

export function buildApplyStageResourcePatchForCall(
  config: ApplyStageResourcePatchForCallConfig,
  args: ApplyStageResourcePatchForCallArgs,
): ApplyStageResourcePatchForCall {
  const normalizedArgs = [
    normalizeBytes32(args.orderId, 'orderId'),
    normalizeStageResourcePatch(args.patch),
    normalizeAddress(args.selector, 'selector'),
    normalizeUintBigInt(args.deadline, 'deadline'),
    normalizeHex(args.signature, 'signature'),
  ] as const;

  return {
    address: normalizeAddress(config.stagePatchModuleAddress, 'stagePatchModuleAddress'),
    abi: STAGE_PATCH_MODULE_ABI,
    functionName: 'applyStageResourcePatchFor',
    args: normalizedArgs,
    data: encodeFunctionData({
      abi: STAGE_PATCH_MODULE_ABI,
      functionName: 'applyStageResourcePatchFor',
      args: normalizedArgs as never,
    }),
    ...(config.chainId !== undefined ? { chainId: normalizeChainId(config.chainId) } : {}),
  };
}

export function buildLinkDockedOrderForCall(
  config: LinkDockedOrderForCallConfig,
  args: LinkDockedOrderForCallArgs,
): LinkDockedOrderForCall {
  const normalizedArgs = [
    normalizeBytes32(args.localOrderId, 'localOrderId'),
    normalizeDockedOrderLink(args.link),
    normalizeAddress(args.selector, 'selector'),
    normalizeUintBigInt(args.deadline, 'deadline'),
    normalizeHex(args.signature, 'signature'),
  ] as const;

  return {
    address: normalizeAddress(config.dockingModuleAddress, 'dockingModuleAddress'),
    abi: DOCKING_MODULE_ABI,
    functionName: 'linkDockedOrderFor',
    args: normalizedArgs,
    data: encodeFunctionData({
      abi: DOCKING_MODULE_ABI,
      functionName: 'linkDockedOrderFor',
      args: normalizedArgs as never,
    }),
    ...(config.chainId !== undefined ? { chainId: normalizeChainId(config.chainId) } : {}),
  };
}

export function buildSubmitDockedSignalCall(
  config: SubmitDockedSignalCallConfig,
  args: SubmitDockedSignalCallArgs,
): SubmitDockedSignalCall {
  const normalizedArgs = [
    normalizeBytes32(args.localOrderId, 'localOrderId'),
    normalizeBytes32(args.linkedOrderId, 'linkedOrderId'),
    normalizeBytes32(args.linkedSourceId, 'linkedSourceId'),
    normalizeBytes32(args.linkedSignalId, 'linkedSignalId'),
    normalizeBytes32(args.idempotencyKey, 'idempotencyKey'),
  ] as const;

  return {
    address: normalizeAddress(config.dockingModuleAddress, 'dockingModuleAddress'),
    abi: DOCKING_MODULE_ABI,
    functionName: 'submitDockedSignal',
    args: normalizedArgs,
    data: encodeFunctionData({
      abi: DOCKING_MODULE_ABI,
      functionName: 'submitDockedSignal',
      args: normalizedArgs,
    }),
    ...(config.chainId !== undefined ? { chainId: normalizeChainId(config.chainId) } : {}),
  };
}

export function canonicalJson(value: unknown): string {
  if (value === null) {
    return 'null';
  }

  if (typeof value === 'string') {
    return JSON.stringify(value);
  }

  if (typeof value === 'number') {
    if (!Number.isFinite(value)) {
      throw new TypeError('canonical JSON does not support non-finite numbers');
    }
    return JSON.stringify(value);
  }

  if (typeof value === 'boolean') {
    return value ? 'true' : 'false';
  }

  if (Array.isArray(value)) {
    return `[${value.map((item) => canonicalJson(item)).join(',')}]`;
  }

  if (typeof value === 'object') {
    const record = value as Record<string, unknown>;
    const entries = Object.keys(record)
      .sort()
      .filter((key) => record[key] !== undefined)
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(record[key])}`);
    return `{${entries.join(',')}}`;
  }

  throw new TypeError(`canonical JSON does not support ${typeof value}`);
}

export function hashEvidenceBytes(bytes: Uint8Array): EvidenceHashResult {
  return {
    algorithm: 'keccak256',
    evidenceHash: keccak256(toHex(bytes)),
    byteLength: bytes.byteLength,
    source: 'bytes',
  };
}

export function hashEvidenceText(text: string): EvidenceHashResult {
  return {
    algorithm: 'keccak256',
    evidenceHash: keccak256(stringToHex(text)),
    byteLength: new TextEncoder().encode(text).byteLength,
    source: 'text',
  };
}

export function hashEvidenceJson(value: unknown): EvidenceHashResult {
  const canonical = canonicalJson(value);
  return {
    algorithm: 'keccak256',
    evidenceHash: keccak256(stringToHex(canonical)),
    byteLength: new TextEncoder().encode(canonical).byteLength,
    source: 'json',
  };
}

export function hashStageExecutorPatchPayload(payload: StageExecutorPatchPayload): Hex {
  const normalized = normalizeStageExecutorPatchPayload(payload);
  return keccak256(encodeAbiParameters(
    [
      { name: 'selectorStageId', type: 'bytes32' },
      { name: 'targetStageId', type: 'bytes32' },
      { name: 'executor', type: 'address' },
      { name: 'role', type: 'bytes32' },
      { name: 'executorMetadataHash', type: 'bytes32' },
      { name: 'mode', type: 'bytes32' },
      { name: 'previousExecutor', type: 'address' },
      { name: 'approvalSourceId', type: 'bytes32' },
      { name: 'approvalSignalId', type: 'bytes32' },
      { name: 'patchNonce', type: 'uint256' },
      { name: 'metadataURI', type: 'string' },
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
  ));
}

export function hashStageResourcePatchPayload(payload: StageResourcePatchPayload): Hex {
  const normalized = normalizeStageResourcePatchPayload(payload);
  return keccak256(encodeAbiParameters(
    [
      { name: 'selectorStageId', type: 'bytes32' },
      { name: 'targetStageId', type: 'bytes32' },
      { name: 'resourceKey', type: 'bytes32' },
      { name: 'manifestHash', type: 'bytes32' },
      { name: 'policyHash', type: 'bytes32' },
      { name: 'patchNonce', type: 'uint256' },
      { name: 'manifestURI', type: 'string' },
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
  ));
}

export function hashDockedOrderLinkPayload(payload: DockedOrderLinkPayload): Hex {
  const normalized = normalizeDockedOrderLinkPayload(payload);
  return keccak256(encodeAbiParameters(
    [
      { name: 'selectorStageId', type: 'bytes32' },
      { name: 'localSourceId', type: 'bytes32' },
      { name: 'linkedOrderId', type: 'bytes32' },
      { name: 'linkedPlanId', type: 'bytes32' },
      { name: 'linkNonce', type: 'uint256' },
      { name: 'metadataURI', type: 'string' },
      { name: 'signalBindingsHash', type: 'bytes32' },
    ],
    [
      normalized.selectorStageId,
      normalized.localSourceId,
      normalized.linkedOrderId,
      normalized.linkedPlanId,
      BigInt(normalized.linkNonce),
      normalized.metadataURI,
      hashDockedSignalBindings(normalized.signalBindings),
    ],
  ));
}

export function hashDockedSignalBindings(bindings: readonly DockedSignalBindingCallTuple[]): Hex {
  let rollingHash = keccak256(encodeAbiParameters([{ name: 'length', type: 'uint256' }], [BigInt(bindings.length)]));
  for (const binding of bindings) {
    rollingHash = keccak256(encodeAbiParameters(
      [
        { name: 'rollingHash', type: 'bytes32' },
        { name: 'localSourceId', type: 'bytes32' },
        { name: 'localSignalId', type: 'bytes32' },
        { name: 'linkedSourceId', type: 'bytes32' },
        { name: 'linkedSignalId', type: 'bytes32' },
      ],
      [rollingHash, binding[0], binding[1], binding[2], binding[3]],
    ));
  }
  return rollingHash;
}

export function hashSignalAuthorizations(authorizations: readonly SignalAuthorizationPayload[]): Hex {
  let rollingHash = keccak256(encodeAbiParameters([{ name: 'length', type: 'uint256' }], [BigInt(authorizations.length)]));
  for (const authorization of authorizations) {
    const normalized = normalizeSignalAuthorization(authorization);
    rollingHash = keccak256(encodeAbiParameters(
      [
        { name: 'rollingHash', type: 'bytes32' },
        { name: 'sourceId', type: 'bytes32' },
        { name: 'signalId', type: 'bytes32' },
        { name: 'submitter', type: 'address' },
        { name: 'role', type: 'bytes32' },
        { name: 'metadataHash', type: 'bytes32' },
      ],
      [rollingHash, normalized[0], normalized[1], normalized[2], normalized[3], normalized[4]],
    ));
  }
  return rollingHash;
}

export function validateResourceManifestV1(manifest: ResourceManifestV1): void {
  normalizeResourceManifestV1(manifest);
}

export function hashResourceManifest(manifest: ResourceManifestV1): Hex {
  const normalized = normalizeResourceManifestV1(manifest);
  return hashCanonicalJson(RESOURCE_MANIFEST_HASH_DOMAIN, normalized);
}

export function normalizeAddress(value: Address | string, fieldName = 'address'): Address {
  if (!isAddress(value, { strict: false })) {
    throw new Error(`${fieldName} must be a valid EVM address`);
  }

  return getAddress(value).toLowerCase() as Address;
}

export function normalizeBytes32(value: Hex | string, fieldName = 'bytes32'): Hex {
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
  if (typeof value === 'string') {
    const namedMode = EXECUTOR_PATCH_MODE_BY_NAME[value.trim().toLowerCase()];
    if (namedMode !== undefined) {
      return namedMode;
    }
  }

  const normalized = normalizeBytes32(value, 'mode');
  if (!EXECUTOR_PATCH_MODE_VALUE_SET.has(normalized)) {
    throw new Error('mode must be assign, handoff, or replacement');
  }
  return normalized;
}

function normalizeSignalAuthorization(authorization: SignalAuthorizationPayload): SignalAuthorizationCallTuple {
  return [
    normalizeBytes32(authorization.sourceId, 'authorization.sourceId'),
    normalizeNonZeroBytes32(authorization.signalId, 'authorization.signalId'),
    normalizeAddress(authorization.submitter, 'authorization.submitter'),
    normalizeBytes32(authorization.role, 'authorization.role'),
    normalizeBytes32(authorization.metadataHash, 'authorization.metadataHash'),
  ] as const;
}

function normalizeSignalAuthorizationStruct(authorization: SignalAuthorizationPayload): SignalAuthorizationCallStruct {
  const tuple = normalizeSignalAuthorization(authorization);
  return {
    sourceId: tuple[0],
    signalId: tuple[1],
    submitter: tuple[2],
    role: tuple[3],
    metadataHash: tuple[4],
  };
}

function normalizeTriggerOrderFromOutside(trigger: TriggerOrderFromOutsidePayload): TriggerOrderFromOutsideCallTuple {
  return [
    normalizeNonZeroBytes32(trigger.orderId, 'orderId'),
    normalizeNonZeroBytes32(trigger.planId, 'planId'),
    normalizeAddress(trigger.creator, 'creator'),
    normalizeNonZeroBytes32(trigger.triggerHookId, 'triggerHookId'),
    normalizeNonZeroBytes32(trigger.triggerStageId, 'triggerStageId'),
    normalizeBytes32(trigger.sourceId, 'sourceId'),
    normalizeNonZeroBytes32(trigger.signalId, 'signalId'),
    normalizeBytes32(trigger.payloadHash, 'payloadHash'),
    normalizeBytes32(trigger.idempotencyKey, 'idempotencyKey'),
    normalizeAddress(trigger.submitter, 'submitter'),
    normalizeUintBigInt(trigger.deadline, 'deadline'),
  ] as const;
}

function normalizeTriggerOrderFromSignal(trigger: TriggerOrderFromSignalPayload): TriggerOrderFromSignalCallTuple {
  return [
    normalizeNonZeroBytes32(trigger.orderId, 'orderId'),
    normalizeNonZeroBytes32(trigger.planId, 'planId'),
    normalizeAddress(trigger.creator, 'creator'),
    normalizeNonZeroBytes32(trigger.triggerOriginOrderId, 'triggerOriginOrderId'),
    normalizeNonZeroBytes32(trigger.triggerHookId, 'triggerHookId'),
    normalizeNonZeroBytes32(trigger.triggerStageId, 'triggerStageId'),
    normalizeBytes32(trigger.originSourceId, 'originSourceId'),
    normalizeNonZeroBytes32(trigger.originSignalId, 'originSignalId'),
    normalizeBytes32(trigger.payloadHash, 'payloadHash'),
    normalizeBytes32(trigger.idempotencyKey, 'idempotencyKey'),
    normalizeAddress(trigger.submitter, 'submitter'),
    normalizeUintBigInt(trigger.deadline, 'deadline'),
  ] as const;
}

function normalizeTriggerOrderFromSignalStruct(trigger: TriggerOrderFromSignalPayload): TriggerOrderFromSignalCallStruct {
  const tuple = normalizeTriggerOrderFromSignal(trigger);
  return {
    orderId: tuple[0],
    planId: tuple[1],
    creator: tuple[2],
    triggerOriginOrderId: tuple[3],
    triggerHookId: tuple[4],
    triggerStageId: tuple[5],
    originSourceId: tuple[6],
    originSignalId: tuple[7],
    payloadHash: tuple[8],
    idempotencyKey: tuple[9],
    submitter: tuple[10],
    deadline: tuple[11],
  };
}

function normalizeStageExecutorPatch(patch: StageExecutorPatchCallPatch): StageExecutorPatchCallTuple {
  if (typeof patch.metadataURI !== 'string') {
    throw new Error('metadataURI must be a string');
  }
  const executor = normalizeAddress(patch.executor, 'executor');
  if (executor === ZERO_ADDRESS) {
    throw new Error('executor must be non-zero');
  }
  return [
    normalizeNonZeroBytes32(patch.selectorStageId, 'selectorStageId'),
    normalizeNonZeroBytes32(patch.targetStageId, 'targetStageId'),
    executor,
    normalizeBytes32(patch.role, 'role'),
    normalizeBytes32(patch.executorMetadataHash, 'executorMetadataHash'),
    normalizeStageExecutorPatchMode(patch.mode),
    normalizeAddress(patch.previousExecutor, 'previousExecutor'),
    normalizeBytes32(patch.approvalSourceId, 'approvalSourceId'),
    normalizeBytes32(patch.approvalSignalId, 'approvalSignalId'),
    normalizeNonZeroBytes32(patch.patchHash, 'patchHash'),
    normalizeUintBigInt(patch.patchNonce, 'patchNonce'),
    patch.metadataURI,
  ] as const;
}

function normalizeStageResourcePatch(patch: StageResourcePatchCallPatch): StageResourcePatchCallTuple {
  if (typeof patch.manifestURI !== 'string') {
    throw new Error('manifestURI must be a string');
  }
  if (patch.manifestURI.trim().length === 0) {
    throw new Error('manifestURI must be a non-empty string');
  }
  return [
    normalizeNonZeroBytes32(patch.selectorStageId, 'selectorStageId'),
    normalizeNonZeroBytes32(patch.targetStageId, 'targetStageId'),
    normalizeNonZeroBytes32(patch.resourceKey, 'resourceKey'),
    normalizeNonZeroBytes32(patch.manifestHash, 'manifestHash'),
    normalizeNonZeroBytes32(patch.policyHash, 'policyHash'),
    normalizeNonZeroBytes32(patch.patchHash, 'patchHash'),
    normalizeUintBigInt(patch.patchNonce, 'patchNonce'),
    patch.manifestURI,
  ] as const;
}

function normalizeDockedSignalBinding(binding: DockedSignalBindingPayload): DockedSignalBindingCallTuple {
  return [
    normalizeNonZeroBytes32(binding.localSourceId, 'localSourceId'),
    normalizeNonZeroBytes32(binding.localSignalId, 'localSignalId'),
    normalizeNonZeroBytes32(binding.linkedSourceId, 'linkedSourceId'),
    normalizeNonZeroBytes32(binding.linkedSignalId, 'linkedSignalId'),
  ] as const;
}

function normalizeDockedOrderLink(link: DockedOrderLinkCallLink): DockedOrderLinkCallTuple {
  if (typeof link.metadataURI !== 'string') {
    throw new Error('metadataURI must be a string');
  }
  if (!Array.isArray(link.signalBindings) || link.signalBindings.length === 0) {
    throw new Error('signalBindings must contain at least one binding');
  }
  return [
    normalizeNonZeroBytes32(link.selectorStageId, 'selectorStageId'),
    normalizeNonZeroBytes32(link.localSourceId, 'localSourceId'),
    normalizeNonZeroBytes32(link.linkedOrderId, 'linkedOrderId'),
    normalizeNonZeroBytes32(link.linkedPlanId, 'linkedPlanId'),
    normalizeNonZeroBytes32(link.linkHash, 'linkHash'),
    normalizeUintBigInt(link.linkNonce, 'linkNonce'),
    link.metadataURI,
    link.signalBindings.map((binding) => normalizeDockedSignalBinding(binding)),
  ] as const;
}

function normalizeStageExecutorPatchPayload(payload: StageExecutorPatchPayload): {
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
  if (typeof payload.metadataURI !== 'string') {
    throw new Error('metadataURI must be a string');
  }
  const executor = normalizeAddress(payload.executor, 'executor');
  if (executor === ZERO_ADDRESS) {
    throw new Error('executor must be non-zero');
  }
  return {
    selectorStageId: normalizeNonZeroBytes32(payload.selectorStageId, 'selectorStageId'),
    targetStageId: normalizeNonZeroBytes32(payload.targetStageId, 'targetStageId'),
    executor,
    role: normalizeBytes32(payload.role, 'role'),
    executorMetadataHash: normalizeBytes32(payload.executorMetadataHash, 'executorMetadataHash'),
    mode: normalizeStageExecutorPatchMode(payload.mode),
    previousExecutor: normalizeAddress(payload.previousExecutor, 'previousExecutor'),
    approvalSourceId: normalizeBytes32(payload.approvalSourceId, 'approvalSourceId'),
    approvalSignalId: normalizeBytes32(payload.approvalSignalId, 'approvalSignalId'),
    patchNonce: normalizeUintString(payload.patchNonce, 'patchNonce'),
    metadataURI: payload.metadataURI,
  };
}

function normalizeStageResourcePatchPayload(payload: StageResourcePatchPayload): {
  readonly selectorStageId: Hex;
  readonly targetStageId: Hex;
  readonly resourceKey: Hex;
  readonly manifestHash: Hex;
  readonly policyHash: Hex;
  readonly patchNonce: string;
  readonly manifestURI: string;
} {
  if (typeof payload.manifestURI !== 'string') {
    throw new Error('manifestURI must be a string');
  }
  if (payload.manifestURI.trim().length === 0) {
    throw new Error('manifestURI must be a non-empty string');
  }
  return {
    selectorStageId: normalizeNonZeroBytes32(payload.selectorStageId, 'selectorStageId'),
    targetStageId: normalizeNonZeroBytes32(payload.targetStageId, 'targetStageId'),
    resourceKey: normalizeNonZeroBytes32(payload.resourceKey, 'resourceKey'),
    manifestHash: normalizeNonZeroBytes32(payload.manifestHash, 'manifestHash'),
    policyHash: normalizeNonZeroBytes32(payload.policyHash, 'policyHash'),
    patchNonce: normalizeUintString(payload.patchNonce, 'patchNonce'),
    manifestURI: payload.manifestURI,
  };
}

function normalizeDockedOrderLinkPayload(payload: DockedOrderLinkPayload): {
  readonly selectorStageId: Hex;
  readonly localSourceId: Hex;
  readonly linkedOrderId: Hex;
  readonly linkedPlanId: Hex;
  readonly linkNonce: string;
  readonly metadataURI: string;
  readonly signalBindings: readonly DockedSignalBindingCallTuple[];
} {
  if (typeof payload.metadataURI !== 'string') {
    throw new Error('metadataURI must be a string');
  }
  if (!Array.isArray(payload.signalBindings) || payload.signalBindings.length === 0) {
    throw new Error('signalBindings must contain at least one binding');
  }
  return {
    selectorStageId: normalizeNonZeroBytes32(payload.selectorStageId, 'selectorStageId'),
    localSourceId: normalizeNonZeroBytes32(payload.localSourceId, 'localSourceId'),
    linkedOrderId: normalizeNonZeroBytes32(payload.linkedOrderId, 'linkedOrderId'),
    linkedPlanId: normalizeNonZeroBytes32(payload.linkedPlanId, 'linkedPlanId'),
    linkNonce: normalizeUintString(payload.linkNonce, 'linkNonce'),
    metadataURI: payload.metadataURI,
    signalBindings: payload.signalBindings.map((binding) => normalizeDockedSignalBinding(binding)),
  };
}

function normalizeResourceManifestV1(manifest: ResourceManifestV1): CanonicalResourceManifestV1 {
  if (!isRecord(manifest)) {
    throw new Error('resource manifest must be an object');
  }
  assertNoLegacyResourceHandles(manifest, 'manifest');
  assertAllowedResourceManifestKeys(manifest);

  if (manifest.schemaVersion !== RESOURCE_MANIFEST_V1_SCHEMA_VERSION) {
    throw new Error(`schemaVersion must be ${RESOURCE_MANIFEST_V1_SCHEMA_VERSION}`);
  }
  if (!isResourceVisibility(manifest.visibility)) {
    throw new Error('visibility must be public, protected, or private');
  }
  if (typeof manifest.storageCID !== 'string' || manifest.storageCID.trim().length === 0) {
    throw new Error('storageCID must be a non-empty content-addressed reference');
  }
  if (/^https?:\/\//i.test(manifest.storageCID)) {
    throw new Error('storageCID must be content-addressed, not an HTTP URL');
  }
  if (/^txcloud:\/\//i.test(manifest.storageCID)) {
    throw new Error('storageCID must not use legacy txcloud resource handles');
  }
  if (typeof manifest.createdAt !== 'string' || manifest.createdAt.trim().length === 0) {
    throw new Error('createdAt must be a non-empty string');
  }

  const normalizedVisibility = manifest.visibility;
  const normalizedContentHash = normalizeOptionalBytes32(manifest.contentHash, 'contentHash');
  const normalizedCiphertextHash = normalizeOptionalBytes32(manifest.ciphertextHash, 'ciphertextHash');
  const normalizedRecipientEnvelopeRoot = normalizeBytes32(
    manifest.recipientEnvelopeRoot,
    'recipientEnvelopeRoot',
  );

  if (normalizedVisibility === 'public') {
    if (normalizedContentHash === undefined) {
      throw new Error('contentHash is required for public resource manifests');
    }
  } else {
    if (normalizedCiphertextHash === undefined) {
      throw new Error('ciphertextHash is required for protected and private resource manifests');
    }
    if (normalizedRecipientEnvelopeRoot === ZERO_BYTES32) {
      throw new Error('recipientEnvelopeRoot must be non-zero for protected and private resource manifests');
    }
  }

  return {
    schemaVersion: RESOURCE_MANIFEST_V1_SCHEMA_VERSION,
    orderId: normalizeNonZeroBytes32(manifest.orderId, 'orderId'),
    targetStageId: normalizeNonZeroBytes32(manifest.targetStageId, 'targetStageId'),
    resourceKey: normalizeNonZeroBytes32(manifest.resourceKey, 'resourceKey'),
    visibility: normalizedVisibility,
    ...(normalizedContentHash !== undefined ? { contentHash: normalizedContentHash } : {}),
    ...(normalizedCiphertextHash !== undefined ? { ciphertextHash: normalizedCiphertextHash } : {}),
    storageCID: manifest.storageCID,
    policyHash: normalizeNonZeroBytes32(manifest.policyHash, 'policyHash'),
    recipientEnvelopeRoot: normalizedRecipientEnvelopeRoot,
    createdBy: normalizeAddress(manifest.createdBy, 'createdBy'),
    createdAt: manifest.createdAt,
    ...(manifest.supersedes !== undefined
      ? { supersedes: normalizeNonZeroBytes32(manifest.supersedes, 'supersedes') }
      : {}),
  };
}

function normalizeOptionalBytes32(value: Hex | string | undefined, fieldName: string): Hex | undefined {
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

function assertNoLegacyResourceHandles(value: unknown, path: string): void {
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoLegacyResourceHandles(item, `${path}[${index}]`));
    return;
  }

  if (!isRecord(value)) {
    return;
  }

  for (const [key, linked] of Object.entries(value)) {
    const normalizedKey = key.toLowerCase();
    if (
      LEGACY_HANDLE_FIELD_NAMES.has(normalizedKey)
      && typeof linked === 'string'
      && LEGACY_FILE_RESOURCE_HANDLE_TYPE_SET.has(linked.trim().toLowerCase())
    ) {
      throw new Error(`${path}.${key} uses legacy file resource handle type "${linked}"`);
    }
    if ((normalizedKey === 'url' || normalizedKey.endsWith('url')) && typeof linked === 'string' && /^https?:\/\//i.test(linked)) {
      throw new Error(`${path}.${key} must not contain public HTTP resource URLs`);
    }
    if (normalizedKey.includes('plaintext') && linked !== undefined) {
      throw new Error(`${path}.${key} must not contain plaintext resource data`);
    }
    assertNoLegacyResourceHandles(linked, `${path}.${key}`);
  }
}

function assertAllowedResourceManifestKeys(manifest: ResourceManifestV1): void {
  for (const key of Object.keys(manifest)) {
    if (!ALLOWED_RESOURCE_MANIFEST_KEYS.has(key)) {
      throw new Error(`resource manifest field ${key} is not part of ResourceManifestV1`);
    }
  }
}

function isResourceVisibility(value: unknown): value is ResourceVisibility {
  return value === 'public' || value === 'protected' || value === 'private';
}

function hashCanonicalJson(domain: string, payload: unknown): Hex {
  return keccak256(stringToHex(`${domain}:${canonicalJson(payload)}`));
}

function normalizeChainId(value: number): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error('chainId must be a positive safe integer');
  }
  return value;
}

function normalizeUintString(value: bigint | number | string, fieldName: string): string {
  if (typeof value === 'bigint') {
    if (value < 0n) {
      throw new Error(`${fieldName} must be a non-negative integer`);
    }
    return value.toString(10);
  }

  if (typeof value === 'number') {
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

function normalizeUintBigInt(value: bigint | number | string, fieldName: string): bigint {
  if (typeof value === 'bigint') {
    if (value < 0n) {
      throw new Error(`${fieldName} must be a non-negative integer`);
    }
    return value;
  }

  if (typeof value === 'number') {
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new Error(`${fieldName} must be a non-negative safe integer`);
    }
    return BigInt(value);
  }

  return BigInt(normalizeUintString(value, fieldName));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

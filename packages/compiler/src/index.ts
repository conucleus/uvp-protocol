export {
  assertHookPlanArtifact,
  compileZhixuHookPlan,
  HookPlanCompilationError,
  HookPlanArtifactValidationError,
  validateHookPlanArtifact,
} from "./hook-plan.js";
export {
  KNOWN_FIELDS,
  loadZhixuDefinition,
  parseZhixuDefinition,
  ZhixuLoadError,
} from "./zhixu-loader.js";
export {
  assertOnchainHookPlanArtifact,
  OnchainHookPlanArtifactValidationError,
  validateOnchainHookPlanArtifact,
} from "./onchain/validate/artifact.js";
export {
  compileOnchainHookPlan,
  compileZhixuOnchainHookPlan,
  compileZhixuRegisterPlanArgs,
} from "./onchain/compile.js";
export {
  hashSolidityRegisterHooks,
  planIdForPublisher,
  toSolidityRegisterPlanArgs,
} from "./onchain/solidity/registration.js";
export {
  onchainHookId,
  onchainHookName,
  onchainSelectorBindingHash,
  onchainSignalId,
  onchainSignalKey,
  onchainSourceId,
  onchainStageId,
} from "./onchain/hash/route.js";
export { hashCanonical, keccak256Hex } from "./hash.js";
export { hashOnchainPlanPayload } from "./onchain/hash/plan.js";
export {
  assertDockArtifact,
  DOCK_ARTIFACT_SCHEMA_VERSION,
  DOCK_WINDOW_OP,
  DockArtifactValidationError,
  dockWindowInstructionsOf,
  validateDockArtifact,
} from "./dock-artifact.js";
export type {
  DockArtifact,
  DockWindowInstruction,
  DockArtifactAtom,
  DockArtifactOutput,
  DockArtifactSide,
  DockArtifactTarget,
} from "./dock-artifact.js";
export {
  definitionUid,
  displayIdentity,
  dockIdentity,
  DEFINITION_UID_DOMAIN,
  DOCK_UID_DOMAIN,
  stripAnnotations,
  stripDisplayFields,
} from "./identity.js";
export type { DockIdentity } from "./identity.js";
export {
  EMPTY_MERKLE_ROOT,
  keccakWord,
  merkleProof,
  merkleRoot,
  verifyMerkleProof,
} from "./merkle.js";
export {
  HOOK_FLAG_ADMISSION,
  HOOK_FLAG_DOCK_EXECUTOR,
  HOOK_FLAG_DYNAMIC_EXECUTOR,
  HOOK_FLAG_EMIT_READY,
  HOOK_FLAG_ORDER_TRIGGER_MINT,
  solidityHookFlags,
} from "./onchain/solidity/registration.js";
export {
  artifactCapabilitiesRoot,
  capabilityLeaves,
  capabilityTablesOf,
  capabilitiesRootOf,
  factAttribution,
  FILE_WRITER_LEAF_DOMAIN,
  fileWriterLeaf,
  fileWriterProof,
  SELECTOR_BINDING_LEAF_DOMAIN,
  selectorBindingLeaf,
  selectorBindingProof,
  SIGNAL_CAPABILITY_LEAF_DOMAIN,
  signalCapabilityLeaf,
  signalCapabilityProof,
} from "./onchain/capabilities-root.js";
export {
  MAX_FILE_WRITERS_PER_STAGE,
  compileStageFileWriters,
  validateOnchainStageFileWriters,
} from "./onchain/file-writers.js";
export {
  EXECUTOR_BINDING_KIND_CANDIDATE,
  EXECUTOR_BINDING_KIND_DEFAULT,
  EXECUTOR_BINDING_LEAF_DOMAIN,
  executorBindingLeaf,
  executorBindingProof,
  executorBindingsRootOf,
  MAX_EXECUTOR_BINDINGS,
  onchainSupplierId,
  resolveExecutorBindings,
  SUPPLIER_ID_DOMAIN,
} from "./onchain/executor-bindings.js";
export {
  COMPILER_NAME,
  COMPILER_VERSION,
  HOOK_PLAN_SCHEMA_VERSION,
  ONCHAIN_HOOK_PLAN_SCHEMA_VERSION,
} from "./types/index.js";
export type {
  Address,
  CompiledHookPlanAdmission,
  CompiledHookPlanHook,
  ExecuteConfigs,
  ExecutorBinding,
  ExecutorBindingKind,
  ExecutorBindingInput,
  ExecutorCandidateInput,
  FileResourceLike,
  HexString,
  HookPlanArtifact,
  HookPlanExecutorRoute,
  ObjectMeta,
  OnchainCompiledAdmission,
  OnchainCompiledHook,
  OnchainDelayInstruction,
  OnchainExecutorRoute,
  OnchainExecutorRouteRef,
  OnchainHookDependency,
  OnchainHookInstruction,
  OnchainHookPlanArtifact,
  OnchainPlanTrigger,
  OnchainJoinInstruction,
  OnchainSignalCapability,
  OnchainSignalInstruction,
  OnchainStageFileWriter,
  OnchainStageSelectorBinding,
  OnchainUnaryInstruction,
  OrderTriggerKind,
  SelectedStageBinding,
  SignalCapability,
  SignalTargetOrderRelation,
  SolidityRegisterDependencyIndexArg,
  SolidityRegisterExecutorBindingArg,
  SolidityRegisterExecutorRouteArg,
  SolidityRegisterFileWriterBindingArg,
  SolidityRegisterHookArg,
  SolidityRegisterInstructionArg,
  SolidityRegisterPlanArgs,
  SolidityRegisterSignalCapabilityArg,
  SolidityRegisterStageSelectorBindingArg,
  ZhixuDefinition,
  ZhixuPlatform,
  ZhixuSendSignal,
  ZhixuStage,
} from "./types/index.js";

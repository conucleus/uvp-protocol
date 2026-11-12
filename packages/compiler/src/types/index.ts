export const COMPILER_NAME = "uvp-eth-compiler" as const;
export const COMPILER_VERSION = "0.2.0" as const;
export const HOOK_PLAN_SCHEMA_VERSION = "uvp.hookPlan.v7" as const;
export const ONCHAIN_HOOK_PLAN_SCHEMA_VERSION =
  "uvp.onchainHookPlan.v7" as const;

export type HexString = `0x${string}`;
export type Address = HexString;

export interface ObjectMeta {
  readonly name: string;
  readonly labels?: Record<string, string>;
  readonly annotations?: Record<string, string>;
}

export interface FileResourceLike {
  readonly fileType: string;
  readonly [key: string]: unknown;
}

export interface ZhixuDefinition {
  readonly apiVersion: "uvp/v0";
  readonly kind: "Zhixu";
  readonly metadata: ObjectMeta;
  readonly spec: {
    readonly platform: ZhixuPlatform;
    readonly nucleation: {
      readonly id: string;
      readonly params?: Record<string, string>;
    };
    readonly stages: readonly ZhixuStage[];
  };
}

export interface ZhixuPlatform {
  readonly type: "cloud" | "blockchain" | "cbdc" | string;
  readonly provider?: string;
  readonly network?: string;
  readonly version?: string;
  readonly params?: Record<string, string>;
}

export interface ZhixuStage {
  readonly name: string;
  readonly source: string;
  readonly executor?: ExecuteConfigs;
  readonly selectedStages?: readonly string[];
  readonly sendSignals?: readonly ZhixuSendSignal[];
  readonly receiveSignals?: Record<string, string>;
  readonly fileResources?: Record<string, FileResourceLike>;
  readonly fileWriters?: readonly string[];
}

export interface ZhixuSendSignal {
  readonly name: string;
  readonly validWhen?: readonly string[];
  readonly trigger?: boolean;
}

export interface ExecuteConfigs {
  readonly supplierType: "individual" | "organization" | "dock";
  readonly supplierID?: string;
  readonly selectableResource?: Record<string, FileResourceLike>;
  readonly [key: string]: unknown;
}

export interface HookPlanArtifact {
  readonly schemaVersion: typeof HOOK_PLAN_SCHEMA_VERSION;
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly zhixuName: string;
  readonly platform: ZhixuPlatform;
  readonly compiledHooks: readonly CompiledHookPlanHook[];
  readonly dependencyIndex: Record<string, readonly string[]>;
  readonly executorRoutes: Record<string, HookPlanExecutorRoute>;
  readonly selectedStageBindings: readonly SelectedStageBinding[];
  readonly signalCapabilities: readonly SignalCapability[];
  readonly admissions: readonly CompiledHookPlanAdmission[];
  readonly source: unknown;
  readonly planHash: HexString;
}

export type OrderTriggerKind = "none" | "trigger";

export interface OnchainPlanTrigger {
  readonly hookId: HexString;
  readonly stageIdentifier: string;
  readonly stageId: HexString;
  readonly hookName: string;
  readonly orderTriggerKind: Exclude<OrderTriggerKind, "none">;
  readonly source: string;
  readonly signalName: string;
  readonly sourceId: HexString;
  readonly signalId: HexString;
}

export interface CompiledHookPlanHook {
  readonly hookId: string;
  readonly kind: "receive";
  readonly stageIdentifier: string;
  readonly hookName: string;
  readonly orderTriggerKind: OrderTriggerKind;
  readonly emitReady: boolean;
  readonly dockExecutor: boolean;
  readonly rawExpression: string;
  readonly normalizedExpression: string;
  readonly ast: import("@uvp-eth/hook-core").HookExpressionAst;
  readonly dependencies: readonly import("@uvp-eth/hook-core").HookDependency[];
  readonly route?: HookPlanExecutorRoute;
}

export interface HookPlanExecutorRoute {
  readonly stageIdentifier: string;
  readonly executor: ExecuteConfigs;
  readonly fileResources?: Record<string, FileResourceLike>;
}

export interface CompiledHookPlanAdmission {
  readonly stageIdentifier: string;
  readonly signalName: string;
  readonly rawExpression: readonly string[];
  readonly normalizedExpression: string;
  readonly ast: import("@uvp-eth/hook-core").HookExpressionAst;
  readonly dependencies: readonly import("@uvp-eth/hook-core").HookDependency[];
}

export interface SelectedStageBinding {
  readonly selectorStageIdentifier: string;
  readonly targetStageIdentifier: string;
}

export type SignalTargetOrderRelation = "current";

export interface ExecutorCandidateInput {
  readonly stageIdentifier: string;
  readonly executor: HexString;
}

export interface OnchainExecutorCandidate {
  readonly stageIdentifier: string;
  readonly stageId: HexString;
  readonly executor: HexString;
}

export interface SignalCapability {
  readonly stageIdentifier: string;
  readonly source: string;
  readonly declaredSignal: string;
  readonly targetSource: string;
  readonly targetSignalName: string;
  readonly targetOrderRelation: SignalTargetOrderRelation;
}

export type OnchainHookInstruction =
  | OnchainSignalInstruction
  | OnchainUnaryInstruction
  | OnchainJoinInstruction
  | OnchainDelayInstruction;

export interface OnchainSignalInstruction {
  readonly op: "SIGNAL";
  readonly source: string;
  readonly signalName: string;
  readonly sourceId: HexString;
  readonly signalId: HexString;
  readonly signalKey: HexString;
}

export interface OnchainUnaryInstruction {
  readonly op: "NOT";
}

export interface OnchainJoinInstruction {
  readonly op: "AND" | "OR";
  readonly arity: number;
}

export interface OnchainDelayInstruction {
  readonly op: "DELAY";
  readonly delaySeconds: number;
}

export interface OnchainHookDependency {
  readonly kind: "positive" | "negative" | "timer";
  readonly source: string;
  readonly signalName: string;
  readonly sourceId: HexString;
  readonly signalId: HexString;
  readonly signalKey: HexString;
  readonly delaySeconds?: number;
}

export interface OnchainExecutorRouteRef {
  readonly routeId: HexString;
  readonly stageId: HexString;
  readonly routeHash: HexString;
}

export interface OnchainExecutorRoute {
  readonly routeId: HexString;
  readonly stageId: HexString;
  readonly stageIdentifier: string;
  readonly executorType: string;
  readonly executorId: string;
  readonly executorHash: HexString;
  readonly resourcesHash: HexString;
  readonly routeHash: HexString;
}

export interface OnchainStageSelectorBinding {
  readonly selectorStageIdentifier: string;
  readonly targetStageIdentifier: string;
  readonly selectorStageId: HexString;
  readonly targetStageId: HexString;
  readonly bindingHash: HexString;
}

export interface OnchainStageFileWriter {
  readonly targetStageIdentifier: string;
  readonly targetStageId: HexString;
  readonly writerStageIdentifier: string;
  readonly writerStageId: HexString;
  readonly fileWriterLeaf: HexString;
}

export interface OnchainSignalCapability {
  readonly stageIdentifier: string;
  readonly stageId: HexString;
  readonly source: string;
  readonly declaredSignal: string;
  readonly targetSource: string;
  readonly targetSourceId: HexString;
  readonly targetSignalName: string;
  readonly signalId: HexString;
  readonly targetOrderRelation: SignalTargetOrderRelation;
  readonly capabilityHash: HexString;
}

export interface OnchainCompiledHook {
  readonly hookId: HexString;
  readonly stageId: HexString;
  readonly stageIdentifier: string;
  readonly hookName: string;
  readonly kind: "receive";
  readonly orderTriggerKind: OrderTriggerKind;
  readonly emitReady: boolean;
  readonly dockExecutor: boolean;
  readonly instructions: readonly OnchainHookInstruction[];
  readonly dependencies: readonly OnchainHookDependency[];
  readonly routeRef?: OnchainExecutorRouteRef;
}

export interface OnchainCompiledAdmission {
  readonly admissionId: HexString;
  readonly stageId: HexString;
  readonly stageIdentifier: string;
  readonly signalName: string;
  readonly signalId: HexString;
  readonly sourceId: HexString;
  readonly instructions: readonly OnchainHookInstruction[];
  readonly dependencies: readonly OnchainHookDependency[];
}

export interface OnchainHookPlanArtifact {
  readonly schemaVersion: typeof ONCHAIN_HOOK_PLAN_SCHEMA_VERSION;
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly zhixuName: string;
  readonly platform: ZhixuPlatform;
  readonly sourcePlanHash: HexString;
  readonly compiledHooks: readonly OnchainCompiledHook[];
  readonly triggers: readonly OnchainPlanTrigger[];
  readonly dependencyIndex: Record<HexString, readonly HexString[]>;
  readonly executorRoutes: readonly OnchainExecutorRoute[];
  readonly capabilitiesRoot: HexString;
  readonly selectorBindings: readonly OnchainStageSelectorBinding[];
  readonly signalCapabilities: readonly OnchainSignalCapability[];
  readonly stageFileWriters: readonly OnchainStageFileWriter[];
  readonly admissions: readonly OnchainCompiledAdmission[];
  readonly executorCandidates: readonly OnchainExecutorCandidate[];
  readonly executorCandidatesRoot: HexString;
  readonly planHash: HexString;
}

export type SolidityRegisterInstructionArg =
  | {
      readonly op: "SIGNAL";
      readonly sourceId: HexString;
      readonly signalId: HexString;
      readonly signalKey: HexString;
    }
  | {
      readonly op: "NOT";
    }
  | {
      readonly op: "AND" | "OR";
      readonly arity: number;
    }
  | {
      readonly op: "DELAY";
      readonly delaySeconds: number;
    };

export interface SolidityRegisterHookArg {
  readonly hookId: HexString;
  readonly stageId: HexString;
  readonly hookName: HexString;
  readonly kind: "receive" | "admission";
  readonly flags: number;
  readonly instructions: readonly SolidityRegisterInstructionArg[];
  readonly dependencyKeys: readonly HexString[];
  readonly routeId?: HexString;
}

export interface SolidityRegisterDependencyIndexArg {
  readonly signalKey: HexString;
  readonly hookIds: readonly HexString[];
}

export interface SolidityRegisterExecutorRouteArg {
  readonly routeId: HexString;
  readonly stageId: HexString;
  readonly executorType: string;
  readonly executorId: string;
  readonly executorHash: HexString;
  readonly resourcesHash: HexString;
  readonly routeHash: HexString;
}

export interface SolidityRegisterStageSelectorBindingArg {
  readonly selectorStageId: HexString;
  readonly targetStageId: HexString;
}

export interface SolidityRegisterFileWriterBindingArg {
  readonly targetStageId: HexString;
  readonly writerStageId: HexString;
}

export interface SolidityRegisterSignalCapabilityArg {
  readonly stageId: HexString;
  readonly targetSourceId: HexString;
  readonly signalId: HexString;
  readonly targetOrderRelation: 0 | 1;
}

export interface SolidityRegisterExecutorCandidateArg {
  readonly stageId: HexString;
  readonly executor: HexString;
}

export interface SolidityRegisterPlanArgs {
  readonly schemaVersion: typeof ONCHAIN_HOOK_PLAN_SCHEMA_VERSION;
  readonly sourcePlanId: HexString;
  readonly zhixuId: string;
  readonly planHash: HexString;
  readonly artifactHash: HexString;
  readonly hooksHash: HexString;
  readonly capabilitiesRoot: HexString;
  readonly executorCandidatesRoot: HexString;
  readonly hooks: readonly SolidityRegisterHookArg[];
  readonly dependencyIndex: readonly SolidityRegisterDependencyIndexArg[];
  readonly executorRoutes: readonly SolidityRegisterExecutorRouteArg[];
  readonly executorCandidates: readonly SolidityRegisterExecutorCandidateArg[];
  readonly selectorBindings: readonly SolidityRegisterStageSelectorBindingArg[];
  readonly signalCapabilities: readonly SolidityRegisterSignalCapabilityArg[];
  readonly fileWriterBindings: readonly SolidityRegisterFileWriterBindingArg[];
}

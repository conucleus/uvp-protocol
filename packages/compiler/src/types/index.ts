export const COMPILER_NAME = "uvp-eth-compiler" as const;
export const COMPILER_VERSION = "0.1.0" as const;
export const HOOK_PLAN_SCHEMA_VERSION = "uvp.hookPlan.v1" as const;
export const ONCHAIN_HOOK_PLAN_SCHEMA_VERSION = "uvp.onchainHookPlan.v1" as const;

export type HexString = `0x${string}`;
export type Address = HexString;

export interface ObjectMeta {
  readonly name: string;
  readonly uid?: string;
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
    readonly taskPatterns: readonly ZhixuTaskPattern[];
  };
}

export interface ZhixuPlatform {
  readonly type: "cloud" | "blockchain" | "cbdc" | string;
  readonly provider?: string;
  readonly version?: string;
  readonly params?: Record<string, string>;
}

export interface ZhixuTaskPattern {
  readonly name: string;
  readonly stages: readonly ZhixuStage[];
}

export interface ZhixuStage {
  readonly name: string;
  readonly source: string;
  readonly trigger: readonly string[];
  readonly executor?: ExecuteConfigs;
  readonly selectedStages?: readonly string[];
  readonly sendSignals?: readonly string[];
  readonly receiveSignals?: Record<string, string>;
  readonly fileResources?: Record<string, FileResourceLike>;
}

export interface ExecuteConfigs {
  readonly supplierType: "individual" | "organization" | "zhixu" | string;
  readonly supplierID?: string;
  readonly zhixuExecutorConfig?: {
    readonly signalMap: Record<string, string>;
  };
  readonly selectableResource?: Record<string, FileResourceLike>;
  readonly [key: string]: unknown;
}

export interface SupplierDefinition {
  readonly apiVersion: "uvp/v0";
  readonly kind: "Supplier";
  readonly metadata: ObjectMeta;
  readonly spec: {
    readonly supplierType: "individual" | "organization" | "zhixu" | string;
    readonly realIdType?: string;
    readonly realId?: string;
    readonly supplierName?: string;
    readonly handlerName?: string;
    readonly authorityID?: string;
    readonly trustDomain?: string;
    readonly capabilityClaims?: readonly string[];
    readonly attestationRefs?: readonly string[];
    readonly status?: string;
    readonly SupplierHandlerConfig: Record<string, unknown>;
  };
}

export interface HookPlanArtifact {
  readonly schemaVersion: typeof HOOK_PLAN_SCHEMA_VERSION;
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly version: string;
  readonly zhixuName: string;
  readonly platform: ZhixuPlatform;
  readonly compiledHooks: readonly CompiledHookPlanHook[];
  readonly dependencyIndex: Record<string, readonly string[]>;
  readonly executorRoutes: Record<string, HookPlanExecutorRoute>;
  readonly selectedStageBindings: readonly SelectedStageBinding[];
  readonly planHash: HexString;
}

export interface CompiledHookPlanHook {
  readonly hookId: string;
  readonly kind: "receive" | "signalMap";
  readonly stageIdentifier: string;
  readonly hookName: string;
  readonly trigger: boolean;
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

export interface SelectedStageBinding {
  readonly selectorStageIdentifier: string;
  readonly targetStageIdentifier: string;
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
  readonly routeHash: HexString;
}

export interface OnchainStageSelectorBinding {
  readonly selectorStageIdentifier: string;
  readonly targetStageIdentifier: string;
  readonly selectorStageId: HexString;
  readonly targetStageId: HexString;
  readonly bindingHash: HexString;
}

export interface OnchainCompiledHook {
  readonly hookId: HexString;
  readonly stageId: HexString;
  readonly stageIdentifier: string;
  readonly hookName: string;
  readonly kind: "receive" | "signalMap";
  readonly trigger: boolean;
  readonly instructions: readonly OnchainHookInstruction[];
  readonly dependencies: readonly OnchainHookDependency[];
  readonly routeRef?: OnchainExecutorRouteRef;
}

export interface OnchainHookPlanArtifact {
  readonly schemaVersion: typeof ONCHAIN_HOOK_PLAN_SCHEMA_VERSION;
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly version: string;
  readonly zhixuName: string;
  readonly platform: ZhixuPlatform;
  readonly sourcePlanHash: HexString;
  readonly compiledHooks: readonly OnchainCompiledHook[];
  readonly dependencyIndex: Record<HexString, readonly HexString[]>;
  readonly executorRoutes: readonly OnchainExecutorRoute[];
  readonly selectorBindings: readonly OnchainStageSelectorBinding[];
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
  readonly kind: "receive" | "signalMap";
  readonly trigger: boolean;
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
  readonly routeHash: HexString;
}

export interface SolidityRegisterStageSelectorBindingArg {
  readonly selectorStageId: HexString;
  readonly targetStageId: HexString;
}

export interface SolidityRegisterPlanArgs {
  readonly schemaVersion: typeof ONCHAIN_HOOK_PLAN_SCHEMA_VERSION;
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly version: string;
  readonly planHash: HexString;
  readonly hooks: readonly SolidityRegisterHookArg[];
  readonly dependencyIndex: readonly SolidityRegisterDependencyIndexArg[];
  readonly executorRoutes: readonly SolidityRegisterExecutorRouteArg[];
  readonly selectorBindings: readonly SolidityRegisterStageSelectorBindingArg[];
}

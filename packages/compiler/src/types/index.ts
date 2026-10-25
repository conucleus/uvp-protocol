export const COMPILER_NAME = "uvp-eth-compiler" as const;
export const COMPILER_VERSION = "0.1.0" as const;
export const HOOK_PLAN_SCHEMA_VERSION = "uvp.hookPlan.v4" as const;
export const ONCHAIN_HOOK_PLAN_SCHEMA_VERSION =
  "uvp.onchainHookPlan.v3" as const;
export const DOCK_INTERFACE_ARTIFACT_SCHEMA_VERSION =
  "uvp.dockInterfaceArtifact.v2" as const;
export const DOCK_ROUTE_SCHEMA_VERSION = "uvp.dockRoute.v4" as const;
export const DOCK_ROUTE_UNRESOLVED_SCHEMA_VERSION =
  "uvp.dockRoute.unresolved.v1" as const;
export const DOCK_RESOLUTION_SCHEMA_VERSION = "uvp.dock.resolution.v2" as const;

export type HexString = `0x${string}`;
export type Address = HexString;

export type DockOrderMode = "new" | "existing";

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
    readonly dockInterface?: DockInterfaceSource;
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
  readonly mint?: "per-fact";
  readonly executor?: ExecuteConfigs;
  readonly selectedStages?: readonly string[];
  readonly sendSignals?: readonly ZhixuSendSignal[];
  readonly receiveSignals?: Record<string, string>;
  readonly fileResources?: Record<string, FileResourceLike>;
}

export interface ZhixuSendSignal {
  readonly name: string;
  readonly validWhen?: readonly string[];
}

export interface ExecuteConfigs {
  readonly supplierType: "individual" | "organization" | "zhixu" | string;
  readonly supplierID?: string;
  readonly zhixuExecutorConfig?: ZhixuExecutorConfigSource;
  readonly selectableResource?: Record<string, FileResourceLike>;
  readonly [key: string]: unknown;
}

export type DockInterfaceSource = Record<string, DockInterfaceSpecSource>;

export interface DockInterfaceSpecSource {
  readonly orderModes: readonly DockOrderMode[];
  readonly inputs?: Record<string, { readonly hook: string }>;
  readonly outputs?: Record<string, { readonly signal: string }>;
}

export interface ZhixuExecutorConfigSource {
  readonly target: { readonly zhixu: string } | null;
  readonly interface: string;
  readonly order: { readonly mode: DockOrderMode };
  readonly inputMap?: Record<string, string>;
  readonly signalMap?: Record<string, string>;
}

export interface DockResolutionManifest {
  readonly schemaVersion: typeof DOCK_RESOLUTION_SCHEMA_VERSION;
  readonly definitions: readonly DockResolutionTarget[];
}

export interface DockResolutionTarget {
  readonly zhixu: string;
  readonly definition: ZhixuDefinition;
  readonly definitionRefHash: HexString;
  readonly artifactHash: HexString;
  readonly published: boolean;
  readonly interfaces: readonly DockInterfaceArtifactInterface[];
  readonly cloudArtifactId?: string;
  readonly evmPlanId?: HexString;
  readonly chainPlanId?: HexString;
  readonly dockEdges?: readonly { readonly target: string }[];
}

export type NeutralDockTargets = readonly NeutralDockTarget[];

export interface NeutralDockTarget {
  readonly uid: string;
  readonly definition: ZhixuDefinition;
}

export interface NeutralInterfaceDeclaration {
  readonly name: string;
  readonly orderModes: readonly string[];
  readonly inputs?: Readonly<
    Record<string, { readonly source: string; readonly hook: string }>
  >;
  readonly outputs?: Readonly<Record<string, { readonly signal: string }>>;
}

export interface NeutralDockRoute {
  readonly schemaVersion: typeof DOCK_ROUTE_SCHEMA_VERSION;
  readonly local: { readonly stageIdentifier: string };
  readonly target: { readonly uid: string; readonly interfaceName: string };
  readonly orderMode: DockOrderMode;
  readonly inputBindings: readonly { readonly hookId: string; readonly port: string }[];
  readonly outputBindings: readonly { readonly signal: string; readonly port: string }[];
}

export interface NeutralUnresolvedDockRoute {
  readonly schemaVersion: typeof DOCK_ROUTE_UNRESOLVED_SCHEMA_VERSION;
  readonly stageIdentifier: string;
  readonly localSource: string;
  readonly interfaceName: string;
  readonly orderMode: DockOrderMode;
  readonly inputBindings: readonly { readonly hookId: string; readonly port: string }[];
  readonly outputBindings: readonly { readonly signal: string; readonly port: string }[];
}

export interface DockInterfaceArtifactV2 {
  readonly schemaVersion: typeof DOCK_INTERFACE_ARTIFACT_SCHEMA_VERSION;
  readonly definition: {
    readonly uid: string;
    readonly definitionRefHash: HexString;
  };
  readonly interfaces: readonly DockInterfaceArtifactInterface[];
  readonly interfaceRoot: HexString;
}

export interface DockInterfaceArtifactInterface {
  readonly name: string;
  readonly orderModes: readonly DockOrderMode[];
  readonly inputs: readonly DockInterfaceArtifactPortInput[];
  readonly outputs: readonly DockInterfaceArtifactPortOutput[];
  readonly inputsRoot: HexString;
  readonly outputsRoot: HexString;
  readonly interfaceRoot: HexString;
}

export interface DockInterfaceArtifactPortInput {
  readonly port: string;
  readonly stageIdentifier: string;
  readonly hookName: string;
  readonly hookId: string;
  readonly canonicalInputSignal: string;
  readonly canonicalInputSignalHash: HexString;
  readonly source: string;
  readonly sourceId: HexString;
  readonly signalId: HexString;
  readonly leafHash: HexString;
}

export interface DockInterfaceArtifactPortOutput {
  readonly port: string;
  readonly canonicalOutputSignal: string;
  readonly canonicalOutputSignalHash: HexString;
  readonly source: string;
  readonly sourceId: HexString;
  readonly signalId: HexString;
  readonly leafHash: HexString;
}

export interface DockRouteV2 {
  readonly schemaVersion: typeof DOCK_ROUTE_SCHEMA_VERSION;
  readonly routeId: HexString;
  readonly local: {
    readonly definitionRefHash: HexString;
    readonly planId: HexString;
    readonly stageIdentifier: string;
    readonly stageKey: HexString;
  };
  readonly target: {
    readonly definitionRefHash: HexString;
    readonly zhixuUid: string;
    readonly zhixuName: string;
    readonly interfaceName: string;
    readonly interfaceRoot: HexString;
    readonly dockInterfaceRoot: HexString;
    readonly artifactHash: HexString;
    readonly cloudArtifactId?: string;
    readonly evmPlanId?: HexString;
    readonly chainPlanId: HexString;
  };
  readonly orderMode: DockOrderMode;
  readonly sourceSeam: string;
  readonly inputBindings: readonly DockRouteInputBinding[];
  readonly outputBindings: readonly DockRouteOutputBinding[];
  readonly inputBindingsRoot: HexString;
  readonly outputBindingsRoot: HexString;
  readonly routeHash: HexString;
}

export interface DockRouteInputBinding {
  readonly localHookName: string;
  readonly targetPort: string;
  readonly targetInputSignalHash: HexString;
  readonly targetSourceId: HexString;
  readonly targetSignalId: HexString;
  readonly targetStageIdentifier: string;
  readonly targetSignalName: string;
  readonly bindingHash: HexString;
}

export interface DockRouteOutputBinding {
  readonly localSignalName: string;
  readonly localSourceId: HexString;
  readonly localSignalId: HexString;
  readonly targetPort: string;
  readonly targetOutputSignalHash: HexString;
  readonly targetSourceId: HexString;
  readonly targetSignalId: HexString;
  readonly targetSignalName: string;
  readonly bindingHash: HexString;
}

export interface UnresolvedDockRouteCandidate {
  readonly zhixuUid: string;
  readonly zhixuName: string;
  readonly definitionRefHash: HexString;
  readonly artifactHash: HexString;
  readonly cloudArtifactId?: string;
  readonly evmPlanId?: HexString;
  readonly chainPlanId: HexString;
}

export interface UnresolvedDockRouteV1 {
  readonly schemaVersion: typeof DOCK_ROUTE_UNRESOLVED_SCHEMA_VERSION;
  readonly stageIdentifier: string;
  readonly stageId: HexString;
  readonly localDefinitionRefHash: HexString;
  readonly localPlanId: HexString;
  readonly localSource: string;
  readonly interfaceName: string;
  readonly orderMode: DockOrderMode;
  readonly inputBindings: readonly {
    readonly hookId: string;
    readonly port: string;
  }[];
  readonly outputBindings: readonly {
    readonly signal: string;
    readonly port: string;
  }[];
  readonly routeId: HexString;
  readonly candidates: readonly UnresolvedDockRouteCandidate[];
  readonly candidatesRoot: HexString;
  readonly routeHash: HexString;
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
  readonly dockInterface: DockInterfaceArtifactV2 | null;
  readonly dockRoutes: readonly DockRouteV2[];
  readonly unresolvedDockRoutes?: readonly UnresolvedDockRouteV1[];
  readonly dockRoutesRoot: HexString;
  readonly dockInterfaceRoot: HexString;
  readonly selectedStageBindings: readonly SelectedStageBinding[];
  readonly signalCapabilities: readonly SignalCapability[];
  readonly admissions: readonly CompiledHookPlanAdmission[];
  readonly source: unknown;
  readonly planHash: HexString;
}

export type OrderTriggerKind = "none" | "mint" | "dock";

export interface CompiledHookPlanHook {
  readonly hookId: string;
  readonly kind: "receive";
  readonly stageIdentifier: string;
  readonly hookName: string;
  readonly orderTriggerKind: OrderTriggerKind;
  readonly emitReady: boolean;
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
  readonly dependencyIndex: Record<HexString, readonly HexString[]>;
  readonly executorRoutes: readonly OnchainExecutorRoute[];
  readonly dockInterface: DockInterfaceArtifactV2 | null;
  readonly dockRoutes: readonly DockRouteV2[];
  readonly unresolvedDockRoutes?: readonly UnresolvedDockRouteV1[];
  readonly dockRoutesRoot: HexString;
  readonly dockInterfaceRoot: HexString;
  readonly capabilitiesRoot: HexString;
  readonly selectorBindings: readonly OnchainStageSelectorBinding[];
  readonly signalCapabilities: readonly OnchainSignalCapability[];
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
  readonly dockRoutesRoot: HexString;
  readonly dockInterfaceRoot: HexString;
  readonly executorCandidatesRoot: HexString;
  readonly hooks: readonly SolidityRegisterHookArg[];
  readonly dependencyIndex: readonly SolidityRegisterDependencyIndexArg[];
  readonly executorRoutes: readonly SolidityRegisterExecutorRouteArg[];
  readonly executorCandidates: readonly SolidityRegisterExecutorCandidateArg[];
  readonly selectorBindings: readonly SolidityRegisterStageSelectorBindingArg[];
  readonly signalCapabilities: readonly SolidityRegisterSignalCapabilityArg[];
}

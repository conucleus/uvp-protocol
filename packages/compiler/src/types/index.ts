export const COMPILER_NAME = "uvp-eth-compiler" as const;
export const COMPILER_VERSION = "0.1.0" as const;
export const HOOK_PLAN_SCHEMA_VERSION = "uvp.hookPlan.v2" as const;
export const ONCHAIN_HOOK_PLAN_SCHEMA_VERSION =
  "uvp.onchainHookPlan.v2" as const;
export const DOCK_SCHEMA_VERSION = "uvp.dock.v1" as const;
export const DOCK_INTERFACE_ARTIFACT_SCHEMA_VERSION =
  "uvp.dockInterfaceArtifact.v1" as const;
export const DOCK_ROUTE_SCHEMA_VERSION = "uvp.dockRoute.v1" as const;
export const DOCK_RESOLUTION_SCHEMA_VERSION = "uvp.dock.resolution.v1" as const;

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
    /** 目标侧公开的版本化对接接口（uvp.dock.v1）。 */
    readonly dockInterface?: DockInterfaceSource;
  };
}

// Intentionally open for future chain/runtime targets. Current public compiler
// output is EVM-facing, but the source Zhixu schema must not be narrowed to
// `provider: "eth"` or EVM-only platform fields.
export interface ZhixuPlatform {
  readonly type: "cloud" | "blockchain" | "cbdc" | string;
  readonly provider?: string;
  readonly network?: string;
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
  /**
   * Birth-stage declaration (subscription-mint model): every fanned-in fact
   * mints one order whose birth stage is this stage. Optional; "per-fact" is
   * the only mint policy.
   */
  readonly mint?: "per-fact";
  readonly executor?: ExecuteConfigs;
  readonly selectedStages?: readonly string[];
  readonly sendSignals?: readonly string[];
  readonly receiveSignals?: Record<string, string>;
  readonly fileResources?: Record<string, FileResourceLike>;
}

export interface ExecuteConfigs {
  readonly supplierType: "individual" | "organization" | "zhixu" | string;
  readonly supplierID?: string;
  /** uvp.dock.v1：`supplierType: zhixu` 时必填，且禁止 supplierID。 */
  readonly zhixuExecutorConfig?: ZhixuExecutorConfigSource;
  readonly selectableResource?: Record<string, FileResourceLike>;
  readonly [key: string]: unknown;
}

/** `spec.dockInterface` source 形状。 */
export interface DockInterfaceSource {
  readonly schemaVersion: "uvp.dock.v1";
  readonly inputs: Record<string, DockInputPortSource>;
  readonly outputs: Record<string, DockOutputPortSource>;
}

export interface DockInputPortSource {
  readonly kind: "entrance" | "signal";
  /** `<task>.<stage>#<receiveHookName>` */
  readonly hook: string;
  readonly access: { readonly policy: "open" | "permit" | "linked" };
}

export interface DockOutputPortSource {
  /** `<source>::<task>.<stage>.<signal>` */
  readonly signal: string;
  /** Rust 权威四值（dock.rs TERMINAL_TABLE），缺省 "none"。 */
  readonly terminal?: "none" | "success" | "failure" | "cancelled";
}

/** 调用方 `executor.zhixuExecutorConfig`。 */
export interface ZhixuExecutorConfigSource {
  readonly schemaVersion: "uvp.dock.v1";
  /** 目标引用只剩 zhixu：不可变 catalog UID 即完整定义身份（PRD_101）。 */
  readonly target: {
    readonly zhixu: string;
  };
  readonly order: { readonly idPolicy: "derived-v1" };
  readonly inputMap: Record<string, string>;
  readonly signalMap: Record<string, string>;
}

/** Resolution manifest：由 Store/发布系统提供。 */
export interface DockResolutionManifest {
  readonly schemaVersion: "uvp.dock.resolution.v1";
  readonly definitions: readonly DockResolutionTarget[];
}

export interface DockResolutionTarget {
  readonly zhixu: string;
  readonly definitionRefHash: HexString;
  readonly artifactHash: HexString;
  readonly published: boolean;
  readonly interface: DockInterfaceArtifact;
  readonly cloudArtifactId?: string;
  readonly evmPlanId?: HexString;
  readonly dockEdges?: readonly { zhixu: string }[];
}

/** 目标接口编译产物（数组按端口名升序）。 */
export interface DockInterfaceArtifact {
  readonly schemaVersion: "uvp.dockInterfaceArtifact.v1";
  readonly definition: {
    readonly uid: string;
    readonly definitionRefHash: HexString;
  };
  readonly inputs: readonly {
    readonly port: string;
    readonly kind: "entrance" | "signal";
    readonly stageIdentifier: string;
    readonly hookName: string;
    readonly hookId: string;
    readonly canonicalInputSignal: string;
    readonly canonicalInputSignalHash: HexString;
    readonly source: string;
    readonly sourceId: HexString;
    readonly signalId: HexString;
    readonly accessPolicy: "open" | "permit" | "linked";
    readonly leafHash: HexString;
  }[];
  readonly outputs: readonly {
    readonly port: string;
    readonly canonicalOutputSignal: string;
    readonly canonicalOutputSignalHash: HexString;
    readonly source: string;
    readonly sourceId: HexString;
    readonly signalId: HexString;
    readonly terminal: "none" | "success" | "failure" | "cancelled";
    readonly leafHash: HexString;
  }[];
  readonly interfaceRoot: HexString;
}

/** 已解析 DockRouteV1（Rust core 权威产出）。 */
export interface DockRouteV1 {
  readonly schemaVersion: "uvp.dockRoute.v1";
  readonly routeId: HexString;
  readonly local: {
    readonly definitionRefHash: HexString;
    readonly stageIdentifier: string;
    readonly stageKey: HexString;
  };
  readonly target: {
    readonly definitionRefHash: HexString;
    readonly zhixuUid: string;
    readonly artifactHash: HexString;
    readonly cloudArtifactId?: string;
    readonly evmPlanId?: HexString;
    readonly interfaceRoot: HexString;
  };
  readonly orderIdPolicy: "derived-v1";
  readonly sourceSeam: string;
  readonly entrance: {
    readonly localHookName: string;
    readonly targetPort: string;
    readonly targetStageKey: HexString;
    readonly targetHookKey: HexString;
    readonly targetInputSignalHash: HexString;
    readonly accessPolicy: "open" | "permit";
  };
  readonly inputs: readonly {
    readonly localHookName: string;
    readonly targetPort: string;
    readonly targetInputSignalHash: HexString;
    readonly targetSourceId: HexString;
    readonly targetSignalId: HexString;
    readonly kind: "entrance" | "signal";
    readonly bindingHash: HexString;
  }[];
  readonly outputs: readonly {
    readonly localSignalName: string;
    readonly localSourceId: HexString;
    readonly localSignalId: HexString;
    readonly targetPort: string;
    readonly targetOutputSignalHash: HexString;
    readonly targetSourceId: HexString;
    readonly targetSignalId: HexString;
    readonly terminal: "none" | "success" | "failure" | "cancelled";
    readonly bindingHash: HexString;
  }[];
  readonly inputsRoot: HexString;
  readonly outputsRoot: HexString;
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
  readonly dockInterface: DockInterfaceArtifact | null;
  readonly dockRoutes: readonly DockRouteV1[];
  readonly dockRoutesRoot: HexString;
  readonly dockInterfaceRoot: HexString;
  readonly selectedStageBindings: readonly SelectedStageBinding[];
  readonly signalCapabilities: readonly SignalCapability[];
  readonly planHash: HexString;
}

/** order-trigger 种类：none / mint / dock；HookReady 发出由 emitReady 表达。 */
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

export interface SelectedStageBinding {
  readonly selectorStageIdentifier: string;
  readonly targetStageIdentifier: string;
}

export type SignalTargetOrderRelation = "current" | "triggerOrigin";

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
  /**
   * Content digests of the opaque executor binding and its file resources,
   * computed once by the producer over canonical JSON. The route hash commits
   * to these digests instead of the raw free-form objects, so cross-language
   * hash reproduction only ever compares fixed hex strings.
   */
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
  readonly dockInterface: DockInterfaceArtifact | null;
  readonly dockRoutes: readonly DockRouteV1[];
  readonly dockRoutesRoot: HexString;
  readonly dockInterfaceRoot: HexString;
  readonly selectorBindings: readonly OnchainStageSelectorBinding[];
  readonly signalCapabilities: readonly OnchainSignalCapability[];
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
  readonly kind: "receive";
  /** 位标志：1=ORDER_TRIGGER_MINT，2=ORDER_TRIGGER_DOCK，4=EMIT_READY。 */
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

export interface SolidityRegisterPlanArgs {
  readonly schemaVersion: typeof ONCHAIN_HOOK_PLAN_SCHEMA_VERSION;
  readonly sourcePlanId: HexString;
  readonly zhixuId: string;
  readonly planHash: HexString;
  readonly artifactHash: HexString;
  readonly hooksHash: HexString;
  readonly metadataHash: HexString;
  readonly dockRoutesRoot: HexString;
  readonly dockInterfaceRoot: HexString;
  readonly hooks: readonly SolidityRegisterHookArg[];
  readonly dependencyIndex: readonly SolidityRegisterDependencyIndexArg[];
  readonly executorRoutes: readonly SolidityRegisterExecutorRouteArg[];
  readonly selectorBindings: readonly SolidityRegisterStageSelectorBindingArg[];
  readonly signalCapabilities: readonly SolidityRegisterSignalCapabilityArg[];
}

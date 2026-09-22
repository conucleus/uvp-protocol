export const COMPILER_NAME = "uvp-eth-compiler" as const;
export const COMPILER_VERSION = "0.1.0" as const;
export const HOOK_PLAN_SCHEMA_VERSION = "uvp.hookPlan.v2" as const;
export const ONCHAIN_HOOK_PLAN_SCHEMA_VERSION =
  "uvp.onchainHookPlan.v3" as const;
export const DOCK_INTERFACE_ARTIFACT_SCHEMA_VERSION =
  "uvp.dockInterfaceArtifact.v2" as const;
export const DOCK_ROUTE_SCHEMA_VERSION = "uvp.dockRoute.v2" as const;
/** 未解析 route（target:null 动态选择）的声明面形态（设计文档 §8.8）。 */
export const DOCK_ROUTE_UNRESOLVED_SCHEMA_VERSION =
  "uvp.dockRoute.unresolved.v1" as const;
export const DOCK_RESOLUTION_SCHEMA_VERSION = "uvp.dock.resolution.v2" as const;

export type HexString = `0x${string}`;
export type Address = HexString;

/** route 订单方式与接口 orderModes 的闭集取值。 */
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
    readonly taskPatterns: readonly ZhixuTaskPattern[];
    /** 目标侧公开的具名对接接口 map（接口名 = key）。 */
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
  /** 键闭集 {target, interface, order, inputMap, signalMap}；`supplierType: zhixu` 时必填，且禁止 supplierID。 */
  readonly zhixuExecutorConfig?: ZhixuExecutorConfigSource;
  readonly selectableResource?: Record<string, FileResourceLike>;
  readonly [key: string]: unknown;
}

/** `spec.dockInterface` source：具名接口 map（接口名 = key，与端口名同规则）。 */
export type DockInterfaceSource = Record<string, DockInterfaceSpecSource>;

export interface DockInterfaceSpecSource {
  /** {new, existing} 的非空子集，无重复。 */
  readonly orderModes: readonly DockOrderMode[];
  /** port -> hook 引用（`<task>.<stage>#<receiveHookName>`）；省略 = 空集合。 */
  readonly inputs?: Record<string, { readonly hook: string }>;
  /** port -> canonical signal（`<source>::<task>.<stage>.<signal>`）；省略 = 空集合。 */
  readonly outputs?: Record<string, { readonly signal: string }>;
}

/** 调用方 `executor.zhixuExecutorConfig`（键闭集 {target, interface, order, inputMap, signalMap}）。 */
export interface ZhixuExecutorConfigSource {
  /**
   * 键必填：`{zhixu: <目标定义 metadata.name>}`（slug）为静态目标，显式
   * `null` 表示运行时由选择记录补齐（loader/编译器对"缺键"与"null"区别
   * 拒绝/放行，类型层面 target 恒为 required）。DSL 壳不携带派生身份——
   * 名字到实体的解析是各轨权威的事（链轨 TS 内容派生 uid、云轨 DB 唯一名）。
   */
  readonly target: { readonly zhixu: string } | null;
  /** 目标接口名（与端口名同规则）。 */
  readonly interface: string;
  readonly order: { readonly mode: DockOrderMode };
  /** 本地 receiveSignals 通道名 -> 目标接口 input 端口名。 */
  readonly inputMap?: Record<string, string>;
  /** 本地 sendSignals 信号名 -> 目标接口 output 端口名。 */
  readonly signalMap?: Record<string, string>;
}

/**
 * Resolution manifest v2（链轨发布面）：由 Store/发布系统或离线 lock 文件
 * 提供。跨轨共享的解析面是中性 name 目录（uvp-core linker 消费的
 * NeutralResolutionManifest，由本包从每个 entry 派生）；内容寻址校验
 * （uid/definitionRefHash/接口叶重算比对）是链轨 TS 自己的事，不入 core。
 */
export interface DockResolutionManifest {
  readonly schemaVersion: typeof DOCK_RESOLUTION_SCHEMA_VERSION;
  readonly definitions: readonly DockResolutionTarget[];
}

export interface DockResolutionTarget {
  /** 目标定义派生身份（zx-<32hex>）；必须与内嵌 definition 派生结果一致。 */
  readonly zhixu: string;
  /** 内嵌目标定义全文（内容寻址：TS 重算 uid 三方一致校验）。 */
  readonly definition: ZhixuDefinition;
  readonly definitionRefHash: HexString;
  readonly artifactHash: HexString;
  readonly published: boolean;
  readonly interfaces: readonly DockInterfaceArtifactInterface[];
  readonly cloudArtifactId?: string;
  readonly evmPlanId?: HexString;
  /** 该定义声明的静态 dock 出边（目标定义 name），供 D015 启动图检测。 */
  readonly dockEdges?: readonly { readonly target: string }[];
}

/**
 * 中性 resolution manifest（uvp-core linker 的解析面）：name 目录 + 中性
 * 接口声明数组 + 可选 name 出边。无任何哈希/派生身份字段。
 */
export interface NeutralResolutionManifest {
  readonly schemaVersion: typeof DOCK_RESOLUTION_SCHEMA_VERSION;
  readonly definitions: readonly {
    readonly name: string;
    readonly interfaces: readonly NeutralInterfaceDeclaration[];
    readonly dockEdges?: readonly { readonly target: string }[];
  }[];
}

/**
 * 中性接口声明（core 产物/解析面共形）：接口名/orderModes/端口原文。
 * input 端口携带 source 兄弟键：hook 引用本身不含 source
 * 维度，中性声明补 `{source, hook}` 后 linker 才能对 input 与 output 两侧
 * 执行同一单源校验（uvp-core parse_interface_declaration 将 source 设为
 * 必填键，缺失/空白即 D008 响亮失败）。
 */
export interface NeutralInterfaceDeclaration {
  readonly name: string;
  readonly orderModes: readonly string[];
  readonly inputs?: Readonly<
    Record<string, { readonly source: string; readonly hook: string }>
  >;
  readonly outputs?: Readonly<Record<string, { readonly signal: string }>>;
}

/** 中性已解析 route（core hook_plan 壳元素）：本地声明 + 目标 name 引用。 */
export interface NeutralDockRoute {
  readonly schemaVersion: typeof DOCK_ROUTE_SCHEMA_VERSION;
  readonly local: { readonly stageIdentifier: string };
  readonly target: { readonly name: string; readonly interfaceName: string };
  readonly orderMode: DockOrderMode;
  readonly inputBindings: readonly { readonly hookId: string; readonly port: string }[];
  readonly outputBindings: readonly { readonly signal: string; readonly port: string }[];
}

/** 中性未解析 route（core hook_plan 壳元素，target:null 动态选择声明面）。 */
export interface NeutralUnresolvedDockRoute {
  readonly schemaVersion: typeof DOCK_ROUTE_UNRESOLVED_SCHEMA_VERSION;
  readonly stageIdentifier: string;
  readonly localSource: string;
  readonly interfaceName: string;
  readonly orderMode: DockOrderMode;
  readonly inputBindings: readonly { readonly hookId: string; readonly port: string }[];
  readonly outputBindings: readonly { readonly signal: string; readonly port: string }[];
}

/** 目标接口编译产物 v2（Rust core 权威产出，字段逐字节镜像 dock.rs to_json）。 */
export interface DockInterfaceArtifactV2 {
  readonly schemaVersion: typeof DOCK_INTERFACE_ARTIFACT_SCHEMA_VERSION;
  readonly definition: {
    readonly uid: string;
    readonly definitionRefHash: HexString;
  };
  /** 按接口名升序。 */
  readonly interfaces: readonly DockInterfaceArtifactInterface[];
  /** 定义级 dockInterfaceRoot：全部接口叶（interfaces[].interfaceRoot）的 merkle root；无接口 = EMPTY root。 */
  readonly interfaceRoot: HexString;
}

/** 一个具名接口的承诺；`interfaceRoot` = interfaceLeaf_v2。 */
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
  /** `<task>.<stage>#<receiveHookName>` 原文（即 leaf preimage 的 hookRef）。 */
  readonly hookId: string;
  readonly canonicalInputSignal: string;
  readonly canonicalInputSignalHash: HexString;
  readonly source: string;
  /** 运行期投递寻址数据（keccak(source) / keccak(task.stage.signal)），随产物携带但不入叶哈希。 */
  readonly sourceId: HexString;
  readonly signalId: HexString;
  readonly leafHash: HexString;
}

export interface DockInterfaceArtifactPortOutput {
  readonly port: string;
  /** `<source>::<task>.<stage>.<signal>` 原文（即 leaf preimage 的 canonicalSignal）。 */
  readonly canonicalOutputSignal: string;
  readonly canonicalOutputSignalHash: HexString;
  readonly source: string;
  readonly sourceId: HexString;
  readonly signalId: HexString;
  readonly leafHash: HexString;
}

/** 已解析 DockRoute v2（Rust core 权威产出）。 */
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
    /** 被绑定接口的 interfaceLeaf_v2（manifest interfaces[].interfaceRoot）。 */
    readonly interfaceRoot: HexString;
    /** 目标定义级 dockInterfaceRoot。 */
    readonly dockInterfaceRoot: HexString;
    readonly artifactHash: HexString;
    readonly cloudArtifactId?: string;
    readonly evmPlanId?: HexString;
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
  /** 目标侧可读名称（仅 JSON 投影，不参与哈希）。 */
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

/**
 * 动态选择（target:null，§8.8 / UVPDockingModule 4.4）的候选声明：resolution
 * manifest（链轨发布面）中发布该具名接口且 orderModes 覆盖 route 模式的全部
 * 定义。候选集是动态路由唯一的选择宇宙——candidatesRoot 冻结进 routeHash
 * 目标槽后，attach 只接受候选叶 membership proof 选定的目标。
 */
export interface UnresolvedDockRouteCandidate {
  /** 候选定义的内容派生身份（zx-<32hex>）。 */
  readonly zhixuUid: string;
  /** manifest 解析键（候选定义的 metadata.name）。 */
  readonly zhixuName: string;
  readonly definitionRefHash: HexString;
  /** 候选目标 plan 的 planHash（运行期定位目标 plan 用，不入候选叶）。 */
  readonly artifactHash: HexString;
  readonly cloudArtifactId?: string;
  readonly evmPlanId?: HexString;
}

/**
 * 未解析 DockRoute（target:null 动态选择，设计文档 §8.8）：本地声明面完整，
 * 目标身份空缺至运行期选择。4.4 起链轨承接动态路由——目标槽可承诺为候选集
 * root（候选叶不含任何目标端口寻址 word），绑定根恒为 EMPTY（bindingHash 的
 * preimage 含目标端口寻址 word，只能在选定后按静态公式重算），因此 routeId/
 * candidates/candidatesRoot/routeHash 四个本地承诺随声明面携带；`target` 与
 * `sourceSeam` 仍不得在场——它们只能在运行期选定目标后计算。
 */
export interface UnresolvedDockRouteV1 {
  readonly schemaVersion: typeof DOCK_ROUTE_UNRESOLVED_SCHEMA_VERSION;
  readonly stageIdentifier: string;
  /** keccak(stageIdentifier)。 */
  readonly stageId: HexString;
  /** H(UVP_DEFINITION_REF_V1, keccak(本定义 uid))。 */
  readonly localDefinitionRefHash: HexString;
  /** 与产物 planId 同源（dockInstanceId 推导消费）。 */
  readonly localPlanId: HexString;
  /** 本地 stage source（output 绑定 localSourceId 的输入）。 */
  readonly localSource: string;
  readonly interfaceName: string;
  readonly orderMode: DockOrderMode;
  readonly inputBindings: readonly {
    /** 本地被绑定通道的完整 hook 标识 `<task>.<stage>#<receiveHookName>`。 */
    readonly hookId: string;
    /** 目标 input 端口名（声明值）。 */
    readonly port: string;
  }[];
  readonly outputBindings: readonly {
    /** 本地 sendSignals 信号名。 */
    readonly signal: string;
    /** 目标 output 端口名（声明值）。 */
    readonly port: string;
  }[];
  /** H(UVP_DOCK_ROUTE_ID_V1, localDefinitionRefHash, stageKey)——与静态路由同公式。 */
  readonly routeId: HexString;
  /** 按 definitionRefHash 字节序排序的候选清单（manifest 派生，非空）。 */
  readonly candidates: readonly UnresolvedDockRouteCandidate[];
  /** merkle(dockCandidateLeaf(routeId, candidate.definitionRefHash, interfaceName)…)。 */
  readonly candidatesRoot: HexString;
  /**
   * H(UVP_DOCK_ROUTE_V2; localDefinitionRefHash, candidatesRoot,
   * keccak(interfaceName), modeWord, EMPTY, EMPTY)——目标槽被候选集 root
   * 占据、两绑定根恒 EMPTY（合约 attachDockedOrder 动态重算口径），随
   * dockRoutesRoot 在 finalize 冻结。
   */
  readonly routeHash: HexString;
}

export interface HookPlanArtifact {
  readonly schemaVersion: typeof HOOK_PLAN_SCHEMA_VERSION;
  readonly planId: HexString;
  /** 定义派生身份（zx-<32hex>）。 */
  readonly zhixuId: string;
  readonly zhixuName: string;
  readonly platform: ZhixuPlatform;
  readonly compiledHooks: readonly CompiledHookPlanHook[];
  readonly dependencyIndex: Record<string, readonly string[]>;
  readonly executorRoutes: Record<string, HookPlanExecutorRoute>;
  readonly dockInterface: DockInterfaceArtifactV2 | null;
  readonly dockRoutes: readonly DockRouteV2[];
  /**
   * target:null 动态选择 route 的声明面（§8.8）：仅非空时落字段，由 TS 承诺
   * 层从 resolution manifest 派生候选集并计算本地承诺（routeId/
   * candidatesRoot/routeHash）。4.4 起链轨承接——onchain 产物同面携带，其
   * routeHash 目标槽（候选集 root）随 dockRoutesRoot 进 finalize 承诺。
   */
  readonly unresolvedDockRoutes?: readonly UnresolvedDockRouteV1[];
  readonly dockRoutesRoot: HexString;
  readonly dockInterfaceRoot: HexString;
  readonly selectedStageBindings: readonly SelectedStageBinding[];
  readonly signalCapabilities: readonly SignalCapability[];
  /**
   * planHash preimage 的 source 快照（canonical 剔除 metadata.annotations 的
   * 定义全文）：制品携带它是为了让边界校验能重算 planHash——否则篡改
   * compiledHooks 后保留旧 planHash 也能通过反序列化校验。
   */
  readonly source: unknown;
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
  /** 定义派生身份（zx-<32hex>）。 */
  readonly zhixuId: string;
  readonly zhixuName: string;
  readonly platform: ZhixuPlatform;
  readonly sourcePlanHash: HexString;
  readonly compiledHooks: readonly OnchainCompiledHook[];
  readonly dependencyIndex: Record<HexString, readonly HexString[]>;
  readonly executorRoutes: readonly OnchainExecutorRoute[];
  readonly dockInterface: DockInterfaceArtifactV2 | null;
  readonly dockRoutes: readonly DockRouteV2[];
  /**
   * target:null 动态选择 route 的声明面（§8.8 / UVPDockingModule 4.4）：
   * 仅非空时落字段（与 hook plan IR 同约定）。动态 routeHash 的目标槽 =
   * 候选集 root，已计入 dockRoutesRoot（finalize 冻结的最终根 = 静态叶 ∪
   * 动态叶）；绑定根恒 EMPTY，选定目标后按静态公式在 attach 期重算。
   */
  readonly unresolvedDockRoutes?: readonly UnresolvedDockRouteV1[];
  readonly dockRoutesRoot: HexString;
  readonly dockInterfaceRoot: HexString;
  /** 能力表/绑定表的域分隔叶混编树根（链上唯一承诺形态）。 */
  readonly capabilitiesRoot: HexString;
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
  /** 与 OnchainExecutorRoute 同面：执行者/资源承诺摘要随 calldata 携带。 */
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
  readonly hooks: readonly SolidityRegisterHookArg[];
  readonly dependencyIndex: readonly SolidityRegisterDependencyIndexArg[];
  readonly executorRoutes: readonly SolidityRegisterExecutorRouteArg[];
  readonly selectorBindings: readonly SolidityRegisterStageSelectorBindingArg[];
  readonly signalCapabilities: readonly SolidityRegisterSignalCapabilityArg[];
}

// V3 订单域 DTO：配置对象、订单草稿/阶段/slot/邀请、订单读面与两个
// 订单簿 EIP-712 消息形状。这里只定义通用产品语言，不含行业字段，
// 也不承载服务端状态、签名校验或链上授权语义。

export const ORDER_CONFIG_V3_SCHEMA = "uvp.order-config/v3" as const;

export type OrderConfigStatusV3 = "draft" | "published" | "deprecated";

export type ConfigSlotKindV3 = "participant" | "contract" | "oracle";

/**
 * 单个 slot 的可见范围声明。缺省即最小可见；服务端按该声明与订单
 * slot 绑定裁剪读面，客户端不得据此自行放行。
 */
export interface ConfigSlotVisibilityV3 {
  readonly amounts?: boolean;
  readonly files?: readonly string[];
  readonly participants?: readonly string[];
  readonly escrow?: readonly string[];
}

export interface ConfigSlotV3 {
  readonly key: string;
  readonly label?: string;
  readonly kind: ConfigSlotKindV3;
  readonly visibility?: ConfigSlotVisibilityV3;
}

export interface ConfigStageSenderV3 {
  readonly slot: string;
  readonly signals?: readonly string[];
}

export interface ConfigStageSignalV3 {
  readonly name: string;
  readonly by?: string;
  readonly validWhen?: readonly string[];
}

export interface ConfigHookV3 {
  readonly name: string;
  readonly expr: string;
  readonly description?: string;
}

export interface ConfigTimeV3 {
  readonly name: string;
  readonly expr?: string;
  readonly description?: string;
}

/** 凝结核声明的窗口：default/min/max 为 DSL 时间字面量（如 3d），订单只可覆写值。 */
export interface ConfigWindowV3 {
  readonly key: string;
  readonly default: string;
  readonly min?: string;
  readonly max?: string;
  readonly description?: string;
}

/** 时间表达式的默认名与模板；`{{window_key}}` 由订单窗口值渲染。 */
export interface ConfigTimeDefaultV3 {
  readonly name: string;
  readonly expr: string;
  readonly description?: string;
}

export type ConfigAcceptanceModeV3 = "self" | "third_party" | "mutual" | "none";

export interface ConfigAcceptanceV3 {
  readonly mode: ConfigAcceptanceModeV3;
}

/** 文件资源引用只存句柄/元数据，正文与凭据在配置包之外。 */
export interface ConfigFileResourceRefV3 {
  readonly name?: string;
  readonly version?: string;
  readonly hash?: string;
  readonly ref: string;
}

export interface ConfigStageV3 {
  readonly key: string;
  readonly name?: string;
  readonly index?: number;
  readonly optional?: boolean;
  readonly funded?: boolean;
  readonly description?: string;
  readonly senders?: readonly (ConfigStageSenderV3 | string)[];
  /** slot key → 该配置阶段的业务标签/展示名；不含协议角色语义。 */
  readonly slots?: Readonly<Record<string, string>>;
  readonly signals?: readonly ConfigStageSignalV3[];
  readonly receiveSignals?: readonly ConfigStageSignalV3[];
  readonly hooks?: readonly ConfigHookV3[];
  readonly time?: readonly ConfigTimeV3[];
  readonly acceptance?: ConfigAcceptanceV3;
  readonly fileResources?: readonly (ConfigFileResourceRefV3 | string)[];
  readonly amount?: Readonly<Record<string, unknown>>;
  readonly linkSignal?: string;
  readonly ui?: Readonly<Record<string, unknown>>;
}

export interface ConfigDefaultsV3 {
  readonly timeExpressions?: Readonly<Record<string, string>>;
  readonly acceptance?: ConfigAcceptanceV3;
}

export interface ConfigBundleV3 {
  readonly schema?: typeof ORDER_CONFIG_V3_SCHEMA | string;
  readonly configId: string;
  readonly version: string;
  readonly status: OrderConfigStatusV3;
  readonly title?: string;
  readonly description?: string;
  readonly currency?: string;
  readonly chain?: Readonly<Record<string, unknown>>;
  readonly flow?: Readonly<Record<string, unknown>>;
  readonly slots: readonly ConfigSlotV3[];
  readonly stages: readonly ConfigStageV3[];
  readonly defaults?: ConfigDefaultsV3;
  readonly windows?: readonly ConfigWindowV3[];
  readonly timeDefaults?: readonly ConfigTimeDefaultV3[];
  readonly stageSubsets?: Readonly<Record<string, readonly string[]>>;
  readonly stageProfiles?: Readonly<Record<string, readonly string[]>>;
  readonly defaultProfile?: string;
  readonly standards?: Readonly<Record<string, unknown>>;
  readonly fileResources?: readonly ConfigFileResourceRefV3[];
  readonly hashes?: Readonly<Record<string, unknown>>;
  readonly ui?: Readonly<Record<string, unknown>>;
  readonly createdAt?: string;
  readonly supersedes?: string;
}

/** 已发布 plan 的 outside-trigger 出生入口（来自 plan 注册产物，非订单字段）。 */
export interface ConfigBirthV3 {
  readonly triggerHookId: string;
  readonly triggerStageId: string;
  readonly sourceId: string;
  readonly signalId: string;
  readonly birthAuthorizer: string;
}

export interface ConfigVersionV3 {
  readonly configId: string;
  readonly version: string;
  readonly status: OrderConfigStatusV3;
  readonly configHash: string;
  readonly title?: string;
  readonly currency?: string;
  /** 配置版本发布时已编译/注册的 UVP plan；同一配置的所有订单复用它。 */
  readonly planId?: string;
  readonly planHash?: string;
  readonly birth?: ConfigBirthV3;
  readonly createdBy: string;
  readonly createdAt: string;
  readonly publishedAt?: string;
  readonly bundle: ConfigBundleV3;
}

export interface StageStandardRefV3 {
  readonly name: string;
  readonly version?: string;
  readonly hash: string;
  readonly ref?: string;
}

/** 订单阶段的冻结条款（服务端派生 stageId/termsHash，客户端不可自报）。 */
/**
 * 配置派生窗口值（窗口名 → 秒）。只由已发布配置版本解析，属于 plan 生成
 * 产物/读面快照；订单草稿不携带、不接受窗口覆写。
 */
export type StageWindowValuesV3 = Readonly<Record<string, number>>;

export interface StageTermsV3 {
  readonly orderDraftId: string;
  readonly configId: string;
  readonly configVersion: string;
  readonly configHash: string;
  readonly stageKey: string;
  readonly stageId: string;
  readonly slots: Readonly<Record<string, string>>;
  readonly amount: string;
  readonly standard?: StageStandardRefV3;
  readonly finalStandardHash: string;
  readonly inviteDeadline: string;
  readonly workDeadline: string;
  readonly profileRef?: string;
  readonly termsHash?: string;
}

export type OrderDraftStatusV3 = "draft" | "inviting" | "ready" | "triggered" | "cancelled";

export interface OrderDraftV3 {
  readonly draftId: string;
  readonly configId: string;
  readonly configVersion: string;
  readonly configHash: string;
  readonly buyerWallet: string;
  readonly chainId: number;
  readonly stateMachine: string;
  readonly title: string;
  readonly currency: string;
  readonly stageSubset: readonly string[];
  readonly stages: readonly StageTermsV3[];
  readonly status: OrderDraftStatusV3;
  readonly termsHash: string | null;
  readonly orderId?: string;
  readonly planId?: string;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly frozenAt?: string;
}

export type StageSlotStatusV3 = "uninvited" | "invited" | "accepted" | "rejected";

export interface StageSlotV3 {
  readonly draftId: string;
  readonly stageKey: string;
  readonly stageId: string;
  readonly slotKey: string;
  readonly required: boolean;
  readonly subjectLabel?: string;
  readonly contactRef?: string;
  readonly wallet?: string;
  readonly status: StageSlotStatusV3;
  readonly inviteId?: string;
  readonly acceptedTermsHash?: string;
  readonly acceptedAt?: string;
  readonly signature?: string;
}

export type StageInviteStatusV3 = "active" | "accepted" | "rejected" | "expired" | "revoked";

export interface InviteV3 {
  readonly inviteId: string;
  readonly draftId: string;
  readonly stageKey: string;
  readonly stageId: string;
  readonly slotKey: string;
  readonly subjectLabel: string;
  readonly contactRef?: string;
  readonly wallet?: string;
  readonly status: StageInviteStatusV3;
  readonly expiresAt: string;
  readonly createdAt: string;
  readonly acceptedBy?: string;
  readonly acceptedAt?: string;
}

/** 创建邀请的一次性回执：明文 token 只在这里出现，服务端只存 hash。 */
export interface StageInviteCreatedV3 extends InviteV3 {
  readonly inviteToken: string;
}

/** 阶段参与者绑定：一个阶段里谁以什么角色绑定到哪个钱包。 */
export interface StageBindingV3 {
  readonly draftId: string;
  readonly orderId?: string;
  readonly stageKey: string;
  readonly stageId: string;
  readonly slotKey: string;
  readonly wallet: string;
  readonly termsHash: string;
  readonly acceptedAt?: string;
}

export type StageTaskKindV3 =
  | "accept_invite"
  | "fund_stage"
  | "perform_stage"
  | "verify_stage"
  | "settle_stage";

export type StageTaskStatusV3 = "open" | "blocked" | "done";

/** 任务是从事实/配置派生的投影，不是新的状态机。 */
export interface StageTaskV3 {
  readonly taskId: string;
  readonly orderId?: string;
  readonly draftId?: string;
  readonly stageKey: string;
  readonly slotKey: string;
  readonly wallet: string;
  readonly kind: StageTaskKindV3;
  readonly status: StageTaskStatusV3;
  readonly dueAt?: string;
  readonly actionRef?: string;
}

export interface OrderStageV3 {
  readonly stageKey: string;
  readonly stageId: string;
  readonly index: number;
  readonly amount: string;
  readonly slots: Readonly<Record<string, string>>;
  readonly finalStandardHash: string;
  readonly inviteDeadline: string;
  readonly workDeadline: string;
  readonly profileRef?: string;
  readonly status: string;
}

export interface OrderV3 {
  readonly orderId: string;
  readonly draftId: string;
  readonly planId: string;
  readonly stateMachine: string;
  readonly chainId: number;
  readonly buyerWallet: string;
  readonly status: string;
  readonly termsHash: string;
  readonly txHash?: string;
  readonly createdAt: string;
  readonly stages: readonly OrderStageV3[];
}

// ---------------------------------------------------------------------------
// 写侧输入/回执（服务端只信任会话身份与会话外重算的派生值）。
// ---------------------------------------------------------------------------

export interface StageTermsInputV3 {
  readonly stageKey: string;
  readonly amount: string;
  readonly slots?: Readonly<Record<string, string>>;
  readonly standard?: StageStandardRefV3;
  readonly finalStandardHash?: string;
  readonly inviteDeadline: string;
  readonly workDeadline: string;
  readonly profileRef?: string;
}

export interface CreateOrderDraftV3Input {
  readonly configId: string;
  readonly configVersion: string;
  readonly title: string;
  readonly currency: string;
  readonly stageSubset: readonly string[];
  readonly stageTerms: readonly StageTermsInputV3[];
}

export interface UpdateOrderDraftV3Input {
  readonly title?: string;
  readonly currency?: string;
  readonly stageTerms?: readonly StageTermsInputV3[];
}

export interface CreateStageInviteV3Input {
  readonly stageKey: string;
  readonly slotKey: string;
  readonly subjectLabel: string;
  readonly contactRef?: string;
  readonly wallet?: string;
  readonly expiresAt?: string;
}

export interface AcceptStageInviteV3Input {
  readonly token: string;
  readonly signature: string;
  readonly termsHash: string;
  readonly nonce: string;
}

export interface RejectStageInviteV3Input {
  readonly token: string;
}

export type OrderBirthStatusV3 = "confirmed" | "submitted" | "unknown";

export interface FinalizeOrderDraftV3Result {
  readonly draftId: string;
  readonly orderId: string;
  readonly planId: string;
  readonly planHash: string;
  readonly stateMachine: string;
  readonly status: OrderBirthStatusV3;
  readonly fundedStageKeys: readonly string[];
  readonly skippedStageKeys: readonly string[];
  readonly txHash?: string;
}

export interface FinalizeOrderDraftV3Input {
  readonly signature: string;
}

export interface FinalizeOrderDraftV3Preparation {
  readonly draftId: string;
  readonly planId: string;
  readonly planHash: string;
  readonly termsHash: string;
  readonly payloadHash: string;
  readonly fundedStageKeys: readonly string[];
  readonly skippedStageKeys: readonly string[];
  readonly nonce: string;
  readonly deadline: string;
  readonly typedData: UVPOrderFinalizeTypedData;
}

export interface OrderV3StageDetail {
  readonly order: OrderV3;
  readonly stage: OrderStageV3;
  readonly slots: readonly StageSlotV3[];
}

export interface OrderDraftDetailV3 {
  readonly draft: OrderDraftV3;
  readonly slots: readonly StageSlotV3[];
}

export interface StageInvitePreviewV3 {
  readonly invite: InviteV3;
  readonly draftId: string;
  readonly title: string;
  readonly stageId: string;
  readonly terms: StageTermsV3;
  readonly typedData: UVPStageInviteAcceptTypedData;
  readonly chainId: number;
  readonly stateMachineAddress: string;
  /** 服务端一次性下发的签名 nonce（EIP-712 message.nonce）。 */
  readonly signNonce: string;
  readonly termsHash: string;
}

export interface AcceptStageInviteV3Result {
  readonly invite: InviteV3;
  readonly slot: StageSlotV3;
  readonly draftStatus: OrderDraftStatusV3;
  readonly termsHash: string;
}

// ---------------------------------------------------------------------------
// EIP-712 消息形状（domain 常量/type hash 在 @uvp-eth/protocol-bindings）。
// ---------------------------------------------------------------------------

export interface Eip712FieldV3 {
  readonly name: string;
  readonly type: string;
}

export interface OrderBookDomainV3 {
  readonly name: "UVPOrderBook";
  readonly version: "1";
  readonly chainId: number;
  readonly verifyingContract: string;
}

export interface UVPStageInviteAcceptMessage {
  readonly draftId: string;
  readonly inviteId: string;
  readonly stageKey: string;
  readonly stageId: string;
  readonly slotKey: string;
  readonly invitee: string;
  readonly amount: string;
  readonly finalStandardHash: string;
  readonly workDeadline: string;
  readonly termsHash: string;
  readonly nonce: string;
  readonly deadline: string;
}

export interface UVPStageInviteAcceptTypedData {
  readonly domain: OrderBookDomainV3;
  readonly types: {
    readonly UVPStageInviteAccept: readonly Eip712FieldV3[];
  };
  readonly primaryType: "UVPStageInviteAccept";
  readonly message: UVPStageInviteAcceptMessage;
}

export interface UVPOrderFinalizeMessage {
  readonly draftId: string;
  readonly planId: string;
  readonly configId: string;
  readonly configVersion: string;
  readonly configHash: string;
  readonly buyer: string;
  readonly termsHash: string;
  readonly nonce: string;
  readonly deadline: string;
}

export interface UVPOrderFinalizeTypedData {
  readonly domain: OrderBookDomainV3;
  readonly types: {
    readonly UVPOrderFinalize: readonly Eip712FieldV3[];
  };
  readonly primaryType: "UVPOrderFinalize";
  readonly message: UVPOrderFinalizeMessage;
}

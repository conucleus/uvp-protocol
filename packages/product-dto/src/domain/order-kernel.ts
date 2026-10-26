/**
 * 订单域 DTO：配置对象、订单草稿/阶段/slot/邀请、订单读面。
 * EIP-712 订单簿 typed-data 单源在 @uvp-eth/protocol-bindings（UVPOrderBook/1），
 * 本模块只引用其类型，不自持副本；不含行业字段。
 */

import type {
  UVPOrderFinalizeTypedData,
  UVPStageInviteAcceptTypedData,
} from "@uvp-eth/protocol-bindings";

export const ORDER_CONFIG_SCHEMA = "uvp.order-config/v3" as const;

export type OrderConfigStatus = "draft" | "published" | "deprecated";

export type ConfigSlotKind = "participant" | "contract" | "oracle";

export interface ConfigSlotVisibility {
  readonly amounts?: boolean;
  readonly files?: readonly string[];
  readonly participants?: readonly string[];
}

export interface ConfigSlot {
  readonly key: string;
  readonly label?: string;
  readonly kind: ConfigSlotKind;
  readonly visibility?: ConfigSlotVisibility;
}

export interface ConfigStageSender {
  readonly slot: string;
  readonly signals?: readonly string[];
}

export interface ConfigStageSignal {
  readonly name: string;
  readonly by?: string;
  readonly validWhen?: readonly string[];
}

export interface ConfigHook {
  readonly name: string;
  readonly expr: string;
  readonly description?: string;
}

export interface ConfigTime {
  readonly name: string;
  readonly expr?: string;
  readonly description?: string;
}

export interface ConfigWindow {
  readonly key: string;
  readonly default: string;
  readonly min?: string;
  readonly max?: string;
  readonly description?: string;
}

export interface ConfigTimeDefault {
  readonly name: string;
  readonly expr: string;
  readonly description?: string;
}

export interface ConfigFileResourceRef {
  readonly name?: string;
  readonly version?: string;
  readonly hash?: string;
  readonly ref: string;
}

export interface ConfigStage {
  readonly key: string;
  readonly name?: string;
  readonly index?: number;
  readonly optional?: boolean;
  readonly funded?: boolean;
  readonly description?: string;
  readonly senders?: readonly (ConfigStageSender | string)[];
  readonly slots?: Readonly<Record<string, string>>;
  readonly signals?: readonly ConfigStageSignal[];
  readonly receiveSignals?: readonly ConfigStageSignal[];
  readonly hooks?: readonly ConfigHook[];
  readonly time?: readonly ConfigTime[];
  readonly fileResources?: readonly (ConfigFileResourceRef | string)[];
  readonly amount?: Readonly<Record<string, unknown>>;
  readonly linkSignal?: string;
  readonly ui?: Readonly<Record<string, unknown>>;
}

export interface ConfigDefaults {
  readonly timeExpressions?: Readonly<Record<string, string>>;
}

export interface ConfigBundle {
  readonly schema?: typeof ORDER_CONFIG_SCHEMA | string;
  readonly configId: string;
  readonly version: string;
  readonly status: OrderConfigStatus;
  readonly title?: string;
  readonly description?: string;
  readonly currency?: string;
  readonly chain?: Readonly<Record<string, unknown>>;
  readonly flow?: Readonly<Record<string, unknown>>;
  readonly slots: readonly ConfigSlot[];
  readonly stages: readonly ConfigStage[];
  readonly defaults?: ConfigDefaults;
  readonly windows?: readonly ConfigWindow[];
  readonly timeDefaults?: readonly ConfigTimeDefault[];
  readonly stageSubsets?: Readonly<Record<string, readonly string[]>>;
  readonly stageProfiles?: Readonly<Record<string, readonly string[]>>;
  readonly defaultProfile?: string;
  readonly standards?: Readonly<Record<string, unknown>>;
  readonly fileResources?: readonly ConfigFileResourceRef[];
  readonly hashes?: Readonly<Record<string, unknown>>;
  readonly ui?: Readonly<Record<string, unknown>>;
  readonly createdAt?: string;
  readonly supersedes?: string;
}

export interface ConfigBirth {
  readonly triggerHookId: string;
  readonly triggerStageId: string;
  readonly sourceId: string;
  readonly signalId: string;
  readonly birthAuthorizer: string;
}

export interface ConfigVersion {
  readonly configId: string;
  readonly version: string;
  readonly status: OrderConfigStatus;
  readonly configHash: string;
  readonly title?: string;
  readonly currency?: string;
  readonly planId?: string;
  readonly planHash?: string;
  readonly birth?: ConfigBirth;
  readonly createdBy: string;
  readonly createdAt: string;
  readonly publishedAt?: string;
  readonly bundle: ConfigBundle;
}

export interface StageStandardRef {
  readonly name: string;
  readonly version?: string;
  readonly hash: string;
  readonly ref?: string;
}

export type StageWindowValues = Readonly<Record<string, number>>;

export interface StageTerms {
  readonly orderDraftId: string;
  readonly configId: string;
  readonly configVersion: string;
  readonly configHash: string;
  readonly stageKey: string;
  readonly stageId: string;
  readonly slots: Readonly<Record<string, string>>;
  readonly amount: string;
  readonly standard?: StageStandardRef;
  readonly finalStandardHash: string;
  readonly inviteDeadline: string;
  readonly workDeadline: string;
  readonly profileRef?: string;
  readonly termsHash?: string;
}

export type OrderDraftStatus = "draft" | "inviting" | "ready" | "triggered" | "cancelled";

export interface OrderDraft {
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
  readonly stages: readonly StageTerms[];
  readonly status: OrderDraftStatus;
  readonly termsHash: string | null;
  readonly orderId?: string;
  readonly planId?: string;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly frozenAt?: string;
}

export type StageSlotStatus = "uninvited" | "invited" | "accepted" | "rejected";

export interface StageSlot {
  readonly draftId: string;
  readonly stageKey: string;
  readonly stageId: string;
  readonly slotKey: string;
  readonly required: boolean;
  readonly subjectLabel?: string;
  readonly contactRef?: string;
  readonly wallet?: string;
  readonly status: StageSlotStatus;
  readonly inviteId?: string;
  readonly acceptedTermsHash?: string;
  readonly acceptedAt?: string;
  readonly signature?: string;
}

export type StageInviteStatus = "active" | "accepted" | "rejected" | "expired" | "revoked";

export interface Invite {
  readonly inviteId: string;
  readonly draftId: string;
  readonly stageKey: string;
  readonly stageId: string;
  readonly slotKey: string;
  readonly subjectLabel: string;
  readonly contactRef?: string;
  readonly wallet?: string;
  readonly status: StageInviteStatus;
  readonly expiresAt: string;
  readonly createdAt: string;
  readonly acceptedBy?: string;
  readonly acceptedAt?: string;
}

export interface StageInviteCreated extends Invite {
  readonly inviteToken: string;
}

export interface StageBinding {
  readonly draftId: string;
  readonly orderId?: string;
  readonly stageKey: string;
  readonly stageId: string;
  readonly slotKey: string;
  readonly wallet: string;
  readonly termsHash: string;
  readonly acceptedAt?: string;
}

export type StageTaskKind = "accept_invite" | "perform_stage";

export type StageTaskStatus = "open" | "blocked" | "done";

export interface StageTask {
  readonly taskId: string;
  readonly orderId?: string;
  readonly draftId?: string;
  readonly stageKey: string;
  readonly slotKey: string;
  readonly wallet: string;
  readonly kind: StageTaskKind;
  readonly status: StageTaskStatus;
  readonly dueAt?: string;
  readonly actionRef?: string;
}

export interface OrderStage {
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

export interface Order {
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
  readonly stages: readonly OrderStage[];
}

export interface StageTermsInput {
  readonly stageKey: string;
  readonly amount: string;
  readonly slots?: Readonly<Record<string, string>>;
  readonly standard?: StageStandardRef;
  readonly finalStandardHash?: string;
  readonly inviteDeadline: string;
  readonly workDeadline: string;
  readonly profileRef?: string;
}

export interface CreateOrderDraftInput {
  readonly configId: string;
  readonly configVersion: string;
  readonly title: string;
  readonly currency: string;
  readonly stageSubset: readonly string[];
  readonly stageTerms: readonly StageTermsInput[];
}

export interface UpdateOrderDraftInput {
  readonly title?: string;
  readonly currency?: string;
  readonly stageTerms?: readonly StageTermsInput[];
}

export interface CreateStageInviteInput {
  readonly stageKey: string;
  readonly slotKey: string;
  readonly subjectLabel: string;
  readonly contactRef?: string;
  readonly wallet?: string;
  readonly expiresAt?: string;
}

export interface AcceptStageInviteInput {
  readonly token: string;
  readonly signature: string;
  readonly termsHash: string;
  readonly nonce: string;
}

export interface RejectStageInviteInput {
  readonly token: string;
}

export type OrderBirthStatus = "confirmed" | "submitted" | "unknown";

export interface FinalizeOrderDraftResult {
  readonly draftId: string;
  readonly orderId: string;
  readonly planId: string;
  readonly planHash: string;
  readonly stateMachine: string;
  readonly status: OrderBirthStatus;
  readonly fundedStageKeys: readonly string[];
  readonly skippedStageKeys: readonly string[];
  readonly txHash?: string;
}

export interface FinalizeOrderDraftInput {
  readonly signature: string;
}

export interface FinalizeOrderDraftPreparation {
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

export interface OrderStageDetail {
  readonly order: Order;
  readonly stage: OrderStage;
  readonly slots: readonly StageSlot[];
}

export interface OrderDraftDetail {
  readonly draft: OrderDraft;
  readonly slots: readonly StageSlot[];
}

export interface StageInvitePreview {
  readonly invite: Invite;
  readonly draftId: string;
  readonly title: string;
  readonly stageId: string;
  readonly terms: StageTerms;
  readonly typedData: UVPStageInviteAcceptTypedData;
  readonly chainId: number;
  readonly stateMachineAddress: string;
  readonly signNonce: string;
  readonly termsHash: string;
}

export interface AcceptStageInviteResult {
  readonly invite: Invite;
  readonly slot: StageSlot;
  readonly draftStatus: OrderDraftStatus;
  readonly termsHash: string;
}

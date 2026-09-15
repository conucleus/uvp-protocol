// 写侧契约（治理审计 §1.1 P1-1：Product API 写侧契约 ×7 手写已冲突）。
// 形状以 uvp-chain-services 服务端真身为权威（submissions/types.ts、
// evidence/types.ts、evidence/service.ts 的 getProof 产出、reconcile/
// status.ts），本包不引入 protocol-bindings 依赖，hex/address 用自持别名。
// 前端与客户端切换 import 由后续治理批执行。
//
// 权威裁决落点：ProductSubmissionDTO.statusLabel 定为必填 string——服务端
// 类型标注可选，但 withSubmissionReconcileDefaults（submissions/service.ts）
// 对每次读取恒兜底产出；三端手写版曾是"可选/必填/无"三样分叉。
// EvidenceProofDTO 的 evidenceId/payloadRef 同理：getProof 恒产出，定为必填
//（order-app 手写版曾为可选、zhixu-store 手写版曾整体缺失）。

/** EVM 十六进制标量（自持别名）。 */
export type ProductWriteHex = `0x${string}`;
/** EVM 地址（自持别名）。 */
export type ProductWriteAddress = `0x${string}`;

/**
 * 产品任务提交意图（服务端 PrepareProductTaskSubmitInput.intent 的权威
 * 词表）。与 TaskSubmitIntent（任务侧推导镜像）是同一联合的历史名字，
 * 值域恒等。
 */
export type ProductSubmitIntent =
  | "confirm_stage"
  | "reject_stage"
  | "raise_dispute"
  | "resolve_dispute";

/** POST /product/tasks/:id/prepare-submit 请求体。 */
export interface PrepareProductTaskSubmitInput {
  readonly evidenceIds: readonly string[];
  readonly walletAddress: string;
  readonly intent: ProductSubmitIntent;
}

/** POST /product/tasks/:id/submit 请求体。 */
export interface SubmitProductTaskInput {
  readonly prepareId: string;
  readonly signature: string;
  readonly walletAddress: string;
}

/** 证据核验状态（服务端 evidence/types.ts 权威词表）。 */
export type EvidenceVerificationStatus =
  | "unbound"
  | "matched"
  | "mismatch"
  | "missing_file";

/**
 * GET /product/evidence/:id/proof 响应 proof 字段的权威字段集：evidenceId/
 * payloadRef/storageURI 为服务端 getProof 恒产出（必填），绑定定位五件套
 * 与 blockNumber/submitter 按记录现状可选。
 */
export interface EvidenceProofDTO {
  readonly evidenceId: string;
  readonly payloadHash: ProductWriteHex;
  readonly contentHash: ProductWriteHex;
  readonly metadataHash: ProductWriteHex;
  readonly payloadRef: string;
  readonly storageURI: string;
  readonly boundSignalTxHash?: ProductWriteHex;
  readonly boundSubmissionId?: string;
  readonly boundOnchainOrderId?: ProductWriteHex;
  readonly boundSourceId?: ProductWriteHex;
  readonly boundSignalId?: ProductWriteHex;
  readonly boundAt?: string;
  readonly blockNumber?: string;
  readonly submitter?: string;
  readonly verificationStatus: EvidenceVerificationStatus;
}

/** 提交生命周期状态（服务端 submissions/types.ts 权威词表）。 */
export type ProductSubmissionStatus =
  | "prepared"
  | "signature_received"
  | "broadcasting"
  | "submitted"
  | "indexing"
  | "confirmed"
  | "failed"
  | "expired"
  | "replaced";

export type ProductSubmissionBroadcastStatus =
  | "not_attempted"
  | "broadcasting"
  | "submitted"
  | "confirmed"
  | "failed";

export type ProductSubmissionAttemptStatus =
  | "broadcasting"
  | "submitted"
  | "confirmed"
  | "failed";

export type ProductSubmissionRetryState =
  | "not_applicable"
  | "retryable"
  | "not_retryable"
  | "dead_letter";

export interface ProductSubmissionProofRowDTO {
  readonly label: string;
  readonly value: string;
}

export interface ProductSubmissionAttemptDTO {
  readonly attemptId: string;
  readonly submissionId: string;
  readonly orderId: string;
  readonly sourceId: ProductWriteHex;
  readonly signalId: ProductWriteHex;
  readonly submitter: ProductWriteAddress;
  readonly txHash?: ProductWriteHex;
  readonly blockNumber?: string;
  readonly status: ProductSubmissionAttemptStatus;
  readonly errorCode?: string;
  readonly errorLabel?: string;
  readonly errorMessage?: string;
  readonly revertReason?: string;
  readonly gasPayer?: ProductWriteAddress;
  readonly attemptNumber: number;
  readonly retryable: boolean;
  readonly retryState: ProductSubmissionRetryState;
  readonly deadLetter: boolean;
  readonly nextRetryAt?: string;
  readonly createdAt: string;
  readonly updatedAt: string;
}

// 事务对账投影（服务端 reconcile/status.ts TxReconcileFields 的自持镜像）。
export type TxReconcileStatus =
  | "broadcasting"
  | "submitted"
  | "indexing"
  | "confirmed"
  | "failed"
  | "stale_pending";

export type TxReceiptStatus =
  | "not_checked"
  | "missing"
  | "unknown"
  | "success"
  | "failed"
  | "timeout";

export type TxProjectionStatus = "not_checked" | "missing" | "present";

export interface TxReconcileFields {
  readonly reconcileStatus?: TxReconcileStatus;
  readonly lastCheckedAt?: string;
  readonly receiptStatus?: TxReceiptStatus;
  readonly projectionStatus?: TxProjectionStatus;
}

/**
 * 提交回执（POST /product/tasks/:id/submit 响应与 GET
 * /product/submissions/:id 的同形 DTO）：逐字段对齐服务端
 * ProductSubmissionDTO；statusLabel 必填（服务端读取兜底恒产出）。
 */
export interface ProductSubmissionDTO extends TxReconcileFields {
  readonly submissionId: string;
  readonly prepareId: string;
  readonly taskId: string;
  readonly orderId: string;
  readonly onchainOrderId: ProductWriteHex;
  /** The plan-scoped identity committed by the prepared EIP-712 signature. */
  readonly planId: ProductWriteHex;
  readonly stageIdentifier: string;
  readonly signalName: string;
  readonly sourceId: ProductWriteHex;
  readonly signalId: ProductWriteHex;
  readonly intent: ProductSubmitIntent;
  readonly payloadHash: ProductWriteHex;
  readonly payloadRef: string;
  readonly idempotencyKey: ProductWriteHex;
  readonly submitter: ProductWriteAddress;
  readonly nonce: string;
  readonly deadline: string;
  readonly status: ProductSubmissionStatus;
  /** 展示标签：服务端 withSubmissionReconcileDefaults 恒兜底产出——必填。 */
  readonly statusLabel: string;
  readonly signatureStatus: "not_verified" | "signature_verified";
  readonly signatureHash?: ProductWriteHex;
  readonly recoveredSubmitter?: ProductWriteAddress;
  readonly broadcastStatus: ProductSubmissionBroadcastStatus;
  readonly txHash?: ProductWriteHex;
  readonly blockNumber?: string;
  readonly errorCode?: string;
  readonly errorLabel?: string;
  readonly errorMessage?: string;
  readonly retryable: boolean;
  readonly retryState: ProductSubmissionRetryState;
  readonly deadLetter: boolean;
  readonly nextRetryAt?: string;
  readonly attempts: readonly ProductSubmissionAttemptDTO[];
  readonly attemptCount: number;
  readonly proofRows: readonly ProductSubmissionProofRowDTO[];
  /**
   * 随提交落库的证据引用（绑定载荷）：reconcile 清扫对"链上提交已成功
   * 但绑定缺失"的记录重试绑定时，唯一的持久化依据。
   */
  readonly evidenceIds?: readonly string[];
  readonly createdAt: string;
  readonly updatedAt: string;
}

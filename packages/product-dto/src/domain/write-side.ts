/**
 * 写侧契约单源：形状以 uvp-chain-services 服务端真身为权威，前端与客户端
 * 一律从本包 import，不自持副本；hex/address 用自持别名。
 */

export type ProductWriteHex = `0x${string}`;
export type ProductWriteAddress = `0x${string}`;

export type ProductSubmitIntent = "confirm_stage" | "reject_stage";

export interface PrepareProductTaskSubmitInput {
  readonly evidenceIds: readonly string[];
  readonly walletAddress: string;
  readonly intent: ProductSubmitIntent;
  readonly signalName?: string;
}

export interface SubmitProductTaskInput {
  readonly prepareId: string;
  readonly signature: string;
  readonly walletAddress: string;
}

export type EvidenceVerificationStatus =
  | "unbound"
  | "matched"
  | "mismatch"
  | "missing_file";

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

export interface ProductSubmissionDTO extends TxReconcileFields {
  readonly submissionId: string;
  readonly prepareId: string;
  readonly taskId: string;
  readonly orderId: string;
  readonly onchainOrderId: ProductWriteHex;
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
  readonly evidenceIds?: readonly string[];
  readonly createdAt: string;
  readonly updatedAt: string;
}

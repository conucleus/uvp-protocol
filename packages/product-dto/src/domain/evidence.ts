/**
 * 证据读/写面 wire DTO 单源：app-backend 的 /product/evidence 响应与 uvp-client
 * 证据方法都引用本模块；服务端实现类型（principal/绑定时序）不在这里定义。
 */

import type { ProductWriteHex } from "./write-side.js";

export type EvidenceStatus =
  | "uploaded"
  | "bound"
  | "superseded"
  | "withdrawn"
  | "missing_file"
  | "mismatch";

export type EvidenceJsonValue =
  | null
  | boolean
  | number
  | string
  | readonly EvidenceJsonValue[]
  | { readonly [key: string]: EvidenceJsonValue };

export type EvidenceJsonObject = { readonly [key: string]: EvidenceJsonValue };

export interface EvidenceObjectDTO {
  readonly evidenceId: string;
  readonly orderId?: string;
  readonly draftId?: string;
  readonly taskId?: string;
  readonly stageIdentifier: string;
  readonly ownerParticipantId: string;
  readonly fileName: string;
  readonly mimeType: string;
  readonly size: number;
  readonly storageURI: string;
  readonly contentHash: ProductWriteHex;
  readonly metadataHash: ProductWriteHex;
  readonly payloadHash: ProductWriteHex;
  readonly payloadRef: string;
  readonly status: EvidenceStatus;
  readonly createdAt: string;
  readonly boundSignalTxHash?: ProductWriteHex;
  readonly boundSubmissionId?: string;
  readonly boundOnchainOrderId?: ProductWriteHex;
  readonly boundSourceId?: ProductWriteHex;
  readonly boundSignalId?: ProductWriteHex;
  readonly boundAt?: string;
}

export interface EvidenceMetadataDTO {
  readonly evidenceId: string;
  readonly businessLabel: string;
  readonly description?: string;
  readonly documentType: string;
  readonly issuer?: string;
  readonly issuedAt?: string;
  readonly fields: EvidenceJsonObject;
  readonly redactionPolicy?: EvidenceJsonValue;
}

export interface EvidenceAccessPolicyDTO {
  readonly evidenceId: string;
  readonly orderId?: string;
  readonly readers: readonly string[];
  readonly writers: readonly string[];
  readonly adminReaders: readonly string[];
  readonly adjudicatorReaders: readonly string[];
}

export type EvidenceContentDTO =
  | {
      readonly encoding: "text" | "base64";
      readonly value: string;
    }
  | {
      readonly encoding: "json";
      readonly value: unknown;
    };

export interface EvidenceMetadataInputDTO {
  readonly businessLabel?: string;
  readonly description?: string;
  readonly documentType?: string;
  readonly issuer?: string;
  readonly issuedAt?: string;
  readonly fields?: unknown;
  readonly redactionPolicy?: unknown;
}

export interface EvidenceAccessPolicyInputDTO {
  readonly readers?: readonly string[];
  readonly writers?: readonly string[];
  readonly adminReaders?: readonly string[];
  readonly adjudicatorReaders?: readonly string[];
}

export interface CreateEvidenceRequestDTO {
  readonly orderId?: string;
  readonly draftId?: string;
  readonly taskId?: string;
  readonly stageIdentifier?: string;
  readonly ownerParticipantId?: string;
  readonly fileName?: string;
  readonly mimeType?: string;
  readonly documentType?: string;
  readonly content?: EvidenceContentDTO;
  readonly textPayload?: string;
  readonly base64Payload?: string;
  readonly jsonPayload?: unknown;
  readonly metadata?: EvidenceMetadataInputDTO;
  readonly accessPolicy?: EvidenceAccessPolicyInputDTO;
}

export interface EvidenceRecordDTO {
  readonly evidence: EvidenceObjectDTO;
  readonly metadata: EvidenceMetadataDTO;
  readonly accessPolicy: EvidenceAccessPolicyDTO;
}

export interface EvidenceUploadResponseDTO extends EvidenceRecordDTO {
  readonly payloadHash: ProductWriteHex;
  readonly payloadRef: string;
}

/**
 * V1 订单要求包与 fileResource 句柄 DTO 单源：只描述“要什么、文件在哪里”，
 * requirementsHash 由服务端计算，客户端不得自算自报。
 */

import type { ProductResourceVisibility } from "./index.js";

export const FILE_RESOURCE_TYPES = [
  "http",
  "txcloud",
  "local",
  "plain_text",
] as const;
export type FileResourceType = (typeof FILE_RESOURCE_TYPES)[number];

export const ORDER_REQUIREMENTS_SCHEMA_VERSION = "uvp.order-requirements.v1";
export type OrderRequirementsSchemaVersion =
  typeof ORDER_REQUIREMENTS_SCHEMA_VERSION;

export interface HttpFileLocatorDTO {
  readonly url: string;
}

export interface TxCloudFileLocatorDTO {
  readonly bucket: string;
  readonly region: string;
  readonly objectKey: string;
}

export interface LocalFileLocatorDTO {
  readonly path: string;
}

export interface PlainTextFileLocatorDTO {
  readonly ref: string;
}

export interface FileResourceLocatorDTO {
  readonly httpFile?: HttpFileLocatorDTO;
  readonly txCloudFile?: TxCloudFileLocatorDTO;
  readonly localFile?: LocalFileLocatorDTO;
  readonly plainText?: PlainTextFileLocatorDTO;
}

export interface FileResourceCipherDTO {
  readonly alg: string;
  readonly keyRef: string;
}

export interface FileResourceHandleDTO {
  readonly key: string;
  readonly fileType: FileResourceType;
  readonly locator: FileResourceLocatorDTO;
  readonly contentHash?: string;
  readonly cipherHash?: string;
  readonly visibility?: ProductResourceVisibility;
  readonly policyRef?: string;
  readonly cipher?: FileResourceCipherDTO;
  readonly metadata?: unknown;
}

export interface OrderRequirementPresetRefDTO {
  readonly name: string;
  readonly version: string;
  readonly hash: string;
  readonly ref?: string;
}

export interface OrderRequirementDTO {
  readonly key: string;
  readonly stageId?: string;
  readonly label?: string;
  readonly dueAt?: string;
  readonly handles: readonly FileResourceHandleDTO[];
  readonly presetRef?: OrderRequirementPresetRefDTO;
}

export interface OrderRequirementsDeclarationDTO {
  readonly schemaVersion: OrderRequirementsSchemaVersion;
  readonly requirements: readonly OrderRequirementDTO[];
  readonly presets: readonly OrderRequirementPresetRefDTO[];
}

export function orderRequirementsConsentMessage(
  draftId: string,
  requirementsHash: string,
): string {
  return [
    "UVP order requirements consent v1",
    `Draft: ${draftId}`,
    `Requirements Hash: ${requirementsHash}`,
  ].join("\n");
}

export interface OrderRequirementsConsentDTO {
  readonly walletAddress: string;
  readonly requirementsHash: string;
  readonly signature: string;
  readonly signedAt: string;
}

export interface OrderRequirementsBundleDTO
  extends OrderRequirementsDeclarationDTO {
  readonly declaredBy: string;
  readonly requirementsHash: string;
  readonly consents?: readonly OrderRequirementsConsentDTO[];
}

export interface OrderRequirementsTriggerAnchorDTO {
  readonly draftId: string;
  readonly schemaVersion: OrderRequirementsSchemaVersion;
  readonly requirementsHash: string;
  readonly declaredBy: string;
  readonly consentedWallets: readonly string[];
}

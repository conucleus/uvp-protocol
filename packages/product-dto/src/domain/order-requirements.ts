// V1 订单要求包与 fileResource 句柄 DTO 单源：只描述“要什么、文件在哪里”，
// 正文/密钥/凭据/解析都在引擎外；requirementsHash 由服务端按 canonical JSON
// 对 declaration 计算，客户端与前端不得自算或自报。相对方合意消息也在本
// 模块单源导出。句柄类型闭集与 DSL fileResources 的 fileType 同集
// （local/http/txcloud/plain_text），V1 不加新类型。

import type { ProductResourceVisibility } from "./index.js";

/** fileResource 句柄类型的协议闭集；V1 不新增类型。 */
export const FILE_RESOURCE_TYPES = [
  "http",
  "txcloud",
  "local",
  "plain_text",
] as const;
export type FileResourceType = (typeof FILE_RESOURCE_TYPES)[number];

/** 订单要求包 schema 版本（generic，与行业无关）。 */
export const ORDER_REQUIREMENTS_SCHEMA_VERSION = "uvp.order-requirements.v1";
export type OrderRequirementsSchemaVersion =
  typeof ORDER_REQUIREMENTS_SCHEMA_VERSION;

/** http 句柄定位：URL 指向链下正文，正文不进句柄。 */
export interface HttpFileLocatorDTO {
  readonly url: string;
}

/** txcloud 句柄定位：对象存储坐标，凭据由 resolver 侧按 principal 持有。 */
export interface TxCloudFileLocatorDTO {
  readonly bucket: string;
  readonly region: string;
  readonly objectKey: string;
}

/** local 句柄定位：本机/执行方路径，仅 fixture 与本地执行使用。 */
export interface LocalFileLocatorDTO {
  readonly path: string;
}

/**
 * plain_text 句柄定位：只引用本地 fixture 的内容引用（ref），
 * 正文永不进句柄；生产文档不使用该类型。
 */
export interface PlainTextFileLocatorDTO {
  readonly ref: string;
}

/**
 * 类型专属 locator：键由 fileType 决定（httpFile/txCloudFile/localFile/
 * plainText），同一句柄只允许出现与 fileType 匹配的那一个键。
 */
export interface FileResourceLocatorDTO {
  readonly httpFile?: HttpFileLocatorDTO;
  readonly txCloudFile?: TxCloudFileLocatorDTO;
  readonly localFile?: LocalFileLocatorDTO;
  readonly plainText?: PlainTextFileLocatorDTO;
}

/** 加密参数：只放算法与密钥引用（keyRef），密钥本身永不进句柄。 */
export interface FileResourceCipherDTO {
  readonly alg: string;
  readonly keyRef: string;
}

/**
 * fileResource 句柄：可解析的资源引用，不是完成判据。
 * 禁止出现密钥、存储凭据、会话 token、私钥与正文；metadata 为不透明 JSON，
 * 由应用解释，引擎/服务端不解析其内容。
 */
export interface FileResourceHandleDTO {
  /** 订单内唯一的句柄名；要求包内所有句柄共用同一命名空间。 */
  readonly key: string;
  readonly fileType: FileResourceType;
  readonly locator: FileResourceLocatorDTO;
  /** 解析后字节的摘要（未加密时）；0x 前缀 32 字节。 */
  readonly contentHash?: string;
  /** 密文摘要（加密时至少承诺密文 hash）；0x 前缀 32 字节。 */
  readonly cipherHash?: string;
  /** 可见性；最终由 resolver 按 principal 强制（fail-closed）。 */
  readonly visibility?: ProductResourceVisibility;
  /** 访问策略引用（策略库/文档名），不是策略正文。 */
  readonly policyRef?: string;
  readonly cipher?: FileResourceCipherDTO;
  /** 不透明 JSON；应用解释，引擎不解析。 */
  readonly metadata?: unknown;
}

/** 预设引用（B2）：只登记 {name, version, hash, ref}，内容由应用/凝结核提供。 */
export interface OrderRequirementPresetRefDTO {
  readonly name: string;
  readonly version: string;
  readonly hash: string;
  readonly ref?: string;
}

/** 一条订单要求：句柄集合与/或预设引用，可绑定环节与时限。 */
export interface OrderRequirementDTO {
  readonly key: string;
  readonly stageId?: string;
  readonly label?: string;
  /** ISO 8601 时限（按环节或整体）。 */
  readonly dueAt?: string;
  readonly handles: readonly FileResourceHandleDTO[];
  readonly presetRef?: OrderRequirementPresetRefDTO;
}

/** 开单人声明的部分：服务端只对这三项算 requirementsHash。 */
export interface OrderRequirementsDeclarationDTO {
  readonly schemaVersion: OrderRequirementsSchemaVersion;
  readonly requirements: readonly OrderRequirementDTO[];
  readonly presets: readonly OrderRequirementPresetRefDTO[];
}

/**
 * 相对方合意消息（单源）：签名覆盖 draftId + requirementsHash，服务端校验
 * 与客户端签名必须逐字一致，客户端不得自行拼接消息格式。
 */
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

/** 相对方合意：对同一 requirementsHash 的签名证明（服务端校验后落审计）。 */
export interface OrderRequirementsConsentDTO {
  readonly walletAddress: string;
  readonly requirementsHash: string;
  readonly signature: string;
  readonly signedAt: string;
}

/**
 * 订单要求包（读面）：declaration + 服务端字段。
 * declaredBy/requirementsHash 由服务端派生，客户端提交时不得携带。
 */
export interface OrderRequirementsBundleDTO
  extends OrderRequirementsDeclarationDTO {
  readonly declaredBy: string;
  readonly requirementsHash: string;
  readonly consents?: readonly OrderRequirementsConsentDTO[];
}

/**
 * 触发锚：V1 订单触发路径随单携带的要求包引用（draftId + hash）。
 * 链上只放该锚/hash，不放句柄正文。
 */
export interface OrderRequirementsTriggerAnchorDTO {
  readonly draftId: string;
  readonly schemaVersion: OrderRequirementsSchemaVersion;
  readonly requirementsHash: string;
  readonly declaredBy: string;
  readonly consentedWallets: readonly string[];
}

// UVPZhixuRegistry/1 EIP-712 domain、ZhixuRecord/IdentityClaim 字段表、
// type hash 与规范化构造单源；registry 存储/HTTP/Postgres 不进入本包。

import { isAddress, keccak256, toHex, type Address, type Hex } from "viem";

export const ZHIXU_REGISTRY_DOMAIN_NAME = "UVPZhixuRegistry";
export const ZHIXU_REGISTRY_DOMAIN_VERSION = "1";

export const ZHIXU_RECORD_PRIMARY_TYPE = "ZhixuRecord";
export const IDENTITY_CLAIM_PRIMARY_TYPE = "IdentityClaim";

export interface ZhixuRegistryTypedDataField {
  readonly name: string;
  readonly type: string;
}

export const ZHIXU_RECORD_TYPED_DATA_FIELDS: readonly ZhixuRegistryTypedDataField[] = [
  { name: "chainId", type: "uint256" },
  { name: "planId", type: "bytes32" },
  { name: "planHash", type: "bytes32" },
  { name: "descriptorUri", type: "string" },
  { name: "descriptorHash", type: "string" },
  { name: "schemaHash", type: "string" },
  { name: "version", type: "string" },
  { name: "registeredBy", type: "address" },
];

export const IDENTITY_CLAIM_TYPED_DATA_FIELDS: readonly ZhixuRegistryTypedDataField[] = [
  { name: "chainId", type: "uint256" },
  { name: "wallet", type: "address" },
  { name: "subject", type: "string" },
  { name: "descriptorUri", type: "string" },
  { name: "descriptorHash", type: "string" },
  { name: "attestationRefs", type: "string[]" },
];

function encodeType(primaryType: string, fields: readonly ZhixuRegistryTypedDataField[]): string {
  return `${primaryType}(${fields.map((field) => `${field.type} ${field.name}`).join(",")})`;
}

/** EIP-712 type hash = keccak256(encodeType(primaryType))。 */
export const ZHIXU_RECORD_TYPE_HASH: Hex = keccak256(
  toHex(encodeType(ZHIXU_RECORD_PRIMARY_TYPE, ZHIXU_RECORD_TYPED_DATA_FIELDS)),
);
export const IDENTITY_CLAIM_TYPE_HASH: Hex = keccak256(
  toHex(encodeType(IDENTITY_CLAIM_PRIMARY_TYPE, IDENTITY_CLAIM_TYPED_DATA_FIELDS)),
);

export interface ZhixuRegistryDomain {
  readonly name: typeof ZHIXU_REGISTRY_DOMAIN_NAME;
  readonly version: typeof ZHIXU_REGISTRY_DOMAIN_VERSION;
  readonly chainId: number;
}

export interface ZhixuRecordTypedDataInput {
  readonly chainId: number;
  readonly planId: string;
  readonly planHash: string;
  readonly descriptorUri?: string;
  readonly descriptorHash?: string;
  readonly schemaHash?: string;
  readonly version?: string;
  readonly registeredBy: string;
}

export interface IdentityClaimTypedDataInput {
  readonly chainId: number;
  readonly wallet: string;
  readonly subject: string;
  readonly descriptorUri?: string;
  readonly descriptorHash?: string;
  readonly attestationRefs?: readonly string[];
}

export interface NormalizedZhixuRecordTypedDataInput {
  readonly chainId: number;
  readonly planId: Hex;
  readonly planHash: Hex;
  readonly descriptorUri?: string;
  readonly descriptorHash?: string;
  readonly schemaHash?: string;
  readonly version?: string;
  readonly registeredBy: Address;
}

export interface NormalizedIdentityClaimTypedDataInput {
  readonly chainId: number;
  readonly wallet: Address;
  readonly subject: string;
  readonly descriptorUri?: string;
  readonly descriptorHash?: string;
  readonly attestationRefs: readonly string[];
}

export interface ZhixuRecordMessage extends Record<string, unknown> {
  readonly chainId: bigint;
  readonly planId: Hex;
  readonly planHash: Hex;
  readonly descriptorUri: string;
  readonly descriptorHash: string;
  readonly schemaHash: string;
  readonly version: string;
  readonly registeredBy: Address;
}

export interface IdentityClaimMessage extends Record<string, unknown> {
  readonly chainId: bigint;
  readonly wallet: Address;
  readonly subject: string;
  readonly descriptorUri: string;
  readonly descriptorHash: string;
  readonly attestationRefs: readonly string[];
}

export interface ZhixuRecordTypedData {
  readonly domain: ZhixuRegistryDomain;
  readonly types: {
    readonly ZhixuRecord: readonly ZhixuRegistryTypedDataField[];
  };
  readonly primaryType: typeof ZHIXU_RECORD_PRIMARY_TYPE;
  readonly message: ZhixuRecordMessage;
}

export interface IdentityClaimTypedData {
  readonly domain: ZhixuRegistryDomain;
  readonly types: {
    readonly IdentityClaim: readonly ZhixuRegistryTypedDataField[];
  };
  readonly primaryType: typeof IDENTITY_CLAIM_PRIMARY_TYPE;
  readonly message: IdentityClaimMessage;
}

const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;

export function buildZhixuRegistryDomain(chainId: number): ZhixuRegistryDomain {
  return {
    name: ZHIXU_REGISTRY_DOMAIN_NAME,
    version: ZHIXU_REGISTRY_DOMAIN_VERSION,
    chainId: requireChainId(chainId),
  };
}

export function buildZhixuRecordTypedData(input: ZhixuRecordTypedDataInput): ZhixuRecordTypedData {
  const fields = normalizeZhixuRecordTypedDataInput(input);
  return {
    domain: buildZhixuRegistryDomain(fields.chainId),
    types: { ZhixuRecord: ZHIXU_RECORD_TYPED_DATA_FIELDS },
    primaryType: ZHIXU_RECORD_PRIMARY_TYPE,
    message: {
      chainId: BigInt(fields.chainId),
      planId: fields.planId,
      planHash: fields.planHash,
      descriptorUri: fields.descriptorUri ?? "",
      descriptorHash: fields.descriptorHash ?? "",
      schemaHash: fields.schemaHash ?? "",
      version: fields.version ?? "",
      registeredBy: fields.registeredBy,
    },
  };
}

export function buildIdentityClaimTypedData(input: IdentityClaimTypedDataInput): IdentityClaimTypedData {
  const fields = normalizeIdentityClaimTypedDataInput(input);
  return {
    domain: buildZhixuRegistryDomain(fields.chainId),
    types: { IdentityClaim: IDENTITY_CLAIM_TYPED_DATA_FIELDS },
    primaryType: IDENTITY_CLAIM_PRIMARY_TYPE,
    message: {
      chainId: BigInt(fields.chainId),
      wallet: fields.wallet,
      subject: fields.subject,
      descriptorUri: fields.descriptorUri ?? "",
      descriptorHash: fields.descriptorHash ?? "",
      attestationRefs: fields.attestationRefs,
    },
  };
}

export function normalizeZhixuRecordTypedDataInput(
  input: ZhixuRecordTypedDataInput,
): NormalizedZhixuRecordTypedDataInput {
  const key = normalizeZhixuRecordTypedDataKey(input);
  const descriptorUri = optionalText(input.descriptorUri, "descriptorUri");
  const descriptorHash = optionalText(input.descriptorHash, "descriptorHash");
  const schemaHash = optionalText(input.schemaHash, "schemaHash");
  const version = optionalText(input.version, "version");
  return {
    ...key,
    registeredBy: requireAddress(input.registeredBy, "registeredBy"),
    ...(descriptorUri !== undefined ? { descriptorUri } : {}),
    ...(descriptorHash !== undefined ? { descriptorHash } : {}),
    ...(schemaHash !== undefined ? { schemaHash } : {}),
    ...(version !== undefined ? { version } : {}),
  };
}

export function normalizeIdentityClaimTypedDataInput(
  input: IdentityClaimTypedDataInput,
): NormalizedIdentityClaimTypedDataInput {
  const key = normalizeIdentityClaimTypedDataKey(input);
  const descriptorUri = optionalText(input.descriptorUri, "descriptorUri");
  const descriptorHash = optionalText(input.descriptorHash, "descriptorHash");
  return {
    ...key,
    ...(descriptorUri !== undefined ? { descriptorUri } : {}),
    ...(descriptorHash !== undefined ? { descriptorHash } : {}),
    attestationRefs: normalizeAttestationRefs(input.attestationRefs),
  };
}

export function normalizeZhixuRecordTypedDataKey(key: {
  readonly chainId: number;
  readonly planId: string;
  readonly planHash: string;
}): { readonly chainId: number; readonly planId: Hex; readonly planHash: Hex } {
  return {
    chainId: requireChainId(key.chainId),
    planId: requireBytes32(key.planId, "planId"),
    planHash: requireBytes32(key.planHash, "planHash"),
  };
}

export function normalizeIdentityClaimTypedDataKey(key: {
  readonly chainId: number;
  readonly wallet: string;
  readonly subject: string;
}): { readonly chainId: number; readonly wallet: Address; readonly subject: string } {
  return {
    chainId: requireChainId(key.chainId),
    wallet: requireAddress(key.wallet, "wallet"),
    subject: requireSubject(key.subject),
  };
}

function requireChainId(value: number): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new TypeError("chainId must be a positive safe integer");
  }
  return value;
}

function requireBytes32(value: string, field: string): Hex {
  if (typeof value !== "string" || !BYTES32_RE.test(value)) {
    throw new TypeError(`${field} must be a 32-byte hex value`);
  }
  return value.toLowerCase() as Hex;
}

function requireAddress(value: string, field: string): Address {
  if (typeof value !== "string" || !isAddress(value, { strict: false })) {
    throw new TypeError(`${field} must be an EVM address`);
  }
  return value.toLowerCase() as Address;
}

function requireSubject(value: string): string {
  if (typeof value !== "string") {
    throw new TypeError("subject must be a self-described string");
  }
  const subject = value.trim();
  if (subject.length === 0) {
    throw new TypeError("subject must be a non-empty self-described string");
  }
  return subject;
}

function optionalText(value: string | undefined, field: string): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "string") {
    throw new TypeError(`${field} must be a string when present`);
  }
  const text = value.trim();
  return text.length > 0 ? text : undefined;
}

function normalizeAttestationRefs(value: readonly string[] | undefined): readonly string[] {
  if (value === undefined) {
    return [];
  }
  if (!Array.isArray(value)) {
    throw new TypeError("attestationRefs must be an array of opaque refs");
  }
  return value.map((ref, index) => {
    if (typeof ref !== "string" || ref.trim().length === 0) {
      throw new TypeError(`attestationRefs[${index}] must be a non-empty opaque ref`);
    }
    return ref.trim();
  });
}

// UVPZhixuRegistry/1 EIP-712 domain、ZhixuRecord 字段表、
// type hash 与规范化构造单源；registry 存储/HTTP/Postgres 不进入本包。

import { isAddress, keccak256, toHex, type Address, type Hex } from "viem";

export const ZHIXU_REGISTRY_DOMAIN_NAME = "UVPZhixuRegistry";
export const ZHIXU_REGISTRY_DOMAIN_VERSION = "1";

export const ZHIXU_RECORD_PRIMARY_TYPE = "ZhixuRecord";

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

function encodeType(primaryType: string, fields: readonly ZhixuRegistryTypedDataField[]): string {
  return `${primaryType}(${fields.map((field) => `${field.type} ${field.name}`).join(",")})`;
}

/** EIP-712 type hash = keccak256(encodeType(primaryType))。 */
export const ZHIXU_RECORD_TYPE_HASH: Hex = keccak256(
  toHex(encodeType(ZHIXU_RECORD_PRIMARY_TYPE, ZHIXU_RECORD_TYPED_DATA_FIELDS)),
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

export interface ZhixuRecordTypedData {
  readonly domain: ZhixuRegistryDomain;
  readonly types: {
    readonly ZhixuRecord: readonly ZhixuRegistryTypedDataField[];
  };
  readonly primaryType: typeof ZHIXU_RECORD_PRIMARY_TYPE;
  readonly message: ZhixuRecordMessage;
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

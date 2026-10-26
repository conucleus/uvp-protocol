// UVP 订单簿（UVPOrderBook/1）EIP-712 域与通用订单消息：
// UVPStageInviteAccept（slot 接受绑定本 stage 条款）与 UVPOrderFinalize。
// 这里只放通用域常量、字段表、type hash 与规范化构造/校验。

import { getAddress, isAddress, isHex, keccak256, toHex, type Address, type Hex } from "viem";

export const UVP_ORDER_BOOK_DOMAIN_NAME = "UVPOrderBook";
export const UVP_ORDER_BOOK_DOMAIN_VERSION = "1";

export const UVP_STAGE_INVITE_ACCEPT_PRIMARY_TYPE = "UVPStageInviteAccept";
export const UVP_ORDER_FINALIZE_PRIMARY_TYPE = "UVPOrderFinalize";

export interface OrderBookTypedDataField {
  readonly name: string;
  readonly type: string;
}

export const UVP_STAGE_INVITE_ACCEPT_TYPED_DATA_FIELDS: readonly OrderBookTypedDataField[] = [
  { name: "draftId", type: "string" },
  { name: "inviteId", type: "string" },
  { name: "stageKey", type: "string" },
  { name: "stageId", type: "bytes32" },
  { name: "slotKey", type: "string" },
  { name: "invitee", type: "address" },
  { name: "amount", type: "uint256" },
  { name: "finalStandardHash", type: "bytes32" },
  { name: "workDeadline", type: "uint256" },
  { name: "termsHash", type: "bytes32" },
  { name: "nonce", type: "uint256" },
  { name: "deadline", type: "uint256" },
];

export const UVP_ORDER_FINALIZE_TYPED_DATA_FIELDS: readonly OrderBookTypedDataField[] = [
  { name: "draftId", type: "string" },
  { name: "planId", type: "bytes32" },
  { name: "configId", type: "string" },
  { name: "configVersion", type: "string" },
  { name: "configHash", type: "bytes32" },
  { name: "buyer", type: "address" },
  { name: "termsHash", type: "bytes32" },
  { name: "nonce", type: "uint256" },
  { name: "deadline", type: "uint256" },
];

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as Address;
const BYTES32_RE = /^0x[a-fA-F0-9]{64}$/;

function encodeType(
  primaryType: string,
  fields: readonly OrderBookTypedDataField[],
): string {
  return `${primaryType}(${fields.map((field) => `${field.type} ${field.name}`).join(",")})`;
}

/** EIP-712 type hash = keccak256(encodeType(primaryType))。 */
export const UVP_STAGE_INVITE_ACCEPT_TYPE_HASH: Hex = keccak256(
  toHex(encodeType(UVP_STAGE_INVITE_ACCEPT_PRIMARY_TYPE, UVP_STAGE_INVITE_ACCEPT_TYPED_DATA_FIELDS)),
);
export const UVP_ORDER_FINALIZE_TYPE_HASH: Hex = keccak256(
  toHex(encodeType(UVP_ORDER_FINALIZE_PRIMARY_TYPE, UVP_ORDER_FINALIZE_TYPED_DATA_FIELDS)),
);
export interface OrderBookDomain {
  readonly name: typeof UVP_ORDER_BOOK_DOMAIN_NAME;
  readonly version: typeof UVP_ORDER_BOOK_DOMAIN_VERSION;
  readonly chainId: number;
  readonly verifyingContract: Address;
}

export function buildOrderBookDomain(input: {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
}): OrderBookDomain {
  return {
    name: UVP_ORDER_BOOK_DOMAIN_NAME,
    version: UVP_ORDER_BOOK_DOMAIN_VERSION,
    chainId: normalizeChainId(input.chainId),
    verifyingContract: normalizeAddress(input.verifyingContract, "verifyingContract"),
  };
}

export interface UVPStageInviteAcceptTypedData {
  readonly domain: OrderBookDomain;
  readonly types: {
    readonly UVPStageInviteAccept: readonly OrderBookTypedDataField[];
  };
  readonly primaryType: typeof UVP_STAGE_INVITE_ACCEPT_PRIMARY_TYPE;
  readonly message: {
    readonly draftId: string;
    readonly inviteId: string;
    readonly stageKey: string;
    readonly stageId: Hex;
    readonly slotKey: string;
    readonly invitee: Address;
    readonly amount: string;
    readonly finalStandardHash: Hex;
    readonly workDeadline: string;
    readonly termsHash: Hex;
    readonly nonce: string;
    readonly deadline: string;
  };
}

export interface BuildUVPStageInviteAcceptTypedDataInput {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
  readonly draftId: string;
  readonly inviteId: string;
  readonly stageKey: string;
  readonly stageId: Hex | string;
  readonly slotKey: string;
  readonly invitee: Address | string;
  readonly amount: bigint | number | string;
  readonly finalStandardHash: Hex | string;
  readonly workDeadline: bigint | number | string;
  readonly termsHash: Hex | string;
  readonly nonce: bigint | number | string;
  readonly deadline: bigint | number | string;
}

export function buildUVPStageInviteAcceptTypedData(
  input: BuildUVPStageInviteAcceptTypedDataInput,
): UVPStageInviteAcceptTypedData {
  return {
    domain: buildOrderBookDomain(input),
    types: { UVPStageInviteAccept: UVP_STAGE_INVITE_ACCEPT_TYPED_DATA_FIELDS },
    primaryType: UVP_STAGE_INVITE_ACCEPT_PRIMARY_TYPE,
    message: {
      draftId: normalizeNonEmptyString(input.draftId, "draftId"),
      inviteId: normalizeNonEmptyString(input.inviteId, "inviteId"),
      stageKey: normalizeNonEmptyString(input.stageKey, "stageKey"),
      stageId: normalizeBytes32(input.stageId, "stageId"),
      slotKey: normalizeNonEmptyString(input.slotKey, "slotKey"),
      invitee: normalizeAddress(input.invitee, "invitee"),
      amount: normalizeUintString(input.amount, "amount"),
      finalStandardHash: normalizeBytes32(input.finalStandardHash, "finalStandardHash"),
      workDeadline: normalizeUintString(input.workDeadline, "workDeadline"),
      termsHash: normalizeBytes32(input.termsHash, "termsHash"),
      nonce: normalizeUintString(input.nonce, "nonce"),
      deadline: normalizeUintString(input.deadline, "deadline"),
    },
  };
}

/**
 * 结构化校验两份 typed data：域四要素、primaryType、字段表与消息字段
 * 类型全部一致才返回；任何字段漂移都显式失败（禁止盲签）。
 */
export function validateUVPStageInviteAcceptTypedData(
  value: unknown,
): UVPStageInviteAcceptTypedData {
  const record = requireRecord(value, "UVPStageInviteAccept");
  const domain = requireOrderBookDomain(record.domain);
  const primaryType = requireString(record.primaryType, "primaryType");
  if (primaryType !== UVP_STAGE_INVITE_ACCEPT_PRIMARY_TYPE) {
    throw new Error(`primaryType must be ${UVP_STAGE_INVITE_ACCEPT_PRIMARY_TYPE}`);
  }
  const types = requireRecord(record.types, "types");
  const fields = types[UVP_STAGE_INVITE_ACCEPT_PRIMARY_TYPE];
  if (!Array.isArray(fields)) {
    throw new Error(`types.${UVP_STAGE_INVITE_ACCEPT_PRIMARY_TYPE} must be an array`);
  }
  const expected = UVP_STAGE_INVITE_ACCEPT_TYPED_DATA_FIELDS;
  if (fields.length !== expected.length) {
    throw new Error("UVPStageInviteAccept field list does not match the canonical type");
  }
  for (let index = 0; index < expected.length; index += 1) {
    const field = requireRecord(fields[index], `types.UVPStageInviteAccept[${index}]`);
    if (field.name !== expected[index]!.name || field.type !== expected[index]!.type) {
      throw new Error(`UVPStageInviteAccept field ${index} does not match the canonical type`);
    }
  }
  const message = requireRecord(record.message, "message");
  return {
    domain,
    types: { UVPStageInviteAccept: expected },
    primaryType: UVP_STAGE_INVITE_ACCEPT_PRIMARY_TYPE,
    message: {
      draftId: requireString(message.draftId, "draftId"),
      inviteId: requireString(message.inviteId, "inviteId"),
      stageKey: requireString(message.stageKey, "stageKey"),
      stageId: normalizeBytes32(requireString(message.stageId, "stageId"), "stageId"),
      slotKey: requireString(message.slotKey, "slotKey"),
      invitee: normalizeAddress(requireString(message.invitee, "invitee"), "invitee"),
      amount: normalizeUintString(requireString(message.amount, "amount"), "amount"),
      finalStandardHash: normalizeBytes32(
        requireString(message.finalStandardHash, "finalStandardHash"),
        "finalStandardHash",
      ),
      workDeadline: normalizeUintString(
        requireString(message.workDeadline, "workDeadline"),
        "workDeadline",
      ),
      termsHash: normalizeBytes32(requireString(message.termsHash, "termsHash"), "termsHash"),
      nonce: normalizeUintString(requireString(message.nonce, "nonce"), "nonce"),
      deadline: normalizeUintString(requireString(message.deadline, "deadline"), "deadline"),
    },
  };
}

export interface UVPOrderFinalizeTypedData {
  readonly domain: OrderBookDomain;
  readonly types: {
    readonly UVPOrderFinalize: readonly OrderBookTypedDataField[];
  };
  readonly primaryType: typeof UVP_ORDER_FINALIZE_PRIMARY_TYPE;
  readonly message: {
    readonly draftId: string;
    readonly planId: Hex;
    readonly configId: string;
    readonly configVersion: string;
    readonly configHash: Hex;
    readonly buyer: Address;
    readonly termsHash: Hex;
    readonly nonce: string;
    readonly deadline: string;
  };
}

export interface BuildUVPOrderFinalizeTypedDataInput {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
  readonly draftId: string;
  readonly planId: Hex | string;
  readonly configId: string;
  readonly configVersion: string;
  readonly configHash: Hex | string;
  readonly buyer: Address | string;
  readonly termsHash: Hex | string;
  readonly nonce: bigint | number | string;
  readonly deadline: bigint | number | string;
}

export function buildUVPOrderFinalizeTypedData(
  input: BuildUVPOrderFinalizeTypedDataInput,
): UVPOrderFinalizeTypedData {
  return {
    domain: buildOrderBookDomain(input),
    types: { UVPOrderFinalize: UVP_ORDER_FINALIZE_TYPED_DATA_FIELDS },
    primaryType: UVP_ORDER_FINALIZE_PRIMARY_TYPE,
    message: {
      draftId: normalizeNonEmptyString(input.draftId, "draftId"),
      planId: normalizeBytes32(input.planId, "planId"),
      configId: normalizeNonEmptyString(input.configId, "configId"),
      configVersion: normalizeNonEmptyString(input.configVersion, "configVersion"),
      configHash: normalizeBytes32(input.configHash, "configHash"),
      buyer: normalizeAddress(input.buyer, "buyer"),
      termsHash: normalizeBytes32(input.termsHash, "termsHash"),
      nonce: normalizeUintString(input.nonce, "nonce"),
      deadline: normalizeUintString(input.deadline, "deadline"),
    },
  };
}

export function validateUVPOrderFinalizeTypedData(value: unknown): UVPOrderFinalizeTypedData {
  const record = requireRecord(value, "UVPOrderFinalize");
  const domain = requireOrderBookDomain(record.domain);
  const primaryType = requireString(record.primaryType, "primaryType");
  if (primaryType !== UVP_ORDER_FINALIZE_PRIMARY_TYPE) {
    throw new Error(`primaryType must be ${UVP_ORDER_FINALIZE_PRIMARY_TYPE}`);
  }
  const types = requireRecord(record.types, "types");
  const fields = types[UVP_ORDER_FINALIZE_PRIMARY_TYPE];
  if (!Array.isArray(fields)) {
    throw new Error(`types.${UVP_ORDER_FINALIZE_PRIMARY_TYPE} must be an array`);
  }
  const expected = UVP_ORDER_FINALIZE_TYPED_DATA_FIELDS;
  if (fields.length !== expected.length) {
    throw new Error("UVPOrderFinalize field list does not match the canonical type");
  }
  for (let index = 0; index < expected.length; index += 1) {
    const field = requireRecord(fields[index], `types.UVPOrderFinalize[${index}]`);
    if (field.name !== expected[index]!.name || field.type !== expected[index]!.type) {
      throw new Error(`UVPOrderFinalize field ${index} does not match the canonical type`);
    }
  }
  const message = requireRecord(record.message, "message");
  return {
    domain,
    types: { UVPOrderFinalize: expected },
    primaryType: UVP_ORDER_FINALIZE_PRIMARY_TYPE,
    message: {
      draftId: requireString(message.draftId, "draftId"),
      planId: normalizeBytes32(requireString(message.planId, "planId"), "planId"),
      configId: requireString(message.configId, "configId"),
      configVersion: requireString(message.configVersion, "configVersion"),
      configHash: normalizeBytes32(requireString(message.configHash, "configHash"), "configHash"),
      buyer: normalizeAddress(requireString(message.buyer, "buyer"), "buyer"),
      termsHash: normalizeBytes32(requireString(message.termsHash, "termsHash"), "termsHash"),
      nonce: normalizeUintString(requireString(message.nonce, "nonce"), "nonce"),
      deadline: normalizeUintString(requireString(message.deadline, "deadline"), "deadline"),
    },
  };
}

function requireOrderBookDomain(value: unknown): OrderBookDomain {
  const record = requireRecord(value, "domain");
  const name = requireString(record.name, "domain.name");
  const version = requireString(record.version, "domain.version");
  if (name !== UVP_ORDER_BOOK_DOMAIN_NAME || version !== UVP_ORDER_BOOK_DOMAIN_VERSION) {
    throw new Error(
      `domain must be ${UVP_ORDER_BOOK_DOMAIN_NAME}/${UVP_ORDER_BOOK_DOMAIN_VERSION}, received ${name}/${version}`,
    );
  }
  const chainId = record.chainId;
  if (typeof chainId !== "number" || !Number.isSafeInteger(chainId) || chainId <= 0) {
    throw new Error("domain.chainId must be a positive safe integer");
  }
  return {
    name: UVP_ORDER_BOOK_DOMAIN_NAME,
    version: UVP_ORDER_BOOK_DOMAIN_VERSION,
    chainId,
    verifyingContract: normalizeAddress(requireString(record.verifyingContract, "domain.verifyingContract"), "domain.verifyingContract"),
  };
}

function requireRecord(value: unknown, fieldName: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${fieldName} must be an object`);
  }
  return value as Record<string, unknown>;
}

function requireString(value: unknown, fieldName: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${fieldName} must be a non-empty string`);
  }
  return value;
}

function normalizeNonEmptyString(value: string, fieldName: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${fieldName} must be a non-empty string`);
  }
  return value;
}

function normalizeAddress(value: Address | string, fieldName: string): Address {
  if (typeof value !== "string" || !isAddress(value, { strict: false })) {
    throw new Error(`${fieldName} must be a valid EVM address`);
  }
  return getAddress(value);
}

function normalizeBytes32(value: Hex | string, fieldName: string): Hex {
  if (typeof value !== "string" || !isHex(value) || !BYTES32_RE.test(value)) {
    throw new Error(`${fieldName} must be a 32-byte hex value`);
  }
  return value as Hex;
}

function normalizeUintString(
  value: bigint | number | string,
  fieldName: string,
): string {
  if (typeof value === "bigint") {
    if (value < 0n) {
      throw new Error(`${fieldName} must be a non-negative integer`);
    }
    return value.toString(10);
  }
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new Error(`${fieldName} must be a non-negative safe integer`);
    }
    return value.toString(10);
  }
  if (!/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error(`${fieldName} must be a base-10 non-negative integer string`);
  }
  return value;
}

function normalizeChainId(value: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) {
    throw new Error("chainId must be a positive safe integer");
  }
  return value;
}

export const ORDER_BOOK_ZERO_ADDRESS = ZERO_ADDRESS;

export const UVP_STAGE_INVITE_CREATE_PRIMARY_TYPE = "UVPStageInviteCreate";

// 开单人邀请授权：buyer 在应用后端铸造 invite 之前签署的条款（不含 inviteId/token，
// 二者由后端在验签后生成）；字段词表与 accept 保持一致，去掉 accept 才有的 inviteId。
export const UVP_STAGE_INVITE_CREATE_TYPED_DATA_FIELDS: readonly OrderBookTypedDataField[] = [
  { name: "draftId", type: "string" },
  { name: "stageKey", type: "string" },
  { name: "stageId", type: "bytes32" },
  { name: "slotKey", type: "string" },
  { name: "invitee", type: "address" },
  { name: "amount", type: "uint256" },
  { name: "finalStandardHash", type: "bytes32" },
  { name: "workDeadline", type: "uint256" },
  { name: "termsHash", type: "bytes32" },
  { name: "nonce", type: "uint256" },
  { name: "deadline", type: "uint256" },
];

export const UVP_STAGE_INVITE_CREATE_TYPE_HASH: Hex = keccak256(
  toHex(encodeType(UVP_STAGE_INVITE_CREATE_PRIMARY_TYPE, UVP_STAGE_INVITE_CREATE_TYPED_DATA_FIELDS)),
);

export interface UVPStageInviteCreateTypedData {
  readonly domain: OrderBookDomain;
  readonly types: {
    readonly UVPStageInviteCreate: readonly OrderBookTypedDataField[];
  };
  readonly primaryType: typeof UVP_STAGE_INVITE_CREATE_PRIMARY_TYPE;
  readonly message: {
    readonly draftId: string;
    readonly stageKey: string;
    readonly stageId: Hex;
    readonly slotKey: string;
    readonly invitee: Address;
    readonly amount: string;
    readonly finalStandardHash: Hex;
    readonly workDeadline: string;
    readonly termsHash: Hex;
    readonly nonce: string;
    readonly deadline: string;
  };
}

export interface BuildUVPStageInviteCreateTypedDataInput {
  readonly chainId: number;
  readonly verifyingContract: Address | string;
  readonly draftId: string;
  readonly stageKey: string;
  readonly stageId: Hex | string;
  readonly slotKey: string;
  readonly invitee: Address | string;
  readonly amount: bigint | number | string;
  readonly finalStandardHash: Hex | string;
  readonly workDeadline: bigint | number | string;
  readonly termsHash: Hex | string;
  readonly nonce: bigint | number | string;
  readonly deadline: bigint | number | string;
}

export function buildUVPStageInviteCreateTypedData(
  input: BuildUVPStageInviteCreateTypedDataInput,
): UVPStageInviteCreateTypedData {
  return {
    domain: buildOrderBookDomain(input),
    types: { UVPStageInviteCreate: UVP_STAGE_INVITE_CREATE_TYPED_DATA_FIELDS },
    primaryType: UVP_STAGE_INVITE_CREATE_PRIMARY_TYPE,
    message: {
      draftId: normalizeNonEmptyString(input.draftId, "draftId"),
      stageKey: normalizeNonEmptyString(input.stageKey, "stageKey"),
      stageId: normalizeBytes32(input.stageId, "stageId"),
      slotKey: normalizeNonEmptyString(input.slotKey, "slotKey"),
      invitee: normalizeAddress(input.invitee, "invitee"),
      amount: normalizeUintString(input.amount, "amount"),
      finalStandardHash: normalizeBytes32(input.finalStandardHash, "finalStandardHash"),
      workDeadline: normalizeUintString(input.workDeadline, "workDeadline"),
      termsHash: normalizeBytes32(input.termsHash, "termsHash"),
      nonce: normalizeUintString(input.nonce, "nonce"),
      deadline: normalizeUintString(input.deadline, "deadline"),
    },
  };
}

export function validateUVPStageInviteCreateTypedData(
  value: unknown,
): UVPStageInviteCreateTypedData {
  const record = requireRecord(value, "UVPStageInviteCreate");
  const domain = requireOrderBookDomain(record.domain);
  const primaryType = requireString(record.primaryType, "primaryType");
  if (primaryType !== UVP_STAGE_INVITE_CREATE_PRIMARY_TYPE) {
    throw new Error(`primaryType must be ${UVP_STAGE_INVITE_CREATE_PRIMARY_TYPE}`);
  }
  const types = requireRecord(record.types, "types");
  const fields = types[UVP_STAGE_INVITE_CREATE_PRIMARY_TYPE];
  if (!Array.isArray(fields)) {
    throw new Error(`types.${UVP_STAGE_INVITE_CREATE_PRIMARY_TYPE} must be an array`);
  }
  const expected = UVP_STAGE_INVITE_CREATE_TYPED_DATA_FIELDS;
  if (fields.length !== expected.length) {
    throw new Error("UVPStageInviteCreate field list does not match the canonical type");
  }
  for (let index = 0; index < expected.length; index += 1) {
    const field = requireRecord(fields[index], `types.UVPStageInviteCreate[${index}]`);
    if (field.name !== expected[index]!.name || field.type !== expected[index]!.type) {
      throw new Error(`UVPStageInviteCreate field ${index} does not match the canonical type`);
    }
  }
  const message = requireRecord(record.message, "message");
  return {
    domain,
    types: { UVPStageInviteCreate: expected },
    primaryType: UVP_STAGE_INVITE_CREATE_PRIMARY_TYPE,
    message: {
      draftId: requireString(message.draftId, "draftId"),
      stageKey: requireString(message.stageKey, "stageKey"),
      stageId: normalizeBytes32(requireString(message.stageId, "stageId"), "stageId"),
      slotKey: requireString(message.slotKey, "slotKey"),
      invitee: normalizeAddress(requireString(message.invitee, "invitee"), "invitee"),
      amount: normalizeUintString(requireString(message.amount, "amount"), "amount"),
      finalStandardHash: normalizeBytes32(
        requireString(message.finalStandardHash, "finalStandardHash"),
        "finalStandardHash",
      ),
      workDeadline: normalizeUintString(requireString(message.workDeadline, "workDeadline"), "workDeadline"),
      termsHash: normalizeBytes32(requireString(message.termsHash, "termsHash"), "termsHash"),
      nonce: normalizeUintString(requireString(message.nonce, "nonce"), "nonce"),
      deadline: normalizeUintString(requireString(message.deadline, "deadline"), "deadline"),
    },
  };
}

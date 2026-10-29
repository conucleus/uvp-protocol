// UVPAppBackend/1 写动作域：draft/invite/attach/evidence 的业务签名 schema。
// 与订单簿 UVPOrderBook/1 分开；字段表/typehash/构造只在这里定义，禁止各端复制。

import { getAddress, isAddress, keccak256, toHex, type Address, type Hex } from "viem";
import { hashCanonicalJson } from "@uvp-eth/canonical-json";
import type { OrderBookTypedDataField } from "./order-book.js";
import { encodeTypedDataFields } from "./order-book.js";

export const UVP_APP_BACKEND_DOMAIN_NAME = "UVPAppBackend";
export const UVP_APP_BACKEND_DOMAIN_VERSION = "1";

export const UVP_APP_WRITE_ACTIONS = [
  "draft.create",
  "draft.update",
  "invite.revoke",
  "invite.reject",
  "order.attach",
  "evidence.upload",
  "joint.child_order",
  "joint.child_settle",
] as const;

export type UvpAppWriteAction = (typeof UVP_APP_WRITE_ACTIONS)[number];

export const UVP_APP_WRITE_PRIMARY_TYPES = {
  "draft.create": "UVPDraftCreate",
  "draft.update": "UVPDraftUpdate",
  "invite.revoke": "UVPInviteRevoke",
  "invite.reject": "UVPInviteReject",
  "order.attach": "UVPAttachOrder",
  "evidence.upload": "UVPEvidenceUpload",
  "joint.child_order": "UVPJointChildOrder",
  "joint.child_settle": "UVPJointChildSettle",
} as const satisfies Record<UvpAppWriteAction, string>;

export type UvpAppWritePrimaryType =
  (typeof UVP_APP_WRITE_PRIMARY_TYPES)[UvpAppWriteAction];

const FIELD_TABLES: Record<UvpAppWriteAction, readonly OrderBookTypedDataField[]> = {
  "draft.create": [
    { name: "draftId", type: "string" },
    { name: "configId", type: "string" },
    { name: "configVersion", type: "string" },
    { name: "configHash", type: "bytes32" },
    { name: "bodyHash", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  "draft.update": [
    { name: "draftId", type: "string" },
    { name: "bodyHash", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  "invite.revoke": [
    { name: "inviteId", type: "string" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  "invite.reject": [
    { name: "inviteId", type: "string" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  "order.attach": [
    { name: "draftId", type: "string" },
    { name: "orderId", type: "bytes32" },
    { name: "planId", type: "bytes32" },
    { name: "bodyHash", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  "evidence.upload": [
    { name: "orderId", type: "bytes32" },
    { name: "draftId", type: "string" },
    { name: "documentType", type: "string" },
    { name: "contentHash", type: "bytes32" },
    { name: "bodyHash", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  "joint.child_order": [
    { name: "parentPlanId", type: "bytes32" },
    { name: "parentOrderId", type: "bytes32" },
    { name: "parentStageKey", type: "string" },
    { name: "childPlanId", type: "bytes32" },
    { name: "creator", type: "address" },
    { name: "bodyHash", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  "joint.child_settle": [
    { name: "parentPlanId", type: "bytes32" },
    { name: "parentOrderId", type: "bytes32" },
    { name: "parentStageKey", type: "string" },
    { name: "childPlanId", type: "bytes32" },
    { name: "creator", type: "address" },
    { name: "jointRef", type: "bytes32" },
    { name: "bodyHash", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
};

export const UVP_APP_WRITE_FIELDS = FIELD_TABLES;

export const UVP_APP_WRITE_TYPE_HASHES = {
  "draft.create": typeHashFor("draft.create"),
  "draft.update": typeHashFor("draft.update"),
  "invite.revoke": typeHashFor("invite.revoke"),
  "invite.reject": typeHashFor("invite.reject"),
  "order.attach": typeHashFor("order.attach"),
  "evidence.upload": typeHashFor("evidence.upload"),
  "joint.child_order": typeHashFor("joint.child_order"),
  "joint.child_settle": typeHashFor("joint.child_settle"),
} as const satisfies Record<UvpAppWriteAction, Hex>;

export const UVP_APP_WRITE_RESOURCE_FIELDS = {
  "draft.create": "draftId",
  "draft.update": "draftId",
  "invite.revoke": "inviteId",
  "invite.reject": "inviteId",
  "order.attach": "draftId",
  "evidence.upload": undefined,
  "joint.child_order": "parentOrderId",
  "joint.child_settle": "parentOrderId",
} as const satisfies Record<UvpAppWriteAction, string | undefined>;

export interface UvpAppBackendDomain {
  readonly name: typeof UVP_APP_BACKEND_DOMAIN_NAME;
  readonly version: typeof UVP_APP_BACKEND_DOMAIN_VERSION;
  readonly chainId: number;
}

export interface UvpAppWriteTypedData {
  readonly domain: UvpAppBackendDomain;
  readonly types: Readonly<Record<string, readonly OrderBookTypedDataField[]>>;
  readonly primaryType: string;
  readonly message: Readonly<Record<string, string>>;
}

export interface BuildUVPAppWriteTypedDataInput {
  readonly action: UvpAppWriteAction;
  readonly chainId: number;
  readonly message: Readonly<Record<string, unknown>>;
}

export function buildUVPAppBackendDomain(input: { readonly chainId: number }): UvpAppBackendDomain {
  return {
    name: UVP_APP_BACKEND_DOMAIN_NAME,
    version: UVP_APP_BACKEND_DOMAIN_VERSION,
    chainId: normalizeChainId(input.chainId),
  };
}

export function buildUVPAppWriteTypedData(
  input: BuildUVPAppWriteTypedDataInput,
): UvpAppWriteTypedData {
  const fields = FIELD_TABLES[input.action];
  if (fields === undefined) {
    throw new Error(`unknown UVPAppBackend action: ${String(input.action)}`);
  }
  const primaryType = UVP_APP_WRITE_PRIMARY_TYPES[input.action];
  const message: Record<string, string> = {};
  for (const field of fields) {
    message[field.name] = normalizeField(field, input.message[field.name], input.action);
  }
  return {
    domain: buildUVPAppBackendDomain(input),
    types: { [primaryType]: fields },
    primaryType,
    message,
  };
}

export function hashAppWritePayload(payload: unknown): Hex {
  return hashCanonicalJson(payload);
}

function typeHashFor(action: UvpAppWriteAction): Hex {
  return keccak256(toHex(encodeTypedDataFields(UVP_APP_WRITE_PRIMARY_TYPES[action], FIELD_TABLES[action])));
}

function normalizeChainId(value: number): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error("chainId must be a positive safe integer");
  }
  return value;
}

function normalizeField(
  field: OrderBookTypedDataField,
  value: unknown,
  action: UvpAppWriteAction,
): string {
  const path = `${action}.${field.name}`;
  if (typeof value === "string") {
    const text = value.trim();
    if (field.type === "string") {
      return text;
    }
    if (text.length === 0) {
      throw new Error(`${path} must be a ${field.type}`);
    }
    if (field.type === "address") {
      if (!isAddress(text, { strict: false })) {
        throw new Error(`${path} must be a valid address`);
      }
      return getAddress(text);
    }
    if (field.type === "bytes32") {
      if (!/^0x[0-9a-fA-F]{64}$/u.test(text)) {
        throw new Error(`${path} must be a 32-byte hex value`);
      }
      return text.toLowerCase();
    }
    if (field.type === "uint256") {
      if (!/^[0-9]+$/u.test(text)) {
        throw new Error(`${path} must be a decimal uint256`);
      }
      return text;
    }
  }
  if (typeof value === "bigint" && field.type === "uint256" && value >= 0n) {
    return value.toString();
  }
  if (typeof value === "number" && field.type === "uint256" && Number.isSafeInteger(value) && value >= 0) {
    return String(value);
  }
  throw new Error(`${path} must be a ${field.type}`);
}


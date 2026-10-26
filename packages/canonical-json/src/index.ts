/**
 * 规范化 JSON 与 evidence hash 单源：code-point 键序、整数词表（float/-0/
 * 超 2^53 整数响亮拒绝）与 keccak256 哈希。Rust 权威语料见
 * uvp-core/fixtures/canonical/canonical.v1.json。
 */

import { keccak256, stringToHex, toHex, type Hex } from "viem";

export type CanonicalJsonValue =
  | null
  | boolean
  | number
  | string
  | readonly CanonicalJsonValue[]
  | { readonly [key: string]: CanonicalJsonValue };

export function canonicalize(value: unknown, path = "$"): CanonicalJsonValue {
  if (value === null) {
    return null;
  }

  const valueType = typeof value;
  if (valueType === "string" || valueType === "boolean") {
    return value as string | boolean;
  }

  if (valueType === "number") {
    if (!Number.isFinite(value)) {
      throw new TypeError(`${path} must be a finite JSON number`);
    }
    if (!Number.isInteger(value) || Object.is(value, -0)) {
      const token = Object.is(value, -0) ? "-0" : String(value);
      throw new TypeError(
        `${path} must be an integer: canonical JSON hash preimages reject float-form numbers, received ${token}`,
      );
    }
    if (!Number.isSafeInteger(value)) {
      throw new TypeError(
        `${path} must be a safe integer: canonical JSON hash preimages reject integers beyond 2^53-1 (JS numbers lose precision and stringify to exponential form past 1e21; carry large integers as strings or hex words), received ${value}`,
      );
    }
    return value as number;
  }

  if (Array.isArray(value)) {
    return value.map((item, index) => canonicalize(item, `${path}[${index}]`));
  }

  if (valueType === "object") {
    const record = value as Record<string, unknown>;
    const sorted: Record<string, CanonicalJsonValue> = {};
    for (const key of Object.keys(record).sort(compareByCodePoint)) {
      const child = record[key];
      if (typeof child === "undefined") {
        throw new TypeError(`${path}.${key} must not be undefined`);
      }
      sorted[key] = canonicalize(child, `${path}.${key}`);
    }
    return sorted;
  }

  throw new TypeError(`${path} contains unsupported JSON value: ${valueType}`);
}

export function compareByCodePoint(left: string, right: string): number {
  const leftPoints = Array.from(left);
  const rightPoints = Array.from(right);
  const length = Math.min(leftPoints.length, rightPoints.length);
  for (let index = 0; index < length; index += 1) {
    const comparison =
      (leftPoints[index] as string).codePointAt(0)! - (rightPoints[index] as string).codePointAt(0)!;
    if (comparison !== 0) {
      return comparison;
    }
  }
  return leftPoints.length - rightPoints.length;
}

export function canonicalJson(value: unknown): string {
  return writeCanonical(canonicalize(value));
}

/** canonical JSON 的 keccak256（无域前缀；域分离由调用方的 preimage 负责）。 */
export function hashCanonicalJson(value: unknown): Hex {
  return keccak256(stringToHex(canonicalJson(value)));
}

export interface EvidenceHashResult {
  readonly algorithm: "keccak256";
  readonly evidenceHash: Hex;
  readonly byteLength: number;
  readonly source: "bytes" | "json" | "text";
}

export function hashEvidenceBytes(bytes: Uint8Array): EvidenceHashResult {
  return {
    algorithm: "keccak256",
    evidenceHash: keccak256(toHex(bytes)),
    byteLength: bytes.byteLength,
    source: "bytes",
  };
}

export function hashEvidenceText(text: string): EvidenceHashResult {
  return {
    algorithm: "keccak256",
    evidenceHash: keccak256(stringToHex(text)),
    byteLength: new TextEncoder().encode(text).byteLength,
    source: "text",
  };
}

export function hashEvidenceJson(value: unknown): EvidenceHashResult {
  const canonical = canonicalJson(value);
  return {
    algorithm: "keccak256",
    evidenceHash: keccak256(stringToHex(canonical)),
    byteLength: new TextEncoder().encode(canonical).byteLength,
    source: "json",
  };
}

function writeCanonicalNumber(value: number): string {
  return JSON.stringify(value);
}

function writeCanonical(node: CanonicalJsonValue): string {
  if (node === null) {
    return "null";
  }
  if (typeof node === "boolean") {
    return node ? "true" : "false";
  }
  if (typeof node === "number") {
    return writeCanonicalNumber(node);
  }
  if (typeof node === "string") {
    return JSON.stringify(node);
  }
  if (Array.isArray(node)) {
    return `[${node.map((item) => writeCanonical(item)).join(",")}]`;
  }
  const entries = Object.entries(node)
    .sort(([left], [right]) => compareByCodePoint(left, right))
    .map(([key, child]) => `${JSON.stringify(key)}:${writeCanonical(child)}`);
  return `{${entries.join(",")}}`;
}

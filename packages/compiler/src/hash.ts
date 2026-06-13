import { canonicalStringify } from "./canonical.js";
import type { HexString } from "./types/index.js";
import { keccak256, stringToBytes } from "viem";

export function keccak256Hex(data: Uint8Array | string): HexString {
  return keccak256(typeof data === "string" ? stringToBytes(data) : data) as HexString;
}

export function hashCanonical(domain: string, payload: unknown): HexString {
  return keccak256Hex(`${domain}:${canonicalStringify(payload)}`);
}

import { canonicalize, canonicalJson } from "@uvp-eth/canonical-json";
import { keccak256Hex } from "./hash.js";
import type { HexString } from "./types/index.js";

/**
 * Zhixu 定义身份：uid 由去掉展示字段（metadata.name/annotations）后的规范化内容
 * 派生；链轨参考实现与 Rust uvp-ir 的 uid cell 对拍。
 */

export const DEFINITION_UID_DOMAIN = "uvp:definition-uid:v2";
export const DOCK_UID_DOMAIN = "uvp:dock-uid:v1";

export interface DockIdentity {
  readonly dkid: string;
  readonly docHash: HexString;
}

export function definitionUid(definition: unknown): string {
  const digest = keccak256Hex(
    `${DEFINITION_UID_DOMAIN}:${canonicalJson(stripDisplayFields(definition))}`,
  );
  return `zx-${digest.slice(2, 2 + 32)}`;
}

export function dockIdentity(dock: unknown): DockIdentity {
  const docHash = keccak256Hex(
    `${DOCK_UID_DOMAIN}:${canonicalJson(stripDisplayFields(dock))}`,
  );
  return { dkid: `zd-${docHash.slice(2, 2 + 32)}`, docHash };
}

export function stripDisplayFields(definition: unknown): unknown {
  const node = canonicalize(definition);
  if (node === null || typeof node !== "object" || Array.isArray(node)) {
    return node;
  }
  const record = node as Record<string, unknown>;
  const metadata = record.metadata;
  if (metadata === null || typeof metadata !== "object" || Array.isArray(metadata)) {
    return node;
  }
  const { name: _name, annotations: _annotations, ...rest } = metadata as Record<string, unknown>;
  void _name;
  void _annotations;
  return { ...record, metadata: rest };
}

export function stripAnnotations(definition: unknown): unknown {
  const node = canonicalize(definition);
  if (node === null || typeof node !== "object" || Array.isArray(node)) {
    return node;
  }
  const record = node as Record<string, unknown>;
  const metadata = record.metadata;
  if (metadata === null || typeof metadata !== "object" || Array.isArray(metadata)) {
    return node;
  }
  const { annotations: _annotations, ...rest } = metadata as Record<string, unknown>;
  void _annotations;
  return { ...record, metadata: rest };
}

export function displayIdentity(name: string, uid: string): string {
  const hex = uid.startsWith("zx-") ? uid.slice(3) : uid;
  return `${name}(${hex.slice(0, 8)})`;
}

import { canonicalize, canonicalJson } from "@uvp-eth/canonical-json";
import { keccak256Hex } from "./hash.js";
import type { HexString } from "./types/index.js";

/**
 * Zhixu 定义身份：uid 由去掉展示字段（metadata.name/annotations/labels）与轨道
 * 选择器（spec.platform/nucleation）后的规范化逻辑内容派生；Dock 身份只去掉展示
 * 字段（metadata.name/annotations），labels 参与 Dock 内容。链轨参考实现与
 * Rust uvp-ir 的 uid cell 对拍。
 */

export const DEFINITION_UID_DOMAIN = "uvp:definition-uid:v2";
export const DOCK_UID_DOMAIN = "uvp:dock-uid:v1";

export interface DockIdentity {
  readonly dkid: string;
  readonly docHash: HexString;
}

export function definitionUid(definition: unknown): string {
  const digest = keccak256Hex(
    `${DEFINITION_UID_DOMAIN}:${canonicalJson(stripDefinitionIdentityFields(definition))}`,
  );
  return `zx-${digest.slice(2, 2 + 32)}`;
}

export function dockIdentity(dock: unknown): DockIdentity {
  const docHash = keccak256Hex(
    `${DOCK_UID_DOMAIN}:${canonicalJson(stripDisplayFields(dock))}`,
  );
  return { dkid: `zd-${docHash.slice(2, 2 + 32)}`, docHash };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function stripDefinitionIdentityFields(definition: unknown): unknown {
  const node = canonicalize(definition);
  if (!isRecord(node)) {
    return node;
  }
  let stripped = node;
  if (isRecord(stripped.metadata)) {
    const {
      name: _name,
      annotations: _annotations,
      labels: _labels,
      ...metadata
    } = stripped.metadata;
    void _name;
    void _annotations;
    void _labels;
    stripped = { ...stripped, metadata };
  }
  if (isRecord(stripped.spec)) {
    const {
      platform: _platform,
      nucleation: _nucleation,
      ...spec
    } = stripped.spec;
    void _platform;
    void _nucleation;
    stripped = { ...stripped, spec };
  }
  return stripped;
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

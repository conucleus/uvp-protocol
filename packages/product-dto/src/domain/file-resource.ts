/**
 * fileResource 句柄单源：type 是唯一固定必填字段，其余字段由 type 自己定义；
 * 句柄校验、canonical keccak handleKey 与读面 wire DTO 只在这里定义，
 * app-backend / uvp-client 编译期引用，不自持副本。
 */

import { canonicalize, canonicalJson, hashCanonicalJson } from "@uvp-eth/canonical-json";

export const FILE_RESOURCE_TYPE_MAX_LENGTH = 64;
export const FILE_RESOURCE_MAX_CANONICAL_BYTES = 4096;

export type ConfigFileResourceRef = { readonly type: string } & Readonly<Record<string, unknown>>;

export type FileResourceHandleErrorReason =
  | "not_object"
  | "type_missing"
  | "type_not_string"
  | "type_empty"
  | "type_too_long"
  | "not_canonical_json"
  | "too_large";

export class FileResourceHandleError extends Error {
  override readonly name = "FileResourceHandleError";

  constructor(
    readonly path: string,
    readonly reason: FileResourceHandleErrorReason,
    message: string,
  ) {
    super(`${path}: ${message}`);
  }
}

export interface HandleView {
  readonly handleKey: string;
  readonly type: string;
  readonly fields: Readonly<Record<string, unknown>>;
}

export type ResourceResolutionView =
  | { readonly kind: "inline"; readonly text: string }
  | { readonly kind: "link"; readonly url: string }
  | { readonly kind: "app_evidence"; readonly ref: string; readonly contentHash?: string }
  | {
      readonly kind: "external";
      readonly type: string;
      readonly handle: Readonly<Record<string, unknown>>;
    };

export function normalizeFileResourceHandle(input: unknown, path = "$"): ConfigFileResourceRef {
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    throw new FileResourceHandleError(path, "not_object", "file resource handle must be a JSON object");
  }
  const record = input as Readonly<Record<string, unknown>>;
  const type = record.type;
  if (type === undefined) {
    throw new FileResourceHandleError(path, "type_missing", "file resource handle requires a type");
  }
  if (typeof type !== "string") {
    throw new FileResourceHandleError(path, "type_not_string", "file resource handle type must be a string");
  }
  if (type.length === 0) {
    throw new FileResourceHandleError(path, "type_empty", "file resource handle type must not be empty");
  }
  if (Array.from(type).length > FILE_RESOURCE_TYPE_MAX_LENGTH) {
    throw new FileResourceHandleError(
      path,
      "type_too_long",
      `file resource handle type must be at most ${FILE_RESOURCE_TYPE_MAX_LENGTH} characters`,
    );
  }
  let canonical: string;
  try {
    canonical = canonicalJson(record);
  } catch (error) {
    throw new FileResourceHandleError(
      path,
      "not_canonical_json",
      `file resource handle must be canonical JSON: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
  if (new TextEncoder().encode(canonical).byteLength > FILE_RESOURCE_MAX_CANONICAL_BYTES) {
    throw new FileResourceHandleError(
      path,
      "too_large",
      `file resource handle must not exceed ${FILE_RESOURCE_MAX_CANONICAL_BYTES} canonical JSON bytes; providers must publish a short id instead`,
    );
  }
  return canonicalize(record) as ConfigFileResourceRef;
}

export function fileResourceHandleKey(handle: ConfigFileResourceRef): string {
  return hashCanonicalJson(normalizeFileResourceHandle(handle, "handle"));
}

export function fileResourceHandleView(handle: ConfigFileResourceRef, path = "$"): HandleView {
  const normalized = normalizeFileResourceHandle(handle, path);
  const { type, ...fields } = normalized;
  return { handleKey: hashCanonicalJson(normalized), type, fields };
}

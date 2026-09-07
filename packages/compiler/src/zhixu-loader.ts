import { readFile } from "node:fs/promises";
import { extname } from "node:path";
import YAML from "yaml";
import type { ZhixuDefinition } from "./types/index.js";

export class ZhixuLoadError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ZhixuLoadError";
  }
}

export async function loadZhixuDefinition(filePath: string): Promise<ZhixuDefinition> {
  const raw = await readFile(filePath, "utf8");
  return parseZhixuDefinition(raw, filePath);
}

export function parseZhixuDefinition(raw: string, sourceName = "zhixu"): ZhixuDefinition {
  const parsed = parseStructuredText(raw, sourceName);
  assertZhixuDefinitionShape(parsed, sourceName);
  return parsed;
}

function parseStructuredText(raw: string, sourceName: string): unknown {
  const extension = extname(sourceName).toLowerCase();
  try {
    if (extension === ".json") {
      return JSON.parse(raw) as unknown;
    }
    return YAML.parse(raw) as unknown;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new ZhixuLoadError(`failed to parse ${sourceName}: ${message}`);
  }
}

/** PRD_102 N7：name 是作者技术标签，slug 形态（字节 ≤100）。 */
const NAME_SLUG_PATTERN = /^[a-z][a-z0-9_-]{0,99}$/;

function assertZhixuDefinitionShape(
  value: unknown,
  sourceName: string
): asserts value is ZhixuDefinition {
  if (!isRecord(value)) {
    throw new ZhixuLoadError(`${sourceName} must contain an object`);
  }
  if (value.apiVersion !== "uvp/v0") {
    throw new ZhixuLoadError(`${sourceName}.apiVersion must be uvp/v0`);
  }
  if (value.kind !== "Zhixu") {
    throw new ZhixuLoadError(`${sourceName}.kind must be Zhixu`);
  }
  if (!isRecord(value.metadata) || typeof value.metadata.name !== "string") {
    throw new ZhixuLoadError(`${sourceName}.metadata.name is required`);
  }
  // PRD_102 N2：uid 由系统从定义内容派生（zx-<32hex>），不是作者可写字段。
  // 出现即按未知字段响亮拒绝——与 Rust serde deny_unknown_fields 的
  // "unknown field `uid`" 路径同口径，不存在"写了就用/不写就兜底"分支。
  if ("uid" in value.metadata) {
    throw new ZhixuLoadError(
      `${sourceName}.metadata.uid: unknown field \`uid\` — the definition identity is derived from content (zx-<32hex>), never authored`,
    );
  }
  const name = value.metadata.name;
  if (
    !NAME_SLUG_PATTERN.test(name) ||
    Buffer.byteLength(name, "utf8") > 100
  ) {
    throw new ZhixuLoadError(
      `${sourceName}.metadata.name must match ^[a-z][a-z0-9_-]{0,99}$ (definition-local technical label)`,
    );
  }
  if (!isRecord(value.spec) || !Array.isArray(value.spec.taskPatterns)) {
    throw new ZhixuLoadError(`${sourceName}.spec.taskPatterns must be an array`);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

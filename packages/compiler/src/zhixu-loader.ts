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
  if (!isRecord(value.spec) || !Array.isArray(value.spec.taskPatterns)) {
    throw new ZhixuLoadError(`${sourceName}.spec.taskPatterns must be an array`);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

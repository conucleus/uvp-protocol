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

const NAME_SLUG_PATTERN = /^[a-z][a-z0-9_-]{0,99}$/;

export const KNOWN_FIELDS = {
  root: ["apiVersion", "kind", "metadata", "spec"],
  metadata: ["name", "labels", "annotations"],
  spec: ["platform", "nucleation", "stages", "dockInterface"],
  platform: ["type", "provider", "network", "version", "params"],
  nucleation: ["id", "params"],
  stage: [
    "name",
    "source",
    "mint",
    "executor",
    "selectedStages",
    "sendSignals",
    "receiveSignals",
    "fileResources",
  ],
  sendSignalEntry: ["name", "validWhen"],
  executor: ["supplierType", "supplierID", "zhixuExecutorConfig", "selectableResource"],
  dockInterfaceEntry: ["orderModes", "inputs", "outputs"],
  dockInputPort: ["hook"],
  dockOutputPort: ["signal"],
} as const satisfies Record<string, readonly string[]>;

function rejectUnknownFields(
  value: Record<string, unknown>,
  knownKey: keyof typeof KNOWN_FIELDS,
  path: string,
  sourceName: string
): void {
  const known: readonly string[] = KNOWN_FIELDS[knownKey];
  for (const key of Object.keys(value)) {
    if (!known.includes(key)) {
      throw new ZhixuLoadError(
        `${sourceName}.${path}: unknown field \`${key}\` — accepted fields are ${known.join(", ")}`,
      );
    }
  }
}

function assertStringValues(
  value: unknown,
  path: string,
  sourceName: string
): void {
  if (value === undefined) {
    return;
  }
  if (!isRecord(value)) {
    throw new ZhixuLoadError(`${sourceName}.${path} must be an object of string values`);
  }
  for (const [key, entry] of Object.entries(value)) {
    if (typeof entry !== "string") {
      throw new ZhixuLoadError(`${sourceName}.${path}.${key} must be a string (quote the value)`);
    }
  }
}

function assertZhixuDefinitionShape(
  value: unknown,
  sourceName: string
): asserts value is ZhixuDefinition {
  if (!isRecord(value)) {
    throw new ZhixuLoadError(`${sourceName} must contain an object`);
  }
  rejectUnknownFields(value, "root", "", sourceName);
  if (value.apiVersion !== "uvp/v0") {
    throw new ZhixuLoadError(`${sourceName}.apiVersion must be uvp/v0`);
  }
  if (value.kind !== "Zhixu") {
    throw new ZhixuLoadError(`${sourceName}.kind must be Zhixu`);
  }
  if (!isRecord(value.metadata) || typeof value.metadata.name !== "string") {
    throw new ZhixuLoadError(`${sourceName}.metadata.name is required`);
  }
  if ("uid" in value.metadata) {
    throw new ZhixuLoadError(
      `${sourceName}.metadata.uid: unknown field \`uid\` — the definition identity is derived from content (zx-<32hex>), never authored`,
    );
  }
  rejectUnknownFields(value.metadata, "metadata", "metadata", sourceName);
  assertStringValues(value.metadata.labels, "metadata.labels", sourceName);
  assertStringValues(value.metadata.annotations, "metadata.annotations", sourceName);
  const name = value.metadata.name;
  if (
    !NAME_SLUG_PATTERN.test(name) ||
    Buffer.byteLength(name, "utf8") > 100
  ) {
    throw new ZhixuLoadError(
      `${sourceName}.metadata.name must match ^[a-z][a-z0-9_-]{0,99}$ (definition-local technical label)`,
    );
  }
  if (!isRecord(value.spec) || !Array.isArray(value.spec.stages)) {
    throw new ZhixuLoadError(`${sourceName}.spec.stages must be an array`);
  }
  rejectUnknownFields(value.spec, "spec", "spec", sourceName);
  if (isRecord(value.spec.platform)) {
    rejectUnknownFields(
      value.spec.platform,
      "platform",
      "spec.platform",
      sourceName,
    );
    assertStringValues(value.spec.platform.params, "spec.platform.params", sourceName);
  }
  if (isRecord(value.spec.nucleation)) {
    rejectUnknownFields(
      value.spec.nucleation,
      "nucleation",
      "spec.nucleation",
      sourceName,
    );
    assertStringValues(value.spec.nucleation.params, "spec.nucleation.params", sourceName);
  }
  value.spec.stages.forEach((stage: unknown, stageIndex: number) => {
    const stagePath = `spec.stages[${stageIndex}]`;
    if (!isRecord(stage)) {
      throw new ZhixuLoadError(`${sourceName}.${stagePath} must be an object`);
    }
    rejectUnknownFields(stage, "stage", stagePath, sourceName);
    assertStringValues(
      stage.receiveSignals,
      `${stagePath}.receiveSignals`,
      sourceName,
    );
    if (stage.sendSignals !== undefined) {
      if (!Array.isArray(stage.sendSignals)) {
        throw new ZhixuLoadError(`${sourceName}.${stagePath}.sendSignals must be an array`);
      }
      stage.sendSignals.forEach((declared: unknown, signalIndex: number) => {
        const entryPath = `${stagePath}.sendSignals[${signalIndex}]`;
        if (!isRecord(declared)) {
          throw new ZhixuLoadError(
            `${sourceName}.${entryPath} must be an object {name, validWhen?} (bare string entries are not accepted)`,
          );
        }
        rejectUnknownFields(declared, "sendSignalEntry", entryPath, sourceName);
        if (typeof declared.name !== "string") {
          throw new ZhixuLoadError(`${sourceName}.${entryPath}.name must be a string`);
        }
        if (declared.validWhen !== undefined) {
          if (
            !Array.isArray(declared.validWhen) ||
            declared.validWhen.length === 0 ||
            declared.validWhen.some((item: unknown) => typeof item !== "string" || item.trim() === "")
          ) {
            throw new ZhixuLoadError(
              `${sourceName}.${entryPath}.validWhen must be a non-empty array of non-empty strings (drop the key to declare unconditional admission)`,
            );
          }
        }
      });
    }
    if (isRecord(stage.executor)) {
      rejectUnknownFields(
        stage.executor,
        "executor",
        `${stagePath}.executor`,
        sourceName,
      );
    }
  });
  if (isRecord(value.spec.dockInterface)) {
    for (const [interfaceName, entry] of Object.entries(value.spec.dockInterface)) {
      if (!isRecord(entry)) {
        continue;
      }
      const interfacePath = `spec.dockInterface[${interfaceName}]`;
      rejectUnknownFields(
        entry,
        "dockInterfaceEntry",
        interfacePath,
        sourceName,
      );
      for (const [portName, port] of Object.entries(
        isRecord(entry.inputs) ? entry.inputs : {},
      )) {
        if (isRecord(port)) {
          rejectUnknownFields(
            port,
            "dockInputPort",
            `${interfacePath}.inputs[${portName}]`,
            sourceName,
          );
        }
      }
      for (const [portName, port] of Object.entries(
        isRecord(entry.outputs) ? entry.outputs : {},
      )) {
        if (isRecord(port)) {
          rejectUnknownFields(
            port,
            "dockOutputPort",
            `${interfacePath}.outputs[${portName}]`,
            sourceName,
          );
        }
      }
    }
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

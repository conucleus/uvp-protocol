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

/** name 是作者技术标签，slug 形态（字节 ≤100）。 */
const NAME_SLUG_PATTERN = /^[a-z][a-z0-9_-]{0,99}$/;

/**
 * 未知字段拒绝的层级字段集，镜像 uvp_model 的 serde deny_unknown_fields
 * （ZhixuDefinition/ObjectMeta/ZhixuSpec/ZhixuPlatform/Nucleation/
 * ZhixuTaskPattern/ZhixuStage/ZhixuExecutor/DockInterfaceSpec/端口）。
 * Value 型开放面（fileResources 条目、selectableResource、
 * zhixuExecutorConfig 的键、labels/annotations/params 的键）不在其中——
 * 它们是数据，不是结构字段。
 */
const KNOWN_FIELDS = {
  root: ["apiVersion", "kind", "metadata", "spec"],
  metadata: ["name", "labels", "annotations"],
  spec: ["platform", "nucleation", "taskPatterns", "dockInterface"],
  platform: ["type", "provider", "network", "version", "params"],
  nucleation: ["id", "params"],
  taskPattern: ["name", "stages"],
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
  // uid 由系统从定义内容派生（zx-<32hex>），不是作者可写字段：单独给锚点
  // （注册表 metadata-uid-not-an-input），先于通用未知字段拒绝。
  if ("uid" in value.metadata) {
    throw new ZhixuLoadError(
      `${sourceName}.metadata.uid: unknown field \`uid\` — the definition identity is derived from content (zx-<32hex>), never authored`,
    );
  }
  rejectUnknownFields(value.metadata, "metadata", "metadata", sourceName);
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
  rejectUnknownFields(value.spec, "spec", "spec", sourceName);
  if (isRecord(value.spec.platform)) {
    rejectUnknownFields(
      value.spec.platform,
      "platform",
      "spec.platform",
      sourceName,
    );
  }
  if (isRecord(value.spec.nucleation)) {
    rejectUnknownFields(
      value.spec.nucleation,
      "nucleation",
      "spec.nucleation",
      sourceName,
    );
  }
  value.spec.taskPatterns.forEach((pattern, patternIndex) => {
    if (!isRecord(pattern)) {
      throw new ZhixuLoadError(
        `${sourceName}.spec.taskPatterns[${patternIndex}] must be an object`,
      );
    }
    rejectUnknownFields(
      pattern,
      "taskPattern",
      `spec.taskPatterns[${patternIndex}]`,
      sourceName,
    );
    // stages 形状在本层响亮拒绝：loader 的声明契约是镜像 uvp_model 的
    // serde 形状面（typed 反序列化对缺失/非数组的 stages、非 map 的
    // stage 条目都会响亮失败），静默 return 会让残缺 pattern 携带"已过
    // loader 校验"的假象离开本层。
    if (!Array.isArray(pattern.stages)) {
      throw new ZhixuLoadError(
        `${sourceName}.spec.taskPatterns[${patternIndex}].stages must be an array`,
      );
    }
    pattern.stages.forEach((stage, stageIndex) => {
      const stagePath = `spec.taskPatterns[${patternIndex}].stages[${stageIndex}]`;
      if (!isRecord(stage)) {
        throw new ZhixuLoadError(`${sourceName}.${stagePath} must be an object`);
      }
      rejectUnknownFields(stage, "stage", stagePath, sourceName);
      if (isRecord(stage.executor)) {
        rejectUnknownFields(
          stage.executor,
          "executor",
          `${stagePath}.executor`,
          sourceName,
        );
      }
    });
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

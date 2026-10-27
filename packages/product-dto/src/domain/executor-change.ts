/**
 * 阶段执行者变更读面：executorChange 的 sourceId/signalId 只能来自编译产物
 * （compiler onchainSourceId/onchainSignalId），signalsHash 覆盖的信号集合与
 * StageExecutorChange typed data 的 SignalRef[] 同形；严格解码只在这里定义，
 * app-backend / uvp-client 编译期引用同一份校验。
 */

export interface ConfigStageExecutorChangeSignal {
  readonly sourceId: string;
  readonly signalId: string;
}

export interface ConfigStageExecutorChange {
  readonly signalsHash: string;
  readonly signals: readonly ConfigStageExecutorChangeSignal[];
}

export type ConfigStageExecutorChangeErrorReason =
  | "not_object"
  | "unknown_field"
  | "signals_hash_invalid"
  | "signals_not_array"
  | "signal_not_object"
  | "signal_unknown_field"
  | "signal_id_invalid";

export class ConfigStageExecutorChangeError extends Error {
  override readonly name = "ConfigStageExecutorChangeError";

  constructor(
    readonly path: string,
    readonly reason: ConfigStageExecutorChangeErrorReason,
    message: string,
  ) {
    super(`${path}: ${message}`);
  }
}

const HEX_32 = /^0x[0-9a-fA-F]{64}$/u;
const CHANGE_FIELDS: ReadonlySet<string> = new Set(["signalsHash", "signals"]);
const SIGNAL_FIELDS: ReadonlySet<string> = new Set(["sourceId", "signalId"]);

export function parseConfigStageExecutorChange(
  value: unknown,
  path = "executorChange",
): ConfigStageExecutorChange {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new ConfigStageExecutorChangeError(path, "not_object", "executorChange 必须是 JSON 对象");
  }
  const record = value as Record<string, unknown>;
  for (const key of Object.keys(record)) {
    if (!CHANGE_FIELDS.has(key)) {
      throw new ConfigStageExecutorChangeError(path, "unknown_field", `executorChange 含未知字段 ${key}`);
    }
  }
  const signalsHash = hex32(record.signalsHash, `${path}.signalsHash`, "signals_hash_invalid");
  if (!Array.isArray(record.signals)) {
    throw new ConfigStageExecutorChangeError(path, "signals_not_array", "executorChange.signals 必须是数组");
  }
  const signals = record.signals.map((entry, index) =>
    parseSignal(entry, `${path}.signals[${index}]`),
  );
  return { signalsHash, signals };
}

function parseSignal(value: unknown, path: string): ConfigStageExecutorChangeSignal {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new ConfigStageExecutorChangeError(
      path,
      "signal_not_object",
      "executorChange.signals[] 必须是 {sourceId, signalId} 对象",
    );
  }
  const record = value as Record<string, unknown>;
  for (const key of Object.keys(record)) {
    if (!SIGNAL_FIELDS.has(key)) {
      throw new ConfigStageExecutorChangeError(path, "signal_unknown_field", `signal 含未知字段 ${key}`);
    }
  }
  return {
    sourceId: hex32(record.sourceId, `${path}.sourceId`, "signal_id_invalid"),
    signalId: hex32(record.signalId, `${path}.signalId`, "signal_id_invalid"),
  };
}

function hex32(value: unknown, path: string, reason: ConfigStageExecutorChangeErrorReason): string {
  if (typeof value !== "string" || !HEX_32.test(value)) {
    throw new ConfigStageExecutorChangeError(path, reason, "必须是 0x + 64 位十六进制摘要");
  }
  return value.toLowerCase();
}

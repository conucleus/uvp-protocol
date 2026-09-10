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
    // 浮点拒绝：canonical 哈希输入的数字词表封闭为整数
    // （u64/i64）——Rust 权威（uvp-ir canonicalize_number）对一切 f64 载荷
    // （分数 1.5、整值浮点 100.0、指数写法 1e2、负零 -0.0）响亮拒绝，三线
    // 共用 uvp-core fixtures/canonical/canonical.v1.json 语料钉死该边界。
    // JS 数字模型无法区分 1 与源字面量 1.0（JSON.parse 即抹平），TS 侧的
    // 拒绝面是"非整数 number + 负零"；整值浮点字面量（不含 -0）的区分与
    // 拒绝只在 Rust 权威解析侧。负零 -0 在 JS 可观测（Object.is）且
    // serde_json 将 "-0"/"-0.0" 都解析为 f64 -0.0，故与权威同口径拒绝。
    if (!Number.isInteger(value) || Object.is(value, -0)) {
      // String(-0) 丢符号显示为 "0"——错误信息按肇事 token 原样列出
      // （与 Rust 权威 FloatNumber { token } 列出原始字面量同口径）。
      const token = Object.is(value, -0) ? "-0" : String(value);
      throw new TypeError(
        `${path} must be an integer: canonical JSON hash preimages reject float-form numbers, received ${token}`,
      );
    }
    // 安全整数边界：|x| ≥ 2^53 的 number 在 JS 侧已丢精度（JSON.parse 即
    // 抹平），放行会让哈希输入与任何一方的真实整值不一致；且 ≥1e21 的
    // number 经 JSON.stringify 输出指数形式（1e+21），违反"整数按十进制
    // 整型输出"。与 Rust 权威对齐响亮拒绝——大整数载荷必须以 string/hex
    // word 携带，不得走 canonical JSON 数字面量。
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
    // Code-point key order (= UTF-8 byte order), matching the Rust authority
    // (serde_json BTreeMap / str Ord). The default Array#sort compares UTF-16
    // code units, which orders astral-plane keys (surrogate pairs) BEFORE
    // high-BMP keys like U+FFFD — a different canonical byte stream for the
    // same value and therefore a different hash.
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

export function canonicalStringify(value: unknown): string {
  return writeCanonical(canonicalize(value));
}

/**
 * 数字写入器（canonical 哈希输入只剩安全整数）：
 * - 整数按十进制整型输出（Rust u64/i64 路径逐字节一致）；
 * - 一切浮点形态（含负零 -0）与安全整数范围外的整值在 canonicalize
 *   入口已拒绝，本函数不会收到它们（安全整数范围内 JSON.stringify 恒为
 *   十进制整型，无指数形式）。
 *
 * 已知 JS 不可表示分叉（记录，非实现缺口）：源字面量 100.0/1e2（整值
 * f64）在 Rust 权威侧按浮点拒绝，而 JS 数字模型无法将其与 u64 100 区分
 * （JSON.parse 即抹平），只能按整数放行——整值浮点字面量的拒绝在 Rust
 * 权威解析侧。语料（uvp-core
 * fixtures/canonical/canonical.v1.json）中依赖该区分的用例在 TS 消费侧
 * 按已知分叉显式登记。
 */
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
  const entries = Object.entries(node).map(
    ([key, child]) => `${JSON.stringify(key)}:${writeCanonical(child)}`,
  );
  return `{${entries.join(",")}}`;
}

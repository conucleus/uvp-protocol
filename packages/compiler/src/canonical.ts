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
    // -0 保留符号原样透传：Rust 权威（uvp-ir canonicalize_number）对
    // serde_json Number 不做任何改写，f64 -0.0 序列化为 "-0.0"（源字面量
    // "-0" 在 serde_json 里同样解析为 f64 -0.0）。把 -0 改写成 0 的
    // 规范化会让同一份产物在两条线上产生不同哈希。
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
 * Rust 权威（uvp-ir canonicalize_number → serde_json Number 原样透传）在
 * TS 侧的最忠实序列化（serde_json 探针实测口径）：
 * - 整数按十进制整型输出（Rust u64/i64 路径逐字节一致）；
 * - -0 输出 "-0.0"（serde_json 对 f64 -0.0 的输出；JSON.stringify 会丢符
 *   号输出 "0"，因此数字必须走本写入器而非 JSON.stringify 直通）；
 * - 其余有限 double 恒为非整值且 |x| < 2^53：JS 的最短往返十进制表示与
 *   ryu 在该区段逐字节一致（1e-5 → "0.00001"、0.000012345、
 *   1234567890123456.5 等均同）。
 *
 * 已知 JS 不可表示分叉（记录，非实现缺口）：源字面量 100.0/1e2（整值
 * f64）在 Rust 侧输出 "100.0"，而 JS 数字模型无法将其与 u64 100 区分，
 * 只能输出 "100"；|x| > 2^53 的整数在 JS 侧丢精度。整值浮点字面量因此
 * 不得进入跨线 canonical 哈希输入（Rust 产线侧应按整数发出）。
 */
function writeCanonicalNumber(value: number): string {
  if (Object.is(value, -0)) {
    return "-0.0";
  }
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

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import test from "node:test";
import { canonicalStringify } from "../src/index.js";

/**
 * Canonical-JSON 跨语言钉死语料：Rust（uvp-ir
 * canonical_stringify）是权威，语料文件 uvp-core
 * fixtures/canonical/canonical.v1.json 是三线共享的唯一出处（消费方式与
 * hook-core/statemachine 的 semantics-corpus 测试同构）。
 *
 * JS 数字模型的固有边界决定了 TS 消费侧的三条口径：
 * 1. 纯整数 token（无 '.'/'e'）且可精确表示 → 与 expectCanonical 逐字节
 *    相等（Rust u64/i64 路径）。
 * 2. 语料 input 含 JS 可见浮点（非整数 number 或负零 -0，两者经
 *    Number.isInteger/Object.is 在 JS 均可观测）→ TS canonicalize 响亮
 *    拒绝，与语料 expectReject 用例同口径（#15：浮点拒绝含负零——
 *    serde_json 把 "-0"/"-0.0" 都解析为 f64 -0.0）。
 * 3. 整值浮点 token（100.0、1e2、1e15 等）在 JSON.parse 后与整数不可
 *    区分——TS 按抹平后的整数放行，字节级区分是 JS 不可表示的分叉；
 *    |x| > 2^53 的整数 token 同理丢精度。这两类不做逐字节断言，只断言
 *    行为方向与语料一致（Rust 侧对整值浮点字面量的拒绝发生在解析边界，
 *    先于 JS 可观察面）。
 */
const corpusUrl = new URL(
  "../../../../uvp-core/fixtures/canonical/canonical.v1.json",
  import.meta.url,
);

interface RawNumber {
  readonly raw: string;
  readonly value: number;
}

interface CorpusCase {
  readonly name: string;
  readonly input: unknown;
  readonly expectCanonical?: string;
  /** 拒绝标记：语料现为字符串原因（如 "float-form JSON number"）。 */
  readonly expectReject?: string | boolean;
  readonly expectError?: string | boolean;
}

function isRawNumber(value: unknown): value is RawNumber {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    "raw" in value &&
    "value" in value
  );
}

/** 語料 input 还原为普通 JS 值（RawNumber → number）。 */
function unwrap(node: unknown): unknown {
  if (isRawNumber(node)) {
    return node.value;
  }
  if (Array.isArray(node)) {
    return node.map(unwrap);
  }
  if (typeof node === "object" && node !== null) {
    const out: Record<string, unknown> = {};
    for (const [key, child] of Object.entries(node)) {
      out[key] = unwrap(child);
    }
    return out;
  }
  return node;
}

function collectNumbers(node: unknown, into: RawNumber[] = []): RawNumber[] {
  if (isRawNumber(node)) {
    into.push(node);
  } else if (Array.isArray(node)) {
    for (const item of node) {
      collectNumbers(item, into);
    }
  } else if (typeof node === "object" && node !== null) {
    for (const child of Object.values(node)) {
      collectNumbers(child, into);
    }
  }
  return into;
}

/**
 * 保留数字原始 token 的最小 JSON 解析器：语料经 JSON.parse 后整值浮点
 * （100.0）与整数不可区分，浮点拒绝边界的对齐必须看原始 token。
 */
class RawNumberJsonParser {
  private pos = 0;
  constructor(private readonly text: string) {}

  parse(): unknown {
    this.skipWhitespace();
    const value = this.parseValue();
    this.skipWhitespace();
    if (this.pos !== this.text.length) {
      throw new SyntaxError(`unexpected trailing content at offset ${this.pos}`);
    }
    return value;
  }

  private skipWhitespace(): void {
    while (this.pos < this.text.length && /\s/.test(this.text[this.pos]!)) {
      this.pos += 1;
    }
  }

  private peek(): string {
    const ch = this.text[this.pos];
    if (ch === undefined) {
      throw new SyntaxError(`unexpected end of input at offset ${this.pos}`);
    }
    return ch;
  }

  private parseValue(): unknown {
    const ch = this.peek();
    if (ch === "{") {
      return this.parseObject();
    }
    if (ch === "[") {
      return this.parseArray();
    }
    if (ch === '"') {
      return this.parseString();
    }
    if (ch === "-" || (ch >= "0" && ch <= "9")) {
      return this.parseNumber();
    }
    for (const [literal, value] of [
      ["true", true],
      ["false", false],
      ["null", null],
    ] as const) {
      if (this.text.startsWith(literal, this.pos)) {
        this.pos += literal.length;
        return value;
      }
    }
    throw new SyntaxError(`unexpected character ${ch} at offset ${this.pos}`);
  }

  private parseObject(): Record<string, unknown> {
    this.pos += 1; // '{'
    const out: Record<string, unknown> = {};
    this.skipWhitespace();
    if (this.peek() === "}") {
      this.pos += 1;
      return out;
    }
    for (;;) {
      this.skipWhitespace();
      const key = this.parseString();
      this.skipWhitespace();
      if (this.peek() !== ":") {
        throw new SyntaxError(`expected ':' at offset ${this.pos}`);
      }
      this.pos += 1;
      this.skipWhitespace();
      out[key] = this.parseValue();
      this.skipWhitespace();
      const ch = this.peek();
      if (ch === ",") {
        this.pos += 1;
        continue;
      }
      if (ch === "}") {
        this.pos += 1;
        return out;
      }
      throw new SyntaxError(`expected ',' or '}' at offset ${this.pos}`);
    }
  }

  private parseArray(): unknown[] {
    this.pos += 1; // '['
    const out: unknown[] = [];
    this.skipWhitespace();
    if (this.peek() === "]") {
      this.pos += 1;
      return out;
    }
    for (;;) {
      this.skipWhitespace();
      out.push(this.parseValue());
      this.skipWhitespace();
      const ch = this.peek();
      if (ch === ",") {
        this.pos += 1;
        continue;
      }
      if (ch === "]") {
        this.pos += 1;
        return out;
      }
      throw new SyntaxError(`expected ',' or ']' at offset ${this.pos}`);
    }
  }

  private parseString(): string {
    if (this.peek() !== '"') {
      throw new SyntaxError(`expected string at offset ${this.pos}`);
    }
    this.pos += 1;
    let out = "";
    for (;;) {
      const ch = this.text[this.pos];
      if (ch === undefined) {
        throw new SyntaxError("unterminated string");
      }
      if (ch === '"') {
        this.pos += 1;
        return out;
      }
      if (ch === "\\") {
        this.pos += 1;
        const esc = this.text[this.pos];
        if (esc === undefined) {
          throw new SyntaxError("unterminated escape");
        }
        if (esc === "u") {
          const hex = this.text.slice(this.pos + 1, this.pos + 5);
          if (!/^[0-9a-fA-F]{4}$/.test(hex)) {
            throw new SyntaxError(`invalid unicode escape at offset ${this.pos}`);
          }
          out += String.fromCharCode(Number.parseInt(hex, 16));
          this.pos += 5;
          continue;
        }
        const map: Record<string, string> = {
          '"': '"',
          "\\": "\\",
          "/": "/",
          b: "\b",
          f: "\f",
          n: "\n",
          r: "\r",
          t: "\t",
        };
        const mapped = map[esc];
        if (mapped === undefined) {
          throw new SyntaxError(`invalid escape \\${esc} at offset ${this.pos}`);
        }
        out += mapped;
        this.pos += 1;
        continue;
      }
      out += ch;
      this.pos += 1;
    }
  }

  private parseNumber(): RawNumber {
    const start = this.pos;
    if (this.peek() === "-") {
      this.pos += 1;
    }
    while (this.pos < this.text.length && /[0-9]/.test(this.text[this.pos]!)) {
      this.pos += 1;
    }
    if (this.text[this.pos] === ".") {
      this.pos += 1;
      while (this.pos < this.text.length && /[0-9]/.test(this.text[this.pos]!)) {
        this.pos += 1;
      }
    }
    if (this.text[this.pos] === "e" || this.text[this.pos] === "E") {
      this.pos += 1;
      if (this.text[this.pos] === "+" || this.text[this.pos] === "-") {
        this.pos += 1;
      }
      while (this.pos < this.text.length && /[0-9]/.test(this.text[this.pos]!)) {
        this.pos += 1;
      }
    }
    const raw = this.text.slice(start, this.pos);
    if (raw === "-" || raw === "") {
      throw new SyntaxError(`invalid number token at offset ${start}`);
    }
    return { raw, value: Number(raw) };
  }
}

function isExactlyRepresentable(number: RawNumber): boolean {
  if (Object.is(number.value, -0)) {
    // "-0"/"-0.0" 都是 f64 载荷：负零按拒绝口径处理，不落入精确整数桶。
    return false;
  }
  return String(number.value) === number.raw;
}

test("canonical TS behavior aligns with the shared uvp-core corpus", () => {
  const corpusText = readFileSync(corpusUrl, "utf8");
  const corpus = new RawNumberJsonParser(corpusText).parse() as {
    cases: CorpusCase[];
  };
  assert.ok(corpus.cases.length > 0, "canonical corpus must expose cases");

  let byteAligned = 0;
  let rejected = 0;
  let jsErasedDivergence = 0;
  for (const case_ of corpus.cases) {
    const numbers = collectNumbers(case_.input);
    // JS 可见浮点 = 非整数 number 或负零（Object.is 可观测）。
    const jsVisibleFloat = numbers.some(
      (n) => !Number.isInteger(n.value) || Object.is(n.value, -0),
    );
    const floatFormToken = numbers.some((n) => /[.eE]/.test(n.raw));
    const exactIntegers = numbers.every(isExactlyRepresentable);
    const input = unwrap(case_.input);
    const corpusRejects =
      case_.expectReject !== undefined || case_.expectError !== undefined;

    if (jsVisibleFloat) {
      // 口径 2：JS 可见浮点（含负零）→ 响亮拒绝；语料对该用例也必须是
      // 拒绝用例（expectReject），否则两线对同一输入分叉。
      assert.throws(
        () => canonicalStringify(input),
        /must be an integer: canonical JSON hash preimages reject float-form numbers/,
        `${case_.name}: JS-visible float must be rejected`,
      );
      assert.equal(
        corpusRejects,
        true,
        `${case_.name}: JS-visible float must be pinned as a rejection case in the shared corpus`,
      );
      rejected += 1;
      continue;
    }

    if (floatFormToken || !exactIntegers) {
      // 口径 3：整值浮点 token（JSON.parse 抹平为整数）或超精度整数
      // token——TS 按抹平后的整数放行（不抛）；Rust 权威在解析边界拒绝
      // 整值浮点字面量，语料将其钉为 expectReject。字节级区分是 JS 不可
      // 表示的分叉：断言止于"TS 不抛"，语料的拒绝标记记录权威侧行为。
      assert.doesNotThrow(
        () => canonicalStringify(input),
        `${case_.name}: erased-integer input must stay canonicalizable on the TS side`,
      );
      jsErasedDivergence += 1;
      continue;
    }

    // 口径 1：可精确表示的纯整数 input → 与语料钉死的 canonical 串逐字节
    // 相等；语料不得把纯整数 input 钉成拒绝用例（两线将真实分叉）。
    assert.equal(
      corpusRejects,
      false,
      `${case_.name}: exactly-representable integers must stay acceptance vectors`,
    );
    assert.equal(
      canonicalStringify(input),
      case_.expectCanonical,
      `${case_.name}: canonical bytes diverged from the pinned vector`,
    );
    byteAligned += 1;
  }

  // 三类口径都要有覆盖，防止语料演进后本消费测试退化成空转。
  assert.ok(byteAligned > 0, "corpus must keep byte-aligned integer vectors");
  assert.ok(rejected > 0, "corpus must keep JS-visible float rejection cases");
  assert.ok(jsErasedDivergence > 0, "corpus must keep integral-float divergence cases");
});

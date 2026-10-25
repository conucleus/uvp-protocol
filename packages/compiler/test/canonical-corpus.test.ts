import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import test from "node:test";
import { canonicalStringify } from "../src/index.js";

const corpusUrl = new URL(
  "../../../../uvp-core/fixtures/canonical/canonical.v1.json",
  import.meta.url,
);

interface RawNumber {
  readonly raw: string;
  readonly value: number;
}

const corpusDocument = JSON.parse(
  readFileSync(corpusUrl, "utf8"),
) as { readonly schemaVersion: string; readonly cases: readonly unknown[] };
assert.equal(
  corpusDocument.schemaVersion,
  "uvp.canonicalJsonCorpus.v1",
  "canonical corpus schemaVersion drifted; migrate this consumer before trusting the file",
);

interface CorpusCase {
  readonly name: string;
  readonly input: unknown;
  readonly expectCanonical?: string;
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
    this.pos += 1;
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
    this.pos += 1;
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
    const jsVisibleFloat = numbers.some(
      (n) => !Number.isInteger(n.value) || Object.is(n.value, -0),
    );
    const floatFormToken = numbers.some((n) => /[.eE]/.test(n.raw));
    const exactIntegers = numbers.every(isExactlyRepresentable);
    const input = unwrap(case_.input);
    const corpusRejects =
      case_.expectReject !== undefined || case_.expectError !== undefined;

    if (jsVisibleFloat) {
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

    if (numbers.some((n) => !Number.isSafeInteger(n.value))) {
      assert.throws(
        () => canonicalStringify(input),
        /must be a safe integer: canonical JSON hash preimages reject integers beyond 2\^53-1/,
        `${case_.name}: erased-precision integers must be rejected loudly on the TS side`,
      );
      rejected += 1;
      continue;
    }

    if (floatFormToken || !exactIntegers) {
      assert.doesNotThrow(
        () => canonicalStringify(input),
        `${case_.name}: erased-integer input must stay canonicalizable on the TS side`,
      );
      jsErasedDivergence += 1;
      continue;
    }

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

  assert.ok(byteAligned > 0, "corpus must keep byte-aligned integer vectors");
  assert.ok(rejected > 0, "corpus must keep JS-visible float rejection cases");
  assert.ok(jsErasedDivergence > 0, "corpus must keep integral-float divergence cases");
});

test("rejects integers beyond the safe range loudly (2^60, 1e21)", () => {
  assert.throws(
    () => canonicalStringify({ a: 2 ** 60 }),
    /must be a safe integer: canonical JSON hash preimages reject integers beyond 2\^53-1.*received 1152921504606847000/,
  );
  assert.throws(
    () => canonicalStringify({ a: 1e21 }),
    /must be a safe integer: canonical JSON hash preimages reject integers beyond 2\^53-1.*received 1e\+21/,
  );
  assert.throws(
    () => canonicalStringify([-(2 ** 60)]),
    /must be a safe integer/,
  );
  assert.equal(
    canonicalStringify({ a: Number.MAX_SAFE_INTEGER }),
    `{"a":${Number.MAX_SAFE_INTEGER}}`,
  );
});

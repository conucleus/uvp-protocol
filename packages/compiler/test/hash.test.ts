import assert from "node:assert/strict";
import test from "node:test";
import {
  canonicalStringify,
  keccak256Hex
} from "../src/index.js";

test("keccak256 matches EVM vectors", () => {
  assert.equal(
    keccak256Hex(""),
    "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
  );
  assert.equal(
    keccak256Hex("abc"),
    "0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"
  );
});

test("keccak256 covers padding boundary lengths", () => {
  const cases: readonly [number, string][] = [
    [135, "0x31ec7240c5dbaa9f1057136b31c7fd181a6870b0d9895618fb771b4ccf6a58a3"],
    [136, "0x9bfbe20595c8da175450082d9bebe797b060971072a0d2a3c897640b54ba676a"],
    [137, "0x13573495501e53a7dd9f67a0541dc450042e34d385d5d43528a2f581877c4bb1"]
  ];

  for (const [length, expected] of cases) {
    const bytes = new Uint8Array(length);
    for (let index = 0; index < bytes.length; index += 1) {
      bytes[index] = (index * 17 + length) % 256;
    }
    assert.equal(keccak256Hex(bytes), expected);
  }
});

test("canonical JSON is independent of object insertion order", () => {
  assert.equal(
    canonicalStringify({ b: 2, a: { d: 4, c: 3 } }),
    canonicalStringify({ a: { c: 3, d: 4 }, b: 2 })
  );
});

test("canonical JSON rejects undefined fields and negative zero", () => {
  // bug_audit #15：负零是 f64 载荷（serde_json 将 "-0"/"-0.0" 都解析为
  // f64 -0.0），权威侧一律拒绝——TS 与之同口径（-0 经 Object.is 可观测，
  // 不存在 JS 表示盲区）；正零 0 是 i64 整数，照常接受。
  assert.throws(
    () => canonicalStringify({ n: -0 }),
    /must be an integer: canonical JSON hash preimages reject float-form numbers, received -0/,
  );
  assert.equal(canonicalStringify({ n: 0 }), "{\"n\":0}");
  assert.throws(
    () => canonicalStringify({ optional: undefined }),
    /must not be undefined/
  );
});

test("canonical JSON number formatting matches the serde_json probe vectors", () => {
  // 与 uvp-ir canonicalize_number 的实测逐字节对齐。bug_audit #15 后
  // canonical 哈希输入的数字词表封闭为整数（u64/i64）：整数按十进制整型
  // 输出；一切浮点形态（0.1/1.5/1e-5/整值浮点/负零）一律响亮拒绝——
  // 语料（uvp-core fixtures/canonical/canonical.v1.json）钉死该边界。
  const cases: readonly [number, string][] = [
    [0, "0"],
    [100, "100"],
    [-42, "-42"],
    [9007199254740991, "9007199254740991"],
  ];
  for (const [value, expected] of cases) {
    assert.equal(canonicalStringify(value), expected);
  }
  assert.equal(canonicalStringify({ a: [0, 1] }), '{"a":[0,1]}');
});

test("canonical JSON rejects float-form numbers loudly (bug_audit #15)", () => {
  // 非整值 float：普通小数、科学计数、整值小数位与嵌套位置全部拒绝，
  // 错误信息带路径与值（响亮失败，不静默截断/取整）。
  const rejected: readonly number[] = [
    1.5,
    0.1,
    -2.75,
    1e-4,
    1e-5,
    2.5e-5,
    0.000012345,
    1234567890123456.5,
  ];
  for (const value of rejected) {
    assert.throws(
      () => canonicalStringify(value),
      /must be an integer: canonical JSON hash preimages reject float-form numbers/,
    );
  }
  assert.throws(
    () => canonicalStringify({ a: [0, 0.5] }),
    /\$\.a\[1\] must be an integer: canonical JSON hash preimages reject float-form numbers, received 0\.5/,
  );
  // 负零是 f64 载荷（serde_json 把 "-0"/"-0.0" 都解析为 f64 -0.0），与
  // 权威同口径拒绝；正零 0 与整数照常接受。
  assert.throws(
    () => canonicalStringify(-0),
    /received -0/,
  );
  assert.equal(canonicalStringify(0), "0");
  assert.equal(canonicalStringify(1), "1");
});

test("canonical JSON sorts keys by code point, not UTF-16 code units", () => {
  // U+FFFD is a single BMP code point (UTF-16 unit 0xFFFD); U+1F600 is
  // astral (surrogate pair 0xD83D 0xDE00, lead unit BELOW 0xFFFD).
  // Code-unit order puts the surrogate pair BEFORE U+FFFD; code-point
  // order (== UTF-8 byte order, the Rust BTreeMap/str Ord authority)
  // puts it after. The canonical byte stream and its hash must follow
  // the Rust order.
  const astral = "\u{1F600}";
  const bmp = "\uFFFD";
  assert.equal(
    canonicalStringify({ [astral]: 1, [bmp]: 2, plain: 3 }),
    `{"plain":3,"${bmp}":2,"${astral}":1}`,
  );
  // Linearity check across the BMP/astral boundary: every BMP key sorts
  // before every astral key under code-point order.
  assert.equal(
    canonicalStringify({ "\u{10FFFF}": 1, "\uFFFE": 2 }),
    `{"\uFFFE":2,"\u{10FFFF}":1}`,
  );
  // Astral keys sort among themselves by code point (U+10000 < U+1F600),
  // which UTF-16 unit order cannot distinguish from the reversed pair when
  // lead units tie.
  assert.equal(
    canonicalStringify({ "\u{1F600}": 2, "\u{10000}": 1 }),
    `{"\u{10000}":1,"\u{1F600}":2}`,
  );
});

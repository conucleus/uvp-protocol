import assert from "node:assert/strict";
import test from "node:test";
import {
  canonicalStringify,
  keccak256Hex,
  u64Word
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

test("canonical JSON rejects undefined fields and negative zero", () => {
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

test("canonical JSON rejects float-form numbers loudly", () => {
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
  assert.throws(
    () => canonicalStringify(-0),
    /received -0/,
  );
  assert.equal(canonicalStringify(0), "0");
  assert.equal(canonicalStringify(1), "1");
});

test("canonical JSON sorts keys by code point, not UTF-16 code units", () => {
  const astral = "\u{1F600}";
  const bmp = "\uFFFD";
  assert.equal(
    canonicalStringify({ [astral]: 1, [bmp]: 2, plain: 3 }),
    `{"plain":3,"${bmp}":2,"${astral}":1}`,
  );
  assert.equal(
    canonicalStringify({ "\u{10FFFF}": 1, "\uFFFE": 2 }),
    `{"\uFFFE":2,"\u{10FFFF}":1}`,
  );
  assert.equal(
    canonicalStringify({ "\u{1F600}": 2, "\u{10000}": 1 }),
    `{"\u{10000}":1,"\u{1F600}":2}`,
  );
});

test("canonical JSON orders integer-like keys by code point, not numeric order", () => {
  assert.equal(
    canonicalStringify({ labels: { zzz: "c", "9": "a", "10": "b", "0": "d" } }),
    '{"labels":{"0":"d","10":"b","9":"a","zzz":"c"}}',
  );
  assert.equal(
    canonicalStringify({ "9": 1, "10": 2 }),
    '{"10":2,"9":1}',
  );
  assert.equal(
    canonicalStringify({ spec: { params: { "2": "x", "10": "y" } } }),
    '{"spec":{"params":{"10":"y","2":"x"}}}',
  );
  assert.equal(
    canonicalStringify([{ "9": 1, "10": 2 }, { a: { "10": 1, "9": 2 } }]),
    '[{"10":2,"9":1},{"a":{"10":1,"9":2}}]',
  );
});

test("u64Word rejects values outside the unsigned 64-bit range", () => {
  assert.throws(
    () => u64Word(-1),
    /must fit the unsigned 64-bit word range, received -1/,
  );
  assert.throws(
    () => u64Word(2n ** 64n),
    /must fit the unsigned 64-bit word range, received 18446744073709551616/,
  );
  assert.equal(u64Word(0), `0x${"0".repeat(64)}`);
  assert.equal(
    u64Word(2n ** 64n - 1n),
    `0x${"0".repeat(48)}${"f".repeat(16)}`,
  );
});

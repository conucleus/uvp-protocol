import assert from "node:assert/strict";
import test from "node:test";
import { canonicalJson } from "../src/index.js";

test("canonical JSON rejects undefined fields and negative zero", () => {
  assert.throws(
    () => canonicalJson({ n: -0 }),
    /must be an integer: canonical JSON hash preimages reject float-form numbers, received -0/,
  );
  assert.equal(canonicalJson({ n: 0 }), "{\"n\":0}");
  assert.throws(
    () => canonicalJson({ optional: undefined }),
    /must not be undefined/,
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
    assert.equal(canonicalJson(value), expected);
  }
  assert.equal(canonicalJson({ a: [0, 1] }), '{"a":[0,1]}');
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
      () => canonicalJson(value),
      /must be an integer: canonical JSON hash preimages reject float-form numbers/,
    );
  }
  assert.throws(
    () => canonicalJson({ a: [0, 0.5] }),
    /\$\.a\[1\] must be an integer: canonical JSON hash preimages reject float-form numbers, received 0\.5/,
  );
  assert.throws(
    () => canonicalJson(-0),
    /received -0/,
  );
  assert.equal(canonicalJson(0), "0");
  assert.equal(canonicalJson(1), "1");
});

test("canonical JSON sorts keys by code point, not UTF-16 code units", () => {
  const astral = "\u{1F600}";
  const bmp = "\uFFFD";
  assert.equal(
    canonicalJson({ [astral]: 1, [bmp]: 2, plain: 3 }),
    `{"plain":3,"${bmp}":2,"${astral}":1}`,
  );
  assert.equal(
    canonicalJson({ "\u{10FFFF}": 1, "\uFFFE": 2 }),
    `{"\uFFFE":2,"\u{10FFFF}":1}`,
  );
  assert.equal(
    canonicalJson({ "\u{1F600}": 2, "\u{10000}": 1 }),
    `{"\u{10000}":1,"\u{1F600}":2}`,
  );
});

test("canonical JSON orders integer-like keys by code point, not numeric order", () => {
  assert.equal(
    canonicalJson({ labels: { zzz: "c", "9": "a", "10": "b", "0": "d" } }),
    '{"labels":{"0":"d","10":"b","9":"a","zzz":"c"}}',
  );
  assert.equal(
    canonicalJson({ "9": 1, "10": 2 }),
    '{"10":2,"9":1}',
  );
  assert.equal(
    canonicalJson({ spec: { params: { "2": "x", "10": "y" } } }),
    '{"spec":{"params":{"10":"y","2":"x"}}}',
  );
  assert.equal(
    canonicalJson([{ "9": 1, "10": 2 }, { a: { "10": 1, "9": 2 } }]),
    '[{"10":2,"9":1},{"a":{"10":1,"9":2}}]',
  );
});

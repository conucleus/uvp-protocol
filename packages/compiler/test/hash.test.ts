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

test("canonical JSON normalizes negative zero and rejects undefined fields", () => {
  assert.equal(canonicalStringify({ n: -0 }), "{\"n\":0}");
  assert.throws(
    () => canonicalStringify({ optional: undefined }),
    /must not be undefined/
  );
});

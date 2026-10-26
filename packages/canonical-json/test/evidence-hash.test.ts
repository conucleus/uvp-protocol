import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  hashCanonicalJson,
  hashEvidenceBytes,
  hashEvidenceJson,
  hashEvidenceText,
} from "../src/index.js";

describe("evidence hash", () => {
  it("hashes canonical JSON bytes and is key-order insensitive", () => {
    const expected = "0xb8ffb64722137f4b100665a52e3c943f8066e8ab8ba3b427e6f4b404defd82b0";
    assert.equal(hashEvidenceJson({ b: 2, a: 1 }).evidenceHash, expected);
    assert.equal(hashEvidenceJson({ a: 1, b: 2 }).evidenceHash, expected);
    assert.equal(hashCanonicalJson({ b: 2, a: 1 }), expected);
    assert.equal(hashEvidenceJson({ a: 1 }).source, "json");
    assert.equal(hashEvidenceJson({ a: 1 }).byteLength, 7);
  });

  it("hashes bytes and UTF-8 text identically while keeping JSON strings distinct", () => {
    assert.equal(
      hashEvidenceBytes(new TextEncoder().encode("paid")).evidenceHash,
      hashEvidenceText("paid").evidenceHash,
    );
    assert.equal(hashEvidenceBytes(new TextEncoder().encode("paid")).source, "bytes");
    assert.equal(hashEvidenceText("paid").source, "text");
    assert.equal(hashEvidenceText("paid").byteLength, 4);
    assert.notEqual(
      hashEvidenceText("paid").evidenceHash,
      hashEvidenceJson("paid").evidenceHash,
    );
  });
});

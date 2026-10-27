import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  FILE_RESOURCE_MAX_CANONICAL_BYTES,
  FileResourceHandleError,
  fileResourceHandleKey,
  fileResourceHandleView,
  normalizeFileResourceHandle,
} from "@uvp-eth/product-dto";

describe("file resource handles", () => {
  it("derives one stable type-qualified key from canonical JSON", () => {
    const first = normalizeFileResourceHandle({ type: "ipfs", cid: "bafy", pin: 7 });
    const reordered = normalizeFileResourceHandle({ pin: 7, cid: "bafy", type: "ipfs" });
    assert.equal(fileResourceHandleKey(first), fileResourceHandleKey(reordered));
    assert.match(fileResourceHandleKey(first), /^0x[0-9a-f]{64}$/u);
    assert.notEqual(fileResourceHandleKey(first), fileResourceHandleKey({ type: "s3", cid: "bafy", pin: 7 }));

    const view = fileResourceHandleView(first);
    assert.equal(view.type, "ipfs");
    assert.equal(view.handleKey, fileResourceHandleKey(first));
    assert.deepEqual(view.fields, { cid: "bafy", pin: 7 });
  });

  it("fails closed with the exact path and reason", () => {
    const cases: readonly (readonly [unknown, string])[] = [
      [{ name: "std/requirements" }, "type_missing"],
      [{ type: 7 }, "type_not_string"],
      [{ type: "" }, "type_empty"],
      [{ type: "x".repeat(65) }, "type_too_long"],
      [{ type: "plaintext", ratio: 1.5 }, "not_canonical_json"],
      [{ type: "plaintext", text: "x".repeat(FILE_RESOURCE_MAX_CANONICAL_BYTES) }, "too_large"],
    ];
    for (const [input, reason] of cases) {
      assert.throws(
        () => normalizeFileResourceHandle(input, "$.handle"),
        (error: unknown) =>
          error instanceof FileResourceHandleError &&
          error.reason === reason &&
          error.path === "$.handle",
      );
    }
  });
});

// executorChange 严格解码：signal refs 只能来自配置生成链路，未知字段/非 32 字节
// id 在 DTO 边界 fail-closed，宿主不得拿到半截授权面。

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  ConfigStageExecutorChangeError,
  parseConfigStageExecutorChange,
} from "@uvp-eth/product-dto";

const SOURCE = `0x${"a1".repeat(32)}`;
const SIGNAL = `0x${"b2".repeat(32)}`;
const HASH = `0x${"c3".repeat(32)}`;

describe("config stage executorChange", () => {
  it("decodes the assign/replace signal set and normalizes ids to lowercase", () => {
    const parsed = parseConfigStageExecutorChange({
      signalsHash: HASH.toUpperCase().replace("0X", "0x"),
      signals: [{ sourceId: SOURCE.toUpperCase().replace("0X", "0x"), signalId: SIGNAL }],
    });
    assert.deepEqual(parsed, {
      signalsHash: HASH,
      signals: [{ sourceId: SOURCE, signalId: SIGNAL }],
    });
  });

  it("fails closed with the field path and reason", () => {
    const cases: readonly (readonly [unknown, string])[] = [
      [null, "not_object"],
      [{ signalsHash: HASH, signals: [], extra: true }, "unknown_field"],
      [{ signalsHash: "0x00", signals: [] }, "signals_hash_invalid"],
      [{ signalsHash: HASH, signals: "nope" }, "signals_not_array"],
      [{ signalsHash: HASH, signals: [SOURCE] }, "signal_not_object"],
      [{ signalsHash: HASH, signals: [{ sourceId: SOURCE, signalId: SIGNAL, label: "x" }] }, "signal_unknown_field"],
      [{ signalsHash: HASH, signals: [{ sourceId: SOURCE, signalId: "0x12" }] }, "signal_id_invalid"],
    ];
    for (const [value, reason] of cases) {
      assert.throws(
        () => parseConfigStageExecutorChange(value, "bundle.stages[1].executorChange"),
        (error: unknown) => {
          assert.ok(error instanceof ConfigStageExecutorChangeError);
          assert.equal(error.reason, reason);
          assert.equal(error.path.startsWith("bundle.stages[1].executorChange"), true);
          return true;
        },
      );
    }
  });
});

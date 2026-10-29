// HookReady decode contract: topic identity, event-field normalization,
// deterministic event ids, skip-on-other-topic, and named decode failures are
// protocol-bindings' event-shape ownership (STATE_MACHINE_ABI).
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { encodeAbiParameters, keccak256, stringToBytes, stringToHex, type Hex } from "viem";
import {
  HOOK_READY_TOPIC,
  decodeHookReadyLog,
  hookReadyEventId,
  type StateMachineRawLog,
} from "../src/index.js";

const STATE_MACHINE = "0x0000000000000000000000000000000000000001" as const;
const ORDER_ID = `0x${"11".repeat(32)}` as Hex;
const PLAN_ID = `0x${"77".repeat(32)}` as Hex;
const HOOK_ID = `0x${"22".repeat(32)}` as Hex;
const STAGE_ID = `0x${"55".repeat(32)}` as Hex;
const HOOK_NAME_ID = `0x${"66".repeat(32)}` as Hex;
const TX_HASH = `0x${"33".repeat(32)}` as Hex;

const STATE_MACHINE_FIXTURE = JSON.parse(
  readFileSync(
    new URL("../../../contracts/uvp-contracts/fixtures/uvp-state-machine.v0.17.json", import.meta.url),
    "utf8",
  ),
) as {
  readonly hashes: {
    readonly artifactHash: Hex;
  };
  readonly events: {
    readonly HookReady: {
      readonly signature: string;
      readonly topic: Hex;
    };
  };
};

function hookReadyLog(logIndex: number | null = 7): StateMachineRawLog {
  return {
    address: STATE_MACHINE,
    data: encodeAbiParameters(
      [
        { type: "bytes32" },
        { type: "bytes32" },
      ],
      [STAGE_ID, HOOK_NAME_ID],
    ),
    topics: [
      keccak256(stringToHex(STATE_MACHINE_FIXTURE.events.HookReady.signature)),
      PLAN_ID,
      ORDER_ID,
      HOOK_ID,
    ],
    blockNumber: 12n,
    transactionHash: TX_HASH,
    logIndex,
  };
}

function artifactIndex() {
  return {
    hooksByHookId: {
      [HOOK_ID]: {
        stageIdentifier: "exec.main",
        hookName: "START",
      },
    },
  };
}

describe("HookReady decode", () => {
  it("decodes HookReady logs", () => {
    const log = hookReadyLog();
    const event = decodeHookReadyLog(log, artifactIndex());

    assert.match(STATE_MACHINE_FIXTURE.hashes.artifactHash, /^0x[0-9a-f]{64}$/);
    assert.equal(
      STATE_MACHINE_FIXTURE.events.HookReady.signature,
      "HookReady(bytes32,bytes32,bytes32,bytes32,bytes32)",
    );
    assert.equal(HOOK_READY_TOPIC, STATE_MACHINE_FIXTURE.events.HookReady.topic);
    assert.deepEqual(event, {
      type: "HookReady",
      eventId: hookReadyEventId(log),
      stateMachineAddress: STATE_MACHINE,
      planId: PLAN_ID,
      orderId: ORDER_ID,
      hookId: HOOK_ID,
      stageId: STAGE_ID,
      hookNameId: HOOK_NAME_ID,
      stageIdentifier: "exec.main",
      hookName: "START",
      blockNumber: 12n,
      transactionHash: TX_HASH,
      logIndex: 7n,
      raw: log,
    });
  });

  it("throws with the original context when a HookReady-topic log fails to decode", () => {
    const broken = { ...hookReadyLog(), data: "0xdeadbeef" as Hex };

    assert.throws(
      () => decodeHookReadyLog(broken, artifactIndex()),
      /failed to decode HookReady log data/,
    );
  });

  it("still skips logs without the HookReady topic", () => {
    const otherTopic = keccak256(stringToBytes("Other(uint256)"));
    const unrelated = { ...hookReadyLog(), topics: [otherTopic, ORDER_ID] };

    assert.equal(decodeHookReadyLog(unrelated, artifactIndex()), undefined);
  });

  it("refuses to derive event ids from zero values when transactionHash or logIndex is missing", () => {
    assert.throws(() => hookReadyEventId({ transactionHash: null, logIndex: 7 }), /transactionHash/);
    assert.throws(() => hookReadyEventId({ transactionHash: TX_HASH, logIndex: null }), /logIndex/);
    assert.throws(() => hookReadyEventId({ transactionHash: TX_HASH }), /logIndex/);
  });
});

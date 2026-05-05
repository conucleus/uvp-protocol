import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  ChainReplayMismatchError,
  replayChainEvents,
  type ChainHookReadyEvent,
  type ChainModeEvent
} from "../src/index.js";

const chainFixtureUrl = new URL("../fixtures/chain-hook-oracle.events.json", import.meta.url);

async function loadChainEvents(): Promise<ChainModeEvent[]> {
  return JSON.parse(await readFile(chainFixtureUrl, "utf8")) as ChainModeEvent[];
}

test("chain-mode replay matches hook expectations from stable chain events", async () => {
  const events = await loadChainEvents();
  const result = replayChainEvents(events);

  assert.deepEqual(result.mismatches, []);
  assert.deepEqual(result.observed, result.expected);

  const cancelOrder = result.state.orders["chain-oracle::order-cancel"];
  assert.equal(
    cancelOrder?.signals["0x0000000000000000000000000000000000000000000000000000000000002001"]?.senderId,
    "init-executor-a"
  );
  assert.equal(
    cancelOrder?.signals["0x0000000000000000000000000000000000000000000000000000000000002001"]?.eventId,
    "2:0:0x03"
  );
  assert.equal(cancelOrder?.hookStatuses["0x0000000000000000000000000000000000000000000000000000000000003001"]?.status, "reg");
  assert.equal(cancelOrder?.hookStatuses["0x0000000000000000000000000000000000000000000000000000000000003002"]?.status, "cxl");

  const cancelStartReadyCount = result.observed.filter(
    (event) =>
      event.eventName === "HookReady" &&
      event.orderId === "order-cancel" &&
      event.hookId === "0x0000000000000000000000000000000000000000000000000000000000003001"
  ).length;
  assert.equal(cancelStartReadyCount, 1);

  const timerOrder = result.state.orders["chain-oracle::order-timer"];
  assert.equal(timerOrder?.hookStatuses["0x0000000000000000000000000000000000000000000000000000000000003001"]?.status, "reg");
  assert.equal(timerOrder?.hookStatuses["0x0000000000000000000000000000000000000000000000000000000000003002"]?.status, "reg");
  assert.equal(
    result.observed.some(
      (event) =>
        event.eventName === "HookReady" &&
        event.orderId === "order-timer" &&
        event.hookId === "0x0000000000000000000000000000000000000000000000000000000000003002"
    ),
    true
  );
});

test("chain-mode reports mismatched golden hook events", async () => {
  const events = await loadChainEvents();
  const readyIndex = events.findIndex(
    (event) => event.eventName === "HookReady" && event.orderId === "order-cancel"
  );
  assert.notEqual(readyIndex, -1);

  const badEvents = [...events];
  const badReady = badEvents[readyIndex] as ChainHookReadyEvent;
  badEvents[readyIndex] = {
    ...badReady,
    hookName: "WRONG"
  };

  const result = replayChainEvents(badEvents, { strict: false });
  assert.equal(result.mismatches.length, 1);
  assert.equal(result.mismatches[0]?.reason, "semantic-mismatch");
  assert.throws(() => replayChainEvents(badEvents), ChainReplayMismatchError);
});

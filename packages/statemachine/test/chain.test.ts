import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  ChainReplayMismatchError,
  chainEventToRuntimeEvent,
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
  assert.deepEqual(
    result.runtimeEvents.map((event) => event.type),
    [
      "PlanRegistered",
      "OrderRegistered",
      "SignalReceived",
      "SignalReceived",
      "SignalReceived",
      "TimerDue",
      "OrderRegistered",
      "SignalReceived",
      "TimerDue"
    ]
  );
  assert.equal(
    result.runtimeEvents.some(
      (event) => event.type === "DispatchSucceeded" || event.type === "DispatchFailed"
    ),
    false
  );

  const cancelOrder = result.state.orders["chain-oracle::order-cancel"];
  assert.equal(cancelOrder?.signals["buyer::init.main.cmp"]?.senderId, "init-executor-a");
  assert.equal(cancelOrder?.signals["buyer::init.main.cmp"]?.eventId, "2:0:0x03");
  assert.equal(cancelOrder?.hookStatuses["exec.main#START"]?.status, "reg");
  assert.equal(cancelOrder?.hookStatuses["exec.main#TIMEOUT"]?.status, "cxl");

  const cancelStartReadyCount = result.observed.filter(
    (event) =>
      event.eventName === "HookReady" &&
      event.orderId === "order-cancel" &&
      event.hookId === "exec.main#START"
  ).length;
  assert.equal(cancelStartReadyCount, 1);

  const timerOrder = result.state.orders["chain-oracle::order-timer"];
  assert.equal(timerOrder?.hookStatuses["exec.main#START"]?.status, "reg");
  assert.equal(timerOrder?.hookStatuses["exec.main#TIMEOUT"]?.status, "reg");
  assert.equal(
    result.observed.some(
      (event) =>
        event.eventName === "HookReady" &&
        event.orderId === "order-timer" &&
        event.hookId === "exec.main#TIMEOUT"
    ),
    true
  );
});

test("chain adapter maps SignalSubmitted and TimerPoked to runtime events", async () => {
  const events = await loadChainEvents();
  const signal = events.find((event) => event.eventName === "SignalSubmitted");
  const timer = events.find((event) => event.eventName === "TimerPoked");

  assert.ok(signal);
  assert.ok(timer);

  const signalRuntimeEvent = chainEventToRuntimeEvent(signal);
  const timerRuntimeEvent = chainEventToRuntimeEvent(timer);

  assert.equal(signalRuntimeEvent?.type, "SignalReceived");
  assert.equal(signalRuntimeEvent?.eventId, "2:0:0x03");
  assert.equal(timerRuntimeEvent?.type, "TimerDue");
  assert.equal(timerRuntimeEvent?.eventId, "5:0:0x06");
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

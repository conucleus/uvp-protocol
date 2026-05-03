import assert from "node:assert/strict";
import test from "node:test";
import type { RuntimeEvent } from "@uvp-eth/statemachine";
import {
  InMemoryRuntimeEventStore,
  type RuntimeEventStore
} from "../src/index.js";

const planEvent: RuntimeEvent = {
  eventId: "plan-1",
  type: "PlanRegistered",
  plan: {
    planId: "0x1111111111111111111111111111111111111111111111111111111111111111",
    zhixuId: "runtime-store-demo",
    version: "1",
    compiledHooks: [],
    dependencyIndex: {}
  }
};

const orderEvent: RuntimeEvent = {
  eventId: "order-1",
  type: "OrderRegistered",
  planId: "0x1111111111111111111111111111111111111111111111111111111111111111",
  zhixuId: "runtime-store-demo",
  orderId: "order-1",
  receivedAt: "2026-04-27T00:00:00.000Z"
};

runRuntimeEventStoreContract("InMemoryRuntimeEventStore", async (initialEvents = []) => {
  return new InMemoryRuntimeEventStore(initialEvents);
});

function runRuntimeEventStoreContract(
  name: string,
  createStore: (initialEvents?: readonly RuntimeEvent[]) => Promise<RuntimeEventStore>
): void {
  test(`${name} preserves append order`, async () => {
    const store = await createStore();

    await store.append(planEvent);
    await store.append(orderEvent);

    assert.deepEqual(
      (await store.load()).map((event) => event.eventId),
      ["plan-1", "order-1"]
    );
  });

  test(`${name} defensively copies initial and loaded events`, async () => {
    const initial = [structuredClone(planEvent)];
    const store = await createStore(initial);

    initial[0] = {
      ...orderEvent,
      eventId: "mutated-before-load"
    };
    const firstLoad = await store.load();
    assert.equal(firstLoad[0]?.eventId, "plan-1");

    (firstLoad[0] as { eventId: string }).eventId = "mutated-after-load";
    const secondLoad = await store.load();
    assert.equal(secondLoad[0]?.eventId, "plan-1");
  });
}

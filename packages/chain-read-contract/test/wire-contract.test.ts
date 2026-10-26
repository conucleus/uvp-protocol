// Pins the chain read wire contract: bigint fields serialize to decimal
// strings, decoders round-trip a representative order/task/snapshot, and a
// missing required group or malformed decimal is rejected with a typed error.
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  ChainReadContractError,
  decodeOrderWire,
  decodeSnapshotWire,
  decodeSyncStateWire,
  decodeTaskWire,
  isChainOrderProjection,
  parseOrdersResponse,
  parseSyncStateResponse,
  parseTaskResponse,
  parseSnapshotResponse,
  toWire,
  type ChainOrderProjection,
  type ChainProjectionSnapshot,
  type ChainSyncState,
  type ChainTaskProjection
} from "@uvp-eth/chain-read-contract";
import type { Address, Hex } from "viem";

const address = (digit: string): Address => `0x${digit.repeat(40)}` as Address;
const bytes32 = (digit: string): Hex => `0x${digit.repeat(64)}` as Hex;

const CHAIN_ID = 31337;
const STATE_MACHINE = address("1");
const ORDER_ID = bytes32("a");
const PLAN_ID = bytes32("b");
const PLAN_HASH = bytes32("c");
const DEPLOYMENT_ID = bytes32("d");
const HOOK_ID = bytes32("e");
const STAGE_ID = bytes32("f");
const SIGNAL_ID = bytes32("1");
const HASH = bytes32("2");
const TX_HASH = bytes32("3");
const WALLET = address("2");

function provenance(blockNumber: bigint) {
  return {
    chainId: CHAIN_ID,
    contractAddress: STATE_MACHINE,
    blockNumber,
    transactionIndex: 0,
    transactionHash: TX_HASH,
    logIndex: 0
  };
}

function proof(blockNumber: bigint) {
  return {
    ...provenance(blockNumber),
    eventId: `event-${blockNumber.toString()}`,
    eventName: "HookReady",
    args: { hookId: HOOK_ID }
  };
}

function internalOrder() {
  return {
    orderId: ORDER_ID,
    chainId: CHAIN_ID,
    contractAddress: STATE_MACHINE,
    deploymentId: DEPLOYMENT_ID,
    planId: PLAN_ID,
    planHash: PLAN_HASH,
    status: "registered" as const,
    currentStage: STAGE_ID,
    creator: WALLET,
    authorizations: {},
    signals: {
      [SIGNAL_ID]: {
        orderId: ORDER_ID,
        sourceId: STAGE_ID,
        signalId: SIGNAL_ID,
        payloadHash: HASH,
        idempotencyKey: HASH,
        submitter: WALLET,
        submittedAt: provenance(13n),
        proof: proof(13n)
      }
    },
    derivedSignals: {},
    stageMaterializations: {},
    stageExecutorOverlays: {},
    stageResourceOverlays: {},
    hooks: {},
    tasks: {
      "task-1": {
        taskId: "task-1",
        orderId: ORDER_ID,
        stateMachineAddress: STATE_MACHINE,
        planId: PLAN_ID,
        hookId: HOOK_ID,
        stageIdentifier: STAGE_ID,
        hookName: HOOK_ID,
        assigneeRole: "performer",
        assigneeWallet: WALLET,
        status: "ready" as const,
        submitSignals: [{ sourceId: STAGE_ID, signalId: SIGNAL_ID, source: "authorization" as const }],
        createdAt: provenance(20n),
        updatedAt: provenance(21n),
        proof: proof(21n)
      }
    },
    timeline: [{
      timelineId: "event-10",
      orderId: ORDER_ID,
      planId: PLAN_ID,
      eventName: "OrderRegistered",
      text: "订单已创建",
      time: "block 10",
      proof: proof(10n)
    }],
    proof: [proof(10n)],
    registeredAt: provenance(10n),
    updatedAt: provenance(12n)
  };
}

function internalTask() {
  return internalOrder().tasks["task-1"]!;
}

function internalSnapshot() {
  const order = internalOrder();
  return {
    rebuildable: true as const,
    eventCount: 15,
    activeStateMachineDeploymentId: DEPLOYMENT_ID,
    stateMachineDeployments: {
      [DEPLOYMENT_ID]: {
        deploymentId: DEPLOYMENT_ID,
        stateMachineAddress: STATE_MACHINE,
        artifactHash: HASH,
        abiHash: HASH,
        deploymentBlock: "4",
        metadataURI: "ipfs://deployment",
        status: "active" as const,
        registeredAt: provenance(4n),
        updatedAt: provenance(5n),
        proof: proof(4n)
      }
    },
    stateMachineModules: {},
    contractGovernance: {},
    stateMachinePlans: {
      [PLAN_ID]: {
        planId: PLAN_ID,
        stateMachineAddress: STATE_MACHINE,
        planHash: PLAN_HASH,
        hookCount: "0",
        selectorBindings: [],
        signalCapabilities: [],
        executorCandidates: [],
        registeredAt: provenance(8n),
        updatedAt: provenance(8n),
        proof: proof(8n),
        commitProof: proof(8n)
      }
    },
    stateMachineOrders: { [ORDER_ID]: order },
    stateMachineDocks: {},
    stateMachineDocksByTargetOrder: {},
    stateMachineOrderDockChainDepth: {},
    stateMachineTasks: { [order.tasks["task-1"]!.taskId]: order.tasks["task-1"]! },
    lastEvent: provenance(15n),
    unresolvedModuleOrderEventCount: 0,
    unresolvedDockEventCount: 2,
    unresolvedStageActivationEventCount: 0,
    unresolvedDockTargetDeploymentCount: 0,
    capabilityEnrichmentMismatchCount: 0,
    unknownEventCount: 0
  };
}

function internalSyncState() {
  return {
    chainId: CHAIN_ID,
    contractAddress: STATE_MACHINE,
    syncStatus: "syncing" as const,
    latestIndexedBlock: 42n,
    finalizedBlock: 40n,
    confirmationDepth: 2,
    lastEventName: "HookReady",
    eventCount: 7,
    rebuild: {
      status: "completed" as const,
      fromBlock: 38n,
      toBlock: 42n,
      eventCount: 7,
      removedLogsFiltered: true
    },
    updatedAt: "2026-10-27T00:00:00.000Z"
  };
}

describe("chain read wire contract", () => {
  it("serializes every bigint field to a decimal string and drops undefined members", () => {
    const wire: ChainOrderProjection = toWire(internalOrder());

    assert.equal(wire.updatedAt.blockNumber, "12");
    assert.equal(wire.registeredAt?.blockNumber, "10");
    assert.equal(wire.tasks["task-1"]?.createdAt.blockNumber, "20");
    assert.equal(wire.signals[SIGNAL_ID]?.submittedAt.blockNumber, "13");
    assert.equal(wire.timeline[0]?.proof.blockNumber, "10");
    assert.equal(wire.proof[0]?.blockNumber, "10");
    assert.deepEqual(findBigints(wire), []);

    const sparse = toWire({ deploymentId: undefined as string | undefined });
    assert.equal("deploymentId" in sparse, false);

    const task: ChainTaskProjection = toWire(internalTask());
    assert.equal(task.proof.blockNumber, "21");
    assert.equal(task.submitSignals?.[0]?.source, "authorization");
  });

  it("round-trips a representative order, task, snapshot, and sync state through the decoders", () => {
    const order: ChainOrderProjection = toWire(internalOrder());
    const task: ChainTaskProjection = toWire(internalTask());
    const snapshot: ChainProjectionSnapshot = toWire(internalSnapshot());
    const syncState: ChainSyncState = toWire(internalSyncState());

    assert.deepEqual(decodeOrderWire(JSON.parse(JSON.stringify(order))), order);
    assert.deepEqual(decodeTaskWire(JSON.parse(JSON.stringify(task))), task);
    assert.deepEqual(decodeSnapshotWire(JSON.parse(JSON.stringify(snapshot))), snapshot);
    assert.deepEqual(decodeSyncStateWire(JSON.parse(JSON.stringify(syncState))), syncState);

    assert.deepEqual(parseOrdersResponse({ orders: [order] }), [order]);
    assert.deepEqual(parseTaskResponse({ task }), task);
    assert.deepEqual(parseSnapshotResponse({ snapshot }), snapshot);
    assert.deepEqual(parseSyncStateResponse({ syncState }), syncState);
    assert.equal(isChainOrderProjection(order), true);
  });


  it("rejects a missing required group and a malformed nested placeholder", () => {
    const order: ChainOrderProjection = toWire(internalOrder());
    const { authorizations: _authorizations, ...withoutAuthorizations } = order;
    assert.throws(
      () => decodeOrderWire(withoutAuthorizations),
      (error: unknown) =>
        error instanceof ChainReadContractError &&
        error.path === "order.authorizations" &&
        error.message.includes("must be an object")
    );
    assert.equal(isChainOrderProjection(withoutAuthorizations), false);

    const malformedBlock = {
      ...order,
      updatedAt: { ...order.updatedAt, blockNumber: "12.5" }
    };
    assert.throws(
      () => decodeOrderWire(malformedBlock),
      (error: unknown) =>
        error instanceof ChainReadContractError &&
        error.path === "order.updatedAt.blockNumber"
    );

    assert.throws(
      () => decodeSnapshotWire({ rebuildable: true, eventCount: 1 }),
      (error: unknown) =>
        error instanceof ChainReadContractError &&
        error.path === "snapshot.stateMachineDeployments"
    );
    assert.throws(
      () => parseOrdersResponse({ orders: "not-an-array" }),
      (error: unknown) =>
        error instanceof ChainReadContractError && error.path === "response.orders"
    );
  });
});

function findBigints(value: unknown): bigint[] {
  if (typeof value === "bigint") {
    return [value];
  }
  if (Array.isArray(value)) {
    return value.flatMap(findBigints);
  }
  if (value !== null && typeof value === "object") {
    return Object.values(value).flatMap(findBigints);
  }
  return [];
}

import {
  applyRuntimeEvent,
  emptyRuntimeState,
  type HookRuntimeStatus,
  type RuntimeEffect,
  type RuntimeEvent,
  type RuntimeHookPlan,
  type RuntimeState,
  type SignalReceivedEvent
} from "./runtime.js";

export type ChainModeEvent =
  | ChainPlanRegisteredEvent
  | ChainOrderRegisteredEvent
  | ChainSignalSubmittedEvent
  | ChainHookStatusChangedEvent
  | ChainHookReadyEvent
  | ChainTimerPokedEvent;

export type ChainModeInputEvent =
  | ChainPlanRegisteredEvent
  | ChainOrderRegisteredEvent
  | ChainSignalSubmittedEvent
  | ChainTimerPokedEvent;

export type ChainModeExpectedEvent = ChainHookStatusChangedEvent | ChainHookReadyEvent;

export type ChainObservableHookStatus = Extract<HookRuntimeStatus, "wait" | "cxl">;

export interface ChainEventBase {
  readonly eventName: string;
  readonly blockNumber: number;
  readonly logIndex: number;
  readonly transactionHash: `0x${string}`;
  readonly contractAddress?: `0x${string}`;
}

export interface ChainPlanRegisteredEvent extends ChainEventBase {
  readonly eventName: "PlanRegistered";
  readonly plan: RuntimeHookPlan;
}

export interface ChainOrderRegisteredEvent extends ChainEventBase {
  readonly eventName: "OrderRegistered";
  readonly planId: `0x${string}`;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly registeredAt: string;
}

export interface ChainSignalSubmittedEvent extends ChainEventBase {
  readonly eventName: "SignalSubmitted";
  readonly zhixuId: string;
  readonly orderId: string;
  readonly source: string;
  readonly stageIdentifier: string;
  readonly signalName: string;
  readonly senderId: string;
  readonly submittedAt: string;
  readonly idempotencyKey?: string;
  readonly traceId?: string;
  readonly payloadRef?: string;
}

export interface ChainHookStatusChangedEvent extends ChainEventBase {
  readonly eventName: "HookStatusChanged";
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly status: ChainObservableHookStatus;
  readonly dueAt?: string;
}

export interface ChainHookReadyEvent extends ChainEventBase {
  readonly eventName: "HookReady";
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly stageIdentifier: string;
  readonly hookName: string;
}

export interface ChainTimerPokedEvent extends ChainEventBase {
  readonly eventName: "TimerPoked";
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly pokedAt: string;
}

export type ChainHookObservation =
  | ChainHookReadyObservation
  | ChainHookStatusChangedObservation;

export interface ChainHookReadyObservation {
  readonly eventName: "HookReady";
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly stageIdentifier: string;
  readonly hookName: string;
}

export interface ChainHookStatusChangedObservation {
  readonly eventName: "HookStatusChanged";
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly status: ChainObservableHookStatus;
  readonly dueAt?: string;
}

export interface ChainReplayOptions {
  readonly sort?: boolean;
  readonly strict?: boolean;
}

export interface ChainReplayResult {
  readonly state: RuntimeState;
  readonly runtimeEvents: readonly RuntimeEvent[];
  readonly expected: readonly ChainHookObservation[];
  readonly observed: readonly ChainHookObservation[];
  readonly mismatches: readonly ChainReplayMismatch[];
}

export interface ChainReplayMismatch {
  readonly index: number;
  readonly reason: "missing-observed" | "unexpected-observed" | "semantic-mismatch";
  readonly expected?: ChainHookObservation;
  readonly observed?: ChainHookObservation;
}

export class ChainReplayMismatchError extends Error {
  readonly mismatches: readonly ChainReplayMismatch[];

  constructor(mismatches: readonly ChainReplayMismatch[]) {
    super(`chain replay mismatched ${mismatches.length} hook observation(s)`);
    this.name = "ChainReplayMismatchError";
    this.mismatches = mismatches;
  }
}

export function replayChainEvents(
  events: readonly ChainModeEvent[],
  options: ChainReplayOptions = {}
): ChainReplayResult {
  const sorted = options.sort === false ? [...events] : [...events].sort(compareChainEvents);
  let state = emptyRuntimeState();
  const runtimeEvents: RuntimeEvent[] = [];
  const expected: ChainHookObservation[] = [];
  const observed: ChainHookObservation[] = [];

  for (const event of sorted) {
    const runtimeEvent = chainEventToRuntimeEvent(event);
    if (runtimeEvent) {
      const previousEffectCount = state.effects.length;
      state = applyRuntimeEvent(state, runtimeEvent);
      runtimeEvents.push(runtimeEvent);
      observed.push(...effectsToChainObservations(state.effects.slice(previousEffectCount)));
      continue;
    }

    if (isChainExpectedEvent(event)) {
      expected.push(chainEventToExpectedObservation(event));
      continue;
    }

    throw new Error(`chain event did not map to runtime or expectation: ${event.eventName}`);
  }

  const mismatches = compareHookObservations(expected, observed);
  if ((options.strict ?? true) && mismatches.length > 0) {
    throw new ChainReplayMismatchError(mismatches);
  }

  return {
    state,
    runtimeEvents,
    expected,
    observed,
    mismatches
  };
}

export function chainEventToRuntimeEvent(event: ChainModeEvent): RuntimeEvent | null {
  switch (event.eventName) {
    case "PlanRegistered":
      return {
        eventId: chainEventId(event),
        type: "PlanRegistered",
        plan: event.plan
      };
    case "OrderRegistered":
      return {
        eventId: chainEventId(event),
        type: "OrderRegistered",
        planId: event.planId,
        zhixuId: event.zhixuId,
        orderId: event.orderId,
        receivedAt: event.registeredAt
      };
    case "SignalSubmitted":
      return {
        eventId: chainEventId(event),
        type: "SignalReceived",
        zhixuId: event.zhixuId,
        orderId: event.orderId,
        source: event.source,
        stageIdentifier: event.stageIdentifier,
        signalName: event.signalName,
        senderId: event.senderId,
        receivedAt: event.submittedAt,
        ...optionalSignalFields(event)
      };
    case "TimerPoked":
      return {
        eventId: chainEventId(event),
        type: "TimerDue",
        zhixuId: event.zhixuId,
        orderId: event.orderId,
        hookId: event.hookId,
        now: event.pokedAt
      };
    case "HookStatusChanged":
    case "HookReady":
      return null;
    default:
      return assertNever(event);
  }
}

export function chainEventId(event: ChainEventBase): string {
  return `${event.blockNumber}:${event.logIndex}:${event.transactionHash}`;
}

export function compareChainEvents(a: ChainEventBase, b: ChainEventBase): number {
  return a.blockNumber - b.blockNumber || a.logIndex - b.logIndex;
}

export function chainEventToExpectedObservation(
  event: ChainModeExpectedEvent
): ChainHookObservation {
  switch (event.eventName) {
    case "HookReady":
      return {
        eventName: "HookReady",
        zhixuId: event.zhixuId,
        orderId: event.orderId,
        hookId: event.hookId,
        stageIdentifier: event.stageIdentifier,
        hookName: event.hookName
      };
    case "HookStatusChanged":
      return {
        eventName: "HookStatusChanged",
        zhixuId: event.zhixuId,
        orderId: event.orderId,
        hookId: event.hookId,
        status: event.status,
        ...(event.dueAt ? { dueAt: event.dueAt } : {})
      };
    default:
      return assertNever(event);
  }
}

export function effectsToChainObservations(
  effects: readonly RuntimeEffect[]
): ChainHookObservation[] {
  return effects.map((effect) => {
    switch (effect.type) {
      case "HookReady":
        return {
          eventName: "HookReady",
          zhixuId: effect.zhixuId,
          orderId: effect.orderId,
          hookId: effect.hookId,
          stageIdentifier: effect.stageIdentifier,
          hookName: effect.hookName
        };
      case "HookWaiting":
        return {
          eventName: "HookStatusChanged",
          zhixuId: effect.zhixuId,
          orderId: effect.orderId,
          hookId: effect.hookId,
          status: "wait",
          dueAt: effect.dueAt
        };
      case "HookCancelled":
        return {
          eventName: "HookStatusChanged",
          zhixuId: effect.zhixuId,
          orderId: effect.orderId,
          hookId: effect.hookId,
          status: "cxl"
        };
      default:
        return assertNever(effect);
    }
  });
}

export function compareHookObservations(
  expected: readonly ChainHookObservation[],
  observed: readonly ChainHookObservation[]
): ChainReplayMismatch[] {
  const mismatches: ChainReplayMismatch[] = [];
  const length = Math.max(expected.length, observed.length);

  for (let index = 0; index < length; index += 1) {
    const expectedObservation = expected[index];
    const observedObservation = observed[index];

    if (!expectedObservation && observedObservation) {
      mismatches.push({
        index,
        reason: "unexpected-observed",
        observed: observedObservation
      });
      continue;
    }
    if (expectedObservation && !observedObservation) {
      mismatches.push({
        index,
        reason: "missing-observed",
        expected: expectedObservation
      });
      continue;
    }
    if (
      expectedObservation &&
      observedObservation &&
      !sameHookObservation(expectedObservation, observedObservation)
    ) {
      mismatches.push({
        index,
        reason: "semantic-mismatch",
        expected: expectedObservation,
        observed: observedObservation
      });
    }
  }

  return mismatches;
}

function optionalSignalFields(
  event: ChainSignalSubmittedEvent
): Pick<SignalReceivedEvent, "idempotencyKey" | "traceId" | "payloadRef"> {
  const fields: {
    idempotencyKey?: string;
    traceId?: string;
    payloadRef?: string;
  } = {};
  if (event.idempotencyKey !== undefined) {
    fields.idempotencyKey = event.idempotencyKey;
  }
  if (event.traceId !== undefined) {
    fields.traceId = event.traceId;
  }
  if (event.payloadRef !== undefined) {
    fields.payloadRef = event.payloadRef;
  }
  return fields;
}

function isChainExpectedEvent(event: ChainModeEvent): event is ChainModeExpectedEvent {
  return event.eventName === "HookStatusChanged" || event.eventName === "HookReady";
}

function sameHookObservation(
  expected: ChainHookObservation,
  observed: ChainHookObservation
): boolean {
  if (expected.eventName !== observed.eventName) {
    return false;
  }

  switch (expected.eventName) {
    case "HookReady":
      return (
        observed.eventName === "HookReady" &&
        expected.zhixuId === observed.zhixuId &&
        expected.orderId === observed.orderId &&
        expected.hookId === observed.hookId &&
        expected.stageIdentifier === observed.stageIdentifier &&
        expected.hookName === observed.hookName
      );
    case "HookStatusChanged":
      return (
        observed.eventName === "HookStatusChanged" &&
        expected.zhixuId === observed.zhixuId &&
        expected.orderId === observed.orderId &&
        expected.hookId === observed.hookId &&
        expected.status === observed.status &&
        expected.dueAt === observed.dueAt
      );
    default:
      return assertNever(expected);
  }
}

function assertNever(value: never): never {
  throw new Error(`unsupported chain-mode value ${JSON.stringify(value)}`);
}

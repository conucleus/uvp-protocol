import { replayWithUvpCore } from "@uvp-eth/hook-core";

export type HexString = `0x${string}`;

export type ChainModeEvent =
  | ChainPlanRegisteredEvent
  | ChainOrderRegisteredEvent
  | ChainOrderMaterializedEvent
  | ChainOrderTriggeredEvent
  | ChainOrderLinkedEvent
  | ChainSignalSubmittedEvent
  | ChainStageMaterializedEvent
  | ChainHookStatusChangedEvent
  | ChainHookReadyEvent
  | ChainTimerPokedEvent;

export type ChainModeInputEvent =
  | ChainPlanRegisteredEvent
  | ChainOrderRegisteredEvent
  | ChainSignalSubmittedEvent
  | ChainTimerPokedEvent;

export type ChainModeExpectedEvent = ChainHookStatusChangedEvent | ChainHookReadyEvent;
export type ChainObservableHookStatus = "wait" | "cxl";
export type ChainOracleHookStatus = "init" | "wait" | "reg" | "cxl";

export interface ChainEventBase {
  readonly eventName: string;
  readonly blockNumber: number;
  readonly transactionIndex?: number;
  readonly logIndex: number;
  readonly transactionHash: `0x${string}`;
  readonly contractAddress?: `0x${string}`;
}

export interface ChainPlanRegisteredEvent extends ChainEventBase {
  readonly eventName: "PlanRegistered";
  readonly plan: ChainOraclePlan;
}

export interface ChainOraclePlan {
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly version: string;
  readonly compiledHooks: readonly ChainOracleHook[];
  readonly dependencyIndex: Record<HexString, readonly HexString[]>;
}

export interface ChainOracleHook {
  readonly hookId: HexString;
  readonly stageId: HexString;
  readonly stageIdentifier: string;
  readonly hookName: string;
  readonly isTrigger: boolean;
  readonly instructions: readonly ChainOracleInstruction[];
}

export type ChainOracleInstruction =
  | {
      readonly op: "SIGNAL";
      readonly sourceId: HexString;
      readonly signalId: HexString;
      readonly signalKey: HexString;
    }
  | {
      readonly op: "NOT";
    }
  | {
      readonly op: "AND" | "OR";
      readonly arity: number;
    }
  | {
      readonly op: "DELAY";
      readonly delaySeconds: number;
    };

export interface ChainOrderRegisteredEvent extends ChainEventBase {
  readonly eventName: "OrderRegistered";
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly registeredAt: string;
}

export interface ChainOrderMaterializedEvent extends ChainEventBase {
  readonly eventName: "OrderMaterialized";
  readonly orderId: string;
  readonly planId: HexString;
  readonly stageId: string;
}

export interface ChainOrderTriggeredEvent extends ChainEventBase {
  readonly eventName: "OrderTriggered";
  readonly orderId: string;
  readonly planId: HexString;
  readonly triggerStageId: string;
  readonly sourceId: string;
  readonly signalId: string;
  readonly submitter: string;
}

export interface ChainOrderLinkedEvent extends ChainEventBase {
  readonly eventName: "OrderLinked";
  readonly triggeredOrderId: string;
  readonly triggerOriginOrderId: string;
  readonly triggerStageId: string;
  readonly originSourceId: string;
  readonly originSignalId: string;
}

export interface ChainSignalSubmittedEvent extends ChainEventBase {
  readonly eventName: "SignalSubmitted";
  readonly zhixuId: string;
  readonly orderId: string;
  readonly sourceId: HexString;
  readonly signalId: HexString;
  readonly signalKey: HexString;
  readonly senderId: string;
  readonly submittedAt: string;
  readonly source?: string;
  readonly stageIdentifier?: string;
  readonly signalName?: string;
  readonly idempotencyKey?: string;
  readonly traceId?: string;
  readonly payloadRef?: string;
}

export interface ChainStageMaterializedEvent extends ChainEventBase {
  readonly eventName: "StageMaterialized";
  readonly orderId: string;
  readonly stageId: string;
  readonly triggerHookId: string;
  readonly sourceId: string;
  readonly signalId: string;
}

export interface ChainHookStatusChangedEvent extends ChainEventBase {
  readonly eventName: "HookStatusChanged";
  /**
   * Frozen payload: HookStatusChanged(bytes32 orderId, bytes32 hookId,
   * uint8 previousStatus, uint8 newStatus, uint64 dueAt).
   * zhixuId below is indexer enrichment joined from the order registration,
   * never part of the emitted event.
   */
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly previousStatus: ChainOracleHookStatus;
  readonly newStatus: ChainOracleHookStatus;
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
  /**
   * Frozen payload: TimerPoked(bytes32 orderId, bytes32 hookId, uint64 dueAt).
   * zhixuId is indexer enrichment from the order registration. pokedAt is the
   * block timestamp of the poke transaction (also enrichment); the replay
   * oracle consumes it as the evaluation clock for this tick.
   */
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly dueAt: string;
  readonly pokedAt: string;
}

export type ChainHookObservation = ChainHookReadyObservation | ChainHookStatusChangedObservation;

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
}

export interface ChainReplayResult {
  readonly state: ChainOracleState;
  readonly expected: readonly ChainHookObservation[];
  readonly observed: readonly ChainHookObservation[];
  readonly mismatches: readonly ChainReplayMismatch[];
}

export interface ChainOracleState {
  readonly plans: Record<string, ChainOraclePlan>;
  readonly orders: Record<string, ChainOracleOrderState>;
}

export interface ChainOracleOrderState {
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly signals: Record<string, ChainOracleSignalRecord>;
  readonly hookStatuses: Record<string, ChainOracleHookRuntime>;
  readonly materializedStages: Record<string, boolean>;
}

export interface ChainOracleSignalRecord {
  readonly eventId: string;
  readonly sourceId: HexString;
  readonly signalId: HexString;
  readonly signalKey: HexString;
  readonly senderId: string;
  readonly submittedAt: string;
  readonly transactionIndex?: number;
}

export interface ChainOracleHookRuntime {
  readonly status: ChainOracleHookStatus;
  readonly dueAt?: string;
  readonly readyEmitted: boolean;
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

/**
 * The single exported replay entry point always validates strictly: any
 * mismatch between expected and observed hook observations throws
 * {@link ChainReplayMismatchError}. There is no option (and no exported
 * wrapper bypass) that yields a never-throwing replay; callers who need to
 * inspect raw mismatches can catch the error and read its `mismatches` field.
 */
export function replayChainEvents(
  events: readonly ChainModeEvent[],
  options: ChainReplayOptions = {}
): ChainReplayResult {
  const result = replayWithUvpCore({
    events: events.map(normalizeChainEventForOracle),
    options: {
      ...options,
      // The native layer collects structured mismatches instead of throwing
      // its own opaque error; this wrapper converts them into an explicit
      // throw so the exported surface cannot observe a lenient replay.
      strict: false
    }
  }) as ChainReplayResult;
  if (result.mismatches.length > 0) {
    throw new ChainReplayMismatchError(result.mismatches);
  }

  return result;
}

export function chainEventId(event: ChainEventBase): string {
  return `${event.blockNumber}:${event.logIndex}:${event.transactionHash}`;
}

/**
 * The replay oracle consumes the projected observation shape (single
 * `status`), while the frozen v0.8 chain event carries
 * previousStatus/newStatus. This adapter is the formal boundary between the
 * two contracts: v0.8 events are projected onto newStatus. A HookStatusChanged
 * event without a valid newStatus violates the frozen v0.8 contract and fails
 * loudly instead of passing through untouched.
 */
function normalizeChainEventForOracle(event: ChainModeEvent): Record<string, unknown> {
  if (event.eventName === "HookStatusChanged") {
    if (!("newStatus" in event) || typeof event.newStatus !== "string") {
      throw new Error(
        `HookStatusChanged ${event.hookId} is missing a valid newStatus; frozen v0.8 events must carry previousStatus/newStatus`
      );
    }
    const { previousStatus: _previousStatus, ...rest } = event;
    return { ...rest, status: event.newStatus };
  }
  return { ...event };
}

export function compareChainEvents(a: ChainEventBase, b: ChainEventBase): number {
  if (a.blockNumber !== b.blockNumber) {
    return a.blockNumber - b.blockNumber;
  }
  if (a.transactionIndex !== undefined && b.transactionIndex !== undefined &&
      a.transactionIndex !== b.transactionIndex) {
    return a.transactionIndex - b.transactionIndex;
  }
  return a.logIndex - b.logIndex || a.transactionHash.localeCompare(b.transactionHash);
}

export function chainEventToExpectedObservation(event: ChainModeExpectedEvent): ChainHookObservation {
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
    case "HookStatusChanged": {
      if (event.newStatus !== "wait" && event.newStatus !== "cxl") {
        throw new Error(
          `HookStatusChanged ${event.hookId} carries non-observable new status ${event.newStatus}; ready transitions are observed through HookReady`
        );
      }
      return {
        eventName: "HookStatusChanged",
        zhixuId: event.zhixuId,
        orderId: event.orderId,
        hookId: event.hookId,
        status: event.newStatus,
        ...(event.dueAt ? { dueAt: event.dueAt } : {})
      };
    }
    default:
      return assertNever(event);
  }
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
      mismatches.push({ index, reason: "unexpected-observed", observed: observedObservation });
      continue;
    }
    if (expectedObservation && !observedObservation) {
      mismatches.push({ index, reason: "missing-observed", expected: expectedObservation });
      continue;
    }
    if (expectedObservation && observedObservation && !sameHookObservation(expectedObservation, observedObservation)) {
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

function sameHookObservation(expected: ChainHookObservation, observed: ChainHookObservation): boolean {
  if (expected.eventName !== observed.eventName) {
    return false;
  }
  switch (expected.eventName) {
    case "HookReady":
      return (
        observed.eventName === "HookReady" &&
        expected.zhixuId === observed.zhixuId &&
        expected.orderId === observed.orderId &&
        expected.hookId.toLowerCase() === observed.hookId.toLowerCase() &&
        expected.stageIdentifier === observed.stageIdentifier &&
        expected.hookName === observed.hookName
      );
    case "HookStatusChanged":
      return (
        observed.eventName === "HookStatusChanged" &&
        expected.zhixuId === observed.zhixuId &&
        expected.orderId === observed.orderId &&
        expected.hookId.toLowerCase() === observed.hookId.toLowerCase() &&
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

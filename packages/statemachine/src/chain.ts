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
export type ChainOracleHookStatus = "init" | "wait" | "ready" | "cxl";

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
  readonly compiledHooks: readonly ChainOracleHook[];
  readonly dependencyIndex: Record<HexString, readonly HexString[]>;
  readonly admissions?: readonly ChainOracleAdmission[];
}

export interface ChainOracleAdmission {
  readonly admissionId: HexString;
  readonly stageIdentifier: string;
  readonly signalName: string;
  readonly instructions: readonly ChainOracleInstruction[];
}

export interface ChainOracleHook {
  readonly hookId: HexString;
  readonly stageId: HexString;
  readonly stageIdentifier: string;
  readonly hookName: string;
  readonly orderTriggerKind: "none" | "mint" | "dock";
  readonly emitReady: boolean;
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
  readonly triggerHookId: string;
  readonly sourceId: string;
  readonly signalId: string;
  readonly submitter: string;
}

export interface ChainOrderLinkedEvent extends ChainEventBase {
  readonly eventName: "OrderLinked";
  readonly planId: HexString;
  readonly triggeredOrderId: string;
  readonly triggerOriginOrderId: string;
  readonly originPlanId: HexString;
  readonly triggerStageId: string;
  readonly originSourceId: string;
  readonly originSignalId: string;
}

export interface ChainSignalSubmittedEvent extends ChainEventBase {
  readonly eventName: "SignalSubmitted";
  readonly planId: HexString;
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
  readonly planId: HexString;
  readonly orderId: string;
  readonly stageId: string;
  readonly triggerHookId: string;
  readonly sourceId: string;
  readonly signalId: string;
}

export interface ChainHookStatusChangedEvent extends ChainEventBase {
  readonly eventName: "HookStatusChanged";
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly previousStatus: ChainOracleHookStatus;
  readonly newStatus: ChainOracleHookStatus;
  readonly dueAt?: string;
}

export interface ChainHookReadyEvent extends ChainEventBase {
  readonly eventName: "HookReady";
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly stageIdentifier: string;
  readonly hookName: string;
}

export interface ChainTimerPokedEvent extends ChainEventBase {
  readonly eventName: "TimerPoked";
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly dueAt: string;
  readonly pokedAt: string;
}

export type ChainHookObservation = ChainHookReadyObservation | ChainHookStatusChangedObservation;

export interface ChainHookReadyObservation {
  readonly eventName: "HookReady";
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly stageIdentifier: string;
  readonly hookName: string;
}

export interface ChainHookStatusChangedObservation {
  readonly eventName: "HookStatusChanged";
  readonly planId: HexString;
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
}

export interface ChainOracleHookRuntime {
  readonly status: ChainOracleHookStatus;
  readonly dueAt?: string;
  readonly readyEmitted: boolean;
}

export interface ChainReplayMismatch {
  readonly index?: number;
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
  const sort = options.sort !== false;
  if (sort) {
    for (const event of events) {
      for (const key of ["blockNumber", "logIndex"] as const) {
        if (!Number.isInteger(event[key])) {
          throw new Error(
            `chain oracle event ${event.eventName} (sorting refuses to fold a non-integer to 0): ${key} must be an integer`
          );
        }
      }
    }
  }
  const ordered = sort ? [...events].sort(compareChainEvents) : events;
  const pokeGate = new TimerPokeGate();
  const normalized: readonly OracleFeedEvent[] = ordered
    .map((event) => {
      const pokeAllowed = pokeGate.admit(event);
      if (!pokeAllowed) {
        return undefined;
      }
      pokeGate.track(event);
      return normalizeChainEventForOracle(event);
    })
    .filter((event): event is OracleFeedEvent => event !== undefined);
  const result = replayWithUvpCore({
    events: normalized,
    options: {
      ...options,
      strict: false
    }
  }) as ChainReplayResult;
  if (result.mismatches.length > 0) {
    throw new ChainReplayMismatchError(result.mismatches);
  }

  return result;
}

interface TrackedHookRuntime {
  status: ChainOracleHookStatus;
  dueAt?: string;
}

class TimerPokeGate {
  private readonly runtimes = new Map<string, TrackedHookRuntime>();
  private readonly orders = new Set<string>();
  private readonly planHooks = new Map<string, ReadonlySet<string>>();

  admit(event: ChainModeEvent): boolean {
    if (event.eventName !== "TimerPoked") {
      return true;
    }
    if (!this.orders.has(orderRegistryKey(event))) {
      throw new Error(
        `chain oracle missing order ${event.planId}:${event.zhixuId}:${event.orderId}`,
      );
    }
    const hookIds = this.planHooks.get(event.planId);
    if (hookIds === undefined) {
      throw new Error(`chain oracle missing plan ${event.planId}`);
    }
    if (!hookIds.has(event.hookId)) {
      throw new Error(`chain oracle missing hook ${event.hookId}`);
    }
    if (typeof event.pokedAt !== "string") {
      throw new Error(
        `TimerPoked ${event.hookId} is missing a valid pokedAt; the replay evaluation clock is required`
      );
    }
    const runtime = this.runtimes.get(runtimeKey(event));
    if (runtime === undefined || runtime.status !== "wait" || runtime.dueAt === undefined) {
      return false;
    }
    const trackedDueAt = chainOracleTimestampSeconds(runtime.dueAt);
    if (trackedDueAt === undefined) {
      throw new Error(`invalid chain oracle timestamp ${runtime.dueAt}`);
    }
    const pokedAt = chainOracleTimestampSeconds(event.pokedAt);
    if (pokedAt === undefined) {
      throw new Error(`invalid chain oracle timestamp ${event.pokedAt}`);
    }
    if (event.dueAt !== undefined) {
      const eventDueAt = chainOracleTimestampSeconds(event.dueAt);
      if (eventDueAt === undefined || eventDueAt !== trackedDueAt) {
        return false;
      }
    }
    return pokedAt >= trackedDueAt;
  }

  track(event: ChainModeEvent): void {
    switch (event.eventName) {
      case "PlanRegistered": {
        const plan: unknown = event.plan;
        if (
          typeof plan !== "object" ||
          plan === null ||
          Array.isArray(plan) ||
          typeof (plan as { readonly planId?: unknown }).planId !== "string" ||
          !Array.isArray((plan as { readonly compiledHooks?: unknown }).compiledHooks)
        ) {
          return;
        }
        const hookIds = new Set<string>();
        for (const hook of (plan as { readonly compiledHooks: readonly unknown[] }).compiledHooks) {
          if (typeof hook === "object" && hook !== null) {
            const hookId = (hook as { readonly hookId?: unknown }).hookId;
            if (typeof hookId === "string") {
              hookIds.add(hookId);
            }
          }
        }
        this.planHooks.set(
          (plan as { readonly planId: string }).planId,
          hookIds,
        );
        return;
      }
      case "OrderRegistered": {
        this.orders.add(orderRegistryKey(event));
        return;
      }
      case "HookStatusChanged": {
        const newStatus = event.newStatus;
        if (newStatus === undefined) {
          return;
        }
        this.runtimes.set(runtimeKey(event), {
          status: newStatus,
          ...(event.dueAt === undefined || newStatus !== "wait"
            ? {}
            : { dueAt: event.dueAt }),
        });
        return;
      }
      case "HookReady": {
        this.runtimes.set(runtimeKey(event), { status: "ready" });
        return;
      }
      default:
        return;
    }
  }
}

function runtimeKey(event: {
  readonly planId: HexString;
  readonly orderId: string;
  readonly hookId: string;
}): string {
  return `${event.planId}::${event.orderId}::${event.hookId}`;
}

function orderRegistryKey(event: {
  readonly planId: HexString;
  readonly orderId: string;
}): string {
  return `${event.planId}::${event.orderId}`;
}

const RFC3339_STRICT_PATTERN =
  /^(\d{4})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(?:[Zz]|([+-\u2212])(\d{2}):(\d{2}))$/;

function chainOracleTimestampSeconds(value: string): number | undefined {
  const match = RFC3339_STRICT_PATTERN.exec(value);
  if (match === null) {
    return undefined;
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  const offsetSign = match[8];
  const offsetHour = Number(match[9] ?? "0");
  const offsetMinute = Number(match[10] ?? "0");
  if (
    month < 1 || month > 12 ||
    day < 1 || day > daysInMonth(year, month) ||
    hour > 23 || minute > 59 || second > 60 ||
    offsetHour > 23 || offsetMinute > 59
  ) {
    return undefined;
  }
  const localSeconds =
    daysFromCivil(year, month, day) * 86400 +
    hour * 3600 +
    minute * 60 +
    (second === 60 ? 59 : second);
  const negativeOffset = offsetSign === "-" || offsetSign === "\u2212";
  const offsetSeconds =
    (negativeOffset ? -1 : 1) * (offsetHour * 3600 + offsetMinute * 60);
  return localSeconds - offsetSeconds;
}

const MONTH_LENGTHS = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

function isGregorianLeapYear(year: number): boolean {
  return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
}

function daysInMonth(year: number, month: number): number {
  return month === 2 && isGregorianLeapYear(year) ? 29 : MONTH_LENGTHS[month - 1]!;
}

function daysFromCivil(year: number, month: number, day: number): number {
  const shiftedYear = year - (month <= 2 ? 1 : 0);
  const era = Math.floor(shiftedYear / 400);
  const yearOfEra = shiftedYear - era * 400;
  const dayOfYear =
    Math.floor((153 * (month + (month > 2 ? -3 : 9)) + 2) / 5) + day - 1;
  const dayOfEra =
    yearOfEra * 365 +
    Math.floor(yearOfEra / 4) -
    Math.floor(yearOfEra / 100) +
    dayOfYear;
  return era * 146097 + dayOfEra - 719468;
}

export function chainEventId(event: ChainEventBase): string {
  return `${event.blockNumber}:${event.logIndex}:${event.transactionHash}`;
}

type ProjectedHookStatusChangedEvent = Omit<ChainHookStatusChangedEvent, "previousStatus" | "newStatus"> & {
  readonly status: "wait" | "cxl";
};

type OracleFeedEvent = ChainModeEvent | ProjectedHookStatusChangedEvent;

function normalizeChainEventForOracle(event: ChainModeEvent): OracleFeedEvent | undefined {
  if (event.eventName === "HookStatusChanged") {
    if (!("newStatus" in event) || typeof event.newStatus !== "string") {
      throw new Error(
        `HookStatusChanged ${event.hookId} is missing a valid newStatus; frozen v0.10 events must carry previousStatus/newStatus`
      );
    }
    if (event.newStatus !== "wait" && event.newStatus !== "cxl") {
      if (event.newStatus === "ready" || event.newStatus === "init") {
        return undefined;
      }
      throw new Error(
        `HookStatusChanged ${event.hookId} carries unknown newStatus ${JSON.stringify(event.newStatus)}; frozen v0.10 statuses are init/wait/ready/cxl`
      );
    }
    const { previousStatus: _previousStatus, newStatus: _newStatus, ...rest } = event;
    return { ...rest, status: event.newStatus };
  }
  return { ...event };
}

export function compareChainEvents(a: ChainEventBase, b: ChainEventBase): number {
  if (a.blockNumber !== b.blockNumber) {
    return a.blockNumber - b.blockNumber;
  }
  return a.logIndex - b.logIndex;
}

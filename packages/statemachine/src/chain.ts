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
  readonly childOrderId: string;
  readonly parentOrderId: string;
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
  readonly strict?: boolean;
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
  const state: ChainOracleState = { plans: {}, orders: {} };
  const expected: ChainHookObservation[] = [];
  const observed: ChainHookObservation[] = [];

  for (const event of sorted) {
    switch (event.eventName) {
      case "PlanRegistered":
        state.plans[event.plan.planId] = event.plan;
        break;
      case "OrderRegistered":
        state.orders[orderKey(event.zhixuId, event.orderId)] = {
          planId: event.planId,
          zhixuId: event.zhixuId,
          orderId: event.orderId,
          signals: {},
          hookStatuses: {},
          materializedStages: {}
        };
        break;
      case "SignalSubmitted":
        observed.push(...recordSignalAndEvaluate(state, event));
        break;
      case "TimerPoked":
        observed.push(...evaluateTimerHook(state, event));
        break;
      case "HookReady":
      case "HookStatusChanged":
        expected.push(chainEventToExpectedObservation(event));
        break;
      case "OrderMaterialized":
      case "OrderTriggered":
      case "OrderLinked":
      case "StageMaterialized":
        break;
      default:
        assertNever(event);
    }
  }

  const mismatches = compareHookObservations(expected, observed);
  if ((options.strict ?? true) && mismatches.length > 0) {
    throw new ChainReplayMismatchError(mismatches);
  }

  return { state, expected, observed, mismatches };
}

export function chainEventId(event: ChainEventBase): string {
  return `${event.blockNumber}:${event.logIndex}:${event.transactionHash}`;
}

export function compareChainEvents(a: ChainEventBase, b: ChainEventBase): number {
  return a.blockNumber - b.blockNumber || a.logIndex - b.logIndex;
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

function recordSignalAndEvaluate(
  state: ChainOracleState,
  event: ChainSignalSubmittedEvent
): readonly ChainHookObservation[] {
  const order = state.orders[orderKey(event.zhixuId, event.orderId)];
  if (!order) {
    throw new Error(`chain oracle missing order ${event.zhixuId}:${event.orderId}`);
  }
  if (order.signals[event.signalKey]) {
    return [];
  }

  order.signals[event.signalKey] = {
    eventId: chainEventId(event),
    sourceId: event.sourceId,
    signalId: event.signalId,
    signalKey: event.signalKey,
    senderId: event.senderId,
    submittedAt: event.submittedAt
  };

  const plan = state.plans[order.planId];
  if (!plan) {
    throw new Error(`chain oracle missing plan ${order.planId}`);
  }

  const hookIds = plan.dependencyIndex[event.signalKey] ?? [];
  const hooks = hookIds.map((hookId) => findHook(plan, hookId));
  const observations: ChainHookObservation[] = [];
  for (const hook of hooks.filter((item) => item.isTrigger)) {
    observations.push(...evaluateHook(order, hook, event.submittedAt));
  }
  for (const hook of hooks.filter((item) => !item.isTrigger)) {
    observations.push(...evaluateHook(order, hook, event.submittedAt));
  }
  return observations;
}

function evaluateTimerHook(
  state: ChainOracleState,
  event: ChainTimerPokedEvent
): readonly ChainHookObservation[] {
  const order = state.orders[orderKey(event.zhixuId, event.orderId)];
  if (!order) {
    throw new Error(`chain oracle missing order ${event.zhixuId}:${event.orderId}`);
  }
  const plan = state.plans[order.planId];
  if (!plan) {
    throw new Error(`chain oracle missing plan ${order.planId}`);
  }
  return evaluateHook(order, findHook(plan, event.hookId), event.pokedAt);
}

function evaluateHook(
  order: ChainOracleOrderState,
  hook: ChainOracleHook,
  now: string
): readonly ChainHookObservation[] {
  const previous = order.hookStatuses[hook.hookId] ?? { status: "init", readyEmitted: false };
  if (previous.status === "cxl" || previous.status === "reg") {
    return [];
  }
  if (!hook.isTrigger && !order.materializedStages[hook.stageId]) {
    return [];
  }

  const result = evaluateInstructions(order, hook.instructions, now);
  const next: { status: ChainOracleHookStatus; dueAt?: string; readyEmitted: boolean } = {
    status: "init",
    readyEmitted: previous.readyEmitted
  };
  if (result.cancel) {
    next.status = "cxl";
  } else if (result.wait) {
    next.status = "wait";
    const dueAt = isoFromSeconds(result.dueAt);
    if (dueAt) {
      next.dueAt = dueAt;
    }
  } else if (result.value) {
    next.status = "reg";
  }
  order.hookStatuses[hook.hookId] = next;

  const observations: ChainHookObservation[] = [];
  if ((previous.status !== next.status || previous.dueAt !== next.dueAt) && next.status === "wait") {
    const waiting: ChainHookStatusChangedObservation = {
      eventName: "HookStatusChanged",
      zhixuId: order.zhixuId,
      orderId: order.orderId,
      hookId: hook.hookId,
      status: "wait",
      ...(next.dueAt ? { dueAt: next.dueAt } : {})
    };
    observations.push(waiting);
  }
  if (previous.status !== next.status && next.status === "cxl") {
    observations.push({
      eventName: "HookStatusChanged",
      zhixuId: order.zhixuId,
      orderId: order.orderId,
      hookId: hook.hookId,
      status: "cxl"
    });
  }
  if (next.status === "reg" && hook.isTrigger && !previous.readyEmitted) {
    next.readyEmitted = true;
    order.hookStatuses[hook.hookId] = next;
    order.materializedStages[hook.stageId] = true;
    observations.push({
      eventName: "HookReady",
      zhixuId: order.zhixuId,
      orderId: order.orderId,
      hookId: hook.hookId,
      stageIdentifier: hook.stageIdentifier,
      hookName: hook.hookName
    });
  }
  return observations;
}

function evaluateInstructions(
  order: ChainOracleOrderState,
  instructions: readonly ChainOracleInstruction[],
  now: string
): EvalValue {
  const stack: EvalValue[] = [];
  for (const instruction of instructions) {
    switch (instruction.op) {
      case "SIGNAL":
        stack.push(signalValue(order, instruction.signalKey));
        break;
      case "NOT":
        stack[stack.length - 1] = notValue(stack[stack.length - 1] ?? falseValue());
        break;
      case "DELAY":
        stack[stack.length - 1] = delayValue(stack[stack.length - 1] ?? falseValue(), instruction.delaySeconds, now);
        break;
      case "AND": {
        const terms = stack.splice(stack.length - instruction.arity, instruction.arity);
        stack.push(terms.reduce((left, right) => andValue(left, right)));
        break;
      }
      case "OR": {
        const terms = stack.splice(stack.length - instruction.arity, instruction.arity);
        stack.push(terms.reduce((left, right) => orValue(left, right)));
        break;
      }
      default:
        assertNever(instruction);
    }
  }
  return stack[0] ?? falseValue();
}

interface EvalValue {
  readonly value: boolean;
  readonly wait: boolean;
  readonly cancel: boolean;
  readonly dueAt: number;
  readonly anchorAt: number;
}

function signalValue(order: ChainOracleOrderState, signalKey: string): EvalValue {
  const signal = order.signals[signalKey];
  if (!signal) {
    return falseValue();
  }
  return { value: true, wait: false, cancel: false, dueAt: 0, anchorAt: secondsFromIso(signal.submittedAt) };
}

function falseValue(): EvalValue {
  return { value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0 };
}

function notValue(value: EvalValue): EvalValue {
  if (value.value || value.wait) {
    return { value: false, wait: false, cancel: true, dueAt: 0, anchorAt: 0 };
  }
  return { value: true, wait: false, cancel: false, dueAt: 0, anchorAt: 0 };
}

function delayValue(value: EvalValue, delaySeconds: number, now: string): EvalValue {
  if (value.cancel || !value.value) {
    return value;
  }
  const dueAt = value.anchorAt + delaySeconds;
  if (secondsFromIso(now) < dueAt) {
    return { value: false, wait: true, cancel: false, dueAt, anchorAt: value.anchorAt };
  }
  return { value: true, wait: false, cancel: false, dueAt: 0, anchorAt: value.anchorAt };
}

function andValue(left: EvalValue, right: EvalValue): EvalValue {
  if (left.cancel || right.cancel) {
    return { value: false, wait: false, cancel: true, dueAt: 0, anchorAt: 0 };
  }
  if (left.value && right.value) {
    return { value: true, wait: false, cancel: false, dueAt: 0, anchorAt: Math.max(left.anchorAt, right.anchorAt) };
  }
  if ((left.wait && (right.value || right.wait)) || (right.wait && (left.value || left.wait))) {
    return {
      value: false,
      wait: true,
      cancel: false,
      dueAt: Math.max(left.dueAt, right.dueAt),
      anchorAt: Math.max(left.anchorAt, right.anchorAt)
    };
  }
  return falseValue();
}

function orValue(left: EvalValue, right: EvalValue): EvalValue {
  if (left.value || right.value) {
    return { value: true, wait: false, cancel: false, dueAt: 0, anchorAt: Math.max(left.anchorAt, right.anchorAt) };
  }
  if (left.wait || right.wait) {
    return {
      value: false,
      wait: true,
      cancel: false,
      dueAt: minNonZero(left.dueAt, right.dueAt),
      anchorAt: Math.max(left.anchorAt, right.anchorAt)
    };
  }
  if (left.cancel && right.cancel) {
    return { value: false, wait: false, cancel: true, dueAt: 0, anchorAt: 0 };
  }
  return falseValue();
}

function minNonZero(left: number, right: number): number {
  if (left === 0) {
    return right;
  }
  if (right === 0) {
    return left;
  }
  return Math.min(left, right);
}

function findHook(plan: ChainOraclePlan, hookId: string): ChainOracleHook {
  const hook = plan.compiledHooks.find((item) => item.hookId.toLowerCase() === hookId.toLowerCase());
  if (!hook) {
    throw new Error(`chain oracle missing hook ${hookId}`);
  }
  return hook;
}

function orderKey(zhixuId: string, orderId: string): string {
  return `${zhixuId}::${orderId}`;
}

function secondsFromIso(value: string): number {
  const milliseconds = Date.parse(value);
  if (Number.isNaN(milliseconds)) {
    throw new Error(`invalid chain oracle timestamp ${value}`);
  }
  return Math.floor(milliseconds / 1000);
}

function isoFromSeconds(value: number | undefined): string | undefined {
  return value === undefined || value === 0 ? undefined : new Date(value * 1000).toISOString();
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

import {
  evaluateHook,
  signalKey,
  type HookDependency,
  type HookEvaluation,
  type HookExpressionAst,
  type SignalIndex
} from "@uvp-eth/hook-core";

export class RuntimeTransitionError extends Error {
  readonly eventType: string;

  constructor(eventType: string, message: string) {
    super(`${eventType}: ${message}`);
    this.name = "RuntimeTransitionError";
    this.eventType = eventType;
  }
}

export type HookRuntimeStatus = "init" | "wait" | "reg" | "dispatched" | "fail" | "cxl";

export interface RuntimeHookPlan {
  readonly planId: `0x${string}`;
  readonly zhixuId: string;
  readonly version: string;
  readonly compiledHooks: readonly RuntimeCompiledHook[];
  readonly dependencyIndex: Record<string, readonly string[]>;
}

export interface RuntimeCompiledHook {
  readonly hookId: string;
  readonly kind: "receive" | "signalMap";
  readonly stageIdentifier: string;
  readonly hookName: string;
  readonly trigger: boolean;
  readonly ast: HookExpressionAst;
  readonly dependencies: readonly HookDependency[];
  readonly route?: unknown;
}

export type RuntimeEvent =
  | PlanRegisteredEvent
  | OrderRegisteredEvent
  | SignalReceivedEvent
  | TimerDueEvent
  | DispatchSucceededEvent
  | DispatchFailedEvent
  | ExecutorPatchedEvent;

export interface RuntimeEventBase {
  readonly eventId: string;
  readonly type: string;
}

export interface PlanRegisteredEvent extends RuntimeEventBase {
  readonly type: "PlanRegistered";
  readonly plan: RuntimeHookPlan;
}

export interface OrderRegisteredEvent extends RuntimeEventBase {
  readonly type: "OrderRegistered";
  readonly planId: `0x${string}`;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly receivedAt: string;
}

export interface SignalReceivedEvent extends RuntimeEventBase {
  readonly type: "SignalReceived";
  readonly zhixuId: string;
  readonly orderId: string;
  readonly source: string;
  readonly stageIdentifier: string;
  readonly signalName: string;
  readonly senderId: string;
  readonly receivedAt: string;
  readonly idempotencyKey?: string;
  readonly traceId?: string;
  readonly payloadRef?: string;
}

export interface TimerDueEvent extends RuntimeEventBase {
  readonly type: "TimerDue";
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly now: string;
}

export interface DispatchSucceededEvent extends RuntimeEventBase {
  readonly type: "DispatchSucceeded";
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly receivedAt: string;
}

export interface DispatchFailedEvent extends RuntimeEventBase {
  readonly type: "DispatchFailed";
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly receivedAt: string;
  readonly error: string;
}

export interface ExecutorPatchedEvent extends RuntimeEventBase {
  readonly type: "ExecutorPatched";
  readonly zhixuId: string;
  readonly orderId: string;
  readonly stageIdentifier: string;
  readonly patchRef: string;
  readonly receivedAt: string;
}

export type RuntimeEffect =
  | HookWaitingEffect
  | HookReadyEffect
  | HookCancelledEffect;

export interface RuntimeEffectBase {
  readonly type: string;
  readonly eventId: string;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
}

export interface HookWaitingEffect extends RuntimeEffectBase {
  readonly type: "HookWaiting";
  readonly dueAt: string;
}

export interface HookReadyEffect extends RuntimeEffectBase {
  readonly type: "HookReady";
  readonly stageIdentifier: string;
  readonly hookName: string;
}

export interface HookCancelledEffect extends RuntimeEffectBase {
  readonly type: "HookCancelled";
  readonly reason: string;
}

export interface RuntimeState {
  readonly plans: Record<string, RuntimeHookPlan>;
  readonly orders: Record<string, RuntimeOrderState>;
  readonly replay: {
    readonly appliedEventIds: readonly string[];
  };
  readonly effects: readonly RuntimeEffect[];
}

export interface RuntimeOrderState {
  readonly zhixuId: string;
  readonly orderId: string;
  readonly planId: `0x${string}`;
  readonly status: "registered" | "running";
  readonly signals: Record<string, RuntimeSignalRecord>;
  readonly idempotencyKeys: Record<string, string>;
  readonly hookStatuses: Record<string, RuntimeHookStatusRecord>;
  readonly dispatchAttempts: Record<string, number>;
  readonly executorPatches: Record<string, RuntimeExecutorPatchRecord>;
}

export interface RuntimeSignalRecord {
  readonly source: string;
  readonly stageIdentifier: string;
  readonly signalName: string;
  readonly senderId: string;
  readonly receivedAt: string;
  readonly eventId: string;
  readonly idempotencyKey?: string;
  readonly traceId?: string;
  readonly payloadRef?: string;
}

export interface RuntimeHookStatusRecord {
  readonly hookId: string;
  readonly status: HookRuntimeStatus;
  readonly updatedAt: string;
  readonly dueAt?: string;
  readonly lastError?: string;
}

export interface RuntimeExecutorPatchRecord {
  readonly stageIdentifier: string;
  readonly patchRef: string;
  readonly receivedAt: string;
  readonly eventId: string;
}

export function emptyRuntimeState(): RuntimeState {
  return {
    plans: {},
    orders: {},
    replay: {
      appliedEventIds: []
    },
    effects: []
  };
}

export function replayRuntimeEvents(events: readonly RuntimeEvent[]): RuntimeState {
  return events.reduce((state, event) => applyRuntimeEvent(state, event), emptyRuntimeState());
}

export function applyRuntimeEvent(current: RuntimeState, event: RuntimeEvent): RuntimeState {
  if (current.replay.appliedEventIds.includes(event.eventId)) {
    return current;
  }

  const state = cloneState(current);
  const newEffects: RuntimeEffect[] = [];

  switch (event.type) {
    case "PlanRegistered":
      state.plans[event.plan.planId] = normalizePlan(event.plan) as Mutable<RuntimeHookPlan>;
      break;
    case "OrderRegistered":
      applyOrderRegistered(state, event);
      break;
    case "SignalReceived":
      applySignalReceived(state, event, newEffects);
      break;
    case "TimerDue":
      applyTimerDue(state, event, newEffects);
      break;
    case "DispatchSucceeded":
      applyDispatchSucceeded(state, event);
      break;
    case "DispatchFailed":
      applyDispatchFailed(state, event);
      break;
    case "ExecutorPatched":
      applyExecutorPatched(state, event);
      break;
    default:
      assertNever(event);
  }

  return {
    ...state,
    replay: {
      appliedEventIds: [...state.replay.appliedEventIds, event.eventId]
    },
    effects: [...state.effects, ...newEffects]
  };
}

function applyOrderRegistered(state: Mutable<RuntimeState>, event: OrderRegisteredEvent): void {
  const plan = state.plans[event.planId];
  if (!plan) {
    throw new RuntimeTransitionError(event.type, `unknown plan ${event.planId}`);
  }
  const key = orderKey(event.zhixuId, event.orderId);
  if (state.orders[key]) {
    throw new RuntimeTransitionError(event.type, `order already registered ${key}`);
  }
  state.orders[key] = {
    zhixuId: event.zhixuId,
    orderId: event.orderId,
    planId: event.planId,
    status: "registered",
    signals: {},
    idempotencyKeys: {},
    hookStatuses: Object.fromEntries(
      plan.compiledHooks.map((hook) => [
        hook.hookId,
        {
          hookId: hook.hookId,
          status: "init" as const,
          updatedAt: event.receivedAt
        }
      ])
    ),
    dispatchAttempts: {},
    executorPatches: {}
  };
}

function applySignalReceived(
  state: Mutable<RuntimeState>,
  event: SignalReceivedEvent,
  effects: RuntimeEffect[]
): void {
  const order = requireOrder(state, event);
  const key = signalKey(event.source, event.signalName);

  if (event.idempotencyKey && order.idempotencyKeys[event.idempotencyKey]) {
    return;
  }
  if (order.signals[key]) {
    return;
  }

  order.signals[key] = {
    source: event.source,
    stageIdentifier: event.stageIdentifier,
    signalName: event.signalName,
    senderId: event.senderId,
    receivedAt: event.receivedAt,
    eventId: event.eventId,
    ...(event.idempotencyKey ? { idempotencyKey: event.idempotencyKey } : {}),
    ...(event.traceId ? { traceId: event.traceId } : {}),
    ...(event.payloadRef ? { payloadRef: event.payloadRef } : {})
  };
  if (event.idempotencyKey) {
    order.idempotencyKeys[event.idempotencyKey] = key;
  }
  order.status = "running";

  const plan = requirePlan(state, order.planId, event.type);
  const hookIds = plan.dependencyIndex[key] ?? [];
  evaluateHooks(state, order, plan, hookIds, event.receivedAt, event.eventId, effects);
}

function applyTimerDue(
  state: Mutable<RuntimeState>,
  event: TimerDueEvent,
  effects: RuntimeEffect[]
): void {
  const order = requireOrder(state, event);
  const hookStatus = order.hookStatuses[event.hookId];
  if (!hookStatus || hookStatus.status !== "wait") {
    return;
  }
  if (hookStatus.dueAt && new Date(event.now).getTime() < new Date(hookStatus.dueAt).getTime()) {
    return;
  }
  const plan = requirePlan(state, order.planId, event.type);
  evaluateHooks(state, order, plan, [event.hookId], event.now, event.eventId, effects);
}

function applyDispatchSucceeded(
  state: Mutable<RuntimeState>,
  event: DispatchSucceededEvent
): void {
  const order = requireOrder(state, event);
  const hookStatus = requireHookStatus(order, event.hookId, event.type);
  if (hookStatus.status !== "reg") {
    throw new RuntimeTransitionError(event.type, `dispatch success requires reg, got ${hookStatus.status}`);
  }
  order.hookStatuses[event.hookId] = {
    hookId: event.hookId,
    status: "dispatched",
    updatedAt: event.receivedAt
  };
}

function applyDispatchFailed(
  state: Mutable<RuntimeState>,
  event: DispatchFailedEvent
): void {
  const order = requireOrder(state, event);
  const hookStatus = requireHookStatus(order, event.hookId, event.type);
  if (hookStatus.status !== "reg") {
    throw new RuntimeTransitionError(event.type, `dispatch failure requires reg, got ${hookStatus.status}`);
  }
  order.dispatchAttempts[event.hookId] = (order.dispatchAttempts[event.hookId] ?? 0) + 1;
  order.hookStatuses[event.hookId] = {
    hookId: event.hookId,
    status: "fail",
    updatedAt: event.receivedAt,
    lastError: event.error
  };
}

function applyExecutorPatched(
  state: Mutable<RuntimeState>,
  event: ExecutorPatchedEvent
): void {
  const order = requireOrder(state, event);
  order.executorPatches[event.stageIdentifier] = {
    stageIdentifier: event.stageIdentifier,
    patchRef: event.patchRef,
    receivedAt: event.receivedAt,
    eventId: event.eventId
  };
}

function evaluateHooks(
  state: Mutable<RuntimeState>,
  order: Mutable<RuntimeOrderState>,
  plan: RuntimeHookPlan,
  hookIds: readonly string[],
  now: string,
  eventId: string,
  effects: RuntimeEffect[]
): void {
  const signalIndex = buildSignalIndex(order);
  const hooksById = new Map(plan.compiledHooks.map((hook) => [hook.hookId, hook]));
  for (const hookId of hookIds) {
    const hook = hooksById.get(hookId);
    if (!hook) {
      throw new RuntimeTransitionError("HookEvaluation", `unknown hook ${hookId}`);
    }
    const current = requireHookStatus(order, hookId, "HookEvaluation");
    if (isEvaluatorTerminal(current.status)) {
      continue;
    }
    const evaluated = evaluateHook(hook.ast, signalIndex, now);
    applyHookEvaluation(state, order, hook, current, evaluated, now, eventId, effects);
  }
}

function applyHookEvaluation(
  _state: Mutable<RuntimeState>,
  order: Mutable<RuntimeOrderState>,
  hook: RuntimeCompiledHook,
  current: RuntimeHookStatusRecord,
  evaluated: HookEvaluation,
  now: string,
  eventId: string,
  effects: RuntimeEffect[]
): void {
  switch (evaluated.status) {
    case "init":
      order.hookStatuses[hook.hookId] = {
        hookId: hook.hookId,
        status: "init",
        updatedAt: now
      };
      break;
    case "wait":
      order.hookStatuses[hook.hookId] = {
        hookId: hook.hookId,
        status: "wait",
        updatedAt: now,
        dueAt: evaluated.dueAt
      };
      if (current.status !== "wait" || current.dueAt !== evaluated.dueAt) {
        effects.push({
          type: "HookWaiting",
          eventId,
          zhixuId: order.zhixuId,
          orderId: order.orderId,
          hookId: hook.hookId,
          dueAt: evaluated.dueAt
        });
      }
      break;
    case "reg":
      if (current.status === "reg") {
        order.hookStatuses[hook.hookId] = {
          hookId: hook.hookId,
          status: "reg",
          updatedAt: current.updatedAt
        };
        break;
      }
      order.hookStatuses[hook.hookId] = {
        hookId: hook.hookId,
        status: "reg",
        updatedAt: now
      };
      effects.push({
        type: "HookReady",
        eventId,
        zhixuId: order.zhixuId,
        orderId: order.orderId,
        hookId: hook.hookId,
        stageIdentifier: hook.stageIdentifier,
        hookName: hook.hookName
      });
      break;
    case "cxl":
      order.hookStatuses[hook.hookId] = {
        hookId: hook.hookId,
        status: "cxl",
        updatedAt: now,
        lastError: evaluated.reason
      };
      effects.push({
        type: "HookCancelled",
        eventId,
        zhixuId: order.zhixuId,
        orderId: order.orderId,
        hookId: hook.hookId,
        reason: evaluated.reason
      });
      break;
    default:
      assertNever(evaluated);
  }
}

function buildSignalIndex(order: RuntimeOrderState): SignalIndex {
  return Object.fromEntries(
    Object.entries(order.signals).map(([key, signal]) => [
      key,
      {
        source: signal.source,
        signalName: signal.signalName,
        receivedAt: signal.receivedAt
      }
    ])
  );
}

function requireOrder(
  state: RuntimeState,
  event: Extract<RuntimeEvent, { zhixuId: string; orderId: string }>
): Mutable<RuntimeOrderState> {
  const order = state.orders[orderKey(event.zhixuId, event.orderId)];
  if (!order) {
    throw new RuntimeTransitionError(event.type, `unknown order ${event.zhixuId}/${event.orderId}`);
  }
  return order as Mutable<RuntimeOrderState>;
}

function requirePlan(
  state: RuntimeState,
  planId: `0x${string}`,
  eventType: string
): RuntimeHookPlan {
  const plan = state.plans[planId];
  if (!plan) {
    throw new RuntimeTransitionError(eventType, `unknown plan ${planId}`);
  }
  return plan;
}

function requireHookStatus(
  order: RuntimeOrderState,
  hookId: string,
  eventType: string
): RuntimeHookStatusRecord {
  const hookStatus = order.hookStatuses[hookId];
  if (!hookStatus) {
    throw new RuntimeTransitionError(eventType, `unknown hook ${hookId}`);
  }
  return hookStatus;
}

function normalizePlan(plan: RuntimeHookPlan): RuntimeHookPlan {
  return {
    ...plan,
    compiledHooks: [...plan.compiledHooks].sort((left, right) => left.hookId.localeCompare(right.hookId)),
    dependencyIndex: Object.fromEntries(
      Object.entries(plan.dependencyIndex)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, hookIds]) => [key, [...hookIds].sort()])
    )
  };
}

function isEvaluatorTerminal(status: HookRuntimeStatus): boolean {
  return status === "dispatched" || status === "fail" || status === "cxl";
}

function orderKey(zhixuId: string, orderId: string): string {
  return `${zhixuId}::${orderId}`;
}

function cloneState(state: RuntimeState): Mutable<RuntimeState> {
  return structuredClone(state) as Mutable<RuntimeState>;
}

function assertNever(value: never): never {
  throw new RuntimeTransitionError("Runtime", `unsupported value ${JSON.stringify(value)}`);
}

type Mutable<T> = {
  -readonly [P in keyof T]: T[P] extends object ? Mutable<T[P]> : T[P];
};

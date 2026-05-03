import {
  RuntimeTransitionError,
  applyRuntimeEvent,
  emptyRuntimeState,
  replayRuntimeEvents,
  type DispatchFailedEvent,
  type DispatchSucceededEvent,
  type HookReadyEffect,
  type HookWaitingEffect,
  type OrderRegisteredEvent,
  type PlanRegisteredEvent,
  type RuntimeEffect,
  type RuntimeEvent,
  type RuntimeHookPlan,
  type RuntimeOrderState,
  type RuntimeState,
  type SignalReceivedEvent,
  type TimerDueEvent
} from "@uvp-eth/statemachine";
import type {
  PendingDispatch,
  PendingTimer,
  RuntimeDispatcher,
  RuntimeEventStore,
  RuntimeHostOptions,
  RuntimeHostSnapshot,
  RuntimeOrderRegistration,
  RuntimePlanInput,
  SignalEnvelope
} from "./types.js";

export class RuntimeHostError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RuntimeHostError";
  }
}

export class InMemoryRuntimeEventStore implements RuntimeEventStore {
  private readonly events: RuntimeEvent[];

  constructor(events: readonly RuntimeEvent[] = []) {
    this.events = [...events];
  }

  async append(event: RuntimeEvent): Promise<void> {
    this.events.push(structuredClone(event));
  }

  async load(): Promise<readonly RuntimeEvent[]> {
    return structuredClone(this.events);
  }
}

export class RuntimeHost {
  private state: RuntimeState = emptyRuntimeState();
  private eventSequence = 0;
  private readonly store: RuntimeEventStore;
  private readonly dispatcher: RuntimeDispatcher;
  private readonly now: () => string;
  private readonly eventIdPrefix: string;
  private readonly pendingDispatches = new Map<string, PendingDispatch>();
  private readonly pendingTimers = new Map<string, PendingTimer>();

  private constructor(options: Required<RuntimeHostOptions>) {
    this.store = options.store;
    this.dispatcher = options.dispatcher;
    this.now = options.now;
    this.eventIdPrefix = options.eventIdPrefix;
  }

  static async create(options: RuntimeHostOptions = {}): Promise<RuntimeHost> {
    const host = new RuntimeHost({
      store: options.store ?? new InMemoryRuntimeEventStore(),
      dispatcher: options.dispatcher ?? new NoopRuntimeDispatcher(),
      now: options.now ?? (() => new Date().toISOString()),
      eventIdPrefix: options.eventIdPrefix ?? "runtime-host"
    });
    await host.reload();
    return host;
  }

  snapshot(): RuntimeHostSnapshot {
    return {
      state: structuredClone(this.state),
      pendingDispatches: this.getPendingDispatches(),
      pendingTimers: this.getPendingTimers()
    };
  }

  getState(): RuntimeState {
    return structuredClone(this.state);
  }

  getPendingDispatches(): readonly PendingDispatch[] {
    return [...this.pendingDispatches.values()].sort(comparePendingEffects);
  }

  getPendingTimers(): readonly PendingTimer[] {
    return [...this.pendingTimers.values()].sort(comparePendingTimers);
  }

  async getEvents(): Promise<readonly RuntimeEvent[]> {
    return this.store.load();
  }

  async replay(): Promise<RuntimeState> {
    return replayRuntimeEvents(await this.store.load());
  }

  async reload(): Promise<RuntimeState> {
    const events = await this.store.load();
    this.state = replayRuntimeEvents(events);
    this.eventSequence = events.length;
    this.rebuildRuntimeProjections();
    return this.getState();
  }

  async registerPlan(plan: RuntimePlanInput): Promise<RuntimeState> {
    const runtimePlan = toRuntimeHookPlan(plan);
    return this.commit({
      eventId: this.nextEventId("PlanRegistered"),
      type: "PlanRegistered",
      plan: runtimePlan
    });
  }

  async registerOrder(order: RuntimeOrderRegistration): Promise<RuntimeState> {
    requireNonEmpty(order.planId, "planId");
    requireNonEmpty(order.zhixuId, "zhixuId");
    requireNonEmpty(order.orderId, "orderId");

    return this.commit({
      eventId: this.nextEventId("OrderRegistered"),
      type: "OrderRegistered",
      planId: order.planId,
      zhixuId: order.zhixuId,
      orderId: order.orderId,
      receivedAt: order.receivedAt ?? this.now()
    });
  }

  async receiveSignal(envelope: SignalEnvelope): Promise<RuntimeState> {
    validateSignalEnvelope(envelope);
    const event: SignalReceivedEvent = {
      eventId: this.nextEventId("SignalReceived"),
      type: "SignalReceived",
      zhixuId: envelope.zhixuId,
      orderId: envelope.orderId,
      source: envelope.source,
      stageIdentifier: envelope.stageIdentifier,
      signalName: envelope.signalName,
      senderId: envelope.senderId,
      receivedAt: envelope.receivedAt ?? this.now(),
      ...(envelope.idempotencyKey ? { idempotencyKey: envelope.idempotencyKey } : {}),
      ...(envelope.traceId ? { traceId: envelope.traceId } : {}),
      ...(envelope.payloadRef ? { payloadRef: envelope.payloadRef } : {})
    };

    return this.commit(event);
  }

  async runDueTimers(now = this.now()): Promise<readonly TimerDueEvent[]> {
    const due = this.getPendingTimers().filter(
      (timer) => new Date(timer.dueAt).getTime() <= new Date(now).getTime()
    );
    const events: TimerDueEvent[] = [];
    for (const timer of due) {
      const event: TimerDueEvent = {
        eventId: this.nextEventId("TimerDue"),
        type: "TimerDue",
        zhixuId: timer.zhixuId,
        orderId: timer.orderId,
        hookId: timer.hookId,
        now
      };
      await this.commit(event);
      events.push(event);
    }
    return events;
  }

  async drainDispatchQueue(): Promise<readonly RuntimeEvent[]> {
    const results: RuntimeEvent[] = [];
    while (this.pendingDispatches.size > 0) {
      const dispatch = this.getPendingDispatches()[0];
      if (!dispatch) {
        break;
      }
      this.pendingDispatches.delete(pendingKey(dispatch.zhixuId, dispatch.orderId, dispatch.hookId));
      if (!this.isHookDispatchable(dispatch)) {
        continue;
      }

      const result = await this.dispatcher.dispatch(dispatch, { state: this.getState() });
      const event: DispatchSucceededEvent | DispatchFailedEvent =
        result.status === "succeeded"
          ? {
              eventId: this.nextEventId("DispatchSucceeded"),
              type: "DispatchSucceeded",
              zhixuId: dispatch.zhixuId,
              orderId: dispatch.orderId,
              hookId: dispatch.hookId,
              receivedAt: this.now()
            }
          : {
              eventId: this.nextEventId("DispatchFailed"),
              type: "DispatchFailed",
              zhixuId: dispatch.zhixuId,
              orderId: dispatch.orderId,
              hookId: dispatch.hookId,
              receivedAt: this.now(),
              error: result.error
            };
      await this.commit(event);
      results.push(event);

      if (result.status === "succeeded" && result.signals) {
        for (const signal of result.signals) {
          await this.receiveSignal({
            ...signal,
            receivedAt: signal.receivedAt ?? this.now()
          });
        }
      }
    }
    return results;
  }

  private async commit(event: RuntimeEvent): Promise<RuntimeState> {
    const previousEffectsLength = this.state.effects.length;
    const nextState = applyRuntimeEvent(this.state, event);
    const newEffects = nextState.effects.slice(previousEffectsLength);
    await this.store.append(event);
    this.state = nextState;
    this.projectEffects(newEffects);
    return this.getState();
  }

  private projectEffects(effects: readonly RuntimeEffect[]): void {
    for (const effect of effects) {
      const key = pendingKey(effect.zhixuId, effect.orderId, effect.hookId);
      switch (effect.type) {
        case "HookReady":
          this.pendingTimers.delete(key);
          if (this.isHookDispatchable(effect)) {
            this.pendingDispatches.set(key, effect);
          }
          break;
        case "HookWaiting":
          if (this.isHookWaiting(effect)) {
            this.pendingTimers.set(key, effect);
          }
          break;
        case "HookCancelled":
          this.pendingTimers.delete(key);
          this.pendingDispatches.delete(key);
          break;
        default:
          assertNever(effect);
      }
    }
  }

  private rebuildRuntimeProjections(): void {
    this.pendingDispatches.clear();
    this.pendingTimers.clear();
    for (const order of Object.values(this.state.orders)) {
      const plan = this.state.plans[order.planId];
      if (!plan) {
        continue;
      }
      const hooksById = new Map(plan.compiledHooks.map((hook) => [hook.hookId, hook]));
      for (const hookStatus of Object.values(order.hookStatuses)) {
        const hook = hooksById.get(hookStatus.hookId);
        if (!hook) {
          continue;
        }
        if (hookStatus.status === "reg") {
          this.pendingDispatches.set(pendingKey(order.zhixuId, order.orderId, hook.hookId), {
            type: "HookReady",
            eventId: `replay:${order.zhixuId}:${order.orderId}:${hook.hookId}`,
            zhixuId: order.zhixuId,
            orderId: order.orderId,
            hookId: hook.hookId,
            stageIdentifier: hook.stageIdentifier,
            hookName: hook.hookName
          });
        } else if (hookStatus.status === "wait" && hookStatus.dueAt) {
          this.pendingTimers.set(pendingKey(order.zhixuId, order.orderId, hook.hookId), {
            type: "HookWaiting",
            eventId: `replay:${order.zhixuId}:${order.orderId}:${hook.hookId}`,
            zhixuId: order.zhixuId,
            orderId: order.orderId,
            hookId: hook.hookId,
            dueAt: hookStatus.dueAt
          });
        }
      }
    }
  }

  private isHookDispatchable(effect: Pick<HookReadyEffect, "zhixuId" | "orderId" | "hookId">): boolean {
    const hookStatus = this.findOrder(effect)?.hookStatuses[effect.hookId];
    return hookStatus?.status === "reg";
  }

  private isHookWaiting(effect: Pick<HookWaitingEffect, "zhixuId" | "orderId" | "hookId" | "dueAt">): boolean {
    const hookStatus = this.findOrder(effect)?.hookStatuses[effect.hookId];
    return hookStatus?.status === "wait" && hookStatus.dueAt === effect.dueAt;
  }

  private findOrder(effect: Pick<HookReadyEffect, "zhixuId" | "orderId">): RuntimeOrderState | undefined {
    return this.state.orders[`${effect.zhixuId}::${effect.orderId}`];
  }

  private nextEventId(type: RuntimeEvent["type"]): string {
    this.eventSequence += 1;
    return `${this.eventIdPrefix}:${this.eventSequence}:${type}`;
  }
}

class NoopRuntimeDispatcher implements RuntimeDispatcher {
  async dispatch(): Promise<{ readonly status: "succeeded" }> {
    return { status: "succeeded" };
  }
}

function toRuntimeHookPlan(plan: RuntimePlanInput): RuntimeHookPlan {
  return {
    planId: plan.planId,
    zhixuId: plan.zhixuId,
    version: plan.version,
    compiledHooks: plan.compiledHooks,
    dependencyIndex: plan.dependencyIndex
  };
}

function validateSignalEnvelope(envelope: SignalEnvelope): void {
  requireNonEmpty(envelope.zhixuId, "zhixuId");
  requireNonEmpty(envelope.orderId, "orderId");
  requireNonEmpty(envelope.source, "source");
  requireNonEmpty(envelope.stageIdentifier, "stageIdentifier");
  requireNonEmpty(envelope.signalName, "signalName");
  requireNonEmpty(envelope.senderId, "senderId");
}

function requireNonEmpty(value: string | undefined, fieldName: string): void {
  if (!value || value.trim().length === 0) {
    throw new RuntimeHostError(`${fieldName} is required`);
  }
}

function pendingKey(zhixuId: string, orderId: string, hookId: string): string {
  return `${zhixuId}::${orderId}::${hookId}`;
}

function comparePendingEffects(left: PendingDispatch, right: PendingDispatch): number {
  return (
    left.zhixuId.localeCompare(right.zhixuId) ||
    left.orderId.localeCompare(right.orderId) ||
    left.hookId.localeCompare(right.hookId)
  );
}

function comparePendingTimers(left: PendingTimer, right: PendingTimer): number {
  return (
    new Date(left.dueAt).getTime() - new Date(right.dueAt).getTime() ||
    left.zhixuId.localeCompare(right.zhixuId) ||
    left.orderId.localeCompare(right.orderId) ||
    left.hookId.localeCompare(right.hookId)
  );
}

function assertNever(value: never): never {
  throw new RuntimeTransitionError("RuntimeHost", `unsupported effect ${JSON.stringify(value)}`);
}

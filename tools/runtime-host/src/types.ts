import type { HookPlanArtifact } from "@uvp-eth/compiler";
import type {
  HookReadyEffect,
  HookWaitingEffect,
  RuntimeEvent,
  RuntimeHookPlan,
  RuntimeState
} from "@uvp-eth/statemachine";

export type RuntimePlanInput = RuntimeHookPlan | HookPlanArtifact;

export interface SignalEnvelope {
  readonly zhixuId: string;
  readonly orderId: string;
  readonly source: string;
  readonly stageIdentifier: string;
  readonly signalName: string;
  readonly senderId: string;
  readonly idempotencyKey?: string;
  readonly traceId?: string;
  readonly payloadRef?: string;
  readonly receivedAt?: string;
}

export interface RuntimeOrderRegistration {
  readonly planId: `0x${string}`;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly receivedAt?: string;
}

export interface RuntimeEventStore {
  append(event: RuntimeEvent): Promise<void>;
  load(): Promise<readonly RuntimeEvent[]>;
}

export interface DispatchContext {
  readonly state: RuntimeState;
}

export interface DispatchSuccess {
  readonly status: "succeeded";
  readonly signals?: readonly SignalEnvelope[];
}

export interface DispatchFailure {
  readonly status: "failed";
  readonly error: string;
}

export type RuntimeDispatchResult = DispatchSuccess | DispatchFailure;

export interface RuntimeDispatcher {
  dispatch(effect: HookReadyEffect, context: DispatchContext): Promise<RuntimeDispatchResult>;
}

export interface RuntimeHostOptions {
  readonly store?: RuntimeEventStore;
  readonly dispatcher?: RuntimeDispatcher;
  readonly now?: () => string;
  readonly eventIdPrefix?: string;
}

export interface PendingDispatch extends HookReadyEffect {}

export interface PendingTimer extends HookWaitingEffect {}

export interface RuntimeHostSnapshot {
  readonly state: RuntimeState;
  readonly pendingDispatches: readonly PendingDispatch[];
  readonly pendingTimers: readonly PendingTimer[];
}

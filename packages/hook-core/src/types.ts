export type HookSource = string;
export type SignalName = string;

export type HookConditionAst =
  | SignalConditionAst
  | SubscriptionConditionAst
  | NotConditionAst
  | AndConditionAst
  | OrConditionAst
  | DelayConditionAst;

export interface HookExpressionAst {
  readonly raw: string;
  readonly source: HookSource;
  readonly condition: HookConditionAst;
}

export interface SignalConditionAst {
  readonly kind: "signal";
  readonly signalName: SignalName;
}

/**
 * Subscription entry `::ANCHOR(@source::task.stage.signal)`: empty source
 * header, delivered per contributing event, no expression verdict. Field name
 * mirrors uvp-hook-dsl `expr_to_ts_value` (`signal`, not `signalName`).
 */
export interface SubscriptionConditionAst {
  readonly kind: "subscription";
  readonly source: HookSource;
  readonly signal: SignalName;
}

export interface NotConditionAst {
  readonly kind: "not";
  readonly expr: HookConditionAst;
}

export interface AndConditionAst {
  readonly kind: "and";
  readonly terms: readonly HookConditionAst[];
}

export interface OrConditionAst {
  readonly kind: "or";
  readonly terms: readonly HookConditionAst[];
}

export interface DelayConditionAst {
  readonly kind: "delay";
  readonly expr: HookConditionAst;
  readonly durationSeconds: number;
  readonly rawDuration: string;
}

export interface HookDependency {
  readonly kind: "positive" | "negative" | "timer";
  readonly source: HookSource;
  readonly signalName: SignalName;
  readonly delaySeconds?: number;
}

export interface SignalFact {
  readonly source: HookSource;
  readonly signalName: SignalName;
  readonly receivedAt: string;
}

export type SignalIndex = Readonly<Record<string, SignalFact>>;

export type HookEvaluation =
  | {
      readonly status: "init";
    }
  | {
      readonly status: "wait";
      readonly dueAt: string;
    }
  | {
      readonly status: "reg";
    }
  | {
      readonly status: "cxl";
      readonly reason: string;
    };

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
 * Subscription entry `::ANCHOR(@source::stage.signal)`: empty source
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
      /**
       * 衰减否决位（合取直接子项上的 `~(A + duration)`）就绪时的有效期
       * （= 被否定延时的成熟时刻）。缺席 = 无限期。链上在信号到达交易内
       * 即时求值、无调度器，该字段只描述"本次就绪成立到何时"，重评时机
       * 由调用方决定。
       */
      readonly expiresAt?: string;
    }
  | {
      readonly status: "cxl";
      readonly reason: string;
    };

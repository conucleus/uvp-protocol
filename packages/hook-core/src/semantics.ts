import { evaluateHookWithUvpCore, parseHookWithUvpCore } from "./core.js";
import {
  type HookDependency,
  type HookEvaluation,
  type HookExpressionAst,
  type HookSource,
  type SignalIndex,
  type SignalName
} from "./types.js";

interface CoreParseHookOutput {
  readonly normalizedExpression: string;
  readonly ast: HookExpressionAst;
  readonly cloudAst: unknown;
  readonly dependencies: readonly HookDependency[];
}

interface CoreEvaluateHookOutput {
  readonly state: "ready" | "wait" | "impossible" | "needs_more";
  readonly readyAt?: string;
  // 衰减否决位（uvp-core Not(Wait) → Ready{expires_at}）的就绪有效期；
  // 仅 ready 态可能在场，缺席 = 无限期。
  readonly expiresAt?: string;
  readonly reason?: string;
}

export class HookExpressionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "HookExpressionError";
  }
}

export function parseHookExpression(raw: string): HookExpressionAst {
  try {
    return (parseHookWithUvpCore({
      profile: "evm_strict",
      hookName: "HOOK",
      hook: raw
    }) as CoreParseHookOutput).ast;
  } catch (error) {
    throw new HookExpressionError(error instanceof Error ? error.message : String(error));
  }
}

export function normalizeHookExpression(ast: HookExpressionAst): string {
  const raw = requireRawHook(ast);
  try {
    return (parseHookWithUvpCore({
      profile: "evm_strict",
      hookName: "HOOK",
      hook: raw
    }) as CoreParseHookOutput).normalizedExpression;
  } catch (error) {
    throw new HookExpressionError(error instanceof Error ? error.message : String(error));
  }
}

export function extractHookDependencies(ast: HookExpressionAst): readonly HookDependency[] {
  const raw = requireRawHook(ast);
  try {
    return (parseHookWithUvpCore({
      profile: "evm_strict",
      hookName: "HOOK",
      hook: raw
    }) as CoreParseHookOutput).dependencies;
  } catch (error) {
    throw new HookExpressionError(error instanceof Error ? error.message : String(error));
  }
}

export function evaluateHook(
  ast: HookExpressionAst,
  signalIndex: SignalIndex,
  now: string | Date
): HookEvaluation {
  const raw = requireRawHook(ast);
  try {
    const parsed = parseHookWithUvpCore({
      profile: "evm_strict",
      hookName: "HOOK",
      hook: raw
    }) as CoreParseHookOutput;
    const evaluated = evaluateHookWithUvpCore({
      profile: "evm_strict",
      ast: parsed.cloudAst,
      signals: Object.values(signalIndex),
      now: toDate(now).toISOString()
    }) as CoreEvaluateHookOutput;
    switch (evaluated.state) {
      case "ready":
        // 衰减否决位的就绪带有效期（成熟时刻）；其余就绪无期限——不落
        // undefined 键，两类 reg 形态保持可区分。
        return evaluated.expiresAt === undefined
          ? { status: "reg" }
          : { status: "reg", expiresAt: evaluated.expiresAt };
      case "wait":
        if (!evaluated.readyAt) {
          throw new HookExpressionError("uvp-core wait result is missing readyAt");
        }
        return { status: "wait", dueAt: evaluated.readyAt };
      case "impossible":
        return { status: "cxl", reason: evaluated.reason ?? "condition is impossible" };
      case "needs_more":
        return { status: "init" };
      default:
        assertNever(evaluated.state);
    }
  } catch (error) {
    if (error instanceof HookExpressionError) {
      throw error;
    }
    throw new HookExpressionError(error instanceof Error ? error.message : String(error));
  }
}

export function signalKey(source: HookSource, signalName: SignalName): string {
  return `${source}::${signalName}`;
}

function requireRawHook(ast: HookExpressionAst): string {
  if (!ast.raw) {
    throw new HookExpressionError("hook AST must include raw expression from uvp-core");
  }
  return ast.raw;
}

function toDate(value: string | Date): Date {
  const rawDate = value instanceof Date ? value : new Date(value);
  const date = new Date(Math.floor(rawDate.getTime() / 1000) * 1000);
  if (Number.isNaN(date.getTime())) {
    throw new HookExpressionError(`invalid date: ${String(value)}`);
  }
  return date;
}

function assertNever(value: never): never {
  throw new HookExpressionError(`unsupported hook state: ${JSON.stringify(value)}`);
}

import {
  type AndConditionAst,
  type DelayConditionAst,
  type ExternalConditionAst,
  type HookConditionAst,
  type HookDependency,
  type HookEvaluation,
  type HookExpressionAst,
  type HookSource,
  type OrConditionAst,
  type SignalFact,
  type SignalIndex,
  type SignalName
} from "./types.js";

export class HookExpressionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "HookExpressionError";
  }
}

export function parseHookExpression(raw: string): HookExpressionAst {
  const separator = raw.indexOf("::");
  if (separator < 0) {
    throw new HookExpressionError('hook expression must contain "::"');
  }

  const source = raw.slice(0, separator).trim();
  const conditionRaw = raw.slice(separator + 2).trim();
  if (!conditionRaw) {
    throw new HookExpressionError("hook condition cannot be empty");
  }
  if (!source && !startsWithExternal(conditionRaw)) {
    throw new HookExpressionError("empty source is only allowed for OUTSIDE or OUTSOURCE hooks");
  }

  const parser = new Parser(conditionRaw);
  const condition = parser.parse();
  validatePositiveAnchors(condition);

  return {
    raw,
    source,
    condition
  };
}

export function normalizeHookExpression(ast: HookExpressionAst): string {
  return `${ast.source}::${normalizeCondition(ast.condition)}`;
}

export function extractHookDependencies(ast: HookExpressionAst): readonly HookDependency[] {
  const dependencies: HookDependency[] = [];
  collectDependencies(ast.condition, ast.source, false, dependencies);
  return dedupeDependencies(dependencies);
}

export function evaluateHook(
  ast: HookExpressionAst,
  signalIndex: SignalIndex,
  now: string | Date
): HookEvaluation {
  const evaluated = evaluateCondition(ast.condition, ast.source, signalIndex, toDate(now));
  switch (evaluated.status) {
    case "true":
      return { status: "reg" };
    case "wait":
      return { status: "wait", dueAt: evaluated.dueAt.toISOString() };
    case "cxl":
      return { status: "cxl", reason: evaluated.reason };
    case "false":
      return { status: "init" };
    default:
      assertNever(evaluated);
  }
}

export function signalKey(source: HookSource, signalName: SignalName): string {
  return `${source}::${signalName}`;
}

function startsWithExternal(value: string): boolean {
  return value.startsWith("OUTSIDE") || value.startsWith("OUTSOURCE");
}

function validatePositiveAnchors(condition: HookConditionAst): void {
  if (!hasPositiveAnchor(condition)) {
    throw new HookExpressionError("hook condition must contain at least one positive signal anchor");
  }
  if (condition.kind === "or") {
    for (const term of condition.terms) {
      if (!hasPositiveAnchor(term)) {
        throw new HookExpressionError("each OR branch must contain a positive signal anchor");
      }
    }
  }
}

function hasPositiveAnchor(condition: HookConditionAst): boolean {
  switch (condition.kind) {
    case "signal":
    case "external":
      return true;
    case "delay":
      return hasPositiveAnchor(condition.expr);
    case "not":
      return false;
    case "and":
    case "or":
      return condition.terms.some((term) => hasPositiveAnchor(term));
    default:
      assertNever(condition);
  }
}

function normalizeCondition(condition: HookConditionAst): string {
  switch (condition.kind) {
    case "signal":
      return condition.signalName;
    case "external": {
      if (!condition.target) {
        return condition.mode;
      }
      return `${condition.mode}@(${normalizeHookExpression(condition.target)})`;
    }
    case "not":
      return `~${normalizeForUnary(condition.expr)}`;
    case "delay":
      return `${normalizeForUnary(condition.expr)}+${condition.rawDuration}`;
    case "and":
      return condition.terms.map(normalizeForJoin).join("&");
    case "or":
      return condition.terms.map(normalizeForJoin).join("|");
    default:
      assertNever(condition);
  }
}

function normalizeForUnary(condition: HookConditionAst): string {
  if (condition.kind === "signal" || condition.kind === "external") {
    return normalizeCondition(condition);
  }
  return `(${normalizeCondition(condition)})`;
}

function normalizeForJoin(condition: HookConditionAst): string {
  if (condition.kind === "or" || condition.kind === "and") {
    return `(${normalizeCondition(condition)})`;
  }
  return normalizeCondition(condition);
}

function collectDependencies(
  condition: HookConditionAst,
  source: HookSource,
  negated: boolean,
  out: HookDependency[]
): void {
  switch (condition.kind) {
    case "signal":
      out.push({
        kind: negated ? "negative" : "positive",
        source,
        signalName: condition.signalName
      });
      break;
    case "external":
      if (condition.target) {
        collectDependencies(condition.target.condition, condition.target.source, negated, out);
      } else {
        out.push({
          kind: negated ? "negative" : "positive",
          source,
          signalName: condition.mode
        });
      }
      break;
    case "not":
      collectDependencies(condition.expr, source, !negated, out);
      break;
    case "delay":
      collectDependencies(condition.expr, source, negated, out);
      if (!negated) {
        for (const dependency of dependenciesForTimer(condition.expr, source)) {
          out.push({
            kind: "timer",
            source: dependency.source,
            signalName: dependency.signalName,
            delaySeconds: condition.durationSeconds
          });
        }
      }
      break;
    case "and":
    case "or":
      for (const term of condition.terms) {
        collectDependencies(term, source, negated, out);
      }
      break;
    default:
      assertNever(condition);
  }
}

function dependenciesForTimer(
  condition: HookConditionAst,
  source: HookSource
): readonly Pick<HookDependency, "source" | "signalName">[] {
  const dependencies: HookDependency[] = [];
  collectDependencies(condition, source, false, dependencies);
  return dependencies.filter((dependency) => dependency.kind === "positive");
}

function dedupeDependencies(dependencies: readonly HookDependency[]): readonly HookDependency[] {
  const byKey = new Map<string, HookDependency>();
  for (const dependency of dependencies) {
    const key = [
      dependency.kind,
      dependency.source,
      dependency.signalName,
      dependency.delaySeconds ?? ""
    ].join("\u0000");
    byKey.set(key, dependency);
  }
  return [...byKey.values()].sort((left, right) => {
    return (
      left.kind.localeCompare(right.kind) ||
      left.source.localeCompare(right.source) ||
      left.signalName.localeCompare(right.signalName) ||
      (left.delaySeconds ?? 0) - (right.delaySeconds ?? 0)
    );
  });
}

type InternalEvaluation =
  | {
      readonly status: "true";
      readonly anchors: readonly Date[];
    }
  | {
      readonly status: "false";
    }
  | {
      readonly status: "wait";
      readonly dueAt: Date;
    }
  | {
      readonly status: "cxl";
      readonly reason: string;
    };

function evaluateCondition(
  condition: HookConditionAst,
  source: HookSource,
  signalIndex: SignalIndex,
  now: Date
): InternalEvaluation {
  switch (condition.kind) {
    case "signal":
      return evaluateSignal(source, condition.signalName, signalIndex);
    case "external":
      if (condition.target) {
        return evaluateCondition(condition.target.condition, condition.target.source, signalIndex, now);
      }
      return evaluateSignal(source, condition.mode, signalIndex);
    case "not": {
      const evaluated = evaluateCondition(condition.expr, source, signalIndex, now);
      if (evaluated.status === "true" || evaluated.status === "wait") {
        return { status: "cxl", reason: `negated condition exists: ${normalizeCondition(condition.expr)}` };
      }
      if (evaluated.status === "cxl") {
        return { status: "true", anchors: [] };
      }
      return { status: "true", anchors: [] };
    }
    case "delay":
      return evaluateDelay(condition, source, signalIndex, now);
    case "and":
      return evaluateAnd(condition, source, signalIndex, now);
    case "or":
      return evaluateOr(condition, source, signalIndex, now);
    default:
      assertNever(condition);
  }
}

function evaluateSignal(
  source: HookSource,
  signalName: SignalName,
  signalIndex: SignalIndex
): InternalEvaluation {
  const signal = signalIndex[signalKey(source, signalName)];
  if (!signal) {
    return { status: "false" };
  }
  return { status: "true", anchors: [toDate(signal.receivedAt)] };
}

function evaluateDelay(
  condition: DelayConditionAst,
  source: HookSource,
  signalIndex: SignalIndex,
  now: Date
): InternalEvaluation {
  const evaluated = evaluateCondition(condition.expr, source, signalIndex, now);
  if (evaluated.status !== "true") {
    return evaluated;
  }
  const anchor = latestDate(evaluated.anchors);
  if (!anchor) {
    return { status: "false" };
  }
  const dueAt = new Date(anchor.getTime() + condition.durationSeconds * 1000);
  if (now.getTime() >= dueAt.getTime()) {
    return { status: "true", anchors: [dueAt] };
  }
  return { status: "wait", dueAt };
}

function evaluateAnd(
  condition: AndConditionAst,
  source: HookSource,
  signalIndex: SignalIndex,
  now: Date
): InternalEvaluation {
  const anchors: Date[] = [];
  const waits: Date[] = [];
  let hasFalseTerm = false;
  for (const term of condition.terms) {
    const evaluated = evaluateCondition(term, source, signalIndex, now);
    if (evaluated.status === "cxl") {
      return evaluated;
    }
    if (evaluated.status === "false") {
      hasFalseTerm = true;
      continue;
    }
    if (evaluated.status === "wait") {
      waits.push(evaluated.dueAt);
      continue;
    }
    anchors.push(...evaluated.anchors);
  }
  const nextDue = earliestDate(waits);
  if (nextDue) {
    return { status: "wait", dueAt: nextDue };
  }
  if (hasFalseTerm) {
    return { status: "false" };
  }
  return { status: "true", anchors };
}

function evaluateOr(
  condition: OrConditionAst,
  source: HookSource,
  signalIndex: SignalIndex,
  now: Date
): InternalEvaluation {
  const waits: Date[] = [];
  let hasOpenBranch = false;
  for (const term of condition.terms) {
    const evaluated = evaluateCondition(term, source, signalIndex, now);
    if (evaluated.status === "true") {
      return evaluated;
    }
    if (evaluated.status === "wait") {
      waits.push(evaluated.dueAt);
    }
    if (evaluated.status === "false" || evaluated.status === "wait") {
      hasOpenBranch = true;
    }
  }
  const nextDue = earliestDate(waits);
  if (nextDue) {
    return { status: "wait", dueAt: nextDue };
  }
  return hasOpenBranch
    ? { status: "false" }
    : { status: "cxl", reason: `all OR branches are cancelled: ${normalizeCondition(condition)}` };
}

class Parser {
  private index = 0;

  constructor(private readonly input: string) {}

  parse(): HookConditionAst {
    const expression = this.parseOr();
    this.skipWhitespace();
    if (!this.atEnd()) {
      throw new HookExpressionError(`unexpected token at ${this.index}: ${this.input.slice(this.index)}`);
    }
    return expression;
  }

  private parseOr(): HookConditionAst {
    const terms = [this.parseAnd()];
    while (this.consume("|")) {
      terms.push(this.parseAnd());
    }
    return terms.length === 1 ? terms[0]! : { kind: "or", terms };
  }

  private parseAnd(): HookConditionAst {
    const terms = [this.parseUnary()];
    while (this.consume("&")) {
      terms.push(this.parseUnary());
    }
    return terms.length === 1 ? terms[0]! : { kind: "and", terms };
  }

  private parseUnary(): HookConditionAst {
    this.skipWhitespace();
    if (this.consume("~")) {
      return { kind: "not", expr: this.parseUnary() };
    }
    return this.parsePostfix();
  }

  private parsePostfix(): HookConditionAst {
    let expression = this.parsePrimary();
    this.skipWhitespace();
    if (this.peek() === "+") {
      this.index += 1;
      const rawDuration = this.readDuration();
      expression = {
        kind: "delay",
        expr: expression,
        rawDuration,
        durationSeconds: durationToSeconds(rawDuration)
      };
    }
    return expression;
  }

  private parsePrimary(): HookConditionAst {
    this.skipWhitespace();
    if (this.consume("(")) {
      const expression = this.parseOr();
      if (!this.consume(")")) {
        throw new HookExpressionError(`expected ")" at ${this.index}`);
      }
      return expression;
    }

    const identifier = this.readIdentifier();
    if (identifier === "OUTSIDE" || identifier === "OUTSOURCE") {
      return this.parseExternal(identifier);
    }
    if (!isSignalReference(identifier)) {
      throw new HookExpressionError(`signal reference must use task.stage.signal: ${identifier}`);
    }
    return { kind: "signal", signalName: identifier };
  }

  private parseExternal(mode: "OUTSIDE" | "OUTSOURCE"): ExternalConditionAst {
    this.skipWhitespace();
    if (!this.consume("@")) {
      return { kind: "external", mode };
    }
    if (!this.consume("(")) {
      throw new HookExpressionError(`expected "@" target at ${this.index}`);
    }
    const targetRaw = this.readBalancedTarget();
    return {
      kind: "external",
      mode,
      target: parseHookExpression(targetRaw)
    };
  }

  private readBalancedTarget(): string {
    let depth = 1;
    const start = this.index;
    while (!this.atEnd()) {
      const char = this.input[this.index];
      this.index += 1;
      if (char === "(") {
        depth += 1;
      } else if (char === ")") {
        depth -= 1;
        if (depth === 0) {
          return this.input.slice(start, this.index - 1).trim();
        }
      }
    }
    throw new HookExpressionError("unterminated @() target");
  }

  private readDuration(): string {
    this.skipWhitespace();
    const start = this.index;
    while (!this.atEnd() && /[0-9smhd]/.test(this.peek())) {
      this.index += 1;
    }
    const duration = this.input.slice(start, this.index);
    if (!/^[1-9][0-9]*(s|m|h|d)$/.test(duration)) {
      throw new HookExpressionError(`invalid duration: ${duration || "<empty>"}`);
    }
    return duration;
  }

  private readIdentifier(): string {
    this.skipWhitespace();
    const start = this.index;
    while (!this.atEnd() && /[A-Za-z0-9_.-]/.test(this.peek())) {
      this.index += 1;
    }
    const identifier = this.input.slice(start, this.index);
    if (!identifier) {
      throw new HookExpressionError(`expected identifier at ${this.index}`);
    }
    return identifier;
  }

  private consume(value: string): boolean {
    this.skipWhitespace();
    if (!this.input.startsWith(value, this.index)) {
      return false;
    }
    this.index += value.length;
    return true;
  }

  private skipWhitespace(): void {
    while (!this.atEnd() && /\s/.test(this.peek())) {
      this.index += 1;
    }
  }

  private peek(): string {
    return this.input[this.index] ?? "";
  }

  private atEnd(): boolean {
    return this.index >= this.input.length;
  }
}

function durationToSeconds(duration: string): number {
  const match = duration.match(/^([1-9][0-9]*)(s|m|h|d)$/);
  if (!match) {
    throw new HookExpressionError(`invalid duration: ${duration}`);
  }
  const value = Number(match[1]);
  const unit = match[2];
  switch (unit) {
    case "s":
      return value;
    case "m":
      return value * 60;
    case "h":
      return value * 60 * 60;
    case "d":
      return value * 60 * 60 * 24;
    default:
      throw new HookExpressionError(`invalid duration unit: ${unit ?? ""}`);
  }
}

function isSignalReference(value: string): boolean {
  const parts = value.split(".");
  return parts.length === 3 && parts.every((part) => part.length > 0);
}

function toDate(value: string | Date): Date {
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) {
    throw new HookExpressionError(`invalid date: ${String(value)}`);
  }
  return date;
}

function earliestDate(values: readonly Date[]): Date | null {
  return values.reduce<Date | null>((earliest, value) => {
    if (!earliest || value.getTime() < earliest.getTime()) {
      return value;
    }
    return earliest;
  }, null);
}

function latestDate(values: readonly Date[]): Date | null {
  return values.reduce<Date | null>((latest, value) => {
    if (!latest || value.getTime() > latest.getTime()) {
      return value;
    }
    return latest;
  }, null);
}

function assertNever(value: never): never {
  throw new HookExpressionError(`unsupported hook node: ${JSON.stringify(value)}`);
}

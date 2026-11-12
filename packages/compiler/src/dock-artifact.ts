import type { HookDependency, HookExpressionAst } from "@uvp-eth/hook-core";
import { keccak256Hex } from "./hash.js";
import type { HexString } from "./types/index.js";

/**
 * uvp.dock.v1（静态 Dock 编译产物）的链轨边界类型与解序列化校验：产物由
 * uvp-core analyzeDock 生成（单一源），带 Hook DSL validWhen 的 AST/dependencies
 * 与 capability proof 用的 atoms；本模块只校验封闭字段集与可重算的 ID。
 * atom/output 的 targetOrderRelation 恒为 0（当前订单）。
 */

export const DOCK_ARTIFACT_SCHEMA_VERSION = "uvp.dock.v1" as const;

export interface DockArtifact {
  readonly schemaVersion: typeof DOCK_ARTIFACT_SCHEMA_VERSION;
  readonly dkid: string;
  readonly docHash: HexString;
  readonly from: DockArtifactSide;
  readonly to: DockArtifactTarget;
  readonly signalMap: readonly DockArtifactOutput[];
}

export interface DockArtifactSide {
  readonly zhixu: string;
  readonly source: string;
  readonly sourceId: HexString;
}

export interface DockArtifactTarget extends DockArtifactSide {
  readonly stage: string;
  readonly stageId: HexString;
}

export interface DockArtifactOutput {
  readonly signal: string;
  readonly signalId: HexString;
  readonly sourceId: HexString;
  readonly stageId: HexString;
  readonly targetOrderRelation: 0;
  readonly rawExpression: string;
  readonly ast: HookExpressionAst;
  readonly dependencies: readonly HookDependency[];
  readonly atoms: readonly DockArtifactAtom[];
}

export interface DockArtifactAtom extends DockArtifactSide {
  readonly stage: string;
  readonly stageId: HexString;
  readonly signal: string;
  readonly signalId: HexString;
  readonly targetOrderRelation: 0;
}

export const DOCK_WINDOW_OP = {
  SIGNAL: 0,
  NOT: 1,
  AND: 2,
  OR: 3,
  DELAY: 4,
} as const;

export interface DockWindowInstruction {
  readonly op: 0 | 1 | 2 | 3 | 4;
  readonly sourceId: HexString;
  readonly signalId: HexString;
  readonly arity: number;
  readonly delaySeconds: number;
}

const ZERO_WORD = `0x${"00".repeat(32)}` as HexString;

const DOCK_ARTIFACT_FIELDS: readonly string[] = [
  "schemaVersion",
  "dkid",
  "docHash",
  "from",
  "to",
  "signalMap",
];
const DOCK_SIDE_FIELDS: readonly string[] = ["zhixu", "source", "sourceId"];
const DOCK_TARGET_FIELDS: readonly string[] = [
  ...DOCK_SIDE_FIELDS,
  "stage",
  "stageId",
];
const DOCK_OUTPUT_FIELDS: readonly string[] = [
  "signal",
  "signalId",
  "sourceId",
  "stageId",
  "targetOrderRelation",
  "rawExpression",
  "ast",
  "dependencies",
  "atoms",
];
const DOCK_ATOM_FIELDS: readonly string[] = [
  "source",
  "sourceId",
  "stage",
  "stageId",
  "signal",
  "signalId",
  "targetOrderRelation",
];

export function validateDockArtifact(value: unknown): readonly string[] {
  const issues: string[] = [];
  if (!isRecord(value)) {
    return ["artifact must be an object"];
  }
  expectClosedKeySet(value, DOCK_ARTIFACT_FIELDS, "artifact", issues);
  expectLiteral(value.schemaVersion, DOCK_ARTIFACT_SCHEMA_VERSION, "schemaVersion", issues);
  if (typeof value.dkid !== "string" || !/^zd-[0-9a-f]{32}$/.test(value.dkid)) {
    issues.push("dkid must be zd-<32 lowercase hex>");
  }
  expectHexHash(value.docHash, "docHash", issues);
  if (
    typeof value.dkid === "string" &&
    isHexHash(value.docHash) &&
    value.dkid !== `zd-${value.docHash.slice(2, 34)}`
  ) {
    issues.push("dkid must be zd-<first 32 hex digits of docHash>");
  }
  validateSide(value.from, "from", issues);
  validateTarget(value.to, "to", issues);
  if (!Array.isArray(value.signalMap)) {
    issues.push("signalMap must be an array");
  } else if (value.signalMap.length === 0) {
    issues.push("signalMap must declare at least one output");
  } else {
    const signals = new Set<string>();
    for (const [index, output] of value.signalMap.entries()) {
      const path = `signalMap[${index}]`;
      if (!isRecord(output)) {
        issues.push(`${path} must be an object`);
        continue;
      }
      expectClosedKeySet(output, DOCK_OUTPUT_FIELDS, path, issues);
      expectNonEmptyString(output.signal, `${path}.signal`, issues);
      expectHexHash(output.signalId, `${path}.signalId`, issues);
      expectHexHash(output.sourceId, `${path}.sourceId`, issues);
      expectHexHash(output.stageId, `${path}.stageId`, issues);
      expectRelation(output.targetOrderRelation, `${path}.targetOrderRelation`, issues);
      expectNonEmptyString(output.rawExpression, `${path}.rawExpression`, issues);
      if (typeof output.signal === "string") {
        if (signals.has(output.signal)) {
          issues.push(`duplicate signalMap output ${output.signal}`);
        }
        signals.add(output.signal);
      }
      if (
        isRecord(value.to) &&
        typeof value.to.source === "string" &&
        typeof value.to.stage === "string"
      ) {
        if (
          typeof output.sourceId === "string" &&
          output.sourceId !== keccak256Hex(value.to.source)
        ) {
          issues.push(`${path}.sourceId must be keccak256(to.source)`);
        }
        if (
          typeof output.stageId === "string" &&
          output.stageId !== keccak256Hex(value.to.stage)
        ) {
          issues.push(`${path}.stageId must be keccak256(to.stage)`);
        }
        if (
          typeof output.signal === "string" &&
          typeof output.signalId === "string" &&
          output.signalId !== keccak256Hex(`${value.to.stage}.${output.signal}`)
        ) {
          issues.push(`${path}.signalId must be keccak256(to.stage.signal)`);
        }
      }
      if (!Array.isArray(output.atoms)) {
        issues.push(`${path}.atoms must be an array`);
      } else {
        for (const [atomIndex, atom] of output.atoms.entries()) {
          const atomPath = `${path}.atoms[${atomIndex}]`;
          if (!isRecord(atom)) {
            issues.push(`${atomPath} must be an object`);
            continue;
          }
          expectClosedKeySet(atom, DOCK_ATOM_FIELDS, atomPath, issues);
          expectNonEmptyString(atom.source, `${atomPath}.source`, issues);
          expectHexHash(atom.sourceId, `${atomPath}.sourceId`, issues);
          expectNonEmptyString(atom.stage, `${atomPath}.stage`, issues);
          expectHexHash(atom.stageId, `${atomPath}.stageId`, issues);
          expectNonEmptyString(atom.signal, `${atomPath}.signal`, issues);
          expectHexHash(atom.signalId, `${atomPath}.signalId`, issues);
          expectRelation(atom.targetOrderRelation, `${atomPath}.targetOrderRelation`, issues);
          if (
            typeof atom.source === "string" &&
            typeof atom.sourceId === "string" &&
            atom.sourceId !== keccak256Hex(atom.source)
          ) {
            issues.push(`${atomPath}.sourceId must be keccak256(source)`);
          }
          if (
            typeof atom.stage === "string" &&
            typeof atom.stageId === "string" &&
            atom.stageId !== keccak256Hex(atom.stage)
          ) {
            issues.push(`${atomPath}.stageId must be keccak256(stage)`);
          }
          if (
            typeof atom.stage === "string" &&
            typeof atom.signal === "string" &&
            typeof atom.signalId === "string" &&
            atom.signalId !== keccak256Hex(`${atom.stage}.${atom.signal}`)
          ) {
            issues.push(`${atomPath}.signalId must be keccak256(stage.signal)`);
          }
        }
      }
      validateOutputAst(output.ast, `${path}.ast`, issues);
      if (!Array.isArray(output.dependencies)) {
        issues.push(`${path}.dependencies must be an array`);
      } else {
        for (const [index, dependency] of output.dependencies.entries()) {
          const dependencyPath = `${path}.dependencies[${index}]`;
          if (!isRecord(dependency)) {
            issues.push(`${dependencyPath} must be an object`);
            continue;
          }
          if (
            dependency.kind !== "positive" &&
            dependency.kind !== "negative" &&
            dependency.kind !== "timer"
          ) {
            issues.push(`${dependencyPath}.kind must be positive, negative, or timer`);
          }
          expectNonEmptyString(dependency.source, `${dependencyPath}.source`, issues);
          expectNonEmptyString(dependency.signalName, `${dependencyPath}.signalName`, issues);
          if (dependency.delaySeconds !== undefined) {
            if (
              !Number.isSafeInteger(dependency.delaySeconds) ||
              Number(dependency.delaySeconds) <= 0
            ) {
              issues.push(`${dependencyPath}.delaySeconds must be a positive safe integer when present`);
            }
          }
        }
      }
    }
  }
  return issues;
}

export function dockWindowInstructionsOf(
  output: DockArtifactOutput,
): readonly DockWindowInstruction[] {
  const atomBySignal = new Map<string, DockArtifactAtom>();
  for (const atom of output.atoms) {
    const key = `${atom.stage}.${atom.signal}`;
    if (atomBySignal.has(key)) {
      throw new DockArtifactValidationError([
        `output ${output.signal} declares duplicate atom signal ${key}`,
      ]);
    }
    atomBySignal.set(key, atom);
  }
  return compileWindowCondition(output.ast.condition, atomBySignal, output.signal);
}

function compileWindowCondition(
  condition: DockArtifactOutput["ast"]["condition"],
  atomBySignal: ReadonlyMap<string, DockArtifactAtom>,
  signal: string,
): DockWindowInstruction[] {
  switch (condition.kind) {
    case "signal": {
      const atom = atomBySignal.get(condition.signalName);
      if (atom === undefined) {
        throw new DockArtifactValidationError([
          `output ${signal} expression references atom ${condition.signalName} absent from atoms`,
        ]);
      }
      return [{
        op: DOCK_WINDOW_OP.SIGNAL,
        sourceId: atom.sourceId,
        signalId: atom.signalId,
        arity: 0,
        delaySeconds: 0,
      }];
    }
    case "not":
      return [
        ...compileWindowCondition(condition.expr, atomBySignal, signal),
        { op: DOCK_WINDOW_OP.NOT, sourceId: ZERO_WORD, signalId: ZERO_WORD, arity: 0, delaySeconds: 0 },
      ];
    case "and":
    case "or":
      return [
        ...condition.terms.flatMap((term) => compileWindowCondition(term, atomBySignal, signal)),
        {
          op: condition.kind === "and" ? DOCK_WINDOW_OP.AND : DOCK_WINDOW_OP.OR,
          sourceId: ZERO_WORD,
          signalId: ZERO_WORD,
          arity: condition.terms.length,
          delaySeconds: 0,
        },
      ];
    case "delay":
      return [
        ...compileWindowCondition(condition.expr, atomBySignal, signal),
        {
          op: DOCK_WINDOW_OP.DELAY,
          sourceId: ZERO_WORD,
          signalId: ZERO_WORD,
          arity: 0,
          delaySeconds: condition.durationSeconds,
        },
      ];
    default:
      throw new DockArtifactValidationError([
        `output ${signal} expression carries unsupported condition node`,
      ]);
  }
}

export function assertDockArtifact(value: unknown): asserts value is DockArtifact {
  const issues = validateDockArtifact(value);
  if (issues.length > 0) {
    throw new DockArtifactValidationError(issues);
  }
}

export class DockArtifactValidationError extends Error {
  readonly issues: readonly string[];

  constructor(issues: readonly string[]) {
    super(issues.join("; "));
    this.name = "DockArtifactValidationError";
    this.issues = issues;
  }
}

function validateOutputAst(value: unknown, path: string, issues: string[]): void {
  if (!isRecord(value)) {
    issues.push(`${path} must be an object`);
    return;
  }
  expectNonEmptyString(value.raw, `${path}.raw`, issues);
  expectNonEmptyString(value.source, `${path}.source`, issues);
  if (!isRecord(value.condition)) {
    issues.push(`${path}.condition must be an object`);
  }
}

function validateSide(
  value: unknown,
  path: string,
  issues: string[],
  fields: readonly string[] = DOCK_SIDE_FIELDS,
): void {
  if (!isRecord(value)) {
    issues.push(`${path} must be an object`);
    return;
  }
  expectClosedKeySet(value, fields, path, issues);
  expectNonEmptyString(value.zhixu, `${path}.zhixu`, issues);
  if (typeof value.zhixu === "string" && !/^zx-[0-9a-f]{32}$/.test(value.zhixu)) {
    issues.push(`${path}.zhixu must be zx-<32 lowercase hex>`);
  }
  expectNonEmptyString(value.source, `${path}.source`, issues);
  expectHexHash(value.sourceId, `${path}.sourceId`, issues);
  if (
    typeof value.source === "string" &&
    typeof value.sourceId === "string" &&
    value.sourceId !== keccak256Hex(value.source)
  ) {
    issues.push(`${path}.sourceId must be keccak256(source)`);
  }
}

function validateTarget(value: unknown, path: string, issues: string[]): void {
  validateSide(value, path, issues, DOCK_TARGET_FIELDS);
  if (!isRecord(value)) {
    return;
  }
  expectNonEmptyString(value.stage, `${path}.stage`, issues);
  expectHexHash(value.stageId, `${path}.stageId`, issues);
  if (
    typeof value.stage === "string" &&
    typeof value.stageId === "string" &&
    value.stageId !== keccak256Hex(value.stage)
  ) {
    issues.push(`${path}.stageId must be keccak256(stage)`);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isHexHash(value: unknown): value is HexString {
  return typeof value === "string" && /^0x[0-9a-f]{64}$/.test(value);
}

function expectClosedKeySet(
  value: Record<string, unknown>,
  allowed: readonly string[],
  path: string,
  issues: string[],
): void {
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) {
      issues.push(`unknown field \`${key}\` on ${path}; remove it or recompile`);
    }
  }
}

function expectLiteral(
  value: unknown,
  expected: string,
  field: string,
  issues: string[],
): void {
  if (value !== expected) {
    issues.push(`${field} must be ${expected}`);
  }
}

function expectRelation(value: unknown, field: string, issues: string[]): void {
  if (value !== 0) {
    issues.push(`${field} must be 0 (current order); the dock compiler never emits a foreign relation`);
  }
}

function expectHexHash(value: unknown, field: string, issues: string[]): void {
  if (!isHexHash(value)) {
    issues.push(`${field} must be a lowercase 32-byte hex hash`);
  }
}

function expectNonEmptyString(value: unknown, field: string, issues: string[]): void {
  if (typeof value !== "string" || value.trim().length === 0) {
    issues.push(`${field} must be a non-empty string`);
  }
}

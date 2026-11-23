import { compareCanonicalKey } from "../../hook-plan.js";
import {
  onchainHookId,
  onchainSignalId,
  onchainSignalKey,
  onchainSourceId,
  onchainStageId,
} from "../hash/route.js";
import {
  expectBoolean,
  expectClosedKeySet,
  expectHexHash,
  expectNonEmptyString,
  expectOneOf,
  expectString,
  isHexHash,
  isRecord,
} from "../shape.js";
import { MAX_ONCHAIN_HOOK_DELAY_SECONDS, MAX_ONCHAIN_INSTRUCTION_DEPTH } from "./limits.js";
import type {
  OnchainCompiledHook,
  OnchainHookDependency,
} from "../../types/index.js";

/**
 * hook 族校验：compiledHooks 形状与 _validateHook 栈机镜像、依赖形状、
 * 阶段物化门、dynamic/dock/route 互斥与依赖索引重算
 * （两个边界共用）。
 */

const COMPILED_HOOK_FIELDS: readonly string[] = [
  "hookId",
  "stageId",
  "stageIdentifier",
  "hookName",
  "kind",
  "orderTriggerKind",
  "emitReady",
  "dockExecutor",
  "dynamicExecutor",
  "instructions",
  "dependencies",
  "routeRef",
];
const ROUTE_REF_FIELDS: readonly string[] = ["routeId", "stageId", "routeHash"];
const DEPENDENCY_FIELDS: readonly string[] = [
  "kind",
  "source",
  "signalName",
  "sourceId",
  "signalId",
  "signalKey",
  "delaySeconds",
];
const ADMISSION_FIELDS: readonly string[] = [
  "admissionId",
  "stageId",
  "stageIdentifier",
  "signalName",
  "signalId",
  "sourceId",
  "instructions",
  "dependencies",
];
const INSTRUCTION_FIELDS: Readonly<Record<string, readonly string[]>> = {
  SIGNAL: ["op", "source", "signalName", "sourceId", "signalId", "signalKey"],
  NOT: ["op"],
  AND: ["op", "arity"],
  OR: ["op", "arity"],
  DELAY: ["op", "delaySeconds"],
};

function expectInstructionKeyClosure(
  instruction: Record<string, unknown>,
  prefix: string,
  issues: string[],
): void {
  const allowed =
    typeof instruction.op === "string"
      ? INSTRUCTION_FIELDS[instruction.op]
      : undefined;
  if (allowed !== undefined) {
    expectClosedKeySet(instruction, allowed, prefix, issues);
  }
}

function validateOnchainCompiledHooks(
  hooks: readonly unknown[],
  supplierRoutes: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  const hookIds = new Set<string>();
  const dynamicByStage = new Map<string, boolean>();
  const mixedDynamicStages = new Set<string>();
  const routeIds = new Set(
    supplierRoutes
      .filter(isRecord)
      .map((route) => route.routeId)
      .filter((routeId): routeId is string => typeof routeId === "string"),
  );
  const routesById = new Map<string, Record<string, unknown>>();
  for (const route of supplierRoutes) {
    if (isRecord(route) && typeof route.routeId === "string") {
      routesById.set(route.routeId, route);
    }
  }

  for (const [index, hook] of hooks.entries()) {
    if (!isRecord(hook)) {
      issues.push(`compiledHooks[${index}] must be an object`);
      continue;
    }

    const prefix = `compiledHooks[${index}]`;
    expectClosedKeySet(hook, COMPILED_HOOK_FIELDS, prefix, issues);
    expectHexHash(hook.hookId, `${prefix}.hookId`, issues);
    expectHexHash(hook.stageId, `${prefix}.stageId`, issues);
    expectNonEmptyString(
      hook.stageIdentifier,
      `${prefix}.stageIdentifier`,
      issues,
    );
    expectNonEmptyString(hook.hookName, `${prefix}.hookName`, issues);
    expectOneOf(hook.kind, ["receive"], `${prefix}.kind`, issues);
    expectOneOf(
      hook.orderTriggerKind,
      ["none", "trigger"],
      `${prefix}.orderTriggerKind`,
      issues,
    );
    expectBoolean(hook.emitReady, `${prefix}.emitReady`, issues);
    expectBoolean(hook.dockExecutor, `${prefix}.dockExecutor`, issues);
    expectBoolean(hook.dynamicExecutor, `${prefix}.dynamicExecutor`, issues);
    if (hook.dynamicExecutor === true) {
      if (hook.orderTriggerKind !== "none") {
        issues.push(
          `${prefix} is a dynamic-executor hook and must not carry an order-trigger bit; birth suppliers are fixed at plan time`,
        );
      }
      if (hook.dockExecutor === true) {
        issues.push(
          `${prefix} cannot be both a dynamic-executor and a dock-executor hook; dock executors are selected once through the stage supplier patch`,
        );
      }
      if (hook.emitReady !== true) {
        issues.push(
          `${prefix} is a dynamic-executor hook without EMIT_READY; a dynamic stage materializes only through its own emit-ready hooks`,
        );
      }
      if (hook.routeRef !== undefined) {
        issues.push(
          `${prefix} is a dynamic-executor hook and must not carry a supplier route; the supplier is assigned per order through the stage supplier patch`,
        );
      }
    }
    if (
      typeof hook.stageId === "string" &&
      typeof hook.dynamicExecutor === "boolean"
    ) {
      const current = dynamicByStage.get(hook.stageId);
      if (current === undefined) {
        dynamicByStage.set(hook.stageId, hook.dynamicExecutor);
      } else if (
        current !== hook.dynamicExecutor &&
        !mixedDynamicStages.has(hook.stageId)
      ) {
        mixedDynamicStages.add(hook.stageId);
        issues.push(
          `stage ${String(hook.stageIdentifier)} mixes dynamic-executor hooks with non-dynamic hooks `
            + "(UVPStateMachine.commitPlan collects the per-stage dynamic set from hook flags and reverts InconsistentDynamicSupplierFlag)",
        );
      }
    }
    if (hook.dockExecutor === true) {
      if (hook.orderTriggerKind !== "none") {
        issues.push(
          `${prefix} is a dock stage hook and must not carry an order-trigger bit (the contract's dock executor flag only decorates receive hooks)`,
        );
      }
      if (hook.emitReady !== true) {
        issues.push(
          `${prefix} is a dock stage hook without EMIT_READY; a dock stage materializes only through its own emit-ready hooks, so the flag would be unreachable`,
        );
      }
      if (hook.routeRef !== undefined) {
        issues.push(
          `${prefix} is a dock stage hook and must not carry a supplier route; the dock executor is selected once through the stage supplier patch (dkid)`,
        );
      }
    }

    if (
      typeof hook.stageIdentifier === "string" &&
      typeof hook.hookName === "string" &&
      typeof hook.hookId === "string" &&
      hook.hookId !== onchainHookId(hook.stageIdentifier, hook.hookName)
    ) {
      issues.push(
        `${prefix}.hookId must be keccak256(stageIdentifier#hookName)`,
      );
    }
    if (
      typeof hook.stageIdentifier === "string" &&
      typeof hook.stageId === "string" &&
      hook.stageId !== onchainStageId(hook.stageIdentifier)
    ) {
      issues.push(`${prefix}.stageId must be keccak256(stageIdentifier)`);
    }
    if (typeof hook.hookId === "string") {
      if (hookIds.has(hook.hookId)) {
        issues.push(`duplicate hookId ${hook.hookId}`);
      }
      hookIds.add(hook.hookId);
    }

    if (!Array.isArray(hook.instructions)) {
      issues.push(`${prefix}.instructions must be an array`);
    } else {
      issues.push(
        ...validateInstructions(hook.instructions, `${prefix}.instructions`, {
          orderTrigger:
            typeof hook.orderTriggerKind === "string" &&
            hook.orderTriggerKind !== "none",
        }),
      );
    }

    if (!Array.isArray(hook.dependencies)) {
      issues.push(`${prefix}.dependencies must be an array`);
    } else {
      issues.push(
        ...validateOnchainDependencies(
          hook.dependencies,
          `${prefix}.dependencies`,
        ),
      );
      const signalKeys = new Set<string>();
      if (Array.isArray(hook.instructions)) {
        for (const instruction of hook.instructions) {
          if (
            isRecord(instruction) &&
            instruction.op === "SIGNAL" &&
            typeof instruction.signalKey === "string"
          ) {
            signalKeys.add(instruction.signalKey);
          }
        }
      }
      const dependencyKeys = new Set<string>();
      for (const dependency of hook.dependencies) {
        if (isRecord(dependency) && typeof dependency.signalKey === "string") {
          dependencyKeys.add(dependency.signalKey);
        }
      }
      for (const key of dependencyKeys) {
        if (!signalKeys.has(key)) {
          issues.push(
            `${prefix}.dependencies key ${key} is not a SIGNAL atom of this hook `
              + "(contract _validateHook reverts HookDependencyKeyMismatch for dependency keys that never participate in evaluation)",
          );
        }
      }
      for (const key of signalKeys) {
        if (!dependencyKeys.has(key)) {
          issues.push(
            `${prefix}.instructions SIGNAL key ${key} is not declared in dependencies `
              + "(contract _validateHook reverts HookDependencyKeyMismatch; an undeclared key never triggers "
              + "evaluation, so the hook would stay Init forever with no alarm)",
          );
        }
      }
    }

    if (hook.routeRef !== undefined) {
      if (!isRecord(hook.routeRef)) {
        issues.push(`${prefix}.routeRef must be an object`);
      } else {
        expectClosedKeySet(
          hook.routeRef,
          ROUTE_REF_FIELDS,
          `${prefix}.routeRef`,
          issues,
        );
        expectHexHash(
          hook.routeRef.routeId,
          `${prefix}.routeRef.routeId`,
          issues,
        );
        expectHexHash(
          hook.routeRef.stageId,
          `${prefix}.routeRef.stageId`,
          issues,
        );
        expectHexHash(
          hook.routeRef.routeHash,
          `${prefix}.routeRef.routeHash`,
          issues,
        );
        if (
          typeof hook.routeRef.stageId === "string" &&
          typeof hook.stageId === "string" &&
          hook.routeRef.stageId !== hook.stageId
        ) {
          issues.push(`${prefix}.routeRef.stageId must equal hook stageId`);
        }
        if (
          typeof hook.routeRef.routeId === "string" &&
          !routeIds.has(hook.routeRef.routeId)
        ) {
          issues.push(
            `${prefix}.routeRef.routeId must reference supplierRoutes`,
          );
        }
        if (
          typeof hook.routeRef.routeId === "string" &&
          typeof hook.routeRef.routeHash === "string"
        ) {
          const referencedRoute = routesById.get(hook.routeRef.routeId);
          if (
            referencedRoute &&
            referencedRoute.routeHash !== hook.routeRef.routeHash
          ) {
            issues.push(
              `${prefix}.routeRef.routeHash must match the referenced supplier route`,
            );
          }
        }
      }
    }
  }

  return issues;
}

function instructionDepthIssue(
  prefix: string,
  depth: number,
  contractValidator: "_validateHook" | "_validateAdmission",
): string | undefined {
  if (depth <= MAX_ONCHAIN_INSTRUCTION_DEPTH) {
    return undefined;
  }
  return `${prefix} instruction nesting depth ${depth} exceeds MAX_INSTRUCTION_DEPTH ${MAX_ONCHAIN_INSTRUCTION_DEPTH} (contract ${contractValidator} reverts InvalidInstruction)`;
}

function validateInstructions(
  instructions: readonly unknown[],
  path: string,
  options: { readonly orderTrigger: boolean },
): readonly string[] {
  const issues: string[] = [];
  let stackDepth = 0;
  const bareSignal: boolean[] = [];
  const hasPosAnchor: boolean[] = [];
  const delayResult: boolean[] = [];
  const delayInside: boolean[] = [];
  const vetoTerm: boolean[] = [];
  const vetoInside: boolean[] = [];
  const instructionDepth: number[] = [];

  for (const [index, instruction] of instructions.entries()) {
    if (!isRecord(instruction)) {
      issues.push(`${path}[${index}] must be an object`);
      continue;
    }

    const prefix = `${path}[${index}]`;
    expectInstructionKeyClosure(instruction, prefix, issues);
    switch (instruction.op) {
      case "SIGNAL":
        expectString(instruction.source, `${prefix}.source`, issues);
        expectNonEmptyString(
          instruction.signalName,
          `${prefix}.signalName`,
          issues,
        );
        expectHexHash(instruction.sourceId, `${prefix}.sourceId`, issues);
        expectHexHash(instruction.signalId, `${prefix}.signalId`, issues);
        expectHexHash(instruction.signalKey, `${prefix}.signalKey`, issues);
        if (
          typeof instruction.source === "string" &&
          typeof instruction.sourceId === "string" &&
          instruction.sourceId !== onchainSourceId(instruction.source)
        ) {
          issues.push(`${prefix}.sourceId must be keccak256(source)`);
        }
        if (
          typeof instruction.signalName === "string" &&
          typeof instruction.signalId === "string" &&
          instruction.signalId !== onchainSignalId(instruction.signalName)
        ) {
          issues.push(
            `${prefix}.signalId must be keccak256(stage.signal)`,
          );
        }
        if (
          typeof instruction.sourceId === "string" &&
          typeof instruction.signalId === "string" &&
          isHexHash(instruction.sourceId) &&
          isHexHash(instruction.signalId) &&
          instruction.signalKey !==
            onchainSignalKey(instruction.sourceId, instruction.signalId)
        ) {
          issues.push(
            `${prefix}.signalKey must be keccak256(abi.encodePacked(sourceId, signalId))`,
          );
        }
        bareSignal[stackDepth] = true;
        hasPosAnchor[stackDepth] = true;
        delayResult[stackDepth] = false;
        delayInside[stackDepth] = false;
        vetoTerm[stackDepth] = false;
        vetoInside[stackDepth] = false;
        instructionDepth[stackDepth] = 0;
        stackDepth += 1;
        break;
      case "NOT": {
        if (stackDepth < 1) {
          issues.push(`${prefix}.op requires one stack item`);
          break;
        }
        if (!bareSignal[stackDepth - 1] && !delayResult[stackDepth - 1]) {
          issues.push(
            `${prefix}.op requires a bare SIGNAL operand `
              + "(contract _validateHook reverts InvalidInstruction for NOT over composite operands)",
          );
        }
        const operandIsDelayResult = delayResult[stackDepth - 1] === true;
        vetoTerm[stackDepth - 1] = operandIsDelayResult;
        vetoInside[stackDepth - 1] = vetoInside[stackDepth - 1] === true || operandIsDelayResult;
        bareSignal[stackDepth - 1] = false;
        delayResult[stackDepth - 1] = false;
        hasPosAnchor[stackDepth - 1] = false;
        instructionDepth[stackDepth - 1] = (instructionDepth[stackDepth - 1] ?? 0) + 1;
        const depthIssue = instructionDepthIssue(
          prefix,
          instructionDepth[stackDepth - 1]!,
          "_validateHook",
        );
        if (depthIssue !== undefined) {
          issues.push(depthIssue);
        }
        break;
      }
      case "AND":
      case "OR": {
        if (
          !Number.isSafeInteger(instruction.arity) ||
          Number(instruction.arity) < 2
        ) {
          issues.push(`${prefix}.arity must be a safe integer greater than 1`);
          break;
        }
        const arity = Number(instruction.arity);
        if (stackDepth < arity) {
          issues.push(`${prefix}.op requires ${arity} stack items`);
          break;
        }
        const firstOperand = stackDepth - arity;
        if (instruction.op === "OR") {
          for (let j = firstOperand; j < stackDepth; j++) {
            if (vetoTerm[j]) {
              issues.push(
                `${prefix}.op cannot take a decaying veto operand; `
                  + "decaying veto NOT-over-DELAY is only legal as a direct AND operand "
                  + "(contract _validateHook reverts InvalidInstruction; the core validator rejects "
                  + "the root/OR/NOT/delay-operand positions)",
              );
            }
          }
        }
        const anchored =
          instruction.op === "AND"
            ? hasPosAnchor
                .slice(firstOperand, stackDepth)
                .some(Boolean)
            : hasPosAnchor
                .slice(firstOperand, stackDepth)
                .every(Boolean);
        const vetoInsideResult = vetoInside
          .slice(firstOperand, stackDepth)
          .some(Boolean);
        const delayInsideResult = delayInside
          .slice(firstOperand, stackDepth)
          .some(Boolean);
        const operandDepth = Math.max(
          ...instructionDepth.slice(firstOperand, stackDepth),
        );
        stackDepth = firstOperand + 1;
        bareSignal[stackDepth - 1] = false;
        delayResult[stackDepth - 1] = false;
        delayInside[stackDepth - 1] = delayInsideResult;
        vetoTerm[stackDepth - 1] = false;
        vetoInside[stackDepth - 1] = vetoInsideResult;
        hasPosAnchor[stackDepth - 1] = anchored;
        instructionDepth[stackDepth - 1] = operandDepth + 1;
        const depthIssue = instructionDepthIssue(
          prefix,
          instructionDepth[stackDepth - 1]!,
          "_validateHook",
        );
        if (depthIssue !== undefined) {
          issues.push(depthIssue);
        }
        break;
      }
      case "DELAY":
        if (
          !Number.isSafeInteger(instruction.delaySeconds) ||
          Number(instruction.delaySeconds) <= 0
        ) {
          issues.push(`${prefix}.delaySeconds must be a positive safe integer`);
        } else if (
          Number(instruction.delaySeconds) > MAX_ONCHAIN_HOOK_DELAY_SECONDS
        ) {
          issues.push(
            `${prefix}.delaySeconds must not exceed ${MAX_ONCHAIN_HOOK_DELAY_SECONDS} `
            + "(contract MAX_HOOK_DELAY_SECONDS = 30 days, reverts HookDelayTooLong)",
          );
        }
        if (stackDepth < 1) {
          issues.push(`${prefix}.op requires one stack item`);
          break;
        }
        if (options.orderTrigger) {
          issues.push(
            `${prefix}.op DELAY is not allowed on order-trigger hooks `
            + "(contract _validateHook reverts InvalidInstruction; birth facts settle at order creation)",
          );
        }
        if (!hasPosAnchor[stackDepth - 1]) {
          issues.push(
            `${prefix}.op DELAY requires an operand with a positive signal anchor `
              + "(contract _validateHook reverts InvalidInstruction for delay over purely-negative operands)",
          );
        }
        if (delayInside[stackDepth - 1]) {
          issues.push(
            `${prefix}.op DELAY cannot consume an operand containing another DELAY `
              + "(contract _validateHook reverts InvalidInstruction for nested delay operands; "
              + "collapse the chain into a single duration)",
          );
        }
        if (vetoTerm[stackDepth - 1] || vetoInside[stackDepth - 1]) {
          issues.push(
            `${prefix}.op DELAY cannot consume an operand containing a decaying veto `
            + "(contract _validateHook reverts InvalidInstruction; a decaying veto's readiness expires "
            + "while delay maturity is permanent, so the outer delay would anchor on an expired veto)",
          );
        }
        bareSignal[stackDepth - 1] = false;
        delayResult[stackDepth - 1] = true;
        delayInside[stackDepth - 1] = true;
        vetoTerm[stackDepth - 1] = false;
        vetoInside[stackDepth - 1] = false;
        instructionDepth[stackDepth - 1] = (instructionDepth[stackDepth - 1] ?? 0) + 1;
        const depthIssue = instructionDepthIssue(
          prefix,
          instructionDepth[stackDepth - 1]!,
          "_validateHook",
        );
        if (depthIssue !== undefined) {
          issues.push(depthIssue);
        }
        break;
      default:
        issues.push(`${prefix}.op must be one of SIGNAL, NOT, AND, OR, DELAY`);
    }
  }

  if (stackDepth !== 1) {
    issues.push(`${path} must leave exactly one stack item`);
  } else if (vetoTerm[0]) {
    issues.push(
      `${path} leaves a decaying veto at the root; `
        + "decaying veto NOT-over-DELAY is only legal as a direct AND operand "
        + "(contract _validateHook reverts InvalidInstruction)",
    );
  } else if (!hasPosAnchor[0]) {
    issues.push(
      `${path} must contain at least one positive signal anchor `
      + "(contract _validateHook reverts InvalidInstruction for purely-negative hook conditions)",
    );
  }

  return issues;
}

function validateAdmissionInstructions(
  instructions: readonly unknown[],
  path: string,
): readonly string[] {
  const issues: string[] = [];
  let stackDepth = 0;
  const bareSignal: boolean[] = [];
  const delayResult: boolean[] = [];
  const hasPosAnchor: boolean[] = [];
  const delayInside: boolean[] = [];
  const instructionDepth: number[] = [];

  for (const [index, instruction] of instructions.entries()) {
    if (!isRecord(instruction)) {
      issues.push(`${path}[${index}] must be an object`);
      continue;
    }

    const prefix = `${path}[${index}]`;
    expectInstructionKeyClosure(instruction, prefix, issues);
    switch (instruction.op) {
      case "SIGNAL":
        expectString(instruction.source, `${prefix}.source`, issues);
        expectNonEmptyString(
          instruction.signalName,
          `${prefix}.signalName`,
          issues,
        );
        expectHexHash(instruction.sourceId, `${prefix}.sourceId`, issues);
        expectHexHash(instruction.signalId, `${prefix}.signalId`, issues);
        expectHexHash(instruction.signalKey, `${prefix}.signalKey`, issues);
        if (
          typeof instruction.source === "string" &&
          typeof instruction.sourceId === "string" &&
          instruction.sourceId !== onchainSourceId(instruction.source)
        ) {
          issues.push(`${prefix}.sourceId must be keccak256(source)`);
        }
        if (
          typeof instruction.signalName === "string" &&
          typeof instruction.signalId === "string" &&
          instruction.signalId !== onchainSignalId(instruction.signalName)
        ) {
          issues.push(
            `${prefix}.signalId must be keccak256(stage.signal)`,
          );
        }
        if (
          typeof instruction.sourceId === "string" &&
          typeof instruction.signalId === "string" &&
          isHexHash(instruction.sourceId) &&
          isHexHash(instruction.signalId) &&
          instruction.signalKey !==
            onchainSignalKey(instruction.sourceId, instruction.signalId)
        ) {
          issues.push(
            `${prefix}.signalKey must be keccak256(abi.encodePacked(sourceId, signalId))`,
          );
        }
        bareSignal[stackDepth] = true;
        delayResult[stackDepth] = false;
        hasPosAnchor[stackDepth] = true;
        delayInside[stackDepth] = false;
        instructionDepth[stackDepth] = 0;
        stackDepth += 1;
        break;
      case "NOT": {
        if (stackDepth < 1) {
          issues.push(`${prefix}.op requires one stack item`);
          break;
        }
        if (!bareSignal[stackDepth - 1] && !delayResult[stackDepth - 1]) {
          issues.push(
            `${prefix}.op requires a bare SIGNAL operand `
              + "(contract _validateAdmission reverts InvalidInstruction for NOT over composite operands)",
          );
        }
        bareSignal[stackDepth - 1] = false;
        delayResult[stackDepth - 1] = false;
        hasPosAnchor[stackDepth - 1] = false;
        instructionDepth[stackDepth - 1] = (instructionDepth[stackDepth - 1] ?? 0) + 1;
        const depthIssue = instructionDepthIssue(
          prefix,
          instructionDepth[stackDepth - 1]!,
          "_validateAdmission",
        );
        if (depthIssue !== undefined) {
          issues.push(depthIssue);
        }
        break;
      }
      case "AND":
      case "OR": {
        if (
          !Number.isSafeInteger(instruction.arity) ||
          Number(instruction.arity) < 2
        ) {
          issues.push(`${prefix}.arity must be a safe integer greater than 1`);
          break;
        }
        const arity = Number(instruction.arity);
        if (stackDepth < arity) {
          issues.push(`${prefix}.op requires ${arity} stack items`);
          break;
        }
        const firstOperand = stackDepth - arity;
        const delayInsideResult = delayInside
          .slice(firstOperand, stackDepth)
          .some(Boolean);
        const anchored = hasPosAnchor
          .slice(firstOperand, stackDepth)
          .some(Boolean);
        const operandDepth = Math.max(
          ...instructionDepth.slice(firstOperand, stackDepth),
        );
        stackDepth = firstOperand + 1;
        bareSignal[stackDepth - 1] = false;
        delayResult[stackDepth - 1] = false;
        delayInside[stackDepth - 1] = delayInsideResult;
        hasPosAnchor[stackDepth - 1] = anchored;
        instructionDepth[stackDepth - 1] = operandDepth + 1;
        const depthIssue = instructionDepthIssue(
          prefix,
          instructionDepth[stackDepth - 1]!,
          "_validateAdmission",
        );
        if (depthIssue !== undefined) {
          issues.push(depthIssue);
        }
        break;
      }
      case "DELAY":
        if (
          !Number.isSafeInteger(instruction.delaySeconds) ||
          Number(instruction.delaySeconds) <= 0
        ) {
          issues.push(`${prefix}.delaySeconds must be a positive safe integer`);
        } else if (
          Number(instruction.delaySeconds) > MAX_ONCHAIN_HOOK_DELAY_SECONDS
        ) {
          issues.push(
            `${prefix}.delaySeconds must not exceed ${MAX_ONCHAIN_HOOK_DELAY_SECONDS} `
              + "(contract MAX_HOOK_DELAY_SECONDS = 30 days, reverts HookDelayTooLong)",
          );
        }
        if (stackDepth < 1) {
          issues.push(`${prefix}.op requires one stack item`);
          break;
        }
        if (!hasPosAnchor[stackDepth - 1]) {
          issues.push(
            `${prefix}.op DELAY requires an operand with a positive signal anchor `
              + "(contract _validateAdmission reverts InvalidInstruction for delay over anchorless operands "
              + "(UB-1: an anchorless delay never matures on the evaluation side))",
          );
        }
        if (delayInside[stackDepth - 1]) {
          issues.push(
            `${prefix}.op DELAY cannot consume an operand containing another DELAY `
              + "(contract _validateAdmission reverts InvalidInstruction for nested delay operands)",
          );
        }
        bareSignal[stackDepth - 1] = false;
        delayResult[stackDepth - 1] = true;
        delayInside[stackDepth - 1] = true;
        instructionDepth[stackDepth - 1] = (instructionDepth[stackDepth - 1] ?? 0) + 1;
        const depthIssue = instructionDepthIssue(
          prefix,
          instructionDepth[stackDepth - 1]!,
          "_validateAdmission",
        );
        if (depthIssue !== undefined) {
          issues.push(depthIssue);
        }
        break;
      default:
        issues.push(`${prefix}.op must be one of SIGNAL, NOT, AND, OR, DELAY`);
    }
  }

  if (stackDepth !== 1) {
    issues.push(`${path} must leave exactly one stack item`);
  }

  return issues;
}

function validateOnchainCompiledAdmissions(
  admissions: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  const admissionIds = new Set<string>();
  const declaredSignals = new Set<string>();

  for (const [index, admission] of admissions.entries()) {
    if (!isRecord(admission)) {
      issues.push(`admissions[${index}] must be an object`);
      continue;
    }

    const prefix = `admissions[${index}]`;
    expectClosedKeySet(admission, ADMISSION_FIELDS, prefix, issues);
    expectHexHash(admission.admissionId, `${prefix}.admissionId`, issues);
    expectHexHash(admission.stageId, `${prefix}.stageId`, issues);
    expectHexHash(admission.signalId, `${prefix}.signalId`, issues);
    expectHexHash(admission.sourceId, `${prefix}.sourceId`, issues);
    expectNonEmptyString(
      admission.stageIdentifier,
      `${prefix}.stageIdentifier`,
      issues,
    );
    expectNonEmptyString(admission.signalName, `${prefix}.signalName`, issues);

    if (
      typeof admission.stageIdentifier === "string" &&
      typeof admission.stageId === "string" &&
      admission.stageId !== onchainStageId(admission.stageIdentifier)
    ) {
      issues.push(`${prefix}.stageId must be keccak256(stageIdentifier)`);
    }
    if (
      typeof admission.signalName === "string" &&
      typeof admission.signalId === "string" &&
      admission.signalId !== onchainSignalId(admission.signalName)
    ) {
      issues.push(`${prefix}.signalId must be keccak256(stage.signal)`);
    }
    if (
      typeof admission.sourceId === "string" &&
      typeof admission.signalId === "string" &&
      isHexHash(admission.sourceId) &&
      isHexHash(admission.signalId) &&
      admission.admissionId !==
        onchainSignalKey(admission.sourceId, admission.signalId)
    ) {
      issues.push(
        `${prefix}.admissionId must be keccak256(abi.encodePacked(sourceId, signalId)) `
          + "(the on-chain admission store is keyed by the emitted fact's signalKey)",
      );
    }
    if (typeof admission.admissionId === "string") {
      if (admissionIds.has(admission.admissionId)) {
        issues.push(`duplicate admissionId ${admission.admissionId}`);
      }
      admissionIds.add(admission.admissionId);
    }
    if (
      typeof admission.stageIdentifier === "string" &&
      typeof admission.signalName === "string"
    ) {
      const declared = `${admission.stageIdentifier}\u0000${admission.signalName}`;
      if (declaredSignals.has(declared)) {
        issues.push(
          `duplicate admission ${admission.stageIdentifier}::${admission.signalName}`,
        );
      }
      declaredSignals.add(declared);
    }

    if (!Array.isArray(admission.instructions)) {
      issues.push(`${prefix}.instructions must be an array`);
    } else if (admission.instructions.length === 0) {
      issues.push(
        `${prefix}.instructions must not be empty (contract reverts InvalidHook)`,
      );
    } else {
      issues.push(
        ...validateAdmissionInstructions(
          admission.instructions,
          `${prefix}.instructions`,
        ),
      );
    }

    if (!Array.isArray(admission.dependencies)) {
      issues.push(`${prefix}.dependencies must be an array`);
    } else {
      issues.push(
        ...validateOnchainDependencies(
          admission.dependencies,
          `${prefix}.dependencies`,
        ),
      );
      const signalKeys = new Set<string>();
      if (Array.isArray(admission.instructions)) {
        for (const instruction of admission.instructions) {
          if (
            isRecord(instruction) &&
            instruction.op === "SIGNAL" &&
            typeof instruction.signalKey === "string"
          ) {
            signalKeys.add(instruction.signalKey);
          }
        }
      }
      const dependencyKeys = new Set<string>();
      for (const dependency of admission.dependencies) {
        if (isRecord(dependency) && typeof dependency.signalKey === "string") {
          dependencyKeys.add(dependency.signalKey);
        }
      }
      for (const key of dependencyKeys) {
        if (!signalKeys.has(key)) {
          issues.push(
            `${prefix}.dependencies key ${key} is not a SIGNAL atom of this admission `
              + "(contract _validateAdmission reverts HookDependencyKeyMismatch)",
          );
        }
      }
      for (const key of signalKeys) {
        if (!dependencyKeys.has(key)) {
          issues.push(
            `${prefix}.instructions SIGNAL key ${key} is not declared in dependencies `
              + "(contract _validateAdmission reverts HookDependencyKeyMismatch)",
          );
        }
      }
    }
  }

  return issues;
}

function validateOnchainDependencies(
  dependencies: readonly unknown[],
  path: string,
): readonly string[] {
  const issues: string[] = [];
  if (dependencies.length === 0) {
    issues.push(
      `${path} must not be empty `
      + "(contract reverts InvalidHook for empty dependencyKeys)",
    );
  }
  for (const [index, dependency] of dependencies.entries()) {
    if (!isRecord(dependency)) {
      issues.push(`${path}[${index}] must be an object`);
      continue;
    }

    const prefix = `${path}[${index}]`;
    expectClosedKeySet(dependency, DEPENDENCY_FIELDS, prefix, issues);
    expectOneOf(
      dependency.kind,
      ["positive", "negative", "timer"],
      `${prefix}.kind`,
      issues,
    );
    expectString(dependency.source, `${prefix}.source`, issues);
    expectNonEmptyString(dependency.signalName, `${prefix}.signalName`, issues);
    expectHexHash(dependency.sourceId, `${prefix}.sourceId`, issues);
    expectHexHash(dependency.signalId, `${prefix}.signalId`, issues);
    expectHexHash(dependency.signalKey, `${prefix}.signalKey`, issues);
    if (
      typeof dependency.source === "string" &&
      typeof dependency.sourceId === "string" &&
      dependency.sourceId !== onchainSourceId(dependency.source)
    ) {
      issues.push(`${prefix}.sourceId must be keccak256(source)`);
    }
    if (
      typeof dependency.signalName === "string" &&
      typeof dependency.signalId === "string" &&
      dependency.signalId !== onchainSignalId(dependency.signalName)
    ) {
      issues.push(`${prefix}.signalId must be keccak256(stage.signal)`);
    }
    if (
      typeof dependency.sourceId === "string" &&
      typeof dependency.signalId === "string" &&
      isHexHash(dependency.sourceId) &&
      isHexHash(dependency.signalId) &&
      dependency.signalKey !==
        onchainSignalKey(dependency.sourceId, dependency.signalId)
    ) {
      issues.push(
        `${prefix}.signalKey must be keccak256(abi.encodePacked(sourceId, signalId))`,
      );
    }
    if (dependency.delaySeconds !== undefined) {
      if (
        !Number.isSafeInteger(dependency.delaySeconds) ||
        Number(dependency.delaySeconds) <= 0
      ) {
        issues.push(
          `${prefix}.delaySeconds must be a positive safe integer when present`,
        );
      }
    }
    if (
      dependency.kind === "timer" &&
      (typeof dependency.delaySeconds !== "number" ||
        !Number.isSafeInteger(dependency.delaySeconds) ||
        Number(dependency.delaySeconds) <= 0)
    ) {
      issues.push(
        `${prefix}.delaySeconds must be a positive safe integer for timer dependencies`,
      );
    }
  }
  return issues;
}

function unmaterializableStageIssues(
  hooks: readonly OnchainCompiledHook[],
  declaredStages: ReadonlySet<string>,
): readonly string[] {
  const issues: string[] = [];
  const stageMaterializer = new Map<string, boolean>();
  for (const hook of hooks) {
    const canMaterialize =
      hook.orderTriggerKind !== "none" || hook.emitReady;
    const current = stageMaterializer.get(hook.stageId) ?? false;
    stageMaterializer.set(hook.stageId, current || canMaterialize);
  }
  for (const hook of hooks) {
    if (stageMaterializer.get(hook.stageId)) {
      continue;
    }
    issues.push(
      `stage ${hook.stageIdentifier} has no order-trigger or EMIT_READY hook; its hooks compile to flags=0 watchers which can never materialize the stage on-chain (deadlock, no recovery path) — the Rust compiler must reject this shape`,
    );
  }
  for (const stageIdentifier of [...declaredStages].sort(compareCanonicalKey)) {
    if (stageMaterializer.has(onchainStageId(stageIdentifier))) {
      continue;
    }
    issues.push(
      `stage ${stageIdentifier} declares no receiveSignals and compiles to zero hooks: `
        + "the stage can never materialize on-chain (materialization only happens via "
        + "this stage's own order-trigger/EMIT_READY hooks) and its sendSignals have "
        + "no hook to hang on — submitSignal requires the source stage to be "
        + "materialized and reverts UnknownHook forever (deadlock, no recovery path); "
        + "declare a trigger signal, receiveSignals, or a static supplier",
    );
  }
  return issues;
}

function declaredStageIdentifiers(
  ...identifierGroups: readonly (readonly (string | undefined)[])[]
): Set<string> {
  const identifiers = new Set<string>();
  for (const group of identifierGroups) {
    for (const identifier of group) {
      if (typeof identifier === "string" && identifier.trim().length > 0) {
        identifiers.add(identifier);
      }
    }
  }
  return identifiers;
}

function silentOrderTriggerIssues(
  hooks: readonly OnchainCompiledHook[],
): readonly string[] {
  const issues: string[] = [];
  for (const hook of hooks) {
    if (hook.orderTriggerKind !== "none" && !hook.emitReady) {
      issues.push(
        `hook ${hook.stageIdentifier}#${hook.hookName} is an order trigger without emitReady; ` +
          `UVPStateMachine.commitPlan reverts SilentOrderTriggerHook — ` +
          `the Rust compiler must always emit trigger flags with EMIT_READY`,
      );
    }
  }
  return issues;
}

function dockStageRouteIssues(
  hooks: readonly unknown[],
  supplierRoutes: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  const routedStages = new Set<string>();
  for (const route of supplierRoutes) {
    if (isRecord(route) && typeof route.stageIdentifier === "string") {
      routedStages.add(route.stageIdentifier);
    }
  }
  const reported = new Set<string>();
  for (const hook of hooks) {
    if (
      !isRecord(hook) ||
      hook.dockExecutor !== true ||
      typeof hook.stageIdentifier !== "string" ||
      !routedStages.has(hook.stageIdentifier) ||
      reported.has(hook.stageIdentifier)
    ) {
      continue;
    }
    reported.add(hook.stageIdentifier);
    issues.push(
      `dock stage ${hook.stageIdentifier} must not carry a supplier route; `
        + "its executor is selected once through the stage supplier patch (dkid), so a plan-level route would pin the wrong executor",
    );
  }
  return issues;
}

function dynamicStageRouteIssues(
  hooks: readonly unknown[],
  supplierRoutes: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  const dynamicStages = new Set<string>();
  for (const hook of hooks) {
    if (
      isRecord(hook) &&
      hook.dynamicExecutor === true &&
      typeof hook.stageIdentifier === "string"
    ) {
      dynamicStages.add(hook.stageIdentifier);
    }
  }
  const reported = new Set<string>();
  for (const route of supplierRoutes) {
    if (
      !isRecord(route) ||
      typeof route.stageIdentifier !== "string" ||
      !dynamicStages.has(route.stageIdentifier) ||
      reported.has(route.stageIdentifier)
    ) {
      continue;
    }
    reported.add(route.stageIdentifier);
    issues.push(
      `dynamic stage ${route.stageIdentifier} must not carry a supplier route; `
        + "a dynamic stage has no plan-default supplier, so a route would pin an executor the plan never binds",
    );
  }
  return issues;
}

function validateOnchainDependencyIndex(
  hooks: readonly unknown[],
  dependencyIndex: Record<string, readonly string[]>,
): readonly string[] {
  const issues: string[] = [];
  const recomputed = new Map<string, string[]>();
  for (const hook of hooks) {
    if (
      !isRecord(hook) ||
      typeof hook.hookId !== "string" ||
      !Array.isArray(hook.dependencies)
    ) {
      continue;
    }
    for (const dependency of hook.dependencies) {
      if (!isOnchainHookDependency(dependency)) {
        continue;
      }
      const hookIds = recomputed.get(dependency.signalKey) ?? [];
      if (!hookIds.includes(hook.hookId)) {
        hookIds.push(hook.hookId);
      }
      recomputed.set(dependency.signalKey, hookIds);
    }
  }

  const expected = Object.fromEntries(
    [...recomputed.entries()]
      .sort(([left], [right]) => compareCanonicalKey(left, right))
      .map(([signalKey, hookIds]) => [signalKey, hookIds]),
  );
  if (JSON.stringify(expected) !== JSON.stringify(dependencyIndex)) {
    issues.push("dependencyIndex must match on-chain hook dependencies");
  }
  return issues;
}

function isOnchainHookDependency(
  value: unknown,
): value is OnchainHookDependency {
  return (
    isRecord(value) &&
    (value.kind === "positive" ||
      value.kind === "negative" ||
      value.kind === "timer") &&
    typeof value.source === "string" &&
    typeof value.signalName === "string" &&
    isHexHash(value.sourceId) &&
    isHexHash(value.signalId) &&
    isHexHash(value.signalKey)
  );
}

export {
  validateOnchainCompiledHooks,
  validateOnchainCompiledAdmissions,
  unmaterializableStageIssues,
  declaredStageIdentifiers,
  silentOrderTriggerIssues,
  dockStageRouteIssues,
  validateOnchainDependencyIndex,
  dynamicStageRouteIssues,
};

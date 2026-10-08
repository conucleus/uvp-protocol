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
import { MAX_ONCHAIN_HOOK_DELAY_SECONDS } from "./limits.js";
import type {
  OnchainCompiledHook,
  OnchainHookDependency,
} from "../../types/index.js";

/**
 * hook 族校验（自 onchain-hook-plan.ts 原样迁入）：compiledHooks 形状与
 * _validateHook 栈机镜像、依赖形状、阶段物化门、HookReady 三线口径、跨
 * 阶段依赖门与依赖索引重算。编译入口 preflight 与反序列化边界共用。
 */

/**
 * compiledHooks[i] 及更深对象（instructions/dependencies/routeRef、
 * admissions 条目）的封闭键集（与 types/index.ts 声明同步）：顶层已有
 * unknown-field 拒绝，深层缺同款闭包会让"唯一字节数组形态"承诺在深层
 * fail-open。
 */
const COMPILED_HOOK_FIELDS: readonly string[] = [
  "hookId",
  "stageId",
  "stageIdentifier",
  "hookName",
  "kind",
  "orderTriggerKind",
  "emitReady",
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
/** 指令键集按 op 闭包（未声明 op 无键集可查，由 op 词表 issue 报告）。 */
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
  executorRoutes: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  const hookIds = new Set<string>();
  const routeIds = new Set(
    executorRoutes
      .filter(isRecord)
      .map((route) => route.routeId)
      .filter((routeId): routeId is string => typeof routeId === "string"),
  );
  const routesById = new Map<string, Record<string, unknown>>();
  for (const route of executorRoutes) {
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
      ["none", "mint", "dock"],
      `${prefix}.orderTriggerKind`,
      issues,
    );
    expectBoolean(hook.emitReady, `${prefix}.emitReady`, issues);

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
      // 合约镜像：dependencyKeys 与指令集 SIGNAL 原子键逐点一致
      // （UVPStateMachine._validateHook reverts HookDependencyKeyMismatch）。
      // 未声明的 SIGNAL 键不进 dependencyIndex——该事实到达永不触发求值，
      // hook 永久 Init 且零告警；多声明的键只是死索引。
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
            `${prefix}.routeRef.routeId must reference executorRoutes`,
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
              `${prefix}.routeRef.routeHash must match the referenced executor route`,
            );
          }
        }
      }
    }
  }

  return issues;
}

/**
 * 镜像 UVPStateMachine._validateHook 的栈机语义（bareSignal/hasPosAnchor
 * 双轨 + 否决位位置轨），形状校验与语义镜像同址：形状坏项计入 issues 后
 * 仍按合同口径推进栈机，让单次校验暴露全部缺口。
 */
function validateInstructions(
  instructions: readonly unknown[],
  path: string,
  options: { readonly orderTrigger: boolean },
): readonly string[] {
  const issues: string[] = [];
  let stackDepth = 0;
  const bareSignal: boolean[] = [];
  const hasPosAnchor: boolean[] = [];
  // DELAY 产出标志：NOT 的第二类合法操作数（衰减否决位内层）。
  const delayResult: boolean[] = [];
  // 否决位标志（本槽即 NOT-over-DELAY，尚待合取父项消费）与子树含否决位
  // 标志（穿透 AND/OR）——位置规则镜像 uvp-hook-dsl validate_anchors 的
  // veto_slot / inside_delay_operand 双闸与合约 _validateHook 的同位判定。
  const vetoTerm: boolean[] = [];
  const vetoInside: boolean[] = [];

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
        vetoTerm[stackDepth] = false;
        vetoInside[stackDepth] = false;
        stackDepth += 1;
        break;
      case "NOT": {
        if (stackDepth < 1) {
          issues.push(`${prefix}.op requires one stack item`);
          break;
        }
        // NOT 操作数词表（_validateHook 镜像）：裸 SIGNAL（现状），或
        // DELAY 产出（衰减否决位 ~(A+duration)，唯一合法位置是合取直接
        // 子项——位置由 vetoTerm 位交给消费方校验）。~(A&B) 一类组合否定
        // 的取消/锚点语义与编译器产物形态分叉，注册边界拒绝。
        if (!bareSignal[stackDepth - 1] && !delayResult[stackDepth - 1]) {
          issues.push(
            `${prefix}.op requires a bare SIGNAL operand `
              + "(contract _validateHook reverts InvalidInstruction for NOT over composite operands)",
          );
        }
        // （数组下标读取在 noUncheckedIndexedAccess 下带 undefined——
        // `=== true` 折回布尔，缺席即 false。）
        const operandIsDelayResult = delayResult[stackDepth - 1] === true;
        vetoTerm[stackDepth - 1] = operandIsDelayResult;
        vetoInside[stackDepth - 1] = vetoInside[stackDepth - 1] === true || operandIsDelayResult;
        bareSignal[stackDepth - 1] = false;
        delayResult[stackDepth - 1] = false;
        hasPosAnchor[stackDepth - 1] = false;
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
        // 否决位唯一合法位置是合取直接子项（_validateHook 镜像）：Or 分支
        // 位一律拒绝。
        if (instruction.op === "OR") {
          for (let j = stackDepth - arity; j < stackDepth; j++) {
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
        // And 取任一正锚，Or 需每一分支都有（Or 的缺席分支可单独就绪且
        // 锚点为 0）——只被 DELAY 的操作数正锚检查消费。
        const anchored =
          instruction.op === "AND"
            ? hasPosAnchor
                .slice(stackDepth - arity, stackDepth)
                .some(Boolean)
            : hasPosAnchor
                .slice(stackDepth - arity, stackDepth)
                .every(Boolean);
        const vetoInsideResult = vetoInside
          .slice(stackDepth - arity, stackDepth)
          .some(Boolean);
        stackDepth = stackDepth - arity + 1;
        bareSignal[stackDepth - 1] = false;
        delayResult[stackDepth - 1] = false;
        vetoTerm[stackDepth - 1] = false;
        vetoInside[stackDepth - 1] = vetoInsideResult;
        hasPosAnchor[stackDepth - 1] = anchored;
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
        // order-trigger hook 内禁止 DELAY（_validateHook 镜像）：出生事实
        // 与订单创建同笔交易，DELAY 只会让出生路径永久 InvalidTriggerHook。
        if (options.orderTrigger) {
          issues.push(
            `${prefix}.op DELAY is not allowed on order-trigger hooks `
            + "(contract _validateHook reverts InvalidInstruction; birth facts settle at order creation)",
          );
        }
        // 延时操作数须含正向信号锚点（validate_anchors 镜像）：全否定/
        // 缺席的操作数在 value=true 时 anchorAt=0，到期时刻恒在过去。
        if (!hasPosAnchor[stackDepth - 1]) {
          issues.push(
            `${prefix}.op DELAY requires an operand with a positive signal anchor `
              + "(contract _validateHook reverts InvalidInstruction for delay over purely-negative operands)",
          );
        }
        // Delay 操作数内任何深度禁止否决位（_validateHook 镜像）：否决位
        // 的 Ready 会衰减而 Delay 成熟是永久的——外层延时锚在已过期的
        // 否决上会静默放行。
        if (vetoTerm[stackDepth - 1] || vetoInside[stackDepth - 1]) {
          issues.push(
            `${prefix}.op DELAY cannot consume an operand containing a decaying veto `
              + "(contract _validateHook reverts InvalidInstruction; a decaying veto's readiness expires "
              + "while delay maturity is permanent, so the outer delay would anchor on an expired veto)",
          );
        }
        bareSignal[stackDepth - 1] = false;
        delayResult[stackDepth - 1] = true;
        vetoTerm[stackDepth - 1] = false;
        vetoInside[stackDepth - 1] = false;
        break;
      default:
        issues.push(`${prefix}.op must be one of SIGNAL, NOT, AND, OR, DELAY`);
    }
  }

  // Aligned with UVPStateMachine._validateHook: `hook.instructions.length == 0`
  // reverts InvalidHook on-chain, so an empty instruction array must fail the
  // preflight too (stack depth 0 !== 1 below).
  if (stackDepth !== 1) {
    issues.push(`${path} must leave exactly one stack item`);
  } else if (vetoTerm[0]) {
    // 根位否决位（_validateHook 镜像）：否决位必须由合取父项消费。
    issues.push(
      `${path} leaves a decaying veto at the root; `
        + "decaying veto NOT-over-DELAY is only legal as a direct AND operand "
        + "(contract _validateHook reverts InvalidInstruction)",
    );
  } else if (!hasPosAnchor[0]) {
    // 整体至少一正锚（validate_anchors 镜像）：纯否定条件在 value=true 时
    // anchorAt=0，注册边界拒绝。
    issues.push(
      `${path} must contain at least one positive signal anchor `
      + "(contract _validateHook reverts InvalidInstruction for purely-negative hook conditions)",
    );
  }

  return issues;
}

/**
 * 镜像 UVPPlanRegistration._validateAdmission 的过滤档栈机（_validateHook
 * 的过滤档兄弟）：适格面只在到达一拍对 pre-state 求值、不参与任何调度——
 * 无正锚要求（根/OR 分支/延时操作数均不要求），衰减否决位 ~(A+duration)
 * 位置全放开（任何位置的瞬时值都良定义）。与钩子档同源的保留闸：NOT
 * 操作数词表（裸 SIGNAL 或 DELAY 产出）、duration ∈ (0, 30d]、AND/OR
 * arity ≥ 2、栈深、结束恰一值。自引用/出生锚/订阅原子是编译期拒绝
 * （core D028-D030），注册门看到的只有指令形态。
 */
function validateAdmissionInstructions(
  instructions: readonly unknown[],
  path: string,
): readonly string[] {
  const issues: string[] = [];
  let stackDepth = 0;
  // 裸 SIGNAL 栈标志与 DELAY 产出标志：NOT 操作数词表的判定面（过滤档
  // 不需要锚点/否决位位置轨）。
  const bareSignal: boolean[] = [];
  const delayResult: boolean[] = [];

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
        stackDepth += 1;
        break;
      case "NOT": {
        if (stackDepth < 1) {
          issues.push(`${prefix}.op requires one stack item`);
          break;
        }
        // NOT 操作数词表（_validateAdmission 镜像，与钩子档同源）：裸
        // SIGNAL 或 DELAY 产出。~(A&B) 一类组合否定的取消/求值语义与
        // 编译器产物形态分叉，注册边界拒绝。
        if (!bareSignal[stackDepth - 1] && !delayResult[stackDepth - 1]) {
          issues.push(
            `${prefix}.op requires a bare SIGNAL operand `
              + "(contract _validateAdmission reverts InvalidInstruction for NOT over composite operands)",
          );
        }
        bareSignal[stackDepth - 1] = false;
        delayResult[stackDepth - 1] = false;
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
        stackDepth = stackDepth - arity + 1;
        bareSignal[stackDepth - 1] = false;
        delayResult[stackDepth - 1] = false;
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
        // 过滤档无锚点闸、无否决位位置闸：延时操作数可以纯否定/含否决位
        // （一拍求值下瞬时值良定义，无外层调度可被过期锚静默放行）。
        bareSignal[stackDepth - 1] = false;
        delayResult[stackDepth - 1] = true;
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

/**
 * 适格面 artifact 校验（编译入口 preflight 与反序列化边界共用）：条目
 * 形状、admissionId/stageId/signalId 派生重算、(stageIdentifier,
 * signalName) 与 admissionId 去重、指令集过滤档镜像、依赖形状与
 * dependencyKeys ≡ SIGNAL 原子键逐点一致（合约 _validateAdmission 的
 * HookDependencyKeyMismatch 镜像——未声明键的事实到达永不触发求值面，
 * 但适格是提交时求值，键错位意味着制品与链上注册面分叉）。
 */
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
  // Aligned with UVPStateMachine._validateHook: `hook.dependencyKeys.length == 0`
  // reverts InvalidHook on-chain, so a hook without dependencies is invalid
  // at the artifact boundary as well.
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
      // E12：delaySeconds 只要在场就必须是正安全整数——非数值/NaN/零/负数
      // 一律拒绝，不按 kind 静默放行。
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

/**
 * 阶段物化门（onchain target，镜像 uvp-core 的
 * validate_onchain_stage_materialization）：
 *
 * - 每个出现在 compiledHooks 的阶段必须至少有一个 order-trigger 或
 *   EMIT_READY hook（能物化自身阶段的 hook）。纯 flags=0 watcher 阶段在
 *   链上永远无法物化——挂在其上的任何 hook 都构成不可恢复死锁。
 * - 每个在 artifact 上留有声明投影（signalCapabilities / executorRoutes /
 *   selectorBindings）的阶段不得编译为零 hook——零 hook 阶段同样永不可
 *   物化，且其 sendSignals 在链上没有钩子可挂（submitSignal 恒 revert
 *   UnknownHook）。Rust 定义层第一道拒绝（"declares no receiveSignals"），
 *   这里是 artifact 边界的第二道。
 *
 * dock entrance 豁免口径与 Rust dock_entrance_hook_ids 单一来源一致：entrance
 * 端口钩子在两个编译器里都编译为 orderTriggerKind=dock（dock|emitReady=6），
 * 因此 artifact 层只认编译后的物化位本身、不再从 dockInterface 端口重推——
 * flags 即该豁免的产物投影，重推属于镜像扩张。
 */
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
        + "declare receiveSignals carrying a mint/dock entrance or a static executor",
    );
  }
  return issues;
}

/**
 * artifact 边界可见的“阶段声明”全集：sendSignals（signalCapabilities）、
 * executor（executorRoutes）、dock 委托（dockRoutes）、selectedStages
 * （selectorBindings 两侧）四类声明各留一处投影；receiveSignals 的投影是
 * compiledHooks 本体。零 hook 阶段没有 compiledHooks 记录，只能从这四处
 * 发现——zhixu 委托阶段只出现在 dockRoutes 一侧、不进 executorRoutes，漏
 * 投影会让手工制品绕过零 hook 门。非字符串项交由形状校验报错，这里静默
 * 跳过。
 */
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

/**
 * HookReady 三线口径统一镜像：order-trigger hook 必须携带 emitReady——
 * Rust 编译器产物恒为 trigger|EMIT_READY（flags=5/6），UVPStateMachine
 * commitPlan 对缺 EMIT_READY 的"沉默 trigger"revert SilentOrderTriggerHook。
 * 这里是 artifact 边界的镜像门禁（编译器第一道，合约注册边界兜底）。
 */
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

/**
 * Cross-stage dependency preflight mirroring UVPStateMachine._registerPlanHook
 * byte-for-byte in SEMANTICS: hooks are processed in submitted (artifact)
 * order, and per signal key the FIRST watcher pins the recorded stage.
 * A later cross-stage watcher passes only while every watcher seen so far on
 * that key (AND-accumulated) is an order trigger; a set-based "any stage plus
 * any non-trigger watcher" check is STRICTER than the contract and rejects
 * plans the contract accepts (e.g. trigger(A) → trigger(B) → watcher(A)),
 * so the sequential scan is load-bearing, not an optimization.
 *
 * Field mapping note: artifacts carry `orderTriggerKind`
 * ("none" | "mint" | "dock") — there is no `isOrderTrigger` boolean, neither
 * at compile time nor in deserialized artifacts. The trigger flag is always
 * derived as `orderTriggerKind !== "none"`; reading a boolean field here
 * silently skipped the guard for every deserialized artifact.
 */
function crossStageDependencyIssues(hooks: readonly unknown[]): readonly string[] {
  interface KeyState {
    stageId: string;
    triggerOnly: boolean;
  }
  const issues: string[] = [];
  const keyState = new Map<string, KeyState>();
  for (const hook of hooks) {
    if (
      !isRecord(hook) ||
      typeof hook.hookId !== "string" ||
      typeof hook.stageId !== "string" ||
      typeof hook.orderTriggerKind !== "string" ||
      !Array.isArray(hook.dependencies)
    ) {
      continue;
    }
    const isOrderTrigger = hook.orderTriggerKind !== "none";
    for (const dependency of hook.dependencies) {
      if (!isOnchainHookDependency(dependency)) {
        continue;
      }
      const seen = keyState.get(dependency.signalKey);
      if (seen === undefined) {
        keyState.set(dependency.signalKey, { stageId: hook.stageId, triggerOnly: isOrderTrigger });
        continue;
      }
      const triggerOnly = seen.triggerOnly && isOrderTrigger;
      if (seen.stageId !== hook.stageId && !triggerOnly) {
        issues.push(
          `dependency ${dependency.signalKey} is shared across stages ${[seen.stageId, hook.stageId]
            .sort((left, right) => compareCanonicalKey(left, right))
            .join(", ")} with a non-trigger watcher after a foreign stage; `
          + "an unmaterialized stage's non-trigger hook would make the "
          + "submitting transaction revert forever",
        );
      }
      seen.triggerOnly = triggerOnly;
    }
  }
  return issues;
}

/**
 * U2 出生通道键查重镜像 UVPStateMachine._registerPlanHook，按通道语义
 * 分界：
 * - 跨通道（mint∪dock）：outside 出生与 dock 出生是两个不同的出生上
 *   下文，共享出生键会让任一侧的出生事务把另一侧的出生线一并推 Ready
 *   并物化幻影阶段——commitPlan reverts DuplicateBirthChannelKey；
 * - dock∪dock：entrance 键按 route 钉死（planHookDependsOn），一键挂
 *   两条 entrance 意味着任一 route 的子单会物化另一 route 的阶段——拒绝；
 * - mint∪mint：一事实扇出多条 mint 出生线是产品现行形态（customs 基准
 *   plan：order::registered 同时出生执行者选择与资源发布两阶段），同一
 *   mint 出生上下文内物化，不是幻影——放行。
 * watcher 共享出生键不受限（watcher 不由出生通道置 Ready）。
 */
function duplicateBirthChannelKeyIssues(hooks: readonly unknown[]): readonly string[] {
  const issues: string[] = [];
  const birthKeyOwner = new Map<string, { label: string; dock: boolean }>();
  for (const hook of hooks) {
    if (
      !isRecord(hook) ||
      typeof hook.orderTriggerKind !== "string" ||
      hook.orderTriggerKind === "none" ||
      !Array.isArray(hook.dependencies)
    ) {
      continue;
    }
    const label = `${String(hook.stageIdentifier)}#${String(hook.hookName)}`;
    const isDock = hook.orderTriggerKind === "dock";
    for (const dependency of hook.dependencies) {
      if (!isOnchainHookDependency(dependency)) {
        continue;
      }
      const owner = birthKeyOwner.get(dependency.signalKey);
      if (owner !== undefined && (isDock || owner.dock)) {
        issues.push(
          `duplicate birth-channel key ${dependency.signalKey}: order-trigger hooks ${owner.label} and ${label} share it `
            + (isDock !== owner.dock
              ? "across the mint and dock birth channels"
              : "across two dock entrances whose keys are pinned per route")
            + "; one birth fact must drive exactly one birth line per channel context "
            + "(contract commitPlan reverts DuplicateBirthChannelKey)",
        );
        continue;
      }
      if (owner === undefined) {
        birthKeyOwner.set(dependency.signalKey, { label, dock: isDock });
      }
    }
  }
  return issues;
}

function validateOnchainDependencyIndex(
  hooks: readonly unknown[],
  dependencyIndex: Record<string, readonly string[]>,
): readonly string[] {
  const issues: string[] = [];
  // Recompute in compiledHooks (= calldata) order, exactly like
  // buildOnchainDependencyIndex and UVPStateMachine._registerPlanHook.
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

  issues.push(...crossStageDependencyIssues(hooks));

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

/**
 * 执行者终生不可变镜像（uvp-core validate_stage_executors /
 * validate_mint_anchors 的出生阶段条款，Rust 是第一道，这里是 artifact
 * 边界的第二道）：订阅/出生阶段在 artifact 上的投影是 orderTriggerKind
 * = mint 的 hook——投递目标编译期定死、运行时禁止 executor patch，
 * selectedStages（selectorBindings）可达不构成绑定。缺静态执行者路由的
 * 出生阶段是"出生即死"：阶段随出生事实物化，却没有 executor route 可
 * 投递，又禁运行时补绑。zhixu 委托不适用（委托 route 不进 executorRoutes，
 * 且 mint 出生 + 委托在 Rust 侧已是拒绝形态）。
 */
function birthStageStaticExecutorIssues(
  hooks: readonly unknown[],
  executorRoutes: readonly unknown[],
): readonly string[] {
  const routedStages = new Set<string>();
  for (const route of executorRoutes) {
    if (isRecord(route) && typeof route.stageIdentifier === "string") {
      routedStages.add(route.stageIdentifier);
    }
  }
  const issues: string[] = [];
  const reported = new Set<string>();
  for (const hook of hooks) {
    if (
      !isRecord(hook) ||
      hook.orderTriggerKind !== "mint" ||
      typeof hook.stageIdentifier !== "string"
    ) {
      continue;
    }
    const stageIdentifier = hook.stageIdentifier;
    if (routedStages.has(stageIdentifier) || reported.has(stageIdentifier)) {
      continue;
    }
    reported.add(stageIdentifier);
    issues.push(
      `stage ${stageIdentifier} is a subscription/birth stage (mint order-trigger) and requires its own static executor route; `
        + "selectedStages reachability cannot bind it because subscription stages reject runtime executor patches "
        + "— the Rust compiler must reject this shape",
    );
  }
  return issues;
}

export {
  validateOnchainCompiledHooks,
  validateOnchainCompiledAdmissions,
  unmaterializableStageIssues,
  declaredStageIdentifiers,
  silentOrderTriggerIssues,
  crossStageDependencyIssues,
  duplicateBirthChannelKeyIssues,
  validateOnchainDependencyIndex,
  birthStageStaticExecutorIssues,
};

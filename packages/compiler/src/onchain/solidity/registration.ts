import {
  encodeAbiParameters,
  keccak256,
  parseAbiParameters,
  stringToHex,
} from "viem";
import { compareCanonicalKey } from "../../hook-plan.js";
import {
  assertOnchainHookPlanArtifact,
  OnchainHookPlanArtifactValidationError,
} from "../validate/artifact.js";
import { ZERO_HASH, onchainHookName } from "../hash/route.js";
import { assertNever } from "../shape.js";
import type {
  HexString,
  OnchainHookInstruction,
  OnchainHookPlanArtifact,
  OrderTriggerKind,
  SignalTargetOrderRelation,
  SolidityRegisterInstructionArg,
  SolidityRegisterPlanArgs,
  SolidityRegisterSignalCapabilityArg,
  SolidityRegisterStageSelectorBindingArg,
} from "../../types/index.js";

/**
 * Solidity 注册边界（自 onchain-hook-plan.ts 原样迁入）：commitPlan +
 * finalizePlan 两步注册流的 calldata 组装、CompactHook flags、hooksHash /
 * metadataHash / PlanCommit runtime hash 的 ABI 编码冻结口径。
 */

const PLAN_RUNTIME_HASH_DOMAIN_V2 = "uvp.plan.runtime.v2";

/** CompactHook flags 位定义。 */
export const HOOK_FLAG_ORDER_TRIGGER_MINT = 1;
export const HOOK_FLAG_ORDER_TRIGGER_DOCK = 2;
export const HOOK_FLAG_EMIT_READY = 4;

export function solidityHookFlags(
  orderTriggerKind: OrderTriggerKind,
  emitReady: boolean,
): number {
  let flags = 0;
  if (orderTriggerKind === "mint") {
    flags |= HOOK_FLAG_ORDER_TRIGGER_MINT;
  }
  if (orderTriggerKind === "dock") {
    flags |= HOOK_FLAG_ORDER_TRIGGER_DOCK;
  }
  if (emitReady) {
    flags |= HOOK_FLAG_EMIT_READY;
  }
  return flags;
}

// Solidity boundary builder: returns args for the two-step
// commitPlan + finalizePlan registration flow. compileZhixuRegisterPlanArgs
// wraps this for direct Zhixu definitions.
export function toSolidityRegisterPlanArgs(
  artifact: OnchainHookPlanArtifact,
): SolidityRegisterPlanArgs {
  assertOnchainHookPlanArtifact(artifact);

  const hooks = artifact.compiledHooks.map((hook) => {
    const dependencyKeys = uniqueSorted(
      hook.dependencies.map((dependency) => dependency.signalKey),
    );
    if (dependencyKeys.length === 0) {
      // Fail-closed mirror of UVPStateMachine._validateHook, which reverts
      // InvalidHook when hook.dependencyKeys is empty.
      throw new OnchainHookPlanArtifactValidationError([
        `compiledHooks ${hook.hookId} dependencyKeys must not be empty `
        + "(contract reverts InvalidHook for empty dependencyKeys)",
      ]);
    }
    const base = {
      hookId: hook.hookId,
      stageId: hook.stageId,
      hookName: onchainHookName(hook.hookName),
      kind: hook.kind,
      flags: solidityHookFlags(hook.orderTriggerKind, hook.emitReady),
      instructions: hook.instructions.map(toSolidityInstructionArg),
      dependencyKeys,
    };
    return hook.routeRef ? { ...base, routeId: hook.routeRef.routeId } : base;
  });
  const selectorBindings = artifact.selectorBindings.map((binding) => ({
    selectorStageId: binding.selectorStageId,
    targetStageId: binding.targetStageId,
  }));
  const signalCapabilities = artifact.signalCapabilities.map((capability) => ({
    stageId: capability.stageId,
    targetSourceId: capability.targetSourceId,
    signalId: capability.signalId,
    targetOrderRelation: solidityTargetOrderRelation(
      capability.targetOrderRelation,
    ),
  }));
  const hooksHash = hashSolidityHooks(hooks);
  const metadataHash = hashSolidityPlanMetadata(
    selectorBindings,
    signalCapabilities,
  );
  // PlanCommit runtime hash 覆盖 dock roots。
  const planHash = keccak256(
    encodeAbiParameters(
      parseAbiParameters(
        "bytes32 domain, bytes32 hooksHash, bytes32 metadataHash, bytes32 dockRoutesRoot, bytes32 dockInterfaceRoot",
      ),
      [
        keccak256(stringToHex(PLAN_RUNTIME_HASH_DOMAIN_V2)),
        hooksHash,
        metadataHash,
        artifact.dockRoutesRoot,
        artifact.dockInterfaceRoot,
      ],
    ),
  ) as HexString;

  return {
    schemaVersion: artifact.schemaVersion,
    sourcePlanId: artifact.planId,
    zhixuId: artifact.zhixuId,
    planHash,
    artifactHash: artifact.planHash,
    hooksHash,
    metadataHash,
    dockRoutesRoot: artifact.dockRoutesRoot,
    dockInterfaceRoot: artifact.dockInterfaceRoot,
    hooks,
    dependencyIndex: Object.entries(artifact.dependencyIndex)
      .sort(([left], [right]) => compareCanonicalKey(left, right))
      .map(([signalKey, hookIds]) => ({
        signalKey: signalKey as HexString,
        hookIds,
      })),
    executorRoutes: artifact.executorRoutes.map((route) => ({
      routeId: route.routeId,
      stageId: route.stageId,
      executorType: route.executorType,
      executorId: route.executorId,
      executorHash: route.executorHash,
      resourcesHash: route.resourcesHash,
      routeHash: route.routeHash,
    })),
    selectorBindings,
    signalCapabilities,
  };
}

export function planIdForPublisher(
  publisher: `0x${string}`,
  planHash: HexString,
): HexString {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters("bytes32 domain, address publisher, bytes32 planHash"),
      [keccak256(stringToHex("uvp.plan.id.v1")), publisher, planHash],
    ),
  ) as HexString;
}

/**
 * hooksHash 的唯一权威公式（冻结口径，三方逐字节一致）：
 *
 *   hooksHash = keccak256(abi.encode(CompactHook[]))
 *
 * 其中每条指令 tuple (uint8 op, bytes32 sourceId, bytes32 signalId,
 * uint16 arity, uint64 delaySeconds) 中，非 SIGNAL 指令的 sourceId/signalId
 * 一律填 Solidity 零字（0x00…00，共 32 字节），arity/delaySeconds 未用位填
 * 0——合约 commitPlan 对提交的 calldata 本身重算（fill-agnostic），因此
 * TS compiler、uvp-deploy 驱动与任何链下预计算方必须用同一填充字节。
 * keccak256("")（0xc5d2…470）只作为 DockMerkle.EMPTY_ROOT 出现，与指令
 * 填充无关——任何一方在填充位改用它都会让含 NOT/AND/OR/DELAY 的计划在
 * commitPlan 处 PlanMetadataHashMismatch 必然 revert。导出以便跨语言冻结
 * 向量与 deploy 侧复用同一实现。
 */
export function hashSolidityRegisterHooks(
  hooks: SolidityRegisterPlanArgs["hooks"],
): HexString {
  return hashSolidityHooks(hooks);
}

function hashSolidityHooks(
  hooks: SolidityRegisterPlanArgs["hooks"],
): HexString {
  const encodedHooks = hooks.map((hook) => ({
    hookId: hook.hookId,
    stageId: hook.stageId,
    hookName: hook.hookName,
    flags: hook.flags,
    instructions: hook.instructions.map((instruction) =>
      solidityInstructionTuple(instruction),
    ),
    dependencyKeys: hook.dependencyKeys,
  }));
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters(
        "(bytes32 hookId,bytes32 stageId,bytes32 hookName,uint8 flags,(uint8 op,bytes32 sourceId,bytes32 signalId,uint16 arity,uint64 delaySeconds)[] instructions,bytes32[] dependencyKeys)[] hooks",
      ),
      [encodedHooks] as never,
    ),
  ) as HexString;
}

function hashSolidityPlanMetadata(
  selectorBindings: readonly SolidityRegisterStageSelectorBindingArg[],
  signalCapabilities: readonly SolidityRegisterSignalCapabilityArg[],
): HexString {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters(
        "(bytes32 selectorStageId,bytes32 targetStageId)[] selectorBindings,(bytes32 stageId,bytes32 targetSourceId,bytes32 signalId,uint8 targetOrderRelation)[] signalCapabilities",
      ),
      [selectorBindings, signalCapabilities],
    ),
  ) as HexString;
}

function solidityInstructionTuple(instruction: SolidityRegisterInstructionArg) {
  switch (instruction.op) {
    case "SIGNAL":
      return {
        op: 0,
        sourceId: instruction.sourceId,
        signalId: instruction.signalId,
        arity: 0,
        delaySeconds: 0n,
      };
    case "NOT":
      return {
        op: 1,
        sourceId: ZERO_HASH,
        signalId: ZERO_HASH,
        arity: 0,
        delaySeconds: 0n,
      };
    case "AND":
      return {
        op: 2,
        sourceId: ZERO_HASH,
        signalId: ZERO_HASH,
        arity: instruction.arity,
        delaySeconds: 0n,
      };
    case "OR":
      return {
        op: 3,
        sourceId: ZERO_HASH,
        signalId: ZERO_HASH,
        arity: instruction.arity,
        delaySeconds: 0n,
      };
    case "DELAY":
      return {
        op: 4,
        sourceId: ZERO_HASH,
        signalId: ZERO_HASH,
        arity: 0,
        delaySeconds: BigInt(instruction.delaySeconds),
      };
  }
}

function toSolidityInstructionArg(
  instruction: OnchainHookInstruction,
): SolidityRegisterInstructionArg {
  switch (instruction.op) {
    case "SIGNAL":
      return {
        op: "SIGNAL",
        sourceId: instruction.sourceId,
        signalId: instruction.signalId,
        signalKey: instruction.signalKey,
      };
    case "NOT":
      return { op: "NOT" };
    case "AND":
    case "OR":
      return { op: instruction.op, arity: instruction.arity };
    case "DELAY":
      return { op: "DELAY", delaySeconds: instruction.delaySeconds };
    default:
      assertNever(instruction);
  }
}

function solidityTargetOrderRelation(
  relation: SignalTargetOrderRelation,
): 0 | 1 {
  switch (relation) {
    case "current":
      return 0;
    case "triggerOrigin":
      return 1;
    default:
      assertNever(relation);
  }
}

function uniqueSorted(values: readonly HexString[]): readonly HexString[] {
  return [...new Set(values)].sort();
}

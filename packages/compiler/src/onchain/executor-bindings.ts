import { concatHex, encodePacked, keccak256, stringToHex } from "viem";
import { compareExecutorBindings } from "./canonical/ordering.js";
import { keccakWord, merkleProof, merkleRoot } from "../merkle.js";
import type {
  ExecutorBinding,
  ExecutorBindingInput,
  ExecutorBindingKind,
  HexString,
} from "../types/index.js";

/**
 * 计划执行者绑定树（executorBindingsRoot）权威实现：supplierId 派生、叶公式、
 * 排序去重与成员证明只在本模块拥有；UVPStateMachine.commitPlan 与各模块按同一
 * 公式逐字节重算，链上只存 root。
 */

export const EXECUTOR_BINDING_LEAF_DOMAIN = "UVP_EXECUTOR_BINDING_V2";
export const SUPPLIER_ID_DOMAIN = "uvp.supplier-id.v1";
export const EXECUTOR_BINDING_KIND_DEFAULT = 0;
export const EXECUTOR_BINDING_KIND_CANDIDATE = 1;
export const MAX_EXECUTOR_BINDINGS = 256;

export function onchainSupplierId(supplierID: string): HexString {
  if (typeof supplierID !== "string" || supplierID.trim().length === 0) {
    throw new Error("supplierID must be a non-empty string");
  }
  return keccak256(
    concatHex([keccakWord(SUPPLIER_ID_DOMAIN), stringToHex(supplierID)]),
  ) as HexString;
}

export function executorBindingLeaf(
  stageId: HexString,
  supplierId: HexString,
  kind: ExecutorBindingKind,
): HexString {
  return keccak256(
    encodePacked(
      ["bytes32", "bytes32", "bytes32", "uint8"],
      [keccakWord(EXECUTOR_BINDING_LEAF_DOMAIN), stageId, supplierId, kind],
    ),
  ) as HexString;
}

export function executorBindingsRootOf(
  bindings: readonly {
    readonly stageId: HexString;
    readonly supplierId: HexString;
    readonly kind: ExecutorBindingKind;
  }[],
): HexString {
  return merkleRoot(
    bindings.map((binding) =>
      executorBindingLeaf(binding.stageId, binding.supplierId, binding.kind),
    ),
  );
}

export function executorBindingProof(
  bindings: readonly {
    readonly stageId: HexString;
    readonly supplierId: HexString;
    readonly kind: ExecutorBindingKind;
  }[],
  stageId: HexString,
  supplierId: HexString,
  kind: ExecutorBindingKind,
): HexString[] | undefined {
  return merkleProof(
    bindings.map((binding) =>
      executorBindingLeaf(binding.stageId, binding.supplierId, binding.kind),
    ),
    executorBindingLeaf(stageId, supplierId, kind),
  );
}

export function resolveExecutorBindings(
  inputs: readonly ExecutorBindingInput[],
  stageIdOf: (stageIdentifier: string) => HexString,
): readonly ExecutorBinding[] {
  return inputs
    .map((input) => ({
      stageIdentifier: input.stageIdentifier,
      stageId: stageIdOf(input.stageIdentifier),
      supplierId: onchainSupplierId(input.supplierID),
      kind: input.kind,
    }))
    .sort(compareExecutorBindings);
}

export function executorBindingSetIssues(
  bindings: readonly ExecutorBinding[],
): readonly string[] {
  const issues: string[] = [];
  if (bindings.length > MAX_EXECUTOR_BINDINGS) {
    issues.push(
      `plan declares ${bindings.length} executor bindings, above the ${MAX_EXECUTOR_BINDINGS} contract cap (UVPStateMachine reverts TooManyExecutorBindings)`,
    );
  }
  const seen = new Set<string>();
  for (const binding of bindings) {
    const key = `${binding.stageId}:${binding.supplierId}:${binding.kind}`;
    if (seen.has(key)) {
      issues.push(
        `duplicate executor binding for stage ${binding.stageIdentifier} (supplierId ${binding.supplierId}, kind ${binding.kind}); `
          + "the contract reverts DuplicateExecutorBinding and the Merkle tree must not absorb the duplicate",
      );
    }
    seen.add(key);
  }
  return issues;
}

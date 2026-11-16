import { keccak256, encodePacked } from "viem";
import { compareSupplierBindings } from "./canonical/ordering.js";
import { keccakWord, merkleProof, merkleRoot } from "../merkle.js";
import type {
  HexString,
  StageSupplierBinding,
  StageSupplierBindingInput,
  SupplierBindingKind,
} from "../types/index.js";

/**
 * 计划 stage→supplier 绑定树（supplierBindingsRoot）与 UUID SID 编解码的权威
 * 实现：链上 UUID 只放 bytes32 低 16 字节、永不做 hash，叶公式、排序去重与
 * 成员证明只在本模块拥有；UVPStateMachine.commitPlan 按同一公式逐字节重算，
 * 链上只存 root。
 */

export const SUPPLIER_BINDING_LEAF_DOMAIN = "UVP_SUPPLIER_BINDING_V1";
export const SUPPLIER_BINDING_KIND_DEFAULT = 0;
export const SUPPLIER_BINDING_KIND_CANDIDATE = 1;
export const MAX_SUPPLIER_BINDINGS = 256;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const HEX_32_BYTES = /^0x[0-9a-fA-F]{64}$/;
const ZERO_WORD = "0".repeat(32);

export function supplierIdFromUuid(supplierID: string): HexString {
  if (typeof supplierID !== "string") {
    throw new Error(
      `supplierID must be a canonical UUID string, received ${JSON.stringify(supplierID)}`,
    );
  }
  const normalized = supplierID.toLowerCase();
  if (!UUID_PATTERN.test(normalized)) {
    throw new Error(
      `supplierID ${JSON.stringify(supplierID)} must be a canonical 8-4-4-4-12 UUID; `
        + "the chain stores the UUID's 16 bytes in the low half of a bytes32 and never hashes the identity",
    );
  }
  return `0x${ZERO_WORD}${normalized.replaceAll("-", "")}` as HexString;
}

export function uuidFromSupplierId(supplierId: HexString): string {
  if (typeof supplierId !== "string" || !HEX_32_BYTES.test(supplierId)) {
    throw new Error(
      `supplierId must be a 32-byte hex word, received ${JSON.stringify(supplierId)}`,
    );
  }
  const body = supplierId.slice(2).toLowerCase();
  if (body.slice(0, 32) !== ZERO_WORD) {
    throw new Error(
      `supplierId ${supplierId} is not a UUID encoding: the high 16 bytes must be zero`,
    );
  }
  const uuid = body.slice(32);
  return [
    uuid.slice(0, 8),
    uuid.slice(8, 12),
    uuid.slice(12, 16),
    uuid.slice(16, 20),
    uuid.slice(20),
  ].join("-");
}

export function supplierBindingLeaf(
  stageId: HexString,
  supplierId: HexString,
  kind: SupplierBindingKind,
): HexString {
  return keccak256(
    encodePacked(
      ["bytes32", "bytes32", "bytes32", "uint8"],
      [keccakWord(SUPPLIER_BINDING_LEAF_DOMAIN), stageId, supplierId, kind],
    ),
  ) as HexString;
}

export function supplierBindingsRootOf(
  bindings: readonly {
    readonly stageId: HexString;
    readonly supplierId: HexString;
    readonly kind: SupplierBindingKind;
  }[],
): HexString {
  return merkleRoot(
    bindings.map((binding) =>
      supplierBindingLeaf(binding.stageId, binding.supplierId, binding.kind),
    ),
  );
}

export function supplierBindingProof(
  bindings: readonly {
    readonly stageId: HexString;
    readonly supplierId: HexString;
    readonly kind: SupplierBindingKind;
  }[],
  stageId: HexString,
  supplierId: HexString,
  kind: SupplierBindingKind,
): HexString[] | undefined {
  return merkleProof(
    bindings.map((binding) =>
      supplierBindingLeaf(binding.stageId, binding.supplierId, binding.kind),
    ),
    supplierBindingLeaf(stageId, supplierId, kind),
  );
}

export function resolveSupplierBindings(
  inputs: readonly StageSupplierBindingInput[],
  stageIdOf: (stageIdentifier: string) => HexString,
): readonly StageSupplierBinding[] {
  return inputs
    .map((input) => ({
      stageIdentifier: input.stageIdentifier,
      stageId: stageIdOf(input.stageIdentifier),
      supplierID: input.supplierID.toLowerCase(),
      supplierId: supplierIdFromUuid(input.supplierID),
      kind: input.kind,
    }))
    .sort(compareSupplierBindings);
}

export function supplierBindingSetIssues(
  bindings: readonly StageSupplierBinding[],
): readonly string[] {
  const issues: string[] = [];
  if (bindings.length > MAX_SUPPLIER_BINDINGS) {
    issues.push(
      `plan declares ${bindings.length} supplier bindings, above the ${MAX_SUPPLIER_BINDINGS} contract cap (UVPStateMachine reverts TooManySupplierBindings)`,
    );
  }
  const seen = new Set<string>();
  for (const binding of bindings) {
    const key = `${binding.stageId}:${binding.supplierId}:${binding.kind}`;
    if (seen.has(key)) {
      issues.push(
        `duplicate supplier binding for stage ${binding.stageIdentifier} (supplierId ${binding.supplierId}, kind ${binding.kind}); `
          + "the contract reverts DuplicateSupplierBinding and the Merkle tree must not absorb the duplicate",
      );
    }
    seen.add(key);
  }
  return issues;
}

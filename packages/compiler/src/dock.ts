import { keccak256 } from "viem";
import { keccak256Hex } from "./hash.js";
import type {
  DockInterfaceArtifact,
  DockRouteV1,
  HexString,
} from "./types/index.js";

/**
 * Zhixu Dock v1 跨运行时哈希库（PRD94 §7、PRD96 M0）。
 *
 * 与 Rust `uvp-compiler::dock` 逐字节对齐：
 * - 所有 commitment = `keccak256(keccak256(domain) ‖ words…)`，等价于
 *   Solidity `keccak256(abi.encode(keccak256(domain), …))`；
 * - Merkle：叶子排序去重后逐层 `keccak256(min ‖ max)`，空集合用
 *   `EMPTY_MERKLE_ROOT = keccak256("")`；奇数尾叶直接提升。
 *
 * 任何修改都必须同步 Rust/Solidity 并重新生成
 * `uvp-core/fixtures/dock/v1/manifest.json` golden vectors。
 */

export const EMPTY_MERKLE_ROOT =
  "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470" as HexString;

export const DOMAIN_DEFINITION_REF = "UVP_DEFINITION_REF_V1";
export const DOMAIN_INTERFACE_INPUT = "UVP_DOCK_INTERFACE_INPUT_V1";
export const DOMAIN_INTERFACE_OUTPUT = "UVP_DOCK_INTERFACE_OUTPUT_V1";
export const DOMAIN_ROUTE_ID = "UVP_DOCK_ROUTE_ID_V1";
export const DOMAIN_INPUT_BINDING = "UVP_DOCK_INPUT_BINDING_V1";
export const DOMAIN_OUTPUT_BINDING = "UVP_DOCK_OUTPUT_BINDING_V1";
export const DOMAIN_ROUTE = "UVP_DOCK_ROUTE_V1";
export const DOMAIN_DOCK_INSTANCE = "UVP_DOCK_INSTANCE_V1";
export const DOMAIN_DOCK_ORDER = "UVP_DOCK_ORDER_V1";
export const DOMAIN_RUNTIME_EIP155 = "UVP_RUNTIME_EIP155_V1";
export const DOMAIN_RUNTIME_CLOUD = "UVP_RUNTIME_CLOUD_V1";
export const DOMAIN_INPUT_PAYLOAD = "UVP_DOCK_INPUT_PAYLOAD_V1";
export const DOMAIN_INPUT_IDEMPOTENCY = "UVP_DOCK_INPUT_IDEMPOTENCY_V1";
export const DOMAIN_OUTPUT_IDEMPOTENCY = "UVP_DOCK_OUTPUT_IDEMPOTENCY_V1";
export const DOMAIN_SOURCE_FACT_SET = "UVP_DOCK_SOURCE_FACT_SET_V1";

export const MAX_DOCK_INPUTS = 8;
export const MAX_DOCK_OUTPUTS = 16;
export const MAX_DOCK_DEPTH = 8;

/** payload preimage 中 sourceFactSetHash 槽位的固定零字（与 Solidity `_DOMAIN_SOURCE_FACT_SET_ZERO` 对齐）。 */
export const ZERO_WORD = `0x${"0".repeat(64)}` as HexString;

export function keccakWord(data: string | Uint8Array): HexString {
  return keccak256Hex(data);
}

function concatWords(words: readonly HexString[]): Uint8Array {
  const out = new Uint8Array(words.length * 32);
  words.forEach((word, index) => {
    out.set(hexToBytes(word), index * 32);
  });
  return out;
}

export function hexToBytes(value: HexString): Uint8Array {
  const body = value.slice(2);
  const out = new Uint8Array(body.length / 2);
  for (let index = 0; index < out.length; index += 1) {
    out[index] = Number.parseInt(body.slice(index * 2, index * 2 + 2), 16);
  }
  return out;
}

export function u64Word(value: bigint | number): HexString {
  const hex = BigInt(value).toString(16).padStart(64, "0");
  return `0x${hex}` as HexString;
}

export function u8Word(value: number): HexString {
  return u64Word(value);
}

export function addressWord(address: HexString): HexString {
  return `0x${"0".repeat(24)}${address.slice(2).toLowerCase()}` as HexString;
}

/** `keccak256(keccak256(domain) ‖ words…)`（= Solidity abi.encode 版本）。 */
export function keccakWords(domain: string, words: readonly HexString[]): HexString {
  return keccak256(concatWords([keccakWord(domain), ...words])) as HexString;
}

/** 排序配对 Merkle root；空集合返回 `EMPTY_MERKLE_ROOT`。 */
export function merkleRoot(leaves: readonly HexString[]): HexString {
  if (leaves.length === 0) {
    return EMPTY_MERKLE_ROOT;
  }
  let level = [...new Set(leaves)].sort();
  while (level.length > 1) {
    const next: HexString[] = [];
    for (let index = 0; index < level.length; index += 2) {
      const left = level[index] as HexString;
      if (index + 1 === level.length) {
        next.push(left);
      } else {
        const right = level[index + 1] as HexString;
        const [first, second] =
          left <= right ? [left, right] : [right, left];
        next.push(keccak256(concatWords([first, second])) as HexString);
      }
    }
    level = next;
  }
  return level[0] as HexString;
}

/** Merkle inclusion proof（与 Rust `dock::merkle_proof` 同规则）。 */
export function merkleProof(
  leaves: readonly HexString[],
  leaf: HexString,
): HexString[] | undefined {
  if (leaves.length === 0 || !leaves.includes(leaf)) {
    return undefined;
  }
  let level = [...new Set(leaves)].sort();
  let index = level.indexOf(leaf);
  const proof: HexString[] = [];
  while (level.length > 1) {
    const next: HexString[] = [];
    for (let cursor = 0; cursor < level.length; cursor += 2) {
      const left = level[cursor] as HexString;
      if (cursor + 1 === level.length) {
        next.push(left);
        if (cursor === index) {
          index = next.length - 1;
        }
      } else {
        const right = level[cursor + 1] as HexString;
        const [first, second] =
          left <= right ? [left, right] : [right, left];
        next.push(keccak256(concatWords([first, second])) as HexString);
        if (cursor === index) {
          proof.push(right);
          index = next.length - 1;
        } else if (cursor + 1 === index) {
          proof.push(left);
          index = next.length - 1;
        }
      }
    }
    level = next;
  }
  return proof;
}

export function verifyMerkleProof(
  root: HexString,
  leaf: HexString,
  proof: readonly HexString[],
): boolean {
  let current = leaf;
  for (const sibling of proof) {
    const [left, right] =
      current <= sibling ? [current, sibling] : [sibling, current];
    current = keccak256(concatWords([left, right])) as HexString;
  }
  return current === root;
}

// ---------------------------------------------------------------------------
// 身份推导（PRD94 §7.3-§7.5）
// ---------------------------------------------------------------------------

export function definitionRefHash(uid: string, version: string): HexString {
  return keccakWords(DOMAIN_DEFINITION_REF, [
    keccakWord(uid),
    keccakWord(version),
  ]);
}

/** `keccak256(abi.encode(sourceId, signalId))`（StateMachine 事实键）。 */
export function signalKey(sourceId: HexString, signalId: HexString): HexString {
  return keccak256(concatWords([sourceId, signalId])) as HexString;
}

export function stageKey(stageIdentifier: string): HexString {
  return keccakWord(stageIdentifier);
}

export function hookKey(hookId: string): HexString {
  return keccakWord(hookId);
}

export function portKey(portName: string): HexString {
  return keccakWord(portName);
}

export function canonicalSignalHash(canonical: string): HexString {
  return keccakWord(canonical);
}

export function dockRouteId(
  localDefinitionRefHash: HexString,
  stageKeyWord: HexString,
): HexString {
  return keccakWords(DOMAIN_ROUTE_ID, [localDefinitionRefHash, stageKeyWord]);
}

export function evmRuntimeDomain(
  chainId: bigint | number,
  stateMachineAddress: HexString,
): HexString {
  return keccakWords(DOMAIN_RUNTIME_EIP155, [
    u64Word(chainId),
    addressWord(stateMachineAddress),
  ]);
}

export function cloudRuntimeDomain(
  deploymentId: string,
  securityDomain: string,
): HexString {
  return keccakWords(DOMAIN_RUNTIME_CLOUD, [
    keccakWord(deploymentId),
    keccakWord(securityDomain),
  ]);
}

export function localOrderKey(orderId: string): HexString {
  return keccakWord(orderId);
}

export function dockInstanceId(input: {
  readonly runtimeDomain: HexString;
  readonly localPlanId: HexString;
  readonly localDefinitionRefHash: HexString;
  readonly localOrderKey: HexString;
  readonly routeId: HexString;
  readonly routeHash: HexString;
}): HexString {
  return keccakWords(DOMAIN_DOCK_INSTANCE, [
    input.runtimeDomain,
    input.localPlanId,
    input.localDefinitionRefHash,
    input.localOrderKey,
    input.routeId,
    input.routeHash,
  ]);
}

export function linkedOrderId(
  dockInstanceIdWord: HexString,
  targetDefinitionRefHash: HexString,
): HexString {
  return keccakWords(DOMAIN_DOCK_ORDER, [
    dockInstanceIdWord,
    targetDefinitionRefHash,
  ]);
}

// ---------------------------------------------------------------------------
// Envelope / 幂等键（PRD95 §3）
// ---------------------------------------------------------------------------

export function sourceFactSetHash(factWords: readonly HexString[]): HexString {
  return keccakWords(DOMAIN_SOURCE_FACT_SET, [
    u64Word(factWords.length),
    ...factWords,
  ]);
}

export function dockInputIdempotencyKey(input: {
  readonly dockInstanceId: HexString;
  readonly inputBindingHash: HexString;
  readonly localHookReadyOccurrence: bigint | number;
}): HexString {
  return keccakWords(DOMAIN_INPUT_IDEMPOTENCY, [
    input.dockInstanceId,
    input.inputBindingHash,
    u64Word(input.localHookReadyOccurrence),
  ]);
}

export function dockOutputIdempotencyKey(input: {
  readonly dockInstanceId: HexString;
  readonly outputBindingHash: HexString;
  readonly targetFactId: HexString;
}): HexString {
  return keccakWords(DOMAIN_OUTPUT_IDEMPOTENCY, [
    input.dockInstanceId,
    input.outputBindingHash,
    input.targetFactId,
  ]);
}

// ---------------------------------------------------------------------------
// 从 artifact 重算 root（fail-closed 校验 core 产物）
// ---------------------------------------------------------------------------

export function interfaceRootOf(
  interfaceArtifact: DockInterfaceArtifact,
): HexString {
  const leaves = [
    ...interfaceArtifact.inputs.map((port) => port.leafHash),
    ...interfaceArtifact.outputs.map((port) => port.leafHash),
  ];
  return merkleRoot(leaves);
}

export function dockRoutesRootOf(routes: readonly DockRouteV1[]): HexString {
  return merkleRoot(routes.map((route) => route.routeHash));
}


// ---------------------------------------------------------------------------
// leaf / binding / routeHash / input payload 推导（与 Rust dock.rs 同公式；
// 供 TS 侧独立重算 golden vectors，不再只消费 Rust 产物）
// ---------------------------------------------------------------------------

export function dockInterfaceInputLeaf(input: {
  readonly definitionRefHash: HexString;
  readonly portName: string;
  readonly kind: "entrance" | "signal";
  readonly hookId: string;
  readonly sourceId: HexString;
  readonly signalId: HexString;
  readonly accessPolicy: "open" | "permit" | "linked";
}): HexString {
  const kindWord = input.kind === "entrance" ? u8Word(1) : u8Word(0);
  const accessWord =
    input.accessPolicy === "open"
      ? u8Word(0)
      : input.accessPolicy === "permit"
        ? u8Word(1)
        : u8Word(2);
  return keccakWords(DOMAIN_INTERFACE_INPUT, [
    input.definitionRefHash,
    portKey(input.portName),
    kindWord,
    hookKey(input.hookId),
    input.sourceId,
    input.signalId,
    accessWord,
  ]);
}

export function dockInterfaceOutputLeaf(input: {
  readonly definitionRefHash: HexString;
  readonly portName: string;
  readonly sourceId: HexString;
  readonly signalId: HexString;
  readonly terminal: "none" | "success" | "failure" | "cancelled";
}): HexString {
  const terminalWord =
    input.terminal === "success"
      ? u8Word(1)
      : input.terminal === "failure"
        ? u8Word(2)
        : input.terminal === "cancelled"
          ? u8Word(3)
          : u8Word(0);
  return keccakWords(DOMAIN_INTERFACE_OUTPUT, [
    input.definitionRefHash,
    portKey(input.portName),
    input.sourceId,
    input.signalId,
    terminalWord,
  ]);
}

export function dockInputBindingHash(input: {
  readonly routeId: HexString;
  readonly localHookId: HexString;
  readonly targetPort: string;
  readonly targetSourceId: HexString;
  readonly targetSignalId: HexString;
  readonly kind: "entrance" | "signal";
}): HexString {
  const kindWord = input.kind === "entrance" ? u8Word(1) : u8Word(0);
  return keccakWords(DOMAIN_INPUT_BINDING, [
    input.routeId,
    input.localHookId,
    portKey(input.targetPort),
    input.targetSourceId,
    input.targetSignalId,
    kindWord,
  ]);
}

export function dockOutputBindingHash(input: {
  readonly routeId: HexString;
  readonly localSourceId: HexString;
  readonly localSignalId: HexString;
  readonly targetPort: string;
  readonly targetSourceId: HexString;
  readonly targetSignalId: HexString;
  readonly terminal: "none" | "success" | "failure" | "cancelled";
}): HexString {
  const terminalWord =
    input.terminal === "success"
      ? u8Word(1)
      : input.terminal === "failure"
        ? u8Word(2)
        : input.terminal === "cancelled"
          ? u8Word(3)
          : u8Word(0);
  return keccakWords(DOMAIN_OUTPUT_BINDING, [
    input.routeId,
    input.localSourceId,
    input.localSignalId,
    portKey(input.targetPort),
    input.targetSourceId,
    input.targetSignalId,
    terminalWord,
  ]);
}

export function dockRouteHash(input: {
  readonly routeId: HexString;
  readonly targetDefinitionRefHash: HexString;
  readonly targetArtifactHash: HexString;
  readonly targetInterfaceRoot: HexString;
  readonly targetPlanId: HexString;
  readonly sourceSeam: string;
  readonly entranceBindingHash: HexString;
  readonly accessPolicy: "open" | "permit";
  readonly inputsRoot: HexString;
  readonly outputsRoot: HexString;
}): HexString {
  return keccakWords(DOMAIN_ROUTE, [
    input.routeId,
    input.targetDefinitionRefHash,
    input.targetArtifactHash,
    input.targetInterfaceRoot,
    input.targetPlanId,
    u8Word(0), // idPolicy derived-v1
    keccakWord(input.sourceSeam),
    input.entranceBindingHash,
    u8Word(input.accessPolicy === "permit" ? 1 : 0),
    input.inputsRoot,
    input.outputsRoot,
  ]);
}

export function dockInputPayloadHash(input: {
  readonly dockInstanceId: HexString;
  readonly routeHash: HexString;
  readonly localPlanId: HexString;
  readonly localOrderId: HexString;
  readonly localStageId: HexString;
  readonly localHookId: HexString;
  readonly targetPlanId: HexString;
  readonly linkedOrderId: HexString;
  readonly targetPort: string;
  readonly targetSignalId: HexString;
}): HexString {
  return keccakWords(DOMAIN_INPUT_PAYLOAD, [
    input.dockInstanceId,
    input.routeHash,
    input.localPlanId,
    input.localOrderId,
    input.localStageId,
    input.localHookId,
    input.targetPlanId,
    input.linkedOrderId,
    portKey(input.targetPort),
    input.targetSignalId,
    u64Word(0),
    ZERO_WORD,
  ]);
}

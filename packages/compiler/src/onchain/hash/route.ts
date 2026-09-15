import { canonicalStringify } from "../../canonical.js";
import { hashCanonical, keccak256Hex } from "../../hash.js";
import { isHexHash } from "../shape.js";
import type {
  HexString,
  HookPlanExecutorRoute,
  SignalTargetOrderRelation,
} from "../../types/index.js";

/**
 * 链轨非 plan 级承诺的组装（自 onchain-hook-plan.ts 原样迁入）：标识 id
 * 派生、route/binding/capability 哈希与 Solidity 零字。哈希基元全部复用根
 * hash.ts / canonical.ts，本文件不复制实现。
 */

const ONCHAIN_ROUTE_HASH_DOMAIN = "uvp:onchain-hook-route:v1";
const ONCHAIN_SELECTOR_BINDING_HASH_DOMAIN =
  "uvp:onchain-stage-selector-binding:v1";
const ONCHAIN_SIGNAL_CAPABILITY_HASH_DOMAIN =
  "uvp:onchain-signal-capability:v1";

const ZERO_HASH = `0x${"00".repeat(32)}` as HexString;

export { ZERO_HASH };

export function onchainHookId(
  stageIdentifier: string,
  hookName: string,
): HexString {
  return keccak256Hex(`${stageIdentifier}#${hookName}`);
}

export function onchainStageId(stageIdentifier: string): HexString {
  return keccak256Hex(stageIdentifier);
}

export function onchainHookName(hookName: string): HexString {
  return keccak256Hex(hookName);
}

export function onchainSourceId(source: string): HexString {
  return keccak256Hex(source);
}

export function onchainSignalId(signalName: string): HexString {
  return keccak256Hex(signalName);
}

export function onchainSelectorBindingHash(
  selectorStageId: HexString,
  targetStageId: HexString,
): HexString {
  return hashCanonical(ONCHAIN_SELECTOR_BINDING_HASH_DOMAIN, {
    selectorStageId,
    targetStageId,
  });
}

export function onchainSignalCapabilityHash(
  stageId: HexString,
  targetSourceId: HexString,
  signalId: HexString,
  targetOrderRelation: SignalTargetOrderRelation,
): HexString {
  return hashCanonical(ONCHAIN_SIGNAL_CAPABILITY_HASH_DOMAIN, {
    stageId,
    targetSourceId,
    signalId,
    targetOrderRelation,
  });
}

export function onchainRouteId(stageIdentifier: string): HexString {
  return keccak256Hex(`${stageIdentifier}#executorRoute`);
}

export function onchainSignalKey(
  sourceId: HexString,
  signalId: HexString,
): HexString {
  return keccak256Hex(concatHex32(sourceId, signalId));
}

export function opaqueContentHash(value: unknown): HexString {
  return keccak256Hex(canonicalStringify(value));
}

export function onchainRouteHash(route: HookPlanExecutorRoute): HexString {
  return routeHashFromDigests(
    onchainStageId(route.stageIdentifier),
    route.stageIdentifier,
    opaqueContentHash(route.executor),
    route.fileResources === undefined ? ZERO_HASH : opaqueContentHash(route.fileResources),
  );
}

export function routeHashFromDigests(
  stageId: HexString,
  stageIdentifier: string,
  executorHash: HexString,
  resourcesHash: HexString,
): HexString {
  return hashCanonical(ONCHAIN_ROUTE_HASH_DOMAIN, {
    stageId,
    stageIdentifier,
    executorHash,
    resourcesHash,
  });
}

function concatHex32(left: HexString, right: HexString): Uint8Array {
  if (!isHexHash(left) || !isHexHash(right)) {
    throw new Error("signal key inputs must be 32-byte hex hashes");
  }
  const bytes = new Uint8Array(64);
  bytes.set(hexToBytes32(left), 0);
  bytes.set(hexToBytes32(right), 32);
  return bytes;
}

function hexToBytes32(value: HexString): Uint8Array {
  const bytes = new Uint8Array(32);
  for (let index = 0; index < 32; index += 1) {
    bytes[index] = Number.parseInt(
      value.slice(2 + index * 2, 4 + index * 2),
      16,
    );
  }
  return bytes;
}

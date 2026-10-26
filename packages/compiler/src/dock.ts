import { keccak256 } from "viem";
import { keccak256Hex } from "./hash.js";
import { canonicalJson, canonicalize } from "@uvp-eth/canonical-json";
import type {
  DockInterfaceArtifactV2,
  DockOrderMode,
  DockRouteV2,
  HexString,
} from "./types/index.js";

/**
 * Zhixu Dock v2 跨运行时哈希库（链轨权威实现）；word 布局单源
 * docs/dock-word-layout.md，改动须同步 Solidity 并重生成 dock golden vectors。
 */

export const EMPTY_MERKLE_ROOT =
  "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470" as HexString;

export const DEFINITION_UID_DOMAIN = "uvp:definition-uid:v2";
export const DOMAIN_DEFINITION_REF = "UVP_DEFINITION_REF_V1";
export const DOMAIN_INTERFACE = "UVP_DOCK_INTERFACE_V2";
export const DOMAIN_INTERFACE_INPUT = "UVP_DOCK_INTERFACE_INPUT_V2";
export const DOMAIN_INTERFACE_OUTPUT = "UVP_DOCK_INTERFACE_OUTPUT_V3";
export const DOMAIN_ROUTE_ID = "UVP_DOCK_ROUTE_ID_V1";
export const DOMAIN_INPUT_BINDING = "UVP_DOCK_INPUT_BINDING_V2";
export const DOMAIN_OUTPUT_BINDING = "UVP_DOCK_OUTPUT_BINDING_V2";
export const DOMAIN_ROUTE = "UVP_DOCK_ROUTE_V3";
export const DOMAIN_DOCK_INSTANCE = "UVP_DOCK_INSTANCE_V2";
export const DOMAIN_DOCK_ORDER = "UVP_DOCK_ORDER_V1";
export const DOMAIN_DOCK_CANDIDATE = "UVP_DOCK_CANDIDATE_V2";
export const DOCK_ORDER_NAMESPACE_MASK = 1n << 255n;
export const DOMAIN_RUNTIME_EIP155 = "UVP_RUNTIME_EIP155_V1";
export const DOMAIN_RUNTIME_CLOUD = "UVP_RUNTIME_CLOUD_V1";
export const DOMAIN_INPUT_PAYLOAD = "UVP_DOCK_INPUT_PAYLOAD_V1";
export const DOMAIN_INPUT_IDEMPOTENCY = "UVP_DOCK_INPUT_IDEMPOTENCY_V1";
export const DOMAIN_OUTPUT_IDEMPOTENCY = "UVP_DOCK_OUTPUT_IDEMPOTENCY_V1";
export const DOMAIN_SOURCE_FACT_SET = "UVP_DOCK_SOURCE_FACT_SET_V1";

export const MAX_DOCK_INPUTS = 8;
export const MAX_DOCK_OUTPUTS = 16;
export const MAX_DOCK_EDGES = 8;
export const MAX_PORT_NAME_BYTES = 32;

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
  const big = requireUintWord(value, "u64 word value");
  if (big < 0n || big >= 1n << 64n) {
    throw new RangeError(
      `value must fit the unsigned 64-bit word range, received ${value}`,
    );
  }
  return `0x${big.toString(16).padStart(64, "0")}` as HexString;
}

function requireUintWord(
  value: bigint | number | string,
  path: string,
): bigint {
  if (typeof value === "bigint") {
    return value;
  }
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) {
      throw new RangeError(
        `${path} must be a safe integer, received ${value}`,
      );
    }
    return BigInt(value);
  }
  if (typeof value === "string" && /^(0|[1-9][0-9]*)$/.test(value)) {
    return BigInt(value);
  }
  throw new RangeError(
    `${path} must be an integer (bigint, safe number, or canonical base-10 string — 0x-prefixed/other forms are rejected), received ${String(value)}`,
  );
}

export function u256Word(value: bigint): HexString {
  if (value < 0n || value >= 1n << 256n) {
    throw new RangeError(
      `value must fit the unsigned 256-bit word range, received ${value}`,
    );
  }
  return `0x${value.toString(16).padStart(64, "0")}` as HexString;
}

export const MAX_CHAIN_ID = (1n << 64n) - 1n;

export function requireChainId(chainId: bigint | number, path = "chainId"): bigint {
  if (typeof chainId === "number") {
    if (!Number.isInteger(chainId)) {
      throw new RangeError(
        `${path} must be an integer chain id, received ${chainId}`,
      );
    }
    if (!Number.isSafeInteger(chainId)) {
      throw new RangeError(
        `${path} must be a safe integer chain id (numbers beyond 2^53 cannot be represented exactly; pass a bigint), received ${chainId}`,
      );
    }
  }
  const value = BigInt(chainId);
  if (value < 0n) {
    throw new RangeError(
      `${path} must be a non-negative chain id, received ${chainId}`,
    );
  }
  if (value > MAX_CHAIN_ID) {
    throw new RangeError(
      `${path} must fit the 64-bit range (< 2^64) — the runtime-domain FFI field stays 64-bit and chainId overflow is rejected explicitly, received ${chainId}`,
    );
  }
  return value;
}

export function u8Word(value: number): HexString {
  return u64Word(value);
}

export function addressWord(address: HexString): HexString {
  return `0x${"0".repeat(24)}${address.slice(2).toLowerCase()}` as HexString;
}

export function keccakWords(domain: string, words: readonly HexString[]): HexString {
  return keccak256(concatWords([keccakWord(domain), ...words])) as HexString;
}

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

export function modeWord(mode: DockOrderMode): HexString {
  if (mode !== "new" && mode !== "existing") {
    throw new RangeError(`order mode must be "new" or "existing", received ${mode}`);
  }
  return u8Word(mode === "new" ? 0 : 1);
}

export function orderModesWord(modes: readonly string[]): HexString | undefined {
  let mask = 0;
  const seen = new Set<string>();
  for (const mode of modes) {
    if (seen.has(mode)) {
      return undefined;
    }
    seen.add(mode);
    if (mode === "new") {
      mask |= 0b01;
    } else if (mode === "existing") {
      mask |= 0b10;
    } else {
      return undefined;
    }
  }
  if (mask === 0) {
    return undefined;
  }
  return u8Word(mask);
}

export function definitionUid(definition: unknown): string {
  const digest = keccak256Hex(
    `${DEFINITION_UID_DOMAIN}:${canonicalJson(stripDisplayFields(definition))}`,
  );
  return `zx-${digest.slice(2, 2 + 32)}`;
}

export function stripDisplayFields(definition: unknown): unknown {
  const node = canonicalize(definition);
  if (node === null || typeof node !== "object" || Array.isArray(node)) {
    return node;
  }
  const record = node as Record<string, unknown>;
  const metadata = record.metadata;
  if (metadata === null || typeof metadata !== "object" || Array.isArray(metadata)) {
    return node;
  }
  const { name: _name, annotations: _annotations, ...rest } = metadata as Record<string, unknown>;
  void _name;
  void _annotations;
  return { ...record, metadata: rest };
}

export function stripAnnotations(definition: unknown): unknown {
  const node = canonicalize(definition);
  if (node === null || typeof node !== "object" || Array.isArray(node)) {
    return node;
  }
  const record = node as Record<string, unknown>;
  const metadata = record.metadata;
  if (metadata === null || typeof metadata !== "object" || Array.isArray(metadata)) {
    return node;
  }
  const { annotations: _annotations, ...rest } = metadata as Record<string, unknown>;
  void _annotations;
  return { ...record, metadata: rest };
}

export function definitionRefHash(uid: string): HexString {
  return keccakWords(DOMAIN_DEFINITION_REF, [keccakWord(uid)]);
}

export function displayIdentity(name: string, uid: string): string {
  const hex = uid.startsWith("zx-") ? uid.slice(3) : uid;
  return `${name}(${hex.slice(0, 8)})`;
}

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

export function interfaceNameKey(interfaceName: string): HexString {
  return keccakWord(interfaceName);
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
    u256Word(requireChainId(chainId)),
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
  return isWordLiteral(orderId) ? (orderId as HexString) : keccakWord(orderId);
}

export function targetOrderRefKey(orderRef: string): HexString {
  return isWordLiteral(orderRef) ? (orderRef as HexString) : keccakWord(orderRef);
}

function isWordLiteral(value: string): boolean {
  return /^0x[0-9a-fA-F]{64}$/u.test(value);
}

export function dockInstanceId(input: {
  readonly runtimeDomain: HexString;
  readonly localPlanId: HexString;
  readonly localDefinitionRefHash: HexString;
  readonly localOrderKey: HexString;
  readonly routeId: HexString;
  readonly routeHash: HexString;
  readonly orderMode: DockOrderMode;
  readonly interfaceName: string;
  readonly targetPlanId: HexString;
  readonly targetOrderRef?: string;
}): HexString {
  return keccakWords(DOMAIN_DOCK_INSTANCE, [
    input.runtimeDomain,
    input.localPlanId,
    input.localDefinitionRefHash,
    input.localOrderKey,
    input.routeId,
    input.routeHash,
    modeWord(input.orderMode),
    interfaceNameKey(input.interfaceName),
    input.targetPlanId,
    ...(input.targetOrderRef === undefined
      ? []
      : [targetOrderRefKey(input.targetOrderRef)]),
  ]);
}

export function linkedOrderId(
  dockInstanceIdWord: HexString,
  targetDefinitionRefHash: HexString,
): HexString {
  const digest = keccakWords(DOMAIN_DOCK_ORDER, [
    dockInstanceIdWord,
    targetDefinitionRefHash,
  ]);
  return `0x${(BigInt(digest) | DOCK_ORDER_NAMESPACE_MASK)
    .toString(16)
    .padStart(64, "0")}` as HexString;
}

export function inputPortLeaf(input: {
  readonly uid: string;
  readonly interfaceName: string;
  readonly portName: string;
  readonly hookId: string;
}): HexString {
  return keccakWords(DOMAIN_INTERFACE_INPUT, [
    keccakWord(input.uid),
    interfaceNameKey(input.interfaceName),
    portKey(input.portName),
    hookKey(input.hookId),
  ]);
}

export function outputPortLeaf(input: {
  readonly uid: string;
  readonly interfaceName: string;
  readonly portName: string;
  readonly canonicalSignal: string;
}): HexString {
  const [source, signalName] = splitCanonicalSignal(input.canonicalSignal);
  return keccakWords(DOMAIN_INTERFACE_OUTPUT, [
    keccakWord(input.uid),
    interfaceNameKey(input.interfaceName),
    portKey(input.portName),
    keccakWord(source),
    keccakWord(signalName),
  ]);
}

export function splitCanonicalSignal(signal: string): [string, string] {
  const separator = signal.indexOf("::");
  if (separator <= 0) {
    throw new RangeError(
      `signal must be <source>::<stage>.<signal>, received ${JSON.stringify(signal)}`,
    );
  }
  return [signal.slice(0, separator), signal.slice(separator + 2)];
}

export function interfaceLeaf(input: {
  readonly uid: string;
  readonly interfaceName: string;
  readonly orderModes: readonly string[];
  readonly inputsRoot: HexString;
  readonly outputsRoot: HexString;
}): HexString {
  const modesWord = orderModesWord(input.orderModes);
  if (modesWord === undefined) {
    throw new RangeError(
      `orderModes must be a non-empty subset of {new, existing} without duplicates, received ${JSON.stringify(input.orderModes)}`,
    );
  }
  return keccakWords(DOMAIN_INTERFACE, [
    keccakWord(input.uid),
    interfaceNameKey(input.interfaceName),
    modesWord,
    input.inputsRoot,
    input.outputsRoot,
  ]);
}

export function inputBindingHash(input: {
  readonly routeId: HexString;
  readonly interfaceName: string;
  readonly localHookId: string;
  readonly portName: string;
  readonly targetSourceId: HexString;
  readonly targetSignalId: HexString;
}): HexString {
  return keccakWords(DOMAIN_INPUT_BINDING, [
    input.routeId,
    interfaceNameKey(input.interfaceName),
    hookKey(input.localHookId),
    portKey(input.portName),
    input.targetSourceId,
    input.targetSignalId,
  ]);
}

export function outputBindingHash(input: {
  readonly routeId: HexString;
  readonly interfaceName: string;
  readonly localSourceId: HexString;
  readonly localSignalId: HexString;
  readonly portName: string;
  readonly targetSourceId: HexString;
  readonly targetSignalId: HexString;
}): HexString {
  return keccakWords(DOMAIN_OUTPUT_BINDING, [
    input.routeId,
    interfaceNameKey(input.interfaceName),
    input.localSourceId,
    input.localSignalId,
    portKey(input.portName),
    input.targetSourceId,
    input.targetSignalId,
  ]);
}

export function routeHash(input: {
  readonly localDefinitionRefHash: HexString;
  readonly targetDefinitionRefHash: HexString;
  readonly targetPlanId: HexString;
  readonly interfaceName: string;
  readonly orderMode: DockOrderMode;
  readonly inputBindingsRoot: HexString;
  readonly outputBindingsRoot: HexString;
}): HexString {
  return keccakWords(DOMAIN_ROUTE, [
    input.localDefinitionRefHash,
    input.targetDefinitionRefHash,
    input.targetPlanId,
    interfaceNameKey(input.interfaceName),
    modeWord(input.orderMode),
    input.inputBindingsRoot,
    input.outputBindingsRoot,
  ]);
}

export function dockCandidateLeaf(input: {
  readonly routeId: HexString;
  readonly targetDefinitionRefHash: HexString;
  readonly targetPlanId: HexString;
  readonly interfaceName: string;
}): HexString {
  return keccakWords(DOMAIN_DOCK_CANDIDATE, [
    input.routeId,
    input.targetDefinitionRefHash,
    input.targetPlanId,
    interfaceNameKey(input.interfaceName),
  ]);
}

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
  readonly sequence?: bigint | number;
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
    u64Word(input.sequence ?? 0),
    ZERO_WORD,
  ]);
}

export function interfaceRootOf(
  interfaceArtifact: DockInterfaceArtifactV2,
): HexString {
  return merkleRoot(
    interfaceArtifact.interfaces.map((entry) => entry.interfaceRoot),
  );
}

export function dockRoutesRootOf(routes: readonly DockRouteV2[]): HexString {
  return merkleRoot(routes.map((route) => route.routeHash));
}

export const PERMIT_TYPEHASH =
  "UVPDockEntrancePermitV2(bytes32 targetPlanId,bytes32 targetEntrancePortId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 routeHash,bytes32 dockInstanceId,bytes32 linkedOrderId,uint256 feeLimit,uint256 nonce,uint256 deadline)";

export const PERMIT_DOMAIN_VERSION = "4";
export const PERMIT_DOMAIN_NAME = "UVPDockingModule";
export const PERMIT_DOMAIN_TYPE =
  "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";

export function eip712PermitDomainSeparator(input: {
  readonly chainId: bigint | number;
  readonly verifyingContract: HexString;
  readonly version?: string;
}): HexString {
  return keccak256(
    concatWords([
      keccakWord(PERMIT_DOMAIN_TYPE),
      keccakWord(PERMIT_DOMAIN_NAME),
      keccakWord(input.version ?? PERMIT_DOMAIN_VERSION),
      u256Word(requireChainId(input.chainId, "chainId")),
      addressWord(input.verifyingContract),
    ]),
  ) as HexString;
}

export function eip712PermitStructHash(input: {
  readonly targetPlanId: HexString;
  readonly targetEntrancePortId: HexString;
  readonly interfaceNameId: HexString;
  readonly localPlanId: HexString;
  readonly routeHash: HexString;
  readonly dockInstanceId: HexString;
  readonly linkedOrderId: HexString;
  readonly nonce: bigint | number | string;
  readonly deadline: bigint | number | string;
}): HexString {
  return keccak256(
    concatWords([
      keccakWord(PERMIT_TYPEHASH),
      input.targetPlanId,
      input.targetEntrancePortId,
      input.interfaceNameId,
      input.localPlanId,
      input.routeHash,
      input.dockInstanceId,
      input.linkedOrderId,
      u256Word(0n),
      u256Word(requireUintWord(input.nonce, "permit nonce")),
      u256Word(requireUintWord(input.deadline, "permit deadline")),
    ]),
  ) as HexString;
}

export function eip712PermitDigest(input: {
  readonly chainId: bigint | number;
  readonly verifyingContract: HexString;
  readonly version?: string;
  readonly targetPlanId: HexString;
  readonly targetEntrancePortId: HexString;
  readonly interfaceNameId: HexString;
  readonly localPlanId: HexString;
  readonly routeHash: HexString;
  readonly dockInstanceId: HexString;
  readonly linkedOrderId: HexString;
  readonly nonce: bigint | number | string;
  readonly deadline: bigint | number | string;
}): HexString {
  if (requireUintWord(input.nonce, "permit nonce") < 1n) {
    throw new RangeError(
      "entrance permit nonce sequence starts at 1 (the contract's usedEntrancePermitNonce storage defaults to 0, so nonce=0 always reverts)",
    );
  }
  const domainSeparator = eip712PermitDomainSeparator(input);
  const structHash = eip712PermitStructHash(input);
  const prefix = new Uint8Array([0x19, 0x01]);
  const body = concatWords([domainSeparator, structHash]);
  const buf = new Uint8Array(prefix.length + body.length);
  buf.set(prefix, 0);
  buf.set(body, prefix.length);
  return keccak256Hex(buf);
}

export const OPEN_CONSENT_TYPEHASH =
  "UVPDockOpenConsentV1(bytes32 targetPlanId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 localOrderId,bytes32 routeId,bytes32 routeHash,bytes32 dockInstanceId,bytes32 linkedOrderId,uint256 nonce,uint256 deadline)";

export function eip712OpenConsentStructHash(input: {
  readonly targetPlanId: HexString;
  readonly interfaceNameId: HexString;
  readonly localPlanId: HexString;
  readonly localOrderId: HexString;
  readonly routeId: HexString;
  readonly routeHash: HexString;
  readonly dockInstanceId: HexString;
  readonly linkedOrderId: HexString;
  readonly nonce: bigint | number | string;
  readonly deadline: bigint | number | string;
}): HexString {
  return keccak256(
    concatWords([
      keccakWord(OPEN_CONSENT_TYPEHASH),
      input.targetPlanId,
      input.interfaceNameId,
      input.localPlanId,
      input.localOrderId,
      input.routeId,
      input.routeHash,
      input.dockInstanceId,
      input.linkedOrderId,
      u256Word(requireUintWord(input.nonce, "consent nonce")),
      u256Word(requireUintWord(input.deadline, "consent deadline")),
    ]),
  );
}

export function eip712OpenConsentDigest(input: {
  readonly chainId: bigint | number;
  readonly verifyingContract: HexString;
  readonly version?: string;
  readonly targetPlanId: HexString;
  readonly interfaceNameId: HexString;
  readonly localPlanId: HexString;
  readonly localOrderId: HexString;
  readonly routeId: HexString;
  readonly routeHash: HexString;
  readonly dockInstanceId: HexString;
  readonly linkedOrderId: HexString;
  readonly nonce: bigint | number | string;
  readonly deadline: bigint | number | string;
}): HexString {
  if (requireUintWord(input.nonce, "consent nonce") < 1n) {
    throw new RangeError(
      "open consent nonce sequence starts at 1 (the contract's usedOpenConsentNonce storage defaults to 0, so nonce=0 always reverts)",
    );
  }
  const domainSeparator = eip712PermitDomainSeparator(input);
  const structHash = eip712OpenConsentStructHash(input);
  const prefix = new Uint8Array([0x19, 0x01]);
  const body = concatWords([domainSeparator, structHash]);
  const buf = new Uint8Array(prefix.length + body.length);
  buf.set(prefix, 0);
  buf.set(body, prefix.length);
  return keccak256Hex(buf);
}

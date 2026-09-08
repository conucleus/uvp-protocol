import { keccak256 } from "viem";
import { keccak256Hex } from "./hash.js";
import { canonicalize, canonicalStringify } from "./canonical.js";
import type {
  DockInterfaceArtifactV2,
  DockOrderMode,
  DockRouteV2,
  HexString,
} from "./types/index.js";

/**
 * Zhixu Dock v2 跨运行时哈希库（链轨权威实现）。
 *
 * word 布局定稿冻结于 UVPDockingModule abiVersion 4.0（规格 =
 * packages/compiler/docs/dock-word-layout.md）：
 * - 所有 commitment = `keccak256(keccak256(domain) ‖ words…)`，等价于
 *   Solidity `keccak256(abi.encode(keccak256(domain), …))`；
 * - Merkle：叶子排序去重后逐层 `keccak256(min ‖ max)`，空集合用
 *   `EMPTY_MERKLE_ROOT = keccak256("")`；奇数尾叶直接提升；
 * - 枚举 word：route modeWord new=0/existing=1；接口 orderModesWord
 *   u8 位掩码 bit0=new、bit1=existing；
 * - EIP-712 permit（V2 typehash + interfaceNameId）按 EIP-712 规范
 *   `keccak256(concat(...))`（无 domain word 前缀）。
 *
 * 任何修改都必须同步 Solidity 并重新生成
 * `packages/compiler/fixtures/dock/v1/manifest.json` golden vectors。
 */

export const EMPTY_MERKLE_ROOT =
  "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470" as HexString;

export const DEFINITION_UID_DOMAIN = "uvp:definition-uid:v1";
export const DOMAIN_DEFINITION_REF = "UVP_DEFINITION_REF_V1";
export const DOMAIN_INTERFACE = "UVP_DOCK_INTERFACE_V2";
export const DOMAIN_INTERFACE_INPUT = "UVP_DOCK_INTERFACE_INPUT_V2";
export const DOMAIN_INTERFACE_OUTPUT = "UVP_DOCK_INTERFACE_OUTPUT_V2";
export const DOMAIN_ROUTE_ID = "UVP_DOCK_ROUTE_ID_V1";
export const DOMAIN_INPUT_BINDING = "UVP_DOCK_INPUT_BINDING_V2";
export const DOMAIN_OUTPUT_BINDING = "UVP_DOCK_OUTPUT_BINDING_V2";
export const DOMAIN_ROUTE = "UVP_DOCK_ROUTE_V2";
export const DOMAIN_DOCK_INSTANCE = "UVP_DOCK_INSTANCE_V2";
export const DOMAIN_DOCK_ORDER = "UVP_DOCK_ORDER_V1";
/** Highest bit marks a derived dock child-order namespace. */
export const DOCK_ORDER_NAMESPACE_MASK = 1n << 255n;
export const DOMAIN_RUNTIME_EIP155 = "UVP_RUNTIME_EIP155_V1";
export const DOMAIN_RUNTIME_CLOUD = "UVP_RUNTIME_CLOUD_V1";
export const DOMAIN_INPUT_PAYLOAD = "UVP_DOCK_INPUT_PAYLOAD_V1";
export const DOMAIN_INPUT_IDEMPOTENCY = "UVP_DOCK_INPUT_IDEMPOTENCY_V1";
export const DOMAIN_OUTPUT_IDEMPOTENCY = "UVP_DOCK_OUTPUT_IDEMPOTENCY_V1";
export const DOMAIN_SOURCE_FACT_SET = "UVP_DOCK_SOURCE_FACT_SET_V1";

export const MAX_DOCK_INPUTS = 8;
export const MAX_DOCK_OUTPUTS = 16;
export const MAX_DOCK_DEPTH = 8;
/** `^[a-z][a-z0-9_]{0,31}$`：端口名与接口名同规则。 */
export const MAX_PORT_NAME_BYTES = 32;

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

/**
 * uint256 word（32 字节大端、高位在左）。合约侧 EIP-155 运行时域以
 * `abi.encode(_DOMAIN_RUNTIME_EIP155, block.chainid, address(...))` 编码
 * chainId（uint256，UVPDockingModule）；word 落位按完整 256 位，但 chainId
 * 取值域保持 64 位（见 requireChainId）。
 */
export function u256Word(value: bigint): HexString {
  if (value < 0n || value >= 1n << 256n) {
    throw new RangeError(
      `value must fit the unsigned 256-bit word range, received ${value}`,
    );
  }
  return `0x${value.toString(16).padStart(64, "0")}` as HexString;
}

/**
 * chainId 取值域上界（bug_audit #19）：跨运行时域（evmRuntimeDomain 与
 * EIP-712 permit 域）的 FFI 侧字段保持 64 位——TS 编译入口对 ≥ 2^64、
 * 负数与非整数 chainId 显式拒绝（fail-closed），不放宽到 u256。
 */
export const MAX_CHAIN_ID = (1n << 64n) - 1n;

/**
 * chainId 入口校验：非整数/负数/≥ 2^64 一律响亮拒绝。number 入参在
 * 2^53 以上本就无法精确表示，同样在此拦截（不静默四舍五入）。
 */
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
      `${path} must fit the 64-bit range (< 2^64) — the runtime-domain FFI field stays 64-bit and chainId overflow is rejected explicitly (bug_audit #19), received ${chainId}`,
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
// 枚举 word
// ---------------------------------------------------------------------------

/** route 的 order mode word：new=0、existing=1。 */
export function modeWord(mode: DockOrderMode): HexString {
  if (mode !== "new" && mode !== "existing") {
    throw new RangeError(`order mode must be "new" or "existing", received ${mode}`);
  }
  return u8Word(mode === "new" ? 0 : 1);
}

/**
 * 接口 orderModes word：u8 位掩码，bit0=new、bit1=existing；空集/未知取值/
 * 重复项返回 undefined（对拍 Rust order_modes_word 的 None 路径）。
 */
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

// ---------------------------------------------------------------------------
// 身份推导
// ---------------------------------------------------------------------------

/**
 * 定义身份派生函数（链轨权威）：canonical 剔除
 * `metadata.annotations` 后按 `uvp:definition-uid:v1:` 域哈希，
 * `zx-` + hex 前 32 字符。链轨制品的 zhixuId 与 resolution manifest 的
 * 内容寻址校验都从这里派生——云轨不镜像本公式（其身份归 DB）。
 */
export function definitionUid(definition: unknown): string {
  const digest = keccak256Hex(
    `${DEFINITION_UID_DOMAIN}:${canonicalStringify(stripAnnotations(definition))}`,
  );
  return `zx-${digest.slice(2, 2 + 32)}`;
}

/** 派生输入剔除 `metadata.annotations`：注解永不参与任何身份/哈希。 */
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

/** `definitionRefHash = H("UVP_DEFINITION_REF_V1", keccak(uid))`。 */
export function definitionRefHash(uid: string): HexString {
  return keccakWords(DOMAIN_DEFINITION_REF, [keccakWord(uid)]);
}

/** 显示口径：`name(uid 去 zx- 后前 8 hex)`。 */
export function displayIdentity(name: string, uid: string): string {
  const hex = uid.startsWith("zx-") ? uid.slice(3) : uid;
  return `${name}(${hex.slice(0, 8)})`;
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

/** 接口名在全部 v2 preimage 中的 word 形态：`keccak256(utf8(name))`。 */
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
  // chainId 按合约 uint256 全宽落位（block.chainid 是 uint256），但取值域
  // 保持 64 位（requireChainId）：FFI 域不放宽，≥ 2^64 在入口显式拒绝。
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
  return keccakWord(orderId);
}

/** existing 模式的目标 order 引用在 dockInstanceId preimage 中的 word 形态。 */
export function targetOrderRefKey(orderRef: string): HexString {
  return keccakWord(orderRef);
}

/**
 * dockInstanceId v2（§8.5）：new 模式恰 9 word（幂等建单锚，末 word =
 * targetPlanId——接口承诺 word 可被第三方复制进自建 plan，实例/子单身份
 * 必须与对接目标 plan 绑定）；existing 模式在尾部追加第 10 个 word =
 * target order 引用（引用不同即不同实例）。
 */
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

// ---------------------------------------------------------------------------
// 接口承诺（目标侧，§8.3）
// ---------------------------------------------------------------------------

/**
 * `inputPortLeaf_v2 = H(UVP_DOCK_INTERFACE_INPUT_V2; keccak(uid),
 * keccak(interfaceName), keccak(portName), keccak(hookRef))`。
 * sourceId/signalId 是运行期寻址数据，不入叶。
 */
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

/** `outputPortLeaf_v2 = H(UVP_DOCK_INTERFACE_OUTPUT_V2; keccak(uid), keccak(interfaceName), keccak(portName), keccak(canonicalSignal))`。 */
export function outputPortLeaf(input: {
  readonly uid: string;
  readonly interfaceName: string;
  readonly portName: string;
  readonly canonicalSignal: string;
}): HexString {
  return keccakWords(DOMAIN_INTERFACE_OUTPUT, [
    keccakWord(input.uid),
    interfaceNameKey(input.interfaceName),
    portKey(input.portName),
    canonicalSignalHash(input.canonicalSignal),
  ]);
}

/**
 * `interfaceLeaf_v2 = H(UVP_DOCK_INTERFACE_V2; keccak(uid),
 * keccak(interfaceName), orderModesWord, inputsRoot, outputsRoot)`；
 * 非法 orderModes（空/未知/重复）响亮抛错，不静默落成零 word。
 */
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

// ---------------------------------------------------------------------------
// 绑定与路由（调用方侧，§8.4）
// ---------------------------------------------------------------------------

/**
 * `inputBindingHash_v2 = H(UVP_DOCK_INPUT_BINDING_V2; routeId,
 * keccak(interfaceName), keccak("<task>.<stage>#<channel>"),
 * keccak(portName), targetSourceId, targetSignalId)`。
 */
export function inputBindingHash(input: {
  readonly routeId: HexString;
  readonly interfaceName: string;
  /** 本地被绑定通道的 `<stageIdentifier>#<hookName>` 原文。 */
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

/** `outputBindingHash_v2 = H(UVP_DOCK_OUTPUT_BINDING_V2; routeId, keccak(interfaceName), localSourceId, localSignalId, keccak(portName), targetSourceId, targetSignalId)`。 */
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

/**
 * `routeHash_v2 = H(UVP_DOCK_ROUTE_V2; localDefinitionRefHash,
 * targetDefinitionRefHash, keccak(interfaceName), modeWord,
 * inputBindingsRoot, outputBindingsRoot)`（6 word；目标运行期身份由
 * resolution manifest 与 route JSON 携带，不进 preimage）。
 */
export function routeHash(input: {
  readonly localDefinitionRefHash: HexString;
  readonly targetDefinitionRefHash: HexString;
  readonly interfaceName: string;
  readonly orderMode: DockOrderMode;
  readonly inputBindingsRoot: HexString;
  readonly outputBindingsRoot: HexString;
}): HexString {
  return keccakWords(DOMAIN_ROUTE, [
    input.localDefinitionRefHash,
    input.targetDefinitionRefHash,
    interfaceNameKey(input.interfaceName),
    modeWord(input.orderMode),
    input.inputBindingsRoot,
    input.outputBindingsRoot,
  ]);
}

// ---------------------------------------------------------------------------
// Envelope / 幂等键
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

// ---------------------------------------------------------------------------
// 从 artifact 重算 root（fail-closed 校验 core 产物）
// ---------------------------------------------------------------------------

/** 定义级 dockInterfaceRoot = 全部接口叶（interfaces[].interfaceRoot）的 merkle root。 */
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

// ---------------------------------------------------------------------------
// EIP-712 entrance permit（V2 typehash，§8.6）
// ---------------------------------------------------------------------------

/** 相对 v1 在 targetEntrancePortId 后加 `interfaceNameId = keccak(interfaceName)`。 */
export const PERMIT_TYPEHASH =
  "UVPDockEntrancePermitV2(bytes32 targetPlanId,bytes32 targetEntrancePortId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 routeHash,bytes32 dockInstanceId,bytes32 linkedOrderId,uint256 feeLimit,uint256 nonce,uint256 deadline)";

/** 链侧 docking module EIP-712 域 version（abiVersion 4.0 线）。 */
export const PERMIT_DOMAIN_VERSION = "4";
export const PERMIT_DOMAIN_NAME = "UVPDockingModule";
export const PERMIT_DOMAIN_TYPE =
  "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";

/**
 * 注意：EIP-712 structHash/typehash 与 domain 的编码是
 * `keccak256(concat(...))`（无 domain word 前缀），与 keccakWords 不同；
 * 这里按 EIP-712 规范逐字实现，Solidity 端用 abi.encode 得到相同结果。
 * feeLimit 固定 0（无费用机制，与合约一致）。
 */
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
  readonly nonce: bigint | number;
  readonly deadline: bigint | number;
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
      u256Word(BigInt(input.nonce)),
      u256Word(BigInt(input.deadline)),
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
  readonly nonce: bigint | number;
  readonly deadline: bigint | number;
}): HexString {
  // nonce 序列从 1 起（UVPDockingModule usedEntrancePermitNonce 的 storage
  // 缺省 0 即单调下界）：nonce=0 的 permit 链上恒拒，在此响亮拒绝而不是
  // 让签发方产出一个必定回退的签名。
  if (BigInt(input.nonce) < 1n) {
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

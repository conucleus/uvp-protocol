import {
  encodeAbiParameters,
  isHex,
  keccak256,
  stringToHex,
  type Hex,
} from "viem";

/**
 * 计划能力树的浏览器侧造证工具：能力表与 selector 绑定表以域分隔叶混编
 * 进同一棵排序配对 Merkle 树，链上只存树根（PlanCommit.capabilitiesRoot），
 * 成员资格由提交方"重算叶 + 携 proof"自证。叶子公式与排序规则和
 * UVPPlanMetadataModule 的 signalCapabilityLeaf / selectorBindingLeaf /
 * DockMerkle 逐字节一致，本模块仅依赖 viem。
 */

/** 信号能力叶的域分隔字（与合约 _DOMAIN_SIGNAL_CAPABILITY 同源）。 */
export const UVP_SIGNAL_CAPABILITY_V1 = "UVP_SIGNAL_CAPABILITY_V1";

/** selector 绑定叶的域分隔字（与合约 _DOMAIN_SELECTOR_BINDING 同源）。 */
export const UVP_SELECTOR_BINDING_V1 = "UVP_SELECTOR_BINDING_V1";

/** 空表树根；两表皆空时 PlanCommit 承诺该值（合约 DockMerkle.EMPTY_ROOT）。 */
export const EMPTY_CAPABILITIES_ROOT: Hex = keccak256("0x");

/** 目标单关系：0=当前单（SIGNAL_TARGET_CURRENT_ORDER）。 */
export const SIGNAL_CAPABILITY_RELATION_CURRENT_ORDER = 0;

/** 目标单关系：1=触发源单（SIGNAL_TARGET_TRIGGER_ORIGIN）。 */
export const SIGNAL_CAPABILITY_RELATION_TRIGGER_ORIGIN = 1;

/** 信号能力表项：某阶段可对 (targetSourceId, signalId) 事实行使的关系。 */
export interface SignalCapabilityTableEntry {
  readonly stageId: Hex | string;
  readonly targetSourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly relation: 0 | 1;
}

/** 阶段 selector 绑定表项：selector 阶段对目标阶段的执行授权。 */
export interface StageSelectorBindingTableEntry {
  readonly selectorStageId: Hex | string;
  readonly targetStageId: Hex | string;
}

interface NormalizedSignalCapability {
  readonly stageId: Hex;
  readonly targetSourceId: Hex;
  readonly signalId: Hex;
  readonly relation: 0 | 1;
}

interface NormalizedStageSelectorBinding {
  readonly selectorStageId: Hex;
  readonly targetStageId: Hex;
}

/** 信号能力叶 = keccak256(abi.encode(keccak256(domain), stageId, sourceId, signalId, uint256(relation)))。 */
export function signalCapabilityLeaf(
  stageId: Hex | string,
  targetSourceId: Hex | string,
  signalId: Hex | string,
  relation: 0 | 1,
): Hex {
  return keccak256(
    encodeAbiParameters(
      [
        { name: "domain", type: "bytes32" },
        { name: "stageId", type: "bytes32" },
        { name: "targetSourceId", type: "bytes32" },
        { name: "signalId", type: "bytes32" },
        { name: "relation", type: "uint256" },
      ],
      [
        keccak256(stringToHex(UVP_SIGNAL_CAPABILITY_V1)),
        normalizeWord(stageId, "stageId"),
        normalizeWord(targetSourceId, "targetSourceId"),
        normalizeWord(signalId, "signalId"),
        BigInt(relation),
      ],
    ),
  );
}

/** selector 绑定叶 = keccak256(abi.encode(keccak256(domain), selectorStageId, targetStageId))。 */
export function selectorBindingLeaf(
  selectorStageId: Hex | string,
  targetStageId: Hex | string,
): Hex {
  return keccak256(
    encodeAbiParameters(
      [
        { name: "domain", type: "bytes32" },
        { name: "selectorStageId", type: "bytes32" },
        { name: "targetStageId", type: "bytes32" },
      ],
      [
        keccak256(stringToHex(UVP_SELECTOR_BINDING_V1)),
        normalizeWord(selectorStageId, "selectorStageId"),
        normalizeWord(targetStageId, "targetStageId"),
      ],
    ),
  );
}

/** 两表全部叶子的树根；两表皆空返回 EMPTY_CAPABILITIES_ROOT。 */
export function capabilitiesRootOf(
  selectorBindings: readonly StageSelectorBindingTableEntry[],
  signalCapabilities: readonly SignalCapabilityTableEntry[],
): Hex {
  return merkleRoot(capabilityLeaves(selectorBindings, signalCapabilities));
}

/**
 * 事实属主（relation=0 能力）的自证材料：submitSignal 族 attribution
 * 参数的造证入口。找不到匹配能力时返回 undefined（事实在词表外，
 * 调用方按合约回退路径提交或不提交）。
 */
export function factAttribution(
  selectorBindings: readonly StageSelectorBindingTableEntry[],
  signalCapabilities: readonly SignalCapabilityTableEntry[],
  sourceId: Hex | string,
  signalId: Hex | string,
): { readonly stageId: Hex; readonly capabilityProof: readonly Hex[] }
| undefined {
  const normalizedSourceId = normalizeWord(sourceId, "sourceId");
  const normalizedSignalId = normalizeWord(signalId, "signalId");
  const capabilities = normalizeCapabilities(signalCapabilities);
  const owner = capabilities.find(
    (capability) =>
      capability.relation === 0 &&
      capability.targetSourceId === normalizedSourceId &&
      capability.signalId === normalizedSignalId,
  );
  if (owner === undefined) {
    return undefined;
  }
  const proof = merkleProof(
    capabilityLeaves(selectorBindings, signalCapabilities),
    signalCapabilityLeaf(
      owner.stageId,
      normalizedSourceId,
      normalizedSignalId,
      0,
    ),
  );
  if (proof === undefined) {
    return undefined;
  }
  return { stageId: owner.stageId, capabilityProof: proof };
}

/**
 * 目标阶段的 selector 绑定证明：submitSignal 族 selectorBinding 参数的
 * 造证入口。同一目标阶段存在多条绑定时取表序第一条；目标阶段未被
 * 绑定时返回 undefined（调用方提交零 selectorStageId 的空证明）。
 */
export function selectorBindingProofFor(
  selectorBindings: readonly StageSelectorBindingTableEntry[],
  signalCapabilities: readonly SignalCapabilityTableEntry[],
  targetStageId: Hex | string,
): { readonly selectorStageId: Hex; readonly proof: readonly Hex[] }
| undefined {
  const normalizedTargetStageId = normalizeWord(targetStageId, "targetStageId");
  const bindings = normalizeBindings(selectorBindings);
  const binding = bindings.find(
    (candidate) => candidate.targetStageId === normalizedTargetStageId,
  );
  if (binding === undefined) {
    return undefined;
  }
  const proof = merkleProof(
    capabilityLeaves(selectorBindings, signalCapabilities),
    selectorBindingLeaf(binding.selectorStageId, normalizedTargetStageId),
  );
  if (proof === undefined) {
    return undefined;
  }
  return { selectorStageId: binding.selectorStageId, proof };
}

function capabilityLeaves(
  selectorBindings: readonly StageSelectorBindingTableEntry[],
  signalCapabilities: readonly SignalCapabilityTableEntry[],
): Hex[] {
  return [
    ...normalizeBindings(selectorBindings).map((binding) =>
      selectorBindingLeaf(binding.selectorStageId, binding.targetStageId),
    ),
    ...normalizeCapabilities(signalCapabilities).map((capability) =>
      signalCapabilityLeaf(
        capability.stageId,
        capability.targetSourceId,
        capability.signalId,
        capability.relation,
      ),
    ),
  ];
}

// 排序配对 Merkle：叶排序去重，逐层 keccak256(min ‖ max)，奇数尾叶直接
// 提升，空集合取 EMPTY_CAPABILITIES_ROOT——与合约 DockMerkle 同规则。
function pairHash(left: Hex, right: Hex): Hex {
  const [min, max] = left <= right ? [left, right] : [right, left];
  return keccak256(
    encodeAbiParameters(
      [{ name: "min", type: "bytes32" }, { name: "max", type: "bytes32" }],
      [min, max],
    ),
  );
}

function merkleRoot(leaves: readonly Hex[]): Hex {
  if (leaves.length === 0) {
    return EMPTY_CAPABILITIES_ROOT;
  }
  let level = sortedUniqueLeaves(leaves);
  while (level.length > 1) {
    const next: Hex[] = [];
    for (let index = 0; index < level.length; index += 2) {
      const left = level[index] as Hex;
      if (index + 1 === level.length) {
        next.push(left);
      } else {
        next.push(pairHash(left, level[index + 1] as Hex));
      }
    }
    level = next;
  }
  return level[0] as Hex;
}

function merkleProof(leaves: readonly Hex[], leaf: Hex): Hex[] | undefined {
  if (leaves.length === 0 || !leaves.includes(leaf)) {
    return undefined;
  }
  let level = sortedUniqueLeaves(leaves);
  let index = level.indexOf(leaf);
  const proof: Hex[] = [];
  while (level.length > 1) {
    const next: Hex[] = [];
    for (let cursor = 0; cursor < level.length; cursor += 2) {
      const left = level[cursor] as Hex;
      if (cursor + 1 === level.length) {
        next.push(left);
        if (cursor === index) {
          index = next.length - 1;
        }
      } else {
        const right = level[cursor + 1] as Hex;
        next.push(pairHash(left, right));
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

function sortedUniqueLeaves(leaves: readonly Hex[]): Hex[] {
  return [...new Set(leaves)].sort();
}

function normalizeBindings(
  selectorBindings: readonly StageSelectorBindingTableEntry[],
): readonly NormalizedStageSelectorBinding[] {
  return selectorBindings.map((binding) => ({
    selectorStageId: normalizeWord(
      binding.selectorStageId,
      "selectorBinding.selectorStageId",
    ),
    targetStageId: normalizeWord(binding.targetStageId, "selectorBinding.targetStageId"),
  }));
}

function normalizeCapabilities(
  signalCapabilities: readonly SignalCapabilityTableEntry[],
): readonly NormalizedSignalCapability[] {
  return signalCapabilities.map((capability) => ({
    stageId: normalizeWord(capability.stageId, "capability.stageId"),
    targetSourceId: normalizeWord(
      capability.targetSourceId,
      "capability.targetSourceId",
    ),
    signalId: normalizeWord(capability.signalId, "capability.signalId"),
    relation: capability.relation,
  }));
}

const BYTES32_RE = /^0x[a-fA-F0-9]{64}$/;

function normalizeWord(value: Hex | string, fieldName: string): Hex {
  if (!isHex(value) || !BYTES32_RE.test(value)) {
    throw new Error(`${fieldName} must be a 32-byte hex value`);
  }
  return value.toLowerCase() as Hex;
}

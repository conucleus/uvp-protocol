/**
 * 浏览器安全入口：只发布不触 Node 内建模块的编译期推导面，包括计划能力树的
 * 叶公式/建树/取证明与 source/signal 标识派生；权威实现（单源）分别在
 * onchain/capabilities-root.ts、onchain/hash/route.ts，Merkle 规则在 dock.ts。
 * YAML/文件加载等 Node 专用面只留在包根入口 "."。
 */

export {
  artifactCapabilitiesRoot,
  capabilityLeaves,
  capabilitiesRootOf,
  capabilityTablesOf,
  factAttribution,
  FILE_WRITER_LEAF_DOMAIN,
  fileWriterLeaf,
  fileWriterProof,
  SELECTOR_BINDING_LEAF_DOMAIN,
  selectorBindingLeaf,
  selectorBindingProof,
  SIGNAL_CAPABILITY_LEAF_DOMAIN,
  signalCapabilityLeaf,
  signalCapabilityProof,
} from "./onchain/capabilities-root.js";

export { onchainSignalId, onchainSourceId } from "./onchain/hash/route.js";

export { EMPTY_MERKLE_ROOT } from "./dock.js";

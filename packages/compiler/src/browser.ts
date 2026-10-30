/**
 * 浏览器安全入口：只发布不触 Node 内建模块的编译期推导面。当前为计划能力树
 * （capabilitiesRoot）的叶公式、建树与取证明；权威实现（单源）在
 * onchain/capabilities-root.ts，Merkle 规则在 dock.ts。YAML/文件加载等 Node
 * 专用面只留在包根入口 "."。
 */

export {
  artifactCapabilitiesRoot,
  capabilityLeaves,
  capabilitiesRootOf,
  capabilityTablesOf,
  factAttribution,
  SELECTOR_BINDING_LEAF_DOMAIN,
  selectorBindingLeaf,
  selectorBindingProof,
  SIGNAL_CAPABILITY_LEAF_DOMAIN,
  signalCapabilityLeaf,
  signalCapabilityProof,
} from "./onchain/capabilities-root.js";

export { EMPTY_MERKLE_ROOT } from "./dock.js";

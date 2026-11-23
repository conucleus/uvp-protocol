/**
 * 浏览器安全入口：只发布不触 Node 内建模块的编译期推导面，包括计划能力树的
 * 叶公式/建树/取证明、stage→supplier 绑定树与 UUID SID 编解码、source/signal
 * 标识派生；权威实现（单源）分别在 onchain/capabilities-root.ts、
 * onchain/supplier-bindings.ts、onchain/hash/route.ts，Merkle 规则在 merkle.ts。
 * YAML/文件加载等 Node 专用面只留在包根入口 "."。
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

export { onchainSignalId, onchainSourceId } from "./onchain/hash/route.js";

export {
  MAX_SUPPLIER_BINDINGS,
  supplierBindingLeaf,
  supplierBindingProof,
  supplierBindingsRootOf,
  supplierIdFromUuid,
  SUPPLIER_BINDING_KIND_CANDIDATE,
  SUPPLIER_BINDING_KIND_DEFAULT,
  SUPPLIER_BINDING_LEAF_DOMAIN,
  uuidFromSupplierId,
} from "./onchain/supplier-bindings.js";

export type {
  StageSupplierBinding,
  StageSupplierBindingInput,
  SupplierBindingKind,
} from "./types/index.js";

export {
  DOCK_WINDOW_OP,
  dockWindowInstructionsOf,
} from "./dock-artifact.js";

export type {
  DockArtifact,
  DockArtifactAtom,
  DockArtifactOutput,
  DockWindowInstruction,
} from "./dock-artifact.js";

export { EMPTY_MERKLE_ROOT } from "./merkle.js";

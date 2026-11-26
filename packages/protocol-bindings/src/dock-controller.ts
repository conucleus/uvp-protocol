// UVPDockController calldata and EIP-712 builders. ABI is single-sourced from
// src/dock-controller-abi.ts (generated from contracts/uvp-dock Forge output).
import {
  encodeFunctionData,
  getAddress,
  isAddress,
  isHex,
  type Address,
  type Hex,
} from "viem";
import type { DockWindowInstruction } from "@uvp-eth/compiler/browser";
import {
  DOCK_CONTROLLER_ABI,
  DOCK_CONTROLLER_CONTRACT_NAME,
} from "./dock-controller-abi.js";

export { DOCK_CONTROLLER_ABI, DOCK_CONTROLLER_CONTRACT_NAME };

export const DOCK_CONTROLLER_DOMAIN_VERSION = "1" as const;
export const DOCK_BIND_LINK_PRIMARY_TYPE = "UVPDockControllerBindLink" as const;

export const DOCK_BIND_LINK_EIP712_TYPES = {
  UVPDockControllerBindLink: [
    { name: "dkid", type: "bytes32" },
    { name: "fromOrderId", type: "bytes32" },
    { name: "toOrderId", type: "bytes32" },
    { name: "toConsentStageId", type: "bytes32" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export interface DockControllerCallConfig {
  readonly dockControllerAddress: Address | string;
  readonly chainId?: number;
}

export interface DockControllerTransactionCall {
  readonly address: Address;
  readonly functionName:
    | "registerDock"
    | "bindLink"
    | "bindLinkPair"
    | "reconcile"
    | "reconcileOutput";
  readonly data: Hex;
  readonly chainId?: number;
}

export interface DockControllerReadCall {
  readonly address: Address;
  readonly functionName:
    | "getDock"
    | "getDockOutput"
    | "getLink"
    | "getStageLink"
    | "dockOutputWindow"
    | "bindLinkDigest";
  readonly data: Hex;
  readonly chainId?: number;
}

export interface DockAtomCallInput {
  readonly stageId: Hex | string;
  readonly signalId: Hex | string;
  readonly relation?: number;
  readonly capabilityProof: readonly (Hex | string)[];
}

export interface DockOutputCallInput {
  readonly signalId: Hex | string;
  readonly relation?: number;
  readonly atoms: readonly DockAtomCallInput[];
  readonly window: readonly DockWindowInstruction[];
  readonly capabilityProof: readonly (Hex | string)[];
}

export interface RegisterDockCallArgs {
  readonly fromPlanId: Hex | string;
  readonly fromSourceId: Hex | string;
  readonly toPlanId: Hex | string;
  readonly toStageId: Hex | string;
  readonly toSourceId: Hex | string;
  readonly docHash: Hex | string;
  readonly outputs: readonly DockOutputCallInput[];
}

export interface DockBindLinkRequestInput {
  readonly dkid: Hex | string;
  readonly fromOrderId: Hex | string;
  readonly toOrderId: Hex | string;
  readonly toConsentStageId: Hex | string;
  readonly selectorProof: readonly (Hex | string)[];
  readonly deadline: bigint | number | string;
}

export interface DockBindLinkTypedDataInput {
  readonly dkid: Hex | string;
  readonly fromOrderId: Hex | string;
  readonly toOrderId: Hex | string;
  readonly toConsentStageId: Hex | string;
  readonly deadline: bigint | number | string;
}

export interface DockBindLinkTypedData {
  readonly domain: {
    readonly name: typeof DOCK_CONTROLLER_CONTRACT_NAME;
    readonly version: typeof DOCK_CONTROLLER_DOMAIN_VERSION;
    readonly chainId: number;
    readonly verifyingContract: Address;
  };
  readonly types: typeof DOCK_BIND_LINK_EIP712_TYPES;
  readonly primaryType: typeof DOCK_BIND_LINK_PRIMARY_TYPE;
  readonly message: {
    readonly dkid: Hex;
    readonly fromOrderId: Hex;
    readonly toOrderId: Hex;
    readonly toConsentStageId: Hex;
    readonly deadline: string;
  };
}

export interface BindLinkPairCallArgs {
  readonly reqAtoB: DockBindLinkRequestInput;
  readonly sigB?: Hex | string;
  readonly reqBtoA: DockBindLinkRequestInput;
  readonly sigA?: Hex | string;
}

export function buildBindLinkTypedDataFor(
  config: DockControllerCallConfig,
  req: DockBindLinkTypedDataInput,
): DockBindLinkTypedData {
  const verifyingContract = normalizeAddress(
    config.dockControllerAddress,
    "dockControllerAddress",
  );
  const chainId = normalizeChainId(config.chainId);
  const deadline = normalizeUintBigInt(req.deadline, "deadline");

  return {
    domain: {
      name: DOCK_CONTROLLER_CONTRACT_NAME,
      version: DOCK_CONTROLLER_DOMAIN_VERSION,
      chainId,
      verifyingContract,
    },
    types: DOCK_BIND_LINK_EIP712_TYPES,
    primaryType: DOCK_BIND_LINK_PRIMARY_TYPE,
    message: {
      dkid: normalizeBytes32(req.dkid, "dkid"),
      fromOrderId: normalizeBytes32(req.fromOrderId, "fromOrderId"),
      toOrderId: normalizeBytes32(req.toOrderId, "toOrderId"),
      toConsentStageId: normalizeBytes32(req.toConsentStageId, "toConsentStageId"),
      deadline: deadline.toString(),
    },
  };
}

export function buildRegisterDockCall(
  config: DockControllerCallConfig,
  args: RegisterDockCallArgs,
): DockControllerTransactionCall {
  const address = normalizeAddress(
    config.dockControllerAddress,
    "dockControllerAddress",
  );
  if (args.outputs.length === 0) {
    throw new Error("registerDock requires at least one output");
  }
  const outputs = args.outputs.map((output, outputIndex) => ({
    signalId: normalizeBytes32(output.signalId, `outputs[${outputIndex}].signalId`),
    relation: normalizeRelation(output.relation ?? 0, `outputs[${outputIndex}].relation`),
    atoms: output.atoms.map((atom, atomIndex) => ({
      stageId: normalizeBytes32(atom.stageId, `outputs[${outputIndex}].atoms[${atomIndex}].stageId`),
      signalId: normalizeBytes32(atom.signalId, `outputs[${outputIndex}].atoms[${atomIndex}].signalId`),
      relation: normalizeRelation(
        atom.relation ?? 0,
        `outputs[${outputIndex}].atoms[${atomIndex}].relation`,
      ),
      capabilityProof: atom.capabilityProof.map((node, proofIndex) =>
        normalizeBytes32(
          node,
          `outputs[${outputIndex}].atoms[${atomIndex}].capabilityProof[${proofIndex}]`,
        ),
      ),
    })),
    window: output.window.map((instruction, instIndex) => ({
      op: normalizeUint8(instruction.op, `outputs[${outputIndex}].window[${instIndex}].op`),
      sourceId: normalizeBytes32(
        instruction.sourceId,
        `outputs[${outputIndex}].window[${instIndex}].sourceId`,
      ),
      signalId: normalizeBytes32(
        instruction.signalId,
        `outputs[${outputIndex}].window[${instIndex}].signalId`,
      ),
      arity: normalizeUint16(instruction.arity, `outputs[${outputIndex}].window[${instIndex}].arity`),
      delaySeconds: normalizeUintBigInt(
        instruction.delaySeconds,
        `outputs[${outputIndex}].window[${instIndex}].delaySeconds`,
      ),
    })),
    capabilityProof: output.capabilityProof.map((node, proofIndex) =>
      normalizeBytes32(node, `outputs[${outputIndex}].capabilityProof[${proofIndex}]`),
    ),
  }));

  const data = encodeFunctionData({
    abi: DOCK_CONTROLLER_ABI,
    functionName: "registerDock",
    args: [
      normalizeBytes32(args.fromPlanId, "fromPlanId"),
      normalizeBytes32(args.fromSourceId, "fromSourceId"),
      normalizeBytes32(args.toPlanId, "toPlanId"),
      normalizeBytes32(args.toStageId, "toStageId"),
      normalizeBytes32(args.toSourceId, "toSourceId"),
      normalizeBytes32(args.docHash, "docHash"),
      outputs,
    ],
  });
  return writeCall(address, "registerDock", data, config.chainId);
}

export function buildBindLinkCall(
  config: DockControllerCallConfig,
  req: DockBindLinkRequestInput,
  toSignature: Hex | string = "0x",
): DockControllerTransactionCall {
  const address = normalizeAddress(
    config.dockControllerAddress,
    "dockControllerAddress",
  );
  const data = encodeFunctionData({
    abi: DOCK_CONTROLLER_ABI,
    functionName: "bindLink",
    args: [
      normalizeBindLinkRequest(req, "req"),
      normalizeSignatureBytes(toSignature, "toSignature"),
    ],
  });
  return writeCall(address, "bindLink", data, config.chainId);
}

export function buildBindLinkPairCall(
  config: DockControllerCallConfig,
  args: BindLinkPairCallArgs,
): DockControllerTransactionCall {
  const address = normalizeAddress(
    config.dockControllerAddress,
    "dockControllerAddress",
  );
  const data = encodeFunctionData({
    abi: DOCK_CONTROLLER_ABI,
    functionName: "bindLinkPair",
    args: [
      normalizeBindLinkRequest(args.reqAtoB, "reqAtoB"),
      normalizeSignatureBytes(args.sigB ?? "0x", "sigB"),
      normalizeBindLinkRequest(args.reqBtoA, "reqBtoA"),
      normalizeSignatureBytes(args.sigA ?? "0x", "sigA"),
    ],
  });
  return writeCall(address, "bindLinkPair", data, config.chainId);
}

export function buildReconcileCall(
  config: DockControllerCallConfig,
  linkId: Hex | string,
  outputCapabilityProofs: readonly (readonly (Hex | string)[])[],
): DockControllerTransactionCall {
  const address = normalizeAddress(
    config.dockControllerAddress,
    "dockControllerAddress",
  );
  const proofs = outputCapabilityProofs.map((proof, outputIndex) =>
    proof.map((node, proofIndex) =>
      normalizeBytes32(node, `outputCapabilityProofs[${outputIndex}][${proofIndex}]`),
    ),
  );
  const data = encodeFunctionData({
    abi: DOCK_CONTROLLER_ABI,
    functionName: "reconcile",
    args: [normalizeBytes32(linkId, "linkId"), proofs],
  });
  return writeCall(address, "reconcile", data, config.chainId);
}

export function buildReconcileOutputCall(
  config: DockControllerCallConfig,
  linkId: Hex | string,
  outputIndex: bigint | number,
  capabilityProof: readonly (Hex | string)[],
): DockControllerTransactionCall {
  const address = normalizeAddress(
    config.dockControllerAddress,
    "dockControllerAddress",
  );
  const data = encodeFunctionData({
    abi: DOCK_CONTROLLER_ABI,
    functionName: "reconcileOutput",
    args: [
      normalizeBytes32(linkId, "linkId"),
      normalizeUintBigInt(outputIndex, "outputIndex"),
      capabilityProof.map((node, idx) =>
        normalizeBytes32(node, `capabilityProof[${idx}]`),
      ),
    ],
  });
  return writeCall(address, "reconcileOutput", data, config.chainId);
}

export function buildGetDockCall(
  config: DockControllerCallConfig,
  dkid: Hex | string,
): DockControllerReadCall {
  const address = normalizeAddress(
    config.dockControllerAddress,
    "dockControllerAddress",
  );
  const data = encodeFunctionData({
    abi: DOCK_CONTROLLER_ABI,
    functionName: "getDock",
    args: [normalizeBytes32(dkid, "dkid")],
  });
  return readCall(address, "getDock", data, config.chainId);
}

export function buildGetDockOutputCall(
  config: DockControllerCallConfig,
  dkid: Hex | string,
  outputIndex: bigint | number,
): DockControllerReadCall {
  const address = normalizeAddress(
    config.dockControllerAddress,
    "dockControllerAddress",
  );
  const data = encodeFunctionData({
    abi: DOCK_CONTROLLER_ABI,
    functionName: "getDockOutput",
    args: [
      normalizeBytes32(dkid, "dkid"),
      normalizeUintBigInt(outputIndex, "outputIndex"),
    ],
  });
  return readCall(address, "getDockOutput", data, config.chainId);
}

export function buildGetLinkCall(
  config: DockControllerCallConfig,
  linkId: Hex | string,
): DockControllerReadCall {
  const address = normalizeAddress(
    config.dockControllerAddress,
    "dockControllerAddress",
  );
  const data = encodeFunctionData({
    abi: DOCK_CONTROLLER_ABI,
    functionName: "getLink",
    args: [normalizeBytes32(linkId, "linkId")],
  });
  return readCall(address, "getLink", data, config.chainId);
}

export function buildGetStageLinkCall(
  config: DockControllerCallConfig,
  toPlanId: Hex | string,
  toOrderId: Hex | string,
  toStageId: Hex | string,
): DockControllerReadCall {
  const address = normalizeAddress(
    config.dockControllerAddress,
    "dockControllerAddress",
  );
  const data = encodeFunctionData({
    abi: DOCK_CONTROLLER_ABI,
    functionName: "getStageLink",
    args: [
      normalizeBytes32(toPlanId, "toPlanId"),
      normalizeBytes32(toOrderId, "toOrderId"),
      normalizeBytes32(toStageId, "toStageId"),
    ],
  });
  return readCall(address, "getStageLink", data, config.chainId);
}

export function buildDockOutputWindowCall(
  config: DockControllerCallConfig,
  linkId: Hex | string,
  outputIndex: bigint | number,
): DockControllerReadCall {
  const address = normalizeAddress(
    config.dockControllerAddress,
    "dockControllerAddress",
  );
  const data = encodeFunctionData({
    abi: DOCK_CONTROLLER_ABI,
    functionName: "dockOutputWindow",
    args: [
      normalizeBytes32(linkId, "linkId"),
      normalizeUintBigInt(outputIndex, "outputIndex"),
    ],
  });
  return readCall(address, "dockOutputWindow", data, config.chainId);
}

export function buildBindLinkDigestCall(
  config: DockControllerCallConfig,
  req: DockBindLinkRequestInput,
): DockControllerReadCall {
  const address = normalizeAddress(
    config.dockControllerAddress,
    "dockControllerAddress",
  );
  const data = encodeFunctionData({
    abi: DOCK_CONTROLLER_ABI,
    functionName: "bindLinkDigest",
    args: [normalizeBindLinkRequest(req, "req")],
  });
  return readCall(address, "bindLinkDigest", data, config.chainId);
}

function normalizeBindLinkRequest(req: DockBindLinkRequestInput, label: string) {
  return {
    dkid: normalizeBytes32(req.dkid, `${label}.dkid`),
    fromOrderId: normalizeBytes32(req.fromOrderId, `${label}.fromOrderId`),
    toOrderId: normalizeBytes32(req.toOrderId, `${label}.toOrderId`),
    toConsentStageId: normalizeBytes32(req.toConsentStageId, `${label}.toConsentStageId`),
    selectorProof: req.selectorProof.map((node, index) =>
      normalizeBytes32(node, `${label}.selectorProof[${index}]`),
    ),
    deadline: normalizeUintBigInt(req.deadline, `${label}.deadline`),
  };
}

function normalizeAddress(value: Address | string, label: string): Address {
  if (!isAddress(value)) {
    throw new Error(`${label} must be a valid EVM address`);
  }
  return getAddress(value);
}

function normalizeBytes32(value: Hex | string, label: string): Hex {
  if (typeof value !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new Error(`${label} must be a 32-byte hex string`);
  }
  return value.toLowerCase() as Hex;
}

function normalizeSignatureBytes(value: Hex | string, label: string): Hex {
  if (typeof value !== "string" || !isHex(value) || value.length % 2 !== 0) {
    throw new Error(`${label} must be a valid hex byte string`);
  }
  return value as Hex;
}

function normalizeChainId(chainId: number | undefined): number {
  if (chainId === undefined || !Number.isSafeInteger(chainId) || chainId <= 0) {
    throw new Error("chainId must be a positive safe integer");
  }
  return chainId;
}

function normalizeRelation(value: number, label: string): number {
  if (value !== 0) {
    throw new Error(`${label} must be 0 (current order)`);
  }
  return 0;
}

function normalizeUint8(value: number, label: string): number {
  if (!Number.isSafeInteger(value) || value < 0 || value > 0xff) {
    throw new Error(`${label} must be a uint8-safe integer`);
  }
  return value;
}

function normalizeUint16(value: number, label: string): number {
  if (!Number.isSafeInteger(value) || value < 0 || value > 0xffff) {
    throw new Error(`${label} must be a uint16-safe integer`);
  }
  return value;
}

function normalizeUintBigInt(value: bigint | number | string, label: string): bigint {
  if (typeof value === "bigint") {
    if (value < 0n) {
      throw new Error(`${label} must be non-negative`);
    }
    return value;
  }
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new Error(`${label} must be a non-negative safe integer`);
    }
    return BigInt(value);
  }
  if (typeof value === "string" && /^[0-9]+$/.test(value)) {
    return BigInt(value);
  }
  throw new Error(`${label} must be a non-negative integer`);
}

function writeCall(
  address: Address,
  functionName: DockControllerTransactionCall["functionName"],
  data: Hex,
  chainId: number | undefined,
): DockControllerTransactionCall {
  return {
    address,
    functionName,
    data,
    ...(chainId !== undefined ? { chainId } : {}),
  };
}

function readCall(
  address: Address,
  functionName: DockControllerReadCall["functionName"],
  data: Hex,
  chainId: number | undefined,
): DockControllerReadCall {
  return {
    address,
    functionName,
    data,
    ...(chainId !== undefined ? { chainId } : {}),
  };
}

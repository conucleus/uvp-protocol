// L3 ABI freshness pin + calldata / EIP-712 contract tests for UVPDockController:
// 1. Compared facts: generated DOCK_CONTROLLER_ABI vs contracts/uvp-dock Forge output.
// 2. Why not single-source import: Forge output under contracts/uvp-dock/out is not a package export.
// 3. Why not generator-only: staleness of checked-in src/dock-controller-abi.ts is only observed here.
// 4. Owner: protocol-bindings (L3).
// 5. Exit condition: remove the ABI freshness check when build-time generation replaces checked-in ABI.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";
import {
  decodeFunctionData,
  encodeAbiParameters,
  hashTypedData,
  keccak256,
  stringToBytes,
  type Abi,
  type Hex,
} from "viem";
import { DOCK_WINDOW_OP } from "@uvp-eth/compiler/browser";
import {
  DOCK_BIND_LINK_PRIMARY_TYPE,
  DOCK_CONTROLLER_ABI,
  DOCK_CONTROLLER_CONTRACT_NAME,
  DOCK_CONTROLLER_DOMAIN_VERSION,
  buildBindLinkCall,
  buildBindLinkPairCall,
  buildBindLinkTypedDataFor,
  buildDockOutputWindowCall,
  buildGetLinkCall,
  buildGetStageLinkCall,
  buildReconcileCall,
  buildReconcileOutputCall,
  buildRegisterDockCall,
} from "../src/index.js";

const packageDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dockControllerArtifactPath = resolve(
  packageDir,
  "../../contracts/uvp-dock/out/UVPDockController.sol/UVPDockController.json",
);

const DOCK_CONTROLLER = "0x000000000000000000000000000000000000000d" as const;
const SIGNATURE = `0x${"ab".repeat(65)}` as Hex;

function bytes32(suffix: string): Hex {
  return `0x${suffix.padStart(64, "0")}` as Hex;
}

describe("UVPDockController bindings", () => {
  it("mirrors the contracts/uvp-dock Forge artifact ABI verbatim", async () => {
    if (!existsSync(dockControllerArtifactPath)) {
      assert.fail(
        `forge artifact missing: ${dockControllerArtifactPath}; run forge build in contracts/uvp-dock`,
      );
    }
    const artifact = JSON.parse(
      await readFile(dockControllerArtifactPath, "utf8"),
    ) as { readonly abi: Abi };
    assert.deepEqual(DOCK_CONTROLLER_ABI, artifact.abi);
  });

  it("derives BindLink EIP-712 typed data matching UVPDockController.bindLinkDigest", () => {
    const req = {
      dkid: bytes32("01"),
      fromOrderId: bytes32("02"),
      toOrderId: bytes32("03"),
      toConsentStageId: bytes32("04"),
      deadline: 1_800_000_000n,
    };
    const typedData = buildBindLinkTypedDataFor(
      { dockControllerAddress: DOCK_CONTROLLER, chainId: 31337 },
      req,
    );

    assert.equal(typedData.primaryType, DOCK_BIND_LINK_PRIMARY_TYPE);
    assert.deepEqual(typedData.domain, {
      name: DOCK_CONTROLLER_CONTRACT_NAME,
      version: DOCK_CONTROLLER_DOMAIN_VERSION,
      chainId: 31337,
      verifyingContract: DOCK_CONTROLLER,
    });
    assert.equal(typedData.message.deadline, "1800000000");

    // Verify digest matches the exact Solidity _EIP712_DOMAIN_TYPEHASH + _BIND_LINK_TYPEHASH formula
    const domainTypehash = keccak256(
      stringToBytes(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
      ),
    );
    const domainSeparator = keccak256(
      encodeAbiParameters(
        [
          { type: "bytes32" },
          { type: "bytes32" },
          { type: "bytes32" },
          { type: "uint256" },
          { type: "address" },
        ],
        [
          domainTypehash,
          keccak256(stringToBytes("UVPDockController")),
          keccak256(stringToBytes("1")),
          31337n,
          DOCK_CONTROLLER,
        ],
      ),
    );
    const bindLinkTypehash = keccak256(
      stringToBytes(
        "UVPDockControllerBindLink(bytes32 dkid,bytes32 fromOrderId,bytes32 toOrderId,bytes32 toConsentStageId,uint256 deadline)",
      ),
    );
    const structHash = keccak256(
      encodeAbiParameters(
        [
          { type: "bytes32" },
          { type: "bytes32" },
          { type: "bytes32" },
          { type: "bytes32" },
          { type: "bytes32" },
          { type: "uint256" },
        ],
        [
          bindLinkTypehash,
          req.dkid,
          req.fromOrderId,
          req.toOrderId,
          req.toConsentStageId,
          req.deadline,
        ],
      ),
    );
    const expectedDigest = keccak256(
      `0x1901${domainSeparator.slice(2)}${structHash.slice(2)}` as Hex,
    );

    const viemDigest = hashTypedData({
      domain: typedData.domain,
      types: typedData.types,
      primaryType: typedData.primaryType,
      message: {
        ...typedData.message,
        deadline: BigInt(typedData.message.deadline),
      },
    });
    assert.equal(viemDigest, expectedDigest);
  });

  it("encodes registerDock, bindLink, bindLinkPair, reconcile, reconcileOutput, and read calls", () => {
    const config = { dockControllerAddress: DOCK_CONTROLLER, chainId: 31337 };

    const regCall = buildRegisterDockCall(config, {
      fromPlanId: bytes32("10"),
      fromSourceId: bytes32("11"),
      toPlanId: bytes32("12"),
      toStageId: bytes32("13"),
      toSourceId: bytes32("14"),
      docHash: bytes32("15"),
      outputs: [
        {
          signalId: bytes32("16"),
          atoms: [
            {
              stageId: bytes32("17"),
              signalId: bytes32("18"),
              capabilityProof: [bytes32("19")],
            },
          ],
          window: [
            {
              op: DOCK_WINDOW_OP.SIGNAL,
              sourceId: bytes32("11"),
              signalId: bytes32("18"),
              arity: 0,
              delaySeconds: 0,
            },
            {
              op: DOCK_WINDOW_OP.DELAY,
              sourceId: bytes32("00"),
              signalId: bytes32("00"),
              arity: 0,
              delaySeconds: 300,
            },
          ],
          capabilityProof: [bytes32("1a")],
        },
      ],
    });
    const decodedReg = decodeFunctionData({
      abi: DOCK_CONTROLLER_ABI,
      data: regCall.data,
    });
    assert.equal(decodedReg.functionName, "registerDock");
    assert.equal(decodedReg.args[5], bytes32("15"));
    assert.equal(decodedReg.args[6][0]?.window[1]?.delaySeconds, 300n);

    const reqAtoB = {
      dkid: bytes32("20"),
      fromOrderId: bytes32("21"),
      toOrderId: bytes32("22"),
      toConsentStageId: bytes32("23"),
      selectorProof: [bytes32("24")],
      deadline: 1_800_000_000n,
    };
    const bindCall = buildBindLinkCall(config, reqAtoB, SIGNATURE);
    const decodedBind = decodeFunctionData({
      abi: DOCK_CONTROLLER_ABI,
      data: bindCall.data,
    });
    assert.equal(decodedBind.functionName, "bindLink");
    assert.equal(decodedBind.args[0].dkid, bytes32("20"));
    assert.equal(decodedBind.args[1], SIGNATURE);

    const pairCall = buildBindLinkPairCall(config, {
      reqAtoB,
      sigB: SIGNATURE,
      reqBtoA: { ...reqAtoB, dkid: bytes32("25") },
      sigA: "0x",
    });
    const decodedPair = decodeFunctionData({
      abi: DOCK_CONTROLLER_ABI,
      data: pairCall.data,
    });
    assert.equal(decodedPair.functionName, "bindLinkPair");
    assert.equal(decodedPair.args[2].dkid, bytes32("25"));
    assert.equal(decodedPair.args[3], "0x");

    const recCall = buildReconcileCall(config, bytes32("30"), [[bytes32("31")]]);
    const decodedRec = decodeFunctionData({
      abi: DOCK_CONTROLLER_ABI,
      data: recCall.data,
    });
    assert.equal(decodedRec.functionName, "reconcile");
    assert.deepEqual(decodedRec.args, [bytes32("30"), [[bytes32("31")]]]);

    const recOutCall = buildReconcileOutputCall(config, bytes32("30"), 1, [bytes32("32")]);
    const decodedRecOut = decodeFunctionData({
      abi: DOCK_CONTROLLER_ABI,
      data: recOutCall.data,
    });
    assert.equal(decodedRecOut.functionName, "reconcileOutput");
    assert.deepEqual(decodedRecOut.args, [bytes32("30"), 1n, [bytes32("32")]]);

    const winCall = buildDockOutputWindowCall(config, bytes32("30"), 0);
    assert.equal(
      decodeFunctionData({ abi: DOCK_CONTROLLER_ABI, data: winCall.data }).functionName,
      "dockOutputWindow",
    );
    const linkCall = buildGetLinkCall(config, bytes32("30"));
    assert.equal(
      decodeFunctionData({ abi: DOCK_CONTROLLER_ABI, data: linkCall.data }).functionName,
      "getLink",
    );
    const stageLinkCall = buildGetStageLinkCall(config, bytes32("12"), bytes32("22"), bytes32("13"));
    assert.equal(
      decodeFunctionData({ abi: DOCK_CONTROLLER_ABI, data: stageLinkCall.data }).functionName,
      "getStageLink",
    );
  });
});

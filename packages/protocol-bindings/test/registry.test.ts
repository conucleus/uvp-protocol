import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { hashTypedData, recoverTypedDataAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  IDENTITY_CLAIM_TYPE_HASH,
  ZHIXU_RECORD_TYPE_HASH,
  buildIdentityClaimTypedData,
  buildZhixuRecordTypedData,
} from "../src/index.js";

const account = privateKeyToAccount(`0x${"11".repeat(32)}`);
const accountAddress = account.address.toLowerCase() as Address;
const bytes32 = (suffix: string): Hex => `0x${suffix.padStart(64, "0")}` as Hex;

const zhixuInput = {
  chainId: 31337,
  planId: bytes32("01"),
  planHash: bytes32("02"),
  descriptorUri: "  ipfs://zhixu-descriptor  ",
  descriptorHash: "sha256:abc",
  schemaHash: "sha256:def",
  version: " 1 ",
  registeredBy: account.address,
};

const claimInput = {
  chainId: 31337,
  wallet: account.address,
  subject: "  curator-of-record ",
  descriptorUri: "  ",
  descriptorHash: "",
  attestationRefs: [" https://attestations.example/1 "],
};

describe("registry EIP-712", () => {
  it("pins UVPZhixuRegistry/1 domain, type hashes, and normalized messages", () => {
    assert.equal(ZHIXU_RECORD_TYPE_HASH, "0x2ae354d1b3bce1fd553b189087cc36c7ab30cee71e91f1c39b5b1addecd2be74");
    assert.equal(IDENTITY_CLAIM_TYPE_HASH, "0xa2065d0d280baac8d3140a93e587666e53178490c1d9d48669a692a780ec286e");

    const zhixu = buildZhixuRecordTypedData(zhixuInput);
    assert.deepEqual(zhixu.domain, { name: "UVPZhixuRegistry", version: "1", chainId: 31337 });
    assert.equal(zhixu.primaryType, "ZhixuRecord");
    assert.deepEqual(zhixu.message, {
      chainId: 31337n,
      planId: bytes32("01"),
      planHash: bytes32("02"),
      descriptorUri: "ipfs://zhixu-descriptor",
      descriptorHash: "sha256:abc",
      schemaHash: "sha256:def",
      version: "1",
      registeredBy: accountAddress,
    });

    const claim = buildIdentityClaimTypedData(claimInput);
    assert.equal(claim.primaryType, "IdentityClaim");
    assert.deepEqual(claim.message, {
      chainId: 31337n,
      wallet: accountAddress,
      subject: "curator-of-record",
      descriptorUri: "",
      descriptorHash: "",
      attestationRefs: ["https://attestations.example/1"],
    });
  });

  it("pins the canonical digest and recovers the signing wallet for both registry messages", async () => {
    const zhixu = buildZhixuRecordTypedData(zhixuInput);
    assert.equal(
      hashTypedData(zhixu),
      "0x5e3d0e4f4ebcb6d256409fb9a54a5d6e9b349509df39bb455677627e13d7110a",
    );
    const zhixuSignature = await account.signTypedData(zhixu);
    assert.equal(
      (await recoverTypedDataAddress({ ...zhixu, signature: zhixuSignature })).toLowerCase(),
      accountAddress,
    );

    const claim = buildIdentityClaimTypedData(claimInput);
    assert.equal(
      hashTypedData(claim),
      "0xa798b86b4e39d3ba554ea9e00c2560b5a4d8154359f1c053939a7d782f8e7bb8",
    );
    const claimSignature = await account.signTypedData(claim);
    assert.equal(
      (await recoverTypedDataAddress({ ...claim, signature: claimSignature })).toLowerCase(),
      accountAddress,
    );
  });
});

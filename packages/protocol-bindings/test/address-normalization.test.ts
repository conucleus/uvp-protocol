import assert from "node:assert/strict";
import { getAddress } from "viem";
import { describe, it } from "node:test";
import {
  normalizeAddress,
  normalizeAddressChecksummed,
  normalizeBytes32,
} from "../src/index.js";

// 治理审计 §1.1 P1-1：normalizeAddress/Bytes32 单源的三处分叉
// （protocol-bindings 宽松+小写 / executor-kit 严格+checksum /
// chain-services 正则+小写）以本包两个权威形态收敛，此处钉住行为语义。

const lowercaseAddress = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const checksummedAddress = getAddress(lowercaseAddress);
// 构造一个混合大小写但 checksum 错误的地址：翻转 checksummed 形态的首个字母字符。
const mixedBadChecksum =
  checksummedAddress.slice(0, 3) +
  (checksummedAddress[3] === "a" ? "A" : "a") +
  checksummedAddress.slice(4);

describe("normalizeAddress（比较键/存储键权威形态：宽松校验+小写）", () => {
  it("全小写合法地址原样通过", () => {
    assert.equal(normalizeAddress(lowercaseAddress), lowercaseAddress);
  });

  it("EIP-55 checksummed 地址归一为小写", () => {
    assert.equal(normalizeAddress(checksummedAddress), lowercaseAddress);
  });

  it("混合大小写坏 checksum 仍按 20 字节身份接受并归一（不校验拼写）", () => {
    assert.equal(normalizeAddress(mixedBadChecksum), lowercaseAddress);
  });

  it("拒绝非 hex 字符", () => {
    assert.throws(
      () => normalizeAddress("0xzzaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
      /must be a valid EVM address/,
    );
  });

  it("拒绝长度错误", () => {
    assert.throws(
      () => normalizeAddress("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
      /must be a valid EVM address/,
    );
    assert.throws(
      () => normalizeAddress("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
      /must be a valid EVM address/,
    );
  });

  it("fieldName 进入错误信息", () => {
    assert.throws(
      () => normalizeAddress("not-an-address", "walletAddress"),
      /walletAddress must be a valid EVM address/,
    );
  });
});

describe("normalizeAddressChecksummed（展示/签名形态：严格 EIP-55）", () => {
  it("全小写合法地址接受并输出 checksummed 形态", () => {
    assert.equal(
      normalizeAddressChecksummed(lowercaseAddress),
      checksummedAddress,
    );
  });

  it("正确 checksummed 地址接受且输出稳定", () => {
    assert.equal(
      normalizeAddressChecksummed(checksummedAddress),
      checksummedAddress,
    );
  });

  it("混合大小写坏 checksum 拒绝（拼写敏感场景）", () => {
    assert.throws(
      () => normalizeAddressChecksummed(mixedBadChecksum),
      /must be a valid EIP-55 checksummed EVM address/,
    );
  });

  it("拒绝非 hex 字符与长度错误", () => {
    assert.throws(
      () => normalizeAddressChecksummed("0xzzaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
      /must be a valid EIP-55 checksummed EVM address/,
    );
    assert.throws(
      () => normalizeAddressChecksummed("0xaaaa"),
      /must be a valid EIP-55 checksummed EVM address/,
    );
  });

  it("fieldName 进入错误信息", () => {
    assert.throws(
      () => normalizeAddressChecksummed("0xzz", "privateKeyEnv signer"),
      /privateKeyEnv signer must be a valid EIP-55 checksummed EVM address/,
    );
  });
});

describe("normalizeBytes32（64-hex + 小写）", () => {
  it("小写 64-hex 原样通过", () => {
    const value = "0x" + "ab".repeat(32);
    assert.equal(normalizeBytes32(value), value);
  });

  it("混合大小写 64-hex 归一为小写", () => {
    const value = "0x" + "Ab".repeat(32);
    assert.equal(normalizeBytes32(value), "0x" + "ab".repeat(32));
  });

  it("拒绝长度错误与非 hex", () => {
    assert.throws(
      () => normalizeBytes32("0x" + "ab".repeat(31)),
      /must be a 32-byte hex value/,
    );
    assert.throws(
      () => normalizeBytes32("0x" + "zz".repeat(32)),
      /must be a 32-byte hex value/,
    );
    assert.throws(
      () => normalizeBytes32("ab".repeat(32)),
      /must be a 32-byte hex value/,
    );
  });

  it("fieldName 进入错误信息", () => {
    assert.throws(
      () => normalizeBytes32("0x1234", "planId"),
      /planId must be a 32-byte hex value/,
    );
  });
});

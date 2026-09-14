import assert from "node:assert/strict";
import { getAddress } from "viem";
import { describe, it } from "node:test";
import {
  isUserRejectedRequestError,
  validateTypedDataForSigning,
} from "../src/index.js";

// 治理审计 §1.1 P1-1：签名闸门单源的最强集行为。三端（order-app
// injectedWallet / zhixu-store wallet / executor-kit product）曾各自漂移
// （取消判定正则不同、preparedSubmitters 交叉核对仅 zhixu-store 有），
// 此处钉住合并后的判定语义：只做判定返回 reason，文案由宿主映射。

const submitter = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const otherAddress = "0xcccccccccccccccccccccccccccccccccccccccc";
const verifyingContract = "0xdddddddddddddddddddddddddddddddddddddddd";

function buildTypedData(overrides?: {
  readonly primaryType?: string;
  readonly domain?: Record<string, unknown>;
  readonly message?: Record<string, unknown>;
  readonly types?: Record<string, unknown>;
}): Record<string, unknown> {
  return {
    types:
      overrides?.types ?? {
        UVPStateMachineSignal: [
          { name: "planId", type: "bytes32" },
          { name: "orderId", type: "bytes32" },
          { name: "submitter", type: "address" },
        ],
        EIP712Domain: [
          { name: "name", type: "string" },
          { name: "version", type: "string" },
          { name: "chainId", type: "uint256" },
          { name: "verifyingContract", type: "address" },
        ],
      },
    primaryType: overrides?.primaryType ?? "UVPStateMachineSignal",
    domain: {
      name: "UVPStateMachine",
      version: "0.10",
      chainId: 11155111,
      verifyingContract,
      ...(overrides?.domain ?? {}),
    },
    message: {
      planId: "0x" + "01".repeat(32),
      orderId: "0x" + "02".repeat(32),
      submitter,
      ...(overrides?.message ?? {}),
    },
  };
}

function baseExpectation() {
  return {
    primaryType: "UVPStateMachineSignal",
    domainName: "UVPStateMachine",
    domainVersion: "0.10",
    chainId: 11155111,
    verifyingContract,
    submitter,
  };
}

describe("validateTypedDataForSigning：通过路径", () => {
  it("完整预期下一致信封通过", () => {
    const check = validateTypedDataForSigning(
      buildTypedData(),
      baseExpectation(),
    );
    assert.deepEqual(check, { ok: true });
  });

  it("私钥路径（无 connectedAddress/preparedSubmitters）兼容通过", () => {
    const check = validateTypedDataForSigning(buildTypedData(), {
      primaryType: "UVPStateMachineSignal",
      domainName: "UVPStateMachine",
      domainVersion: "0.10",
      chainId: 11155111,
      verifyingContract,
      submitter,
    });
    assert.deepEqual(check, { ok: true });
  });

  it("不提供 version/chainId/verifyingContract 预期时跳过比对（字段本身仍须合法）", () => {
    const { domainVersion, chainId, verifyingContract, ...minimal } =
      baseExpectation();
    void domainVersion;
    void chainId;
    void verifyingContract;
    const check = validateTypedDataForSigning(buildTypedData(), minimal);
    assert.deepEqual(check, { ok: true });
  });

  it("地址比对不区分大小写（EIP-55 checksummed 与小写混用通过）", () => {
    const check = validateTypedDataForSigning(
      buildTypedData({
        message: { submitter: getAddress(submitter) },
      }),
      baseExpectation(),
    );
    assert.deepEqual(check, { ok: true });
  });

  it("domain.chainId 以十进制字符串到达时同样可解析", () => {
    const check = validateTypedDataForSigning(
      buildTypedData({ domain: { chainId: "11155111" } }),
      baseExpectation(),
    );
    assert.deepEqual(check, { ok: true });
  });

  it("submitterField 可切换为 selector（dock permit 类信封）", () => {
    const check = validateTypedDataForSigning(
      buildTypedData({
        primaryType: "UVPDockEntrancePermitV2",
        types: {
          UVPDockEntrancePermitV2: [
            { name: "targetPlanId", type: "bytes32" },
            { name: "selector", type: "address" },
          ],
          EIP712Domain: [
            { name: "name", type: "string" },
            { name: "version", type: "string" },
            { name: "chainId", type: "uint256" },
            { name: "verifyingContract", type: "address" },
          ],
        },
        message: { selector: submitter },
      }),
      {
        ...baseExpectation(),
        primaryType: "UVPDockEntrancePermitV2",
        submitterField: "selector",
      },
    );
    assert.deepEqual(check, { ok: true });
  });
});

describe("validateTypedDataForSigning：拒绝路径", () => {
  it("非对象/数组/null 拒绝为 not-typed-data", () => {
    for (const value of [undefined, "string", 42, [], null]) {
      assert.deepEqual(validateTypedDataForSigning(value, baseExpectation()), {
        ok: false,
        reason: "not-typed-data",
      });
    }
  });

  it("primaryType 不一致拒绝", () => {
    const check = validateTypedDataForSigning(
      buildTypedData({ primaryType: "UVPStateMachinePlanCommit" }),
      baseExpectation(),
    );
    assert.equal(check.ok, false);
    assert.equal(check.reason, "primary-type");
  });

  it("types 缺少 primaryType 字段定义拒绝（最强集吸收 order-app 独有校验）", () => {
    const check = validateTypedDataForSigning(
      buildTypedData({ types: { EIP712Domain: [] } }),
      baseExpectation(),
    );
    assert.equal(check.ok, false);
    assert.equal(check.reason, "primary-type-fields");
  });

  it("domain 为数组拒绝为 domain-shape", () => {
    const check = validateTypedDataForSigning(
      { ...buildTypedData(), domain: ["fake"] },
      baseExpectation(),
    );
    assert.deepEqual(check, { ok: false, reason: "domain-shape" });
  });

  it("domain.name 不一致拒绝", () => {
    const check = validateTypedDataForSigning(
      buildTypedData({ domain: { name: "EvilModule" } }),
      baseExpectation(),
    );
    assert.equal(check.ok, false);
    assert.equal(check.reason, "domain-name");
  });

  it("domain.version 提供预期时不一致拒绝", () => {
    const check = validateTypedDataForSigning(
      buildTypedData({ domain: { version: "0.9" } }),
      baseExpectation(),
    );
    assert.equal(check.ok, false);
    assert.equal(check.reason, "domain-version");
  });

  it("domain.chainId 不可解析拒绝", () => {
    const check = validateTypedDataForSigning(
      buildTypedData({ domain: { chainId: "not-a-chain" } }),
      baseExpectation(),
    );
    assert.equal(check.ok, false);
    assert.equal(check.reason, "domain-chain-id");
  });

  it("domain.chainId 与预期不一致拒绝", () => {
    const check = validateTypedDataForSigning(
      buildTypedData({ domain: { chainId: 1 } }),
      baseExpectation(),
    );
    assert.equal(check.ok, false);
    assert.equal(check.reason, "domain-chain-id");
  });

  it("domain.verifyingContract 非 40-hex 拒绝（即使未提供预期）", () => {
    const { verifyingContract: _unused, ...minimal } = baseExpectation();
    void _unused;
    const check = validateTypedDataForSigning(
      buildTypedData({ domain: { verifyingContract: "0x1234" } }),
      minimal,
    );
    assert.equal(check.ok, false);
    assert.equal(check.reason, "domain-verifying-contract");
  });

  it("domain.verifyingContract 与预期不一致拒绝（大小写不敏感）", () => {
    const check = validateTypedDataForSigning(
      buildTypedData(),
      { ...baseExpectation(), verifyingContract: otherAddress },
    );
    assert.equal(check.ok, false);
    assert.equal(check.reason, "domain-verifying-contract");
  });

  it("message 为字符串拒绝为 message-shape", () => {
    const check = validateTypedDataForSigning(
      { ...buildTypedData(), message: "flat" },
      baseExpectation(),
    );
    assert.deepEqual(check, { ok: false, reason: "message-shape" });
  });

  it("message.submitter 非地址拒绝为 signer-field", () => {
    const check = validateTypedDataForSigning(
      buildTypedData({ message: { submitter: "0x1234" } }),
      baseExpectation(),
    );
    assert.equal(check.ok, false);
    assert.equal(check.reason, "signer-field");
  });

  it("message.submitter 与当前连接钱包不一致拒绝（浏览器路径）", () => {
    const check = validateTypedDataForSigning(buildTypedData(), {
      ...baseExpectation(),
      connectedAddress: otherAddress,
    });
    assert.equal(check.ok, false);
    assert.equal(check.reason, "signer-not-connected");
  });

  it("message.submitter 与预期提交方不一致拒绝", () => {
    const check = validateTypedDataForSigning(
      buildTypedData({ message: { submitter: otherAddress } }),
      baseExpectation(),
    );
    assert.equal(check.ok, false);
    assert.equal(check.reason, "signer-not-expected");
  });

  it("preparedSubmitters 交叉核对：任一非 undefined 条目不一致拒绝（zhixu-store 独有校验入单源）", () => {
    const check = validateTypedDataForSigning(buildTypedData(), {
      ...baseExpectation(),
      preparedSubmitters: [submitter, otherAddress],
    });
    assert.equal(check.ok, false);
    assert.equal(check.reason, "signer-not-prepared");
  });

  it("preparedSubmitters 的 undefined 条目跳过（兼容缺省字段）", () => {
    const check = validateTypedDataForSigning(buildTypedData(), {
      ...baseExpectation(),
      preparedSubmitters: [undefined, submitter],
    });
    assert.deepEqual(check, { ok: true });
  });

  it("detail 携带被拒关键值供日志/文案拼装", () => {
    const check = validateTypedDataForSigning(
      buildTypedData({ primaryType: "EvilEnvelope" }),
      baseExpectation(),
    );
    assert.equal(check.ok, false);
    assert.equal(check.detail, "EvilEnvelope");
  });
});

describe("isUserRejectedRequestError（取消判定超集）", () => {
  it("EIP-1193 code 4001 判定为用户拒绝", () => {
    assert.equal(isUserRejectedRequestError({ code: 4001 }), true);
  });

  it("reject/denied/cancel 三族消息均判定（超集：order-app 认 denied/cancel、zhixu-store 只认 reject）", () => {
    assert.equal(
      isUserRejectedRequestError(new Error("User rejected the request")),
      true,
    );
    assert.equal(
      isUserRejectedRequestError(new Error("User denied message signature")),
      true,
    );
    assert.equal(
      isUserRejectedRequestError({ message: "transaction cancelled by user" }),
      true,
    );
    assert.equal(
      isUserRejectedRequestError({ message: "Request REJECTED" }),
      true,
    );
  });

  it("其他错误不误判", () => {
    assert.equal(isUserRejectedRequestError(new Error("network error")), false);
    assert.equal(isUserRejectedRequestError({ code: -32000 }), false);
    assert.equal(isUserRejectedRequestError("rejected"), false);
    assert.equal(isUserRejectedRequestError(null), false);
    assert.equal(isUserRejectedRequestError(undefined), false);
  });

  it("无 message 字段的对象不抛错", () => {
    assert.equal(isUserRejectedRequestError({ code: "x" }), false);
    assert.equal(isUserRejectedRequestError({}), false);
  });
});

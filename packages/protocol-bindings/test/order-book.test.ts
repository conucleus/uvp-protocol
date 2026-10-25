// UVPOrderBook/1 订单域 EIP-712：域常量、type hash、字段表、构造/校验与
// 真实签名恢复（用私钥在测试内现签，仓库不留任何私钥字面量）。

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { hashTypedData, keccak256, recoverTypedDataAddress, toHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  buildOrderBookDomain,
  buildUVPStageInviteAcceptTypedData,
  buildUVPStageSettlementProposalTypedData,
  buildUVPOrderFinalizeTypedData,
  UVP_ORDER_BOOK_DOMAIN_NAME,
  UVP_ORDER_BOOK_DOMAIN_VERSION,
  UVP_STAGE_INVITE_ACCEPT_PRIMARY_TYPE,
  UVP_STAGE_INVITE_ACCEPT_TYPED_DATA_FIELDS,
  UVP_STAGE_INVITE_ACCEPT_TYPE_HASH,
  UVP_STAGE_SETTLEMENT_PROPOSAL_TYPE_HASH,
  UVP_STAGE_SETTLEMENT_PROPOSAL_TYPED_DATA_FIELDS,
  UVP_ORDER_FINALIZE_TYPED_DATA_FIELDS,
  UVP_ORDER_FINALIZE_TYPE_HASH,
  validateUVPOrderFinalizeTypedData,
  validateUVPStageInviteAcceptTypedData,
  validateUVPStageSettlementProposalTypedData,
} from "../src/order-book.js";

const verifyingContract = "0x1234567890abcdef1234567890abcdef12345678" as const;
const buyer = "0x1111111111111111111111111111111111111111" as const;
const invitee = "0x2222222222222222222222222222222222222222" as const;
const stageId = `0x${"ab".repeat(32)}` as const;
const termsHash = `0x${"cd".repeat(32)}` as const;
const standardHash = `0x${"ef".repeat(32)}` as const;

function inviteMessageFields() {
  return UVP_STAGE_INVITE_ACCEPT_TYPED_DATA_FIELDS.map(
    (field) => `${field.type} ${field.name}`,
  ).join(",");
}

function inviteTypedData() {
  return buildUVPStageInviteAcceptTypedData({
    chainId: 31337,
    verifyingContract,
    draftId: "draft-1",
    inviteId: "invite-1",
    stageKey: "inspection",
    stageId,
    slotKey: "performer",
    invitee,
    payee: invitee,
    verifier: "0x0000000000000000000000000000000000000000",
    amount: "1200000000",
    feeBps: 100,
    finalStandardHash: standardHash,
    workDeadline: 1_900_000_000,
    termsHash,
    nonce: "987654321",
    deadline: 1_800_000_000,
  });
}

describe("UVPOrderBook EIP-712 domain", () => {
  it("pins the domain name/version and normalizes the verifying contract", () => {
    const domain = buildOrderBookDomain({ chainId: 31337, verifyingContract: verifyingContract.toUpperCase().replace("0X", "0x") });
    assert.equal(domain.name, UVP_ORDER_BOOK_DOMAIN_NAME);
    assert.equal(domain.name, "UVPOrderBook");
    assert.equal(domain.version, UVP_ORDER_BOOK_DOMAIN_VERSION);
    assert.equal(domain.version, "1");
    assert.equal(domain.verifyingContract, "0x1234567890AbcdEF1234567890aBcdef12345678");
    assert.throws(() => buildOrderBookDomain({ chainId: 0, verifyingContract }));
    assert.throws(() => buildOrderBookDomain({ chainId: 31337, verifyingContract: "0x1234" }));
  });
});

describe("UVPStageInviteAccept typed data", () => {
  it("computes the canonical type hash from the field list", () => {
    const expected = keccak256(
      toHex(`UVPStageInviteAccept(${inviteMessageFields()})`),
    );
    assert.equal(UVP_STAGE_INVITE_ACCEPT_TYPE_HASH, expected);
    assert.match(UVP_STAGE_INVITE_ACCEPT_TYPE_HASH, /^0x[0-9a-f]{64}$/);
  });

  it("round-trips a real signature recovery and is case insensitive for addresses", async () => {
    const account = privateKeyToAccount(`0x${"11".repeat(32)}`);
    const typedData = inviteTypedData();
    const signature = await account.signTypedData(typedData);
    const recovered = await recoverTypedDataAddress({ ...typedData, signature });
    assert.equal(recovered.toLowerCase(), account.address.toLowerCase());

    const uppercase = {
      ...typedData,
      message: {
        ...typedData.message,
        invitee: typedData.message.invitee.toUpperCase().replace("0X", "0x"),
      },
    };
    assert.equal(hashTypedData(uppercase), hashTypedData(typedData));
  });

  it("rejects a field list or domain that drifted from the canonical shape", () => {
    const typedData = inviteTypedData();
    const validated = validateUVPStageInviteAcceptTypedData(typedData);
    assert.equal(validated.primaryType, UVP_STAGE_INVITE_ACCEPT_PRIMARY_TYPE);

    const wrongDomain = {
      ...typedData,
      domain: { ...typedData.domain, version: "2" },
    };
    assert.throws(() => validateUVPStageInviteAcceptTypedData(wrongDomain), /domain must be/);

    const wrongFields = {
      ...typedData,
      types: {
        UVPStageInviteAccept: [{ name: "draftId", type: "bytes32" }],
      },
    };
    assert.throws(() => validateUVPStageInviteAcceptTypedData(wrongFields), /field list/);

    const wrongAmount = {
      ...typedData,
      message: { ...typedData.message, amount: "-1" },
    };
    assert.throws(() => validateUVPStageInviteAcceptTypedData(wrongAmount), /amount/);
  });
});

describe("UVPStageSettlementProposal typed data", () => {
  it("computes the canonical type hash and validates the shape", () => {
    const expected = keccak256(
      toHex(
        `UVPStageSettlementProposal(${UVP_STAGE_SETTLEMENT_PROPOSAL_TYPED_DATA_FIELDS.map(
          (field) => `${field.type} ${field.name}`,
        ).join(",")})`,
      ),
    );
    assert.equal(UVP_STAGE_SETTLEMENT_PROPOSAL_TYPE_HASH, expected);

    const typedData = buildUVPStageSettlementProposalTypedData({
      chainId: 31337,
      verifyingContract,
      orderId: `0x${"01".repeat(32)}`,
      stageId,
      payerAmount: 800,
      payeeAmount: 200,
      sourceFact: `0x${"02".repeat(32)}`,
      instructionRef: `0x${"03".repeat(32)}`,
      proposer: buyer,
      counterparty: invitee,
      nonce: 7,
      deadline: 1_800_000_000,
    });
    const validated = validateUVPStageSettlementProposalTypedData(typedData);
    assert.equal(validated.message.payerAmount, "800");
    assert.equal(validated.message.payeeAmount, "200");

    assert.throws(
      () =>
        validateUVPStageSettlementProposalTypedData({
          ...typedData,
          primaryType: "UVPStageInviteAccept",
        }),
      /primaryType/,
    );
  });
});

describe("UVPOrderFinalize typed data", () => {
  it("pins the type hash, validates the shape, and recovers a real buyer signature", async () => {
    const expected = keccak256(
      toHex(
        `UVPOrderFinalize(${UVP_ORDER_FINALIZE_TYPED_DATA_FIELDS.map(
          (field) => `${field.type} ${field.name}`,
        ).join(",")})`,
      ),
    );
    assert.equal(UVP_ORDER_FINALIZE_TYPE_HASH, expected);

    const typedData = buildUVPOrderFinalizeTypedData({
      chainId: 31337,
      verifyingContract,
      draftId: "draft-1",
      planId: `0x${"01".repeat(32)}`,
      configId: "test/flow",
      configVersion: "1.0.0",
      configHash: `0x${"02".repeat(32)}`,
      buyer,
      termsHash,
      nonce: 11,
      deadline: 1_800_000_000,
    });
    assert.equal(validateUVPOrderFinalizeTypedData(typedData).primaryType, "UVPOrderFinalize");

    const account = privateKeyToAccount(`0x${"22".repeat(32)}`);
    const signature = await account.signTypedData(typedData);
    const recovered = await recoverTypedDataAddress({ ...typedData, signature });
    assert.equal(recovered.toLowerCase(), account.address.toLowerCase());

    assert.throws(
      () =>
        validateUVPOrderFinalizeTypedData({
          ...typedData,
          message: { ...typedData.message, nonce: "-1" },
        }),
      /nonce/,
    );
  });
});

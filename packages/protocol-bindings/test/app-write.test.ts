// UVPAppBackend/1 写动作契约：joint.child_order 的 primary type、字段表顺序、
// typehash、resource 字段与真实签名恢复。字段顺序是 EIP-712 摘要 preimage 的
// 一部分；后端/客户端只引用这里导出的常量，不复制。

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { keccak256, recoverTypedDataAddress, toHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  UVP_APP_BACKEND_DOMAIN_NAME,
  UVP_APP_BACKEND_DOMAIN_VERSION,
  UVP_APP_WRITE_FIELDS,
  UVP_APP_WRITE_PRIMARY_TYPES,
  UVP_APP_WRITE_RESOURCE_FIELDS,
  UVP_APP_WRITE_TYPE_HASHES,
  buildUVPAppWriteTypedData,
  hashAppWritePayload,
} from "../src/app-write.js";

const CHAIN_ID = 31337;
const PARENT_PLAN_ID = `0x${"11".repeat(32)}` as const;
const PARENT_ORDER_ID = `0x${"22".repeat(32)}` as const;
const CHILD_PLAN_ID = `0x${"33".repeat(32)}` as const;
const BODY_HASH = `0x${"44".repeat(32)}` as const;
const CREATOR = "0xAbCdEf1234567890AbCdEf1234567890AbCdEf12" as const;

describe("UVPAppBackend joint.child_order typed data", () => {
  it("pins UVPJointChildOrder type hash over the ordered field list and parentOrderId resource", () => {
    const canonical = keccak256(
      toHex(
        "UVPJointChildOrder(bytes32 parentPlanId,bytes32 parentOrderId,string parentStageKey,bytes32 childPlanId,address creator,bytes32 bodyHash,uint256 nonce,uint256 deadline)",
      ),
    );
    assert.equal(UVP_APP_WRITE_PRIMARY_TYPES["joint.child_order"], "UVPJointChildOrder");
    assert.equal(UVP_APP_WRITE_TYPE_HASHES["joint.child_order"], canonical);
    assert.equal(UVP_APP_WRITE_RESOURCE_FIELDS["joint.child_order"], "parentOrderId");
    assert.deepEqual(
      UVP_APP_WRITE_FIELDS["joint.child_order"].map((field) => field.name),
      [
        "parentPlanId",
        "parentOrderId",
        "parentStageKey",
        "childPlanId",
        "creator",
        "bodyHash",
        "nonce",
        "deadline",
      ],
    );
  });

  it("normalizes payload-derived message fields and recovers the buyer signature", async () => {
    const account = privateKeyToAccount(keccak256(toHex("uvp.protocol-bindings.joint")));
    const payload = {
      parent: { planId: PARENT_PLAN_ID, orderId: PARENT_ORDER_ID, stageKey: "acquisition" },
      child: { planId: CHILD_PLAN_ID, creator: CREATOR },
    };
    const typedData = buildUVPAppWriteTypedData({
      action: "joint.child_order",
      chainId: CHAIN_ID,
      message: {
        parentPlanId: PARENT_PLAN_ID.toUpperCase().replace("0X", "0x"),
        parentOrderId: PARENT_ORDER_ID,
        parentStageKey: " acquisition ",
        childPlanId: CHILD_PLAN_ID,
        creator: CREATOR,
        bodyHash: hashAppWritePayload(payload),
        nonce: "17",
        deadline: "1800000000",
      },
    });
    assert.equal(typedData.domain.name, UVP_APP_BACKEND_DOMAIN_NAME);
    assert.equal(typedData.domain.version, UVP_APP_BACKEND_DOMAIN_VERSION);
    assert.equal(typedData.domain.chainId, CHAIN_ID);
    assert.equal(typedData.primaryType, "UVPJointChildOrder");
    assert.equal(typedData.message.parentPlanId, PARENT_PLAN_ID);
    assert.equal(typedData.message.parentStageKey, "acquisition");
    assert.equal(typedData.message.creator?.toLowerCase(), CREATOR.toLowerCase());

    const signature = await account.signTypedData(typedData as never);
    const recovered = await recoverTypedDataAddress({
      ...typedData,
      signature,
    } as never);
    assert.equal(recovered.toLowerCase(), account.address.toLowerCase());
  });
});

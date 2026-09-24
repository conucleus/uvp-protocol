import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";
import {
  concatHex,
  decodeEventLog,
  decodeFunctionData,
  encodeAbiParameters,
  hashTypedData,
  keccak256,
  stringToHex,
  toEventHash,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  UnsupportedChainTargetError,
  unsupportedSolanaProtocolBinding,
} from "@uvp-eth/protocol-bindings/solana";
import {
  EXECUTOR_PATCH_MODE_ASSIGN,
  EXECUTOR_PATCH_MODE_HANDOFF,
  EXECUTOR_PATCH_MODE_REPLACEMENT,
  DERIVED_SIGNAL_MODULE_ABI,
  ORDER_LINK_MODULE_ABI,
  STATE_MACHINE_ABI,
  STAGE_PATCH_MODULE_ABI,
  buildApplyStageExecutorPatchForCall,
  buildApplyStageResourcePatchForCall,
  buildDerivedSignalTypedData,
  buildPlanCommitTypedData,
  buildProductSubmitTypedData,
  buildStageExecutorPatchTypedData,
  buildStageResourcePatchTypedData,
  buildSubmitDerivedSignalForCall,
  buildSubmitSignalForCall,
  buildTriggerOrderFromOutsideForCall,
  buildTriggerOrderFromSignalForCall,
  buildTriggerOrderFromSignalTypedData,
  canonicalJson,
  capabilitiesRootOf,
  deriveTriggerOrderId,
  EMPTY_CAPABILITIES_ROOT,
  factAttribution,
  hashEvidenceJson,
  hashResourceManifest,
  hashStageExecutorPatchPayload,
  hashStageResourcePatchPayload,
  selectorBindingLeaf,
  selectorBindingProofFor,
  signalCapabilityLeaf,
  STAGE_EXECUTOR_PATCH_PAYLOAD_HASH_DOMAIN,
  STAGE_RESOURCE_PATCH_PAYLOAD_HASH_DOMAIN,
  recoverDerivedSignalSigner,
  recoverPlanCommitSigner,
  recoverProductSubmitSigner,
  recoverStageExecutorPatchSigner,
  recoverStageResourcePatchSigner,
  recoverTriggerOrderFromSignalSigner,
  type ResourceManifestV1,
} from "../src/index.js";

// 能力树 golden 语料同源消费（模式对齐 compiler 侧
// capabilities-root-golden.test.ts）：vectors.json 由 @uvp-eth/compiler
// 权威实现生成，Foundry 侧 CapabilitiesRootParity.t.sol 消费同一份——
// 叶公式/建树/证明规则漂移时三份实现共享同一报警面。
interface GoldenBindingInput {
  readonly selectorStageId: `0x${string}`;
  readonly targetStageId: `0x${string}`;
}

interface GoldenCapabilityInput {
  readonly stageId: `0x${string}`;
  readonly targetSourceId: `0x${string}`;
  readonly signalId: `0x${string}`;
  readonly targetOrderRelation: 0 | 1;
}

interface GoldenSample {
  readonly name: string;
  readonly counts: {
    readonly selectorBindings: number;
    readonly signalCapabilities: number;
    readonly sortedUniqueLeaves: number;
  };
  readonly inputs: {
    readonly selectorBindings: readonly GoldenBindingInput[];
    readonly signalCapabilities: readonly GoldenCapabilityInput[];
  };
  readonly expected: {
    readonly root: `0x${string}`;
    readonly sortedUniqueLeaves: readonly `0x${string}`[];
    readonly selectorBindingLeaves: readonly {
      readonly leaf: `0x${string}`;
      readonly proofLength: number;
      readonly proof: readonly `0x${string}`[];
    }[];
    readonly signalCapabilityLeaves: readonly {
      readonly leaf: `0x${string}`;
      readonly proofLength: number;
      readonly proof: readonly `0x${string}`[];
    }[];
  };
}

const golden = JSON.parse(
  readFileSync(
    resolve(
      dirname(fileURLToPath(import.meta.url)),
      "../../compiler/fixtures/capabilities-root/v1/vectors.json",
    ),
    "utf8",
  ),
) as {
  readonly schemaVersion: string;
  readonly samples: readonly GoldenSample[];
};

// fixture 键名（targetOrderRelation）映射到本包表项键名（relation）。
function goldenBindings(sample: GoldenSample) {
  return sample.inputs.selectorBindings.map((binding) => ({
    selectorStageId: binding.selectorStageId,
    targetStageId: binding.targetStageId,
  }));
}

function goldenCapabilities(sample: GoldenSample) {
  return sample.inputs.signalCapabilities.map((capability) => ({
    stageId: capability.stageId,
    targetSourceId: capability.targetSourceId,
    signalId: capability.signalId,
    relation: capability.targetOrderRelation,
  }));
}

const privateKey =
  "0x1111111111111111111111111111111111111111111111111111111111111111" as const;
const account = privateKeyToAccount(privateKey);
const submitter = account.address.toLowerCase() as `0x${string}`;
const previousExecutorPrivateKey =
  "0x2222222222222222222222222222222222222222222222222222222222222222" as const;
const previousExecutorAccount = privateKeyToAccount(previousExecutorPrivateKey);
const previousExecutor =
  previousExecutorAccount.address.toLowerCase() as `0x${string}`;
const verifyingContract = "0x8888888888888888888888888888888888888888" as const;
const zeroAddress = "0x0000000000000000000000000000000000000000" as const;
const zeroBytes32 = bytes32("");
const orderId = bytes32("01");
const triggerOriginOrderId = bytes32("12");
const planId = bytes32("13");
const originPlanId = bytes32("18");
const localPlanId = bytes32("19");
const linkedPlanId = bytes32("20");
const targetPlanId = bytes32("21");
const triggerHookId = bytes32("14");
const triggerStageId = bytes32("15");
const sourceId = bytes32("02");
const signalId = bytes32("03");
const payloadHash = bytes32("04");
const idempotencyKey = bytes32("05");
const selectorStageId = bytes32("06");
const targetStageId = bytes32("07");
const role = bytes32("08");
const executorMetadataHash = bytes32("09");
const policyHash = bytes32("0a");
const recipientEnvelopeRoot = bytes32("0b");
const ciphertextHash = bytes32("0c");
const resourceKey = bytes32("0d");
const contentHash = bytes32("0e");
const approvalSourceId = bytes32("0f");
const approvalSignalId = bytes32("10");
const originSourceId = bytes32("16");
const originSignalId = bytes32("17");
const deadline = "1777777777";
const executor = "0x7777777777777777777777777777777777777777" as const;
const metadataURI = "ipfs://stage-overlay/executor-demo";
const handoffMetadataURI = "ipfs://stage-overlay/executor-handoff";
const replacementMetadataURI = "ipfs://stage-overlay/executor-replacement";
const manifestURI = "ipfs://stage-overlay/resource-demo";
const executorPatchNonce = "3";
const handoffPatchNonce = "4";
const replacementPatchNonce = "5";
const resourcePatchNonce = "6";
const resourceManifest: ResourceManifestV1 = {
  schemaVersion: "uvp-resource-manifest-v1",
  orderId,
  targetStageId,
  resourceKey,
  visibility: "protected",
  ciphertextHash,
  storageCID: "ipfs://bafyresourceciphertext",
  policyHash,
  recipientEnvelopeRoot,
  createdBy: submitter,
  createdAt: "2026-04-30T00:00:00.000Z",
};
const assignExecutorPatchPayload = {
  selectorStageId,
  targetStageId,
  executor,
  role,
  executorMetadataHash,
  mode: EXECUTOR_PATCH_MODE_ASSIGN,
  previousExecutor: zeroAddress,
  approvalSourceId: zeroBytes32,
  approvalSignalId: zeroBytes32,
  patchNonce: executorPatchNonce,
  metadataURI,
} as const;
const assignExecutorPatchHash = hashStageExecutorPatchPayload(
  assignExecutorPatchPayload,
);
const handoffExecutorPatchPayload = {
  selectorStageId,
  targetStageId,
  executor,
  role,
  executorMetadataHash,
  mode: EXECUTOR_PATCH_MODE_HANDOFF,
  previousExecutor,
  approvalSourceId: zeroBytes32,
  approvalSignalId: zeroBytes32,
  patchNonce: handoffPatchNonce,
  metadataURI: handoffMetadataURI,
} as const;
const handoffExecutorPatchHash = hashStageExecutorPatchPayload(
  handoffExecutorPatchPayload,
);
const replacementExecutorPatchPayload = {
  selectorStageId,
  targetStageId,
  executor,
  role,
  executorMetadataHash,
  mode: EXECUTOR_PATCH_MODE_REPLACEMENT,
  previousExecutor,
  approvalSourceId,
  approvalSignalId,
  patchNonce: replacementPatchNonce,
  metadataURI: replacementMetadataURI,
} as const;
const replacementExecutorPatchHash = hashStageExecutorPatchPayload(
  replacementExecutorPatchPayload,
);
const manifestHash = hashResourceManifest(resourceManifest);
const resourcePatchHash = hashStageResourcePatchPayload({
  selectorStageId,
  targetStageId,
  resourceKey,
  manifestHash,
  policyHash,
  patchNonce: resourcePatchNonce,
  manifestURI,
});
const signalAuthorizations = [
  {
    sourceId,
    signalId,
    submitter,
    role,
    metadataHash: executorMetadataHash,
  },
] as const;

describe("protocol bindings", () => {
  it("exposes plan-scoped hook observation events", () => {
    // 订单级事件自 v0.10 起携带 planId（事件口径冻结面，事件签名不随
    // EIP-712 版本走；当前签名域版本 0.12）。
    assert.equal(
      toEventHash("HookStatusChanged(bytes32,bytes32,bytes32,uint8,uint8,uint64)"),
      "0xa0c688f78d307bee6d38b69ad4c19b02d9e1be8c6772327015b60fd21ec38fd2"
    );
    assert.equal(
      toEventHash("TimerPoked(bytes32,bytes32,bytes32,uint64)"),
      "0x4662f441e8cd10042e3591b57bbcf10851c0d735032f89690d2cca5d1297fd57"
    );

    const decoded = decodeEventLog({
      abi: STATE_MACHINE_ABI,
      data: (
        "0x"
        + "00".repeat(31) + "01"
        + "00".repeat(31) + "02"
        + "00".repeat(24) + "0000000000000018"
      ) as `0x${string}`,
      topics: [
        "0xa0c688f78d307bee6d38b69ad4c19b02d9e1be8c6772327015b60fd21ec38fd2",
        `0x${"33".repeat(32)}`,
        `0x${"11".repeat(32)}`,
        `0x${"22".repeat(32)}`
      ] as const
    });
    assert.equal(decoded.eventName, "HookStatusChanged");
    assert.deepEqual(decoded.args, {
      planId: "0x" + "33".repeat(32),
      orderId: "0x" + "11".repeat(32),
      hookId: "0x" + "22".repeat(32),
      previousStatus: 1,
      newStatus: 2,
      dueAt: 24n
    });
  });

  it("rejects unimplemented Solana protocol bindings", () => {
    assert.throws(
      () => unsupportedSolanaProtocolBinding(),
      (error) =>
        error instanceof UnsupportedChainTargetError &&
        error.target === "solana" &&
        /not implemented/.test(error.message),
    );
  });

  it("builds stable Product submit typed data", () => {
    const typedData = buildProductSubmitTypedData({
      chainId: 31337,
      verifyingContract,
      planId,
      orderId,
      sourceId,
      signalId,
      payloadHash,
      idempotencyKey,
      submitter,
      deadline,
    });

    assert.deepEqual(typedData, {
      domain: {
        name: "UVPStateMachine",
        version: "0.12",
        chainId: 31337,
        verifyingContract,
      },
      types: {
        UVPStateMachineSignal: [
          { name: "planId", type: "bytes32" },
          { name: "orderId", type: "bytes32" },
          { name: "sourceId", type: "bytes32" },
          { name: "signalId", type: "bytes32" },
          { name: "payloadHash", type: "bytes32" },
          { name: "idempotencyKey", type: "bytes32" },
          { name: "submitter", type: "address" },
          { name: "deadline", type: "uint256" },
        ],
      },
      primaryType: "UVPStateMachineSignal",
      message: {
        planId,
        orderId,
        sourceId,
        signalId,
        payloadHash,
        idempotencyKey,
        submitter,
        deadline,
      },
    });
  });

  it("recovers a Product submit signer", async () => {
    const typedData = buildProductSubmitTypedData({
      chainId: 31337,
      verifyingContract,
      planId,
      orderId,
      sourceId,
      signalId,
      payloadHash,
      idempotencyKey,
      submitter,
      deadline,
    });
    const signature = await account.signTypedData(
      typedData as unknown as Parameters<typeof account.signTypedData>[0],
    );

    assert.equal(
      await recoverProductSubmitSigner(typedData, signature),
      submitter,
    );
  });

  it("builds and recovers a PlanCommit publisher signature", async () => {
    // commitPlan(PlanCommit, hooks, signature) 是 UVPStateMachine 的签名面
    // 之一：七个 typed-data builder 中 PlanCommit 不得是唯一没有 recover
    // 助手的一个（签名面不对称会让发布侧无法离线验证 publisher）。
    const typedData = buildPlanCommitTypedData({
      chainId: 31337,
      verifyingContract,
      publisher: submitter,
      hooksHash: payloadHash,
      capabilitiesRoot: idempotencyKey,
      dockRoutesRoot: planId,
      dockInterfaceRoot: originPlanId,
      deadline,
    });
    const signature = await account.signTypedData(
      typedData as unknown as Parameters<typeof account.signTypedData>[0],
    );

    assert.equal(typedData.primaryType, "UVPStateMachinePlanCommit");
    assert.deepEqual(
      typedData.types.UVPStateMachinePlanCommit.map((field) => field.name),
      [
        "publisher",
        "hooksHash",
        "capabilitiesRoot",
        "dockRoutesRoot",
        "dockInterfaceRoot",
        "deadline",
      ],
    );
    assert.equal(
      await recoverPlanCommitSigner(typedData, signature),
      submitter,
    );
  });

  it("builds and recovers trigger-origin order typed data", async () => {
    const typedData = buildTriggerOrderFromSignalTypedData({
      chainId: 31337,
      verifyingContract,
      orderId,
      planId,
      creator: submitter,
      triggerOriginOrderId,
      originPlanId,
      triggerHookId,
      triggerStageId,
      originSourceId,
      originSignalId,
      payloadHash,
      idempotencyKey,
      authorizations: signalAuthorizations,
      submitter,
      deadline,
    });
    const signature = await account.signTypedData(
      typedData as unknown as Parameters<typeof account.signTypedData>[0],
    );

    assert.deepEqual(
      typedData.types.UVPOrderLinkModuleTriggerOrderFromSignal.map(
        (field) => field.name,
      ),
      [
        "orderId",
        "planId",
        "creator",
        "triggerOriginOrderId",
        "originPlanId",
        "triggerHookId",
        "triggerStageId",
        "originSourceId",
        "originSignalId",
        "payloadHash",
        "idempotencyKey",
        "authorizationsHash",
        "submitter",
        "deadline",
      ],
    );
    assert.equal(typedData.message.triggerOriginOrderId, triggerOriginOrderId);
    assert.equal(
      await recoverTriggerOrderFromSignalSigner(typedData, signature),
      submitter,
    );
  });

  it("builds assign, handoff, and replacement stage executor patch typed data", () => {
    const cases = [
      {
        payload: assignExecutorPatchPayload,
        patchHash: assignExecutorPatchHash,
      },
      {
        payload: handoffExecutorPatchPayload,
        patchHash: handoffExecutorPatchHash,
      },
      {
        payload: replacementExecutorPatchPayload,
        patchHash: replacementExecutorPatchHash,
      },
    ] as const;

    const [firstCase] = cases;
    assert.ok(firstCase);
    const firstTypedData = buildStageExecutorPatchTypedData({
      chainId: 31337,
      verifyingContract,
      planId,
      orderId,
      ...firstCase.payload,
      patchHash: firstCase.patchHash,
      selector: submitter,
      deadline,
    });

    assert.deepEqual(
      firstTypedData.types.UVPStagePatchModuleStageExecutorPatch,
      [
        { name: "planId", type: "bytes32" },
        { name: "orderId", type: "bytes32" },
        { name: "selectorStageId", type: "bytes32" },
        { name: "targetStageId", type: "bytes32" },
        { name: "executor", type: "address" },
        { name: "role", type: "bytes32" },
        { name: "executorMetadataHash", type: "bytes32" },
        { name: "mode", type: "bytes32" },
        { name: "previousExecutor", type: "address" },
        { name: "approvalSourceId", type: "bytes32" },
        { name: "approvalSignalId", type: "bytes32" },
        { name: "patchHash", type: "bytes32" },
        { name: "patchNonce", type: "uint256" },
        { name: "metadataURI", type: "string" },
        { name: "selector", type: "address" },
        { name: "deadline", type: "uint256" },
      ],
    );
    assert.equal(
      firstTypedData.primaryType,
      "UVPStagePatchModuleStageExecutorPatch",
    );

    for (const { payload, patchHash } of cases) {
      const typedData = buildStageExecutorPatchTypedData({
        chainId: 31337,
        verifyingContract,
        planId,
        orderId,
        ...payload,
        patchHash,
        selector: submitter,
        deadline,
      });

      assert.equal(typedData.message.mode, payload.mode);
      assert.equal(
        typedData.message.previousExecutor,
        payload.previousExecutor,
      );
      assert.equal(
        typedData.message.approvalSourceId,
        payload.approvalSourceId,
      );
      assert.equal(
        typedData.message.approvalSignalId,
        payload.approvalSignalId,
      );
      assert.equal(typedData.message.patchHash, patchHash);
      assert.equal(typedData.message.patchNonce, payload.patchNonce);
      assert.equal(typedData.message.metadataURI, payload.metadataURI);
      assert.equal("fileResourcesHash" in typedData.message, false);
    }
  });

  it("recovers selector and previous executor stage executor patch signers", async () => {
    const typedData = buildStageExecutorPatchTypedData({
      chainId: 31337,
      verifyingContract,
      planId,
      orderId,
      ...handoffExecutorPatchPayload,
      patchHash: handoffExecutorPatchHash,
      selector: submitter,
      deadline,
    });
    const selectorSignature = await account.signTypedData(
      typedData as unknown as Parameters<typeof account.signTypedData>[0],
    );
    const previousExecutorSignature =
      await previousExecutorAccount.signTypedData(
        typedData as unknown as Parameters<
          typeof previousExecutorAccount.signTypedData
        >[0],
      );

    assert.equal(
      await recoverStageExecutorPatchSigner(typedData, selectorSignature),
      submitter,
    );
    assert.equal(
      await recoverStageExecutorPatchSigner(
        typedData,
        previousExecutorSignature,
      ),
      previousExecutor,
    );
  });

  it("builds and recovers stage resource patch typed data", async () => {
    const typedData = buildStageResourcePatchTypedData({
      chainId: 31337,
      verifyingContract,
      planId,
      orderId,
      selectorStageId,
      targetStageId,
      resourceKey,
      manifestHash,
      policyHash,
      patchHash: resourcePatchHash,
      patchNonce: resourcePatchNonce,
      manifestURI,
      selector: submitter,
      deadline,
    });
    const signature = await account.signTypedData(
      typedData as unknown as Parameters<typeof account.signTypedData>[0],
    );

    assert.deepEqual(typedData.types.UVPStagePatchModuleStageResourcePatch, [
      { name: "planId", type: "bytes32" },
      { name: "orderId", type: "bytes32" },
      { name: "selectorStageId", type: "bytes32" },
      { name: "targetStageId", type: "bytes32" },
      { name: "resourceKey", type: "bytes32" },
      { name: "manifestHash", type: "bytes32" },
      { name: "policyHash", type: "bytes32" },
      { name: "patchHash", type: "bytes32" },
      { name: "patchNonce", type: "uint256" },
      { name: "manifestURI", type: "string" },
      { name: "selector", type: "address" },
      { name: "deadline", type: "uint256" },
    ]);
    assert.equal(
      typedData.primaryType,
      "UVPStagePatchModuleStageResourcePatch",
    );
    assert.equal(typedData.message.patchNonce, resourcePatchNonce);
    assert.equal(typedData.message.manifestURI, manifestURI);
    assert.equal(
      await recoverStageResourcePatchSigner(typedData, signature),
      submitter,
    );
  });

  it("builds submitSignalFor calls from the shared ABI", () => {
    const signature = `0x${"aa".repeat(65)}` as const;
    const capabilityProof = [payloadHash, idempotencyKey] as const;
    const call = buildSubmitSignalForCall(
      {
        stateMachineAddress: verifyingContract,
        chainId: 31337,
      },
      {
        planId,
        orderId,
        sourceId,
        signalId,
        payloadHash,
        idempotencyKey,
        submitter,
        deadline,
        signature,
        attribution: {
          sourceId: `0x${sourceId.slice(2).toUpperCase()}`,
          signalId,
          stageId: targetStageId,
          capabilityProof,
        },
        selectorBinding: {
          selectorStageId,
          proof: [],
        },
      },
    );

    assert.equal(call.address, verifyingContract);
    assert.equal(call.abi, STATE_MACHINE_ABI);
    assert.equal(call.functionName, "submitSignalFor");
    assert.deepEqual(call.args, [
      planId,
      orderId,
      sourceId,
      signalId,
      payloadHash,
      idempotencyKey,
      submitter,
      BigInt(deadline),
      signature,
      // attribution 归一化：大小写折叠 + proof 数组逐词 bytes32 校验。
      { sourceId, signalId, stageId: targetStageId, capabilityProof: [...capabilityProof] },
      { selectorStageId, proof: [] },
    ]);
    assert.match(call.data, /^0x[0-9a-f]+$/);
    const decoded = decodeFunctionData({
      abi: STATE_MACHINE_ABI,
      data: call.data,
    });
    assert.equal(decoded.functionName, "submitSignalFor");
    const decodedArgs = decoded.args as unknown as [
      unknown,
      unknown,
      unknown,
      unknown,
      unknown,
      unknown,
      unknown,
      unknown,
      unknown,
      { sourceId: `0x${string}`; capabilityProof: readonly `0x${string}`[] },
      { selectorStageId: `0x${string}`; proof: readonly `0x${string}`[] },
    ];
    assert.equal(decodedArgs[9].sourceId, sourceId);
    assert.deepEqual(decodedArgs[9].capabilityProof, [...capabilityProof]);
    assert.equal(decodedArgs[10].selectorStageId, selectorStageId);
  });

  it("matches the shared capabilities-root golden vectors consumed by compiler and Foundry", () => {
    // 同源消费 packages/compiler/fixtures/capabilities-root/v1/vectors.json
    // （compiler 权威实现生成，Foundry 侧 CapabilitiesRootParity.t.sol 消费
    // 同一份）：叶公式/建树/证明规则漂移时三份实现共享同一报警面，本包
    // 不自产硬编码根值。
    assert.equal(golden.schemaVersion, "uvp.capabilities-root.golden.v1");
    assert.equal(golden.samples.length, 2);
    for (const sample of golden.samples) {
      const selectorBindings = goldenBindings(sample);
      const signalCapabilities = goldenCapabilities(sample);
      const { expected } = sample;
      // 计数镜像（forge 侧 vm.parseJson 不支持 .length 路径）与实际数组
      // 长一致，防止 fixture 内部漂移。
      assert.equal(selectorBindings.length, sample.counts.selectorBindings);
      assert.equal(signalCapabilities.length, sample.counts.signalCapabilities);
      assert.equal(
        expected.sortedUniqueLeaves.length,
        sample.counts.sortedUniqueLeaves,
      );

      // 树根与排序去重叶集：能力叶/绑定叶域分隔混编进同一棵排序配对树。
      assert.equal(
        capabilitiesRootOf(selectorBindings, signalCapabilities),
        expected.root,
      );
      assert.deepEqual(
        [
          ...new Set([
            ...selectorBindings.map((binding) =>
              selectorBindingLeaf(
                binding.selectorStageId,
                binding.targetStageId,
              ),
            ),
            ...signalCapabilities.map((capability) =>
              signalCapabilityLeaf(
                capability.stageId,
                capability.targetSourceId,
                capability.signalId,
                capability.relation,
              ),
            ),
          ]),
        ].sort(),
        expected.sortedUniqueLeaves,
      );

      // 每条绑定输入：叶公式重算 + 按目标阶段取证的 proof 逐字相等。
      for (const [index, binding] of selectorBindings.entries()) {
        assert.equal(
          selectorBindingLeaf(binding.selectorStageId, binding.targetStageId),
          expected.selectorBindingLeaves[index]!.leaf,
        );
        const proof = selectorBindingProofFor(
          selectorBindings,
          signalCapabilities,
          binding.targetStageId,
        );
        assert.ok(proof, "bound target stage must yield a selector proof");
        assert.equal(proof.selectorStageId, binding.selectorStageId);
        assert.deepEqual(proof.proof, expected.selectorBindingLeaves[index]!.proof);
        assert.equal(
          foldProof(
            selectorBindingLeaf(binding.selectorStageId, binding.targetStageId),
            proof.proof,
          ),
          expected.root,
        );
      }

      // 每条能力输入：叶公式重算；relation=0 是事实属主自证材料（stageId +
      // proof 与 pinned 叶证明一致），relation=1 不构成属主自证。
      for (const [index, capability] of signalCapabilities.entries()) {
        const leaf = signalCapabilityLeaf(
          capability.stageId,
          capability.targetSourceId,
          capability.signalId,
          capability.relation,
        );
        assert.equal(leaf, expected.signalCapabilityLeaves[index]!.leaf);
        const attribution = factAttribution(
          selectorBindings,
          signalCapabilities,
          capability.targetSourceId,
          capability.signalId,
        );
        if (capability.relation === 0) {
          assert.ok(attribution, "relation=0 fact key must resolve to an owner");
          assert.equal(attribution.stageId, capability.stageId);
          assert.deepEqual(
            attribution.capabilityProof,
            expected.signalCapabilityLeaves[index]!.proof,
          );
        } else {
          assert.equal(attribution, undefined);
        }
      }
    }

    // 空表根 = keccak256("")（合约 DockMerkle.EMPTY_ROOT 的规范空根常量）。
    assert.equal(
      EMPTY_CAPABILITIES_ROOT,
      "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
    );
    assert.equal(capabilitiesRootOf([], []), EMPTY_CAPABILITIES_ROOT);

    // 大小写归一：等价 word 不因拼写漂移换根。
    const sample = golden.samples[0]!;
    assert.equal(
      capabilitiesRootOf(
        goldenBindings(sample).map((binding) => ({
          selectorStageId: `0x${binding.selectorStageId.slice(2).toUpperCase()}`,
          targetStageId: `0x${binding.targetStageId.slice(2).toUpperCase()}`,
        })),
        goldenCapabilities(sample).map((capability) => ({
          stageId: `0x${capability.stageId.slice(2).toUpperCase()}`,
          targetSourceId: `0x${capability.targetSourceId
            .slice(2)
            .toUpperCase()}`,
          signalId: `0x${capability.signalId.slice(2).toUpperCase()}`,
          relation: capability.relation,
        })),
      ),
      sample.expected.root,
    );
    // 词表外事实键不构成属主自证；未被绑定的目标阶段返回 undefined
    // （调用方提交零 selectorStageId 的空证明）。
    assert.equal(
      factAttribution(
        goldenBindings(sample),
        goldenCapabilities(sample),
        "0x0000000000000000000000000000000000000000000000000000000000000bad",
        "0x0000000000000000000000000000000000000000000000000000000000000bad",
      ),
      undefined,
    );
    assert.equal(
      selectorBindingProofFor(
        goldenBindings(sample),
        goldenCapabilities(sample),
        "0x0000000000000000000000000000000000000000000000000000000000000bad",
      ),
      undefined,
    );
  });

  it("wires capability-tree proofs straight into submitSignalFor attribution args", () => {
    const stageA = bytes32("a1");
    const stageB = bytes32("a2");
    const bindings = [
      { selectorStageId: stageA, targetStageId: stageB },
    ] as const;
    const capabilities = [
      { stageId: stageA, targetSourceId: sourceId, signalId, relation: 0 },
    ] as const;
    const attribution = factAttribution(bindings, capabilities, sourceId, signalId);
    const selectorBinding = selectorBindingProofFor(
      bindings,
      capabilities,
      stageB,
    );
    assert.ok(attribution && selectorBinding);

    const call = buildSubmitSignalForCall(
      { stateMachineAddress: verifyingContract, chainId: 31337 },
      {
        planId,
        orderId,
        sourceId,
        signalId,
        payloadHash,
        idempotencyKey,
        submitter,
        deadline,
        signature: `0x${"aa".repeat(65)}` as const,
        attribution: {
          sourceId,
          signalId,
          stageId: attribution.stageId,
          capabilityProof: attribution.capabilityProof,
        },
        selectorBinding: selectorBinding,
      },
    );
    assert.deepEqual(call.args[9], {
      sourceId,
      signalId,
      stageId: stageA,
      capabilityProof: attribution.capabilityProof,
    });
    assert.deepEqual(call.args[10], {
      selectorStageId: stageA,
      proof: selectorBinding.proof,
    });
    const decoded = decodeFunctionData({
      abi: STATE_MACHINE_ABI,
      data: call.data,
    });
    assert.equal(decoded.functionName, "submitSignalFor");
  });

  it("builds triggerOrderFromSignalFor calls from the order-link module ABI", () => {
    const signature = `0x${"ac".repeat(65)}` as const;
    const originFactAttributions = [
      { sourceId: originSourceId, signalId: originSignalId, stageId: targetStageId, capabilityProof: [payloadHash] },
    ] as const;
    const call = buildTriggerOrderFromSignalForCall(
      {
        orderLinkModuleAddress: verifyingContract,
        chainId: 31337,
      },
      {
        orderId,
        planId,
        creator: submitter,
        triggerOriginOrderId,
        originPlanId,
        triggerHookId,
        triggerStageId,
        originSourceId,
        originSignalId,
        payloadHash,
        idempotencyKey,
        submitter,
        deadline,
        authorizations: signalAuthorizations,
        signature,
        originFactAttributions,
      },
    );
    const decoded = decodeFunctionData({
      abi: ORDER_LINK_MODULE_ABI,
      data: call.data,
    });

    assert.equal(call.address, verifyingContract);
    assert.equal(call.abi, ORDER_LINK_MODULE_ABI);
    assert.equal(call.functionName, "triggerOrderFromSignalFor");
    assert.equal(call.args[0].triggerOriginOrderId, triggerOriginOrderId);
    assert.deepEqual(call.args[3], [
      {
        sourceId: originSourceId,
        signalId: originSignalId,
        stageId: targetStageId,
        capabilityProof: [payloadHash],
      },
    ]);
    assert.equal(decoded.functionName, "triggerOrderFromSignalFor");
    const decodedArgs = decoded.args as unknown as readonly [
      { triggerOriginOrderId: `0x${string}` },
      unknown,
      `0x${string}`,
      readonly {
        sourceId: `0x${string}`;
        signalId: `0x${string}`;
        stageId: `0x${string}`;
        capabilityProof: readonly `0x${string}`[];
      }[],
    ];
    assert.ok(decodedArgs);
    assert.equal(decodedArgs[0].triggerOriginOrderId, triggerOriginOrderId);
    assert.equal(decodedArgs[2], signature);
    assert.deepEqual(decodedArgs[3], [
      {
        sourceId: originSourceId,
        signalId: originSignalId,
        stageId: targetStageId,
        capabilityProof: [payloadHash],
      },
    ]);
  });

  it("builds submitDerivedSignalFor calls from the derived signal module ABI", () => {
    const signature = `0x${"ab".repeat(65)}` as const;
    const proofs = {
      fromCapabilityProof: [payloadHash],
      targetCapabilityProof: [idempotencyKey],
      selectorBinding: { selectorStageId, proof: [] },
    } as const;
    const call = buildSubmitDerivedSignalForCall(
      {
        derivedSignalModuleAddress: verifyingContract,
        chainId: 31337,
      },
      {
        fromPlanId: planId,
        fromOrderId: orderId,
        fromStageId: targetStageId,
        targetPlanId,
        targetOrderId: bytes32("11"),
        targetSourceId: sourceId,
        signalId,
        payloadHash,
        idempotencyKey,
        submitter,
        deadline,
        signature,
        proofs,
      },
    );

    assert.equal(call.address, verifyingContract);
    assert.equal(call.abi, DERIVED_SIGNAL_MODULE_ABI);
    assert.equal(call.functionName, "submitDerivedSignalFor");
    assert.deepEqual(call.args, [
      {
        fromPlanId: planId,
        fromOrderId: orderId,
        fromStageId: targetStageId,
        targetPlanId,
        targetOrderId: bytes32("11"),
        targetSourceId: sourceId,
        signalId,
        payloadHash,
        idempotencyKey,
      },
      submitter,
      BigInt(deadline),
      signature,
      {
        fromCapabilityProof: [payloadHash],
        targetCapabilityProof: [idempotencyKey],
        selectorBinding: { selectorStageId, proof: [] },
      },
    ]);
    assert.match(call.data, /^0x[0-9a-f]+$/);
  });

  it("builds derived signal typed data whose digest matches the module formula", async () => {
    const typedData = buildDerivedSignalTypedData({
      fromPlanId: planId,
      fromOrderId: orderId,
      fromStageId: targetStageId,
      targetPlanId,
      targetOrderId: bytes32("11"),
      targetSourceId: sourceId,
      signalId,
      payloadHash,
      idempotencyKey,
      submitter,
      deadline,
      chainId: 31337,
      verifyingContract,
    });

    assert.equal(typedData.domain.name, "UVPDerivedSignalModule");
    assert.equal(typedData.domain.version, "0.6");
    assert.equal(typedData.primaryType, "UVPDerivedSignalModuleSignal");

    // 与 UVPDerivedSignalModule.derivedSignalDigest 的链上公式逐字段对拍：
    // typehash（字段名/顺序即冻结面）、domain separator、struct hash。
    const typehash = keccak256(
      stringToHex(
        "UVPDerivedSignalModuleSignal(bytes32 fromPlanId,bytes32 fromOrderId,bytes32 fromStageId,bytes32 targetPlanId,bytes32 targetOrderId,bytes32 targetSourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline)",
      ),
    );
    const domainSeparator = keccak256(
      encodeAbiParameters(
        [
          { name: "typehash", type: "bytes32" },
          { name: "name", type: "bytes32" },
          { name: "version", type: "bytes32" },
          { name: "chainId", type: "uint256" },
          { name: "verifyingContract", type: "address" },
        ],
        [
          keccak256(
            stringToHex(
              "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
            ),
          ),
          keccak256(stringToHex("UVPDerivedSignalModule")),
          keccak256(stringToHex("0.6")),
          31337n,
          verifyingContract,
        ],
      ),
    );
    const structHash = keccak256(
      encodeAbiParameters(
        [
          { name: "typehash", type: "bytes32" },
          { name: "fromPlanId", type: "bytes32" },
          { name: "fromOrderId", type: "bytes32" },
          { name: "fromStageId", type: "bytes32" },
          { name: "targetPlanId", type: "bytes32" },
          { name: "targetOrderId", type: "bytes32" },
          { name: "targetSourceId", type: "bytes32" },
          { name: "signalId", type: "bytes32" },
          { name: "payloadHash", type: "bytes32" },
          { name: "idempotencyKey", type: "bytes32" },
          { name: "submitter", type: "address" },
          { name: "deadline", type: "uint256" },
        ],
        [
          typehash,
          planId,
          orderId,
          targetStageId,
          targetPlanId,
          bytes32("11"),
          sourceId,
          signalId,
          payloadHash,
          idempotencyKey,
          submitter,
          BigInt(deadline),
        ],
      ),
    );
    const expectedDigest = keccak256(
      concatHex(["0x1901", domainSeparator, structHash]),
    );
    assert.equal(
      await hashTypedData({
        domain: typedData.domain,
        types: typedData.types,
        primaryType: typedData.primaryType,
        message: typedData.message,
      }),
      expectedDigest,
    );

    // 签名/恢复闭环：module 的 submitter 即 EIP-712 签名者。
    const signature = await account.signTypedData({
      domain: typedData.domain,
      types: typedData.types,
      primaryType: typedData.primaryType,
      message: typedData.message,
    });
    assert.equal(await recoverDerivedSignalSigner(typedData, signature), submitter);
  });

  it("builds applyStageExecutorPatchFor calls from the stage patch module ABI", () => {
    const selectorSignature = `0x${"bb".repeat(65)}` as const;
    const previousExecutorSignature = `0x${"dd".repeat(65)}` as const;
    const bindingProof = { selectorStageId, proof: [payloadHash] } as const;
    const stageFacts = [
      { sourceId, signalId, capabilityProof: [idempotencyKey] },
    ] as const;
    const call = buildApplyStageExecutorPatchForCall(
      {
        stagePatchModuleAddress: verifyingContract,
        chainId: 31337,
      },
      {
        planId,
        orderId,
        patch: {
          ...replacementExecutorPatchPayload,
          patchHash: replacementExecutorPatchHash,
        },
        selector: submitter,
        deadline,
        selectorSignature,
        previousExecutorSignature,
        bindingProof,
        stageFacts,
      },
    );
    const decoded = decodeFunctionData({
      abi: STAGE_PATCH_MODULE_ABI,
      data: call.data,
    });

    assert.equal(call.address, verifyingContract);
    assert.equal(call.abi, STAGE_PATCH_MODULE_ABI);
    assert.equal(call.functionName, "applyStageExecutorPatchFor");
    assert.deepEqual(call.args, [
      planId,
      orderId,
      [
        selectorStageId,
        targetStageId,
        executor,
        role,
        executorMetadataHash,
        EXECUTOR_PATCH_MODE_REPLACEMENT,
        previousExecutor,
        approvalSourceId,
        approvalSignalId,
        replacementExecutorPatchHash,
        BigInt(replacementPatchNonce),
        replacementMetadataURI,
      ],
      submitter,
      BigInt(deadline),
      selectorSignature,
      previousExecutorSignature,
      { selectorStageId, proof: [payloadHash] },
      [{ sourceId, signalId, capabilityProof: [idempotencyKey] }],
    ]);
    assert.equal(decoded.functionName, "applyStageExecutorPatchFor");
    assert.ok(decoded.args);
    const decodedArgs = decoded.args;
    assert.equal(decodedArgs[0], planId);
    assert.equal(decodedArgs[1], orderId);
    assert.deepEqual(decodedArgs[2], {
      selectorStageId,
      targetStageId,
      executor,
      role,
      executorMetadataHash,
      mode: EXECUTOR_PATCH_MODE_REPLACEMENT,
      previousExecutor: previousExecutorAccount.address,
      approvalSourceId,
      approvalSignalId,
      patchHash: replacementExecutorPatchHash,
      patchNonce: BigInt(replacementPatchNonce),
      metadataURI: replacementMetadataURI,
    });
    assert.equal(String(decodedArgs[3]).toLowerCase(), submitter);
    assert.equal(decodedArgs[4], BigInt(deadline));
    assert.equal(decodedArgs[5], selectorSignature);
    assert.equal(decodedArgs[6], previousExecutorSignature);
    assert.deepEqual(decodedArgs[7], { selectorStageId, proof: [payloadHash] });
    assert.deepEqual(decodedArgs[8], [
      { sourceId, signalId, capabilityProof: [idempotencyKey] },
    ]);
  });

  it("builds applyStageResourcePatchFor calls from the stage patch module ABI", () => {
    const signature = `0x${"cc".repeat(65)}` as const;
    const bindingProof = { selectorStageId, proof: [] } as const;
    const stageFacts = [] as const;
    const call = buildApplyStageResourcePatchForCall(
      {
        stagePatchModuleAddress: verifyingContract,
        chainId: 31337,
      },
      {
        planId,
        orderId,
        patch: {
          selectorStageId,
          targetStageId,
          resourceKey,
          manifestHash,
          policyHash,
          patchHash: resourcePatchHash,
          patchNonce: resourcePatchNonce,
          manifestURI,
        },
        selector: submitter,
        deadline,
        signature,
        bindingProof,
        stageFacts,
      },
    );
    const decoded = decodeFunctionData({
      abi: STAGE_PATCH_MODULE_ABI,
      data: call.data,
    });

    assert.equal(call.address, verifyingContract);
    assert.equal(call.abi, STAGE_PATCH_MODULE_ABI);
    assert.equal(call.functionName, "applyStageResourcePatchFor");
    assert.deepEqual(call.args, [
      planId,
      orderId,
      [
        selectorStageId,
        targetStageId,
        resourceKey,
        manifestHash,
        policyHash,
        resourcePatchHash,
        BigInt(resourcePatchNonce),
        manifestURI,
      ],
      submitter,
      BigInt(deadline),
      signature,
      { selectorStageId, proof: [] },
      [],
    ]);
    assert.equal(decoded.functionName, "applyStageResourcePatchFor");
    assert.ok(decoded.args);
    const decodedArgs = decoded.args;
    assert.equal(decodedArgs[0], planId);
    assert.equal(decodedArgs[1], orderId);
    assert.deepEqual(decodedArgs[2], {
      selectorStageId,
      targetStageId,
      resourceKey,
      manifestHash,
      policyHash,
      patchHash: resourcePatchHash,
      patchNonce: BigInt(resourcePatchNonce),
      manifestURI,
    });
    assert.equal(String(decodedArgs[3]).toLowerCase(), submitter);
    assert.equal(decodedArgs[4], BigInt(deadline));
    assert.equal(decodedArgs[5], signature);
    assert.deepEqual(decodedArgs[6], { selectorStageId, proof: [] });
    assert.deepEqual(decodedArgs[7], []);
  });

  it("hashes canonical JSON in a browser-safe helper", () => {
    assert.equal(
      canonicalJson({ b: 2, a: { d: 4, c: 3 } }),
      '{"a":{"c":3,"d":4},"b":2}',
    );
    // 浮点拒绝——canonical 哈希输入只收整数，非整值 float
    // 与负零（f64 -0.0）响亮拒绝（与 @uvp-eth/compiler canonical.ts 同口
    // 径，三线语料 uvp-core fixtures/canonical/canonical.v1.json 钉死边界）。
    assert.equal(canonicalJson({ n: 0 }), '{"n":0}');
    assert.throws(() => canonicalJson({ n: -0 }), /float-form numbers.*received -0/);
    assert.throws(
      () => canonicalJson({ optional: undefined }),
      /undefined object properties/,
    );
    assert.equal(
      hashEvidenceJson({ b: 2, a: 1 }).evidenceHash,
      hashEvidenceJson({ a: 1, b: 2 }).evidenceHash,
    );
    // Code-point key order (Rust authority): astral keys sort AFTER every
    // BMP key; UTF-16 code-unit order would put the surrogate pair first.
    const astral = "\u{1F600}";
    const bmp = "\uFFFD";
    assert.equal(
      canonicalJson({ [astral]: 1, [bmp]: 2 }),
      `{"${bmp}":2,"${astral}":1}`,
    );
    assert.equal(
      canonicalJson({ "\u{10FFFF}": 1, "\uFFFE": 2 }),
      `{"\uFFFE":2,"\u{10FFFF}":1}`,
    );
    // 浮点拒绝——canonical 哈希输入只收整数与 -0，
    // 非整值 float 响亮拒绝（与 @uvp-eth/compiler canonical.ts 同口径，
    // 三线语料 uvp-core fixtures/canonical/canonical.v1.json 钉死边界）。
    assert.throws(() => canonicalJson(1.5), /float-form numbers/);
    assert.throws(() => canonicalJson({ a: [0, 0.5] }), /float-form numbers/);
    assert.throws(() => canonicalJson(1e-5), /float-form numbers/);
  });

  it("rejects chain ids at and beyond the 64-bit FFI boundary", () => {
    const base = {
      verifyingContract,
      planId,
      orderId,
      sourceId,
      signalId,
      payloadHash,
      idempotencyKey,
      submitter,
      deadline,
    };
    // 负数 / 零 / 非整数拒绝。
    assert.throws(
      () => buildProductSubmitTypedData({ ...base, chainId: -1 }),
      /chainId must be a positive integer/,
    );
    assert.throws(
      () => buildProductSubmitTypedData({ ...base, chainId: 0 }),
      /chainId must be a positive integer/,
    );
    assert.throws(
      () => buildProductSubmitTypedData({ ...base, chainId: 31337.5 }),
      /chainId must be a positive integer/,
    );
    // ≥ 2^64 显式拒绝（FFI 域保持 64 位）——number 面上不可精确表示，
    // 但拒绝必须发生在入口而不是静默取整后放行。
    assert.throws(
      () => buildProductSubmitTypedData({ ...base, chainId: 2 ** 64 }),
      /chainId must be < 2\^64/,
    );
    assert.throws(
      () => buildProductSubmitTypedData({ ...base, chainId: 1e21 }),
      /chainId must be < 2\^64/,
    );
    // 2^53 以上的整数（如 1e19 < 2^64）因无法精确表示同样拒绝。
    assert.throws(
      () => buildProductSubmitTypedData({ ...base, chainId: 1e19 }),
      /chainId must be a safe integer/,
    );
    // 边界内正常放行。
    assert.doesNotThrow(() =>
      buildProductSubmitTypedData({ ...base, chainId: 31337 }),
    );
  });

  it("hashes split patch payloads canonically", () => {
    assert.equal(
      EXECUTOR_PATCH_MODE_ASSIGN,
      "0x61737369676e0000000000000000000000000000000000000000000000000000",
    );
    assert.equal(
      EXECUTOR_PATCH_MODE_HANDOFF,
      "0x68616e646f666600000000000000000000000000000000000000000000000000",
    );
    assert.equal(
      EXECUTOR_PATCH_MODE_REPLACEMENT,
      "0x7265706c6163656d656e74000000000000000000000000000000000000000000",
    );
    // payload 哈希必须吃进导出的域常量（域分离）——keccak256(abi
    // .encode(keccak256(domain), …payload))。独立重算而非同源引用。
    assert.equal(
      STAGE_EXECUTOR_PATCH_PAYLOAD_HASH_DOMAIN,
      "uvp:stage-executor-patch-payload:v1",
    );
    assert.equal(
      STAGE_RESOURCE_PATCH_PAYLOAD_HASH_DOMAIN,
      "uvp:stage-resource-patch-payload:v1",
    );
    assert.equal(
      assignExecutorPatchHash,
      keccak256(
        encodeAbiParameters(
          [
            { name: "domain", type: "bytes32" },
            { name: "selectorStageId", type: "bytes32" },
            { name: "targetStageId", type: "bytes32" },
            { name: "executor", type: "address" },
            { name: "role", type: "bytes32" },
            { name: "executorMetadataHash", type: "bytes32" },
            { name: "mode", type: "bytes32" },
            { name: "previousExecutor", type: "address" },
            { name: "approvalSourceId", type: "bytes32" },
            { name: "approvalSignalId", type: "bytes32" },
            { name: "patchNonce", type: "uint256" },
            { name: "metadataURI", type: "string" },
          ],
          [
            keccak256(
              stringToHex(STAGE_EXECUTOR_PATCH_PAYLOAD_HASH_DOMAIN),
            ),
            selectorStageId,
            targetStageId,
            executor,
            role,
            executorMetadataHash,
            EXECUTOR_PATCH_MODE_ASSIGN,
            zeroAddress,
            zeroBytes32,
            zeroBytes32,
            BigInt(executorPatchNonce),
            metadataURI,
          ],
        ),
      ),
    );
    assert.equal(
      resourcePatchHash,
      keccak256(
        encodeAbiParameters(
          [
            { name: "domain", type: "bytes32" },
            { name: "selectorStageId", type: "bytes32" },
            { name: "targetStageId", type: "bytes32" },
            { name: "resourceKey", type: "bytes32" },
            { name: "manifestHash", type: "bytes32" },
            { name: "policyHash", type: "bytes32" },
            { name: "patchNonce", type: "uint256" },
            { name: "manifestURI", type: "string" },
          ],
          [
            keccak256(
              stringToHex(STAGE_RESOURCE_PATCH_PAYLOAD_HASH_DOMAIN),
            ),
            selectorStageId,
            targetStageId,
            resourceKey,
            manifestHash,
            policyHash,
            BigInt(resourcePatchNonce),
            manifestURI,
          ],
        ),
      ),
    );
    assert.equal(
      assignExecutorPatchHash,
      hashStageExecutorPatchPayload({
        targetStageId,
        selectorStageId,
        executor,
        role,
        executorMetadataHash,
        mode: "assign",
        previousExecutor: zeroAddress,
        approvalSourceId: zeroBytes32,
        approvalSignalId: zeroBytes32,
        patchNonce: BigInt(executorPatchNonce),
        metadataURI,
      }),
    );
    assert.equal(
      replacementExecutorPatchHash,
      hashStageExecutorPatchPayload({
        ...replacementExecutorPatchPayload,
        mode: "replacement",
        patchNonce: BigInt(replacementPatchNonce),
      }),
    );
    assert.notEqual(
      assignExecutorPatchHash,
      hashStageExecutorPatchPayload({
        ...assignExecutorPatchPayload,
        mode: EXECUTOR_PATCH_MODE_HANDOFF,
        metadataURI: "ipfs://stage-overlay/changed",
      }),
    );
    assert.equal(
      resourcePatchHash,
      hashStageResourcePatchPayload({
        targetStageId,
        selectorStageId,
        resourceKey,
        manifestHash,
        policyHash,
        patchNonce: BigInt(resourcePatchNonce),
        manifestURI,
      }),
    );
  });

  it("hashes ResourceManifestV1 canonically and rejects public URLs", () => {
    assert.equal(
      manifestHash,
      hashResourceManifest({
        createdAt: "2026-04-30T00:00:00.000Z",
        createdBy: submitter,
        recipientEnvelopeRoot,
        policyHash,
        storageCID: "ipfs://bafyresourceciphertext",
        ciphertextHash,
        visibility: "protected",
        resourceKey,
        targetStageId,
        orderId,
        schemaVersion: "uvp-resource-manifest-v1",
      }),
    );
    assert.throws(
      () =>
        hashResourceManifest({
          ...resourceManifest,
          storageCID: "https://files.example.com/plain.pdf",
        }),
      /not an HTTP URL/,
    );
    assert.throws(
      () =>
        hashResourceManifest({
          ...resourceManifest,
          contentHash,
          plaintext: "invoice bytes",
        } as ResourceManifestV1),
      /plaintext is not part of ResourceManifestV1/,
    );
  });

  // pinned 向量与 forge 测试 testTriggerOrderIdForMatchesPinnedMirrorVector
  // （UVPStateMachine.t.sol）同源：向量由 `cast keccak` 对
  // abi.encode(planId, sourceId, signalId, payloadHash) 生成后按合约
  // triggerOrderIdFor 同口径清除 dock 子单命名空间保留位（最高位）。
  // V3 的原始 digest 最高位为 1，专门钉住清位语义；两侧任一漂移即红。
  it("derives trigger order ids matching the pinned contract vectors", () => {
    // V1：小词输入。
    assert.equal(
      deriveTriggerOrderId(
        "0x0000000000000000000000000000000000000000000000000000000000000001",
        "0x0000000000000000000000000000000000000000000000000000000000000002",
        "0x0000000000000000000000000000000000000000000000000000000000000003",
        "0x0000000000000000000000000000000000000000000000000000000000000004",
      ),
      "0x392791df626408017a264f53fde61065d5a93a32b60171df9d8a46afdf82992d",
    );

    // V2：keccak 产物资（planId=keccak("plan")、sourceId=keccak("payment")、
    // signalId=keccak("payment.ready")、payloadHash=keccak("payload")）。
    assert.equal(
      deriveTriggerOrderId(
        "0x23ed4d6a785e89846f63d29858367b8fe694fb73179a0c2bc540e0687079c161",
        "0x1fab0c92eaead7da02fe29795732249e0861c98d6738709e6be992a170920770",
        "0x69a75a88c14fab0bfb411e1062f0e56850184f83a4737b3b14440b08947b43da",
        "0xebc84cbd75ba5516bf45e7024a9e12bc3c5c880f73e3a5beca7ebba52b2867a7",
      ),
      "0x5ea3f67d172d893746b323173444e0dff190f5a4d4d91db58776692ad483009a",
    );

    // V3：同 V2 前三参，payloadHash=keccak("payload-3")——原始 digest
    // 0xfadbfa9e…最高位为 1，清位后首字节 0xfa→0x7a。
    assert.equal(
      deriveTriggerOrderId(
        "0x23ed4d6a785e89846f63d29858367b8fe694fb73179a0c2bc540e0687079c161",
        "0x1fab0c92eaead7da02fe29795732249e0861c98d6738709e6be992a170920770",
        "0x69a75a88c14fab0bfb411e1062f0e56850184f83a4737b3b14440b08947b43da",
        "0x7ddb57e56bc008d7f232156ac0c4a9be3da0582cbda6ae545fb75e0b912ee6fa",
      ),
      "0x7adbfa9eb5e66f4bda59ce36fa07abdf9979eb14222e023ed9480d0adb8d2c0a",
    );

    // V4：全零边界。
    assert.equal(
      deriveTriggerOrderId(
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        "0x0000000000000000000000000000000000000000000000000000000000000000",
      ),
      "0x012893657d8eb2efad4de0a91bcd0e39ad9837745dec3ea923737ea803fc8e3d",
    );
  });

  it("rejects unsafe-range integers in canonical JSON (2^60, 1e21)", () => {
    // 2609100052 C-2 同型：|x| >= 2^53 已丢精度、>=1e21 输出指数形式——与
    // @uvp-eth/compiler canonical.ts 同口径响亮拒绝（大整数以 string/hex
    // word 携带）。
    assert.throws(
      () => canonicalJson({ n: 2 ** 60 }),
      /beyond the safe integer range 2\^53-1.*received 1152921504606847000/,
    );
    assert.throws(
      () => canonicalJson({ n: 1e21 }),
      /beyond the safe integer range 2\^53-1.*received 1e\+21/,
    );
    assert.equal(
      canonicalJson({ n: Number.MAX_SAFE_INTEGER }),
      `{"n":${Number.MAX_SAFE_INTEGER}}`,
    );
  });

  it("rejects zero sourceId at the trigger/authorization boundary (ZeroSourceId mirror)", () => {
    // L-4：合约 triggerOrderFromOutsideFor / _authorizeSignalSubmitter 对
    // sourceId==0 revert ZeroSourceId——签名摘要工具的可编码集不得大于
    // 合约接受集（可构造必败调用）。
    const signature = "0x" + "11".repeat(65);
    const config = {
      stateMachineAddress: "0x8888888888888888888888888888888888888888",
    };
    // 出生事实不主张属主：零 stageId + 空 proof 的空 attribution。
    const noBirthFactAttribution = {
      sourceId: zeroBytes32,
      signalId: zeroBytes32,
      stageId: zeroBytes32,
      capabilityProof: [],
    } as const;
    assert.throws(
      () =>
        buildTriggerOrderFromOutsideForCall(config, {
          planId,
          creator: executor,
          triggerHookId,
          triggerStageId,
          sourceId: zeroBytes32,
          signalId,
          payloadHash,
          idempotencyKey,
          submitter: executor,
          deadline,
          authorizations: [],
          signature,
          birthFactAttribution: noBirthFactAttribution,
        }),
      /sourceId must be non-zero/,
    );
    assert.throws(
      () =>
        buildTriggerOrderFromOutsideForCall(config, {
          planId,
          creator: executor,
          triggerHookId,
          triggerStageId,
          sourceId,
          signalId,
          payloadHash,
          idempotencyKey,
          submitter: executor,
          deadline,
          authorizations: [
            {
              sourceId: zeroBytes32,
              signalId,
              submitter: executor,
              role,
              metadataHash: payloadHash,
            },
          ],
          signature,
          birthFactAttribution: noBirthFactAttribution,
        }),
      /authorization\.sourceId must be non-zero/,
    );
    // 非零 sourceId 照常可编码（回归护栏）。
    assert.doesNotThrow(() =>
      buildTriggerOrderFromOutsideForCall(config, {
        planId,
        creator: executor,
        triggerHookId,
        triggerStageId,
        sourceId,
        signalId,
        payloadHash,
        idempotencyKey,
        submitter: executor,
        deadline,
        authorizations: [
          {
            sourceId,
            signalId,
            submitter: executor,
            role,
            metadataHash: payloadHash,
          },
        ],
        signature,
        birthFactAttribution: noBirthFactAttribution,
      }),
    );
  });
});


function bytes32(suffix: string): `0x${string}` {
  return `0x${suffix.padStart(64, "0")}`;
}

// 排序配对 Merkle 的独立折叠（keccak256(min ‖ max)），与包内造证工具
// 分开实现，用于 proof → root 的对拍。
function foldProof(leaf: `0x${string}`, proof: readonly `0x${string}`[]) {
  let current = leaf;
  for (const sibling of proof) {
    const [min, max] =
      current <= sibling ? [current, sibling] : [sibling, current];
    current = keccak256(concatHex([min, max]));
  }
  return current;
}

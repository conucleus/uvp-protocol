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
  parseAbiParameters,
  stringToHex,
  toEventHash,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  UnsupportedChainTargetError,
  unsupportedSolanaProtocolBinding,
} from "@uvp-eth/protocol-bindings/solana";
import {
  DERIVED_SIGNAL_MODULE_ABI,
  FILE_PATCH_HASH_DOMAIN,
  SIGNAL_SUBMISSION_PRIMARY_TYPE,
  SIGNAL_SUBMISSION_TYPED_DATA_FIELDS,
  STAGE_PATCH_MODULE_ABI,
  STAGE_SUPPLIER_PATCH_PAYLOAD_HASH_DOMAIN,
  STATE_MACHINE_ABI,
  buildApplyStageSupplierPatchForCall,
  buildDerivedSignalTypedData,
  buildPlanCommitTypedData,
  buildSignalSubmissionTypedData,
  buildStageSupplierPatchTypedData,
  buildSubmitDerivedSignalForCall,
  buildSubmitSignalCall,
  capabilitiesRootOf,
  EMPTY_CAPABILITIES_ROOT,
  factAttribution,
  factAttributionHash,
  filePatchHash,
  hashStageSupplierPatchPayload,
  selectorBindingLeaf,
  selectorBindingProofFor,
  signalCapabilityLeaf,
  recoverDerivedSignalSigner,
  recoverPlanCommitSigner,
  recoverSignalSubmissionSigner,
  recoverStageSupplierPatchSigner,
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
  readonly targetOrderRelation: 0;
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

function bytes32(value: string): `0x${string}` {
  return `0x${value.padStart(64, "0")}` as `0x${string}`;
}

function foldProof(
  leaf: `0x${string}`,
  proof: readonly `0x${string}`[],
): `0x${string}` {
  let current = leaf;
  for (const sibling of proof) {
    const [left, right] =
      current <= sibling ? [current, sibling] : [sibling, current];
    current = keccak256(concatHex([left, right]));
  }
  return current;
}

const privateKey =
  "0x1111111111111111111111111111111111111111111111111111111111111111" as const;
const account = privateKeyToAccount(privateKey);
const submitter = account.address.toLowerCase() as `0x${string}`;
const previousSupplierPrivateKey =
  "0x2222222222222222222222222222222222222222222222222222222222222222" as const;
const previousSupplierAccount = privateKeyToAccount(previousSupplierPrivateKey);
const previousSupplier =
  previousSupplierAccount.address.toLowerCase() as `0x${string}`;
const verifyingContract = "0x8888888888888888888888888888888888888888" as const;
const zeroAddress = "0x0000000000000000000000000000000000000000" as const;
const zeroBytes32 = bytes32("");
const orderId = bytes32("01");
const planId = bytes32("13");
const targetPlanId = bytes32("21");
const targetStageId = bytes32("07");
const patchHash = bytes32("0c");
const sourceId = bytes32("02");
const signalId = bytes32("03");
const payloadHash = bytes32("04");
const idempotencyKey = bytes32("05");
const selectorStageId = bytes32("06");
const supplierId = bytes32("08");
const previousSupplierId = bytes32("09");
const replacementSupplierId = bytes32("0a");
const deadline = "1777777777";
const supplierPatchNonce = "3";
const handoffPatchNonce = "4";
const replacementPatchNonce = "5";
const assignSupplierPatchPayload = {
  selectorStageId,
  targetStageId,
  supplierId,
  previousSupplierId: zeroBytes32,
  patchNonce: supplierPatchNonce,
} as const;
const assignSupplierPatchHash = hashStageSupplierPatchPayload(
  assignSupplierPatchPayload,
);
const handoffSupplierPatchPayload = {
  selectorStageId,
  targetStageId,
  supplierId,
  previousSupplierId,
  patchNonce: handoffPatchNonce,
} as const;
const handoffSupplierPatchHash = hashStageSupplierPatchPayload(
  handoffSupplierPatchPayload,
);
const handoffReplacementSupplierPatchPayload = {
  selectorStageId,
  targetStageId,
  supplierId: replacementSupplierId,
  previousSupplierId,
  patchNonce: replacementPatchNonce,
} as const;
const handoffReplacementSupplierPatchHash = hashStageSupplierPatchPayload(
  handoffReplacementSupplierPatchPayload,
);

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

  it("builds and recovers a PlanCommit publisher signature", async () => {
    const typedData = buildPlanCommitTypedData({
      chainId: 31337,
      verifyingContract,
      publisher: submitter,
      hooksHash: payloadHash,
      capabilitiesRoot: idempotencyKey,
      supplierBindingsRoot: idempotencyKey,
      deadline,
    });
    const signature = await account.signTypedData(
      typedData as unknown as Parameters<typeof account.signTypedData>[0],
    );

    assert.equal(typedData.primaryType, "UVPStateMachinePlanCommit");
    assert.deepEqual(typedData.domain, {
      name: "UVPStateMachine",
      version: "0.20",
      chainId: 31337,
      verifyingContract,
    });
    assert.deepEqual(
      typedData.types.UVPStateMachinePlanCommit.map((field) => field.name),
      [
        "publisher",
        "hooksHash",
        "capabilitiesRoot",
        "supplierBindingsRoot",
        "deadline",
      ],
    );
    assert.equal(
      await recoverPlanCommitSigner(typedData, signature),
      submitter,
    );
  });

  it("builds assign, handoff, and replacement stage supplier patch typed data", () => {
    const cases = [
      assignSupplierPatchPayload,
      handoffSupplierPatchPayload,
      handoffReplacementSupplierPatchPayload,
    ] as const;

    const [firstCase] = cases;
    assert.ok(firstCase);
    const firstTypedData = buildStageSupplierPatchTypedData({
      chainId: 31337,
      verifyingContract,
      planId,
      orderId,
      ...firstCase,
      selector: submitter,
      deadline,
    });

    assert.equal(firstTypedData.domain.version, "0.5");
    assert.deepEqual(
      firstTypedData.types.UVPStagePatchModuleStageSupplierPatch,
      [
        { name: "planId", type: "bytes32" },
        { name: "orderId", type: "bytes32" },
        { name: "selectorStageId", type: "bytes32" },
        { name: "targetStageId", type: "bytes32" },
        { name: "supplierId", type: "bytes32" },
        { name: "previousSupplierId", type: "bytes32" },
        { name: "patchNonce", type: "uint256" },
        { name: "selector", type: "address" },
        { name: "deadline", type: "uint256" },
      ],
    );
    assert.equal(
      firstTypedData.primaryType,
      "UVPStagePatchModuleStageSupplierPatch",
    );

    for (const payload of cases) {
      const typedData = buildStageSupplierPatchTypedData({
        chainId: 31337,
        verifyingContract,
        planId,
        orderId,
        ...payload,
        selector: submitter,
        deadline,
      });

      assert.equal(typedData.message.supplierId, payload.supplierId);
      assert.equal(
        typedData.message.previousSupplierId,
        payload.previousSupplierId,
      );
      assert.equal(typedData.message.patchNonce, payload.patchNonce);
      assert.equal("mode" in typedData.message, false);
      assert.equal("executor" in typedData.message, false);
      assert.equal("metadataURI" in typedData.message, false);
    }
  });

  it("recovers selector and previous supplier signers over the stage supplier patch typed data", async () => {
    const typedData = buildStageSupplierPatchTypedData({
      chainId: 31337,
      verifyingContract,
      planId,
      orderId,
      ...handoffReplacementSupplierPatchPayload,
      selector: submitter,
      deadline,
    });
    const selectorSignature = await account.signTypedData(
      typedData as unknown as Parameters<typeof account.signTypedData>[0],
    );
    const previousSupplierSignature =
      await previousSupplierAccount.signTypedData(
        typedData as unknown as Parameters<
          typeof previousSupplierAccount.signTypedData
        >[0],
      );

    assert.equal(
      await recoverStageSupplierPatchSigner(typedData, selectorSignature),
      submitter,
    );
    assert.equal(
      await recoverStageSupplierPatchSigner(
        typedData,
        previousSupplierSignature,
      ),
      previousSupplier,
    );
  });

  it("builds and recovers a SignalSubmission typed data whose digest matches the contract formula", async () => {
    const attribution = {
      sourceId,
      signalId,
      stageId: targetStageId,
      capabilityProof: [payloadHash],
    } as const;
    const typedData = buildSignalSubmissionTypedData({
      chainId: 31337,
      verifyingContract,
      planId,
      orderId,
      sourceId,
      signalId,
      payloadHash,
      idempotencyKey,
      patchHash,
      attribution,
      submitter,
      deadline,
    });

    assert.equal(typedData.primaryType, SIGNAL_SUBMISSION_PRIMARY_TYPE);
    assert.deepEqual(typedData.domain, {
      name: "UVPStateMachine",
      version: "0.20",
      chainId: 31337,
      verifyingContract,
    });
    assert.deepEqual(
      typedData.types.UVPStateMachineSignalSubmission.map((field) => field.name),
      ["planId", "orderId", "sourceId", "signalId", "payloadHash", "idempotencyKey", "patchHash", "attributionHash", "submitter", "deadline"],
    );
    assert.deepEqual(
      typedData.types.UVPStateMachineSignalSubmission,
      SIGNAL_SUBMISSION_TYPED_DATA_FIELDS,
    );
    assert.equal(typedData.message.attributionHash, factAttributionHash(attribution));
    assert.equal(typedData.message.patchHash, patchHash);

    // 与 UVPStateMachine._signalSubmissionDigest 的链上公式逐字段对拍：
    // typehash 字段名/顺序、attributionHash 的 FactAttribution typehash 与
    // capabilityProof 的 abi.encode 外层哈希、domain separator、struct hash。
    const factTypehash = keccak256(
      stringToHex(
        "FactAttribution(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof)",
      ),
    );
    const expectedAttributionHash = keccak256(
      encodeAbiParameters(
        [
          { type: "bytes32" },
          { type: "bytes32" },
          { type: "bytes32" },
          { type: "bytes32" },
          { type: "bytes32" },
        ],
        [
          factTypehash,
          attribution.sourceId,
          attribution.signalId,
          attribution.stageId,
          keccak256(
            encodeAbiParameters(
              [{ type: "bytes32[]" }],
              [attribution.capabilityProof],
            ),
          ),
        ],
      ),
    );
    assert.equal(typedData.message.attributionHash, expectedAttributionHash);

    const typehash = keccak256(
      stringToHex(
        "UVPStateMachineSignalSubmission(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 patchHash,bytes32 attributionHash,address submitter,uint256 deadline)",
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
          keccak256(
            stringToHex(
              "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
            ),
          ),
          keccak256(stringToHex("UVPStateMachine")),
          keccak256(stringToHex("0.20")),
          31337n,
          verifyingContract,
        ],
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
          { type: "bytes32" },
          { type: "bytes32" },
          { type: "bytes32" },
          { type: "bytes32" },
          { type: "address" },
          { type: "uint256" },
        ],
        [
          typehash,
          planId,
          orderId,
          sourceId,
          signalId,
          payloadHash,
          idempotencyKey,
          patchHash,
          expectedAttributionHash,
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

    const signature = await account.signTypedData({
      domain: typedData.domain,
      types: typedData.types,
      primaryType: typedData.primaryType,
      message: typedData.message,
    });
    assert.equal(
      await recoverSignalSubmissionSigner(typedData, signature),
      submitter,
    );
  });

  it("builds submitSignal calldata from the frozen struct, file patch, and patchHash", () => {
    const attribution = {
      sourceId,
      signalId,
      stageId: targetStageId,
      capabilityProof: [payloadHash],
    } as const;
    const fileKey = bytes32("0d");
    const fileContentHash = bytes32("0e");
    const filePatch = {
      targetStageId,
      baseHash: payloadHash,
      writerStageId: selectorStageId,
      writerProof: [idempotencyKey],
      ops: [
        {
          kind: 0 as const,
          key: fileKey,
          contentHash: fileContentHash,
          handle: "uvp://files/1",
        },
      ],
    } as const;
    const submissionPatchHash = filePatchHash(filePatch);
    assert.equal(
      submissionPatchHash,
      keccak256(
        encodeAbiParameters(
          parseAbiParameters(
            "bytes32,bytes32,bytes32,bytes32,bytes32[],(uint8,bytes32,bytes32,string)[]",
          ),
          [
            keccak256(stringToHex(FILE_PATCH_HASH_DOMAIN)),
            targetStageId,
            payloadHash,
            selectorStageId,
            [idempotencyKey],
            [[0, fileKey, fileContentHash, "uvp://files/1"]],
          ] as never,
        ),
      ),
    );

    const signature = `0x${"ab".repeat(65)}` as const;
    const call = buildSubmitSignalCall(
      { stateMachineAddress: verifyingContract, chainId: 31337 },
      {
        planId,
        orderId,
        sourceId,
        signalId,
        payloadHash,
        idempotencyKey,
        attribution,
        filePatch,
        patchHash: submissionPatchHash,
        submitter,
        deadline,
        signature,
      },
    );

    assert.equal(call.address, verifyingContract);
    assert.equal(call.chainId, 31337);
    assert.equal(call.functionName, "submitSignal");
    const [submission, callSignature] = call.args;
    assert.equal(submission.planId, planId);
    assert.equal(submission.orderId, orderId);
    assert.equal(submission.patchHash, submissionPatchHash);
    assert.equal(submission.filePatch.baseHash, payloadHash);
    assert.equal(submission.filePatch.ops[0]?.handle, "uvp://files/1");
    assert.equal(submission.attribution.stageId, targetStageId);
    assert.equal(callSignature, signature);

    const decoded = decodeFunctionData({
      abi: STATE_MACHINE_ABI,
      data: call.data,
    });
    assert.equal(decoded.functionName, "submitSignal");
    assert.ok(decoded.args);
    const decodedSubmission = decoded.args[0] as {
      readonly orderId: `0x${string}`;
      readonly patchHash: `0x${string}`;
      readonly filePatch: {
        readonly ops: readonly { readonly handle: string }[];
      };
    };
    assert.equal(decodedSubmission.orderId, orderId);
    assert.equal(decodedSubmission.patchHash, submissionPatchHash);
    assert.equal(decodedSubmission.filePatch.ops[0]?.handle, "uvp://files/1");
    assert.equal(decoded.args[1], signature);

    const triggerCall = buildSubmitSignalCall(
      { stateMachineAddress: verifyingContract },
      {
        planId,
        sourceId,
        signalId,
        payloadHash,
        idempotencyKey,
        attribution,
        patchHash: zeroBytes32,
        submitter,
        deadline,
      },
    );
    assert.equal(triggerCall.args[0].orderId, zeroBytes32);
    assert.equal(triggerCall.args[1], "0x");
  });

  it("matches the shared capabilities-root golden vectors consumed by compiler and Foundry", () => {
    // 同源消费 packages/compiler/fixtures/capabilities-root/v1/vectors.json
    // （compiler 权威实现生成，Foundry 侧 CapabilitiesRootParity.t.sol 消费
    // 同一份）：叶公式/建树/证明规则漂移时三份实现共享同一报警面，本包
    // 不自产硬编码根值。
    assert.equal(golden.schemaVersion, "uvp.capabilities-root.golden.v1");
    assert.equal(golden.samples.length, 5);
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

      // 每条能力输入：relation 恒为 current-order(0)，即事实属主自证材料
      // （stageId + proof 与 pinned 叶证明一致）。
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
        assert.ok(attribution, "current-order fact key must resolve to an owner");
        assert.equal(attribution.stageId, capability.stageId);
        assert.deepEqual(
          attribution.capabilityProof,
          expected.signalCapabilityLeaves[index]!.proof,
        );
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

  it("builds submitDerivedSignalFor calls from the derived signal module ABI", () => {
    const signature = `0x${"ab".repeat(65)}` as const;
    const proofs = {
      fromCapabilityProof: [payloadHash],
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
    assert.equal(typedData.domain.version, "0.7");
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
          keccak256(stringToHex("0.7")),
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

  it("builds applyStageSupplierPatchFor calls from the stage patch module ABI", () => {
    const selectorSignature = `0x${"bb".repeat(65)}` as const;
    const previousSupplierSignature = `0x${"dd".repeat(65)}` as const;
    const bindingProof = { selectorStageId, proof: [payloadHash] } as const;
    const candidateProof = [payloadHash, idempotencyKey] as const;
    const call = buildApplyStageSupplierPatchForCall(
      {
        stagePatchModuleAddress: verifyingContract,
        chainId: 31337,
      },
      {
        planId,
        orderId,
        patch: handoffReplacementSupplierPatchPayload,
        selector: submitter,
        deadline,
        selectorSignature,
        previousSupplierSignature,
        bindingProof,
        candidateProof,
      },
    );
    const decoded = decodeFunctionData({
      abi: STAGE_PATCH_MODULE_ABI,
      data: call.data,
    });

    assert.equal(call.address, verifyingContract);
    assert.equal(call.abi, STAGE_PATCH_MODULE_ABI);
    assert.equal(call.functionName, "applyStageSupplierPatchFor");
    assert.deepEqual(call.args, [
      planId,
      orderId,
      [
        selectorStageId,
        targetStageId,
        replacementSupplierId,
        previousSupplierId,
        BigInt(replacementPatchNonce),
      ],
      submitter,
      BigInt(deadline),
      selectorSignature,
      previousSupplierSignature,
      { selectorStageId, proof: [payloadHash] },
      candidateProof,
    ]);
    assert.equal(decoded.functionName, "applyStageSupplierPatchFor");
    assert.ok(decoded.args);
    const decodedArgs = decoded.args;
    assert.equal(decodedArgs[0], planId);
    assert.equal(decodedArgs[1], orderId);
    assert.deepEqual(decodedArgs[2], {
      selectorStageId,
      targetStageId,
      supplierId: replacementSupplierId,
      previousSupplierId,
      patchNonce: BigInt(replacementPatchNonce),
    });
    assert.equal(String(decodedArgs[3]).toLowerCase(), submitter);
    assert.equal(decodedArgs[4], BigInt(deadline));
    assert.equal(decodedArgs[5], selectorSignature);
    assert.equal(decodedArgs[6], previousSupplierSignature);
    assert.deepEqual(decodedArgs[7], { selectorStageId, proof: [payloadHash] });
    assert.deepEqual(decodedArgs[8], candidateProof);
  });

  it("hashes stage supplier patch payload canonically", () => {
    // payload 哈希必须吃进导出的域常量（域分离）——keccak256(abi
    // .encode(keccak256(domain), …payload))。独立重算而非同源引用。
    assert.equal(
      STAGE_SUPPLIER_PATCH_PAYLOAD_HASH_DOMAIN,
      "uvp:stage-supplier-patch-payload:v2",
    );
    assert.equal(
      assignSupplierPatchHash,
      keccak256(
        encodeAbiParameters(
          [
            { name: "domain", type: "bytes32" },
            { name: "selectorStageId", type: "bytes32" },
            { name: "targetStageId", type: "bytes32" },
            { name: "supplierId", type: "bytes32" },
            { name: "previousSupplierId", type: "bytes32" },
            { name: "patchNonce", type: "uint256" },
          ],
          [
            keccak256(
              stringToHex(STAGE_SUPPLIER_PATCH_PAYLOAD_HASH_DOMAIN),
            ),
            selectorStageId,
            targetStageId,
            supplierId,
            zeroBytes32,
            BigInt(supplierPatchNonce),
          ],
        ),
      ),
    );
    assert.equal(
      assignSupplierPatchHash,
      hashStageSupplierPatchPayload({
        selectorStageId,
        targetStageId,
        supplierId,
        previousSupplierId: zeroBytes32,
        patchNonce: BigInt(supplierPatchNonce),
      }),
    );
    assert.equal(
      handoffSupplierPatchHash,
      hashStageSupplierPatchPayload({
        ...handoffSupplierPatchPayload,
        patchNonce: BigInt(handoffPatchNonce),
      }),
    );
    assert.notEqual(
      assignSupplierPatchHash,
      hashStageSupplierPatchPayload({
        ...assignSupplierPatchPayload,
        previousSupplierId,
      }),
    );
  });
});

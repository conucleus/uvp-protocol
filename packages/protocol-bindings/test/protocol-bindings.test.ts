import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { decodeFunctionData } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { STATE_MACHINE_ABI as EVM_STATE_MACHINE_ABI } from '@uvp-eth/protocol-bindings/evm';
import {
  UnsupportedChainTargetError,
  unsupportedSolanaProtocolBinding,
  type SolanaInstructionPlanPlaceholder,
} from '@uvp-eth/protocol-bindings/solana';
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
  buildProductSubmitTypedData,
  buildStageExecutorPatchTypedData,
  buildStageResourcePatchTypedData,
  buildSubmitDerivedSignalForCall,
  buildSubmitSignalForCall,
  buildTriggerOrderFromSignalForCall,
  buildTriggerOrderFromSignalTypedData,
  canonicalJson,
  hashEvidenceJson,
  hashResourceManifest,
  hashStageExecutorPatchPayload,
  hashStageResourcePatchPayload,
  recoverProductSubmitSigner,
  recoverStageExecutorPatchSigner,
  recoverStageResourcePatchSigner,
  recoverTriggerOrderFromSignalSigner,
  type ResourceManifestV1,
} from '../src/index.js';

const privateKey = '0x1111111111111111111111111111111111111111111111111111111111111111' as const;
const account = privateKeyToAccount(privateKey);
const submitter = account.address.toLowerCase() as `0x${string}`;
const previousExecutorPrivateKey = '0x2222222222222222222222222222222222222222222222222222222222222222' as const;
const previousExecutorAccount = privateKeyToAccount(previousExecutorPrivateKey);
const previousExecutor = previousExecutorAccount.address.toLowerCase() as `0x${string}`;
const verifyingContract = '0x8888888888888888888888888888888888888888' as const;
const zeroAddress = '0x0000000000000000000000000000000000000000' as const;
const zeroBytes32 = bytes32('');
const orderId = bytes32('01');
const triggerOriginOrderId = bytes32('12');
const planId = bytes32('13');
const triggerHookId = bytes32('14');
const triggerStageId = bytes32('15');
const sourceId = bytes32('02');
const signalId = bytes32('03');
const payloadHash = bytes32('04');
const idempotencyKey = bytes32('05');
const selectorStageId = bytes32('06');
const targetStageId = bytes32('07');
const role = bytes32('08');
const executorMetadataHash = bytes32('09');
const policyHash = bytes32('0a');
const recipientEnvelopeRoot = bytes32('0b');
const ciphertextHash = bytes32('0c');
const resourceKey = bytes32('0d');
const contentHash = bytes32('0e');
const approvalSourceId = bytes32('0f');
const approvalSignalId = bytes32('10');
const originSourceId = bytes32('16');
const originSignalId = bytes32('17');
const deadline = '1777777777';
const executor = '0x7777777777777777777777777777777777777777' as const;
const metadataURI = 'ipfs://stage-overlay/executor-demo';
const handoffMetadataURI = 'ipfs://stage-overlay/executor-handoff';
const replacementMetadataURI = 'ipfs://stage-overlay/executor-replacement';
const manifestURI = 'ipfs://stage-overlay/resource-demo';
const executorPatchNonce = '3';
const handoffPatchNonce = '4';
const replacementPatchNonce = '5';
const resourcePatchNonce = '6';
const resourceManifest: ResourceManifestV1 = {
  schemaVersion: 'uvp-resource-manifest-v1',
  orderId,
  targetStageId,
  resourceKey,
  visibility: 'protected',
  ciphertextHash,
  storageCID: 'ipfs://bafyresourceciphertext',
  policyHash,
  recipientEnvelopeRoot,
  createdBy: submitter,
  createdAt: '2026-04-30T00:00:00.000Z',
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
const assignExecutorPatchHash = hashStageExecutorPatchPayload(assignExecutorPatchPayload);
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
const handoffExecutorPatchHash = hashStageExecutorPatchPayload(handoffExecutorPatchPayload);
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
const replacementExecutorPatchHash = hashStageExecutorPatchPayload(replacementExecutorPatchPayload);
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

describe('protocol bindings', () => {
  it('exposes explicit EVM and Solana binding boundaries', () => {
    assert.equal(EVM_STATE_MACHINE_ABI, STATE_MACHINE_ABI);
    const placeholder: SolanaInstructionPlanPlaceholder = {
      target: 'solana',
      programIds: {},
      TODO: 'solana protocol bindings are reserved but not implemented',
    };

    assert.equal(placeholder.target, 'solana');
    assert.throws(
      () => unsupportedSolanaProtocolBinding(),
      (error) =>
        error instanceof UnsupportedChainTargetError &&
        error.target === 'solana' &&
        /not implemented/.test(error.message),
    );
  });

  it('builds stable Product submit typed data', () => {
    const typedData = buildProductSubmitTypedData({
      chainId: 31337,
      verifyingContract,
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
        name: 'UVPStateMachine',
        version: '0.7',
        chainId: 31337,
        verifyingContract,
      },
      types: {
        UVPStateMachineSignal: [
          { name: 'orderId', type: 'bytes32' },
          { name: 'sourceId', type: 'bytes32' },
          { name: 'signalId', type: 'bytes32' },
          { name: 'payloadHash', type: 'bytes32' },
          { name: 'idempotencyKey', type: 'bytes32' },
          { name: 'submitter', type: 'address' },
          { name: 'deadline', type: 'uint256' },
        ],
      },
      primaryType: 'UVPStateMachineSignal',
      message: {
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

  it('recovers a Product submit signer', async () => {
    const typedData = buildProductSubmitTypedData({
      chainId: 31337,
      verifyingContract,
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

    assert.equal(await recoverProductSubmitSigner(typedData, signature), submitter);
  });

  it('builds and recovers trigger-origin order typed data', async () => {
    const typedData = buildTriggerOrderFromSignalTypedData({
      chainId: 31337,
      verifyingContract,
      orderId,
      planId,
      creator: submitter,
      triggerOriginOrderId,
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

    assert.deepEqual(typedData.types.UVPOrderLinkModuleTriggerOrderFromSignal.map((field) => field.name), [
      'orderId',
      'planId',
      'creator',
      'triggerOriginOrderId',
      'triggerHookId',
      'triggerStageId',
      'originSourceId',
      'originSignalId',
      'payloadHash',
      'idempotencyKey',
      'authorizationsHash',
      'submitter',
      'deadline',
    ]);
    assert.equal(typedData.message.triggerOriginOrderId, triggerOriginOrderId);
    assert.equal(await recoverTriggerOrderFromSignalSigner(typedData, signature), submitter);
  });

  it('builds assign, handoff, and replacement stage executor patch typed data', () => {
    const cases = [
      { payload: assignExecutorPatchPayload, patchHash: assignExecutorPatchHash },
      { payload: handoffExecutorPatchPayload, patchHash: handoffExecutorPatchHash },
      { payload: replacementExecutorPatchPayload, patchHash: replacementExecutorPatchHash },
    ] as const;

    const [firstCase] = cases;
    assert.ok(firstCase);
    const firstTypedData = buildStageExecutorPatchTypedData({
      chainId: 31337,
      verifyingContract,
      orderId,
      ...firstCase.payload,
      patchHash: firstCase.patchHash,
      selector: submitter,
      deadline,
    });

    assert.deepEqual(firstTypedData.types.UVPStagePatchModuleStageExecutorPatch, [
      { name: 'orderId', type: 'bytes32' },
      { name: 'selectorStageId', type: 'bytes32' },
      { name: 'targetStageId', type: 'bytes32' },
      { name: 'executor', type: 'address' },
      { name: 'role', type: 'bytes32' },
      { name: 'executorMetadataHash', type: 'bytes32' },
      { name: 'mode', type: 'bytes32' },
      { name: 'previousExecutor', type: 'address' },
      { name: 'approvalSourceId', type: 'bytes32' },
      { name: 'approvalSignalId', type: 'bytes32' },
      { name: 'patchHash', type: 'bytes32' },
      { name: 'patchNonce', type: 'uint256' },
      { name: 'metadataURI', type: 'string' },
      { name: 'selector', type: 'address' },
      { name: 'deadline', type: 'uint256' },
    ]);
    assert.equal(firstTypedData.primaryType, 'UVPStagePatchModuleStageExecutorPatch');

    for (const { payload, patchHash } of cases) {
      const typedData = buildStageExecutorPatchTypedData({
        chainId: 31337,
        verifyingContract,
        orderId,
        ...payload,
        patchHash,
        selector: submitter,
        deadline,
      });

      assert.equal(typedData.message.mode, payload.mode);
      assert.equal(typedData.message.previousExecutor, payload.previousExecutor);
      assert.equal(typedData.message.approvalSourceId, payload.approvalSourceId);
      assert.equal(typedData.message.approvalSignalId, payload.approvalSignalId);
      assert.equal(typedData.message.patchHash, patchHash);
      assert.equal(typedData.message.patchNonce, payload.patchNonce);
      assert.equal(typedData.message.metadataURI, payload.metadataURI);
      assert.equal('fileResourcesHash' in typedData.message, false);
    }
  });

  it('recovers selector and previous executor stage executor patch signers', async () => {
    const typedData = buildStageExecutorPatchTypedData({
      chainId: 31337,
      verifyingContract,
      orderId,
      ...handoffExecutorPatchPayload,
      patchHash: handoffExecutorPatchHash,
      selector: submitter,
      deadline,
    });
    const selectorSignature = await account.signTypedData(
      typedData as unknown as Parameters<typeof account.signTypedData>[0],
    );
    const previousExecutorSignature = await previousExecutorAccount.signTypedData(
      typedData as unknown as Parameters<typeof previousExecutorAccount.signTypedData>[0],
    );

    assert.equal(await recoverStageExecutorPatchSigner(typedData, selectorSignature), submitter);
    assert.equal(await recoverStageExecutorPatchSigner(typedData, previousExecutorSignature), previousExecutor);
  });

  it('builds and recovers stage resource patch typed data', async () => {
    const typedData = buildStageResourcePatchTypedData({
      chainId: 31337,
      verifyingContract,
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
      { name: 'orderId', type: 'bytes32' },
      { name: 'selectorStageId', type: 'bytes32' },
      { name: 'targetStageId', type: 'bytes32' },
      { name: 'resourceKey', type: 'bytes32' },
      { name: 'manifestHash', type: 'bytes32' },
      { name: 'policyHash', type: 'bytes32' },
      { name: 'patchHash', type: 'bytes32' },
      { name: 'patchNonce', type: 'uint256' },
      { name: 'manifestURI', type: 'string' },
      { name: 'selector', type: 'address' },
      { name: 'deadline', type: 'uint256' },
    ]);
    assert.equal(typedData.primaryType, 'UVPStagePatchModuleStageResourcePatch');
    assert.equal(typedData.message.patchNonce, resourcePatchNonce);
    assert.equal(typedData.message.manifestURI, manifestURI);
    assert.equal(await recoverStageResourcePatchSigner(typedData, signature), submitter);
  });

  it('builds submitSignalFor calls from the shared ABI', () => {
    const signature = `0x${'aa'.repeat(65)}` as const;
    const call = buildSubmitSignalForCall({
      stateMachineAddress: verifyingContract,
      chainId: 31337,
    }, {
      orderId,
      sourceId,
      signalId,
      payloadHash,
      idempotencyKey,
      submitter,
      deadline,
      signature,
    });

    assert.equal(call.address, verifyingContract);
    assert.equal(call.abi, STATE_MACHINE_ABI);
    assert.equal(call.functionName, 'submitSignalFor');
    assert.deepEqual(call.args, [
      orderId,
      sourceId,
      signalId,
      payloadHash,
      idempotencyKey,
      submitter,
      BigInt(deadline),
      signature,
    ]);
    assert.match(call.data, /^0x[0-9a-f]+$/);
  });

  it('builds triggerOrderFromSignalFor calls from the order-link module ABI', () => {
    const signature = `0x${'ac'.repeat(65)}` as const;
    const call = buildTriggerOrderFromSignalForCall({
      orderLinkModuleAddress: verifyingContract,
      chainId: 31337,
    }, {
      orderId,
      planId,
      creator: submitter,
      triggerOriginOrderId,
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
    });
    const decoded = decodeFunctionData({
      abi: ORDER_LINK_MODULE_ABI,
      data: call.data,
    });

    assert.equal(call.address, verifyingContract);
    assert.equal(call.abi, ORDER_LINK_MODULE_ABI);
    assert.equal(call.functionName, 'triggerOrderFromSignalFor');
    assert.equal(call.args[0].triggerOriginOrderId, triggerOriginOrderId);
    assert.equal(decoded.functionName, 'triggerOrderFromSignalFor');
    assert.equal(decoded.args[0].triggerOriginOrderId, triggerOriginOrderId);
    assert.equal(decoded.args[2], signature);
  });

  it('builds submitDerivedSignalFor calls from the derived signal module ABI', () => {
    const signature = `0x${'ab'.repeat(65)}` as const;
    const call = buildSubmitDerivedSignalForCall({
      derivedSignalModuleAddress: verifyingContract,
      chainId: 31337,
    }, {
      fromOrderId: orderId,
      fromStageId: targetStageId,
      targetOrderId: bytes32('11'),
      targetSourceId: sourceId,
      signalId,
      payloadHash,
      idempotencyKey,
      submitter,
      deadline,
      signature,
    });

    assert.equal(call.address, verifyingContract);
    assert.equal(call.abi, DERIVED_SIGNAL_MODULE_ABI);
    assert.equal(call.functionName, 'submitDerivedSignalFor');
    assert.deepEqual(call.args, [
      orderId,
      targetStageId,
      bytes32('11'),
      sourceId,
      signalId,
      payloadHash,
      idempotencyKey,
      submitter,
      BigInt(deadline),
      signature,
    ]);
    assert.match(call.data, /^0x[0-9a-f]+$/);
  });

  it('builds applyStageExecutorPatchFor calls from the stage patch module ABI', () => {
    const selectorSignature = `0x${'bb'.repeat(65)}` as const;
    const previousExecutorSignature = `0x${'dd'.repeat(65)}` as const;
    const call = buildApplyStageExecutorPatchForCall({
      stagePatchModuleAddress: verifyingContract,
      chainId: 31337,
    }, {
      orderId,
      patch: {
        ...replacementExecutorPatchPayload,
        patchHash: replacementExecutorPatchHash,
      },
      selector: submitter,
      deadline,
      selectorSignature,
      previousExecutorSignature,
    });
    const decoded = decodeFunctionData({
      abi: STAGE_PATCH_MODULE_ABI,
      data: call.data,
    });

    assert.equal(call.address, verifyingContract);
    assert.equal(call.abi, STAGE_PATCH_MODULE_ABI);
    assert.equal(call.functionName, 'applyStageExecutorPatchFor');
    assert.deepEqual(call.args, [
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
    ]);
    assert.equal(decoded.functionName, 'applyStageExecutorPatchFor');
    assert.ok(decoded.args);
    const decodedArgs = decoded.args;
    assert.equal(decodedArgs[0], orderId);
    assert.deepEqual(decodedArgs[1], {
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
    assert.equal(String(decodedArgs[2]).toLowerCase(), submitter);
    assert.equal(decodedArgs[3], BigInt(deadline));
    assert.equal(decodedArgs[4], selectorSignature);
    assert.equal(decodedArgs[5], previousExecutorSignature);
  });

  it('builds applyStageResourcePatchFor calls from the stage patch module ABI', () => {
    const signature = `0x${'cc'.repeat(65)}` as const;
    const call = buildApplyStageResourcePatchForCall({
      stagePatchModuleAddress: verifyingContract,
      chainId: 31337,
    }, {
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
    });
    const decoded = decodeFunctionData({
      abi: STAGE_PATCH_MODULE_ABI,
      data: call.data,
    });

    assert.equal(call.address, verifyingContract);
    assert.equal(call.abi, STAGE_PATCH_MODULE_ABI);
    assert.equal(call.functionName, 'applyStageResourcePatchFor');
    assert.deepEqual(call.args, [
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
    ]);
    assert.equal(decoded.functionName, 'applyStageResourcePatchFor');
    assert.ok(decoded.args);
    const decodedArgs = decoded.args;
    assert.equal(decodedArgs[0], orderId);
    assert.deepEqual(decodedArgs[1], {
      selectorStageId,
      targetStageId,
      resourceKey,
      manifestHash,
      policyHash,
      patchHash: resourcePatchHash,
      patchNonce: BigInt(resourcePatchNonce),
      manifestURI,
    });
    assert.equal(String(decodedArgs[2]).toLowerCase(), submitter);
    assert.equal(decodedArgs[3], BigInt(deadline));
    assert.equal(decodedArgs[4], signature);
  });

  it('hashes canonical JSON in a browser-safe helper', () => {
    assert.equal(canonicalJson({ b: 2, a: { d: 4, c: 3 } }), '{"a":{"c":3,"d":4},"b":2}');
    assert.equal(hashEvidenceJson({ b: 2, a: 1 }).evidenceHash, hashEvidenceJson({ a: 1, b: 2 }).evidenceHash);
  });

  it('hashes split patch payloads canonically', () => {
    assert.equal(
      EXECUTOR_PATCH_MODE_ASSIGN,
      '0x61737369676e0000000000000000000000000000000000000000000000000000',
    );
    assert.equal(
      EXECUTOR_PATCH_MODE_HANDOFF,
      '0x68616e646f666600000000000000000000000000000000000000000000000000',
    );
    assert.equal(
      EXECUTOR_PATCH_MODE_REPLACEMENT,
      '0x7265706c6163656d656e74000000000000000000000000000000000000000000',
    );
    assert.equal(
      assignExecutorPatchHash,
      hashStageExecutorPatchPayload({
        targetStageId,
        selectorStageId,
        executor,
        role,
        executorMetadataHash,
        mode: 'assign',
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
        mode: 'replacement',
        patchNonce: BigInt(replacementPatchNonce),
      }),
    );
    assert.notEqual(
      assignExecutorPatchHash,
      hashStageExecutorPatchPayload({
        ...assignExecutorPatchPayload,
        mode: EXECUTOR_PATCH_MODE_HANDOFF,
        metadataURI: 'ipfs://stage-overlay/changed',
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

  it('hashes ResourceManifestV1 canonically and rejects legacy resource handles', () => {
    assert.equal(
      manifestHash,
      hashResourceManifest({
        createdAt: '2026-04-30T00:00:00.000Z',
        createdBy: submitter,
        recipientEnvelopeRoot,
        policyHash,
        storageCID: 'ipfs://bafyresourceciphertext',
        ciphertextHash,
        visibility: 'protected',
        resourceKey,
        targetStageId,
        orderId,
        schemaVersion: 'uvp-resource-manifest-v1',
      }),
    );
    assert.throws(
      () => hashResourceManifest({
        schemaVersion: 'uvp-resource-manifest-v1',
        orderId,
        targetStageId,
        resourceKey,
        visibility: 'public',
        contentHash,
        storageCID: 'ipfs://bafypublicresource',
        policyHash,
        recipientEnvelopeRoot: bytes32('10'),
        createdBy: submitter,
        createdAt: '2026-04-30T00:00:00.000Z',
        fileType: 'http',
      } as ResourceManifestV1),
      /legacy file resource handle type "http"/,
    );
    assert.throws(
      () => hashResourceManifest({
        ...resourceManifest,
        storageCID: 'https://files.example.com/plain.pdf',
      }),
      /not an HTTP URL/,
    );
    assert.throws(
      () => hashResourceManifest({
        ...resourceManifest,
        contentHash,
        plaintext: 'invoice bytes',
      } as ResourceManifestV1),
      /must not contain plaintext resource data/,
    );
  });
});

function bytes32(suffix: string): `0x${string}` {
  return `0x${suffix.padStart(64, '0')}`;
}

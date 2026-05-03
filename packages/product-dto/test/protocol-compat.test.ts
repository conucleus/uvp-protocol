import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  demoFundingGuaranteeSignalContainers,
  demoPaymentTask,
  demoResourcePatchTask,
  demoSelectorTask,
  demoTask,
  phase2CustomsExecutorTask,
  phase2CustomsResourceControllerTask,
  phase2CustomsSelectorTask
} from "@uvp-eth/product-dto/fixtures";

type AbiItem = {
  readonly type?: string;
  readonly name?: string;
};

type ProtocolBindings = {
  readonly STATE_MACHINE_ABI: readonly AbiItem[];
  readonly PRODUCT_SUBMIT_DOMAIN_NAME: string;
  readonly PRODUCT_SUBMIT_DOMAIN_VERSION: string;
  readonly PRODUCT_SUBMIT_PRIMARY_TYPE: string;
  readonly PRODUCT_SUBMIT_TYPED_DATA_FIELDS: readonly ProtocolTypedDataField[];
  readonly STAGE_EXECUTOR_PATCH_DOMAIN_NAME: string;
  readonly STAGE_EXECUTOR_PATCH_DOMAIN_VERSION: string;
  readonly STAGE_EXECUTOR_PATCH_PRIMARY_TYPE: string;
  readonly STAGE_EXECUTOR_PATCH_TYPED_DATA_FIELDS: readonly ProtocolTypedDataField[];
  readonly STAGE_RESOURCE_PATCH_DOMAIN_NAME: string;
  readonly STAGE_RESOURCE_PATCH_DOMAIN_VERSION: string;
  readonly STAGE_RESOURCE_PATCH_PRIMARY_TYPE: string;
  readonly STAGE_RESOURCE_PATCH_TYPED_DATA_FIELDS: readonly ProtocolTypedDataField[];
};

type ProtocolTypedDataField = {
  readonly name: string;
  readonly type: string;
};

type ProductAction = {
  readonly actionKind: string;
  readonly inputBindings: Readonly<Record<string, string>>;
};

const submitSignalFieldNames = [
  "orderId",
  "sourceId",
  "signalId",
  "payloadHash",
  "idempotencyKey",
  "submitter",
  "deadline"
] as const;

const stageExecutorPatchFieldNames = [
  "orderId",
  "selectorStageId",
  "targetStageId",
  "executor",
  "role",
  "executorMetadataHash",
  "mode",
  "previousExecutor",
  "approvalSourceId",
  "approvalSignalId",
  "patchHash",
  "patchNonce",
  "metadataURI",
  "selector",
  "deadline"
] as const;

const stageResourcePatchFieldNames = [
  "orderId",
  "selectorStageId",
  "targetStageId",
  "resourceKey",
  "manifestHash",
  "policyHash",
  "patchHash",
  "patchNonce",
  "manifestURI",
  "selector",
  "deadline"
] as const;

describe("Product DTO protocol 0.2 compatibility", () => {
  it("maps submit_signal fixtures to the existing UVPStateMachine 0.2 submit action", async () => {
    const protocol = await loadProtocolBindings();

    assert.equal(protocol.PRODUCT_SUBMIT_DOMAIN_NAME, "UVPStateMachine");
    assert.equal(protocol.PRODUCT_SUBMIT_DOMAIN_VERSION, "0.2");
    assert.equal(protocol.PRODUCT_SUBMIT_PRIMARY_TYPE, "UVPStateMachineSignal");
    assert.deepEqual(fieldNames(protocol.PRODUCT_SUBMIT_TYPED_DATA_FIELDS), [...submitSignalFieldNames]);
    assertAbiNames(protocol.STATE_MACHINE_ABI, "function", ["submitSignal", "submitSignalFor"]);
    assertAbiNames(protocol.STATE_MACHINE_ABI, "event", ["SignalSubmitted"]);

    const submitActions = [
      demoTask.addOnManifest?.actions[0],
      demoPaymentTask.addOnManifest?.actions[0],
      phase2CustomsExecutorTask.addOnManifest?.actions[0]
    ];

    for (const action of submitActions) {
      assertSubmitSignalAction(action);
    }

    for (const container of demoFundingGuaranteeSignalContainers) {
      assert.equal(container.schemaVersion, "uvp.signal-container.v1");
      assert.equal(container.actionKind, "submit_signal");
      assert.equal(container.prepare.typedData.domainLabel, "UVPStateMachine 0.2");
      assert.equal(container.prepare.typedData.domainLabel, `${protocol.PRODUCT_SUBMIT_DOMAIN_NAME} ${protocol.PRODUCT_SUBMIT_DOMAIN_VERSION}`);
      assert.equal(productSubmitPrimaryType(container.prepare.typedData.primaryType), protocol.PRODUCT_SUBMIT_PRIMARY_TYPE);
      assert.equal(container.prepare.submitter, container.acceptedActor.wallet);
      assert.match(container.prepare.payloadHash, /^0x[0-9a-f]{64}$/);
      assert.match(container.prepare.idempotencyKey, /^funding:/);
      assert.equal(container.proof.eventName, "SignalSubmitted");
      assert.ok(container.proof.rows.some((row) => row.label === "链上事件" && row.value === "SignalSubmitted"));
    }
  });

  it("maps executor and resource patch fixtures to existing 0.2 patch actions", async () => {
    const protocol = await loadProtocolBindings();

    assert.equal(protocol.STAGE_EXECUTOR_PATCH_DOMAIN_NAME, protocol.PRODUCT_SUBMIT_DOMAIN_NAME);
    assert.equal(protocol.STAGE_EXECUTOR_PATCH_DOMAIN_VERSION, protocol.PRODUCT_SUBMIT_DOMAIN_VERSION);
    assert.equal(protocol.STAGE_EXECUTOR_PATCH_PRIMARY_TYPE, "UVPStateMachineStageExecutorPatch");
    assert.deepEqual(fieldNames(protocol.STAGE_EXECUTOR_PATCH_TYPED_DATA_FIELDS), [...stageExecutorPatchFieldNames]);
    assertAbiNames(protocol.STATE_MACHINE_ABI, "function", [
      "applyStageExecutorPatch",
      "applyStageExecutorPatchFor"
    ]);
    assertAbiNames(protocol.STATE_MACHINE_ABI, "event", [
      "StageExecutorPatchApplied",
      "StageExecutorActivated"
    ]);

    const executorPatchActions = [
      demoSelectorTask.addOnManifest?.actions[0],
      phase2CustomsSelectorTask.addOnManifest?.actions[0]
    ];
    for (const action of executorPatchActions) {
      assertProductAction(action, "stage_executor_patch", [
        "selectorWallet",
        "targetStageId",
        "mode",
        "executorWallet",
        "executorMetadataHash",
        "metadataURI"
      ]);
      assert.equal("sourceId" in action.inputBindings, false);
      assert.equal("signalId" in action.inputBindings, false);
      assert.equal("paymentContract" in action.inputBindings, false);
    }

    assert.equal(protocol.STAGE_RESOURCE_PATCH_DOMAIN_NAME, protocol.PRODUCT_SUBMIT_DOMAIN_NAME);
    assert.equal(protocol.STAGE_RESOURCE_PATCH_DOMAIN_VERSION, protocol.PRODUCT_SUBMIT_DOMAIN_VERSION);
    assert.equal(protocol.STAGE_RESOURCE_PATCH_PRIMARY_TYPE, "UVPStateMachineStageResourcePatch");
    assert.deepEqual(fieldNames(protocol.STAGE_RESOURCE_PATCH_TYPED_DATA_FIELDS), [...stageResourcePatchFieldNames]);
    assertAbiNames(protocol.STATE_MACHINE_ABI, "function", [
      "applyStageResourcePatch",
      "applyStageResourcePatchFor"
    ]);
    assertAbiNames(protocol.STATE_MACHINE_ABI, "event", ["StageResourcePatchApplied"]);

    const resourcePatchActions = [
      demoResourcePatchTask.addOnManifest?.actions[0],
      phase2CustomsResourceControllerTask.addOnManifest?.actions[0]
    ];
    for (const action of resourcePatchActions) {
      assertProductAction(action, "stage_resource_patch", [
        "selectorWallet",
        "targetStageId",
        "resourceKey",
        "manifestURI",
        "manifestHash",
        "policyHash"
      ]);
      assert.equal("writerWallet" in action.inputBindings, false);
      assert.equal("visibility" in action.inputBindings, false);
      assert.equal("paymentContract" in action.inputBindings, false);
    }
  });

  it("keeps funding guarantee containers on the submit-signal surface only", async () => {
    const protocol = await loadProtocolBindings();
    const protocolSurface = demoFundingGuaranteeSignalContainers.map((container) => ({
      scenarioId: container.scenarioId,
      actionKind: container.actionKind,
      functionName: "submitSignalFor",
      eventName: container.proof.eventName,
      typedDataPrimaryType: productSubmitPrimaryType(container.prepare.typedData.primaryType)
    }));

    assert.deepEqual(protocolSurface, [
      {
        scenarioId: "buyer-payment-evidence",
        actionKind: "submit_signal",
        functionName: "submitSignalFor",
        eventName: "SignalSubmitted",
        typedDataPrimaryType: protocol.PRODUCT_SUBMIT_PRIMARY_TYPE
      },
      {
        scenarioId: "guarantor-backing-proof",
        actionKind: "submit_signal",
        functionName: "submitSignalFor",
        eventName: "SignalSubmitted",
        typedDataPrimaryType: protocol.PRODUCT_SUBMIT_PRIMARY_TYPE
      },
      {
        scenarioId: "stablecoin-adapter-proof",
        actionKind: "submit_signal",
        functionName: "submitSignalFor",
        eventName: "SignalSubmitted",
        typedDataPrimaryType: protocol.PRODUCT_SUBMIT_PRIMARY_TYPE
      }
    ]);

    const protocolHints = protocolSurface
      .map((entry) => `${entry.functionName} ${entry.eventName} ${entry.typedDataPrimaryType}`)
      .join(" ");
    assert.doesNotMatch(protocolHints, /SignalContainer|Escrow|Custody|Settlement|PaymentProvider|Exchange/iu);
  });
});

async function loadProtocolBindings(): Promise<ProtocolBindings> {
  const protocolBindingsUrl = new URL("../../protocol-bindings/src/index.ts", import.meta.url);
  return import(protocolBindingsUrl.href) as Promise<ProtocolBindings>;
}

function assertSubmitSignalAction(action: ProductAction | undefined): asserts action is ProductAction {
  assertProductAction(action, "submit_signal", [
    "walletAddress",
    "evidenceIds",
    "confirmation"
  ]);
  assert.equal("paymentContract" in action.inputBindings, false);
}

function assertProductAction(
  action: ProductAction | undefined,
  expectedActionKind: string,
  requiredBindings: readonly string[]
): asserts action is ProductAction {
  assert.ok(action);
  assert.equal(action.actionKind, expectedActionKind);
  for (const binding of requiredBindings) {
    assert.equal(binding in action.inputBindings, true, `${expectedActionKind} must bind ${binding}`);
  }
}

function fieldNames(fields: readonly ProtocolTypedDataField[]): readonly string[] {
  return fields.map((field) => field.name);
}

function assertAbiNames(
  abi: readonly AbiItem[],
  itemType: "event" | "function",
  expectedNames: readonly string[]
): void {
  const actualNames = new Set(
    abi
      .filter((item) => item.type === itemType && typeof item.name === "string")
      .map((item) => item.name)
  );

  for (const expectedName of expectedNames) {
    assert.equal(actualNames.has(expectedName), true, `${itemType} ${expectedName} must stay in STATE_MACHINE_ABI`);
  }
}

function productSubmitPrimaryType(primaryType: "SubmitSignal"): "UVPStateMachineSignal" {
  assert.equal(primaryType, "SubmitSignal");
  return "UVPStateMachineSignal";
}

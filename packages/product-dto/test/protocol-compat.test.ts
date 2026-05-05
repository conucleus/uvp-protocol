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
  phase2CustomsSelectorTask,
  phase2CustomsStoreProductSchema
} from "@uvp-eth/product-dto/fixtures";
import type { StoreProductSchemaDTO } from "@uvp-eth/product-dto";

type AbiItem = {
  readonly type?: string;
  readonly name?: string;
};

type ProtocolBindings = {
  readonly STATE_MACHINE_ABI: readonly AbiItem[];
  readonly STAGE_PATCH_MODULE_ABI: readonly AbiItem[];
  readonly DOCKING_MODULE_ABI: readonly AbiItem[];
  readonly STATE_MACHINE_LENS_ABI: readonly AbiItem[];
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
  readonly DOCKED_ORDER_LINK_DOMAIN_NAME: string;
  readonly DOCKED_ORDER_LINK_DOMAIN_VERSION: string;
  readonly DOCKED_ORDER_LINK_PRIMARY_TYPE: string;
  readonly DOCKED_ORDER_LINK_TYPED_DATA_FIELDS: readonly ProtocolTypedDataField[];
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

const dockedOrderLinkFieldNames = [
  "localOrderId",
  "selectorStageId",
  "localSourceId",
  "linkedOrderId",
  "linkedPlanId",
  "linkHash",
  "linkNonce",
  "signalBindingsHash",
  "metadataURI",
  "selector",
  "deadline"
] as const;

describe("Product DTO protocol 0.7 compatibility", () => {
  it("maps submit_signal fixtures to the existing UVPStateMachine 0.7 submit action", async () => {
    const protocol = await loadProtocolBindings();

    assert.equal(protocol.PRODUCT_SUBMIT_DOMAIN_NAME, "UVPStateMachine");
    assert.equal(protocol.PRODUCT_SUBMIT_DOMAIN_VERSION, "0.7");
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
      assert.equal(container.prepare.typedData.domainLabel, "UVPStateMachine 0.7");
      assert.equal(container.prepare.typedData.domainLabel, `${protocol.PRODUCT_SUBMIT_DOMAIN_NAME} ${protocol.PRODUCT_SUBMIT_DOMAIN_VERSION}`);
      assert.equal(productSubmitPrimaryType(container.prepare.typedData.primaryType), protocol.PRODUCT_SUBMIT_PRIMARY_TYPE);
      assert.equal(container.prepare.submitter, container.acceptedActor.wallet);
      assert.match(container.prepare.payloadHash, /^0x[0-9a-f]{64}$/);
      assert.match(container.prepare.idempotencyKey, /^funding:/);
      assert.equal(container.proof.eventName, "SignalSubmitted");
      assert.ok(container.proof.rows.some((row) => row.label === "链上事件" && row.value === "SignalSubmitted"));
    }
  });

  it("maps executor and resource patch fixtures to the stage patch module", async () => {
    const protocol = await loadProtocolBindings();

    assert.equal(protocol.STAGE_EXECUTOR_PATCH_DOMAIN_NAME, "UVPStagePatchModule");
    assert.equal(protocol.STAGE_EXECUTOR_PATCH_DOMAIN_VERSION, "0.1");
    assert.equal(protocol.STAGE_EXECUTOR_PATCH_PRIMARY_TYPE, "UVPStagePatchModuleStageExecutorPatch");
    assert.deepEqual(fieldNames(protocol.STAGE_EXECUTOR_PATCH_TYPED_DATA_FIELDS), [...stageExecutorPatchFieldNames]);
    assertAbiNames(protocol.STAGE_PATCH_MODULE_ABI, "function", [
      "applyStageExecutorPatchFor"
    ]);
    assertAbiNames(protocol.STAGE_PATCH_MODULE_ABI, "event", [
      "StageExecutorPatchApplied",
    ]);
    assertAbiNames(protocol.STATE_MACHINE_ABI, "event", ["StageExecutorActivated"]);

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

    assert.equal(protocol.STAGE_RESOURCE_PATCH_DOMAIN_NAME, "UVPStagePatchModule");
    assert.equal(protocol.STAGE_RESOURCE_PATCH_DOMAIN_VERSION, "0.1");
    assert.equal(protocol.STAGE_RESOURCE_PATCH_PRIMARY_TYPE, "UVPStagePatchModuleStageResourcePatch");
    assert.deepEqual(fieldNames(protocol.STAGE_RESOURCE_PATCH_TYPED_DATA_FIELDS), [...stageResourcePatchFieldNames]);
    assertAbiNames(protocol.STAGE_PATCH_MODULE_ABI, "function", [
      "applyStageResourcePatchFor"
    ]);
    assertAbiNames(protocol.STAGE_PATCH_MODULE_ABI, "event", ["StageResourcePatchApplied"]);

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

  it("keeps docked order link on the docking module surface", async () => {
    const protocol = await loadProtocolBindings();

    assert.equal(protocol.DOCKED_ORDER_LINK_DOMAIN_NAME, "UVPDockingModule");
    assert.equal(protocol.DOCKED_ORDER_LINK_DOMAIN_VERSION, "0.1");
    assert.equal(protocol.DOCKED_ORDER_LINK_PRIMARY_TYPE, "UVPDockingModuleDockedOrderLink");
    assert.deepEqual(fieldNames(protocol.DOCKED_ORDER_LINK_TYPED_DATA_FIELDS), [...dockedOrderLinkFieldNames]);
    assertAbiNames(protocol.DOCKING_MODULE_ABI, "function", ["linkDockedOrderFor", "submitDockedSignal"]);
    assertAbiNames(protocol.DOCKING_MODULE_ABI, "event", [
      "DockedOrderLinked",
      "DockedSignalMapped",
      "DockedSignalSubmitted"
    ]);
    assertAbiNames(protocol.STATE_MACHINE_LENS_ABI, "function", [
      "getActiveStageExecutorPatch",
      "getActiveStageResourcePatch",
      "getActiveDockedOrderLink",
      "getActiveDockedSignalBinding"
    ]);
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

  it("fails Product signal map gate when schema source, signal, action or permission rows drift", async () => {
    const gate = await loadProductSignalMapGate();

    assert.deepEqual(gate.verifyPhase2ProductSignalMap().failures, []);

    assert.match(
      gate.verifyPhase2ProductSignalMap({
        schema: {
          ...phase2CustomsStoreProductSchema,
          createOrderTrigger: {
            ...phase2CustomsStoreProductSchema.createOrderTrigger!,
            source: "order-wrong"
          }
        }
      }).failures.join("\n"),
      /schema\.createOrderTrigger/
    );

    assert.match(
      gate.verifyPhase2ProductSignalMap({
        schema: {
          ...phase2CustomsStoreProductSchema,
          createOrderTrigger: {
            ...phase2CustomsStoreProductSchema.createOrderTrigger!,
            signalName: "wrong.registered"
          }
        }
      }).failures.join("\n"),
      /schema\.createOrderTrigger/
    );

    assert.match(
      gate.verifyPhase2ProductSignalMap({
        schema: {
          ...phase2CustomsStoreProductSchema,
          orderPermissionTable: phase2CustomsStoreProductSchema.orderPermissionTable.filter((entry) =>
            entry.permissionId !== "phase2.customs.executor-signal"
          )
        }
      }).failures.join("\n"),
      /submit_signal has no Product permission row/
    );

    assert.match(
      gate.verifyPhase2ProductSignalMap({
        schema: {
          ...phase2CustomsStoreProductSchema,
          selectorBindings: (phase2CustomsStoreProductSchema.selectorBindings ?? []).filter((binding) =>
            binding.selectorStageIdentifier !== "buyer.select-customs-executor"
          )
        }
      }).failures.join("\n"),
      /selector binding missing/
    );
  });
});

async function loadProtocolBindings(): Promise<ProtocolBindings> {
  const protocolBindingsUrl = new URL("../../protocol-bindings/src/index.ts", import.meta.url);
  return import(protocolBindingsUrl.href) as Promise<ProtocolBindings>;
}

type ProductSignalMapGate = {
  readonly verifyPhase2ProductSignalMap: (overrides?: { readonly schema?: StoreProductSchemaDTO }) => { readonly failures: readonly string[] };
};

async function loadProductSignalMapGate(): Promise<ProductSignalMapGate> {
  const gateUrl = new URL("../../../../uvp-deploy/deploy/scripts/verify-product-signal-map.ts", import.meta.url);
  return import(gateUrl.href) as Promise<ProductSignalMapGate>;
}

function withPermission(
  permissionId: string,
  patch: Partial<StoreProductSchemaDTO["orderPermissionTable"][number]>
): StoreProductSchemaDTO {
  return {
    ...phase2CustomsStoreProductSchema,
    orderPermissionTable: phase2CustomsStoreProductSchema.orderPermissionTable.map((entry) =>
      entry.permissionId === permissionId ? { ...entry, ...patch } : entry
    )
  };
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

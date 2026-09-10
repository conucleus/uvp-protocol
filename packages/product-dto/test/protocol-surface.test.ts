import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  demoFundingGuaranteeSignalContainers,
  demoPaymentTask,
  demoResourcePatchTask,
  demoSelectorTask,
  demoTask,
  customsExecutorTask,
  customsResourceControllerTask,
  customsSelectorTask,
  customsStoreProductSchema
} from "@uvp-eth/product-dto/fixtures";
import type { StoreProductSchemaDTO } from "@uvp-eth/product-dto";

type AbiItem = {
  readonly type?: string;
  readonly name?: string;
  readonly inputs?: readonly {
    readonly name?: string;
    readonly type: string;
    readonly components?: readonly { readonly name?: string; readonly type: string }[];
  }[];
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
  "planId",
  "orderId",
  "sourceId",
  "signalId",
  "payloadHash",
  "idempotencyKey",
  "submitter",
  "deadline"
] as const;

const stageExecutorPatchFieldNames = [
  "planId",
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
  "planId",
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

describe("Product DTO protocol surface", () => {
  it("maps submit_signal fixtures to the current UVPStateMachine 0.10 submit action", async () => {
    const protocol = await loadProtocolBindings();

    assert.equal(protocol.PRODUCT_SUBMIT_DOMAIN_NAME, "UVPStateMachine");
    assert.equal(protocol.PRODUCT_SUBMIT_DOMAIN_VERSION, "0.10");
    assert.equal(protocol.PRODUCT_SUBMIT_PRIMARY_TYPE, "UVPStateMachineSignal");
    assert.deepEqual(fieldNames(protocol.PRODUCT_SUBMIT_TYPED_DATA_FIELDS), [...submitSignalFieldNames]);
    assertAbiNames(protocol.STATE_MACHINE_ABI, "function", ["submitSignal", "submitSignalFor"]);
    assertAbiNames(protocol.STATE_MACHINE_ABI, "event", ["SignalSubmitted"]);

    const submitActions = [
      demoTask.addOnManifest?.actions[0],
      demoPaymentTask.addOnManifest?.actions[0],
      customsExecutorTask.addOnManifest?.actions[0]
    ];

    for (const action of submitActions) {
      assertSubmitSignalAction(action);
    }

    for (const container of demoFundingGuaranteeSignalContainers) {
      assert.equal(container.schemaVersion, "uvp.signal-container.v1");
      assert.equal(container.actionKind, "submit_signal");
      assert.equal(container.prepare.typedData.stateMachineLabel, "UVPStateMachine 0.10");
      assert.equal(container.prepare.typedData.stateMachineLabel, `${protocol.PRODUCT_SUBMIT_DOMAIN_NAME} ${protocol.PRODUCT_SUBMIT_DOMAIN_VERSION}`);
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
      customsSelectorTask.addOnManifest?.actions[0]
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
      customsResourceControllerTask.addOnManifest?.actions[0]
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

  it("keeps the committed-route docking surface", async () => {
    const protocol = await loadProtocolBindings();

    // 全部 dock 走 committed route：openDockedOrder 原子 open；终态不由
    // 链上事件驱动，事件面闭集不含 terminal 类事件。
    assertAbiNames(protocol.DOCKING_MODULE_ABI, "function", [
      "openDockedOrder",
      "submitDockedInput",
      "submitDockedSignal",
      "getActiveDock",
      "getDockInputBinding",
      "getDockOutputBinding",
      "entrancePermitDigest"
    ]);
    assertAbiEventNames(protocol.DOCKING_MODULE_ABI, [
      "DockOpened",
      "DockInputSubmitted",
      "DockOutputSubmitted"
    ]);
    const dockOpened = protocol.DOCKING_MODULE_ABI.find(
      (item) => item.type === "event" && item.name === "DockOpened"
    );
    assert.ok(dockOpened?.inputs?.some((input) => input.name === "interfaceNameId"),
      "DockOpened must carry interfaceNameId (named-interface dock, abiVersion 4.0)");
    // v4.0：output 绑定自带端口叶 word + membership 证明（调用方不得自报叶值）。
    const openDockedOrder = protocol.DOCKING_MODULE_ABI.find(
      (item) => item.type === "function" && item.name === "openDockedOrder"
    );
    const outputsTuple = openDockedOrder?.inputs?.find((input) => input.name === "outputs");
    const outputComponentNames = (outputsTuple?.components ?? []).map((component) => component.name);
    assert.deepEqual(outputComponentNames, [
      "localSourceId",
      "localSignalId",
      "portKey",
      "targetSourceId",
      "targetSignalId",
      "bindingHash",
      "portProof"
    ]);
    assertAbiNames(protocol.STATE_MACHINE_LENS_ABI, "function", [
      "getActiveStageExecutorPatch",
      "getActiveStageResourcePatch",
      "getActiveDock",
      "getDockInputBinding",
      "getDockOutputBinding"
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

    // uvp-deploy 的 verify-product-signal-map 门禁断言 typed-data 字段清单
    // （planId / localPlanId）全量生效。
    assert.deepEqual(gate.verifyCustomsProductSignalMap().failures, []);

    assert.match(
      gate.verifyCustomsProductSignalMap({
        schema: {
          ...customsStoreProductSchema,
          createOrderTrigger: {
            ...customsStoreProductSchema.createOrderTrigger!,
            source: "order-wrong"
          }
        }
      }).failures.join("\n"),
      /schema\.createOrderTrigger/
    );

    assert.match(
      gate.verifyCustomsProductSignalMap({
        schema: {
          ...customsStoreProductSchema,
          createOrderTrigger: {
            ...customsStoreProductSchema.createOrderTrigger!,
            signalName: "wrong.registered"
          }
        }
      }).failures.join("\n"),
      /schema\.createOrderTrigger/
    );

    assert.match(
      gate.verifyCustomsProductSignalMap({
        schema: {
          ...customsStoreProductSchema,
          orderPermissionTable: customsStoreProductSchema.orderPermissionTable.filter((entry) =>
            entry.permissionId !== "customs.executor-signal"
          )
        }
      }).failures.join("\n"),
      /submit_signal has no Product permission row/
    );

    assert.match(
      gate.verifyCustomsProductSignalMap({
        schema: {
          ...customsStoreProductSchema,
          selectorBindings: (customsStoreProductSchema.selectorBindings ?? []).filter((binding) =>
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
  readonly verifyCustomsProductSignalMap: (overrides?: { readonly schema?: StoreProductSchemaDTO }) => { readonly failures: readonly string[] };
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
    ...customsStoreProductSchema,
    orderPermissionTable: customsStoreProductSchema.orderPermissionTable.map((entry) =>
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

/** 事件名闭集断言：多余/缺失事件都视为协议面漂移。 */
function assertAbiEventNames(
  abi: readonly AbiItem[],
  expectedNames: readonly string[]
): void {
  const actualNames = abi
    .filter((item) => item.type === "event" && typeof item.name === "string")
    .map((item) => item.name)
    .sort();
  assert.deepEqual(actualNames, [...expectedNames].sort());
}

function productSubmitPrimaryType(primaryType: "SubmitSignal"): "UVPStateMachineSignal" {
  assert.equal(primaryType, "SubmitSignal");
  return "UVPStateMachineSignal";
}

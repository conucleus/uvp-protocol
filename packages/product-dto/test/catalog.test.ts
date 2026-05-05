import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  STORE_SUPPLIER_CAPABILITY_TAGS,
  type ParticipantAddOnManifestDTO,
  type ParticipantAddOnKind,
  type ProductExecutorPatchMode,
  type ProductExecutorPatchRequirementDTO,
  type ProductExecutorOverlayDTO,
  type ProductOrderDTO,
  type ProductResourceAccessPolicyDTO,
  type ProductResourceManifestDTO,
  type ProductResourceOverlayDTO,
  type ProductResourceRequirementDTO,
  type ProductTaskDTO,
  summarizeZhixu,
  toStoreZhixuConsoleDTO,
  toStoreZhixuDetailDTO,
  storeConsoleSummary
} from "@uvp-eth/product-dto";
import {
  demoFundingGuaranteeSignalContainers,
  demoPaymentTask,
  demoProductCatalog,
  demoResourcePatchTask,
  demoSelectorTask,
  demoTask,
  phase2CustomsInitialTriggerSource,
  phase2CustomsProductCatalog,
  phase2CustomsResourceManifest,
  phase2CustomsRoleSlotIds,
  phase2CustomsSignalIds,
  phase2CustomsStageIds,
  phase2CustomsStoreProductSchema
} from "@uvp-eth/product-dto/fixtures";

describe("product DTO catalog", () => {
  it("keeps package root free of demo fixture exports", async () => {
    const rootExports = await import("@uvp-eth/product-dto");
    const fixtureNames = [
      "DEMO_ORDER_ID",
      "DEMO_TASK_ID",
      "CROSS_BORDER_ZHIXU_ID",
      "crossBorderPlanIds",
      "demoOrder",
      "demoOrderPermissionTable",
      "demoParticipants",
      "demoPaymentTask",
      "demoFundingGuaranteeSignalContainers",
      "demoResourcePatchTask",
      "demoProductCatalog",
      "demoSelectorTask",
      "demoStages",
      "demoTask",
      "demoZhixuDetail"
    ];

    for (const fixtureName of fixtureNames) {
      assert.equal(fixtureName in rootExports, false, `${fixtureName} must stay behind /fixtures`);
    }
  });

  it("exposes demo catalog from the explicit fixture subpath", async () => {
    const fixtures = await import("@uvp-eth/product-dto/fixtures");
    assert.equal(fixtures.demoProductCatalog.zhixus[0]?.zhixuId, demoProductCatalog.zhixus[0]?.zhixuId);
    assert.equal(fixtures.demoTask.taskId, demoTask.taskId);
  });

  it("keeps zhixu DTOs serializable and summary-safe", () => {
    const zhixu = demoProductCatalog.zhixus[0];
    assert.ok(zhixu);

    const serialized = JSON.stringify(zhixu);
    assert.doesNotThrow(() => JSON.parse(serialized));
    assert.equal(zhixu.roleSlots.length, zhixu.roleSlotCount);

    const summary = summarizeZhixu(zhixu);
    assert.equal(summary.zhixuId, zhixu.zhixuId);
    assert.equal("roleSlots" in summary, false);
    assert.equal("dockableModules" in summary, false);
    assert.equal("stages" in summary, false);
  });

  it("carries explicit performance slot capability metadata", () => {
    const zhixu = demoProductCatalog.zhixus[0];
    assert.ok(zhixu);

    assert.ok(zhixu.roleSlots.every((slot) => (slot.capabilityPlugins?.length ?? 0) > 0));
    assert.ok(zhixu.roleSlots.every((slot) => slot.capabilityPlugins?.every((plugin) => plugin.source === "explicit")));
    assert.ok(zhixu.roleSlots.every((slot) => slot.addOnManifest?.schemaVersion === "participant-addon-manifest.v1"));

    const deliverySlot = zhixu.roleSlots.find((slot) => slot.slotId === "delivery");
    assert.ok(deliverySlot);
    assert.equal(deliverySlot.performanceSlotLabel, "交付履约者");
    assert.deepEqual(deliverySlot.businessPersonaLabels, ["报关行", "物流/货代"]);
    assert.ok(deliverySlot.capabilityPlugins?.some((plugin) =>
      plugin.pluginKind === "delivery_update" && plugin.stageIds.includes("customs-complete")
    ));

    const serialized = JSON.stringify(deliverySlot);
    const parsed = JSON.parse(serialized);
    assert.equal(parsed.slotId, "delivery");
    assert.equal(parsed.capabilityPlugins[0].source, "explicit");
    assert.equal(parsed.addOnManifest.addOnKind, "submit_signal");
  });

  it("models role-slot add-on manifests as declarative page and action contracts", () => {
    const deliverySlot = demoProductCatalog.zhixus[0]?.roleSlots.find((slot) => slot.slotId === "delivery");
    assert.ok(deliverySlot?.addOnManifest);
    const manifest: ParticipantAddOnManifestDTO = deliverySlot.addOnManifest;

    assert.equal(manifest.schemaVersion, "participant-addon-manifest.v1");
    assert.equal(manifest.roleSlotId, deliverySlot.slotId);
    assert.equal(manifest.addOnKind, "submit_signal");
    assert.ok(manifest.stageBindings.includes("customs-complete"));
    assert.ok(manifest.pages.some((page) =>
      page.sections.some((section) =>
        section.components.some((component) => component.componentKind === "evidence_refs" && component.inputId)
      )
    ));
    assert.deepEqual(manifest.actions.map((action) => action.actionKind), ["submit_signal"]);
    assert.equal(manifest.actions[0]?.inputBindings.walletAddress, "delivery.wallet");
    assert.equal(manifest.actions[0]?.inputBindings.confirmation, "delivery.confirmation");
    assert.equal(demoSelectorTask.addOnManifest?.actions[0]?.actionKind, "stage_executor_patch");
    assert.equal(demoSelectorTask.addOnManifest?.actions[0]?.inputBindings.executorMetadataHash, "selector.executorMetadataHash");
    assert.equal(demoResourcePatchTask.addOnManifest?.actions[0]?.actionKind, "stage_resource_patch");
    assert.equal(demoResourcePatchTask.addOnManifest?.actions[0]?.inputBindings.selectorWallet, "resourcePatch.selectorWallet");
    assert.equal("writerWallet" in (demoResourcePatchTask.addOnManifest?.actions[0]?.inputBindings ?? {}), false);
  });

  it("exports the Phase 2 customs scenario fixture with role-slot manifests", () => {
    const zhixu = phase2CustomsProductCatalog.zhixus[0];
    assert.ok(zhixu);
    assert.deepEqual(zhixu.stages.map((stage) => stage.stageId), [
      phase2CustomsStageIds.buyerSelectCustomsExecutor,
      phase2CustomsStageIds.buyerPublishCustomsResources,
      phase2CustomsStageIds.customsComplete
    ]);
    assert.equal(phase2CustomsStoreProductSchema.validation.ok, true);
    assert.equal(phase2CustomsStoreProductSchema.selectorBindings?.length, 2);

    const executorPatchSlot = zhixu.roleSlots.find((slot) => slot.slotId === phase2CustomsRoleSlotIds.buyerSelector);
    const resourcePatchSlot = zhixu.roleSlots.find((slot) => slot.slotId === phase2CustomsRoleSlotIds.buyerResourceController);
    const signalSubmitSlot = zhixu.roleSlots.find((slot) => slot.slotId === phase2CustomsRoleSlotIds.customsExecutor);
    assert.equal(executorPatchSlot?.addOnManifest?.actions[0]?.actionKind, "stage_executor_patch");
    assert.equal(executorPatchSlot?.addOnManifest?.actions[0]?.inputBindings.executorMetadataHash, "buyerSelector.executorMetadataHash");
    assert.equal(resourcePatchSlot?.addOnManifest?.actions[0]?.actionKind, "stage_resource_patch");
    assert.equal(resourcePatchSlot?.addOnManifest?.actions[0]?.inputBindings.selectorWallet, "buyerResourceController.selectorWallet");
    assert.equal("writerWallet" in (resourcePatchSlot?.addOnManifest?.actions[0]?.inputBindings ?? {}), false);
    assert.equal("visibility" in (resourcePatchSlot?.addOnManifest?.actions[0]?.inputBindings ?? {}), false);
    assert.equal(signalSubmitSlot?.addOnManifest?.actions[0]?.actionKind, "submit_signal");
    assert.equal(signalSubmitSlot?.addOnManifest?.actions[0]?.inputBindings.confirmation, "customsExecutor.confirmation");
    assert.equal(zhixu.roleSlots.some((slot) => slot.slotId.startsWith("system:")), false);
    assert.equal(zhixu.orderPermissionTable.some((entry) => entry.permissionId.startsWith("system.")), false);
    assert.deepEqual(zhixu.createOrderTrigger, {
      source: phase2CustomsInitialTriggerSource,
      signalName: phase2CustomsSignalIds.orderRegistered,
      triggerHookId: "0x4625d43b26ce487427096279b6f54b8bf51a479e9ff90e52c0e71bcc0cba42a2",
      triggerStageId: "0xc670b506d61c646291c5d7ad8521d23188993447ada564c84d6be83599107cca"
    });
    assert.deepEqual(phase2CustomsStoreProductSchema.createOrderTrigger, zhixu.createOrderTrigger);

    const serialized = JSON.stringify([executorPatchSlot, resourcePatchSlot, signalSubmitSlot]);
    const parsed = JSON.parse(serialized);
    assert.deepEqual(parsed.map((slot: { slotId: string }) => slot.slotId), [
      phase2CustomsRoleSlotIds.buyerSelector,
      phase2CustomsRoleSlotIds.buyerResourceController,
      phase2CustomsRoleSlotIds.customsExecutor
    ]);
  });

  it("keeps the Phase 2 customs resource manifest content-addressed and payload-safe", () => {
    assert.equal(phase2CustomsResourceManifest.schemaVersion, "uvp-resource-manifest-v1");
    assert.equal(phase2CustomsResourceManifest.resourceKey, "customs_declaration_pdf");
    assert.match(phase2CustomsResourceManifest.manifestURI, /^uvp-resource:\/\//);
    assert.match(phase2CustomsResourceManifest.manifestHash, /^0x[0-9a-f]{64}$/);
    assert.match(phase2CustomsResourceManifest.policyHash, /^0x[0-9a-f]{64}$/);
    assert.doesNotMatch(JSON.stringify(phase2CustomsResourceManifest), /https?:\/\/|plain_text|download/);
  });

  it("derives Store console lifecycle from review and chain attestation state", () => {
    const zhixu = demoProductCatalog.zhixus[0];
    assert.ok(zhixu);

    const draftRow = toStoreZhixuConsoleDTO(summarizeZhixu(zhixu));
    assert.equal(draftRow.lifecycleStatus, "approved_for_broadcast");
    assert.equal(draftRow.lifecycleLabel, "待链上背书");

    const activeRow = toStoreZhixuConsoleDTO({
      ...summarizeZhixu(zhixu),
      chainAttestation: {
        ...zhixu.chainAttestation,
        status: "attested",
        label: "已写入链上背书",
        txHash: "0xabc"
      }
    }, {
      orderCount: 2,
      openTaskCount: 1,
      supplierCount: 3
    });
    assert.equal(activeRow.lifecycleStatus, "active");
    assert.equal(activeRow.nextAction, "持续观察订单、待办和供应商状态");

    const summary = storeConsoleSummary([draftRow, activeRow]);
    assert.equal(summary.totalZhixus, 2);
    assert.equal(summary.activeZhixus, 1);
    assert.equal(summary.needsReview, 1);
    assert.equal(summary.runningOrders, 2);
    assert.equal(summary.openTasks, 1);
    assert.equal(summary.trustedSuppliers, 3);
  });

  it("models ordinary participant fulfillment plugins without real funding claims", () => {
    assert.equal(demoTask.fulfillmentKind, "delivery_update");
    assert.equal(demoTask.addOnKind, "submit_signal");
    assert.ok(demoTask.resourceRequirements?.some((resource) => resource.source === "plan_default"));
    assert.equal(demoTask.capabilityPlugin?.pluginKind, demoTask.fulfillmentKind);
    assert.equal(demoTask.capabilityPlugin?.source, "explicit");
    assert.equal(demoTask.performanceSlotId, "delivery");
    assert.equal(demoTask.primaryActionLabel, "确认报关完成");
    assert.equal(demoTask.requiredInputs?.some((input) => input.inputType === "evidence"), true);

    assert.equal(demoPaymentTask.fulfillmentKind, "payment_placeholder");
    assert.equal(demoPaymentTask.capabilityPlugin?.pluginKind, demoPaymentTask.fulfillmentKind);
    assert.equal(demoPaymentTask.capabilityPlugin?.roleSlotId, demoPaymentTask.performanceSlotId);
    assert.equal(demoPaymentTask.settlementPreview?.adapterStatus, "placeholder");
    assert.ok(demoPaymentTask.proofRows.some((row) => row.label === "链上事件" && row.value === "SignalSubmitted"));
    const paymentCopy = [
      demoPaymentTask.capabilityPlugin?.summary,
      demoPaymentTask.fundingImpact,
      demoPaymentTask.settlementPreview?.disclaimer,
      ...demoPaymentTask.responsibilityStatements.map((statement) => `${statement.title} ${statement.desc}`)
    ].join(" ");
    assert.match(paymentCopy, /不托管/);
    assert.match(paymentCopy, /不划转/);
    assert.match(paymentCopy, /不释放/);
    assert.match(paymentCopy, /不退款/);

    const ordinaryFundingCopy = [
      demoProductCatalog.zhixus[0]?.supportedPaymentMethods.join(" "),
      demoProductCatalog.zhixus[0]?.roleSlots.find((slot) => slot.slotId === "funds")?.duty,
      demoProductCatalog.zhixus[0]?.dockableModules.find((module) => module.moduleId === "funds-protection")?.desc,
      demoProductCatalog.zhixus[0]?.dockableModules.find((module) => module.moduleId === "funds-protection")?.ports.join(" "),
      demoPaymentTask.title,
      demoPaymentTask.subtitle,
      demoPaymentTask.fundingImpact,
      ...demoPaymentTask.responsibilityStatements.map((statement) => `${statement.title} ${statement.desc}`)
    ].join(" ");
    assert.doesNotMatch(ordinaryFundingCopy, /退款条件|资金托管|托管适配器|划转资金|释放资金|退款资金|结算保证/u);
  });

  it("expresses funding and guarantee options as standard signal containers", () => {
    assert.deepEqual(demoFundingGuaranteeSignalContainers.map((container) => container.scenarioId), [
      "buyer-payment-evidence",
      "guarantor-backing-proof",
      "stablecoin-adapter-proof"
    ]);

    for (const container of demoFundingGuaranteeSignalContainers) {
      assert.equal(container.schemaVersion, "uvp.signal-container.v1");
      assert.equal(container.taskId, demoPaymentTask.taskId);
      assert.equal(container.orderId, demoPaymentTask.orderId);
      assert.equal(container.stageId, demoPaymentTask.stageId);
      assert.equal(container.capabilityKind, "payment_placeholder");
      assert.equal(container.actionKind, "submit_signal");
      assert.equal(container.prepare.submitter, container.acceptedActor.wallet);
      assert.equal(container.prepare.typedData.primaryType, "SubmitSignal");
      assert.match(container.prepare.payloadHash, /^0x[0-9a-f]{64}$/);
      assert.match(container.fundingMetadata.policyHash, /^0x[0-9a-f]{64}$/);
      assert.ok(container.requiredInputs.some((input) => input.inputType === "payment_placeholder"));
      assert.ok(container.fundingMetadata.evidenceIds.length > 0);
      assert.ok(container.fundingMetadata.adapterProofRows.length > 0);
      assert.equal(container.proof.eventName, "SignalSubmitted");
      assert.ok(container.proof.rows.some((row) => row.label === "链上事件" && row.value === "SignalSubmitted"));

      const serialized = JSON.stringify(container);
      const parsed = JSON.parse(serialized);
      assert.equal(parsed.schemaVersion, "uvp.signal-container.v1");
      assert.equal("sourceId" in parsed, false);
      assert.equal("signalId" in parsed, false);

      const copy = Object.values(container.productCopy).join(" ");
      assert.match(copy, /不托管/);
      assert.match(copy, /不划转/);
      assert.match(copy, /不释放/);
      assert.match(copy, /不退款/);
      assert.doesNotMatch(copy, /资金托管|划转资金|释放资金|退款资金|结算保证|payment provider|custodian|settlement rail|exchange/iu);
    }

    const guarantorContainer = demoFundingGuaranteeSignalContainers.find((container) => container.acceptedActor.actorKind === "guarantor");
    assert.ok(guarantorContainer);
    assert.equal(guarantorContainer.acceptedActor.trustStatus, "attested");
    assert.equal(guarantorContainer.fundingMetadata.guarantorSupplierSubjectId, guarantorContainer.acceptedActor.supplierSubjectId);

    const adapterContainer = demoFundingGuaranteeSignalContainers.find((container) => container.acceptedActor.actorKind === "adapter");
    assert.ok(adapterContainer);
    assert.equal(adapterContainer.acceptedActor.trustStatus, "attested");
    assert.ok(adapterContainer.fundingMetadata.adapterProofRows.some((row) => row.label === "外部状态"));
  });

  it("keeps task capability plugins aligned with fulfillmentKind", () => {
    const fulfillmentTasks = demoProductCatalog.tasks.filter((task) => task.fulfillmentKind);
    assert.ok(fulfillmentTasks.length > 0);

    for (const task of fulfillmentTasks) {
      assert.ok(task.fulfillmentKind);
      assert.ok(task.capabilityPlugin);
      assert.equal(task.capabilityPlugin.pluginKind, task.fulfillmentKind);
      assert.equal(task.capabilityPlugin.source, "explicit");
      assert.equal(task.capabilityPlugin.roleSlotId, task.performanceSlotId);
      assert.deepEqual(task.capabilityPlugin.inputPolicy, task.requiredInputs);
    }
  });

  it("serializes executor overlays and resource requirement DTOs", () => {
    const executorOverlay: ProductExecutorOverlayDTO = {
      orderId: demoTask.orderId,
      selectorStageId: "order-confirmed",
      targetStageId: demoTask.stageId,
      mode: "handoff",
      modeLabel: "交接履约者",
      selectorWallet: "0x1111111111111111111111111111111111111111",
      previousExecutor: "0x3333333333333333333333333333333333333333",
      previousExecutorWallet: "0x3333333333333333333333333333333333333333",
      previousExecutorLabel: "原履约者",
      activeExecutorWallet: "0x2222222222222222222222222222222222222222",
      activeExecutorLabel: "新履约者",
      roleHash: "0x0000000000000000000000000000000000000000000000000000000000000a01",
      executorMetadataHash: "0x0000000000000000000000000000000000000000000000000000000000000a02",
      priorAuthorityLabel: "已完成部分不变",
      futureAuthorityLabel: "交接确认后，新履约者只接续后续工作",
      authorityNotice: "只变更后续履约权限",
      patchHash: "0x0000000000000000000000000000000000000000000000000000000000000a04",
      patchNonce: "1",
      metadataURI: "ipfs://executor-overlay/example",
      proofRows: [
        { label: "链上事件", value: "StageExecutorPatchApplied" },
        { label: "补丁序号", value: "1" }
      ]
    };
    const resourceOverlay: ProductResourceOverlayDTO = {
      orderId: demoTask.orderId,
      selectorStageId: "order-confirmed",
      targetStageId: demoTask.stageId,
      resourceKey: "inspection_report",
      writerWallet: "0x1111111111111111111111111111111111111111",
      manifestURI: "ipfs://resource-manifest/example",
      manifestHash: "0x0000000000000000000000000000000000000000000000000000000000000b01",
      policyHash: "0x0000000000000000000000000000000000000000000000000000000000000b02",
      patchHash: "0x0000000000000000000000000000000000000000000000000000000000000b03",
      patchNonce: "2",
      visibility: "protected",
      proofRows: [
        { label: "链上事件", value: "StageResourcePatchApplied" }
      ]
    };

    const order = demoProductCatalog.orders[0];
    assert.ok(order);

    const orderWithOverlay: ProductOrderDTO = {
      ...order,
      executorOverlays: {
        [executorOverlay.targetStageId]: executorOverlay
      },
      resourceOverlays: {
        [resourceOverlay.targetStageId]: [resourceOverlay]
      },
      resourceRequirements: {
        [executorOverlay.targetStageId]: [
          ...(demoTask.resourceRequirements ?? []),
          {
            resourceId: "resource-patch-extra-manifest",
            resourceKey: "resource_patch_extra_manifest",
            label: "补充凭证清单",
            required: false,
            source: "resource_patch",
            visibility: "protected",
            sourceStageId: executorOverlay.targetStageId,
            sourcePatchHash: resourceOverlay.patchHash,
            manifestURI: resourceOverlay.manifestURI,
            manifestHash: resourceOverlay.manifestHash,
            accessStatus: {
              state: "request_required",
              label: "需要授权后查看加密文件",
              canRead: false
            }
          }
        ]
      },
      stages: order.stages.map((stage) => stage.stageId === executorOverlay.targetStageId
        ? {
          ...stage,
          addOnKind: "submit_signal",
          executorOverlay,
          resourceOverlays: [resourceOverlay],
          resourceRequirements: demoTask.resourceRequirements ?? []
        }
        : stage)
    };
    const taskWithOverlay: ProductTaskDTO = {
      ...demoTask,
      executorOverlay,
      resourceOverlays: [resourceOverlay]
    };

    const parsed = JSON.parse(JSON.stringify({ orderWithOverlay, taskWithOverlay }));
    assert.equal(parsed.orderWithOverlay.executorOverlays["customs-complete"].patchNonce, "1");
    assert.equal(parsed.taskWithOverlay.executorOverlay.mode, "handoff");
    assert.equal(parsed.taskWithOverlay.executorOverlay.previousExecutor, executorOverlay.previousExecutor);
    assert.equal(parsed.taskWithOverlay.executorOverlay.priorAuthorityLabel, "已完成部分不变");
    assert.equal(parsed.taskWithOverlay.executorOverlay.activeExecutorWallet, executorOverlay.activeExecutorWallet);
    assert.equal(parsed.orderWithOverlay.resourceOverlays["customs-complete"][0].resourceKey, "inspection_report");
    assert.equal(parsed.orderWithOverlay.resourceRequirements["customs-complete"][0].source, "plan_default");
  });

  it("models resource manifests and product-safe access policy", () => {
    const policy: ProductResourceAccessPolicyDTO = {
      visibility: "private",
      readers: [{ kind: "wallet", label: "指定读取方", value: "0x1111111111111111111111111111111111111111" }],
      writers: [{ kind: "role", label: "交付方" }],
      controllers: [{ kind: "stage", label: "订单确认" }],
      policyHash: "0x0000000000000000000000000000000000000000000000000000000000000c01"
    };
    const manifest: ProductResourceManifestDTO = {
      schemaVersion: "uvp-resource-manifest-v1",
      orderId: demoTask.orderId,
      targetStageId: demoTask.stageId,
      resourceKey: "private_delivery_file",
      visibility: "private",
      manifestURI: "ipfs://resource-manifest/private-delivery-file",
      manifestHash: "0x0000000000000000000000000000000000000000000000000000000000000c02",
      policyHash: policy.policyHash ?? "",
      ciphertextHash: "0x0000000000000000000000000000000000000000000000000000000000000c03",
      storageCID: "bafyuvp-private-delivery-ciphertext",
      recipientEnvelopeRoot: "0x0000000000000000000000000000000000000000000000000000000000000c04",
      createdBy: "0x2222222222222222222222222222222222222222",
      createdAt: "2026-04-30T00:00:00.000Z"
    };
    const requirement: ProductResourceRequirementDTO = {
      resourceId: "private-delivery-file",
      resourceKey: manifest.resourceKey,
      label: "私密交付文件",
      required: true,
      source: "resource_patch",
      resourceType: "document",
      visibility: "private",
      manifest,
      manifestURI: manifest.manifestURI,
      manifestHash: manifest.manifestHash,
      ciphertextHash: manifest.ciphertextHash ?? "",
      storageCID: manifest.storageCID ?? "",
      accessPolicy: policy,
      accessStatus: {
        state: "not_authorized",
        label: "当前钱包不可查看",
        canRead: false,
        reason: "读取受加密信封约束。"
      }
    };

    const parsed = JSON.parse(JSON.stringify(requirement));
    assert.equal(parsed.visibility, "private");
    assert.equal(parsed.accessPolicy.readers[0].kind, "wallet");
    assert.equal(parsed.accessStatus.canRead, false);
    assert.equal(parsed.manifest.schemaVersion, "uvp-resource-manifest-v1");
    assert.equal("sourceId" in parsed, false);
    assert.equal("signalId" in parsed, false);
  });

  it("keeps fallback task payloads compatible without add-on fields", () => {
    const legacyTask: ProductTaskDTO = {
      taskId: "legacy-evidence-task",
      orderId: "legacy-order",
      orderTitle: "Legacy order",
      zhixuId: "legacy-zhixu",
      title: "Submit evidence",
      subtitle: "Legacy payload using fulfillment plugin fields.",
      assigneeRole: "Participant",
      stageId: "legacy-stage",
      stageName: "Legacy stage",
      deadline: "2026-05-01 18:00",
      fundingImpact: "No funding movement is represented by this DTO.",
      requiredEvidence: ["Evidence hash"],
      status: "open",
      fulfillmentKind: "evidence_submission",
      capabilityPlugin: {
        pluginKind: "evidence_submission",
        source: "legacy_inferred",
        requiredEvidence: ["Evidence hash"]
      },
      responsibilityStatements: [],
      proofRows: []
    };

    const parsed = JSON.parse(JSON.stringify(legacyTask));
    assert.equal(parsed.fulfillmentKind, "evidence_submission");
    assert.equal(parsed.capabilityPlugin.pluginKind, parsed.fulfillmentKind);
    assert.equal("addOnKind" in parsed, false);
    assert.equal("resourceRequirements" in parsed, false);
  });

  it("allows generic participant add-ons without industry-specific plugins", () => {
    const supportedKinds: readonly ParticipantAddOnKind[] = ["submit_signal", "stage_executor_patch", "stage_resource_patch"];
    assert.deepEqual(supportedKinds, ["submit_signal", "stage_executor_patch", "stage_resource_patch"]);

    assert.equal(demoSelectorTask.addOnKind, "stage_executor_patch");
    assert.equal(demoSelectorTask.fulfillmentKind, undefined);
    assert.equal(demoSelectorTask.capabilityPlugin, undefined);
    assert.ok(demoSelectorTask.selectableTargets?.some((target) => target.allowed));

    assert.equal(demoResourcePatchTask.addOnKind, "stage_resource_patch");
    assert.ok(demoResourcePatchTask.resourceRequirements?.some((resource) => resource.visibility === "protected"));

    const executorTask: ProductTaskDTO = {
      taskId: "task-executor-generic-001",
      orderId: demoTask.orderId,
      orderTitle: demoTask.orderTitle,
      zhixuId: demoTask.zhixuId,
      title: "提交确认",
      subtitle: "核对凭证指纹并提交确认结果。",
      assigneeRole: "验收方",
      stageId: "inspection",
      stageName: "检验验收",
      deadline: "2026-05-04 18:00",
      fundingImpact: "仅记录验收确认，不处理任何资金动作",
      requiredEvidence: ["凭证指纹"],
      status: "open",
      addOnKind: "submit_signal",
      resourceRequirements: [
        {
          resourceId: "review-evidence-fingerprint",
          label: "凭证指纹",
          required: true,
          source: "participant_input",
          resourceType: "metadata",
          visibility: "protected",
          accessStatus: {
            state: "available",
            label: "当前参与方可核对",
            canRead: true
          }
        }
      ],
      primaryActionLabel: "提交确认",
      responsibilityStatements: [],
      proofRows: []
    };

    const parsed = JSON.parse(JSON.stringify(executorTask));
    assert.equal(parsed.addOnKind, "submit_signal");
    assert.equal(parsed.capabilityPlugin, undefined);
    assert.equal(parsed.resourceRequirements[0].source, "participant_input");
  });

  it("models executor patch governance modes for executor patch tasks", () => {
    const supportedModes: readonly ProductExecutorPatchMode[] = ["assign", "handoff", "replacement"];
    assert.deepEqual(supportedModes, ["assign", "handoff", "replacement"]);
    assert.deepEqual(demoSelectorTask.executorPatchModes?.map((mode) => mode.mode), supportedModes);

    const modeById = new Map(
      demoSelectorTask.executorPatchModes?.map((mode): readonly [ProductExecutorPatchMode, ProductExecutorPatchRequirementDTO] => [
        mode.mode,
        mode
      ])
    );
    const assign = modeById.get("assign");
    const handoff = modeById.get("handoff");
    const replacement = modeById.get("replacement");

    assert.ok(assign);
    assert.equal(assign.workStarted, false);
    assert.equal(assign.requiresPreviousExecutorSignature, false);
    assert.equal(assign.modeLabel, "选择履约者");

    assert.ok(handoff);
    assert.equal(handoff.workStarted, true);
    assert.equal(handoff.requiresPreviousExecutorSignature, true);
    assert.equal(handoff.requiresApprovalSignal, false);
    assert.equal(handoff.priorAuthorityLabel, "已完成部分不变");
    assert.ok(handoff.previousExecutor);

    assert.ok(replacement);
    assert.equal(replacement.workStarted, true);
    assert.equal(replacement.requiresPreviousExecutorSignature, false);
    assert.equal(replacement.requiresApprovalSignal, true);
    assert.equal(replacement.guidanceLabel, "需要替换证明");
    assert.ok(replacement.approvalSignal?.approvalSourceId);
    assert.ok(replacement.approvalSignal?.approvalSignalId);

    const startedTarget = demoSelectorTask.selectableTargets?.find((target) => target.workStarted);
    assert.ok(startedTarget);
    assert.deepEqual(startedTarget.executorPatchModes?.map((mode) => mode.mode), ["handoff", "replacement"]);
    assert.equal(startedTarget.executorPatchModes?.some((mode) => mode.mode === "assign"), false);
    assert.equal(startedTarget.priorAuthorityLabel, "已完成部分不变");

    const parsed = JSON.parse(JSON.stringify(demoSelectorTask));
    assert.equal(parsed.executorPatchModes[2].mode, "replacement");
    assert.equal(parsed.executorPatchModes[2].approvalSignal.label, "裁定方替换证明");

    const governanceCopy = demoSelectorTask.executorPatchModes?.map((mode) => [
      mode.modeLabel,
      mode.guidanceLabel,
      mode.priorAuthorityLabel,
      mode.futureAuthorityLabel
    ].join(" ")).join(" ") ?? "";
    assert.match(governanceCopy, /已完成部分不变/);
    assert.doesNotMatch(governanceCopy, /托管|划转|释放|退款/u);
  });

  it("builds Store zhixu detail as a summary-compatible superset", () => {
    const zhixu = demoProductCatalog.zhixus[0];
    assert.ok(zhixu);

    const row = toStoreZhixuConsoleDTO(summarizeZhixu(zhixu), {
      orderCount: 2,
      openTaskCount: 1,
      supplierCount: 3
    });
    const detail = toStoreZhixuDetailDTO(row, zhixu);

    assert.equal(detail.zhixuId, row.zhixuId);
    assert.equal(detail.lifecycleStatus, row.lifecycleStatus);
    assert.equal(detail.orderCount, row.orderCount);
    assert.equal(detail.stages.length, zhixu.stages.length);
    assert.equal(detail.roleSlots.length, zhixu.roleSlots.length);
    const deliverySlot = detail.roleSlots.find((slot) => slot.roleSlotId === "delivery");
    assert.ok(deliverySlot);
    assert.equal(deliverySlot.performanceSlotLabel, "交付履约者");
    assert.deepEqual(deliverySlot.businessPersonaLabels, ["报关行", "物流/货代"]);
    assert.equal(deliverySlot.capabilityReviewStatus, "explicit");
    assert.equal(deliverySlot.capabilityReviewLabel, "显式配置");
    assert.ok(deliverySlot.capabilityPlugins.some((plugin) =>
      plugin.pluginKind === "delivery_update" &&
      plugin.source === "explicit" &&
      plugin.stageIds.includes("customs-complete") &&
      plugin.title === "交付进度更新" &&
      plugin.primaryActionLabel === "确认报关完成" &&
      plugin.requiredEvidence.includes("报关单")
    ));
    assert.ok(detail.supplierRequirements.length > 0);
    assert.ok(detail.proofSections.some((section) => section.sectionId === "chain-attestation"));
    assert.ok(detail.allowedActions.some((action) => action.actionId === "broadcast_attestation"));
  });

  it("keeps revoked Store zhixu detail proof-visible but closed for new orders", () => {
    const zhixu = demoProductCatalog.zhixus[0];
    assert.ok(zhixu);

    const row = toStoreZhixuConsoleDTO({
      ...summarizeZhixu(zhixu),
      reviewStatus: "revoked",
      reviewLabel: "链上背书已撤销",
      chainAttestation: {
        ...zhixu.chainAttestation,
        status: "revoked",
        label: "已撤销链上背书",
        txHash: "0xabc",
        blockNumber: "42"
      }
    });
    const detail = toStoreZhixuDetailDTO(row, zhixu);

    assert.equal(detail.lifecycleStatus, "revoked");
    assert.match(detail.lifecycleReason, /不能创建新订单/);
    assert.equal(detail.allowedActions.some((action) => action.actionId === "create_order"), false);
    assert.ok(detail.proofSections.some((section) =>
      section.rows.some((row) => row.label === "链上事件" && row.value === "PlanRevoked")
    ));
  });

  it("exports Store supplier capability tags for registry DTOs", () => {
    assert.deepEqual(STORE_SUPPLIER_CAPABILITY_TAGS, [
      "logistics",
      "customs",
      "inspection",
      "payment",
      "dispute-review",
      "document-verification"
    ]);
  });
});

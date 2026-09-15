import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type {
  EvidenceProofDTO,
  FulfillmentPluginKind,
  ParticipantAddOnManifestDTO,
  ProductSubmissionDTO,
  ProductSubmitIntent,
  TaskSubmitIntent,
} from "@uvp-eth/product-dto";
import {
  submitIntentByPluginKind,
  taskSubmitIntent,
  taskSubmitIntentForAction,
} from "@uvp-eth/product-dto";

// 治理审计 §1.1 P1-1：写侧契约入包后的形状与推导钉子——形状对齐
// uvp-chain-services 服务端真身（submissions/types.ts、evidence/types.ts、
// evidence/service.ts getProof、reconcile/status.ts），推导对齐
// order-app taskPresentation 与 zhixu-store workbenchSupport 的镜像。

const ALL_PLUGIN_KINDS: readonly FulfillmentPluginKind[] = [
  "payment_placeholder",
  "evidence_submission",
  "delivery_update",
  "validation_confirm",
  "dispute_material",
];

const ALL_SUBMIT_INTENTS: readonly ProductSubmitIntent[] = [
  "confirm_stage",
  "reject_stage",
  "raise_dispute",
  "resolve_dispute",
];

describe("写侧词表对齐服务端", () => {
  it("ProductSubmitIntent 与 TaskSubmitIntent 值域恒等（同一联合的历史名字）", () => {
    const asTask: readonly TaskSubmitIntent[] = ALL_SUBMIT_INTENTS;
    const asProduct: readonly ProductSubmitIntent[] = asTask;
    assert.equal(asProduct.length, 4);
    assert.deepEqual(new Set(asProduct), new Set(ALL_SUBMIT_INTENTS));
  });

  it("submitIntentByPluginKind 覆盖全部插件类型且争议任务不得 confirm_stage", () => {
    for (const kind of ALL_PLUGIN_KINDS) {
      assert.ok(kind in submitIntentByPluginKind, `missing ${kind}`);
    }
    assert.equal(submitIntentByPluginKind.dispute_material, "raise_dispute");
    for (const kind of ALL_PLUGIN_KINDS) {
      if (kind !== "dispute_material") {
        assert.equal(submitIntentByPluginKind[kind], "confirm_stage");
      }
    }
  });
});

function capabilityPlugin(pluginKind: FulfillmentPluginKind) {
  return { pluginKind, source: "explicit" as const };
}

function manifestWithActions(
  actions: ParticipantAddOnManifestDTO["actions"],
): ParticipantAddOnManifestDTO {
  return {
    schemaVersion: "uvp.participantAddOnManifest.v1",
    manifestId: "manifest-1",
    roleSlotId: "role-1",
    addOnKind: "submit_signal",
    title: "提交",
    summary: "提交",
    stageBindings: ["stage-1"],
    pages: [],
    actions,
  } as unknown as ParticipantAddOnManifestDTO;
}

describe("taskSubmitIntent 推导（manifest 优先，两端镜像收敛）", () => {
  it("manifest 显式声明的 submit_signal intent 优先", () => {
    const task = {
      addOnManifest: manifestWithActions([
        {
          actionId: "a1",
          actionKind: "submit_signal",
          label: "拒绝",
          primary: true,
          intent: "reject_stage",
          inputBindings: {},
        },
        {
          actionId: "a2",
          actionKind: "submit_signal",
          label: "确认",
          intent: "confirm_stage",
          inputBindings: {},
        },
      ]),
    };
    assert.equal(taskSubmitIntent(task), "reject_stage");
  });

  it("无 primary 时取第一个 submit_signal 动作", () => {
    const task = {
      addOnManifest: manifestWithActions([
        {
          actionId: "a1",
          actionKind: "submit_signal",
          label: "解决",
          intent: "resolve_dispute",
          inputBindings: {},
        },
      ]),
    };
    assert.equal(taskSubmitIntent(task), "resolve_dispute");
  });

  it("manifest 未声明 intent 时按能力插件类型推导", () => {
    const task = {
      addOnManifest: manifestWithActions([
        {
          actionId: "a1",
          actionKind: "submit_signal",
          label: "提交",
          inputBindings: {},
        },
      ]),
      capabilityPlugin: capabilityPlugin("evidence_submission"),
    };
    assert.equal(taskSubmitIntent(task), "confirm_stage");
  });

  it("dispute_material 未声明动作不得兜底成 confirm_stage", () => {
    const task = {
      capabilityPlugin: capabilityPlugin("dispute_material"),
    };
    assert.equal(taskSubmitIntent(task), "raise_dispute");
    assert.equal(
      taskSubmitIntentForAction(undefined, task),
      "raise_dispute",
    );
  });

  it("无 manifest 且无 capabilityPlugin 时中性兜底 confirm_stage", () => {
    assert.equal(taskSubmitIntent({}), "confirm_stage");
  });

  it("非 submit_signal 动作不参与推导", () => {
    const task = {
      addOnManifest: manifestWithActions([
        {
          actionId: "a1",
          actionKind: "stage_executor_patch",
          label: "查看",
          primary: true,
          intent: "reject_stage",
          inputBindings: {},
        },
      ]),
    };
    assert.equal(taskSubmitIntent(task), "confirm_stage");
  });
});

describe("写侧 DTO 形状（编译期由 tsc --noEmit 钉住）", () => {
  it("EvidenceProofDTO：getProof 恒产出字段必填（evidenceId/payloadRef/storageURI）", () => {
    const proof = {
      evidenceId: "ev-1",
      payloadHash: "0x01",
      contentHash: "0x02",
      metadataHash: "0x03",
      payloadRef: "cos://payload",
      storageURI: "cos://store",
      verificationStatus: "matched",
    } as const satisfies EvidenceProofDTO;
    assert.equal(proof.evidenceId, "ev-1");
    assert.equal(proof.storageURI, "cos://store");
  });

  it("ProductSubmissionDTO：statusLabel 必填（服务端读取兜底恒产出）", () => {
    const submission = {
      submissionId: "sub-1",
      prepareId: "prep-1",
      taskId: "task-1",
      orderId: "order-1",
      onchainOrderId: "0x04",
      planId: "0x05",
      stageIdentifier: "stage-1",
      signalName: "CONFIRM",
      sourceId: "0x06",
      signalId: "0x07",
      intent: "confirm_stage",
      payloadHash: "0x08",
      payloadRef: "cos://payload",
      idempotencyKey: "0x09",
      submitter: "0xaa",
      nonce: "1",
      deadline: "0",
      status: "confirmed",
      statusLabel: "已确认",
      signatureStatus: "signature_verified",
      broadcastStatus: "confirmed",
      retryable: false,
      retryState: "not_applicable",
      deadLetter: false,
      attempts: [],
      attemptCount: 0,
      proofRows: [],
      createdAt: "2026-09-14T00:00:00.000Z",
      updatedAt: "2026-09-14T00:00:00.000Z",
    } as const satisfies ProductSubmissionDTO;
    assert.equal(submission.statusLabel, "已确认");
  });

  it("statusLabel 缺失即编译错误（@ts-expect-error 由 typecheck 钉住）", () => {
    const _missingStatusLabel = {
      submissionId: "sub-1",
    } as const;
    void _missingStatusLabel;
    // 形状断言在编译期：以下赋值缺 statusLabel，tsc 必须报错。
    // @ts-expect-error statusLabel 是必填字段（服务端兜底恒产出的裁决落点）
    const bad: ProductSubmissionDTO = { submissionId: "sub-1" };
    void bad;
  });
});

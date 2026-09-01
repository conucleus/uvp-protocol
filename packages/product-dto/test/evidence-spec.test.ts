import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  type ProductTaskDTO,
  type TaskEvidenceSpecDTO,
  validateTaskEvidenceSpec
} from "@uvp-eth/product-dto";
import { demoTask } from "@uvp-eth/product-dto/fixtures";

describe("task evidence spec", () => {
  it("treats an absent spec as valid so existing tasks stay compatible", () => {
    assert.deepEqual(validateTaskEvidenceSpec(undefined), []);
    assert.deepEqual(validateTaskEvidenceSpec(null), []);
  });

  it("accepts a structural valid spec", () => {
    const spec: readonly TaskEvidenceSpecDTO[] = [
      { key: "report_pdf", label: "报告 PDF", inputKind: "file", accept: ["application/pdf", ".pdf"], required: true },
      { key: "serial_no", label: "编号", inputKind: "text", required: true },
      { key: "done_at", label: "完成时间", inputKind: "date" },
      { key: "optional_note", label: "补充说明", inputKind: "text", required: false }
    ];
    assert.deepEqual(validateTaskEvidenceSpec(spec), []);
  });

  it("rejects an empty array: declare nothing or declare slots", () => {
    const issues = validateTaskEvidenceSpec([]);
    assert.equal(issues.length, 1);
    assert.equal(issues[0]?.code, "empty_spec");
  });

  it("flags empty keys and labels with their index", () => {
    const issues = validateTaskEvidenceSpec([
      { key: "  ", label: "凭证" },
      { key: "slot", label: "" }
    ]);
    assert.deepEqual(issues.map((issue) => issue.code), ["empty_key", "empty_label"]);
    assert.equal(issues[0]?.index, 0);
    assert.equal(issues[1]?.index, 1);
  });

  it("flags duplicate keys", () => {
    const issues = validateTaskEvidenceSpec([
      { key: "same", label: "A" },
      { key: "same", label: "B" }
    ]);
    assert.deepEqual(issues.map((issue) => issue.code), ["duplicate_key"]);
    assert.equal(issues[0]?.index, 1);
  });

  it("rejects unknown input kinds", () => {
    const badSpec = [
      { key: "slot", label: "凭证", inputKind: "signature" }
    ] as unknown as readonly TaskEvidenceSpecDTO[];
    const issues = validateTaskEvidenceSpec(badSpec);
    assert.deepEqual(issues.map((issue) => issue.code), ["invalid_input_kind"]);
  });

  it("restricts accept lists to file inputs and non-empty entries", () => {
    const issues = validateTaskEvidenceSpec([
      { key: "note", label: "说明", inputKind: "text", accept: ["application/pdf"] },
      { key: "file", label: "凭证", inputKind: "file", accept: [""] }
    ]);
    assert.deepEqual(issues.map((issue) => issue.code), ["accept_on_non_file_input", "invalid_accept_entry"]);
    assert.equal(issues[1]?.index, 1);
  });

  it("keeps the demo task fixture spec aligned with its declared evidence", () => {
    // The demo fixture is demo configuration data: it must pass the same
    // structural validation any publisher-carried spec goes through.
    assert.deepEqual(validateTaskEvidenceSpec(demoTask.evidenceSpec), []);
    assert.ok(demoTask.evidenceSpec && demoTask.evidenceSpec.length > 0);
  });

  it("stays additive: tasks without evidenceSpec serialize unchanged", () => {
    const task: ProductTaskDTO = {
      taskId: "task-legacy",
      orderId: "order",
      orderTitle: "Order",
      zhixuId: "zhixu",
      title: "提交凭证",
      subtitle: "无结构化配置的旧任务。",
      assigneeRole: "履约方",
      stageId: "stage",
      stageName: "阶段",
      deadline: "2026-09-30 18:00",
      fundingImpact: "无资金动作",
      requiredEvidence: ["任意声明"],
      status: "open",
      responsibilityStatements: [],
      proofRows: []
    };
    const parsed = JSON.parse(JSON.stringify(task));
    assert.equal("evidenceSpec" in parsed, false);
    assert.deepEqual(parsed.requiredEvidence, ["任意声明"]);
  });

  it("serializes evidenceSpec payloads as plain JSON", () => {
    const parsed = JSON.parse(JSON.stringify(demoTask));
    assert.ok(Array.isArray(parsed.evidenceSpec));
    assert.equal(parsed.evidenceSpec[0].key, "customs_declaration_pdf");
    assert.equal(parsed.evidenceSpec[0].inputKind, "file");
    assert.deepEqual(parsed.evidenceSpec[0].accept, ["application/pdf", ".pdf"]);
  });
});

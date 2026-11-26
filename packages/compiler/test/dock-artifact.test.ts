// Pins uvp.dock.v1 artifact validation and AST -> RPN DockWindowInstruction[]
// lowering against IUVPDockController.WindowInstruction opcodes (0..4).
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  DOCK_ARTIFACT_SCHEMA_VERSION,
  DOCK_WINDOW_OP,
  DockArtifactValidationError,
  assertDockArtifact,
  dockWindowInstructionsOf,
  keccak256Hex,
  validateDockArtifact,
  type DockArtifact,
  type DockArtifactAtom,
  type DockArtifactOutput,
} from "../src/index.js";

const ZERO_WORD = `0x${"00".repeat(32)}` as const;

function makeAtom(source: string, stage: string, signal: string): DockArtifactAtom {
  return {
    source,
    sourceId: keccak256Hex(source),
    stage,
    stageId: keccak256Hex(stage),
    signal,
    signalId: keccak256Hex(`${stage}.${signal}`),
    targetOrderRelation: 0,
  };
}

function validDockArtifact(): DockArtifact {
  const docHash = keccak256Hex("uvp:dock-uid:v1:sample");
  const dkid = `zd-${docHash.slice(2, 34)}`;
  const fromSource = "customs_ops";
  const toSource = "performer";
  const toStage = "performer_work";

  const clearedAtom = makeAtom(fromSource, "release", "cleared");
  const seizedAtom = makeAtom(fromSource, "inspection", "seized");
  const rejectedAtom = makeAtom(fromSource, "compliance", "rejected");

  const output: DockArtifactOutput = {
    signal: "submit",
    signalId: keccak256Hex(`${toStage}.submit`),
    sourceId: keccak256Hex(toSource),
    stageId: keccak256Hex(toStage),
    targetOrderRelation: 0,
    rawExpression: "((release.cleared | inspection.seized) & ~compliance.rejected) + 1h",
    ast: {
      raw: `${fromSource}::((release.cleared | inspection.seized) & ~compliance.rejected) + 1h`,
      source: fromSource,
      condition: {
        kind: "delay",
        durationSeconds: 3600,
        rawDuration: "1h",
        expr: {
          kind: "and",
          terms: [
            {
              kind: "or",
              terms: [
                { kind: "signal", signalName: "release.cleared" },
                { kind: "signal", signalName: "inspection.seized" },
              ],
            },
            {
              kind: "not",
              expr: { kind: "signal", signalName: "compliance.rejected" },
            },
          ],
        },
      },
    },
    dependencies: [
      { kind: "positive", source: fromSource, signalName: "release.cleared" },
      { kind: "positive", source: fromSource, signalName: "inspection.seized" },
      { kind: "negative", source: fromSource, signalName: "compliance.rejected" },
      { kind: "timer", source: fromSource, signalName: "release.cleared", delaySeconds: 3600 },
    ],
    atoms: [clearedAtom, seizedAtom, rejectedAtom],
  };

  return {
    schemaVersion: DOCK_ARTIFACT_SCHEMA_VERSION,
    dkid,
    docHash,
    from: {
      zhixu: "zx-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      source: fromSource,
      sourceId: keccak256Hex(fromSource),
    },
    to: {
      zhixu: "zx-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      stage: toStage,
      stageId: keccak256Hex(toStage),
      source: toSource,
      sourceId: keccak256Hex(toSource),
    },
    signalMap: [output],
  };
}

describe("dock-artifact", () => {
  it("validates a uvp.dock.v1 artifact and lowers & / | / ~ / +T into RPN WindowInstruction[]", () => {
    const artifact = validDockArtifact();
    assert.deepEqual(validateDockArtifact(artifact), []);
    assertDockArtifact(artifact);

    const output = artifact.signalMap[0]!;
    const instructions = dockWindowInstructionsOf(output);
    const fromSourceId = keccak256Hex("customs_ops");

    assert.deepEqual(instructions, [
      {
        op: DOCK_WINDOW_OP.SIGNAL,
        sourceId: fromSourceId,
        signalId: keccak256Hex("release.cleared"),
        arity: 0,
        delaySeconds: 0,
      },
      {
        op: DOCK_WINDOW_OP.SIGNAL,
        sourceId: fromSourceId,
        signalId: keccak256Hex("inspection.seized"),
        arity: 0,
        delaySeconds: 0,
      },
      {
        op: DOCK_WINDOW_OP.OR,
        sourceId: ZERO_WORD,
        signalId: ZERO_WORD,
        arity: 2,
        delaySeconds: 0,
      },
      {
        op: DOCK_WINDOW_OP.SIGNAL,
        sourceId: fromSourceId,
        signalId: keccak256Hex("compliance.rejected"),
        arity: 0,
        delaySeconds: 0,
      },
      {
        op: DOCK_WINDOW_OP.NOT,
        sourceId: ZERO_WORD,
        signalId: ZERO_WORD,
        arity: 0,
        delaySeconds: 0,
      },
      {
        op: DOCK_WINDOW_OP.AND,
        sourceId: ZERO_WORD,
        signalId: ZERO_WORD,
        arity: 2,
        delaySeconds: 0,
      },
      {
        op: DOCK_WINDOW_OP.DELAY,
        sourceId: ZERO_WORD,
        signalId: ZERO_WORD,
        arity: 0,
        delaySeconds: 3600,
      },
    ]);
  });

  it("rejects unknown closed-set fields, mismatched dkid/hash, and non-zero targetOrderRelation", () => {
    const artifact = validDockArtifact();
    const broken = {
      ...artifact,
      dkid: "zd-00000000000000000000000000000000",
      extraField: true,
      signalMap: [
        {
          ...artifact.signalMap[0]!,
          targetOrderRelation: 1,
        },
      ],
    };

    const issues = validateDockArtifact(broken);
    assert.ok(issues.some((issue) => issue.includes("unknown field `extraField` on artifact")));
    assert.ok(issues.some((issue) => issue.includes("dkid must be zd-<first 32 hex digits of docHash>")));
    assert.ok(issues.some((issue) => issue.includes("signalMap[0].targetOrderRelation must be 0")));

    assert.throws(
      () => assertDockArtifact(broken),
      (error: unknown) =>
        error instanceof DockArtifactValidationError && error.issues.length === issues.length,
    );
  });

  it("rejects an AST referencing an atom absent from output.atoms", () => {
    const artifact = validDockArtifact();
    const output = artifact.signalMap[0]!;
    const missingAtomOutput: DockArtifactOutput = {
      ...output,
      atoms: output.atoms.slice(0, 2),
    };

    assert.throws(
      () => dockWindowInstructionsOf(missingAtomOutput),
      (error: unknown) =>
        error instanceof DockArtifactValidationError &&
        error.issues.some((issue) =>
          issue.includes("output submit expression references atom compliance.rejected absent from atoms"),
        ),
    );
  });
});

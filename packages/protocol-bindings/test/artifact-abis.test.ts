import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";
import { toEventHash, type Abi, type AbiEvent } from "viem";
import {
  buildCompactHookFlags,
  HOOK_FLAG_EMIT_READY,
  HOOK_FLAG_ORDER_TRIGGER_DOCK,
  HOOK_FLAG_ORDER_TRIGGER_MINT,
  SIGNAL_SUBMITTED_ABI,
  SIGNAL_SUBMITTED_TOPIC,
  STATE_MACHINE_ABI,
  UVP_STATE_MACHINE_ARTIFACT_ABI,
} from "../src/index.js";

const packageDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const artifactPath = resolve(
  packageDir,
  "../../contracts/uvp-contracts/out/UVPStateMachine.sol/UVPStateMachine.json",
);

interface FoundryArtifact {
  readonly abi: Abi;
}

// The generated ABI mirrors a forge build product; without `forge build` the
// artifact does not exist and the pin has nothing to compare against.
const artifactAvailable = existsSync(artifactPath);

describe("generated artifact ABI bindings", () => {
  it("keeps CompactHook flag bits pinned to the contract constants", () => {
    assert.equal(HOOK_FLAG_ORDER_TRIGGER_MINT, 1);
    assert.equal(HOOK_FLAG_ORDER_TRIGGER_DOCK, 2);
    assert.equal(HOOK_FLAG_EMIT_READY, 4);
    // 编译器产物恒为 trigger|EMIT_READY：mint=5 / dock=6。
    assert.equal(
      buildCompactHookFlags({ orderTriggerKind: "mint", emitReady: true }),
      5,
    );
    assert.equal(
      buildCompactHookFlags({ orderTriggerKind: "dock", emitReady: true }),
      6,
    );
    assert.equal(buildCompactHookFlags({ emitReady: true }), 4);
    assert.equal(buildCompactHookFlags(), 0);
  });

  it("exposes the SignalSubmitted topic of the current composite-identity event", async (t) => {
    if (!artifactAvailable) {
      return t.skip("forge artifacts not built");
    }
    const artifact = JSON.parse(
      await readFile(artifactPath, "utf8"),
    ) as FoundryArtifact;
    const event = artifact.abi.find(
      (item) => item.type === "event" && item.name === "SignalSubmitted",
    ) as AbiEvent | undefined;
    assert.ok(event, "artifact ABI must contain SignalSubmitted");

    assert.equal(SIGNAL_SUBMITTED_ABI.length, 1);
    assert.deepEqual(SIGNAL_SUBMITTED_ABI[0], event);
    assert.equal(SIGNAL_SUBMITTED_TOPIC, toEventHash(event));
  });

  it("mirrors the full forge artifact ABI verbatim", async (t) => {
    if (!artifactAvailable) {
      return t.skip("forge artifacts not built");
    }
    const artifact = JSON.parse(
      await readFile(artifactPath, "utf8"),
    ) as FoundryArtifact;
    assert.deepEqual(UVP_STATE_MACHINE_ARTIFACT_ABI, artifact.abi);
  });

  it("keeps the handwritten frozen STATE_MACHINE_ABI a subset of the artifact ABI", async (t) => {
    if (!artifactAvailable) {
      return t.skip("forge artifacts not built");
    }
    const artifact = JSON.parse(
      await readFile(artifactPath, "utf8"),
    ) as FoundryArtifact;
    const artifactSignatures = new Set(
      artifact.abi.map((item) => abiSignature(item)),
    );
    const missing = STATE_MACHINE_ABI.filter(
      (item) => !artifactSignatures.has(abiSignature(item)),
    ).map((item) => abiSignature(item));
    assert.deepEqual(missing, []);
  });
});

function abiSignature(
  item:
    | string
    | {
        readonly type: string;
        readonly name?: string;
        readonly inputs?: readonly {
          readonly type: string;
          readonly components?: readonly unknown[];
        }[];
      },
): string {
  if (typeof item === "string") {
    return item;
  }
  if (item.type !== "function" && item.type !== "event") {
    return `${item.type}:${item.name ?? ""}`;
  }
  const inputs = (item.inputs ?? []).map(abiInputType).join(",");
  return `${item.name}(${inputs})`;
}

function abiInputType(input: {
  readonly type: string;
  readonly components?: readonly unknown[];
}): string {
  if (!input.type.startsWith("tuple")) {
    return input.type;
  }
  const suffix = input.type.slice("tuple".length);
  const components = (input.components ?? [])
    .map((component) => abiInputType(component as never))
    .join(",");
  return `(${components})${suffix}`;
}

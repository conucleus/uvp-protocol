// L3 ABI pin (generation-freshness, not two hand-written implementations):
// 1. Compared facts: the checked-in generated constants in src/artifact-abis.ts
//    versus the Forge artifact ABI JSON that scripts/generate-artifact-abis.ts
//    consumes as its only input.
// 2. Why they cannot be collapsed into one source: the Forge artifacts are
//    build products under contracts/uvp-contracts/out and are not importable
//    package exports; downstream packages must consume a checked-in copy.
// 3. Why the comparison cannot run through the generator alone: staleness of
//    the checked-in generated file is only observable here. The pin is
//    fail-closed: missing Forge artifacts fail this suite instead of skipping,
//    so `pnpm contracts:build` must run before it.
// 4. Owner: protocol-bindings (L3) owns the ABI surface and the generator; this
//    file never re-derives ABI shapes by hand.
// 5. Exit condition: delete this pin when ABI generation becomes part of the
//    package build or consumers import the Forge artifacts directly.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";
import { toEventHash, type Abi, type AbiEvent } from "viem";
import {
  buildCompactHookFlags,
  FILE_RESOURCE_MODULE_ABI,
  HOOK_FLAG_DOCK_EXECUTOR,
  HOOK_FLAG_DYNAMIC_EXECUTOR,
  HOOK_FLAG_EMIT_READY,
  HOOK_FLAG_ORDER_TRIGGER_MINT,
  SIGNAL_SUBMITTED_ABI,
  SIGNAL_SUBMITTED_TOPIC,
  STATE_MACHINE_ABI,
  IDENTITY_REGISTRY_ABI,
  UVP_STATE_MACHINE_ARTIFACT_ABI,
} from "../src/index.js";

const packageDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const artifactPath = resolve(
  packageDir,
  "../../contracts/uvp-contracts/out/UVPStateMachine.sol/UVPStateMachine.json",
);
const fileResourceModuleArtifactPath = resolve(
  packageDir,
  "../../contracts/uvp-contracts/out/UVPFileResourceModule.sol/UVPFileResourceModule.json",
);
const identityRegistryArtifactPath = resolve(
  packageDir,
  "../../contracts/uvp-contracts/out/UVPIdentityRegistry.sol/UVPIdentityRegistry.json",
);

interface FoundryArtifact {
  readonly abi: Abi;
}

// The generated ABI mirrors a forge build product; without `forge build` the
// pin has no evidence, so a missing artifact is a hard failure.
async function readForgeArtifact(path: string): Promise<FoundryArtifact> {
  if (!existsSync(path)) {
    assert.fail(
      `forge artifact missing: ${path}; run \`pnpm contracts:build\` before the ABI freshness pin`,
    );
  }
  return JSON.parse(await readFile(path, "utf8")) as FoundryArtifact;
}

describe("generated artifact ABI bindings", () => {
  it("keeps CompactHook flag bits pinned to the contract constants", () => {
    assert.equal(HOOK_FLAG_ORDER_TRIGGER_MINT, 1);
    assert.equal(HOOK_FLAG_EMIT_READY, 4);
    assert.equal(HOOK_FLAG_DOCK_EXECUTOR, 16);
    assert.equal(HOOK_FLAG_DYNAMIC_EXECUTOR, 32);
    // 编译器产物恒为 trigger|EMIT_READY：trigger=5。
    assert.equal(
      buildCompactHookFlags({ orderTriggerKind: "trigger", emitReady: true }),
      5,
    );
    assert.equal(buildCompactHookFlags({ emitReady: true }), 4);
    assert.equal(buildCompactHookFlags({ dockExecutor: true }), 16);
    assert.equal(
      buildCompactHookFlags({ emitReady: true, dynamicExecutor: true }),
      36,
    );
    assert.equal(buildCompactHookFlags(), 0);
  });

  it("exposes the SignalSubmitted topic of the current composite-identity event", async () => {
    const artifact = await readForgeArtifact(artifactPath);
    const event = artifact.abi.find(
      (item) => item.type === "event" && item.name === "SignalSubmitted",
    ) as AbiEvent | undefined;
    assert.ok(event, "artifact ABI must contain SignalSubmitted");

    assert.equal(SIGNAL_SUBMITTED_ABI.length, 1);
    assert.deepEqual(SIGNAL_SUBMITTED_ABI[0], event);
    assert.equal(SIGNAL_SUBMITTED_TOPIC, toEventHash(event));
  });

  it("mirrors the full forge artifact ABI verbatim", async () => {
    const artifact = await readForgeArtifact(artifactPath);
    assert.deepEqual(UVP_STATE_MACHINE_ARTIFACT_ABI, artifact.abi);
  });

  it("mirrors the identity registry forge artifact ABI verbatim", async () => {
    const artifact = await readForgeArtifact(identityRegistryArtifactPath);
    assert.deepEqual(IDENTITY_REGISTRY_ABI, artifact.abi);
  });

  it("mirrors the full file resource module forge artifact ABI verbatim", async () => {
    const artifact = await readForgeArtifact(fileResourceModuleArtifactPath);
    assert.deepEqual(FILE_RESOURCE_MODULE_ABI, artifact.abi);
  });

  it("keeps finalizePlan free of capability-table size-gate errors", async () => {
    // 前提钉住：两表 Merkle 化形态下能力表/绑定表无链上规模闸——
    // TooManySelectorBindings / TooManySignalCapabilities 若出现在
    // 主 ABI（或手写镜像）里，说明合约侧回到了枚举式注册，本包的
    // capabilitiesRoot 工具面随之失效，必须红。
    const stateMachineArtifact = await readForgeArtifact(artifactPath);
    const artifactErrorNames = stateMachineArtifact.abi
      .filter((item) => item.type === "error")
      .map((item) => item.name);
    for (const name of [
      "TooManySelectorBindings",
      "TooManySignalCapabilities",
    ]) {
      assert.equal(
        artifactErrorNames.includes(name),
        false,
        `${name} reappeared in the UVPStateMachine artifact ABI; the capability tables regressed to on-chain size gates`,
      );
      assert.equal(
        STATE_MACHINE_ABI.some(
          (item) =>
            typeof item !== "string" && item.name.startsWith("TooMany"),
        ),
        false,
        "handwritten ABI must not mirror capability-table size-gate errors",
      );
    }
    // finalizePlan 是单参数边界：表内容不再随 finalize 提交。
    const finalizePlan = stateMachineArtifact.abi.find(
      (item) => item.type === "function" && item.name === "finalizePlan",
    ) as { inputs: readonly unknown[] } | undefined;
    assert.ok(finalizePlan, "artifact ABI must contain finalizePlan");
    assert.equal(finalizePlan.inputs.length, 1);
  });

  it("keeps the handwritten frozen STATE_MACHINE_ABI a subset of the artifact ABI", async () => {
    const artifact = await readForgeArtifact(artifactPath);
    const artifactSignatures = new Set(
      artifact.abi.map((item) => abiSignature(item)),
    );
    const missing = STATE_MACHINE_ABI.filter(
      (item) => !artifactSignatures.has(abiSignature(item)),
    ).map((item) => abiSignature(item));
    assert.deepEqual(missing, []);
  });

  it("keeps handwritten ABI function outputs (names+types) pinned to the forge artifact", async () => {
    // 2609100124 L-3 / 2609100406 L-3：getHookStatus 第三个输出名曾手写为
    // exists（合约与 forge 生成物是 readyEmitted）。签名子集钉只比输入形
    // 状，输出名漂移必须单独钉——解码方按名取值会拿到 undefined。
    const artifact = await readForgeArtifact(artifactPath);
    const artifactOutputs = new Map(
      artifact.abi
        .filter((item) => item.type === "function")
        .map((item) => [
          `${(item as { name: string }).name}(${(item as { inputs?: readonly unknown[] }).inputs ?? []})`,
          item,
        ]),
    );
    const mismatches: string[] = [];
    for (const item of STATE_MACHINE_ABI) {
      if (typeof item === "string" || item.type !== "function") {
        continue;
      }
      const inputs = (item.inputs ?? []).map(abiInputType).join(",");
      const artifactItem = artifactOutputs.get(`${item.name}(${inputs})`) as
        | { outputs?: readonly { name?: string; type: string }[] }
        | undefined;
      if (artifactItem === undefined) {
        continue; // 已由 subset 钉覆盖
      }
      const handwritten = ((item as { outputs?: unknown }).outputs ?? []) as {
        name?: string;
        type: string;
      }[];
      const generated = artifactItem.outputs ?? [];
      // forge 对无名输出给 ""，human-readable ABI 无法表达名——缺名按 ""
      // 归一后比对（命名漂移才是要钉的缺陷，如 exists→readyEmitted）。
      const same =
        handwritten.length === generated.length &&
        handwritten.every(
          (output, index) =>
            (output.name ?? "") === (generated[index]?.name ?? "") &&
            abiInputType(output) === generated[index]?.type,
        );
      if (!same) {
        mismatches.push(
          `${item.name}: handwritten outputs ${JSON.stringify(handwritten)} != forge ${JSON.stringify(generated)}`,
        );
      }
    }
    assert.deepEqual(mismatches, []);
    // 直接钉 getHookStatus 的第三输出名（回归锚点）。
    const getHookStatus = STATE_MACHINE_ABI.find(
      (item) => typeof item !== "string" && item.name === "getHookStatus",
    ) as { outputs: readonly { name: string }[] } | undefined;
    assert.ok(getHookStatus, "handwritten ABI must keep getHookStatus");
    assert.deepEqual(getHookStatus.outputs.map((output) => output.name), [
      "status",
      "dueAt",
      "readyEmitted",
    ]);
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

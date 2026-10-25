#!/usr/bin/env tsx
/**
 * 生成承诺面跨语言金向量到 uvp-core/fixtures/commitments/golden-vectors.v1.json
 * （TS/Rust/Foundry 三侧消费）；运行 pnpm --filter @uvp-eth/compiler
 * generate:commitment-golden-vectors。
 */
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  canonicalStringify,
  compileZhixuHookPlan,
  compileZhixuOnchainHookPlan,
  definitionUid,
  hashSolidityRegisterHooks,
  toSolidityRegisterPlanArgs,
  type ExecutorCandidateInput,
  type SolidityRegisterHookArg,
  type SolidityRegisterInstructionArg,
  type SolidityRegisterPlanArgs,
  type ZhixuDefinition,
} from "../src/index.js";
import { hookPlanPayloadForHash } from "../src/dock-commitments.js";
import type { DockResolutionManifest, HexString } from "../src/types/index.js";
import {
  dockProductionTargetDefinition,
  dockSourcingParentDefinition,
  resolutionManifestFor,
} from "../test/dock-demo.js";
import { commitmentRegisterHooksArgs } from "../test/commitment-golden.js";

interface UidVector {
  readonly name: string;
  readonly note: string;
  readonly input: { readonly definition: unknown };
  readonly expected: { readonly uid: string };
}

interface GoldenInstruction {
  readonly op: number;
  readonly sourceId: HexString;
  readonly signalId: HexString;
  readonly arity: number;
  readonly delaySeconds: number;
}

interface GoldenHook {
  readonly hookId: HexString;
  readonly stageId: HexString;
  readonly hookName: HexString;
  readonly flags: number;
  readonly instructions: readonly GoldenInstruction[];
  readonly dependencyKeys: readonly HexString[];
}

interface CommitmentGoldenCase {
  readonly name: string;
  readonly note: string;
  readonly input: {
    readonly definition: ZhixuDefinition;
    readonly dockManifest?: DockResolutionManifest;
    readonly executorCandidates?: readonly ExecutorCandidateInput[];
    readonly hooks: readonly GoldenHook[];
  };
  readonly counts: {
    readonly hooks: number;
    readonly instructions: readonly number[];
    readonly dependencyKeys: readonly number[];
  };
  readonly preimages: {
    readonly hookPlanCanonical: string;
    readonly onchainPlanCanonical: string;
  };
  readonly expected: {
    readonly uid: string;
    readonly hookPlanHash: string;
    readonly onchainPlanHash: string;
    readonly runtimePlanHash: string;
    readonly hooksHash: string;
    readonly capabilitiesRoot: string;
    readonly dockRoutesRoot: string;
    readonly dockInterfaceRoot: string;
    readonly executorCandidatesRoot: string;
  };
}

interface RegisterHooksVector {
  readonly name: string;
  readonly note: string;
  readonly input: { readonly hooks: readonly GoldenHook[] };
  readonly counts: {
    readonly hooks: number;
    readonly instructions: readonly number[];
    readonly dependencyKeys: readonly number[];
  };
  readonly expected: { readonly hooksHash: string };
}

const ZERO_HASH = `0x${"0".repeat(64)}` as const;

function goldenInstruction(
  instruction: SolidityRegisterInstructionArg,
): GoldenInstruction {
  switch (instruction.op) {
    case "SIGNAL":
      return {
        op: 0,
        sourceId: instruction.sourceId,
        signalId: instruction.signalId,
        arity: 0,
        delaySeconds: 0,
      };
    case "NOT":
      return { op: 1, sourceId: ZERO_HASH, signalId: ZERO_HASH, arity: 0, delaySeconds: 0 };
    case "AND":
      return { op: 2, sourceId: ZERO_HASH, signalId: ZERO_HASH, arity: instruction.arity, delaySeconds: 0 };
    case "OR":
      return { op: 3, sourceId: ZERO_HASH, signalId: ZERO_HASH, arity: instruction.arity, delaySeconds: 0 };
    case "DELAY":
      return { op: 4, sourceId: ZERO_HASH, signalId: ZERO_HASH, arity: 0, delaySeconds: instruction.delaySeconds };
  }
}

function goldenHooks(
  hooks: readonly SolidityRegisterHookArg[],
): readonly GoldenHook[] {
  return hooks.map((hook) => ({
    hookId: hook.hookId,
    stageId: hook.stageId,
    hookName: hook.hookName,
    flags: hook.flags,
    instructions: hook.instructions.map(goldenInstruction),
    dependencyKeys: hook.dependencyKeys,
  }));
}

function countsOf(hooks: readonly GoldenHook[]) {
  return {
    hooks: hooks.length,
    instructions: hooks.map((hook) => hook.instructions.length),
    dependencyKeys: hooks.map((hook) => hook.dependencyKeys.length),
  };
}

function buildDefinitionCase(
  name: string,
  note: string,
  input: Omit<CommitmentGoldenCase["input"], "hooks">,
): CommitmentGoldenCase {
  const manifest = input.dockManifest;
  const plan = compileZhixuHookPlan(input.definition, manifest);
  const onchain = compileZhixuOnchainHookPlan(
    input.definition,
    manifest,
    input.executorCandidates,
  );
  const args: SolidityRegisterPlanArgs = toSolidityRegisterPlanArgs(onchain);
  const hooks = goldenHooks(args.hooks);
  const { planHash: _onchainHash, ...onchainPayload } = onchain;
  return {
    name,
    note,
    input: { ...input, hooks },
    counts: countsOf(hooks),
    preimages: {
      hookPlanCanonical: canonicalStringify(hookPlanPayloadForHash(plan)),
      onchainPlanCanonical: canonicalStringify(onchainPayload),
    },
    expected: {
      uid: plan.zhixuId,
      hookPlanHash: plan.planHash,
      onchainPlanHash: onchain.planHash,
      runtimePlanHash: args.planHash,
      hooksHash: args.hooksHash,
      capabilitiesRoot: args.capabilitiesRoot,
      dockRoutesRoot: args.dockRoutesRoot,
      dockInterfaceRoot: args.dockInterfaceRoot,
      executorCandidatesRoot: args.executorCandidatesRoot,
    },
  };
}

const demoManifest = resolutionManifestFor(dockProductionTargetDefinition());

const demoZhixu: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: { name: "demo_zhixu" },
  spec: {
    platform: { type: "cloud" },
    nucleation: { id: "core" },
    stages: [
      {
        name: "assign",
        source: "buyer",
        selectedStages: ["main"],
        receiveSignals: { PLACE: "buyer::assign.seed" },
        sendSignals: [{ name: "executor_selected" }, { name: "seed" }],
        executor: { supplierType: "organization", supplierID: "selector-org" },
      },
      {
        name: "main",
        source: "buyer",
        receiveSignals: {
          START: "buyer::assign.executor_selected",
          TIMEOUT: "buyer::(assign.executor_selected +5s) & ~main.cmp",
        },
        sendSignals: [{ name: "str" }, { name: "cmp" }, { name: "err" }],
        executor: {
          supplierType: "zhixu",
          zhixuExecutorConfig: {
            target: { zhixu: demoManifest.definitions[0]!.zhixu },
            interface: "production_service",
            order: { mode: "new" },
            inputMap: { START: "execute" },
            signalMap: { str: "started", cmp: "completed" },
          },
        },
      },
    ],
  },
};

const sharedKeyOrderZhixu: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: { name: "shared_key_order_demo" },
  spec: {
    platform: { type: "cloud" },
    nucleation: { id: "core" },
    stages: [{
      name: "stage",
      source: "buyer",
      receiveSignals: {
        FIRST: "buyer::stage.seed",
        SECOND: "buyer::stage.seed",
      },
      sendSignals: [{ name: "seed" }],
      executor: { supplierType: "organization", supplierID: "watcher-org" },
    }],
  },
};

const mintBirthZhixu: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: { name: "demo_zhixu" },
  spec: {
    platform: { type: "cloud" },
    nucleation: { id: "core" },
    stages: [
      {
        name: "assign",
        source: "buyer",
        receiveSignals: { PLACE: "buyer::assign.seed" },
        sendSignals: [{ name: "executor_selected" }, { name: "seed" }],
        executor: { supplierType: "organization", supplierID: "selector-org" },
      },
      {
        name: "main",
        source: "buyer",
        receiveSignals: { START: "buyer::assign.executor_selected" },
        sendSignals: [{ name: "str" }, { name: "cmp" }, { name: "err" }],
        executor: { supplierType: "organization", supplierID: "work-org" },
      },
      {
        name: "post",
        source: "buyer",
        receiveSignals: { PUBLISH: "buyer::post.seed" },
        sendSignals: [{ name: "posted" }, { name: "seed" }],
        executor: { supplierType: "organization", supplierID: "intake-exec" },
      },
      {
        name: "birth",
        source: "fulfiller",
        mint: "per-fact",
        receiveSignals: { BIRTH: "::ANCHOR(@buyer::post.posted)" },
        sendSignals: [{ name: "str" }, { name: "cmp" }, { name: "err" }],
        executor: { supplierType: "organization", supplierID: "fulfiller-exec" },
      },
    ],
  },
};

const admissionZhixu = (validWhen: string): ZhixuDefinition => ({
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: { name: "admission_demo" },
  spec: {
    platform: { type: "cloud" },
    nucleation: { id: "core" },
    stages: [
      {
        name: "gate",
        source: "buyer",
        receiveSignals: { BEGIN: "buyer::gate.seed" },
        sendSignals: [{ name: "seed" }, { name: "ready" }],
        executor: { supplierType: "organization", supplierID: "gate-org" },
      },
      {
        name: "work",
        source: "buyer",
        receiveSignals: { RUN: "buyer::gate.ready" },
        sendSignals: [
          { name: "cmp", validWhen: [validWhen] },
          { name: "cmp_err" },
        ],
        executor: { supplierType: "organization", supplierID: "work-org" },
      },
    ],
  },
});

const twoStageZhixu: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: { name: "candidates_blackbox" },
  spec: {
    platform: { type: "blockchain", provider: "eth" },
    nucleation: { id: "core_org" },
    stages: [
      {
        name: "main",
        source: "buyer",
        receiveSignals: { START: "buyer::main.kickoff" },
        sendSignals: [{ name: "str" }, { name: "cmp" }, { name: "kickoff" }],
        executor: { supplierType: "organization", supplierID: "patchable-org" },
      },
      {
        name: "deal",
        source: "trading",
        receiveSignals: { PLACE: "trading::deal.kickoff" },
        sendSignals: [{ name: "closed" }, { name: "kickoff" }],
        executor: { supplierType: "organization", supplierID: "trading-org" },
      },
    ],
  },
};

const birthZhixu: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: { name: "candidates_blackbox_birth" },
  spec: {
    platform: { type: "blockchain", provider: "eth" },
    nucleation: { id: "core_org" },
    stages: [
      {
        name: "main",
        source: "buyer",
        mint: "per-fact",
        receiveSignals: { ON_DEAL: "::ANCHOR(@trading::deal.closed)" },
        sendSignals: [{ name: "str" }, { name: "cmp" }],
        executor: { supplierType: "organization", supplierID: "birth-org" },
      },
      {
        name: "deal",
        source: "trading",
        receiveSignals: { PLACE: "trading::deal.kickoff" },
        sendSignals: [{ name: "closed" }, { name: "kickoff" }],
        executor: { supplierType: "organization", supplierID: "trading-org" },
      },
    ],
  },
};

const WALLET_A = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266" as const;
const WALLET_B = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8" as const;

const uidVectors: readonly UidVector[] = [
  {
    name: "minimal_cloud_definition",
    note: "最小云侧定义只钉 uid 派生（无 stage 不可编译，无承诺面格）",
    input: {
      definition: {
        apiVersion: "uvp/v0",
        kind: "Zhixu",
        metadata: { name: "weaving_order" },
        spec: { platform: { type: "cloud" } },
      },
    },
    expected: {
      uid: definitionUid({
        apiVersion: "uvp/v0",
        kind: "Zhixu",
        metadata: { name: "weaving_order" },
        spec: { platform: { type: "cloud" } },
      }),
    },
  },
];

const cases: readonly CommitmentGoldenCase[] = [
  buildDefinitionCase(
    "friction_wheel_production_target",
    "dock demo 目标定义（双具名接口发布方，无 zhixu 执行者）",
    { definition: dockProductionTargetDefinition() },
  ),
  buildDefinitionCase(
    "sourcing_parent_static_dock",
    "dock demo 父定义：new 模式生产委托 + existing 模式既有事实引用各一条 route（dockRoutesRoot 非空叶）",
    {
      definition: dockSourcingParentDefinition(demoManifest.definitions[0]!.zhixu),
      dockManifest: demoManifest,
    },
  ),
  buildDefinitionCase(
    "demo_zhixu_production_dock",
    "onchain-hook-plan / hook-plan 基座定义：main 以 zhixu 执行器委托 production_service[new]（mode=new 出生锚 + selectedStages 绑定表非空）",
    { definition: demoZhixu, dockManifest: demoManifest },
  ),
  buildDefinitionCase(
    "candidates_blackbox_two_stage",
    "候选集黑盒双阶段基座（blockchain/eth 平台，无候选集输入）",
    { definition: twoStageZhixu },
  ),
  buildDefinitionCase(
    "candidates_blackbox_with_candidates",
    "同上定义 + 两阶段候选集输入（executorCandidatesRoot 非 EMPTY）",
    {
      definition: twoStageZhixu,
      executorCandidates: [
        { stageIdentifier: "main", executor: WALLET_A },
        { stageIdentifier: "deal", executor: WALLET_B },
      ],
    },
  ),
  buildDefinitionCase(
    "candidates_blackbox_birth",
    "出生（mint）阶段形态 + deal 候选（出生阶段执行者终生不可变）",
    {
      definition: birthZhixu,
      executorCandidates: [
        { stageIdentifier: "deal", executor: WALLET_A },
      ],
    },
  ),
  buildDefinitionCase(
    "admission_demo_declared_valid_when",
    "发射适格面：declared validWhen 编译出 flags=8 admission 槽进 hooksHash",
    { definition: admissionZhixu("buyer::gate.seed & ~(work.cmp_err +14d)") },
  ),
  buildDefinitionCase(
    "admission_demo_bare_root_veto",
    "发射适格面：裸根否决（filter 档合法、hook 档非法的形态）",
    { definition: admissionZhixu("buyer::~(work.cmp_err +14d)") },
  ),
  buildDefinitionCase(
    "shared_key_order_demo",
    "同键双 hook 的 dependencyIndex calldata 序钉（keccak 序与 calldata 序分叉形态）",
    { definition: sharedKeyOrderZhixu },
  ),
  buildDefinitionCase(
    "mint_birth_subscription",
    "出生订阅（::ANCHOR）编译为 mint 触发 SIGNAL 钩子的多阶段形态",
    { definition: mintBirthZhixu },
  ),
];

const zeroWordFillHooks: readonly GoldenHook[] = [
  {
    hookId: "0x0000000000000000000000000000000000000000000000000000000000001001",
    stageId: "0x0000000000000000000000000000000000000000000000000000000000002001",
    hookName: "0x0000000000000000000000000000000000000000000000000000000000003001",
    flags: 5,
    instructions: [
      {
        op: 0,
        sourceId: "0x0000000000000000000000000000000000000000000000000000000000004001",
        signalId: "0x0000000000000000000000000000000000000000000000000000000000005001",
        arity: 0,
        delaySeconds: 0,
      },
      { op: 1, sourceId: ZERO_HASH, signalId: ZERO_HASH, arity: 0, delaySeconds: 0 },
      { op: 4, sourceId: ZERO_HASH, signalId: ZERO_HASH, arity: 0, delaySeconds: 30 },
    ],
    dependencyKeys: [
      "0x0000000000000000000000000000000000000000000000000000000000006001",
    ],
  },
  {
    hookId: "0x0000000000000000000000000000000000000000000000000000000000001002",
    stageId: "0x0000000000000000000000000000000000000000000000000000000000002002",
    hookName: "0x0000000000000000000000000000000000000000000000000000000000003002",
    flags: 0,
    instructions: [
      {
        op: 0,
        sourceId: "0x0000000000000000000000000000000000000000000000000000000000004002",
        signalId: "0x0000000000000000000000000000000000000000000000000000000000005002",
        arity: 0,
        delaySeconds: 0,
      },
      {
        op: 0,
        sourceId: "0x0000000000000000000000000000000000000000000000000000000000004001",
        signalId: "0x0000000000000000000000000000000000000000000000000000000000005001",
        arity: 0,
        delaySeconds: 0,
      },
      { op: 2, sourceId: ZERO_HASH, signalId: ZERO_HASH, arity: 2, delaySeconds: 0 },
      { op: 3, sourceId: ZERO_HASH, signalId: ZERO_HASH, arity: 2, delaySeconds: 0 },
    ],
    dependencyKeys: [
      "0x0000000000000000000000000000000000000000000000000000000000006002",
      "0x0000000000000000000000000000000000000000000000000000000000006001",
    ],
  },
];

const registerHooksVectors: readonly RegisterHooksVector[] = [
  {
    name: "register_hooks_zero_word_fill",
    note: "非 SIGNAL 指令的 sourceId/signalId 填 Solidity 零字、arity/delaySeconds 未用位填 0 的冻结向量（commitPlan 对 calldata 重算本哈希）",
    input: { hooks: zeroWordFillHooks },
    counts: countsOf(zeroWordFillHooks),
    expected: {
      hooksHash: hashSolidityRegisterHooks(
        commitmentRegisterHooksArgs(zeroWordFillHooks),
      ),
    },
  },
];

const fixture = {
  schemaVersion: "uvp.commitmentGoldenVectors.v1",
  note: "承诺面（uid/planHash/hooksHash）跨语言金向量：TS compiler（链轨权威，generate:commitment-golden-vectors 生成）、Rust uvp-ir（derive_definition_uid 逐格消费 uid，preimages 两格经自身 canonicalize + 域分隔 keccak 复算）、Foundry CommitmentGoldenVectors.t.sol（按格重建 CompactHook[] 重算 hooksHash 并经 UVPStateMachine.planRuntimeHash 复算 runtimePlanHash；preimages 两格按域分隔 + keccak 复算）三方对同一份文件对拍。改本文件必须同跑三侧测试。",
  uidVectors,
  cases,
  registerHooksVectors,
};

const fixturePath = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../../../../uvp-core/fixtures/commitments/golden-vectors.v1.json",
);
await mkdir(dirname(fixturePath), { recursive: true });
await writeFile(fixturePath, `${JSON.stringify(fixture, null, 2)}\n`, "utf8");
console.log(`wrote ${fixturePath}`);

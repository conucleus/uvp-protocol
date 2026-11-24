#!/usr/bin/env tsx
/**
 * 生成承诺面跨语言金向量到 uvp-core/fixtures/commitments/golden-vectors.v1.json
 * （TS/Rust/Foundry 三侧消费）；运行 pnpm --filter @uvp-eth/compiler
 * generate:commitment-golden-vectors。
 */
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { canonicalJson } from "@uvp-eth/canonical-json";
import {
  extractHookDependencies,
  parseHookExpression,
  type HookDependency,
  type HookExpressionAst,
} from "@uvp-eth/hook-core";
import {
  compileZhixuHookPlan,
  compileZhixuOnchainHookPlan,
  definitionUid,
  dockIdentity,
  hashSolidityRegisterHooks,
  keccak256Hex,
  toSolidityRegisterPlanArgs,
  type SupplierCandidateInput,
  type SolidityRegisterHookArg,
  type SolidityRegisterInstructionArg,
  type SolidityRegisterPlanArgs,
  type ZhixuDefinition,
} from "../src/index.js";
import { hookPlanPayloadForHash } from "../src/hook-plan/assemble.js";
import type { HexString } from "../src/types/index.js";
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
    readonly supplierCandidates?: readonly SupplierCandidateInput[];
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
    readonly supplierBindingsRoot: string;
    readonly supplierBindings: readonly GoldenSupplierBinding[];
  };
}

interface GoldenSupplierBinding {
  readonly stageId: HexString;
  readonly supplierId: HexString;
  readonly kind: 0 | 1;
}

interface DockAtomVector {
  readonly source: string;
  readonly sourceId: HexString;
  readonly stage: string;
  readonly stageId: HexString;
  readonly signal: string;
  readonly signalId: HexString;
  readonly targetOrderRelation: 0;
}

interface DockOutputVector {
  readonly signal: string;
  readonly signalId: HexString;
  readonly sourceId: HexString;
  readonly stageId: HexString;
  readonly targetOrderRelation: 0;
  readonly rawExpression: string;
  readonly ast: HookExpressionAst;
  readonly dependencies: readonly HookDependency[];
  readonly atoms: readonly DockAtomVector[];
}

interface DockVector {
  readonly name: string;
  readonly note: string;
  readonly input: {
    readonly dock: unknown;
    readonly from: ZhixuDefinition;
    readonly to: ZhixuDefinition;
  };
  readonly expected: {
    readonly dkid: string;
    readonly docHash: HexString;
    readonly from: {
      readonly zhixu: string;
      readonly source: string;
      readonly sourceId: HexString;
    };
    readonly to: {
      readonly zhixu: string;
      readonly stage: string;
      readonly stageId: HexString;
      readonly source: string;
      readonly sourceId: HexString;
    };
    readonly outputs: readonly DockOutputVector[];
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
  const plan = compileZhixuHookPlan(input.definition);
  const onchain = compileZhixuOnchainHookPlan(
    input.definition,
    input.supplierCandidates,
  );
  const args: SolidityRegisterPlanArgs = toSolidityRegisterPlanArgs(onchain);
  const hooks = goldenHooks(args.hooks);
  const { planHash: _onchainHash, triggers: _triggers, ...onchainPayload } = onchain;
  return {
    name,
    note,
    input: { ...input, hooks },
    counts: countsOf(hooks),
    preimages: {
      hookPlanCanonical: canonicalJson(hookPlanPayloadForHash(plan)),
      onchainPlanCanonical: canonicalJson(onchainPayload),
    },
    expected: {
      uid: plan.zhixuId,
      hookPlanHash: plan.planHash,
      onchainPlanHash: onchain.planHash,
      runtimePlanHash: args.planHash,
      hooksHash: args.hooksHash,
      capabilitiesRoot: args.capabilitiesRoot,
      supplierBindingsRoot: args.supplierBindingsRoot,
      supplierBindings: args.supplierBindings.map((binding) => ({
        stageId: binding.stageId,
        supplierId: binding.supplierId,
        kind: binding.kind,
      })),
    },
  };
}

const SUPPLIER_PATCHABLE = "5f0b1e2a-7c9d-4e1f-9a2b-000000000031";
const SUPPLIER_TRADING = "5f0b1e2a-7c9d-4e1f-9a2b-000000000032";
const SUPPLIER_BIRTH = "5f0b1e2a-7c9d-4e1f-9a2b-000000000033";
const SUPPLIER_ATELIER = "5f0b1e2a-7c9d-4e1f-9a2b-000000000034";
const SUPPLIER_ACCEPTOR = "5f0b1e2a-7c9d-4e1f-9a2b-000000000035";
const SUPPLIER_WATCHER = "5f0b1e2a-7c9d-4e1f-9a2b-000000000036";
const SUPPLIER_SELECTOR = "5f0b1e2a-7c9d-4e1f-9a2b-000000000037";
const SUPPLIER_WORK = "5f0b1e2a-7c9d-4e1f-9a2b-000000000038";
const SUPPLIER_INTAKE = "5f0b1e2a-7c9d-4e1f-9a2b-000000000039";
const SUPPLIER_FULFILLER = "5f0b1e2a-7c9d-4e1f-9a2b-00000000003a";
const SUPPLIER_GATE = "5f0b1e2a-7c9d-4e1f-9a2b-00000000003b";
const CANDIDATE_SUPPLIER_A = "5f0b1e2a-7c9d-4e1f-9a2b-00000000003c";
const CANDIDATE_SUPPLIER_B = "5f0b1e2a-7c9d-4e1f-9a2b-00000000003d";

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
      executor: { supplierType: "organization", supplierID: SUPPLIER_WATCHER },
    }],
  },
};

const triggerBirthZhixu: ZhixuDefinition = {
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
        executor: { supplierType: "organization", supplierID: SUPPLIER_SELECTOR },
      },
      {
        name: "main",
        source: "buyer",
        receiveSignals: { START: "buyer::assign.executor_selected" },
        sendSignals: [{ name: "str" }, { name: "cmp" }, { name: "err" }],
        executor: { supplierType: "organization", supplierID: SUPPLIER_WORK },
      },
      {
        name: "post",
        source: "buyer",
        receiveSignals: { PUBLISH: "buyer::post.seed" },
        sendSignals: [{ name: "posted" }, { name: "seed" }],
        executor: { supplierType: "organization", supplierID: SUPPLIER_INTAKE },
      },
      {
        name: "birth",
        source: "fulfiller",
        sendSignals: [{ name: "str", trigger: true }, { name: "cmp" }, { name: "err" }],
        executor: { supplierType: "organization", supplierID: SUPPLIER_FULFILLER },
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
        executor: { supplierType: "organization", supplierID: SUPPLIER_GATE },
      },
      {
        name: "work",
        source: "buyer",
        receiveSignals: { RUN: "buyer::gate.ready" },
        sendSignals: [
          { name: "cmp", validWhen: [validWhen] },
          { name: "cmp_err" },
        ],
        executor: { supplierType: "organization", supplierID: SUPPLIER_WORK },
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
        executor: { supplierType: "organization", supplierID: SUPPLIER_PATCHABLE },
      },
      {
        name: "deal",
        source: "trading",
        receiveSignals: { PLACE: "trading::deal.kickoff" },
        sendSignals: [{ name: "closed" }, { name: "kickoff" }],
        executor: { supplierType: "organization", supplierID: SUPPLIER_TRADING },
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
        sendSignals: [{ name: "str", trigger: true }, { name: "cmp" }],
        executor: { supplierType: "organization", supplierID: SUPPLIER_BIRTH },
      },
      {
        name: "deal",
        source: "trading",
        receiveSignals: { PLACE: "trading::deal.kickoff" },
        sendSignals: [{ name: "closed" }, { name: "kickoff" }],
        executor: { supplierType: "organization", supplierID: SUPPLIER_TRADING },
      },
    ],
  },
};

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
    "candidates_blackbox_two_stage",
    "候选集黑盒双阶段基座（blockchain/eth 平台，无候选集输入）",
    { definition: twoStageZhixu },
  ),
  buildDefinitionCase(
    "candidates_blackbox_with_candidates",
    "同上定义 + 两阶段候选 supplierID 输入（supplierBindingsRoot 含 kind=1 叶）",
    {
      definition: twoStageZhixu,
      supplierCandidates: [
        { stageIdentifier: "main", supplierID: CANDIDATE_SUPPLIER_A },
        { stageIdentifier: "deal", supplierID: CANDIDATE_SUPPLIER_B },
      ],
    },
  ),
  buildDefinitionCase(
    "candidates_blackbox_birth",
    "出生（trigger）阶段形态 + deal 候选（出生阶段执行者终生不可变，只带 default binding）",
    {
      definition: birthZhixu,
      supplierCandidates: [
        { stageIdentifier: "deal", supplierID: CANDIDATE_SUPPLIER_A },
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
    "trigger_birth_definition",
    "trigger 信号编译为 order-trigger SIGNAL 钩子（MINT 位）的多阶段形态",
    { definition: triggerBirthZhixu },
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

const dockFromDefinition: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: { name: "atelier_production" },
  spec: {
    platform: { type: "blockchain", provider: "eth" },
    nucleation: { id: "atelier-core" },
    stages: [
      {
        name: "produce",
        source: "atelier",
        receiveSignals: { START: "atelier::produce.seed" },
        sendSignals: [{ name: "str" }, { name: "err" }, { name: "seed" }],
        executor: { supplierType: "organization", supplierID: SUPPLIER_ATELIER },
      },
      {
        name: "settle",
        source: "atelier",
        receiveSignals: { CLOSE: "atelier::settle.close" },
        sendSignals: [{ name: "cmp" }, { name: "close" }],
        executor: { supplierType: "organization", supplierID: SUPPLIER_ATELIER },
      },
    ],
  },
};

const dockToDefinition: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: { name: "acceptor_intake" },
  spec: {
    platform: { type: "blockchain", provider: "eth" },
    nucleation: { id: "acceptor-core" },
    stages: [
      {
        name: "accept",
        source: "acceptor",
        receiveSignals: { CHECK: "acceptor::accept.check" },
        sendSignals: [{ name: "accepted" }, { name: "shipped" }, { name: "check" }],
        executor: { supplierType: "dock" },
      },
      {
        name: "gate",
        source: "acceptor",
        receiveSignals: { OPEN: "acceptor::gate.open" },
        sendSignals: [{ name: "open" }],
        executor: { supplierType: "organization", supplierID: SUPPLIER_ACCEPTOR },
      },
    ],
  },
};

function dockVector(
  name: string,
  note: string,
  signalMap: Readonly<Record<string, string>>,
): DockVector {
  const fromUid = definitionUid(dockFromDefinition);
  const toUid = definitionUid(dockToDefinition);
  const dock = {
    apiVersion: "uvp/v0",
    kind: "Dock",
    metadata: { name: "atelier_to_acceptor" },
    spec: {
      from: { zhixu: fromUid, source: "atelier" },
      to: { zhixu: toUid, stage: "accept" },
      signalMap,
    },
  };
  const identity = dockIdentity(dock);
  const parsedOf = (expression: string) => {
    const ast = parseHookExpression(`atelier::${expression}`);
    return { ast, dependencies: extractHookDependencies(ast) };
  };
  const atomsOf = (dependencies: readonly HookDependency[]): readonly DockAtomVector[] =>
    [...new Set(dependencies.map((dependency) => dependency.signalName))]
      .sort()
      .map((atom) => {
        const [stage, signal] = atom.split(".") as [string, string];
        return {
          source: "atelier",
          sourceId: keccak256Hex("atelier"),
          stage,
          stageId: keccak256Hex(stage),
          signal,
          signalId: keccak256Hex(atom),
          targetOrderRelation: 0 as const,
        };
      });
  return {
    name,
    note,
    input: {
      dock,
      from: dockFromDefinition,
      to: dockToDefinition,
    },
    expected: {
      dkid: identity.dkid,
      docHash: identity.docHash,
      from: {
        zhixu: fromUid,
        source: "atelier",
        sourceId: keccak256Hex("atelier"),
      },
      to: {
        zhixu: toUid,
        stage: "accept",
        stageId: keccak256Hex("accept"),
        source: "acceptor",
        sourceId: keccak256Hex("acceptor"),
      },
      outputs: Object.entries(signalMap)
        .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0))
        .map(([signal, expression]) => {
          const parsed = parsedOf(expression);
          return {
            signal,
            signalId: keccak256Hex(`accept.${signal}`),
            sourceId: keccak256Hex("acceptor"),
            stageId: keccak256Hex("accept"),
            targetOrderRelation: 0 as const,
            rawExpression: expression,
            ast: parsed.ast,
            dependencies: parsed.dependencies,
            atoms: atomsOf(parsed.dependencies),
          };
        }),
    },
  };
}

const dockVectors: readonly DockVector[] = [
  dockVector(
    "dock_atom_and_conjunction",
    "Dock ids + AST/dependencies 跨语言钉：单输出 AND 两原子 + 负向 atom",
    { accepted: "produce.str & settle.cmp & ~produce.err" },
  ),
  dockVector(
    "dock_multi_output_disjunction",
    "同一 Dock 多输出与 OR/延时表达式：每输出自己的 signalId/AST/dependencies，原子集按码点序",
    { accepted: "produce.str | settle.cmp", shipped: "produce.str & ~(produce.err +5s)" },
  ),
  dockVector(
    "dock_atom_positive_delay",
    "正向 +T：AST 为 delay，dependencies 出 positive+timer(delaySeconds)",
    { accepted: "produce.str & (settle.cmp +5s)" },
  ),
];

const fixture = {
  schemaVersion: "uvp.commitmentGoldenVectors.v3",
  note: "承诺面（uid/planHash/hooksHash）跨语言金向量：TS compiler（链轨权威，generate:commitment-golden-vectors 生成）、Rust uvp-ir（derive_definition_uid 逐格消费 uid，preimages 两格经自身 canonicalize + 域分隔 keccak 复算）、Foundry CommitmentGoldenVectors.t.sol（按格重建 CompactHook[] 重算 hooksHash 并经 UVPStateMachine.planRuntimeHash 复算 runtimePlanHash；preimages 两格按域分隔 + keccak 复算）三方对同一份文件对拍。改本文件必须同跑三侧测试。",
  uidVectors,
  cases,
  dockVectors,
  registerHooksVectors,
};

const fixturePath = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../../../../uvp-core/fixtures/commitments/golden-vectors.v1.json",
);
await mkdir(dirname(fixturePath), { recursive: true });
await writeFile(fixturePath, `${JSON.stringify(fixture, null, 2)}\n`, "utf8");
console.log(`wrote ${fixturePath}`);

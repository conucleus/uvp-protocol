import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  ExecutorCandidateInput,
  SolidityRegisterPlanArgs,
  ZhixuDefinition,
} from "../src/index.js";
import type { DockResolutionManifest, HexString } from "../src/types/index.js";

/**
 * 承诺面金向量（uvp-core/fixtures/commitments/golden-vectors.v1.json）的
 * TS 侧读取口：文件由本包 generate:commitment-golden-vectors 生成（链轨
 * 权威），Rust uvp-ir 与 Foundry CommitmentGoldenVectors.t.sol 消费同一份
 * ——测试经本模块直读，不保留同值内联副本。
 */

export interface CommitmentGoldenInstruction {
  readonly op: number;
  readonly sourceId: HexString;
  readonly signalId: HexString;
  readonly arity: number;
  readonly delaySeconds: number;
}

export interface CommitmentGoldenHook {
  readonly hookId: HexString;
  readonly stageId: HexString;
  readonly hookName: HexString;
  readonly flags: number;
  readonly instructions: readonly CommitmentGoldenInstruction[];
  readonly dependencyKeys: readonly HexString[];
}

export interface CommitmentGoldenCase {
  readonly name: string;
  readonly note: string;
  readonly input: {
    readonly definition: ZhixuDefinition;
    readonly dockManifest?: DockResolutionManifest;
    readonly executorCandidates?: readonly ExecutorCandidateInput[];
    readonly hooks: readonly CommitmentGoldenHook[];
  };
  readonly counts: {
    readonly hooks: number;
    readonly instructions: readonly number[];
    readonly dependencyKeys: readonly number[];
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

export interface CommitmentUidVector {
  readonly name: string;
  readonly note: string;
  /** uid 格定义不要求可编译（如最小云侧定义只参与身份派生对拍）。 */
  readonly input: { readonly definition: unknown };
  readonly expected: { readonly uid: string };
}

export interface CommitmentRegisterHooksVector {
  readonly name: string;
  readonly note: string;
  readonly input: { readonly hooks: readonly CommitmentGoldenHook[] };
  readonly counts: {
    readonly hooks: number;
    readonly instructions: readonly number[];
    readonly dependencyKeys: readonly number[];
  };
  readonly expected: { readonly hooksHash: string };
}

export interface CommitmentGoldenVectors {
  readonly schemaVersion: string;
  readonly note: string;
  readonly uidVectors: readonly CommitmentUidVector[];
  readonly cases: readonly CommitmentGoldenCase[];
  readonly registerHooksVectors: readonly CommitmentRegisterHooksVector[];
}

export const COMMITMENT_GOLDEN_VECTORS_PATH = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../../../../uvp-core/fixtures/commitments/golden-vectors.v1.json",
);

let cached: CommitmentGoldenVectors | undefined;

export function commitmentGoldenVectors(): CommitmentGoldenVectors {
  if (cached === undefined) {
    const parsed = JSON.parse(
      readFileSync(COMMITMENT_GOLDEN_VECTORS_PATH, "utf8"),
    ) as CommitmentGoldenVectors;
    if (parsed.schemaVersion !== "uvp.commitmentGoldenVectors.v1") {
      throw new Error(
        `commitment golden vectors schemaVersion drifted: ${parsed.schemaVersion}`,
      );
    }
    cached = parsed;
  }
  return cached;
}

export function commitmentGoldenCase(name: string): CommitmentGoldenCase {
  const found = commitmentGoldenVectors().cases.find(
    (candidate) => candidate.name === name,
  );
  if (!found) {
    throw new Error(`commitment golden case not found: ${name}`);
  }
  return found;
}

export function commitmentUidVector(name: string): CommitmentUidVector {
  const found = commitmentGoldenVectors().uidVectors.find(
    (candidate) => candidate.name === name,
  );
  if (!found) {
    throw new Error(`commitment uid vector not found: ${name}`);
  }
  return found;
}

export function commitmentRegisterHooksVector(
  name: string,
): CommitmentRegisterHooksVector {
  const found = commitmentGoldenVectors().registerHooksVectors.find(
    (candidate) => candidate.name === name,
  );
  if (!found) {
    throw new Error(`commitment register-hooks vector not found: ${name}`);
  }
  return found;
}

const ZERO_HASH = `0x${"0".repeat(64)}` as const;

/** 金向量数值化 hooks → SolidityRegisterPlanArgs["hooks"]（生成脚本与测试
 * 共用同一重建：SIGNAL 携 sourceId/signalId，其余指令槽由
 * hashSolidityRegisterHooks 按冻结口径填零字）。 */
export function commitmentRegisterHooksArgs(
  hooks: readonly CommitmentGoldenHook[],
): SolidityRegisterPlanArgs["hooks"] {
  return hooks.map((hook) => ({
    hookId: hook.hookId,
    stageId: hook.stageId,
    hookName: hook.hookName,
    kind: "receive",
    flags: hook.flags,
    instructions: hook.instructions.map((instruction) => {
      switch (instruction.op) {
        case 0:
          return {
            op: "SIGNAL",
            sourceId: instruction.sourceId,
            signalId: instruction.signalId,
            signalKey: ZERO_HASH,
          };
        case 1:
          return { op: "NOT" };
        case 2:
          return { op: "AND", arity: instruction.arity };
        case 3:
          return { op: "OR", arity: instruction.arity };
        default:
          return { op: "DELAY", delaySeconds: instruction.delaySeconds };
      }
    }),
    dependencyKeys: hook.dependencyKeys,
  }));
}

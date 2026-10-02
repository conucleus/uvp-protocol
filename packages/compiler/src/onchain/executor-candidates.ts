import { concat, keccak256 } from "viem";
import { keccakWord, merkleProof, merkleRoot } from "../dock.js";
import type {
  ExecutorCandidateInput,
  HexString,
  OnchainExecutorCandidate,
} from "../types/index.js";

/**
 * 执行者候选集树（executorCandidatesRoot，UB-36②③）的权威实现：ASSIGN
 * 收窄后逐单 executor patch 的目标 (stageId, executor) 必须命中计划承诺
 * 的候选集。叶公式与 UVPPlanRegistration._executorCandidatesRoot 逐字节
 * 一致——`keccak256(abi.encodePacked(UVP_EXECUTOR_CANDIDATE_V1 域字,
 * stageId, executor))`，注意地址以 20 字节紧凑形态进叶（84 字节 preimage，
 * 刻意不同于 keccakWords 的 32 字节 word 序列化）；建树沿用 DockMerkle
 * 排序去重口径（排序配对、奇数尾叶提升、空树 root = keccak256("")）。
 * 链上只存 root，成员资格由使用方按"重算叶 + 携 proof"验证；空候选集
 * root = EMPTY_MERKLE_ROOT，该形态下逐单 patch 恒拒（不开候选集的计划
 * 没有逐单换人面，fail-closed）。
 */

export const EXECUTOR_CANDIDATE_LEAF_DOMAIN = "UVP_EXECUTOR_CANDIDATE_V1";

export function executorCandidateLeaf(
  stageId: HexString,
  executor: HexString,
): HexString {
  return keccak256(
    concat([
      keccakWord(EXECUTOR_CANDIDATE_LEAF_DOMAIN),
      stageId,
      executor.toLowerCase() as HexString,
    ]),
  ) as HexString;
}

export function executorCandidatesRootOf(
  candidates: readonly { stageId: HexString; executor: HexString }[],
): HexString {
  return merkleRoot(candidates.map((c) => executorCandidateLeaf(c.stageId, c.executor)));
}

export function executorCandidateProof(
  candidates: readonly { stageId: HexString; executor: HexString }[],
  stageId: HexString,
  executor: HexString,
): HexString[] | undefined {
  return merkleProof(
    candidates.map((c) => executorCandidateLeaf(c.stageId, c.executor)),
    executorCandidateLeaf(stageId, executor),
  );
}

/** 候选集条目是否为合法输入形态：20 字节十六进制地址、非零。 */
export function isExecutorAddress(value: string): value is HexString {
  return /^0x[0-9a-fA-F]{40}$/.test(value) && !/^0x0{40}$/.test(value);
}

export interface CompiledExecutorCandidate {
  readonly candidates: readonly OnchainExecutorCandidate[];
  readonly root: HexString;
}

/**
 * 编译入口的候选集归一：输入按叶哈希去重后按 stageId → executor 字节序
 * 排序（同一 plan 唯一数组形态，planHash 与 calldata 都覆盖数组顺序；
 * 排序用裸字节序而非 localeCompare，与 merkleRoot 的叶排序同口径）。
 * 空输入产空集（root = EMPTY_MERKLE_ROOT）。
 */
export function normalizeExecutorCandidates(
  inputs: readonly ExecutorCandidateInput[],
  stageIdOf: (stageIdentifier: string) => HexString,
): readonly OnchainExecutorCandidate[] {
  const byLeaf = new Map<string, OnchainExecutorCandidate>();
  for (const input of inputs) {
    const stageId = stageIdOf(input.stageIdentifier);
    const candidate: OnchainExecutorCandidate = {
      stageIdentifier: input.stageIdentifier,
      stageId,
      executor: input.executor.toLowerCase() as HexString,
    };
    byLeaf.set(executorCandidateLeaf(candidate.stageId, candidate.executor), candidate);
  }
  return [...byLeaf.values()].sort((left, right) => {
    if (left.stageId !== right.stageId) {
      return left.stageId < right.stageId ? -1 : 1;
    }
    if (left.executor !== right.executor) {
      return left.executor < right.executor ? -1 : 1;
    }
    return 0;
  });
}

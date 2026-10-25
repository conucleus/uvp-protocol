import { concat, keccak256 } from "viem";
import { keccakWord, merkleProof, merkleRoot } from "../dock.js";
import type {
  ExecutorCandidateInput,
  HexString,
  OnchainExecutorCandidate,
} from "../types/index.js";

/**
 * 执行者候选集树（executorCandidatesRoot）权威实现：叶公式与
 * UVPPlanRegistration 逐字节一致；链上只存 root，成员资格携 proof 验证。
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

export function isExecutorAddress(value: string): value is HexString {
  return /^0x[0-9a-fA-F]{40}$/.test(value) && !/^0x0{40}$/.test(value);
}

export interface CompiledExecutorCandidate {
  readonly candidates: readonly OnchainExecutorCandidate[];
  readonly root: HexString;
}

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

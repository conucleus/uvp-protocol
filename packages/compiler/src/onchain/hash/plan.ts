import { hashCanonical } from "../../hash.js";
import type {
  HexString,
  OnchainHookPlanArtifact,
} from "../../types/index.js";

/**
 * OnchainHookPlan 的 planHash 承诺面：只覆盖提交面字段；birthChannel 由
 * compiledHooks 派生并在 artifact 边界重算校验，不进 preimage。
 */

const ONCHAIN_PLAN_HASH_DOMAIN = "uvp:onchain-hook-plan-artifact:v1";

export function hashOnchainPlanPayload(
  payload: Omit<OnchainHookPlanArtifact, "planHash">,
): HexString {
  const { birthChannel: _birthChannel, ...committed } = payload;
  return hashCanonical(ONCHAIN_PLAN_HASH_DOMAIN, committed);
}

import { hashCanonical } from "../../hash.js";
import type {
  HexString,
  OnchainHookPlanArtifact,
} from "../../types/index.js";

const ONCHAIN_PLAN_HASH_DOMAIN = "uvp:onchain-hook-plan-artifact:v1";

export function hashOnchainPlanPayload(
  payload: Omit<OnchainHookPlanArtifact, "planHash">,
): HexString {
  return hashCanonical(ONCHAIN_PLAN_HASH_DOMAIN, payload);
}

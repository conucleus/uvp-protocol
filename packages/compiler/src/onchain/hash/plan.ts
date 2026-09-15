import { hashCanonical } from "../../hash.js";
import type {
  HexString,
  OnchainHookPlanArtifact,
} from "../../types/index.js";

const ONCHAIN_PLAN_HASH_DOMAIN = "uvp:onchain-hook-plan-artifact:v1";

/**
 * Canonical payload hash of an on-chain HookPlan artifact. Exported so
 * golden-fixture maintainers can re-pin planHash values with the exact
 * production formula instead of transcribing them by hand.
 */
export function hashOnchainPlanPayload(
  payload: Omit<OnchainHookPlanArtifact, "planHash">,
): HexString {
  return hashCanonical(ONCHAIN_PLAN_HASH_DOMAIN, payload);
}

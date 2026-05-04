import type { HookPlanArtifact, SolanaHookPlanArtifact } from "./types/index.js";
import { UnsupportedChainTargetError } from "./unsupported-chain-target.js";

export function compileSolanaHookPlan(_hookPlanArtifact: HookPlanArtifact): SolanaHookPlanArtifact {
  throw new UnsupportedChainTargetError("solana", "solana HookPlan target is reserved but not implemented");
}

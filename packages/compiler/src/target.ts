import { compileEvmHookPlan } from "./onchain-hook-plan.js";
import { compileSolanaHookPlan } from "./solana-hook-plan.js";
import { UnsupportedChainTargetError } from "./unsupported-chain-target.js";
import type {
  ChainTarget,
  EvmHookPlanArtifact,
  HookPlanArtifact,
  SolanaHookPlanArtifact
} from "./types/index.js";

export interface CompileHookPlanForTargetOptions {
  readonly target: ChainTarget;
}

export type TargetHookPlanArtifact = EvmHookPlanArtifact | SolanaHookPlanArtifact;

export function compileHookPlanForTarget(
  hookPlanArtifact: HookPlanArtifact,
  options: CompileHookPlanForTargetOptions
): TargetHookPlanArtifact {
  switch (options.target) {
    case "evm":
      return compileEvmHookPlan(hookPlanArtifact);
    case "solana":
      return compileSolanaHookPlan(hookPlanArtifact);
  }
  throw new UnsupportedChainTargetError(String(options.target));
}

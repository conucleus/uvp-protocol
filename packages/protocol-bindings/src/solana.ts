import { UnsupportedChainTargetError } from "./unsupported-chain-target.js";

export { UnsupportedChainTargetError } from "./unsupported-chain-target.js";

export interface SolanaProgramIds {
  readonly stateMachineProgramId?: string;
  readonly trustRegistryProgramId?: string;
  readonly deploymentRegistryProgramId?: string;
}

export interface SolanaInstructionPlanPlaceholder {
  readonly target: "solana";
  readonly programIds: SolanaProgramIds;
  readonly TODO: "solana protocol bindings are reserved but not implemented";
}

export function unsupportedSolanaProtocolBinding(): never {
  throw new UnsupportedChainTargetError("solana", "solana protocol bindings are reserved but not implemented");
}

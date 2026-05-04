export class UnsupportedChainTargetError extends Error {
  readonly target: string;

  constructor(target: string, message = `${target} target is reserved but not implemented`) {
    super(message);
    this.name = "UnsupportedChainTargetError";
    this.target = target;
  }
}

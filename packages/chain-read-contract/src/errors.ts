// Typed failure for malformed chain read wire payloads; carries the JSON path
// of the first field that did not match the contract.
export class ChainReadContractError extends Error {
  override readonly name = "ChainReadContractError";
  readonly path: string;

  constructor(path: string, problem: string) {
    super(`chain read wire ${path}: ${problem}`);
    this.path = path;
  }
}

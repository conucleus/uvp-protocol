// Public surface of the chain read wire contract: DTOs, serialization rule,
// runtime decoders, and typed malformed-wire error.
export * from "./projections.js";
export { ChainReadContractError } from "./errors.js";
export { toWire, type Wire } from "./serialize.js";
export * from "./decode.js";

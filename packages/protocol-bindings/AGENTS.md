# AGENTS.md

## Module Purpose

`uvp-protocol/packages/protocol-bindings/` owns browser-safe UVP EVM protocol
bindings shared by services, executor tools, and participant apps.

## Responsibilities

- Export public ABI constants for current UVP contracts.
- Export EIP-712 typed-data definitions and builders for wallet-bound protocol
  actions.
- Export deterministic contract call builders for protocol calls such as
  `submitSignalFor`.
- Export browser-safe address, bytes32, canonical JSON, and evidence hash
  helpers.

## Non-Responsibilities

- Do not read env vars, private keys, files, databases, or network config.
- Do not request browser-wallet signatures or own EIP-1193 wallet UX.
- Do not run watchers, relayers, HTTP servers, Product APIs, or job stores.
- Do not import `uvp-chain-services`, `uvp-executor-kit`, `uvp-order-app`, or
  frontend apps.
- Do not decide business authorization or product task state.

## Testing Expectations

- Keep golden tests for EIP-712 type fields, ABI call args, and canonical hashes.
- Keep the package importable in browser-targeted builds.

# @uvp-eth/chain-read-contract

Neutral wire contract for chain-services' anonymous generic chain reads
(`GET /chain/orders`, `/chain/tasks`, `/chain/sync-state`, `/chain/snapshot`,
`/chain/plans/:planId/:planHash/admissions`,
`/chain/plans/:planId/:planHash/triggers`).

This package is the single owner of the chain read wire field names and JSON
value types. It defines no chain runtime, storage, or business rules:

- projection DTOs for orders, tasks, plans, deployments, modules, governance,
  docks, sync state, and the full projection snapshot;
- plan capability table DTOs carried on `ChainPlanProjection`;
- plan admission DTOs for `/chain/plans/:planId/:planHash/admissions`;
- plan trigger DTOs for `/chain/plans/:planId/:planHash/triggers`: each
  `ChainPlanTrigger` mirrors one order-trigger hook of the recorded plan
  artifact (`orderTriggerKind` `trigger` or `dock`, plus hookId, stage/signal
  identity), in artifact order;
- the serialization rule that every bigint field is a decimal string
  (`toWire`/`Wire<T>`);
- runtime guards, decoders, response-envelope parsers, and the typed
  `ChainReadContractError` used by `@uvp-eth/uvp-client/chain-read`.

`uvp-chain-services/service` serializes its internal indexer projections through
`toWire` and types `/chain/*` responses with these DTOs; `@uvp-eth/uvp-client/chain-read`
reads the same DTOs over HTTP and revives block numbers to bigint, and the used-car
backend's projection store consumes that view. Indexer-internal projection types stay in chain-services.

## Gates

```bash
cd uvp-protocol/packages/chain-read-contract
pnpm typecheck
pnpm test
```

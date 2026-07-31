# horizon-nest

A [nuthatch](https://github.com/nightswatchhq/nuthatch) nest indexing **The Graph Protocol Horizon**
staking activity on **Arbitrum One** — operators, allocations, delegations, per-indexer totals, and
daily/hourly aggregations — from three contracts, with a parity check against the community subgraph
it mirrors.

> Credit: the entity model mirrors PaulieB14's
> [horizon-indexer-subgraph](https://github.com/PaulieB14). This nest reproduces its semantics over
> nuthatch's SQL surface; where behaviour is genuinely ambiguous, the chosen semantics are documented
> here rather than silently matching a bug.

## Use it

```sh
nuthatch init --from https://github.com/nightswatchhq/horizon-nest
nuthatch dev --dir horizon-nest
# then, in another shell:
curl 'localhost:8288/sql?q=SELECT * FROM indexers ORDER BY CAST(rewards AS HUGEINT) DESC LIMIT 10'
```

The nest is self-contained: the three ABIs are vendored under `abis/` (frozen, so the decode
registry hash is stable) and nothing is resolved at consume time.

### Start blocks & archive RPC

Each contract's deployment block is vendored in `nuthatch.toml` (`staking` 42449585, `extension`
180370540, `service` 397492865), so `dev` backfills **full history from deployment** by default. That
requires an **archive** Arbitrum RPC — the public keyless endpoints in `nuthatch.toml` serve the tip
fine but not historical `eth_getLogs` over that range. Swap in your own archive endpoint (edit
`rpc_urls`) for a real backfill. To index only recent activity instead, clear the `start_block`s and
run `dev --backfill N`.

## Contracts (Arbitrum One)

| alias | contract | address |
|---|---|---|
| `staking`   | HorizonStaking   | `0x00669A4CF01450B64E8A2A20E9b1FCB71E61eF03` |
| `service`   | SubgraphService  | `0xb2Bb92d0DE618878E438b55D5846cfecD9301105` |
| `extension` | StakingExtension | `0x3bE385576d7C282070Ad91BF94366de9f9ba3571` |

Every declared event of each contract is decoded into a `{alias}__{event}` table. The derived
entities below are DuckDB views over those tables.

## Derived entities (`views/`)

| view | meaning |
|---|---|
| `operators` | current operator authorisations (latest `OperatorSet`, `allowed` only) |
| `allocations` | current state per allocation, folding Created / Resized / Closed (latest wins) |
| `delegations` | net delegated stake per (indexer, delegator) = Σ(delegated) − Σ(withdrawn) |
| `indexers` | per-indexer rewards, query fees, active allocation count |
| `rewards_daily` / `query_fees_daily` / `rewards_hourly` | time-bucketed rollups |
| `global` | one-row network totals |

Token amounts use nuthatch's derived `*_dec` DECIMAL columns, so they sum and compare as numbers
(base units, i.e. GRT × 10¹⁸).

Each view's meaning — and the footguns above — are declared in `semantic.toml`, so they surface through
nuthatch's `/schema` endpoint and the MCP `schema` tool: a coding agent gets the intent of every view,
not just its columns. This nest is nuthatch's reference for the authored semantic layer (RFC-0018 §1) —
a nest with a brain, in plain `nuthatch.toml` + SQL views, no bespoke authoring language.

## Freshness (honest tradeoff)

Derived views read **sealed (finalized) data**, so entities lag the tip by the finality window
(Arbitrum's `finalized` tag, ~10–20 min). Raw event tables (`service__allocation_created`, …) stay
tip-fresh via the hot path. This is fine for the analytics/dashboard consumer here; closing the gap
(registering hot rows into DuckDB per query) is a nuthatch follow-up, not this nest's concern.

## Parity (`checks/`)

`checks/*.sql` are queries whose results must match the source subgraph at a pinned block. To record
the expected fixtures against a fully-backfilled instance:

```sh
nuthatch check --dir horizon-nest --update   # records checks/expected/*.json from current results
nuthatch check --dir horizon-nest            # later runs compare against them; non-zero exit on drift
```

Comparisons are taken at a fixed block `B` that is sealed on this side and indexed on the subgraph's,
eliminating freshness skew. The fixtures are committed so `nuthatch check` runs hermetically in CI.

## Provenance

- Chain: Arbitrum One (42161). Finality: the node's L1-aware `finalized` tag.
- ABIs: resolved via Sourcify, vendored here and frozen.
- License: see the nuthatch project (AGPL-3.0 core).

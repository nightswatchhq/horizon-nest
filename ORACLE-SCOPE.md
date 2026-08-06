# What nuthatch can do for the Lodestar Oracle

Scoped 2026-08-06 against Arbitrum One at head 491,677,674. Every claim below was checked against
the chain or the code, and where it wasn't, it says so.

## Why this is worth doing at all

GRC-009's headline claim is "no operational dependency on any single team". That is **not currently
true of our own oracle.**

`foghorn-probe/src/allocations.rs` and `autodiscover.rs` fetch active allocations, indexer URLs and
deployment candidates from the network subgraph **through Edge & Node's gateway, using their API
key**. That is the critical path for paid probing: no allocation refresh means no `collection_id` to
bill, which means direct probing stops. If that key is revoked or the gateway stalls, the
independent oracle stops being independent.

The second gap is smaller but visible on the page: `avg_query_fee` and `total_query_fees` are
always null, and `/qos` says so in as many words.

Both are on-chain, event-shaped, and therefore nuthatch's exact shape.

## Why the old "nuthatch can't help" finding no longer applies

It was correct and narrowly scoped. V1's QoS oracle publishes via **DataEdge calldata** — a contract
call, not an event — plus IPFS payloads. nuthatch indexes events via `eth_getLogs` and deliberately
refuses call traces and storage diffs (`src/indexer.rs`: they need a colocated node per RFC-0003
ExEx and are not sourced from `debug_*` RPC). So it genuinely could not index the thing we were
mirroring.

We deleted the mirror on 2026-08-06. The constraint no longer describes what this oracle does.

## Verified available on-chain

Counts are from `eth_getLogs` over a 20,000-block window at head unless noted.

| What | Event | Contract | Firing | Nest status |
|---|---|---|---|---|
| Active allocation set | `AllocationCreated` / `AllocationResized` / `AllocationClosed` | SubgraphService | 329 closes, 1 create | **`allocations` view already written** (`views/20-allocations.sql`) |
| Realised query fees | `QueryFeesCollected(address,address,address,bytes32,uint256,uint256)` | SubgraphService | 110 | table `service__query_fees_collected` in schema |
| Indexing rewards | `IndexingRewardsCollected` | SubgraphService | 329 | in schema |
| Service payments | `ServicePaymentCollected` | SubgraphService | 439 | in schema |
| Stake claims | `StakeClaimLocked` / `Released` / `sReleased` | SubgraphService | 315 | in schema |
| **TAP settlement** | `PaymentCollected(uint8,bytes32,address,address,address,uint256)` | GraphTallyCollector | 110 | **contract not in the nest yet** |

SubgraphService `0xb2Bb92d0DE618878E438b55D5846cfecD9301105` — the same address our TAP receipts
already name as `data_service`. GraphTallyCollector `0x8f69F5C07477Ac46FBc491B1E6D91E2bb0111A9e` —
the same contract our receipts are signed against.

## Indexer service URLs — SOLVED, after a false negative

**Correction to the first version of this document**, which said URLs were not on-chain and that the
gateway dependency therefore could not be fully removed. That was wrong, and wrong for the same
reason described in the next section.

`ServiceProviderRegistered(address indexed serviceProvider, bytes data)` fires **139 times** across
SubgraphService history. The `data` blob is `abi.encode(string url, string geohash)`:

```
indexer 0xedca8740873152ff30a2696add66d1ab41882beb
  url     https://indexer1.subgraphs.riv-dev1.pinax.io/
  geohash f25dyhdh2
```

I had concluded "zero registrations, URLs are not on chain" from a public RPC that silently capped
the range and answered `[]`. Against an RPC that actually serves wide ranges, they are all there.

Two notes for the view that consumes this:

- **Latest-wins per indexer.** 139 registrations across roughly 60 indexers means operators
  re-register when their endpoint moves. The example above is `riv-dev1.pinax.io`, while the same
  indexer currently serves from `indexer1.subgraphs.pinax.network` — so an early registration is
  not the current URL. Fold these exactly as `views/20-allocations.sql` folds allocation events.
- A URL that is on-chain but stale is still a URL we will send paid probes to. If a probe fails
  against a registered endpoint, that is a real finding about the registration, not necessarily
  about the operator — worth distinguishing before it reaches a grade.

With this, **every input the oracle currently takes from Edge & Node's gateway is available from the
chain**: the allocation set, indexer URLs, and query fees. The gateway is then needed only for the
peer-comparison feed, which is deliberate.

## Trap found while scoping, which the nest work must respect

Public Arbitrum RPCs **silently cap wide `eth_getLogs` ranges and return `[]` rather than erroring.**
A 9M-block query returned zero for `AllocationCreated`, an event I had just watched fire. Chunked
100k-block windows over the same span returned 79, 4 and 397.

This is the "absent renders as healthy" failure in its purest form, and it nearly made me conclude
that indexers never register URLs on chain. A backfill run against a capped RPC would produce a nest
that reports itself synced and holds no data.

nuthatch already anticipates this — `nuthatch probe` exists to measure an endpoint's max `eth_getLogs`
width before trusting a backfill to it (`src/cli.rs`). **Run it before any backfill, and treat an
empty result over a wide range as a red flag rather than an answer.** The binary at
`~/.local/bin/nuthatch` predates the subcommand and does not have it yet; rebuild from HEAD.

Measured for the record. `https://petko-rpc.infradao.tech/arbitrum` serves `AllocationCreated` at
78 / 2,891 / 10,783 logs for 100k / 1M / 5M-block windows. `https://arb1.arbitrum.io/rpc` returns
**zero** for the same 5M window. Use the InfraDAO endpoint for this nest; the public one is not
merely slower, it is silently wrong.

## Proposed work, in value order

1. **Add GraphTallyCollector to this nest.** Gives TAP settlement — realised query fees per indexer
   from the chain, nobody self-reporting. This is the half GRC-009 said probing cannot produce, and
   it is currently unbuilt.
2. **Deploy the nest on a VPS.** Helsinki (89.167.109.4) is now empty — 114G free, all containers
   stopped — and already has Caddy fronting it.
3. **Point Foghorn's allocation sync at the nest** instead of the gateway — allocations AND URLs,
   both of which the nest can now serve.
4. **Fill `avg_query_fee` / `total_query_fees`** in `foghorn_qos` from `QueryFeesCollected`, and
   change the page's "always null, unmeasured" line to the real figure.
5. Optional: stake and provision data from the `staking` contract, replacing the Lodestar profile
   fetch that currently feeds `self_stake_grt` into scoring.

## What already exists and does not need writing

This nest is largely built. `nuthatch.toml` targets the three right contracts with correct start
blocks, `abis/` carries 31 SubgraphService events including every one listed above, and
`views/20-allocations.sql` already folds Created/Resized/Closed into a current-state `allocations`
view keyed exactly how `active_allocation` is keyed. `checks/` has parity queries against the
community subgraph.

The gap between here and useful is smaller than it looks: one contract to add, a deploy, and a
change of source in `allocations.rs`.

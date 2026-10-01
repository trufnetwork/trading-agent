# Finding: block sync is round-trip bound, 583x slower than necessary

**Measured 2026-09-17** on a node in the Northern Mariana Islands (UTC+10) syncing TN mainnet
(`tn-v2.1`) from peers in US/EU. kwild **v2.5.8**, embedding kwil-db
`v0.10.3-0.20260917021347-cf061288132e` — i.e. **with** the recent p2p and
statesync fixes (#1723, #1726, #1728, #1729).

## Symptom

State sync restored a snapshot at height 2,543,774, then began replaying
~68,000 blocks to reach the tip.

RESULT (run completed 2026-09-18 04:55 local):

```
CONS: Block sync completed {startHeight=2548249 endHeight=2614302
                            elapsed=9h15m3.6s}

66,053 blocks in 9h15m = 1.98 blocks/sec = 504 ms/block
```

**The instantaneous rate varies by ~5x** (0.41 to ~2 blocks/sec across 3-minute
windows). Always average over the full run. A 60-second sample taken at the
start of replay read 1.1 blocks/sec and was wrong by nearly 2x.

## Nothing local is the bottleneck

| Resource | Utilisation |
|----------|-------------|
| kwild CPU | 7.4% |
| Postgres CPU | 2% (493 MB RSS) |
| Disk (`sda`) | ~11% util |
| Peers connected | 6 |

A representative stretch of per-block log timing shows tens of ms executing
against most of a second waiting (this window was slower than the 542 ms
average):

```
19:00:33.237  PG: ...
              <-- 944 ms of silence
19:00:34.181  PG: ...
```

## Not a peer-failure regression

The obvious suspicion — that the peer-classification fixes caused the node to
try dead peers — is **ruled out by the logs**:

```
"block not available"      : 0
"unable to retrieve block" : 0
"no peers" / "failed to get": 0
```

Every peer answers on the first attempt. There is no retry storm.

*(Not fully excluded: a peer-**ordering** change causing preference for a more
distant peer would log nothing. A control node inside US/EU would settle it —
same rate means geography, faster means regression.)*

## Root cause: serial fetch, one stream per block, over a 200 ms link

`node/consensus/blocksync.go`:

```go
for height <= endHeight {
    ce.syncBlockWithRetry(ctx, height)   // fetch, THEN apply
    height++                              // no pipelining, no prefetch
}
```

One block per request, and `getBlk` walks peers sequentially. Measured RTT:

| Peer | RTT |
|------|-----|
| `3.17.146.5` (AWS us-east-2) | 194 ms |
| `135.181.29.50` (Hetzner) | 305 ms |

504 ms per block averaged over the full run ≈ 2-3 RTTs: stream setup plus transfer, paid per block.

## The damning arithmetic

**Blocks average 2.6 KB** (blockstore 1.6 MB after ~626 blocks; cap is
`max_block_size` = 6,291,456).

| | |
|---|---|
| Backlog from a fresh snapshot | ~68,000 blocks |
| × 2.6 KB | **≈ 177 MB** |
| Demonstrated throughput (snapshot: 3.2 GB in ~17 min) | ≈ 3.1 MB/s |
| Transfer time at that rate | **≈ 1 minute** |
| Actual elapsed at 504 ms/block | **9h 15m** |

The same links moved **18x more data** than the entire backlog, in 17 minutes.
The backlog took 583x longer than its own transfer time, purely because it is
requested 2.6 KB at a time, serially.

## Chunking a block would make it worse

Splitting a 2.6 KB payload adds round trips to a workload that is already
round-trip bound, not bandwidth bound. Per-block chunking already exists for
large blocks (`block_sync.idle_timeout`, "timeout between reading chunks of a
block") and is irrelevant at this size.

## Fix: batch blocks per request — the codebase already has the pattern

```
/kwil/snaprange/1.0.0   SnapshotChunkRangeReq{Height, Index, Offset, Length}   <- ranges
/kwil/snapchunk/1.1.0   + concurrent_chunk_fetchers = 5                        <- parallel
/kwil/blk/1.0.0         blockHashReq{Hash}                                     <- ONE block
```

State sync has range requests and parallel fetchers. Block sync has neither.
Adding `/kwil/blkrange/1.0.0` mirroring the snapshot protocol would let peers
that speak it batch, while others fall back — the `1.1.0` suffixes show
compatible protocol versioning is already practised here.

Projected, holding the measured 504 ms round trip, for 68,000 blocks:

| Blocks per request | Round trips | ETA |
|---|---|---|
| 1 *(today)* | 68,000 | **9h 15m, measured** |
| 50 | 1,360 | ~11 min |
| 100 | 680 | ~6 min |
| 500 | 136 | **~1 min** |

500 blocks is 1.3 MB — smaller than one snapshot chunk.

## Why it matters

This penalises every operator outside US/EU. A node in Asia-Pacific, South
America or Africa pays 200-300 ms per block where a US mainland node pays
~20 ms, so the same catch-up takes 9h 15m here.
That includes US territories: the node measured here sits in the Northern
Mariana Islands. It is a
structural barrier to geographic decentralisation of the validator/node set,
and the codebase already contains the solution in its state sync path.

## Workarounds for an operator today

1. **Let it run.** Unattended, 9h 15m measured.
2. **Sync near the peers** (US-east VPS, ~20 ms RTT) — roughly 10x faster, but
   the node is then not local.
3. **Wait for a newer snapshot.** Snapshots appear every 100k blocks
   (2,343,774 / 2,443,774 / 2,543,774). The next is ~31k blocks out ≈ 8 days.
   No help in the short term.

# Request retention after C9

Date: 2026-10-15. Local host: macOS arm64, OTP 29.1, Elixir 1.20.4,
10 schedulers. These values are local measurements, not service guarantees.

The workload writes a claim and completion for 100,000 unique IDs. Each result
contains its index and 256 bytes of text. The SQLite store uses WAL and FULL
synchronization. Each claim is recorded before execution. Completion is recorded
before acknowledgement. No transaction batch delays either boundary.

| Measure | Earlier ETS ledger | C9 private store |
| --- | ---: | ---: |
| Retained request IDs | 100,000 | 100,000 on disk |
| ETS rows in the resource table | 100,000 | 1 private locator |
| Resource-table ETS bytes | 24,807,416 | 2,552 |
| Cached request entries | 100,000 | 1,000 |
| Encoded cache bytes | Not separately bounded | 340,000 |
| SQLite allocator bytes, all connections in this VM | Not applicable | 2,231,136 |
| SQLite allocator peak bytes | Not applicable | 2,243,000 |
| Connection page-cache bytes | Not applicable | 2,155,184 |
| Connection schema bytes | Not applicable | 1,440 |
| Connection statement bytes during the probe | Not applicable | 6,080 |
| Database and WAL bytes | 0 | 45,072,080 |
| Claim and completion workload time | 0.254 s | 19.564 s |
| Cache-hit p50 / p95 / p99 | Below 1 / below 1 / below 1 µs | 1 / 2 / 6 µs |
| Disk-hit p50 / p95 / p99 | Not applicable | 23 / 77 / 149 µs |
| New-claim p50 / p95 / p99 | Below 1 / 1 / 3 µs | 69 / 140 / 227 µs |

The oldest exact result also passed replay after cache eviction and store-worker
replacement. The store path and Runtime lifetime remained the same. The memory
cache retained at most 1,000 entries and 16 MiB of encoded entry data. Large
entries can bypass the cache. Neither cache eviction nor age releases an ID.

The database cache setting is 2,048 KiB. SQLite's measured cache includes
allocation overhead. This setting does not bound connection, statement, result
buffer, journal, or all native memory. The measurement extension reads SQLite's
own allocator and connection counters. It runs only in the local benchmark;
production connections do not enable extension loading.

## BEAM memory

The earlier workload's total BEAM increase was 57,493,151 bytes. The C9 increase
was 101,015,718 bytes, or 100,529,014 after collecting the store processes.
These are whole-VM differences from separate cold runs. They include unrelated
code and application loading. C9 code memory alone increased from 20,893,068 to
77,129,306 bytes. Global ETS also includes tables outside request history.
Do not interpret these totals as the retained-history cost or claim a lower
overall BEAM total from this run.

The C9 store process reported 689,624 bytes and its database worker 8,896 bytes
before the extra collection. Encoded cache binaries are reported separately.
Raw BEAM categories, limits, latency samples, and SQLite counters are in
[the C9 result](benchmarks/c9-retention.json). The earlier values are in
[the baseline result](benchmarks/c9-retention-before.json).

## Repeat the check

From the monofolder, compile the local measurement extension:

```sh
clang -dynamiclib -Wall -Wextra -Werror \
  -I jido_chat/integration/deps/exqlite/c_src \
  jido_messaging/bench/request_memory_probe.c \
  -o jido_messaging/bench/request_memory_probe.dylib
```

From `jido_chat/integration`, run the pinned local graph:

```sh
MIX_OS_CONCURRENCY_LOCK=0 MIX_ENV=test JIDO_CHAT_PATH=.. \
JIDO_INTEGRATION_PROFILE=all JIDO_INTEGRATION_AI=0 \
mix run ../../jido_messaging/bench/request_retention.exs
```

The script writes `/tmp/jido-request-retention.json` through the system temporary
directory, then closes and removes its private history files. Set
`JIDO_RETENTION_REPORT` to choose a different output path. The shared library is
a local build artifact; do not commit it.

Disk use still grows with unique IDs. Resource values retain their existing
owner and TTL rules. C10 covers the second ledger in Runtime-created Chat
bindings. External bindings retain their own backend. Runtime or VM restart
ends replay history; this store is not a durable command log.

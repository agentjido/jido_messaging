# Outbound queue measurement

C5 measured the original partition before the C12 and C13 queue changes. The
C5 sections below are historical evidence. The C13 section gives the current
queue behavior.

## Workload

Run `scripts/outbound_queue_probe.exs` through the local Chat integration graph.
It uses a local adapter and sends no network messages. Set `JIDO_QUEUE_REPORT`
to a JSON output path. For example, from `jido_chat/integration`:

```sh
env MIX_ENV=test JIDO_CHAT_PATH=.. JIDO_INTEGRATION_PROFILE=all \
  JIDO_INTEGRATION_AI=0 JIDO_QUEUE_REPORT=/tmp/messaging-queue.json \
  mix run ../../jido_messaging/scripts/outbound_queue_probe.exs
```

The script runs three trials. Each trial uses one partition and internal queue
capacity two. A provider barrier holds the first send. One later call has a
20 ms caller timeout. Twelve other calls arrive while the provider is held.
The script checks that all 13 calls reached the mailbox, holds the provider
for another 100 ms, then releases it. Burst calls use high priority and are not
subject to low-priority shedding. The repeat explicitly disables pressure
shedding and throttle delays. This is a controlled latency test, not a
throughput benchmark.

The retry workload then fails once with `network_error`, waits 200 ms, and
succeeds on the second attempt. Another call arrives during that wait.
The script records its latency and the partition mailbox depth.

## Results and limits

Before extraction, all three trials had 13 pending dispatch calls in the
mailbox with capacity set to two. The twelve burst calls received `queue_full`
only after the provider was released. Their maximum rejection latency was
102.8–108.7 ms. The late caller timed out, but its provider send still completed.
Each trial produced two provider effects: the first send and that late send.

The repeated workload after extraction retained those functional results.
Final rejection latency was 102.9–109.6 ms. The call that arrived during the
200 ms retry wait took 202.1–203.6 ms to complete. Exact timings depend on scheduling
and are saved in the checkpoint JSON report.
No test asserts a percentile timing target. Functional tests use barriers and
check capacity, duplicate calls, provider-owner death, and uncertain outcomes.

The measurement establishes three limits:

* `queue_capacity` bounds the internal Erlang queue, not pending GenServer
  calls. A slow provider delays both admission and overload rejection.
* Provider calls, pressure throttle delays, and retry sleeps occupy the same
  partition. A later call cannot be admitted during a retry wait.
* A caller timeout does not cancel work. A queued send can still produce an
  external effect after the caller has stopped waiting. A lost reply does not
  prove that the provider did nothing.

The gateway retries only according to its existing classification. A typed
`request_outcome_unknown` contract error is fatal to that attempt and is not
automatically retried. A stable Chat request ID remains held while its binding
owner lives. Omitting that ID or restarting its owner removes this protection.
Transport errors retain their existing classification; they are not proof that
an external effect is absent. See [Runtime ownership](runtime-ownership.md).

## Decision for C5

Keep serialized execution and the existing supervisor strategy. The data shows
a real admission limit, but it does not establish a production traffic target
or safe cancellation contract. Do not add concurrency as part of extraction.

A later admission change must define a maximum admission latency and a bound
for mailbox plus queued plus active work. Keep one ordering owner per routing
key. Use monitored provider work and timer messages for retry waits only after
those contracts are agreed. Test slow providers, burst overload, caller and
provider deadlines, shutdown before and after an effect, and unknown outcomes.
Do not automatically release or retry an unknown send. Keep a separate test
for failed dependency recovery and the lifetime of request-ID tombstones.


## C13: capacity before mailbox submission

Run `bench/queue_admission.exs` through the same integration graph. Set
`JIDO_QUEUE_REPORT` to an output JSON path. The script sends no network messages.
It runs five trials with capacity 64, one held provider, and 10,000 simultaneous
prebuilt dispatch calls. Each trial admits 63 burst calls and rejects 9,937.
All rejections return before the provider is released. The barrier has 64
permits, 63 queued jobs, and no pending coordinator messages. Every trial drains
to zero permits. Accepted completion latency includes the held-provider wait.

The machine used macOS arm64, OTP 29.1, Elixir 1.20.4, and ten schedulers. The five
final trials measured rejection p95 at 0.226–1.736 ms and p99 at 0.337–4.884 ms.
All five pass the 50 ms p95 and 100 ms p99 targets. These are local measurement
gates, not production guarantees. The delayed-DeadLetter trial holds that process
through all rejections. It measured p95 0.440 ms and p99 0.964 ms. Its pending
record count stays at the configured bound of 5,000.

The initial cold run missed the target: first-trial p95 was 149.114 ms and p99
was 154.828 ms. Concurrent timestamp code loading caused this delay. Loading
DateTime and Calendar.ISO during DeadLetter startup removes this first-burst
wait. Both the original result and final trials are saved in
`benchmarks/c13-cold-before-fix.json` and `benchmarks/c13-queue.json`.

The repeated capacity-two C5 workload rejects all twelve overloads before
provider release. Maximum public rejection time is 2.313 ms, compared with C5's
102.9–109.6 ms after extraction. The accepted 20 ms caller timeout still sends
once. Retry uses two provider attempts; overload during its timer returns in
0.114 ms. Later accepted work waits 206.969 ms behind that retry and retains FIFO.

A separate test delays ConfigStore by 100 ms. Public total time is 103.976 ms;
a prebuilt admission call during the same delay takes 0.037 ms. Public request
construction still waits for configuration before it reaches admission. This
limit is explicit. Direct execution, ChatActions, Streaming, and Sender also
remain outside gateway admission. The bound does not cover arbitrary process
mailboxes or payload bytes. Runtime and VM restart end request replay retention.

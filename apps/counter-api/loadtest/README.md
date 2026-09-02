# Load testing counter-api at 5000 req/s

The request path is a lock-free read of a pre-serialized snapshot (`atomic.Pointer`),
so a single pod should sustain 5000 req/s well under 50 ms p95. These scripts prove it
without touching the public internet.

## 1. Start a deterministic origin

```bash
cd apps/counter-api
go run ./loadtest/stub-origin        # :9000, 200 absolute links => count 600 per URL
```

## 2. Start counter-api pointed at the stub (10 identical targets)

```bash
cd apps/counter-api
TARGET_URLS="$(printf 'http://localhost:9000,%.0s' {1..10} | sed 's/,$//')" \
  REFRESH_INTERVAL_SECONDS=30 \
  PORT=8080 \
  go run .
```

`GOMAXPROCS` defaults to the host core count. In Kubernetes set it to the CPU
limit (or add `go.uber.org/automaxprocs`) so the scheduler doesn't thrash.

## 3a. Drive load with the built-in generator (no install)

```bash
cd apps/counter-api
go run ./loadtest/loadgen                              # 5000 rps for 60s
go run ./loadtest/loadgen -rate 8000 -duration 30s -url http://localhost:8080
```

Open-model, self-correcting schedule: it launches `rate` requests/s regardless of
response speed. A server that can't keep up shows up as `dropped > 0` (the send
schedule slipped) and rising p99, not as a lowered send rate. Exit code is
non-zero if anything dropped or returned non-200.

Reference run (loopback, stub origin, i9-13900H): 5000 rps / 60s →
`dropped 0`, `errors 0`, `p95 ≈ 0.3 ms`, `p99 ≈ 1.2 ms`. Still 0 drops at
15000 rps.

## 3b. …or with k6

```bash
k6 run loadtest/k6.js
RATE=8000 DURATION=120s k6 run loadtest/k6.js
```

Thresholds in the script: `http_req_failed < 0.1%`, `p95 < 50 ms`,
`p99 < 150 ms`, `dropped_iterations == 0`.

## 3c. …or with vegeta

```bash
go install github.com/tsenart/vegeta/v12@latest   # if not installed
RATE=5000 DURATION=60s BASE_URL=http://localhost:8080 ./loadtest/vegeta.sh
```

## 4. In-process micro-benchmarks (no network, no OS sockets)

```bash
cd apps/counter-api
go test -run '^$' -bench 'BenchmarkGetTag|BenchmarkCountLinks' -benchmem
```

Reference numbers (i9-13900H, Go 1.26): `/v1/tags` cached path ≈ **460 ns/op,
10 allocs/op** → ~2M req/s per core in-process; the network stack, not the
handler, is the ceiling.

## Tuning knobs

| Env var | Default | Notes |
|---|---|---|
| `REFRESH_INTERVAL_SECONDS` | `60` | how often the background refresher re-fetches all targets |
| `HTTP_TIMEOUT_SECONDS` | `10` | per outbound fetch (refresh path only) |
| `TARGET_URLS` | 10 built-in sites | comma-separated |
| `PORT` | `8080` | |

## Watching the server under load

- `/healthcheck` stays 200 and cheap — it never touches the cache.
- The first few requests after boot may return `503 {"data":"cache warming up"}`
  until the initial synchronous refresh completes. `main` warms the cache before
  `ListenAndServe`, so in practice this only happens if the very first refresh
  times out.
- `GET /v1/cache/clear` triggers one out-of-band refresh; it returns immediately.

#!/usr/bin/env bash
# Sustained 5000 req/s with vegeta (https://github.com/tsenart/vegeta).
#
#   ./loadtest/vegeta.sh                       # 5000/s for 60s at localhost:8080
#   BASE_URL=http://host:8080 RATE=5000 DURATION=60s ./loadtest/vegeta.sh
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
RATE="${RATE:-5000}"
DURATION="${DURATION:-60s}"

targets="$(mktemp)"
trap 'rm -f "$targets"' EXIT

# ~90% list, ~10% single-id
for _ in $(seq 1 9); do echo "GET ${BASE_URL}/v1/tags"; done >>"$targets"
for i in $(seq 0 9); do echo "GET ${BASE_URL}/v1/tags/${i}"; done >>"$targets"

echo "attacking ${BASE_URL} at ${RATE}/s for ${DURATION}"
vegeta attack -targets="$targets" -rate="${RATE}/1s" -duration="${DURATION}" -keepalive=true \
  | tee /tmp/counter-api.vegeta.bin \
  | vegeta report -type=text

echo
echo "latency histogram:"
vegeta report -type='hist[0,1ms,2ms,5ms,10ms,25ms,50ms,100ms,250ms,500ms]' </tmp/counter-api.vegeta.bin

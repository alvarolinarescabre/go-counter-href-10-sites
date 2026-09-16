#!/usr/bin/env bash
# Run the in-cluster load test and stream its report.
#
#   ./run.sh
#   STEPS="2000 5000 10000" STEP_DURATION=3m ./run.sh
#   TARGET_URL=http://counter-api.counter-api.svc ./run.sh   # skip NLB/gateway
set -euo pipefail
cd "$(dirname "$0")"

NS=loadtest
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create configmap loadgen-src --from-file=main.go=../loadgen/main.go \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" delete job counter-api-loadtest --ignore-not-found >/dev/null

# A Job's pod template is immutable, so overrides go in before it is created.
overrides=()
for var in TARGET_URL STEPS STEP_DURATION WORKERS; do
  [ -n "${!var:-}" ] && overrides+=("$var=${!var}")
done
if [ ${#overrides[@]} -gt 0 ]; then
  kubectl set env --local -f job.yaml -o yaml "${overrides[@]}" | kubectl apply -f - >/dev/null
else
  kubectl apply -f job.yaml >/dev/null
fi

echo "waiting for the load generator pod (Karpenter may need to add a node)..."
kubectl -n "$NS" wait --for=condition=Ready pod -l app=counter-api-loadtest --timeout=10m >/dev/null
kubectl -n "$NS" logs -f job/counter-api-loadtest

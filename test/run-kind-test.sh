#!/usr/bin/env bash
# Local test on Kubernetes (kind) with the Datadog Helm chart.
# Requires: kind, kubectl, helm, docker.
#
#   ./run-kind-test.sh             local only (dummy API key), tags printed in the terminal
#   ./run-kind-test.sh --datadog   also send to Datadog, so it shows on the dashboard (env:cg-label-test)
#
# Creates its own kind cluster named cg-label-test. Never changes your current kubectl context.
set -euo pipefail
cd "$(dirname "$0")"
. ./common.sh

CLUSTER=cg-label-test
CTX="kind-$CLUSTER"
K=(kubectl --context "$CTX")
H=(helm --kube-context "$CTX")
trap restore_context EXIT

echo "== Mode: $MODE"
kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER"
restore_context   # kind create switches the current context. Put it back right away.

build_test_images
kind load docker-image --name "$CLUSTER" local/cg-derived:test local/cg-derived-override:test

"${K[@]}" create namespace workloads --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
until "${K[@]}" -n workloads get serviceaccount default >/dev/null 2>&1; do sleep 2; done
# Recreate the test pods so a rerun always runs the freshly built images.
"${K[@]}" -n workloads delete pod cg-direct cg-derived cg-derived-override control --ignore-not-found --wait=true >/dev/null
"${K[@]}" -n workloads apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: cg-direct}
spec: {containers: [{name: app, image: "cgr.dev/chainguard/nginx:latest"}]}
---
apiVersion: v1
kind: Pod
metadata: {name: cg-derived}
spec: {containers: [{name: app, image: "local/cg-derived:test", imagePullPolicy: Never}]}
---
apiVersion: v1
kind: Pod
metadata: {name: cg-derived-override}
spec: {containers: [{name: app, image: "local/cg-derived-override:test", imagePullPolicy: Never}]}
---
apiVersion: v1
kind: Pod
metadata: {name: control}
spec: {containers: [{name: app, image: "busybox:latest", command: ["sleep", "100000"]}]}
EOF

"${H[@]}" repo add datadog https://helm.datadoghq.com >/dev/null 2>&1 || true
"${H[@]}" repo update datadog >/dev/null
# The API key goes in through stdin, not the command line.
secret_result=$(printf '%s' "$DD_API_KEY" | "${K[@]}" create secret generic dd-api --from-file=api-key=/dev/stdin --dry-run=client -o yaml | "${K[@]}" apply -f -)
"${H[@]}" upgrade --install datadog datadog/datadog -f values-kind.yaml \
  --set datadog.site="$SITE" --wait --timeout 10m >/dev/null
if grep -q configured <<<"$secret_result"; then
  echo "== API key changed, restarting the Agent so it picks up the new key"
  "${K[@]}" rollout restart daemonset/datadog deployment/datadog-cluster-agent >/dev/null 2>&1 || true
  "${K[@]}" rollout status daemonset/datadog --timeout=5m >/dev/null
fi

"${K[@]}" -n workloads wait --for=condition=Ready pod --all --timeout=180s >/dev/null
echo "== Waiting for the Agent tagger to populate"; sleep 45

AGENT_POD=$("${K[@]}" get pods -l app=datadog -o jsonpath='{.items[0].metadata.name}')
OUT=$("${K[@]}" exec "$AGENT_POD" -c agent -- agent tagger-list)
echo "== Tags per workload pod (from the Agent's tagger)"
for p in cg-direct cg-derived cg-derived-override control; do
  id=$("${K[@]}" -n workloads get pod "$p" -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|.*://||')
  tags=$(printf '%s\n' "$OUT" | awk -v id="$id" '
    index($0, "container_id://" id) {f=1; next}
    f && /^=== Entity/ {f=0}
    f' | grep -Eo '(vendor|cg_image):[^] ,"]+' | sort -u | tr '\n' ' ' || true)
  printf '%-22s %s\n' "$p" "${tags:-<no vendor/cg_image tags>}"
done
mode_footer cg-label-test
echo
echo "Your kubectl context is unchanged (${ORIG_CONTEXT:-none}). To look at the test cluster: kubectl --context $CTX get pods -A"
echo "Tear down with: kind delete cluster --name $CLUSTER"

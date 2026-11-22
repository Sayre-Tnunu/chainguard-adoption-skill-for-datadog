#!/usr/bin/env bash
# Kubernetes/containerd version of the label test, using the Datadog Helm chart.
# Requires: kind, kubectl, helm, docker. Run ./run-docker-test.sh first (it builds the local test images).
#
#   ./run-kind-test.sh                          # dummy API key, local only
#   DD_API_KEY=<real key> ./run-kind-test.sh    # also ships metrics to your Datadog org
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER=cg-label-test
API_KEY="${DD_API_KEY:-00000000000000000000000000000000}"
SITE="${DD_SITE:-datadoghq.com}"

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER"
kubectl config use-context "kind-$CLUSTER" >/dev/null

docker image inspect local/cg-derived:test local/cg-derived-override:test >/dev/null
kind load docker-image --name "$CLUSTER" local/cg-derived:test local/cg-derived-override:test

kubectl create namespace workloads --dry-run=client -o yaml | kubectl apply -f - >/dev/null
until kubectl -n workloads get serviceaccount default >/dev/null 2>&1; do sleep 2; done
kubectl -n workloads apply -f - <<'EOF'
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

helm repo add datadog https://helm.datadoghq.com >/dev/null 2>&1 || true
helm repo update datadog >/dev/null
kubectl create secret generic dd-api --from-literal=api-key="$API_KEY" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install datadog datadog/datadog -f values-kind.yaml \
  --set datadog.site="$SITE" --wait --timeout 10m >/dev/null

kubectl -n workloads wait --for=condition=Ready pod --all --timeout=180s >/dev/null
echo "== Waiting for the Agent tagger to populate"; sleep 45

AGENT_POD=$(kubectl get pods -l app=datadog -o jsonpath='{.items[0].metadata.name}')
OUT=$(kubectl exec "$AGENT_POD" -c agent -- agent tagger-list)
echo "== Tags per workload pod (from the Agent's tagger)"
for p in cg-direct cg-derived cg-derived-override control; do
  id=$(kubectl -n workloads get pod "$p" -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|.*://||')
  tags=$(printf '%s\n' "$OUT" | awk -v id="$id" '
    index($0, "container_id://" id) {f=1; next}
    f && /^=== Entity/ {f=0}
    f' | grep -Eo '(vendor|cg_image):[^] ,"]+' | sort -u | tr '\n' ' ' || true)
  printf '%-22s %s\n' "$p" "${tags:-<no vendor/cg_image tags>}"
done
echo
echo "Tear down with: kind delete cluster --name $CLUSTER"

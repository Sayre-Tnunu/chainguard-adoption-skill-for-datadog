#!/usr/bin/env bash
# Datadog Operator version of the label test: installs the Operator on its own kind cluster,
# applies a DatadogAgent with spec.override.nodeAgent.env, and checks the tags.
# Run ./run-docker-test.sh first (it builds the local test images).
#
#   ./run-operator-test.sh                          # dummy API key, local only
#   DD_API_KEY=<real key> ./run-operator-test.sh    # also ships metrics to your Datadog org
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER=cg-operator-test
API_KEY="${DD_API_KEY:-00000000000000000000000000000000}"
SITE="${DD_SITE:-datadoghq.com}"

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER"
kubectl config use-context "kind-$CLUSTER" >/dev/null

docker image inspect local/cg-derived:test local/cg-derived-override:test >/dev/null
kind load docker-image --name "$CLUSTER" local/cg-derived:test local/cg-derived-override:test

helm repo add datadog https://helm.datadoghq.com >/dev/null 2>&1 || true
helm repo update datadog >/dev/null
helm upgrade --install datadog-operator datadog/datadog-operator --wait --timeout 5m >/dev/null
kubectl wait --for=condition=Established crd/datadogagents.datadoghq.com --timeout=120s >/dev/null
kubectl create secret generic datadog-secret --from-literal=api-key="$API_KEY" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# This is the block customers add. Everything else is a minimal DatadogAgent for kind.
kubectl apply -f - <<EOF
apiVersion: datadoghq.com/v2alpha1
kind: DatadogAgent
metadata:
  name: datadog
spec:
  global:
    clusterName: $CLUSTER
    site: $SITE
    tags: ["env:$CLUSTER"]
    credentials:
      apiSecret:
        secretName: datadog-secret
        keyName: api-key
    kubelet:
      tlsVerify: false
  override:
    nodeAgent:
      env:
        - name: DD_CONTAINER_LABELS_AS_TAGS
          value: '{"org.opencontainers.image.vendor":"vendor","dev.chainguard.image.title":"cg_image"}'
EOF

kubectl create namespace workloads --dry-run=client -o yaml | kubectl apply -f - >/dev/null
until kubectl -n workloads get serviceaccount default >/dev/null 2>&1; do sleep 2; done
kubectl -n workloads apply -f - >/dev/null <<'EOF'
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

echo "== Waiting for the Operator to create the node Agent"
for _ in $(seq 1 60); do kubectl get ds datadog-agent >/dev/null 2>&1 && break; sleep 5; done
kubectl rollout status daemonset/datadog-agent --timeout=5m
kubectl -n workloads wait --for=condition=Ready pod --all --timeout=180s >/dev/null
echo "== Waiting for the Agent tagger to populate"; sleep 45

echo "== Effective setting"
kubectl exec ds/datadog-agent -c agent -- agent config | grep -A1 '^container_labels_as_tags'

OUT=$(kubectl exec ds/datadog-agent -c agent -- agent tagger-list)
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

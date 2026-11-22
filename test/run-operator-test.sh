#!/usr/bin/env bash
# Local test on Kubernetes (kind) with the Datadog Operator: installs the Operator on its own kind
# cluster, applies a DatadogAgent with spec.override.nodeAgent.env, and checks the tags.
# Requires: kind, kubectl, helm, docker.
#
#   ./run-operator-test.sh             local only (dummy API key), tags printed in the terminal
#   ./run-operator-test.sh --datadog   also send to Datadog, so it shows on the dashboard (env:cg-operator-test)
#
# Creates its own kind cluster named cg-operator-test. Never changes your current kubectl context.
set -euo pipefail
cd "$(dirname "$0")"
. ./common.sh

CLUSTER=cg-operator-test
CTX="kind-$CLUSTER"
K=(kubectl --context "$CTX")
H=(helm --kube-context "$CTX")
trap restore_context EXIT

echo "== Mode: $MODE"
kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER"
restore_context   # kind create switches the current context. Put it back right away.

build_test_images
kind load docker-image --name "$CLUSTER" local/cg-derived:test local/cg-derived-override:test

"${H[@]}" repo add datadog https://helm.datadoghq.com >/dev/null 2>&1 || true
"${H[@]}" repo update datadog >/dev/null
"${H[@]}" upgrade --install datadog-operator datadog/datadog-operator --wait --timeout 5m >/dev/null
"${K[@]}" wait --for=condition=Established crd/datadogagents.datadoghq.com --timeout=120s >/dev/null
# The API key goes in through stdin, not the command line.
secret_result=$(printf '%s' "$DD_API_KEY" | "${K[@]}" create secret generic datadog-secret --from-file=api-key=/dev/stdin --dry-run=client -o yaml | "${K[@]}" apply -f -)

# This is the block customers add. Everything else is a minimal DatadogAgent for kind.
"${K[@]}" apply -f - >/dev/null <<EOF
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

echo "== Waiting for the Operator to create the node Agent"
for _ in $(seq 1 60); do "${K[@]}" get ds datadog-agent >/dev/null 2>&1 && break; sleep 5; done
"${K[@]}" rollout status daemonset/datadog-agent --timeout=5m >/dev/null
if grep -q configured <<<"$secret_result"; then
  echo "== API key changed, restarting the Agent so it picks up the new key"
  "${K[@]}" rollout restart daemonset/datadog-agent deployment/datadog-cluster-agent >/dev/null 2>&1 || true
  "${K[@]}" rollout status daemonset/datadog-agent --timeout=5m >/dev/null
fi
"${K[@]}" -n workloads wait --for=condition=Ready pod --all --timeout=180s >/dev/null
echo "== Waiting for the Agent tagger to populate"; sleep 45

echo "== Effective setting"
"${K[@]}" exec ds/datadog-agent -c agent -- agent config | grep -A2 '^container_labels_as_tags'

OUT=$("${K[@]}" exec ds/datadog-agent -c agent -- agent tagger-list)
echo "== Tags per workload pod (from the Agent's tagger)"
for p in cg-direct cg-derived cg-derived-override control; do
  id=$("${K[@]}" -n workloads get pod "$p" -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|.*://||')
  tags=$(printf '%s\n' "$OUT" | awk -v id="$id" '
    index($0, "container_id://" id) {f=1; next}
    f && /^=== Entity/ {f=0}
    f' | grep -Eo '(vendor|cg_image):[^] ,"]+' | sort -u | tr '\n' ' ' || true)
  printf '%-22s %s\n' "$p" "${tags:-<no vendor/cg_image tags>}"
done
mode_footer "$CLUSTER"
echo
echo "Your kubectl context is unchanged (${ORIG_CONTEXT:-none}). To look at the test cluster: kubectl --context $CTX get pods -A"
echo "Tear down with: kind delete cluster --name $CLUSTER"

#!/usr/bin/env bash
# Check that a running Datadog Agent in Kubernetes picked up the label mapping and is tagging containers.
# Usage: verify-agent.sh [namespace] [daemonset]
# Defaults come from the skill config (AGENT_NAMESPACE, AGENT_DAEMONSET), else datadog / datadog.
# Helm chart: the DaemonSet is named after the release. Datadog Operator: <DatadogAgent name>-agent.
set -uo pipefail
. "$(dirname "$0")/config.sh"
NS=${1:-$AGENT_NAMESPACE}
DS=${2:-$AGENT_DAEMONSET}

if ! kubectl -n "$NS" get "daemonset/$DS" >/dev/null 2>&1; then
  echo "DaemonSet $NS/$DS not found in context $(kubectl config current-context 2>/dev/null)."
  echo "Datadog DaemonSets in this cluster:"
  kubectl get ds -A 2>/dev/null | grep -i datadog || echo "  (none found)"
  exit 1
fi

echo "== Agent DaemonSet $NS/$DS (context $(kubectl config current-context))"
kubectl -n "$NS" rollout status "daemonset/$DS" --timeout=30s || exit 1

cfg_all=$(kubectl -n "$NS" exec "ds/$DS" -c agent -- agent config 2>/dev/null)
echo; echo "== Effective setting (expect vendor and cg_image mappings)"
cfg=$(grep -A3 '^container_labels_as_tags' <<<"$cfg_all")
if [ -z "$cfg" ] || ! grep -q 'dev.chainguard.image.title' <<<"$cfg"; then
  echo "MISSING: container_labels_as_tags does not map dev.chainguard.image.title."
  echo "Set DD_CONTAINER_LABELS_AS_TAGS on the Agent and roll it out."
  exit 1
fi
echo "$cfg"
grep -A3 '^docker_labels_as_tags' <<<"$cfg_all" | grep -qE 'vendor|cg_image' \
  && echo "WARNING: DD_DOCKER_LABELS_AS_TAGS (legacy) is also set. If it maps the same label it overrides the new setting."

echo; echo "== Tags on containers seen by one Agent pod (counts)"
kubectl -n "$NS" exec "ds/$DS" -c agent -- agent tagger-list 2>/dev/null \
  | grep -Eo '(cg_image|vendor):[^] ,]+' | sort | uniq -c | sort -rn
echo
echo "Each node runs its own Agent. If no cg_image tags appear, exec into a pod on a node that runs a Chainguard container:"
echo "  kubectl -n $NS get pods -o wide | grep $DS"
echo "  kubectl -n $NS exec <pod> -c agent -- agent tagger-list | grep cg_image"

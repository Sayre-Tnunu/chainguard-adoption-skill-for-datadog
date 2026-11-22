#!/usr/bin/env bash
# Check that a running Datadog Agent in Kubernetes picked up the label mapping and is tagging containers.
# Usage: verify-agent.sh [namespace] [daemonset] [context]
# Defaults come from the skill config (AGENT_NAMESPACE, AGENT_DAEMONSET, KUBE_CONTEXT).
# With no context configured, it uses your current kubectl context.
# Helm chart: the DaemonSet is named after the release. Datadog Operator: <DatadogAgent name>-agent.
# Read-only: it needs get on daemonsets and pods, and create on pods/exec, in the Agent namespace.
set -uo pipefail
. "$(dirname "$0")/config.sh"
NS=${1:-$AGENT_NAMESPACE}
DS=${2:-$AGENT_DAEMONSET}
CTX=${3:-${KUBE_CONTEXT:-}}

CURRENT=$(kubectl config current-context 2>/dev/null || true)
if [ -n "$CTX" ]; then
  kubectl config get-contexts -o name 2>/dev/null | grep -qx "$CTX" \
    || { echo "kubectl context '$CTX' not found. Available contexts:"; kubectl config get-contexts -o name; exit 1; }
  K=(kubectl --context "$CTX")
  [ "$CTX" != "$CURRENT" ] && echo "Note: checking context $CTX (your current context is ${CURRENT:-none} and is left unchanged)."
else
  [ -n "$CURRENT" ] || { echo "No current kubectl context. Log in to your cluster or set KUBE_CONTEXT."; exit 1; }
  CTX=$CURRENT
  K=(kubectl)
fi

if ! "${K[@]}" -n "$NS" get "daemonset/$DS" >/dev/null 2>&1; then
  echo "DaemonSet $NS/$DS not found in context $CTX."
  echo "Datadog DaemonSets in this cluster:"
  "${K[@]}" get ds -A 2>/dev/null | grep -i datadog || echo "  (none found, or no permission to list DaemonSets)"
  exit 1
fi

echo "== Agent DaemonSet $NS/$DS (context $CTX)"
"${K[@]}" -n "$NS" rollout status "daemonset/$DS" --timeout=30s || exit 1

if ! cfg_all=$("${K[@]}" -n "$NS" exec "ds/$DS" -c agent -- agent config 2>&1); then
  if grep -qi 'forbidden' <<<"$cfg_all"; then
    echo "Your account cannot exec into pods in $NS (RBAC forbids pods/exec), so the Agent cannot be checked from here."
    echo "Ask a cluster admin to run this check, or confirm in Datadog instead: group container.cpu.usage by cg_image."
  else
    echo "Could not run 'agent config' in the Agent pod: $(tail -1 <<<"$cfg_all")"
  fi
  exit 1
fi
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
"${K[@]}" -n "$NS" exec "ds/$DS" -c agent -- agent tagger-list 2>/dev/null \
  | grep -Eo '(cg_image|vendor):[^] ,]+' | sort | uniq -c | sort -rn
echo
echo "Each node runs its own Agent. If no cg_image tags appear, exec into a pod on a node that runs a Chainguard container:"
echo "  ${K[*]} -n $NS get pods -o wide | grep $DS"
echo "  ${K[*]} -n $NS exec <pod> -c agent -- agent tagger-list | grep cg_image"

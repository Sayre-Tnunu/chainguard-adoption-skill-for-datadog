#!/usr/bin/env bash
# Non-secret settings for the chainguard-adoption skill, stored in one file:
#   ~/.config/chainguard-adoption/config.env   (override with CGA_CONFIG)
#
# Usage:
#   config.sh show                 print current settings
#   config.sh set KEY VALUE        set one setting (creates the file if needed)
#   config.sh path                 print the config file path
#   source config.sh               (from other scripts) load settings with defaults
#
# Settings:
#   CG_ORG           Chainguard organization name, as in cgr.dev/<CG_ORG>/python
#   CG_REGISTRY      Where images are pulled from. Default cgr.dev/<CG_ORG>. Set to a mirror path if
#                    images come through Artifactory, Nexus, Harbor or similar.
#   DD_SITE          Datadog site: datadoghq.com, datadoghq.eu, us3.datadoghq.com, us5.datadoghq.com,
#                    ap1.datadoghq.com, ap2.datadoghq.com, ddog-gov.com
#   DD_ORG_NAME      Datadog organization name (used to confirm you are pointed at the right account)
#   AGENT_DEPLOY     helm | operator | docker | ecs | none
#   AGENT_NAMESPACE  Kubernetes namespace of the Datadog Agent
#   AGENT_DAEMONSET  Agent DaemonSet name (Helm: release name, Operator: <DatadogAgent name>-agent)
#   DD_ENV           Value of the env tag to scope checks to (optional)
#   DD_KEYS_FILE     Secret API and application keys file. Default ~/.config/datadog/keys.env

CGA_CONFIG="${CGA_CONFIG:-$HOME/.config/chainguard-adoption/config.env}"
CGA_KEYS=(CG_ORG CG_REGISTRY DD_SITE DD_ORG_NAME AGENT_DEPLOY AGENT_NAMESPACE AGENT_DAEMONSET DD_ENV DD_KEYS_FILE)

cga_load() {
  # shellcheck disable=SC1090
  [ -r "$CGA_CONFIG" ] && { set -a; . "$CGA_CONFIG"; set +a; }
  : "${CG_REGISTRY:=${CG_ORG:+cgr.dev/$CG_ORG}}"
  : "${DD_SITE:=datadoghq.com}"
  : "${AGENT_DEPLOY:=helm}"
  : "${AGENT_NAMESPACE:=datadog}"
  if [ -z "${AGENT_DAEMONSET:-}" ]; then
    [ "$AGENT_DEPLOY" = operator ] && AGENT_DAEMONSET=datadog-agent || AGENT_DAEMONSET=datadog
  fi
  : "${DD_KEYS_FILE:=$HOME/.config/datadog/keys.env}"
  DD_KEYS_FILE="${DD_KEYS_FILE/#\~/$HOME}"
}

# When sourced, just load. When executed, act as a CLI.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then cga_load; return 0; fi

set -euo pipefail
case "${1:-show}" in
  path) echo "$CGA_CONFIG" ;;
  show)
    [ -r "$CGA_CONFIG" ] || echo "(no config file yet at $CGA_CONFIG, showing defaults)"
    cga_load
    for k in "${CGA_KEYS[@]}"; do printf '%-16s %s\n' "$k" "${!k:-<unset>}"; done
    ;;
  set)
    k="${2:?usage: config.sh set KEY VALUE}"; v="${3-}"
    printf '%s\n' "${CGA_KEYS[@]}" | grep -qx "$k" || { echo "Unknown key $k. Valid: ${CGA_KEYS[*]}"; exit 1; }
    case "$k" in DD_API_KEY|DD_APP_KEY) echo "Keys do not belong here. Put them in the keys file."; exit 1 ;; esac
    [[ "$v" =~ ^[A-Za-z0-9._:/@~+-]*$ ]] || { echo "Value for $k has characters that are not allowed: $v"; exit 1; }
    mkdir -p "$(dirname "$CGA_CONFIG")"; touch "$CGA_CONFIG"
    tmp=$(mktemp); grep -v "^$k=" "$CGA_CONFIG" > "$tmp" || true; echo "$k=$v" >> "$tmp"; mv "$tmp" "$CGA_CONFIG"
    echo "$k=$v"
    ;;
  *) sed -n '2,23p' "$0"; exit 1 ;;
esac

#!/usr/bin/env bash
# Create, update and check the "Chainguard Adoption (Runtime)" dashboard through the Datadog API.
#
# Keys come from a file that only you can read (never pass them on the command line):
#   DD_KEYS_FILE from the skill config, default ~/.config/datadog/keys.env   (chmod 600)
#     DD_API_KEY=...
#     DD_APP_KEY=...
#     DD_SITE=datadoghq.com        (optional here, the skill config DD_SITE is used otherwise)
#
# Usage:
#   dd-dashboard.sh init-keys          create the keys file with safe permissions (you fill in values)
#   dd-dashboard.sh validate           check the keys and show which Datadog org they belong to
#   dd-dashboard.sh create             POST the dashboard, print its URL, remember its id
#   dd-dashboard.sh update [id]        PUT the dashboard JSON to an existing id (default: remembered id)
#   dd-dashboard.sh check [env]        live counts: Chainguard, non-Chainguard, total, adoption %
set -euo pipefail
. "$(dirname "$0")/config.sh"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DASH="${DASHBOARD_JSON:-$HERE/assets/dashboard.json}"
KEYS="$DD_KEYS_FILE"
STATE="$(dirname "$CGA_CONFIG")/dashboard-id"

usage() { sed -n '2,16p' "$0"; exit 1; }

load_keys() {
  [ -r "$KEYS" ] || { echo "No keys file at $KEYS. Run: $0 init-keys"; exit 1; }
  perms=$(stat -f '%Lp' "$KEYS" 2>/dev/null || stat -c '%a' "$KEYS")
  [ "$perms" = "600" ] || echo "WARNING: $KEYS has permissions $perms, expected 600 (chmod 600 $KEYS)"
  local site_cfg="$DD_SITE"
  set -a; . "$KEYS"; set +a
  : "${DD_API_KEY:?DD_API_KEY missing in $KEYS}"
  DD_SITE="${DD_SITE:-$site_cfg}"
  API="https://api.${DD_SITE}"
  case "$DD_SITE" in
    datadoghq.com|datadoghq.eu|ddog-gov.com) APP="https://app.${DD_SITE}" ;;
    *) APP="https://${DD_SITE}" ;;   # us3, us5, ap1, ap2 use the site name as the web address
  esac
}

need_app_key() { : "${DD_APP_KEY:?DD_APP_KEY missing in $KEYS (needed for dashboards and queries)}"; }

dd() { # method path [file]
  local a=(-sS -X "$1" "$API$2" -H "DD-API-KEY: $DD_API_KEY" -H "DD-APPLICATION-KEY: $DD_APP_KEY" -H "Content-Type: application/json")
  [ $# -ge 3 ] && a+=(--data-binary "@$3")
  curl "${a[@]}"
}

case "${1:-}" in
  init-keys)
    mkdir -p "$(dirname "$KEYS")"
    if [ -e "$KEYS" ]; then echo "$KEYS already exists. Not overwriting."; else
      printf 'DD_API_KEY=\nDD_APP_KEY=\nDD_SITE=%s\n' "$DD_SITE" > "$KEYS"
      echo "Created $KEYS"
    fi
    chmod 600 "$KEYS"
    echo "Open it in an editor and fill in DD_API_KEY and DD_APP_KEY yourself."
    ;;
  validate)
    load_keys
    echo "Site: $DD_SITE"
    printf 'API key: '; curl -sS "$API/api/v1/validate" -H "DD-API-KEY: $DD_API_KEY"; echo
    if [ -n "${DD_APP_KEY:-}" ]; then
      code=$(curl -s -o /dev/null -w '%{http_code}' "$API/api/v1/dashboard?count=1" -H "DD-API-KEY: $DD_API_KEY" -H "DD-APPLICATION-KEY: $DD_APP_KEY")
      [ "$code" = "200" ] && echo "Application key: OK (can read dashboards)" || echo "Application key: check failed (HTTP $code)"
      org=$(curl -s "$API/api/v1/org" -H "DD-API-KEY: $DD_API_KEY" -H "DD-APPLICATION-KEY: $DD_APP_KEY" | jq -r '.orgs[0].name // empty' 2>/dev/null || true)
      if [ -n "$org" ]; then
        echo "Datadog org: $org"
        [ -n "${DD_ORG_NAME:-}" ] && [ "$org" != "$DD_ORG_NAME" ] && echo "WARNING: config says DD_ORG_NAME=$DD_ORG_NAME. These keys belong to a different org."
      else
        echo "Datadog org: not readable with this application key (fine, it only needs dashboard access)"
      fi
    else echo "DD_APP_KEY not set"; fi
    ;;
  create)
    load_keys; need_app_key
    out=$(dd POST /api/v1/dashboard "$DASH")
    id=$(jq -r '.id // empty' <<<"$out")
    [ -n "$id" ] || { echo "$out"; exit 1; }
    mkdir -p "$(dirname "$STATE")"; echo "$id" > "$STATE"
    echo "Created dashboard $id"
    echo "$APP$(jq -r '.url' <<<"$out")"
    ;;
  update)
    load_keys; need_app_key
    id="${2:-$(cat "$STATE" 2>/dev/null || true)}"
    [ -n "$id" ] || { echo "No dashboard id. Pass one: $0 update <id>"; exit 1; }
    out=$(dd PUT "/api/v1/dashboard/$id" "$DASH")
    jq -e '.id' >/dev/null <<<"$out" || { echo "$out"; exit 1; }
    echo "Updated dashboard $id ($(jq '.widgets|length' <<<"$out") widgets)"
    echo "$APP$(jq -r '.url' <<<"$out")"
    ;;
  check)
    load_keys; need_app_key
    env="${2:-${DD_ENV:-}}"
    scope="${env:+env:$env}"; scope="${scope:-*}"
    echo "Scope: $scope"
    now=$(date +%s); from=$((now - 900))
    for q in "sum:container.cpu.usage{$scope} by {vendor}" "sum:container.cpu.usage{$scope} by {cg_image}"; do
      echo "== $q"
      curl -sS -G "$API/api/v1/query" -H "DD-API-KEY: $DD_API_KEY" -H "DD-APPLICATION-KEY: $DD_APP_KEY" \
        --data-urlencode "from=$from" --data-urlencode "to=$now" --data-urlencode "query=$q" \
        | jq -r '.errors // empty, (.series[]? | .scope)'
    done
    echo "== container counts"
    body=$(jq -n --arg s "$scope" --argjson f "$((from*1000))" --argjson t "$((now*1000))" '{data:{type:"scalar_request",attributes:{from:$f,to:$t,
      queries:[
        {name:"cgb",data_source:"metrics",query:("sum:container.cpu.usage{cg_image:*," + $s + "} by {container_id}"),aggregator:"last"},
        {name:"ncg",data_source:"metrics",query:("sum:container.cpu.usage{!cg_image:*," + $s + "} by {container_id}"),aggregator:"last"},
        {name:"total",data_source:"metrics",query:("sum:container.cpu.usage{" + $s + "} by {container_id}"),aggregator:"last"}],
      formulas:[{formula:"count_not_null(cgb)"},{formula:"count_not_null(ncg)"},{formula:"count_not_null(total)"},
                {formula:"100 * count_not_null(cgb) / count_not_null(total)"}]}}}')
    curl -sS -X POST "$API/api/v2/query/scalar" -H "DD-API-KEY: $DD_API_KEY" -H "DD-APPLICATION-KEY: $DD_APP_KEY" \
      -H "Content-Type: application/json" -d "$body" \
      | jq -r '.errors // (.data.attributes.columns | map(select(.type=="number") | .values[0]) as $v
          | "chainguard=\($v[0] // 0)  non_chainguard=\($v[1] // 0)  total=\($v[2] // 0)  adoption=\(($v[3] // 0) * 10 | round / 10)%")'
    ;;
  *) usage ;;
esac

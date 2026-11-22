#!/usr/bin/env bash
# Troubleshooting helper: report the Chainguard OCI labels on specific images, read from the registry.
# Use it when one image does not show up as Chainguard in Datadog.
#
# Usage: check-image-labels.sh [--platform linux/amd64] <image> [<image> ...]
#
# A short name such as python:latest is expanded to $CG_REGISTRY/python:latest from the skill config.
# Needs crane, jq and registry credentials (for cgr.dev: chainctl auth configure-docker).
set -uo pipefail
. "$(dirname "$0")/config.sh"

PLATFORM=linux/amd64
if [ "${1:-}" = "--platform" ]; then PLATFORM=$2; shift 2; fi
[ $# -gt 0 ] || { sed -n '2,8p' "$0"; exit 1; }
command -v crane >/dev/null || { echo "crane not found (https://github.com/google/go-containerregistry)"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }

images=()
for i in "$@"; do
  if [[ "$i" != */* && -n "${CG_REGISTRY:-}" ]]; then images+=("$CG_REGISTRY/$i"); else images+=("$i"); fi
done

printf '%-60s %-11s %-18s %-22s %s\n' IMAGE VENDOR CG_IMAGE PACKAGE.MAIN RESULT
rc=0
err=$(mktemp); trap 'rm -f "$err"' EXIT
for img in "${images[@]}"; do
  if ! cfg=$(crane config --platform "$PLATFORM" "$img" 2>"$err") || ! jq -e . >/dev/null 2>&1 <<<"$cfg"; then
    if grep -q 'MANIFEST_UNKNOWN' "$err"; then
      printf '%-60s %s\n' "$img" "SKIPPED: tag not found in this repo"
    elif grep -qE 'no child with platform|no matching manifest' "$err"; then
      printf '%-60s %s\n' "$img" "SKIPPED: no $PLATFORM image (try --platform)"
    else
      printf '%-60s %s\n' "$img" "ERROR: $(tail -1 "$err" | cut -c1-90)"; rc=1
    fi
    continue
  fi
  IFS=$'\t' read -r vendor title pkg < <(jq -r '.config.Labels // {} | [(.["org.opencontainers.image.vendor"] // "-"), (.["dev.chainguard.image.title"] // "-"), ((.["dev.chainguard.package.main"] // "-") | if . == "" then "(empty)" else . end)] | @tsv' <<<"$cfg")
  if [ "$title" = "-" ]; then result="NOT counted (no dev.chainguard.image.title)"; rc=1
  elif [ "$vendor" != "Chainguard" ]; then result="counted (cg_image), vendor label overwritten"
  else result="counted"; fi
  printf '%-60s %-11s %-18s %-22s %s\n' "$img" "$vendor" "$title" "$pkg" "$result"
done
exit $rc

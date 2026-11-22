#!/usr/bin/env bash
# Report the Chainguard OCI labels on images, read straight from the registry.
#
# Usage:
#   check-image-labels.sh [--platform linux/amd64] <image> [<image> ...]
#   check-image-labels.sh [--platform linux/amd64] --all [tag]
#
# A short name such as python:latest is expanded to $CG_REGISTRY/python:latest from the skill config.
# --all lists every repo in $CG_ORG with chainctl and checks the given tag (default latest).
# Needs crane and jq, registry credentials (for cgr.dev: chainctl auth configure-docker),
# and chainctl for --all.
set -uo pipefail
. "$(dirname "$0")/config.sh"

PLATFORM=linux/amd64
if [ "${1:-}" = "--platform" ]; then PLATFORM=$2; shift 2; fi
command -v crane >/dev/null || { echo "crane not found (https://github.com/google/go-containerregistry)"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }

images=()
if [ "${1:-}" = "--all" ]; then
  tag="${2:-latest}"
  [ -n "${CG_ORG:-}" ] || { echo "CG_ORG is not set. Run: $(dirname "$0")/config.sh set CG_ORG <your-org>"; exit 1; }
  command -v chainctl >/dev/null || { echo "chainctl not found"; exit 1; }
  while read -r r; do [ -n "$r" ] && images+=("$CG_REGISTRY/$r:$tag"); done \
    < <(chainctl images repos list --parent "$CG_ORG" -o json 2>/dev/null | jq -r '.items[]?.name' | sort)
  [ ${#images[@]} -gt 0 ] || { echo "No repos found in $CG_ORG (check chainctl auth status and the org name)."; exit 1; }
else
  [ $# -gt 0 ] || { sed -n '2,12p' "$0"; exit 1; }
  for i in "$@"; do
    if [[ "$i" != */* && -n "${CG_REGISTRY:-}" ]]; then images+=("$CG_REGISTRY/$i"); else images+=("$i"); fi
  done
fi

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

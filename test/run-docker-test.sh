#!/usr/bin/env bash
# Local test: does the Datadog Agent turn Chainguard OCI labels into tags at runtime?
#
# Usage:
#   ./run-docker-test.sh            # local only, dummy API key, nothing useful leaves the laptop
#   DD_API_KEY=<real key> ./run-docker-test.sh   # also ships metrics to your Datadog org
#
# Tested with gcr.io/datadoghq/agent:7: DD_CONTAINER_LABELS_AS_TAGS is honored,
# DD_DOCKER_LABELS_AS_TAGS is the legacy name (it overrides the new one if both map the same
# label), and DD_CONTAINER_IMAGE_LABELS_AS_TAGS is not a real setting and is silently ignored.
set -euo pipefail
cd "$(dirname "$0")"

API_KEY="${DD_API_KEY:-00000000000000000000000000000000}"
SITE="${DD_SITE:-datadoghq.com}"
AGENT_IMAGE="${AGENT_IMAGE:-gcr.io/datadoghq/agent:7}"

cleanup() { docker rm -f dd-agent cg-direct cg-derived cg-derived-override control >/dev/null 2>&1 || true; }
cleanup

echo "== Building derived test images"
docker build -q -t local/cg-derived:test derived >/dev/null
docker build -q -t local/cg-derived-override:test derived-override >/dev/null

echo "== Starting workload containers"
docker run -d --name cg-direct           cgr.dev/chainguard/nginx:latest >/dev/null       # Chainguard image as is
docker run -d --name cg-derived          local/cg-derived:test >/dev/null                 # FROM Chainguard, label inherited
docker run -d --name cg-derived-override local/cg-derived-override:test >/dev/null        # FROM Chainguard, vendor overwritten
docker run -d --name control             busybox:latest sleep 100000 >/dev/null           # negative control, not Chainguard

echo "== Starting Datadog Agent ($AGENT_IMAGE)"
docker run -d --name dd-agent \
  -e DD_API_KEY="$API_KEY" \
  -e DD_SITE="$SITE" \
  -e DD_HOSTNAME=cg-label-test \
  -e DD_TAGS="env:cg-label-test" \
  -e DD_CONTAINER_LABELS_AS_TAGS='{"org.opencontainers.image.vendor":"vendor","dev.chainguard.image.title":"cg_image"}' \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /proc/:/host/proc/:ro \
  -v /sys/fs/cgroup/:/host/sys/fs/cgroup:ro \
  "$AGENT_IMAGE" >/dev/null

echo "== Waiting for the Agent tagger to populate"
for _ in $(seq 1 24); do
  docker exec dd-agent agent tagger-list >/dev/null 2>&1 && break
  sleep 5
done
sleep 15

echo
echo "== Tags per workload container (from the Agent's tagger)"
OUT=$(docker exec dd-agent agent tagger-list 2>/dev/null)
for c in cg-direct cg-derived cg-derived-override control; do
  id=$(docker inspect -f '{{.Id}}' "$c")
  tags=$(printf '%s\n' "$OUT" | awk -v id="$id" '
    index($0, "container_id://" id) {f=1; next}
    f && /^=== Entity/ {f=0}
    f' | grep -Eo '(vendor|cg_image):[^] ,"]+' | sort -u | tr '\n' ' ' || true)
  printf '%-22s %s\n' "$c" "${tags:-<no vendor/cg_image tags>}"
done

echo
echo "Expected: cg-direct and cg-derived show vendor:chainguard and cg_image:*,"
echo "cg-derived-override shows cg_image:python but not vendor:chainguard, control shows nothing."
echo
echo "Agent left running for inspection. Clean up with: docker rm -f dd-agent cg-direct cg-derived cg-derived-override control"

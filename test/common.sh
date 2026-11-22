# Shared by the local test scripts. Sourced from inside the test/ directory.
#
# Modes:
#   (default)   local only: the Agent gets a dummy API key, nothing reaches Datadog. You see the
#               tags the Agent applied, printed in the terminal.
#   --datadog   send to Datadog: reads DD_API_KEY (and DD_SITE) from the keys file so the test
#               shows up on the dashboard. The key is passed through the environment or stdin,
#               never as a command-line argument.
#
# Kubernetes tests never change your current kubectl context. They use explicit --context and
# --kube-context flags, and restore your original context on exit in case kind changed it.

MODE=local
for a in "$@"; do
  case "$a" in
    --datadog) MODE=datadog ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "Unknown option: $a (use --datadog to send data to Datadog)"; exit 1 ;;
  esac
done

# Settings: the skill config if this copy of the skill has one, else defaults.
if [ -r ../scripts/config.sh ]; then . ../scripts/config.sh; fi
KEYS="${DD_KEYS_FILE:-$HOME/.config/datadog/keys.env}"
KEYS="${KEYS/#\~/$HOME}"
SITE="${DD_SITE:-datadoghq.com}"
API_KEY=00000000000000000000000000000000

if [ "$MODE" = datadog ]; then
  [ -r "$KEYS" ] || { echo "--datadog needs a keys file at $KEYS containing DD_API_KEY."; exit 1; }
  API_KEY=$(set -a; . "$KEYS"; printf '%s' "${DD_API_KEY:-}")
  key_site=$(set -a; . "$KEYS"; printf '%s' "${DD_SITE:-}")
  [ -n "$key_site" ] && SITE=$key_site
  [ -n "$API_KEY" ] || { echo "DD_API_KEY is empty in $KEYS."; exit 1; }
fi
export DD_API_KEY="$API_KEY"

ORIG_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
restore_context() {
  if [ -n "$ORIG_CONTEXT" ] && [ "$(kubectl config current-context 2>/dev/null || true)" != "$ORIG_CONTEXT" ]; then
    kubectl config use-context "$ORIG_CONTEXT" >/dev/null 2>&1 || true
  fi
}

# Build the two local test images from this copy's Dockerfiles. Every test calls this, so a test
# never reuses a stale image built earlier by another copy of the skill.
build_test_images() {
  echo "== Building test images"
  docker build -q -t local/cg-derived:test derived >/dev/null
  docker build -q -t local/cg-derived-override:test derived-override >/dev/null
}

# Print where to look next.
mode_footer() { # env-tag-value
  echo
  if [ "$MODE" = datadog ]; then
    echo "Sent to Datadog ($SITE). Data appears in a few minutes."
    echo "On the Chainguard Adoption (Runtime) dashboard, set the env filter to $1."
  else
    echo "Local only: the Agent used a dummy key, so nothing reached Datadog."
    echo "To see this on the dashboard, rerun with --datadog (needs a keys file with DD_API_KEY)."
  fi
}

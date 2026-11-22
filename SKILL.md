---
name: chainguard-adoption
description: Track how many running containers use Chainguard images, in Datadog. Guided setup, the one Datadog Agent setting that turns Chainguard image labels into tags, verification, an adoption and migration-backlog dashboard, and an optional local proof. Use when someone wants Chainguard adoption metrics in Datadog, a list of non-Chainguard images still running, or to confirm Chainguard images are detectable at runtime.
argument-hint: "[setup | agent-config | verify | dashboard | local-test]"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/config.sh show) Bash(${CLAUDE_SKILL_DIR}/scripts/check-image-labels.sh *) Bash(${CLAUDE_SKILL_DIR}/scripts/verify-agent.sh *) Bash(${CLAUDE_SKILL_DIR}/scripts/dd-dashboard.sh validate) Bash(${CLAUDE_SKILL_DIR}/scripts/dd-dashboard.sh check *) Bash(${CLAUDE_SKILL_DIR}/scripts/dd-dashboard.sh init-keys)
---

# Chainguard adoption in Datadog

The user ran this skill with: `$ARGUMENTS`

There are five commands: `setup`, `agent-config`, `verify`, `dashboard`, `local-test`. Pick the one that matches the first word (`$0`).

Start every run with `${CLAUDE_SKILL_DIR}/scripts/config.sh show`.
- If there is no config file yet and the command is not `local-test`, run `setup` first, then continue with what they asked for.
- With no arguments: list the five commands with one line each, summarize the current config in one line, and suggest the next step. The normal order is setup, agent-config, verify, dashboard. Also mention that `docs/setup-guide.md` walks through the whole setup by hand.
- If the user wants to do it manually, or wants something to share with a platform team, point them to `${CLAUDE_SKILL_DIR}/docs/setup-guide.md`. It covers the Agent setting for Helm, Operator, Docker and ECS, verification, and both dashboard routes (Datadog UI, and API including key creation and the keys file). Offer to copy it somewhere they choose.

## How detection works (explain when asked, keep it short)

1. Every Chainguard image carries labels in its image config: `org.opencontainers.image.vendor=Chainguard` and `dev.chainguard.image.title=<name>`, plus `dev.chainguard.package.main=<package-version>` on images in a customer org. Images built `FROM` a Chainguard image inherit them.
2. The container runtime copies image labels onto each container it creates.
3. One Agent setting, `DD_CONTAINER_LABELS_AS_TAGS`, turns those labels into tags `vendor` and `cg_image` on every metric from the container. Datadog lowercases values, so `vendor:chainguard`.
4. The dashboard counts distinct containers with `count_not_null(sum:container.cpu.usage{...} by {container_id})`. Chainguard = `cg_image:*`, everything else = `!cg_image:*`.

Facts established by testing (Agent 7.84, Docker, kind with the Helm chart, kind with the Datadog Operator, live Datadog):
- `DD_CONTAINER_LABELS_AS_TAGS` works for Docker and containerd. `DD_DOCKER_LABELS_AS_TAGS` is the legacy name and overrides the new one if both map the same label. `DD_CONTAINER_IMAGE_LABELS_AS_TAGS` is not an Agent setting and is silently ignored. Never recommend it.
- Count on `cg_image`, not `vendor`: a build that sets its own `org.opencontainers.image.vendor` loses `vendor:chainguard` but keeps `cg_image`.
- Chainguard images carry these labels, including Custom Assembly images and images pulled through a registry mirror. Missing labels have not been seen in practice, so do not check images up front.
- Nothing in an image marks it as Custom Assembly. To track customized images separately, the overlay can set an environment variable (for example `CG_OVERLAY_CERTS=corp`) and the Agent can map it with `DD_CONTAINER_ENV_AS_TAGS='{"CG_OVERLAY_CERTS":"cg_overlay"}'`. Only the Agent side of this was tested.
- It is a label check, not proof of provenance. Signatures and SBOMs prove origin.
- Totals include system containers and the Datadog Agent itself. Filter by `kube_namespace` for application adoption.

## setup

Collect what the other commands need and save it with `${CLAUDE_SKILL_DIR}/scripts/config.sh set KEY VALUE`. Ask with the AskUserQuestion tool. Offer detected values as the first option. Never ask for API keys or secrets.

1. **Detect first (read-only):** `kubectl config get-contexts`, `kubectl config current-context` and `kubectl get ds -A | grep -i datadog` for clusters and existing Agent DaemonSets, and `chainctl iam organizations list -o table` for Chainguard orgs. Skip quietly whatever is unavailable.
2. **Ask, round 1:**
   - Datadog site (`DD_SITE`): offer `datadoghq.com` (US1), `us3.datadoghq.com`, `us5.datadoghq.com`, `datadoghq.eu`, `ap1.datadoghq.com`. It matches the address they use to open Datadog.
   - How the Datadog Agent is deployed (`AGENT_DEPLOY`): `helm`, `operator`, `docker` or `ecs`, or `none` if not deployed yet.
   - Dashboard route: UI import (no keys) or API (needs an API key and application key). Do not store it, just use it for the plan.
   - Chainguard organization (`CG_ORG`), optional. Offer the detected orgs. If they pull through a mirror (Artifactory, Nexus, Harbor), also save the path that replaces `cgr.dev/<org>` as `CG_REGISTRY`. Only used to troubleshoot a specific image later.
3. **Ask, round 2** (skip what does not apply):
   - Which cluster to check (`KUBE_CONTEXT`), for Kubernetes. Offer the current context first, then the other contexts. Saving it means `verify` always checks that cluster, even if their current context changes later. Leave it empty to always use whatever context is current.
   - Agent namespace and DaemonSet (`AGENT_NAMESPACE`, `AGENT_DAEMONSET`) for Kubernetes. Offer what was detected. Defaults: Helm `datadog`/`datadog` (DaemonSet = release name), Operator `datadog`/`datadog-agent` (DaemonSet = `<DatadogAgent name>-agent`).
   - The `env` tag value to scope numbers to (`DD_ENV`), for example `prod`. Optional.
   - Datadog organization name (`DD_ORG_NAME`), optional. Used to warn if API keys belong to a different org.
4. Save the answers, show `config.sh show`, then give the short plan (agent-config, verify, dashboard) and offer to start `agent-config` right away.

## agent-config

Use `AGENT_DEPLOY` from the config. Show the snippet plus apply and rollback commands, filled in with their namespace and names. Do not change a cluster without the user's explicit go-ahead.

Helm `values.yaml` (merge into an existing `datadog.env` list if there is one):
```yaml
datadog:
  env:
    - name: DD_CONTAINER_LABELS_AS_TAGS
      value: '{"org.opencontainers.image.vendor":"vendor","dev.chainguard.image.title":"cg_image"}'
```
Apply: `helm upgrade <release> datadog/datadog -n <ns> -f values.yaml`, then `kubectl rollout status daemonset/<release> -n <ns>`.

Datadog Operator: add to the `DatadogAgent` resource and apply with `kubectl apply -f`:
```yaml
spec:
  override:
    nodeAgent:
      env:
        - name: DD_CONTAINER_LABELS_AS_TAGS
          value: '{"org.opencontainers.image.vendor":"vendor","dev.chainguard.image.title":"cg_image"}'
```
Then `kubectl rollout status daemonset/<DatadogAgent name>-agent -n <ns>`.

Docker: `-e DD_CONTAINER_LABELS_AS_TAGS='{"org.opencontainers.image.vendor":"vendor","dev.chainguard.image.title":"cg_image"}'` on the Agent container. ECS: the same name and value in the Agent container's `environment` list in the task definition.

Requires Agent 7.33 or later. Rollback: remove the entry and re-apply.
Tested: Helm and Operator (both on kind with containerd) and plain Docker. ECS follows Datadog's documented fields but was not tested. Say so if they use ECS.
If `AGENT_DEPLOY` is `none`, point them to Datadog's Agent install docs for their platform first.

## verify

Two checks. Run whichever applies and report both in plain language.

1. **The Agent** (Kubernetes deployments): `${CLAUDE_SKILL_DIR}/scripts/verify-agent.sh` (namespace, DaemonSet and context from the config, or pass them as arguments). It works with any cluster the user's kubectl can reach (EKS, AKS, GKE, OpenShift, on-prem) and only reads. It targets `KUBE_CONTEXT` with `--context` and never changes the user's current context. It needs permission to get DaemonSets and pods and to exec into pods in the Agent namespace. If exec is forbidden, say so plainly and fall back to the Datadog numbers in check 2. On EKS Fargate the Agent runs as a sidecar, not a DaemonSet, so skip this check there. The mapping must include `dev.chainguard.image.title` (Helm prints it as a JSON string, the Operator as key-value lines), and `cg_image:<name>` tags should appear for Chainguard containers on that node. If the DaemonSet is not found, the script lists the Datadog DaemonSets it can see. Offer to save the right one with `config.sh set`.
2. **The numbers in Datadog** (if the keys file exists): `${CLAUDE_SKILL_DIR}/scripts/dd-dashboard.sh check` (scoped to `DD_ENV`, or pass an env). Shows Chainguard, non-Chainguard and total container counts and adoption %. Data appears a few minutes after the Agent starts reporting. Without keys, tell them to look at the dashboard instead.

Troubleshooting only: if one specific image they expect to be Chainguard shows up as non-Chainguard, check its labels with `${CLAUDE_SKILL_DIR}/scripts/check-image-labels.sh <image>` (short names expand to `CG_REGISTRY`). Do not inspect local images with `docker image inspect` without `--platform`, because on Docker Desktop an unpulled platform looks like an image with no labels.

## dashboard

Ask UI or API if setup did not settle it. Both create the same "Chainguard Adoption (Runtime)" dashboard from `${CLAUDE_SKILL_DIR}/assets/dashboard.json`.

**UI (no keys):** copy the JSON to the clipboard (`pbcopy < ${CLAUDE_SKILL_DIR}/assets/dashboard.json` on macOS, `xclip -selection clipboard < ...` on Linux), then give these steps, which were verified in the Datadog UI:
1. Open Datadog for their site, go to Dashboards and click New Dashboard.
2. Under "Or start from scratch", click Blank Dashboard. It is created immediately with a default name.
3. Click Configure (top right) and choose Import dashboard JSON.
4. Click inside the import window and paste (Cmd+V or Ctrl+V), or drag in `assets/dashboard.json`. The dashboard becomes "Chainguard Adoption (Runtime)" with eight widgets.
5. Set the `env` and `kube_namespace` filters (suggest `DD_ENV` if set).
Browser automation cannot complete step 4 (the dialog ignores scripted paste and drop), so the user does that click.

**API:** walk through it in order with `${CLAUDE_SKILL_DIR}/scripts/dd-dashboard.sh`:
1. If there is no keys file, run `init-keys`. It creates `DD_KEYS_FILE` (default `~/.config/datadog/keys.env`) with permissions 600. Explain how to create the keys: API key under Organization Settings, API Keys. Application key under Organization Settings, Application Keys, scoped to `dashboards_read` and `dashboards_write` if they scope it. Some roles can create application keys but not API keys, in which case a Datadog admin provides the API key. The user fills in the file themselves in an editor.
2. Run `validate`. It also shows which Datadog org the keys belong to and warns if it differs from `DD_ORG_NAME`.
3. Confirm with the user, then run `create` (first time) or `update` (a dashboard id is already saved). Both change their Datadog account. Print the URL.
Never ask the user to paste keys into chat, never print or echo key values, and never put keys on a command line.

## local-test

Proves the whole chain on the user's laptop with four fixed containers built from public images: `cgr.dev/chainguard/nginx` as is, an image built FROM `cgr.dev/chainguard/python`, the same with its vendor label overwritten, and `busybox` as a non-Chainguard control. No Chainguard org is needed. The Kubernetes variants create their own kind clusters on the laptop. They never touch the user's real clusters and never change the user's current kubectl context.

Ask two questions together:
1. **Where:** Docker (default, about 2 minutes), Kubernetes with the Datadog Helm chart, or Kubernetes with the Datadog Operator (about 5 minutes each).
2. **Mode:**
   - Local only (default): the Agent gets a dummy key, nothing reaches Datadog, and the result is the table of tags the Agent applied, printed in the terminal. No Datadog account needed, but nothing shows on a dashboard.
   - Send to Datadog: the test appears on the Chainguard Adoption (Runtime) dashboard. Needs a keys file with `DD_API_KEY` (the application key is not needed for this). If there is no keys file, run `${CLAUDE_SKILL_DIR}/scripts/dd-dashboard.sh init-keys` and have the user fill it in first.

Commands (add `--datadog` for send to Datadog. The script reads the key from the keys file itself and never puts it on a command line):
- Docker: `${CLAUDE_SKILL_DIR}/test/run-docker-test.sh [--datadog]`
- Helm on kind: `${CLAUDE_SKILL_DIR}/test/run-kind-test.sh [--datadog]`
- Operator on kind: `${CLAUDE_SKILL_DIR}/test/run-operator-test.sh [--datadog]`
Each script builds its own test images first, so the variants can run in any order.

Expected: Chainguard and derived show `vendor:Chainguard` and `cg_image:*`, the override shows `vendor:example-co` but keeps `cg_image`, the control shows neither. The tests use the upstream `gcr.io/datadoghq/agent:7` image because that is the Agent most customers run.

After a send-to-Datadog run: tell them data appears in a few minutes, and to set the dashboard's `env` filter to `cg-label-test` (Docker and Helm) or `cg-operator-test` (Operator). If they do not have the dashboard yet, offer to run `dashboard`. With keys and an application key, offer `dd-dashboard.sh check cg-label-test` after a few minutes to confirm the numbers.

When done, offer cleanup and run it only after a yes: `kind delete cluster --name cg-label-test`, `kind delete cluster --name cg-operator-test`, `docker rm -f dd-agent cg-direct cg-derived cg-derived-override control`. Only remove these local test resources. If the user runs `local-test clean`, go straight to the cleanup offer.

## Writing style for anything customer-facing
Plain and direct. No semicolons, no em dashes. State what was tested and what was not.

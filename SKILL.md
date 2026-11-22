---
name: chainguard-adoption
description: Track how many running containers use Chainguard images, in Datadog. Walks through setup (Chainguard org, image registry, Datadog site, Agent deployment), checks that images carry Chainguard OCI labels, generates the Datadog Agent setting that turns those labels into tags, verifies the Agent, creates an adoption and migration-backlog dashboard (UI import or API), and runs a local Docker or kind proof. Use when someone wants Chainguard adoption metrics, a list of non-Chainguard images still running, or to confirm Chainguard images are detectable at runtime in Datadog.
argument-hint: "[setup | labels [--all | <image...>] | agent-config | verify [ns] [ds] | dashboard ui | dashboard api [init-keys|validate|create|update] | check [env] | guide | local-test [docker|kind|operator] | teardown]"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/config.sh show) Bash(${CLAUDE_SKILL_DIR}/scripts/config.sh path) Bash(${CLAUDE_SKILL_DIR}/scripts/check-image-labels.sh *) Bash(${CLAUDE_SKILL_DIR}/scripts/verify-agent.sh *) Bash(${CLAUDE_SKILL_DIR}/scripts/dd-dashboard.sh validate) Bash(${CLAUDE_SKILL_DIR}/scripts/dd-dashboard.sh check *) Bash(${CLAUDE_SKILL_DIR}/scripts/dd-dashboard.sh init-keys)
---

# Chainguard adoption in Datadog

The user ran this skill with: `$ARGUMENTS`

Start every run with `${CLAUDE_SKILL_DIR}/scripts/config.sh show`.
- If there is no config file yet and the command is not `local-test`, `guide` or `teardown`, run the **setup** workflow first, then continue with what they asked for.
- With no arguments or `help`: show the menu under "Commands", summarize the current config in one line, and suggest the next step (usually `setup`, then `labels`, `agent-config`, `verify`, `dashboard`).

Pick the section that matches the first word (`$0`).

## How detection works (explain when asked, keep it short)

1. Every Chainguard image carries labels in its image config: `org.opencontainers.image.vendor=Chainguard` and `dev.chainguard.image.title=<name>`, plus `dev.chainguard.package.main=<package-version>` on images in a customer org (it is empty on the public `cgr.dev/chainguard` images). Images built `FROM` a Chainguard image inherit them.
2. The container runtime copies image labels onto each container it creates.
3. One Agent setting, `DD_CONTAINER_LABELS_AS_TAGS`, turns those labels into tags `vendor` and `cg_image` on every metric from the container. Datadog lowercases values, so `vendor:chainguard`.
4. The dashboard counts distinct containers with `count_not_null(sum:container.cpu.usage{...} by {container_id})`. Chainguard = `cg_image:*`, everything else = `!cg_image:*`.

Facts established by testing (Agent 7.84, Docker, kind with the Helm chart, kind with the Datadog Operator, live Datadog):
- `DD_CONTAINER_LABELS_AS_TAGS` works for Docker and containerd. `DD_DOCKER_LABELS_AS_TAGS` is the legacy name and overrides the new one if both map the same label. `DD_CONTAINER_IMAGE_LABELS_AS_TAGS` is not an Agent setting and is silently ignored. Never recommend it.
- Count on `cg_image`, not `vendor`: a build that sets its own `org.opencontainers.image.vendor` loses `vendor:chainguard` but keeps `cg_image`.
- Images pulled through a registry mirror (Artifactory, Nexus, Harbor) keep their labels, because labels live inside the image.
- Custom Assembly images keep all Chainguard labels, and nothing in the image marks them as customized. To track customized images separately, the overlay can set an environment variable (for example `CG_OVERLAY_CERTS=corp`) and the Agent can map it with `DD_CONTAINER_ENV_AS_TAGS='{"CG_OVERLAY_CERTS":"cg_overlay"}'`. Use a distinct variable name per overlay. The Agent side of this was tested. Setting the variable through an overlay was not.
- It is a label check, not proof of provenance. Signatures and SBOMs prove origin.
- Totals include system containers and the Datadog Agent itself. Filter by `kube_namespace` for application adoption.

## Commands

### `setup`
Collect what the other commands need and save it with `${CLAUDE_SKILL_DIR}/scripts/config.sh set KEY VALUE`. Ask with the AskUserQuestion tool, a few questions at a time. Offer detected values as the first option. Never ask for API keys or secrets here.

1. **Detect first (read-only)**, so you can offer real choices:
   - `chainctl auth status` and `chainctl iam organizations list -o table` (Chainguard orgs the user can see). If chainctl is missing or not logged in, say so and let the user type the org name.
   - `kubectl config current-context` and `kubectl get ds -A | grep -i datadog` (existing Agent DaemonSets). Skip quietly if kubectl is unavailable.
   - If the user has an existing keys file, run `dd-dashboard.sh validate` to read the Datadog org name and site from it.
2. **Ask** (round 1):
   - Chainguard organization (`CG_ORG`), for example `example.com`. Offer the detected orgs.
   - Where workloads pull images from (`CG_REGISTRY`): directly from `cgr.dev/<org>` (default), or through a mirror. If a mirror, ask for the path that replaces `cgr.dev/<org>`, for example `artifactory.example.com/cgr-remote/<org>`.
   - Datadog site (`DD_SITE`): offer `datadoghq.com` (US1), `us3.datadoghq.com`, `us5.datadoghq.com`, `datadoghq.eu`, `ap1.datadoghq.com`. Tell them it matches the address they use to open Datadog.
   - How the Datadog Agent is deployed (`AGENT_DEPLOY`): `helm`, `operator`, `docker` or `ecs`, or `none` if not deployed yet.
3. **Ask** (round 2):
   - Datadog organization name (`DD_ORG_NAME`), so later steps can warn if keys belong to a different org. Optional.
   - Agent namespace and DaemonSet (`AGENT_NAMESPACE`, `AGENT_DAEMONSET`) for Kubernetes deployments. Offer what was detected. Defaults: Helm `datadog`/`datadog` (DaemonSet = release name), Operator `datadog`/`datadog-agent` (DaemonSet = `<DatadogAgent name>-agent`).
   - The `env` tag value to scope checks to (`DD_ENV`), for example `prod`. Optional.
   - Dashboard route: UI import (no keys) or API (needs an API key and application key). Do not store this, just remember it for the next-steps summary.
4. Save each answer with `config.sh set`, then show `config.sh show`.
5. Finish with a numbered plan tailored to their answers, for example: check labels (`labels --all`), apply the Agent setting (`agent-config`), verify (`verify`), create the dashboard (`dashboard ui` or `dashboard api`), check numbers (`check`).

### `labels [--all | <image...>]`
Run `${CLAUDE_SKILL_DIR}/scripts/check-image-labels.sh` with the arguments.
- `--all [tag]` lists every repo in `CG_ORG` with chainctl and checks `<CG_REGISTRY>/<repo>:<tag>` (default `latest`).
- Short names like `python:latest` expand to `<CG_REGISTRY>/python:latest`. Full references are used as given.
- Add `--platform linux/arm64` first if their nodes are arm64.
For `cgr.dev` the user needs registry credentials (`chainctl auth configure-docker`). For a mirror they need to be logged in to it (`docker login <host>`). If a login needs a browser, ask the user to run it with `!` so the prompt reaches them.
Explain the result column: "counted" is good. "vendor label overwritten" is still counted through `cg_image`. "NOT counted" means the image has no Chainguard label and will appear as non-Chainguard.
Do not inspect local images with `docker image inspect` without `--platform`: on Docker Desktop an unpulled platform shows an empty config with no labels, which looks like a missing label but is not.

### `agent-config`
Use `AGENT_DEPLOY` from the config (or a deployment named in the arguments). Show the snippet plus apply and rollback commands, filled in with their namespace and names. Do not change a cluster without the user's explicit go-ahead.

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

### `verify [namespace] [daemonset]`
Run `${CLAUDE_SKILL_DIR}/scripts/verify-agent.sh` (defaults from the config). If the DaemonSet is not found, the script lists the Datadog DaemonSets it can see. Offer to save the right one with `config.sh set`. Explain: the mapping must include `dev.chainguard.image.title` (Helm prints it as a JSON string, the Operator as key-value lines), and `cg_image:<name>` tags should appear for Chainguard containers on that node.

### `dashboard ui`
The quick path, no keys. Copy the dashboard JSON to the clipboard (`pbcopy < ${CLAUDE_SKILL_DIR}/assets/dashboard.json` on macOS, `xclip -selection clipboard < ...` on Linux), then give these steps, which were verified in the Datadog UI:
1. Open Datadog for their site, go to Dashboards and click New Dashboard.
2. Under "Or start from scratch", click Blank Dashboard. It is created immediately with a default name.
3. Click Configure (top right) and choose Import dashboard JSON.
4. Click inside the import window and paste (Cmd+V or Ctrl+V), or drag in `assets/dashboard.json`. The dashboard becomes "Chainguard Adoption (Runtime)" with eight widgets.
5. Set the `env` and `kube_namespace` filters (suggest `DD_ENV` if set).
Browser automation cannot complete step 4 (the dialog ignores scripted paste and drop), so the user does that click.

### `dashboard api [init-keys|validate|create|update]`
Uses `${CLAUDE_SKILL_DIR}/scripts/dd-dashboard.sh`. Keys live in `DD_KEYS_FILE` (default `~/.config/datadog/keys.env`, chmod 600) with `DD_API_KEY` and `DD_APP_KEY`. The site comes from the config.
- Never ask the user to paste keys into chat, never print or echo key values, and never put keys on a command line. The user fills in the file themselves in an editor.
- Walk them through creating keys if needed: API key under Organization Settings, API Keys. Application key under Organization Settings, Application Keys, scoped to `dashboards_read` and `dashboards_write` if they scope it. Some roles can create application keys but not API keys, in which case a Datadog admin provides the API key.
- Order: `init-keys` (creates the file safely), user edits it, `validate` (also shows the Datadog org the keys belong to and warns if it differs from `DD_ORG_NAME`), then `create`. `create` remembers the id so `update` edits in place. Confirm with the user before `create` or `update`, since both change their Datadog account.

### `check [env]`
Run `${CLAUDE_SKILL_DIR}/scripts/dd-dashboard.sh check <env>` (default `DD_ENV`). Shows series grouped by `vendor` and `cg_image`, plus Chainguard, non-Chainguard and total container counts and adoption %. Data appears a few minutes after the Agent starts reporting. Needs the API keys.

### `guide`
Point the user to `${CLAUDE_SKILL_DIR}/docs/setup-guide.md`, a self-contained setup guide they can share with their platform team. If they want it tailored, fill in their site, namespace and DaemonSet from the config in a copy they choose the location of.

### `local-test [docker|kind|operator]`
Proves the whole chain locally with four containers built from public `cgr.dev/chainguard` images: a Chainguard image, one built FROM Chainguard, one that overwrites the vendor label, and a non-Chainguard control. No Chainguard org is needed.
- `docker`: `${CLAUDE_SKILL_DIR}/test/run-docker-test.sh` (about 2 minutes).
- `kind`: run the docker test once first (it builds the test images), then `${CLAUDE_SKILL_DIR}/test/run-kind-test.sh` (about 5 minutes, Datadog Helm chart on containerd).
- `operator`: run the docker test once first, then `${CLAUDE_SKILL_DIR}/test/run-operator-test.sh` (about 5 minutes, Datadog Operator on its own kind cluster).
All default to a dummy API key and read tags from the Agent directly, so no Datadog account is needed. To send data to Datadog, load the keys file in the same command: `set -a; . <DD_KEYS_FILE>; set +a; ${CLAUDE_SKILL_DIR}/test/run-kind-test.sh`.
Expected: Chainguard and derived show `vendor:Chainguard` and `cg_image:*`, the override shows `vendor:example-co` but keeps `cg_image`, the control shows neither.
The tests use the upstream `gcr.io/datadoghq/agent:7` image because that is the Agent most customers run.

### `teardown`
Confirm first, then: `kind delete cluster --name cg-label-test`, `kind delete cluster --name cg-operator-test` and `docker rm -f dd-agent cg-direct cg-derived cg-derived-override control`. Only remove the local test resources, never anything in the user's real clusters.

## Writing style for anything customer-facing
Plain and direct. No semicolons, no em dashes. State what was tested and what was not.

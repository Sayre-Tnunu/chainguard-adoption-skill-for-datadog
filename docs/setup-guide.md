# Chainguard adoption in Datadog: setup guide

## What this gives you

With one environment variable on the Datadog Agent and an importable dashboard, Datadog reports how many running containers are built on Chainguard images, what share of your total that is, and which non-Chainguard images are still running. It works across every environment the Agent sees.

Every Chainguard image carries the OCI label `org.opencontainers.image.vendor=Chainguard`. It also carries `dev.chainguard.image.title`, which names the Chainguard image it was built from. The Agent can turn both labels into Datadog tags (`vendor:chainguard` and `cg_image:<name>`), and once they are tags you can filter and group any container metric by them. The result is an adoption number based on what is actually running, not on registry contents or image naming conventions.

## Why the label, not the image name

Matching on the image path or tag (anything with "chainguard" or "cgr.dev" in it) breaks the moment an image is pulled through a registry mirror, retagged, or used as the base of a new image under your own name. The label survives all of that because it is part of the image metadata and travels with the image wherever it is pushed.

Using the label means the measurement is:

- Runtime based, so it reflects what is deployed right now
- Registry agnostic, so it works the same whether images come from cgr.dev or a mirror such as Artifactory, Nexus or Harbor
- Built in, since the label is part of the image rather than something a team has to remember to set

## Before you start

You need:

- Datadog Agent 7.33 or later with container metrics enabled, which is the default on Kubernetes.
- Access to change how the Agent is deployed: the Helm values file, the `DatadogAgent` resource for the Operator, or the Agent container definition.
- `kubectl` access to the namespace the Agent runs in, for the checks in Step 2.
- A Datadog user who can create dashboards. That is all Option A in Step 3 needs. Option B, the API route, also needs an API key and an application key with the `dashboards_write` permission.

You do not need to check your images first. Chainguard images carry these labels, including Custom Assembly images and images pulled through a registry mirror. If one image later does not show up as Chainguard, see "Troubleshooting a single image" under Notes and caveats.

## Optional: try it on your laptop first

Before changing anything in a real environment, you can watch the whole thing work on your own machine in a few minutes. The test runs four containers:

- `cgr.dev/chainguard/nginx`, a Chainguard image used as is
- an image built FROM `cgr.dev/chainguard/python`, like an in-house base image
- the same image with its vendor label overwritten, like a team that sets its own labels
- `busybox`, a non-Chainguard image, as the control

It uses only public images, so you need no Chainguard account. The Kubernetes variants create their own throwaway kind clusters. The test never touches your real clusters and never changes your current kubectl context.

You need Docker. The Kubernetes variants also need `kind`, `kubectl` and `helm`. The scripts are in the `test/` folder of this repository (https://github.com/Sayre-Tnunu/chainguard-adoption-skill-for-datadog). Run them from the repository root. Pick one variant:

- Docker, about 2 minutes:

  ```sh
  ./test/run-docker-test.sh
  ```

- Kubernetes with the Datadog Helm chart, about 5 minutes:

  ```sh
  ./test/run-kind-test.sh
  ```

- Kubernetes with the Datadog Operator, about 5 minutes:

  ```sh
  ./test/run-operator-test.sh
  ```

By default the test is local only. The Agent gets a dummy API key, nothing reaches Datadog, and the result is printed in your terminal:

```
cg-direct              cg_image:nginx vendor:Chainguard
cg-derived             cg_image:python vendor:Chainguard
cg-derived-override    cg_image:python vendor:example-co
control                <no vendor/cg_image tags>
```

The first two are counted as Chainguard through both tags. The third still has `cg_image` even though its vendor label was overwritten, which is why the dashboard counts on `cg_image`. The control has neither, so it counts as non-Chainguard.

To see the test on the dashboard, add `--datadog` to the command. The script reads `DD_API_KEY` and `DD_SITE` from `~/.config/datadog/keys.env` (the same keys file as Option B in Step 3, and only the API key is needed) and passes the key to the Agent without putting it on a command line. Create the dashboard as described in Step 3, then set its `env` filter to `cg-label-test` for the Docker and Helm tests, or `cg-operator-test` for the Operator test. Data appears a few minutes after the test starts.

Clean up when you are done:

```sh
docker rm -f dd-agent cg-direct cg-derived cg-derived-override control
kind delete cluster --name cg-label-test
kind delete cluster --name cg-operator-test
```

## Step 1: Tell the Agent to turn the labels into tags

Add one environment variable, `DD_CONTAINER_LABELS_AS_TAGS`, to the Datadog Agent. It maps `org.opencontainers.image.vendor` to a Datadog tag named `vendor`, and `dev.chainguard.image.title` to a tag named `cg_image`. The same variable covers Docker and containerd, so it works the same on Kubernetes.

### Helm chart

Add this to your `values.yaml` (it goes under `datadog.env`). If `datadog.env` already exists, add the entry to that list instead of creating a second one.

```yaml
datadog:
  env:
    - name: DD_CONTAINER_LABELS_AS_TAGS
      value: '{"org.opencontainers.image.vendor":"vendor","dev.chainguard.image.title":"cg_image"}'
```

Apply it. Replace the release name, namespace and values file with your own:

```sh
helm upgrade datadog datadog/datadog -n datadog -f values.yaml
kubectl rollout status daemonset/datadog -n datadog
```

### Datadog Operator

Add the same entry to the `DatadogAgent` resource, then apply it with `kubectl apply -f`:

```yaml
spec:
  override:
    nodeAgent:
      env:
        - name: DD_CONTAINER_LABELS_AS_TAGS
          value: '{"org.opencontainers.image.vendor":"vendor","dev.chainguard.image.title":"cg_image"}'
```

The Operator names the node Agent DaemonSet after the resource plus `-agent`, so for a `DatadogAgent` named `datadog`:

```sh
kubectl rollout status daemonset/datadog-agent -n datadog
```

### Docker or ECS

Set the variable on the Agent container:

```sh
-e DD_CONTAINER_LABELS_AS_TAGS='{"org.opencontainers.image.vendor":"vendor","dev.chainguard.image.title":"cg_image"}'
```

For ECS, add the same name and value to the Agent container's `environment` list in the task definition. The ECS form follows Datadog's documented fields but has not been tested by the authors of this guide.

### Notes

Use only `DD_CONTAINER_LABELS_AS_TAGS`. `DD_DOCKER_LABELS_AS_TAGS` is the legacy name for the same setting, and if both map the same label the legacy one wins. You may see `DD_CONTAINER_IMAGE_LABELS_AS_TAGS` in older write-ups. It is not an Agent setting and is silently ignored.

To roll back, remove the entry and run the same upgrade or apply command. Nothing else depends on it.

Nothing changes on your application containers. The labels are already on every Chainguard image, so there is no Dockerfile or deployment change for the teams that use them.

## Step 2: Confirm the tags are flowing

From the cluster, before any data reaches Datadog, confirm the Agent picked up the setting. With the Operator, use `ds/datadog-agent` in both commands. If you have more than one cluster, add `--context <your-context>` to each command so you check the right one.

```sh
kubectl exec -n datadog ds/datadog -c agent -- agent config | grep -A3 container_labels_as_tags
```

The output should show `container_labels_as_tags` with both mappings, as the JSON string from Step 1 with Helm, or as two key-value lines with the Operator. If it is empty, the variable did not reach the Agent, so check the values file and the rollout.

Then list the tags the Agent attached to running containers:

```sh
kubectl exec -n datadog ds/datadog -c agent -- agent tagger-list | grep -E 'cg_image|vendor:'
```

Chainguard containers show `cg_image:<name>` and `vendor:Chainguard`. Each node runs its own Agent, so pick a pod on a node where a Chainguard container is running if the first one shows nothing.

These commands need permission to exec into pods in the Agent namespace. If your account gets a "forbidden" error, ask a cluster admin to run them, or skip ahead to the Datadog checks below. On EKS Fargate the Agent runs as a sidecar instead of a DaemonSet, so use the Datadog checks there.

A few minutes after the Agent restarts, open Metrics Explorer in Datadog and query `container.cpu.usage` filtered by `vendor:chainguard`. Datadog lowercases tag values, so the label value `Chainguard` shows up as `vendor:chainguard`. Two other quick checks:

- In Infrastructure, open a container you know is a Chainguard image and look for `vendor:chainguard` in its tags.
- Group `container.cpu.usage` by `cg_image`. You should see the Chainguard image names, such as `python` or `node`. Grouping by `vendor` shows `chainguard` next to other vendors that label their images, plus an untagged bucket.

## Step 3: Build the adoption dashboard

The dashboard uses `container.cpu.usage` because every running container emits it, which makes it a reliable stand-in for "what is running right now." Each widget counts distinct containers by grouping on `container_id` and counting the series with `count_not_null`.

| Widget | Query | What it shows |
|---|---|---|
| Chainguard containers (vendor label) | `count_not_null(cg)`, where `cg = sum:container.cpu.usage{vendor:chainguard} by {container_id}` | Running containers whose image still carries the Chainguard vendor label |
| Chainguard-based containers (incl. relabeled) | `count_not_null(cgb)`, where `cgb = sum:container.cpu.usage{cg_image:*} by {container_id}` | Adds containers whose build overwrote the vendor label (they keep the `cg_image` tag) |
| Chainguard adoption (%) | `100 * count_not_null(cgb) / count_not_null(total)`, where `total = sum:container.cpu.usage{*} by {container_id}` | Share of all running containers built on a Chainguard image |
| Non-Chainguard containers | `count_not_null(ncg)`, where `ncg = sum:container.cpu.usage{!cg_image:*} by {container_id}` | Running containers with no Chainguard image label |
| Non-Chainguard images still running | `sum:container.cpu.usage{!cg_image:*} by {short_image,image_tag,kube_namespace}` | Images and tags still running something other than Chainguard. This is the migration backlog |

The dashboard also has "All containers", "Adoption over time (%)" and "Running containers by Chainguard base image" widgets, plus `env` and `kube_namespace` filters at the top.

The dashboard definition is in `assets/dashboard.json` next to this guide. Both options below use it.

There are two ways to create the dashboard. Both produce the same result, so pick one.

- Option A, the Datadog UI: about a minute of clicking. No keys, files or command line.
- Option B, the Datadog API: a few terminal commands. Use it when you want the dashboard in version control or created by a pipeline.

### Option A: Create the dashboard in the Datadog UI

You need a Datadog user who can create dashboards.

1. Open `assets/dashboard.json` and copy all of it.
2. In Datadog, go to Dashboards and click New Dashboard.
3. On the page that opens, under "Or start from scratch", click Blank Dashboard. Datadog creates an empty dashboard with a default name.
4. Click Configure (top right) and choose Import dashboard JSON.
5. Click inside the import window and paste (Cmd+V on Mac, Ctrl+V on Windows). You can also drag `dashboard.json` into the window. The dashboard is renamed "Chainguard Adoption (Runtime)" and fills with eight widgets.
6. Set the `env` and `kube_namespace` filters at the top to the environment you want to see.

### Option B: Create the dashboard with the Datadog API

You need a terminal with `curl`, plus a Datadog API key and application key. Steps B1 and B2 create the keys, and B3 stores them in a file so they never appear on the command line or in shell history.

**B1. Create an API key.** In Datadog, go to Organization Settings, then API Keys, and click New Key. Name it `chainguard-dashboard` and copy the key. If your role cannot create API keys, ask a Datadog admin to create one for you, or copy an existing key your role can view.

**B2. Create an application key.** Go to Organization Settings, then Application Keys, and click New Key. Name it `chainguard-dashboard`. If you scope the key, give it `dashboards_read` and `dashboards_write`. Copy the key right away, because Datadog may not show it again.

**B3. Save both keys in a file that only you can read.** Create the file and lock down its permissions:

```sh
mkdir -p ~/.config/datadog
touch ~/.config/datadog/keys.env
chmod 600 ~/.config/datadog/keys.env
```

Open `~/.config/datadog/keys.env` in a text editor, add these three lines with your own values, and save it:

```
DD_API_KEY=<your API key>
DD_APP_KEY=<your application key>
DD_SITE=datadoghq.com
```

Set `DD_SITE` to the site in your Datadog address: `datadoghq.com` for app.datadoghq.com, `datadoghq.eu` for app.datadoghq.eu, `us3.datadoghq.com` for us3.datadoghq.com, and so on. Keep this file out of Git, and do not paste the keys into chat or tickets.

**B4. Save the dashboard definition.** Copy `assets/dashboard.json` into the directory you will run the commands from.

**B5. Load the keys into your shell and check them.** The first line reads the file into environment variables for this terminal session only:

```sh
set -a; . ~/.config/datadog/keys.env; set +a
curl -s "https://api.${DD_SITE}/api/v1/validate" -H "DD-API-KEY: ${DD_API_KEY}"
```

The response should be `{"valid":true}`. If it is not, check the API key and `DD_SITE`.

**B6. Create the dashboard.** Run this in the same terminal:

```sh
curl -s -X POST "https://api.${DD_SITE}/api/v1/dashboard" \
  -H "DD-API-KEY: ${DD_API_KEY}" \
  -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
  -H "Content-Type: application/json" \
  --data-binary @dashboard.json
```

The response is the new dashboard as JSON. Its `id` field identifies the dashboard, and its `url` field is the path to open, for example `/dashboard/abc-def-ghi/chainguard-adoption-runtime`. Open it under your Datadog address and set the `env` and `kube_namespace` filters.

**B7. Update it later.** Edit `dashboard.json` and send it with PUT to the same id. This updates the existing dashboard instead of creating a copy:

```sh
curl -s -X PUT "https://api.${DD_SITE}/api/v1/dashboard/<id>" \
  -H "DD-API-KEY: ${DD_API_KEY}" \
  -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
  -H "Content-Type: application/json" \
  --data-binary @dashboard.json
```

**B8. Clean up.** When you are finished, revoke the application key under Organization Settings, Application Keys if you created it only for this. Delete the keys file too if you no longer need it.

## Notes and caveats

- The count is containers, not images or services. A deployment with 12 replicas counts 12. That is the right measure for runtime exposure, but say so when you present the number. The total also includes system containers and the Datadog Agent itself, so filter by namespace when you want application adoption only.
- Containers built FROM a Chainguard image inherit the labels unless the build overwrites them. If a team sets its own `org.opencontainers.image.vendor` label, that image drops out of the `vendor:chainguard` count. The `dev.chainguard.image.title` label survives that override, which is why the adoption widgets count on `cg_image` instead of `vendor`.
- "Non-Chainguard" means "no Chainguard label seen." An image whose build strips every `dev.chainguard.*` label would be counted as non-Chainguard. That takes deliberate effort and is rare.
- This is a label check, not proof of origin. Anyone can add a label to a Dockerfile. If you need proof that an image came from Chainguard, verify its signature and SBOM.
- Custom Assembly images keep all the Chainguard labels, so they are counted as Chainguard. Nothing in the image marks them as customized. If you want to track them separately, have the overlay set an environment variable, for example `CG_OVERLAY_CERTS=corp`, and add `DD_CONTAINER_ENV_AS_TAGS='{"CG_OVERLAY_CERTS":"cg_overlay"}'` to the Agent.
- This only counts what the Agent sees. Environments without the Agent, or with container collection disabled, appear in neither the numerator nor the denominator.
- Snapshot the dashboard values before the first migrations land and again at each milestone. That before and after pair is the simplest adoption metric to put in front of leadership, and it pairs well with the CVE reduction numbers in the Chainguard Console.

### Troubleshooting a single image

If an image you expect to be Chainguard shows up as non-Chainguard, check its labels straight from the registry. With `crane` installed and logged in to your registry:

```sh
crane config --platform linux/amd64 cgr.dev/<your-org>/python:latest | jq '.config.Labels'
```

Look for `dev.chainguard.image.title`. If it is there, the image is counted, so check that the Agent setting reached the node it runs on (Step 2). On a Mac with Docker Desktop, do not check with `docker image inspect` unless you pass `--platform`, because a platform that was never pulled shows an empty config with no labels.

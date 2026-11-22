# chainguard-adoption: a Claude Code skill

Track how many of your running containers use Chainguard images, in Datadog. The skill walks you through setup, checks your images, generates the Datadog Agent setting, verifies the Agent, creates an adoption dashboard, and can prove the whole thing locally first.

What you get in Datadog: a "Chainguard Adoption (Runtime)" dashboard with Chainguard container counts, adoption %, adoption over time, the Chainguard images in use, and a list of non-Chainguard images still running (your migration backlog). It measures what is actually running, not what sits in a registry.

## Requirements

- Claude Code
- A Datadog account with the Agent running on your hosts or clusters (Agent 7.33 or later)
- Depending on what you run: `jq` and `crane` (label checks and API), `chainctl` (list your Chainguard repos, log in to cgr.dev), `kubectl` (verify the Agent), `docker`, `kind` and `helm` (local test)

## Install

Personal install, available in every project:

```sh
mkdir -p ~/.claude/skills
git clone https://github.com/Sayre-Tnunu/chainguard-adoption-skill.git ~/.claude/skills/chainguard-adoption
```

Update to the latest version later with:

```sh
git -C ~/.claude/skills/chainguard-adoption pull
```

Project install, shared with everyone who clones a repo: copy this folder to `.claude/skills/chainguard-adoption` in that repo and commit it.

If you are editing the skill yourself, clone it anywhere and symlink it instead, so changes take effect in place:

```sh
ln -s /path/to/chainguard-adoption-skill ~/.claude/skills/chainguard-adoption
```

Claude Code picks up new skills without a restart. Type `/` in the prompt and look for `/chainguard-adoption`, or ask Claude "What skills are available?"

## Run

Start with setup. It asks for your Chainguard org, where your images are pulled from, your Datadog site and org, and how the Agent is deployed, then saves them to `~/.config/chainguard-adoption/config.env` (no secrets).

| Type in the Claude Code prompt | What it does |
|---|---|
| `/chainguard-adoption setup` | Guided setup. Detects what it can (chainctl orgs, Agent DaemonSets) and asks for the rest |
| `/chainguard-adoption` | Menu, current config and suggested next step |
| `/chainguard-adoption labels --all` | Checks every repo in your Chainguard org carries the labels the dashboard counts |
| `/chainguard-adoption labels python:latest node:latest` | Checks specific images (short names use your configured registry) |
| `/chainguard-adoption agent-config` | The Agent setting for your deployment (Helm, Operator, Docker or ECS), with apply and rollback commands |
| `/chainguard-adoption verify` | Confirms the running Agent has the mapping and is tagging containers |
| `/chainguard-adoption dashboard ui` | Copies the dashboard JSON to your clipboard and walks you through the import. No keys needed |
| `/chainguard-adoption dashboard api init-keys` | Creates a keys file with safe permissions for you to fill in |
| `/chainguard-adoption dashboard api validate` | Checks the keys and shows which Datadog org they belong to |
| `/chainguard-adoption dashboard api create` | Creates the dashboard through the API and prints its URL |
| `/chainguard-adoption dashboard api update` | Pushes changes to the same dashboard |
| `/chainguard-adoption check prod` | Live numbers for `env:prod`: Chainguard, non-Chainguard, total, adoption % |
| `/chainguard-adoption guide` | Points you to a setup guide you can share with your platform team |
| `/chainguard-adoption local-test docker` | Local proof on Docker with a dummy key (about 2 minutes, no accounts needed) |
| `/chainguard-adoption local-test kind` | Same on a kind cluster with the Datadog Helm chart |
| `/chainguard-adoption local-test operator` | Same on a kind cluster with the Datadog Operator |
| `/chainguard-adoption teardown` | Removes the local test clusters and containers |

You can also describe what you want in plain language, for example "show me how many of our running containers are Chainguard in Datadog", and Claude loads the skill on its own.

## Keys

Only the API dashboard route and `check` need Datadog keys. They are read from `~/.config/datadog/keys.env` (chmod 600, or the path in `DD_KEYS_FILE`):

```
DD_API_KEY=<your API key>
DD_APP_KEY=<your application key>
```

Fill the file in yourself in an editor. The skill never asks for keys in chat and never prints them. Revoke the application key when you no longer need it.

## How it works

Every Chainguard image carries the labels `org.opencontainers.image.vendor=Chainguard` and `dev.chainguard.image.title=<name>`. Images built from a Chainguard image inherit them, and they survive registry mirrors and retagging. One Datadog Agent setting turns those labels into the tags `vendor` and `cg_image`, and the dashboard counts running containers by those tags. See `docs/setup-guide.md` for the full explanation and caveats.

## Files

- `SKILL.md`: instructions Claude follows
- `docs/setup-guide.md`: shareable setup guide, no Claude required
- `assets/dashboard.json`: the 8-widget dashboard
- `scripts/config.sh`: reads and writes the non-secret settings
- `scripts/check-image-labels.sh`, `scripts/verify-agent.sh`, `scripts/dd-dashboard.sh`: each step as a standalone script that also works without Claude
- `test/`: local Docker, kind (Helm) and kind (Operator) test harness

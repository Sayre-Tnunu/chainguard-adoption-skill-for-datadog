# chainguard-adoption: a Claude Code skill

Track how many of your running containers use Chainguard images, in Datadog. The skill walks you through setup, gives you the one Datadog Agent setting to add, verifies it, creates an adoption dashboard, and can prove the whole thing locally first.

What you get in Datadog: a "Chainguard Adoption (Runtime)" dashboard with Chainguard container counts, adoption %, adoption over time, the Chainguard images in use, and a list of non-Chainguard images still running (your migration backlog). It measures what is actually running, not what sits in a registry.

**Prefer to set it up by hand, or handing this to a platform team?** Follow [docs/setup-guide.md](docs/setup-guide.md). It covers every step without Claude Code: the Agent setting for Helm, the Operator, Docker or ECS, how to confirm it works, and creating the dashboard in the Datadog UI or through the API, including how to create and store the API keys.

## Requirements

- Claude Code
- A Datadog account with the Agent running on your hosts or clusters (Agent 7.33 or later)
- Depending on what you run: `kubectl` (verify the Agent), `jq` (dashboard API and live numbers), `docker`, `kind` and `helm` (local test)

## Install

Personal install, available in every project:

```sh
mkdir -p ~/.claude/skills
git clone https://github.com/Sayre-Tnunu/chainguard-adoption-skill-for-datadog.git ~/.claude/skills/chainguard-adoption
```

Update to the latest version later with:

```sh
git -C ~/.claude/skills/chainguard-adoption pull
```

Project install, shared with everyone who clones a repo: copy this folder to `.claude/skills/chainguard-adoption` in that repo and commit it.

If you are editing the skill yourself, clone it anywhere and symlink it instead, so changes take effect in place:

```sh
ln -s /path/to/chainguard-adoption-skill-for-datadog ~/.claude/skills/chainguard-adoption
```

Claude Code picks up new skills without a restart. Type `/` in the prompt and look for `/chainguard-adoption`, or ask Claude "What skills are available?"

## Run

Five commands, usually run in this order:

| Type in the Claude Code prompt | What it does |
|---|---|
| `/chainguard-adoption setup` | Asks a few questions (Datadog site, how the Agent is deployed, which cluster to check, UI or API dashboard) and saves the answers. No secrets |
| `/chainguard-adoption agent-config` | The one Agent setting for your deployment (Helm, Operator, Docker or ECS), with apply and rollback commands |
| `/chainguard-adoption verify` | Confirms the Agent is tagging containers in the cluster you chose (read-only, works with any cluster your kubectl can reach), and shows live Chainguard counts and adoption % in Datadog |
| `/chainguard-adoption dashboard` | Creates the adoption dashboard, by UI import (no keys) or through the API |
| `/chainguard-adoption local-test` | Optional. Proves the whole thing on your laptop first (Docker, or a throwaway kind cluster with Helm or the Operator). Local only, or send to Datadog to see it on the dashboard. Never touches your real clusters or changes your kubectl context |

Type `/chainguard-adoption` on its own to see where you are and what to do next. You can also describe what you want in plain language, for example "show me how many of our running containers are Chainguard in Datadog", and Claude loads the skill on its own.

## Keys

Only three things need Datadog keys: the API dashboard route, the live numbers in `verify`, and `local-test` when you choose to send the test to Datadog (that one needs only the API key). The UI dashboard route and a local-only test need no keys. Keys are read from `~/.config/datadog/keys.env` (chmod 600, or the path in `DD_KEYS_FILE`):

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
- `scripts/verify-agent.sh`, `scripts/dd-dashboard.sh`: the verify and dashboard steps as standalone scripts that also work without Claude
- `scripts/check-image-labels.sh`: troubleshooting helper for when one image does not show up as Chainguard
- `test/`: local Docker, kind (Helm) and kind (Operator) test harness

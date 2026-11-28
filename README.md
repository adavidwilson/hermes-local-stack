# hermes-local-stack

A rootless Podman (Quadlet) stack that serves a Hermes **Webapp** over **Tailscale**.
The agent runs entirely on **OpenRouter**: the main model, its side tasks (titling,
compression, approval, vision), and delegated children all use
`deepseek/deepseek-v4.1-flash-1017`. There is no local model server, no GPU access, and
no Compose path — model calls leave the container over HTTPS to OpenRouter.

## Topology

```text
device ──Tailscale──▶ hermes-tailscale (container, userspace mode)
                         │  tailscale serve → 127.0.0.1:9120
                         ▼
        hermes-web shares this netns, binds 0.0.0.0:9120 (gateway run)
                         │  HTTPS → openrouter.ai
                         ▼
        deepseek/deepseek-v4.1-flash-1017
```

- Only the **Webapp** is reachable, and only via Tailscale Serve → loopback :9120. Nothing
  binds `0.0.0.0` on the host; no router port forwarding.
- `hermes-web` shares Tailscale's network namespace (`Network=hermes-tailscale.container`)
  and is reachable on the tailnet IP.
- The dashboard (9119) is **not** run.
- No devices are passed into any container, so the host GPU is not part of the deployment.

## Files

| Path | Meaning | Git |
|------|---------|-----|
| `env.example`, `.gitignore`, `TODO.md`, `README.md` | Project files | tracked |
| `scripts/check.sh`, `scripts/brave.sh` | Invariant checks, host browser | tracked |
| `deploy/quadlet/`, `scripts/install-quadlet.sh`, `scripts/render-quadlet-env.sh` | Rootless Podman units, installer, env renderer | tracked |
| `docs/browser-automation.md`, `docs/quadlet.md` | Browser tunnel, Quadlet deployment reference | tracked |
| `runtime/hermes-home/config.yaml` | Instance config | tracked |
| `runtime/hermes-home/` | `.env`, sessions, `state.db`, logs | ignored |
| `runtime/tailscale-state/` | Tailscale state | ignored |
| `deploy/podman/env/` | Generated per-service env files | ignored |
| `.env` | Sign-in creds, OpenRouter key, Tailscale auth key | ignored |

State and secrets are git-ignored: regenerated or backed up, not versioned. Files are
created as `HERMES_UID`/`HERMES_GID` (default 1000); `chown` on the host if your user differs.

## Prerequisites

1. **Podman ≥ 5.4** with a systemd user session, cgroup v2, **crun**, and `pasta`
   (Podman 6 requires it). See [Rootless Podman (Quadlet)](#rootless-podman-quadlet).
   `runc` cannot work here: the rootless `keep-id` container cannot start under it.
2. A **Tailscale auth key** (`TAILSCALE_AUTHKEY`) from the console — Tailscale runs in the
   `tailscale` container, not on the host.
3. An **OpenRouter API key** (`OPENROUTER_API_KEY`).

No model weights, AMD GPU, or Vulkan setup are needed.

## Setup

### 1. Place the repo

Copy the tracked files into a project dir on the host (e.g. `~/hermes-local-stack/`),
keeping the structure including `runtime/` and `scripts/`.

### 2. Secrets

```bash
cp env.example .env
```

Set `DASHBOARD_USERNAME`/`DASHBOARD_PASSWORD` (strong, e.g. `openssl rand -hex 16`),
`TAILSCALE_AUTHKEY`, and `OPENROUTER_API_KEY`. `OPENROUTER_API_KEY` is the only model
credential: it is rendered into `deploy/podman/env/hermes-web.env` and read by the
`openrouter` provider named in `config.yaml`.

### 3. Config

Edit `runtime/hermes-home/config.yaml`:

- `webapp.public_url` → `http://hermes-tailscale.<your-tailnet>.ts.net:9120` (OIDC callback;
  only needed for OIDC).
- `model.default` → the OpenRouter model slug. If you change it, update the matching key
  under `provider_routing.models` too — routing is keyed by the exact slug.

### 4. Bring it up

```bash
bash scripts/install-quadlet.sh --dry-run   # render env, run the systemd generator
bash scripts/install-quadlet.sh             # install into ~/.config/containers/systemd
loginctl enable-linger "$USER"              # survive logout and start at boot
systemctl --user start hermes-web.service   # pulls in tailscale
```

The installer creates the runtime directories, renders `deploy/podman/env/*.env` from
`.env` (only the keys each service needs), refuses root-owned runtime directories, and
adds an optional `HERMES_EXTRA_WORKSPACE` drop-in. Units are generated with absolute
paths, so re-run the installer after editing `deploy/quadlet/`.

### 5. Access

Open `http://hermes-tailscale.<your-tailnet>.ts.net` from a Tailscale-connected device;
enter the basic-auth username/password from `.env`.

### Optional: browser automation

Driving a real Chrome requires an SSH tunnel to the host's browser. See
[`docs/browser-automation.md`](docs/browser-automation.md).

## Rootless Podman (Quadlet)

Two containers and one network, defined as systemd units under `deploy/quadlet/`. The
rootless `hermes-web` startup fix is `UserNS=keep-id` + `User=0`: `keep-id` maps the host
user to container UID 1000, while `User=0` keeps the init process as root so the image's
s6 bootstrap can remap `hermes` and seed `$HERMES_HOME`. Both lines are required — see
[`docs/quadlet.md`](docs/quadlet.md) for the unit reference, caveats, and troubleshooting.

Prerequisites: Podman ≥ 5.4 (6.x requires pasta), cgroup v2, a working `systemctl --user`
session, and `/etc/subuid` + `/etc/subgid` for the user.

## Operation

```bash
systemctl --user status hermes-web.service hermes-tailscale.service
systemctl --user restart hermes-web.service            # after config.yaml edits
journalctl --user -u hermes-web -u hermes-tailscale -f # logs
systemctl --user stop hermes-web.service hermes-tailscale.service
```

The SSH/browser-tunnel config lives at `runtime/hermes-home/home/.ssh/config`
(see [`docs/browser-automation.md`](docs/browser-automation.md)).

## Update

```bash
podman pull docker.io/nousresearch/hermes-agent:v0.23.3
systemctl --user restart hermes-web.service
```

Image tags are pinned in the units; bump the tag there, re-run
`scripts/install-quadlet.sh`, and restart. Editing a unit does not recreate a running
container until the service restarts.

## Backup

```bash
rsync -a runtime/hermes-home/ runtime/hermes-home-backup-$(date +%Y%m%d%H%M%S)/
# Restore: rsync -a runtime/hermes-home-backup-<ts>/ runtime/hermes-home/
#          && systemctl --user restart hermes-web
```

## Verify

```bash
bash scripts/check.sh
```

Checks, with no extra dependencies: the units are present and well formed, every unit
reference resolves, image references are fully qualified, `hermes-web` keeps the
`UserNS=keep-id` + `User=0` pair and shares Tailscale's netns, no secrets live in unit
files, `model.provider` is `openrouter` and `model.default` matches a
`provider_routing.models` entry, `OPENROUTER_API_KEY` is documented in `env.example` and
rendered into `hermes-web.env`, every script named by the docs exists, and — when the
host has Podman's generator — the units are accepted by
`podman-system-generator --dryrun`. It also fails if Compose or local-inference artifacts
come back.

Then, at runtime:

- **Up:** `systemctl --user status hermes-web.service` → `active (running)`;
  `podman ps` shows `hermes-web` and `hermes-tailscale`.
- **Reachable:** from a tailnet device, load the Webapp URL and sign in.
- **Model:** a message in the Webapp returns an answer; `journalctl --user -u hermes-web`
  shows no provider auth errors.

## Troubleshoot

- **Webapp won't start:** `.env` missing/empty, `OPENROUTER_API_KEY` unset (the renderer
  refuses placeholders), or `HERMES_DASHBOARD_BASIC_AUTH_*` missing.
- **`[stage2] ERROR: container started with --user 1000`:** `User=0` is missing from
  `hermes-web.container`, or the unit was not re-installed after an edit.
- **401 / model errors:** `OPENROUTER_API_KEY` is stale in `deploy/podman/env/hermes-web.env`;
  re-run `scripts/render-quadlet-env.sh` and restart the unit.
- **Not reachable on the tailnet:** `podman exec hermes-web tailscale serve status` must
  show the `:9120` rule; re-check `TAILSCALE_AUTHKEY`.
- **Routing silently ignored:** the `provider_routing.models` key must be the exact
  `model.default` slug; `scripts/check.sh` catches a mismatch.

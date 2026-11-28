# hermes-local-stack

A container stack — Docker Compose, or rootless Podman with Quadlet — that serves a Hermes
**Webapp** over **Tailscale**, with **local inference on the host GPU** via **llama.cpp
(Vulkan)**. The main model routes through OpenRouter; the local model is the fallback and
runs side tasks (titling, compression, approval, vision) so background traffic stays free.

## Topology

```text
device ──Tailscale──▶ hermes-tailscale (container)
                         │  http://127.0.0.1:9120
                         ▼
        hermes-web shares this netns, binds 0.0.0.0:9120 (gateway run)
                         │  http://inference:8080/v1   (hermes-stack net only)
                         ▼
        inference (llama-server, Vulkan) — /dev/dri, no ports published
```

- Only the **Webapp** is reachable, and only via Tailscale Serve → loopback :9120. Nothing binds
  `0.0.0.0` on the host; no router port forwarding.
- `hermes-web` uses `network_mode: service:tailscale`, so it shares Tailscale's network namespace
  and is reachable on the tailnet IP.
- **Inference publishes no ports**; only `hermes-web` reaches it over the internal `hermes-stack`
  network.
- The dashboard (9119) is **not** run. GPU access is scoped to `inference` only (`/dev/dri`); no
  `privileged`, extra libs, custom image, or `HSA_OVERRIDE`.

## Files

| Path | Meaning | Git |
|------|---------|-----|
| `compose.yaml`, `env.example`, `.gitignore`, `TODO.md`, `README.md` | Project files | tracked |
| `scripts/prestart.sh`, `scripts/check.sh`, `scripts/brave.sh` | Setup, invariant checks, host browser | tracked |
| `deploy/quadlet/`, `scripts/install-quadlet.sh`, `scripts/render-quadlet-env.sh`, `scripts/check-quadlet.sh` | Rootless Podman units, installer, env renderer | tracked |
| `docs/browser-automation.md`, `docs/rootless-podman.md`, `docs/quadlet-migration.md` | Browser tunnel, rootless and Quadlet plans | tracked |
| `runtime/hermes-home/config.yaml` | Instance config | tracked |
| `runtime/models/models.ini` | llama.cpp model presets | tracked |
| `runtime/hermes-home/` | `.env`, sessions, `state.db`, logs | ignored |
| `runtime/models/` | GGUF weights | ignored |
| `runtime/tailscale-state/` | Tailscale state | ignored |
| `deploy/podman/env/` | Generated per-service env files for Quadlet | ignored |
| `ssh_config` | SSH config for the browser tunnel | ignored |
| `.env` | Sign-in creds + Tailscale auth key | ignored |

Weights, state, and secrets are git-ignored: regenerated or backed up, not versioned. Files are
created as `HERMES_UID`/`HERMES_GID` (default 1000); `chown` on the host if your user differs.

## Prerequisites

1. **Docker + Compose**, or **Podman ≥ 5.4** with a systemd user session (see
   [Rootless Podman (Quadlet)](#rootless-podman-quadlet)).
2. A **Tailscale auth key** (`TAILSCALE_AUTHKEY`) from the console — Tailscale runs in the
   `tailscale` container, not on the host.
3. A **GGUF** at the path in `runtime/models/models.ini` (see *Model weights*).
4. An **AMD Radeon** with a working Vulkan path. This targets **RDNA1 (gfx1010, e.g. RX 5700 XT)**,
   which is **not** ROCm-supported; `HSA_OVERRIDE_GFX_VERSION` only helps RDNA 2/3. **Vulkan is the
   engine.**

## Setup

### 1. Place the repo

Copy the tracked files into a project dir on the host (e.g. `~/hermes-local-stack/`), keeping the
structure including `runtime/` and `scripts/`.

### 2. Prepare runtime directories

Docker creates missing bind-mount sources as root-owned directories, which the non-root Hermes user
(and the SSH-config mount) can't use. Run this once before `docker compose up` (needs root / sudo,
since two items must be root-owned):

```bash
sudo bash scripts/prestart.sh
```

It creates `runtime/hermes-home`, `runtime/models`, `runtime/tailscale-state`, and an empty
`ssh_config`, then chowns `runtime/hermes-home` and `runtime/models` to `HERMES_UID`/`HERMES_GID`
and `runtime/tailscale-state` + `ssh_config` to `root:root`.

### 3. Secrets

```bash
cp env.example .env
```

Set `DASHBOARD_USERNAME`/`DASHBOARD_PASSWORD` (strong, e.g. `openssl rand -hex 16`),
`TAILSCALE_AUTHKEY`, and `LLAMA_API_KEY`. `LLAMA_API_KEY` is one value used twice: the inference
server requires it, and `config.yaml` names it via `key_env`.

### 4. Model weights

Ships configured for **Qwen3.6-35B-A3B** (`runtime/models/models.ini`). Download the GGUF and
`mmproj` to the paths it lists:

```bash
mkdir -p runtime/models/Qwen3.6
# runtime/models/Qwen3.6/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf
# runtime/models/Qwen3.6/mmproj-F16.gguf
sha256sum runtime/models/Qwen3.6/*.gguf   # verify against the source
```

Different model? Edit `runtime/models/models.ini`, then `providers.llama-cpp.default_model` in
`config.yaml` to match the preset name.

### 5. Config

Edit `runtime/hermes-home/config.yaml`:

- `webapp.public_url` → `http://hermes-tailscale.<your-tailnet>.ts.net:9120` (OIDC callback; only
  needed for OIDC).
- `model.default` → your OpenRouter model. If you change it, update the matching key under
  `provider_routing.models` too — routing is keyed by the exact slug.
- `providers.llama-cpp.default_model` → the preset stem served by default.

### 6. Bring it up

```bash
docker compose up -d
```

### 7. Access

Open `http://hermes-tailscale.<your-tailnet>.ts.net` from a Tailscale-connected device; enter the
basic-auth username/password from `.env`.

### Optional: browser automation

Driving a real Chrome requires an SSH tunnel to the host's browser. See
[`docs/browser-automation.md`](docs/browser-automation.md).

## Operation

```bash
docker compose ps                 # status
docker compose logs -f hermes-web # agent / Webapp
docker compose logs -f inference  # llama-server
docker compose restart hermes-web # after config.yaml edits
docker compose down               # stop (keeps runtime/)
```

## Rootless Podman (Quadlet)

`compose.yaml` is the Docker path. On a Podman host the same services are defined as
systemd units under `deploy/quadlet/` (one network + three containers); no Compose
provider is involved. The rootless `hermes-web` startup fix is expressed as
`UserNS=keep-id` + `User=0`: `keep-id` maps the host user to container UID 1000, while
`User=0` keeps the init process as root so the image's s6 bootstrap can remap `hermes`
and seed `$HERMES_HOME`. See `docs/quadlet-migration.md` for the comparison and
`docs/rootless-podman.md` for the ownership rules.

Prerequisites: Podman ≥ 5.4 (6.x requires pasta), cgroup v2, a working `systemctl --user`
session, `/etc/subuid` + `/etc/subgid` for the user, and membership in `video` and
`render` for `/dev/dri`.

```bash
bash scripts/install-quadlet.sh --dry-run   # render units, run the systemd generator
bash scripts/install-quadlet.sh             # install into ~/.config/containers/systemd
loginctl enable-linger "$USER"              # survive logout and start at boot
systemctl --user start hermes-web.service   # pulls in inference + tailscale
```

The installer renders `deploy/podman/env/*.env` from `.env` (only the keys each service
needs), refuses root-owned runtime directories, and adds an optional
`HERMES_EXTRA_WORKSPACE` drop-in. Units are generated with absolute paths, so re-run the
installer after editing `deploy/quadlet/`.

```bash
systemctl --user status hermes-web.service hermes-inference.service hermes-tailscale.service
systemctl --user restart hermes-web.service        # after config.yaml edits
journalctl --user -u hermes-web -u hermes-inference -u hermes-tailscale -f
bash scripts/check-quadlet.sh                      # static unit checks + generator dry-run
```

Image tags are pinned; update with `podman pull` followed by
`systemctl --user restart <unit>`. Do not run the compose stack and the Quadlet units at
the same time: they share container names and `runtime/tailscale-state`. Rollback is
`systemctl --user stop ...` then `docker compose up -d`.

For browser automation, the SSH config lives at
`runtime/hermes-home/home/.ssh/config` (see `docs/browser-automation.md`); the Quadlet
units do not mount the compose-only `/root/.ssh/config`.

## Update

```bash
docker compose pull               # newer images (setup-time egress)
docker compose up -d              # re-create to match compose.yaml
```

## Backup

```bash
rsync -a runtime/hermes-home/ runtime/hermes-home-backup-$(date +%Y%m%d%H%M%S)/
# Restore: rsync -a runtime/hermes-home-backup-<ts>/ runtime/hermes-home/ && docker compose restart hermes-web
```

## Verify

```bash
bash scripts/check.sh
```

Checks, with no extra dependencies: `compose.yaml` validates, every `key_env` in `config.yaml` is
documented in `env.example`, every script the README names exists, and the configured
`default_model` is a real `models.ini` preset.

Then, at runtime:

- **Up:** `docker compose ps` → `hermes-web` and `inference` `Up` (and `Healthy` once the
  healthchecks pass — inference needs a minute to load the model on RDNA1).
- **Inference internal only:** `docker compose exec hermes-web curl -H "Authorization: Bearer $LLAMA_API_KEY" http://inference:8080/v1/models`
  succeeds; host `curl http://127.0.0.1:8080/v1/models` fails (expected — no published ports).

## Troubleshoot

- **Webapp won't start:** `.env` missing/empty or `HERMES_DASHBOARD_BASIC_AUTH_*` unset.
- **Inference "No devices found":** image must be the `server-vulkan` tag with
  `devices: /dev/dri:/dev/dri` (Vulkan, not ROCm, on RDNA1).
- **401 from the local provider:** `LLAMA_API_KEY` must be the value the server was started with —
  `config.yaml` reads it from the container environment via `key_env: LLAMA_API_KEY`.
- **Slow / OOM:** the model spills to RAM when `ngl` is too high for the card (`models.ini` sets
  `ngl = 41` under `[*]`); lower it or pick a smaller model.
- **Model not selectable:** the preset name in `config.yaml` must match a `[section]` in
  `models.ini`; `scripts/check.sh` catches this for `default_model`.

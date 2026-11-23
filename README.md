# hermes-local-stack

A Docker Compose stack that runs a **local-only** Hermes instance and serves its **Webapp**
(Hermes Desktop in a browser) over **Tailscale**, with **local** inference on the host GPU
via **llama.cpp (Vulkan)**. Cloudflare Workers AI free tier is configured if desired as a fallback.

## Browser Automation

1. On the client, create a key: `ssh-keygen -t ed25519 -f /opt/data/home/.ssh/chromecdp_ed25519 -C chromecdp`
2. On the server, create the account and key file:

```bash
sudo useradd --create-home --shell /usr/sbin/nologin chromecdp
sudo install -d -o chromecdp -g chromecdp -m 700 /home/chromecdp/.ssh
sudoedit /home/chromecdp/.ssh/authorized_keys
```

3. On the client, run `cat ~/.ssh/chromecdp_ed25519.pub`. Paste its output into the server’s `authorized_keys`, prefixed with:

```bash
restrict,port-forwarding,permitopen="127.0.0.1:9222"
```

4. Then on the server:

```bash
sudo chown chromecdp:chromecdp /home/chromecdp/.ssh/authorized_keys
sudo chmod 600 /home/chromecdp/.ssh/authorized_keys
```

5. On the server, add to `/etc/ssh/sshd_config`:

```bash
Match User chromecdp
   PubkeyAuthentication yes
   PasswordAuthentication no
   KbdInteractiveAuthentication no
   AllowTcpForwarding local
   PermitOpen 127.0.0.1:9222
   AllowAgentForwarding no
   X11Forwarding no
   PermitTTY no
   PermitTunnel no
   MaxSessions 0
```

6. Validate and reload SSH on the server:

```bash
sudo sshd -t
sudo systemctl reload ssh
```

7. Add an ssh configuration named `ssh_config` to the repo:

```bash
Host <machine>
	Hostname <machine>.<tailnet>.ts.net
	User chromecdp
	IdentityFile /opt/data/home/.ssh/chromecdp_ed25519
	SessionType none
	ExitOnForwardFailure yes
	ConnectTimeout 5
	LocalForward 9222 127.0.0.1:9222
```

**Note:** The compose file is already set to bind mount this to the correct
directory. The file must be owned by root: `chown root:root ssh_config`.

8. Start the tunnel on the client: `ssh <machine>`

**Note:** Add necessary firewall rules if needed for SSH on the host.

9. Run the browser on the host: `./brave.sh`

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
| `compose.yaml`, `env.example`, `README.md` | Project files | tracked |
| `runtime/hermes-home/config.yaml` | Instance config | tracked |
| `runtime/models/models.ini` | llama.cpp model preset | tracked |
| `runtime/hermes-home/` | `.env`, sessions, `state.db`, logs | ignored |
| `runtime/models/` | GGUF weights | ignored |
| `runtime/tailscale-state/` | Tailscale state | ignored |
| `.env` | Sign-in creds + Tailscale auth key | ignored |

Weights, state, and secrets are git-ignored: regenerated or backed up, not versioned. Files are
created as UID 1000 via `HERMES_UID`; `chown` on the host if your user differs.

## Prerequisites

1. **Docker + Compose** on the host.
2. A **Tailscale auth key** (`TAILSCALE_AUTHKEY`) from the console — Tailscale runs in the
   `tailscale` container, not on the host.
3. A **GGUF** at the path in `runtime/models/models.ini` (see *Model weights*).
4. An **AMD Radeon** with a working Vulkan path. This targets **RDNA1 (gfx1010, e.g. RX 5700 XT)**,
   which is **not** ROCm-supported; `HSA_OVERRIDE_GFX_VERSION` only helps RDNA 2/3. **Vulkan is the
   engine.**

## Setup

### 1. Place the repo

Copy the tracked files into a project dir on the host (e.g. `~/hermes-local-stack/`), keeping the
structure including `runtime/`.

### 2. Secrets

```bash
cp env.example .env
```

Set `DASHBOARD_USERNAME`/`DASHBOARD_PASSWORD` (strong, e.g. `openssl rand -hex 16`) and
`TAILSCALE_AUTHKEY`.

### 3. Model weights

Ships configured for **Tiel-Coder-35B-A3B-UD-Q4_K_XL** (`runtime/models/models.ini`). Download the
GGUF + `mmproj` to the paths it lists:

```bash
mkdir -p runtime/models/Tiel
# runtime/models/Tiel/Tiel-Coder-35B-A3B-UD-Q4_K_XL.gguf  and  runtime/models/Tiel/mmproj-BF16.gguf
sha256sum runtime/models/Tiel/*.gguf   # verify against the source
```

Different model? Edit `runtime/models/models.ini` and the `llama-cpp` provider in `config.yaml`.

### 4. Config

Edit `runtime/hermes-home/config.yaml`:

- `webapp.public_url` → `http://hermes-tailscale.<your-tailnet>.ts.net:9120` (OIDC callback).
- `providers.llama-cpp.model` → served model stem (optional; unset to query `/v1/models`).

### 5. Bring it up

```bash
docker compose up -d
```

### 6. Access

Open `http://hermes-tailscale.<your-tailnet>.ts.net` from a Tailscale-connected device; enter the
basic-auth username/password from `.env`.

## Operation

```bash
docker compose ps                 # status
docker compose logs -f hermes-web # agent / Webapp
docker compose logs -f inference  # llama-server
docker compose restart hermes-web # after config.yaml edits
docker compose down               # stop (keeps runtime/)
```

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
docker compose -f compose.yaml config >/dev/null && echo CONFIG_OK
```

- **Up:** `docker compose ps` → `hermes-web` and `inference` `Up`.
- **Inference internal only:** `docker compose exec hermes-web curl http://inference:8080/v1/models`
  succeeds; host `curl http://127.0.0.1:8080/v1/models` fails (expected — no published ports).

## Troubleshoot

- **Webapp won't start:** `.env` missing/empty or `HERMES_DASHBOARD_BASIC_AUTH_*` unset.
- **Inference "No devices found":** image must be the `server-vulkan` tag with
  `devices: /dev/dri:/dev/dri` (Vulkan, not ROCm, on RDNA1).
- **Slow / OOM:** the model spills to RAM on small cards (`models.ini` sets no `ngl`); pick a
  smaller model or add RAM.
- **Model not selectable:** set `providers.llama-cpp.model` to the served stem, or unset it.

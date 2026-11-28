# Quadlet migration: is it better, and what changes

Status: the units, env renderer, installer, and checks are implemented under
`deploy/quadlet/` and `scripts/`; the cutover from compose has not been executed. The
unit files use `@REPO@` placeholders that `scripts/install-quadlet.sh` substitutes with
the absolute repo path, so the snippets below show the installed form.

## Recommendation

**Yes — if this host is committing to Podman, make Quadlet the primary deployment and
stop maintaining the compose stack as a live deployment path.** Keep `compose.yaml` only
as a frozen Docker fallback (or delete it), because dual-maintaining compose and Quadlet
is the one outcome worse than either.

Quadlet does not replace the image-level fix; it replaces the orchestration layer. The
`hermes-web` blocker is the same `UserNS=keep-id` + `User=0` combination. What Quadlet
removes is the layer that caused the rest of the rootless friction:

- no external Compose provider (`podman-compose` vs `docker-compose`), no
  `x-podman.in_pod`, no provider-specific `userns_mode` parsing;
- health-gated startup is native (`Notify=healthy` + systemd ordering) instead of
  provider-dependent `depends_on: condition: service_healthy`;
- boot is native (`[Install] WantedBy=default.target` + linger), not a hand-written unit
  wrapping `compose up`;
- one lifecycle tool (`systemctl --user`), one log sink (journald), native restart
  policy, and `podman auto-update` if you ever move off pinned tags.

It is *not* better if you need the same definition to run under Docker. Quadlet is
Podman-only and systemd-only; there is no portable artifact.

## Differences that matter for this stack

| Concern | Compose (current) | Quadlet |
|---|---|---|
| Unit of deployment | One YAML file, project-scoped | 4 files: `.network` + 3 `.container`, user-scoped |
| Orchestrator | `podman-compose` or `docker-compose` via `podman compose` | Podman's systemd generator; no provider |
| `userns_mode` | Provider parses/forwards it; `podman-compose` additionally needs `in_pod: false` | `UserNS=keep-id` passed straight to Podman; no pod layer |
| Init-user override | `user: "0"` | `User=0` |
| `network_mode: service:...` | `service:tailscale` | `Network=hermes-tailscale.container` (Quadlet adds the unit dependency) |
| Network | `networks: hermes-stack` created on `up` | `hermes-stack.network` unit, name preserved with `NetworkName=hermes-stack` |
| Dependency + readiness | `depends_on: condition: service_healthy` (podman-compose support varies) | `Requires=`/`After=` + `Notify=healthy` on the dependency |
| Boot | `restart: unless-stopped` does **not** start at boot; needs linger + a wrapper unit or `podman-restart.service` (which only starts `restart-policy=always`) | `[Install] WantedBy=default.target`; generator enables it; linger keeps the user manager alive |
| Restart | Container restart policy | `[Service] Restart=always` (systemd) |
| Logs | `json-file` (alias for `k8s-file` under Podman; `max-file` ignored) | `journald` by default; `journalctl --user -u <unit>` |
| Health | `healthcheck:` map | `HealthCmd=`, `HealthInterval=`, `HealthTimeout=`, `HealthRetries=`, `HealthStartPeriod=` |
| Updates | `podman compose pull && up -d` | `AutoUpdate=registry` + `podman-auto-update.timer` (needs mutable tags; current pinned tags won't update) |
| Secrets/env | `.env` interpolation; only listed vars injected per service | `EnvironmentFile=` per unit; systemd file parsing (no `${VAR}` interpolation, no `export`) |
| Resource limits | `deploy.resources` (compose semantics vary) | `Memory=`, `CPUQuota=`/`CPUWeight=` on the service, `PidsLimit=` |
| Ad-hoc operations | `compose up/down/ps/logs/restart` | `systemctl --user start/stop/status`; `podman ps/logs/exec` |
| Portability | Docker + Podman | Podman + systemd only |
| Failure visibility | Provider errors | `systemctl status`, `journalctl`, `podman-system-generator --dryrun` |

Two behavioral differences worth calling out:

1. **Stop propagation.** Compose `depends_on` does not stop the dependent when the
   dependency stops. Systemd `Requires=` + `After=` does. For `hermes-web` this is
   arguably correct for `tailscale` (it shares the netns) and debatable for `inference`;
   choose `Requires=` or `Wants=` deliberately.
2. **Netns-sharing restarts.** If `hermes-tailscale` is restarted, `hermes-web` is left
   in the old network namespace. Compose has the same bug. Add
   `PartOf=hermes-tailscale.container` (or `BindsTo=`) to `hermes-web` so restarting
   Tailscale restarts the web container too.

## Proposed layout

Repo:

```text
deploy/quadlet/
  hermes-stack.network
  hermes-tailscale.container
  hermes-inference.container
  hermes-web.container
deploy/podman/env/          # generated, git-ignored, 0600
  tailscale.env
  inference.env
  hermes-web.env
scripts/render-quadlet-env.sh
```

Host: symlink or copy the four units into `~/.config/containers/systemd/`. Absolute
`%h` paths below make symlinking safe; the generator follows symlinks.

### hermes-stack.network

```ini
[Network]
NetworkName=hermes-stack
```

`NetworkName` keeps the Podman network named `hermes-stack` instead of the default
`systemd-hermes-stack`, so `podman network inspect hermes-stack` and the compose-era
name still match.

### hermes-tailscale.container

```ini
[Unit]
Description=Hermes Tailscale sidecar

[Container]
ContainerName=hermes-tailscale
HostName=hermes-tailscale
Image=docker.io/tailscale/tailscale:v1.104.7
EnvironmentFile=%h/hermes-local-stack/deploy/podman/env/tailscale.env
Environment=TS_STATE_DIR=/var/lib/tailscale
Environment=TS_USERSPACE=true
Volume=%h/hermes-local-stack/runtime/tailscale-state:/var/lib/tailscale
Network=hermes-stack.network
HealthCmd=tailscale status
HealthInterval=10s
HealthTimeout=5s
HealthRetries=12
HealthStartPeriod=30s
Notify=healthy
LogDriver=journald

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=120

[Install]
WantedBy=default.target
```

Userspace mode is already the image default; stating it makes the rootless contract
explicit. No `AddCapability`/`AddDevice`; inbound access still comes from
`tailscale serve` (userspace mode does not forward inbound TCP on its own).

### hermes-inference.container

```ini
[Unit]
Description=Hermes local inference (llama.cpp Vulkan)

[Container]
ContainerName=hermes-inference
Image=ghcr.io/ggml-org/llama.cpp:server-vulkan-v1.0.0-b12359-b1b770d
Entrypoint=/app/llama-server
Exec=--api-key ${LLAMA_API_KEY} --no-webui --models-preset /models/models.ini
EnvironmentFile=%h/hermes-local-stack/deploy/podman/env/inference.env
Volume=%h/hermes-local-stack/runtime/models:/models:ro
AddDevice=/dev/dri
GroupAdd=keep-groups
Network=hermes-stack.network
HealthCmd=curl -f localhost:8080/health
HealthInterval=10s
HealthTimeout=5s
HealthRetries=30
HealthStartPeriod=90s
Notify=healthy
LogDriver=journald

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=300

[Install]
WantedBy=default.target
```

`Exec=` replaces the image CMD; `Entrypoint=` preserves the compose entrypoint override.
`${LLAMA_API_KEY}` is expanded by systemd from `EnvironmentFile` (hex key, no word
splitting). `GroupAdd=keep-groups` is the rootless GPU access requirement; the host user
must be in `video` and `render`. `TimeoutStartSec=300` covers the RDNA1 model load plus
health start period; systemd's default 90 s is too short.

### hermes-web.container

```ini
[Unit]
Description=Hermes web gateway
Requires=hermes-tailscale.container hermes-inference.container
After=hermes-tailscale.container hermes-inference.container
PartOf=hermes-tailscale.container

[Container]
ContainerName=hermes-web
Image=docker.io/nousresearch/hermes-agent:v0.23.3
Exec=gateway run
UserNS=keep-id
User=0
EnvironmentFile=%h/hermes-local-stack/deploy/podman/env/hermes-web.env
Volume=%h/hermes-local-stack/runtime/hermes-home:/opt/data
Volume=%h/Organize:/opt/data/workspace/projects/Organize
Network=hermes-tailscale.container
HealthCmd=curl -fsS --max-time 3 http://127.0.0.1:8642/health
HealthInterval=10s
HealthTimeout=5s
HealthRetries=15
HealthStartPeriod=30s
Notify=healthy
LogDriver=journald

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=300

[Install]
WantedBy=default.target
```

`UserNS=keep-id` + `User=0` is the same fix as the compose overlay:
`keep-id` maps host `$UID` to container UID 1000, and `User=0` keeps the init process as
root so the image's s6 bootstrap can remap `hermes` and seed `$HERMES_HOME` without
tripping the image's `--user` guard.

`Requires=` + `After=` gives compose-style "do not start until the dependency is
healthy" because both dependencies set `Notify=healthy`. `PartOf=` makes a Tailscale
restart restart the web container, which is required because it shares Tailscale's
network namespace.

### Environment files

Compose's `.env` cannot be used verbatim as a shared systemd `EnvironmentFile` without
injecting every secret into every container. Generate per-service files from `.env`
once, in `scripts/render-quadlet-env.sh` (called by `install-quadlet.sh`):

| File | Keys |
|---|---|
| `tailscale.env` | `TS_AUTHKEY` |
| `inference.env` | `LLAMA_API_KEY` |
| `hermes-web.env` | `DASHBOARD_USERNAME`, `DASHBOARD_PASSWORD`, `LLAMA_API_KEY`, `HERMES_UID`, `HERMES_GID` |

`HERMES_UID`/`HERMES_GID` are written from `id -u`/`id -g` at render time rather than
trusting the compose default of 1000. The generated directory is git-ignored and mode
0700; files mode 0600.

## Migration plan

### Phase 0 — gate

Do not cut over until these hold on the host:

- Podman ≥ 5.4 (6.x is current in 2026; 5.4 is the first version with the
  `Network=$name.container` ordering fix). Podman 6 requires netavark/aardvark v2 and
  **pasta** (slirp4netns and CNI are gone); cgroup v2 only.
- `systemctl --user` works, `loginctl enable-linger "$USER"` succeeds.
- `/etc/subuid` and `/etc/subgid` have a range for the user.
- The standalone `hermes-web` spike from `docs/rootless-podman.md` passes:
  `--userns=keep-id --user 0` reaches `[stage2] Setup complete`.
- The user is in the `video` and `render` groups.

### Phase 1 — author and dry-run units

1. Run `bash scripts/install-quadlet.sh --dry-run`. It renders the three env files,
   substitutes `@REPO@` with the absolute repo path, and runs
   `podman-system-generator --dryrun`.
2. Install with `bash scripts/install-quadlet.sh` (copies units to
   `~/.config/containers/systemd/` and runs `daemon-reload`).
3. Confirm the generated unit:
   ```bash
   systemctl --user cat hermes-web.service
   ```
   The output must show `--userns keep-id --user 0`, `--network container:...`,
   and the generated `After=`/`Requires=` ordering.
4. Pre-pull all three images (`podman pull ...`) so the first start is not a pull race.

### Phase 2 — parallel smoke test, then switch

1. `docker compose down` (or the current Podman compose stack down) to free container
   names and Tailscale state.
2. `systemctl --user start hermes-web.service` — this pulls in tailscale and inference.
3. Verify:
   ```bash
   systemctl --user status hermes-tailscale.service hermes-inference.service hermes-web.service
   journalctl --user -u hermes-web.service -n 50   # no --user guard, no chown EPERM
   podman healthcheck run hermes-web
   podman exec --user hermes hermes-web id
   find runtime/hermes-home -maxdepth 1 ! -user "$(id -u)" -print
   podman exec hermes-web curl -fsS -H "Authorization: Bearer $LLAMA_API_KEY" \
     http://inference:8080/v1/models
   podman exec hermes-web tailscale serve status
   ```
4. Open `http://hermes-tailscale.<tailnet>.ts.net:9120` from a tailnet device.

### Phase 3 — boot and lifecycle

1. `loginctl enable-linger "$USER"` (once).
2. `systemctl --user reboot`-equivalent test: reboot or `loginctl terminate-user "$USER"`,
   then confirm all three units come back with no login session.
3. `systemctl --user restart hermes-web.service` after a `config.yaml` edit; confirm the
   container is recreated and the config is picked up.
4. `systemctl --user restart hermes-tailscale.service`; confirm `PartOf=` restarts the
   web container and networking recovers.

### Phase 4 — tooling and docs

1. Rewrite `scripts/check.sh` for Quadlet: validate the units with the generator
   `--dryrun`, assert `UserNS=keep-id` implies `User=0`, assert per-service env keys
   match the `.env` source, and assert image references are fully qualified.
2. README: replace the compose operation block with `systemctl --user` commands and a
   short "why Quadlet" note. Keep a Docker section only if you keep `compose.yaml`.
3. Decide the fate of `compose.yaml`:
   - **Quadlet-only (recommended):** delete it and the Podman overlay after one verified
     release; no dual maintenance.
   - **Docker fallback:** freeze it, mark it unsupported for Podman, and keep the
     `user: "0"` / SSH-path fixes so it still works under both engines.
4. Optional: `AutoUpdate=registry` + `systemctl --user enable --now podman-auto-update.timer`
   only after switching to mutable tags; pinned `v0.23.3`/`v1.104.7`/`v1.0.0-b12359`
   will never auto-update.

## Rollback

```bash
systemctl --user stop hermes-web.service hermes-inference.service hermes-tailscale.service
podman compose -f compose.yaml -f compose.podman.yaml up -d
```

Both stacks can coexist on disk; they cannot coexist as running stacks when they share
`ContainerName` and `runtime/tailscale-state`. Rollback is a stop/start, not a data
migration, because every Quadlet bind mount points at the same host paths.

## Caveats

- **Quadlet units are transient.** `systemctl enable` does not work; boot enabling comes
  from `[Install]` applied by the generator. `daemon-reload` is required after edits.
- **Editing a unit does not recreate a running container** until the service is
  restarted.
- **Network unit updates are not applied in place**; changing `hermes-stack.network`
  requires deleting the Podman network and restarting the units.
- **`Network=$name.container` ordering** is broken before Podman 5.4; on 5.3 it works only
  if the referenced unit is processed first. Pin ≥ 5.4 or use
  `Network=container:hermes-tailscale` plus explicit `[Unit]` dependencies.
- **Podman 6 quadlet install layout changed** (subdirectories instead of `.app` files).
  Placing units manually avoids depending on `podman quadlet install` behavior.
- **`EnvironmentFile` is not a compose `.env` parser.** No `export`, no `${VAR}`
  expansion inside values, and quoting rules differ. The render script keeps the
  translation explicit; do not point units at `.env` directly.
- **`Notify=healthy` requires a healthcheck** and converts the dependency's start into
  "healthy before dependent starts." A service that never becomes healthy blocks its
  dependents until `TimeoutStartSec`; that is the intended replacement for
  `depends_on: service_healthy`.
- **Compose parity gaps**: no project scoping, no profiles, no `--scale`, no
  `compose logs -f` equivalent that follows all three (use
  `journalctl --user -u hermes-web -u hermes-inference -u hermes-tailscale -f`).

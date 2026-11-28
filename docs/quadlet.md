# Quadlet deployment

The stack is deployed as rootless Podman Quadlet units — there is no Compose path.
Two containers and one network, all owned by the invoking user's systemd session:

```text
deploy/quadlet/
  hermes-stack.network        NetworkName=hermes-stack
  hermes-tailscale.container  tailscale sidecar, userspace mode, `tailscale serve`
  hermes-web.container        gateway, shares tailscale's netns
deploy/podman/env/            generated, git-ignored, 0600
  tailscale.env
  hermes-web.env
```

`hermes-web` runs the agent and the Webapp on `deepseek/deepseek-v4.1-flash-1017`
through OpenRouter. There is no local inference service: model calls leave the host
over HTTPS, so no GPU devices are passed into any container and no model weights live
on disk.

## Why Quadlet

- Health-gated startup is native (`Notify=healthy` + systemd ordering) instead of a
  provider-dependent `depends_on` condition.
- Boot is native (`[Install] WantedBy=default.target` + linger), not a wrapper unit.
- One lifecycle tool (`systemctl --user`), one log sink (`journalctl`), native
  restart policy.
- No external orchestration provider to pin or debug, and `UserNS=keep-id` is
  passed straight to Podman.

## Units

### hermes-stack.network

```ini
[Network]
NetworkName=hermes-stack
```

`NetworkName` keeps the Podman network named `hermes-stack` instead of the default
`systemd-hermes-stack`.

### hermes-tailscale.container

`TS_USERSPACE=true` is the only mode that works rootless without `NET_ADMIN` or
`/dev/net/tun`. Userspace networking does not forward inbound TCP on its own —
inbound access comes from `tailscale serve`, which relays inside `tailscaled`.
State lives in `runtime/tailscale-state`.

### hermes-web.container

```ini
[Unit]
Requires=hermes-tailscale.container
After=hermes-tailscale.container
PartOf=hermes-tailscale.container

[Container]
UserNS=keep-id
User=0
PodmanArgs=--runtime=crun
Network=hermes-tailscale.container
EnvironmentFile=@REPO@/deploy/podman/env/hermes-web.env
Volume=@REPO@/runtime/hermes-home:/opt/data
```

`UserNS=keep-id` + `User=0` is the rootless startup fix: `keep-id` maps the host
user to container UID 1000 so the `hermes` user owns the bind mount, while `User=0`
keeps the init process as root so the image's s6 bootstrap can remap `hermes` and
seed `$HERMES_HOME` without tripping the image's `--user` guard. Both lines are
required — `keep-id` alone trips the guard.

`Requires=` + `After=` gate startup on Tailscale becoming healthy. `PartOf=` makes a
Tailscale restart restart the web container too, because it shares Tailscale's
network namespace. `PodmanArgs=--runtime=crun` is required: `keep-id` creates an
unprivileged user namespace, and `runc` cannot mount `sysfs` there — it fails at
container init with `error mounting "sysfs" ... operation not permitted`. `crun`
bind-mounts the host's `/sys` instead, so the unit must not run under `runc`. `@REPO@`
is substituted with the absolute repo path by `scripts/install-quadlet.sh`.

## Environment files

`.env` holds every secret for the stack. `scripts/render-quadlet-env.sh` writes one
file per service with only the keys that service needs, because a shared systemd
`EnvironmentFile` would inject every secret into every container:

| File | Keys |
|---|---|
| `tailscale.env` | `TS_AUTHKEY` |
| `hermes-web.env` | `DASHBOARD_USERNAME`, `DASHBOARD_PASSWORD`, `OPENROUTER_API_KEY`, `HERMES_UID`, `HERMES_GID` |

`HERMES_UID`/`HERMES_GID` come from `id -u`/`id -g` at render time, not from the
`.env` default. `OPENROUTER_API_KEY` reaches the container as a normal environment
variable; Hermes reads it for the `openrouter` provider named in `config.yaml`.
The generated directory is git-ignored and mode 0700, files mode 0600.

## Install

```bash
bash scripts/install-quadlet.sh --dry-run   # render env, substitute paths, run the generator
bash scripts/install-quadlet.sh             # install into ~/.config/containers/systemd
loginctl enable-linger "$USER"              # survive logout and start at boot
systemctl --user start hermes-web.service   # pulls in tailscale
```

The installer refuses root-owned runtime directories, creates
`runtime/hermes-home`, `runtime/tailscale-state`, `runtime/hermes-home/home/.ssh`,
and adds an optional `HERMES_EXTRA_WORKSPACE` drop-in. Units are generated with
absolute paths, so re-run it after editing `deploy/quadlet/`.

## Operate

```bash
systemctl --user status hermes-web.service hermes-tailscale.service
systemctl --user restart hermes-web.service        # after config.yaml edits
journalctl --user -u hermes-web -u hermes-tailscale -f
bash scripts/check.sh                              # static invariants + generator dry-run
```

The Webapp is reached through `tailscale serve` on the tailnet at
`http://hermes-tailscale.<tailnet>.ts.net:9120`, using the basic-auth credentials
from `.env`.

Image tags are pinned; update with `podman pull` followed by
`systemctl --user restart <unit>`. Editing a unit does not recreate a running
container until the service is restarted.

## Backup

```bash
rsync -a runtime/hermes-home/ runtime/hermes-home-backup-$(date +%Y%m%d%H%M%S)/
# Restore: rsync -a runtime/hermes-home-backup-<ts>/ runtime/hermes-home/
#          && systemctl --user restart hermes-web
```

## Caveats

- **Quadlet units are transient.** `systemctl enable` does not work; boot enabling
  comes from `[Install]` applied by the generator. `daemon-reload` is required after
  edits.
- **Network unit updates are not applied in place**; changing
  `hermes-stack.network` requires deleting the Podman network and restarting the units.
- **`EnvironmentFile` is not a `.env` parser.** No `export`, no `${VAR}` expansion
  inside values, and different quoting rules. Do not point units at `.env` directly.
- **`Notify=healthy` requires a healthcheck** and turns the dependency's start into
  "healthy before dependent starts". A service that never becomes healthy blocks its
  dependents until `TimeoutStartSec`.
- **`Network=$name.container` ordering** is broken before Podman 5.4; pin ≥ 5.4.
- **Podman 6 quadlet install layout changed.** Installing units by copying to
  `~/.config/containers/systemd/` avoids depending on `podman quadlet install`.

## Troubleshooting

- **`[stage2] ERROR: container started with --user 1000`** — `User=0` is missing from
  `hermes-web.container`, or the unit was not re-installed after an edit.
- **`error mounting "sysfs" ... operation not permitted` at container create** — the
  container ran under `runc`. `keep-id` needs a userns and `runc` cannot mount sysfs
  inside one. Install crun (`sudo pacman -S crun` on Arch), confirm
  `podman info --format '{{.Host.OCIRuntime.Name}}'`, re-run
  `scripts/install-quadlet.sh`, then restart. The unit already pins
  `PodmanArgs=--runtime=crun`; if it still happens, crun is missing or broken.
- **Files in `runtime/hermes-home` owned by a subuid** — `HERMES_UID` in the rendered
  `hermes-web.env` differs from the host UID; re-run the env renderer.
- **Container unreachable on the tailnet** — `podman exec hermes-web tailscale serve status`
  must show the `:9120` rule; re-check the Tailscale auth key in `.env`.
- **401/model errors from OpenRouter** — `OPENROUTER_API_KEY` is missing or stale in
  `deploy/podman/env/hermes-web.env`; re-run `scripts/render-quadlet-env.sh` and restart
  the unit. The model slug in `config.yaml` must match the `provider_routing.models`
  entry, and `scripts/check.sh` verifies both.

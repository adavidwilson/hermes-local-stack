# Rootless Podman: changes and migration plan

Status: proposed, not implemented. Everything below is derived from the compose file,
scripts, image source (`docker/entrypoint-dispatch.sh`, `docker/stage2-hook.sh`,
`docker/main-wrapper.sh`), and the Podman/Tailscale documentation cited at the end.
Podman is not installed in this environment, so none of the container-level steps have
been executed here; each one has an explicit verification command for the host.

> For the systemd/Quadlet deployment path, the same UID requirement applies
> (`UserNS=keep-id` + `User=0`). See `docs/quadlet-migration.md`; the manifests under
> `deploy/quadlet/` implement it.

## 1. What works and what does not

Already rootless in practice (per operator): `tailscale` and `inference`.

The single blocker is `hermes-web`, and it is structural, not a tuning problem:

- The image must **start as root (UID 0)**. Its stage2 bootstrap remaps the `hermes`
  user to `HERMES_UID`, seeds `$HERMES_HOME`, fixes ownership, and then every service
  drops to `hermes` via `s6-setuidgid` (`docker/stage2-hook.sh`, `docker/main-wrapper.sh`).
- Podman's `userns_mode: keep-id` maps host `$UID` to **container UID 1000**, but also
  makes the container's **init process run as the current user's UID** unless `--user`
  is set explicitly (podman `--userns` docs). s6 therefore starts as UID 1000 and the
  image's guard rejects it:
  `[stage2] ERROR: container started with --user 1000 ...` — or the bootstrap runs
  without root and cannot remap/chown.
- Without `keep-id`, rootless Podman maps container root to the host user, so s6 starts
  correctly, but the dropped `hermes` UID 1000 maps to a **subuid** on the host. It can
  then not write `runtime/hermes-home` (owned by host UID 1000), and stage2's `chown`
  fails with EPERM on host files (`chown ... failed (rootless container?)`).
- You cannot map both container UID 0 and container UID 1000 to the same host UID:
  UID mappings are one-to-one. So "root bootstrap + unprivileged hermes that owns the
  host bind mount" cannot be expressed by passing a single `--userns` mode.

The fix is to keep `keep-id` (so `hermes` = host user) and start the container **as
root** so s6 can bootstrap:

```yaml
userns_mode: keep-id
user: "0"          # overrides keep-id's "init runs as host UID" default
```

That is exactly the combination the Podman docs allow: `keep-id` maps the host user to
container UID 1000, and an explicit `--user` only overrides which UID the init process
starts as. `HERMES_UID/HERMES_GID` must still equal the host UID/GID (the compose
defaults of 1000 are correct only for UID 1000 hosts).

## 2. Secondary incompatibilities

| Area | Current | Rootless Podman behavior | Change |
|---|---|---|---|
| `ssh_config` mount | `./ssh_config:/root/.ssh/config`, owner `root:root` 0600 | An explicit `user: "0"` runs as the *subuid-mapped* root, and `hermes` is UID 1000; neither can traverse `/root` (0700, unique to image root) or read a host-root-owned file | Keep `~/.ssh/config` inside `HERMES_HOME/home/.ssh/` (already where the key lives), owned by the host user; drop the mount and the root-owned `ssh_config` file |
| `runtime/tailscale-state` | `prestart.sh` chowns `root:root`, mode 700 | tailscale container runs with the default mapping (container root = host user), so it cannot read/write a host-root-owned 0700 dir | Own it by the invoking user, 0700; migrate once with `chown -R $(id -u):$(id -g)` |
| `prestart.sh` | Needs `sudo`; chowns to root | Rootless has no root-owned bind sources; running it with sudo reintroduces exactly the ownership it must avoid | Run unprivileged; refuse sudo; create dirs as the caller |
| Logging | `json-file`, `max-size`, `max-file` | Podman accepts `json-file` as an **alias for `k8s-file`**; it supports `max-size` but **not `max-file`** (no rotation-count implementation) | Accept the alias; `max-file` is a no-op. If you want real rotation, switch to `journald` (no size options) |
| `cap_add: net_admin/net_raw` | tailscale service | Tailscale's `TS_USERSPACE` defaults to `true` in the image; userspace mode needs neither capability. Rootless can add them only inside the container's user namespace, where they do nothing useful | Optional: drop them in the Podman overlay (`cap_add: []`) |
| Tailscale inbound | `tailscale serve` to `127.0.0.1:9120` | Userspace networking does **not** forward inbound TCP by itself; `tailscale serve` does, because the relay happens in `tailscaled` | Keep Serve. Verify rules survive restarts in `runtime/tailscale-state` |
| GPU `/dev/dri` | `devices: /dev/dri:/dev/dri` | Rootless can bind the device, but the process must carry the host's `video`/`render` group to pass the device node's mode bits; Podman's mapping drops supplementary groups | Add `group_add: ["keep-groups"]` (requires `crun`); confirm the host user is in `video` and `render` |
| Compose provider | `docker compose` | `podman compose` is a wrapper around `docker-compose` or `podman-compose`; docker-compose wins if installed | Pin one provider. If `podman-compose`: top-level `x-podman.in_pod: false` is mandatory for `userns_mode` |
| Boot | `restart: unless-stopped` | Rootless containers need lingering; `podman-restart.service` only starts `restart-policy=always`, so `unless-stopped` containers are not started at boot | `loginctl enable-linger` + a user unit that runs compose `up -d` (snippet below) |
| Ports | none published | No change; 9120 > 1024, and the webapp is reached through Tailscale Serve | — |
| SELinux | none (CachyOS/Arch) | If ever enabled, `:Z` labels and `--security-opt label=disable` for the GPU device are needed | Not applicable on this host |

## 3. File changes

### compose.yaml

- Remove the `./ssh_config:/root/.ssh/config` volume from `hermes-web`.
- Keep `userns_mode: keep-id`.
- Leave everything else unchanged (images, healthchecks, `network_mode: service:tailscale`,
  `devices`, `depends_on` all work on both engines).

### compose.podman.yaml (new overlay)

```yaml
# Rootless Podman overrides. Not used by Docker.
#   podman compose -f compose.yaml -f compose.podman.yaml up -d
x-podman:
  # podman-compose runs compose services in a pod by default, and a pod's
  # user namespace is fixed at pod creation; userns_mode is ignored/illegal
  # there. Standalone containers are required for keep-id.
  in_pod: false

services:
  hermes-web:
    # keep-id maps host $UID to container UID 1000, but by default also starts
    # the container as $UID. The image's s6 bootstrap must start as root so it
    # can remap the hermes user and seed $HERMES_HOME; this pin is what makes
    # the image's `--user` guard pass.
    user: "0"

  inference:
    # Rootless Podman drops the caller's supplementary groups; without this the
    # process cannot open /dev/dri/renderD128 (root:render 0660).
    group_add:
      - keep-groups

  tailscale:
    # TS_USERSPACE defaults to true in the image; these caps are then unused
    # and cannot do anything outside the container's user namespace.
    cap_add: []
```

### scripts/prestart.sh

- Drop `sudo`; fail with a clear message if run as root.
- `install -d -m 755 runtime/hermes-home runtime/models`.
- `install -d -m 700 runtime/tailscale-state`.
- Create `runtime/hermes-home/home/.ssh` (0700) if missing.
- Delete the `ssh_config` file creation and all root chowns.
- One-time migration for an existing Docker deployment:
  `sudo chown -R "$(id -u):$(id -g)" runtime/tailscale-state` (and `ssh_config` can be
  deleted once its contents are moved).

### docs/browser-automation.md

- `ssh_config` lives at `runtime/hermes-home/home/.ssh/config` (inside the mounted
  `HERMES_HOME`, git-ignored), owned by the host user, mode 0600.
- No bind mount, no `root:root` chown; the existing identity path
  `/opt/data/home/.ssh/chromecdp_ed25519` stays correct.

### scripts/check.sh

- Detect the provider instead of hard-coding `docker compose`:
  `podman-compose` if present (daemonless, parses without a running socket), else
  `docker compose`, else `podman compose`.
- Validate both files: `... -f compose.yaml -f compose.podman.yaml config -q`.
- Add one invariant that encodes this failure: if `hermes-web` has
  `userns_mode: keep-id`, then `compose.podman.yaml` must pin `user: "0"`; otherwise
  the next image update silently reintroduces the s6 startup failure.
- Update the prestart bind-source list (drop `ssh_config`, add
  `runtime/hermes-home/home/.ssh`).

### README.md / env.example

- Prerequisites: Docker + Compose **or** Podman 5.x + a pinned Compose provider,
  `crun`, `passt`/`slirp4netns`, and a `/etc/subuid` + `/etc/subgid` range for the user.
- Setup: `bash scripts/prestart.sh` (no sudo).
- Operation: `podman compose -f compose.yaml -f compose.podman.yaml up -d`; keep the
  Docker commands in a parallel block.
- `HERMES_UID/HERMES_GID` must match `id -u`/`id -g`; `keep-id` maps that exact UID.
- Note that `logging.options.max-file` is ignored under Podman.

### Boot unit (user scope)

```ini
# ~/.config/systemd/user/hermes-stack.service
[Unit]
Description=Hermes local stack (rootless podman)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=%h/hermes-local-stack
Environment=PODMAN_COMPOSE_PROVIDER=/usr/bin/podman-compose
ExecStart=/usr/bin/podman compose -f compose.yaml -f compose.podman.yaml up -d
ExecStop=/usr/bin/podman compose -f compose.yaml -f compose.podman.yaml down
TimeoutStartSec=600

[Install]
WantedBy=default.target
```

```bash
loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable --now hermes-stack.service
```

If the `docker-compose` provider is pinned instead, also
`systemctl --user enable --now podman.socket` (the wrapper needs it) and set
`PODMAN_COMPOSE_PROVIDER=/usr/bin/docker-compose`.

## 4. Verification plan

Run on the host, as the target user, in this order. Stop at the first failure.

1. **Host preflight**
   ```bash
   podman info --format '{{.Host.Security.Rootless}} {{.Host.OCIRuntime.Name}} {{.Host.LogDriver}}'
   id -u; id -g; grep "$USER" /etc/subuid /etc/subgid
   id -nG | tr ' ' '\n' | grep -E '^(video|render)$'
   ```
   Expect rootless `true`, `crun`, a subuid/subgid range, and both GPU groups.

2. **Reproduce the blocker, then prove the fix with the image alone**
   ```bash
   podman run --rm --userns=keep-id \
     -e HERMES_UID="$(id -u)" -e HERMES_GID="$(id -g)" \
     -v "$PWD/runtime/hermes-home:/opt/data" \
     nousresearch/hermes-agent:v0.23.3 gateway run
   # expected failure: [stage2] ERROR: container started with --user <uid>

   podman run --rm --userns=keep-id --user 0 \
     -e HERMES_UID="$(id -u)" -e HERMES_GID="$(id -g)" \
     -v "$PWD/runtime/hermes-home:/opt/data" \
     nousresearch/hermes-agent:v0.23.3 gateway run
   # expected: "Changing hermes UID to 1000" then "Setup complete; starting user services"
   ```
   While the second run is up, in another shell:
   ```bash
   podman exec <container> s6-setuidgid hermes id
   # uid=1000 gid=1000, and files created in /opt/data are host-owned by $(id -u)
   ```
   This is the load-bearing test: it isolates `hermes-web` from compose, Tailscale,
   and the inference service.

3. **Compose up**
   ```bash
   bash scripts/prestart.sh
   podman compose -f compose.yaml -f compose.podman.yaml up -d
   podman compose -f compose.yaml -f compose.podman.yaml ps
   podman logs hermes-web | head -40        # no --user guard, no chown EPERM loop
   ```
   Expect all three `Up`; `hermes-web` and `inference` become `healthy` after the
   inference model load.

4. **Ownership and reporting**
   ```bash
   find runtime/hermes-home -maxdepth 1 ! -user "$(id -u)" -print
   find runtime/tailscale-state ! -user "$(id -u)" -print
   ```
   Both must print nothing. Files created by the agent in a test session must be
   host-owned.

5. **Network path**
   ```bash
   podman exec hermes-web curl -fsS -H "Authorization: Bearer $LLAMA_API_KEY" \
     http://inference:8080/v1/models
   podman exec hermes-web tailscale serve status
   ```
   From a tailnet device: open `http://hermes-tailscale.<tailnet>.ts.net:9120` and sign in.

6. **Boot**
   `systemctl --user restart hermes-stack` then `loginctl terminate-user $USER`
   (or reboot) and confirm all three containers come back without a login session.

7. **Invariants**
   `bash scripts/check.sh` (passes with the new provider-aware checks).

## 5. Risks and fallbacks

- **`s6-overlay` under root-in-userns.** The image's bootstrap assumes root; in a
  rootless user namespace root is real UID 0 with full capabilities inside that
  namespace, so `usermod`, `/run` writes and `s6-setuidgid` work. The one operation it
  cannot do is `chown` host bind-mount inodes (EPERM); with `keep-id` the ownership is
  already correct, so the code skips that branch. If a future image starts chowning
  unconditionally, this breaks — pin the image tag and keep the step-2 spike as a
  pre-upgrade gate.
- **Provider divergence.** `podman-compose` honors `x-podman` and `userns_mode`
  directly; `docker-compose` (via `podman compose`) sends `userns_mode` through Podman's
  Docker-compatible API. Test the chosen provider once with `podman compose config`
  and record it in the README; do not leave selection to "whichever is installed".
- **Fallback A (image-level):** build a small derived image with `usermod -u 1000 hermes`
  baked in and `USER hermes`, plus `--init` so the entrypoint's non-PID-1 path skips
  s6. This loses supervision (dashboard, per-profile gateways), so it is only for a
  single `gateway run` deployment.
- **Fallback B (hybrid):** keep `hermes-web` rootful (`sudo podman`) while `tailscale`
  and `inference` stay rootless. Works today, but leaves the most privileged container
  (agent with terminal access to the host bind mount) as the rootful one — the opposite
  of the security goal.
- **Rollback:** the overlay is additive. `podman compose -f compose.yaml down` reverts to
  the Docker path once `runtime/tailscale-state` is chowned back to `root:root` if the
  Docker deployment needs it (root can read a user-owned dir either way, so this is
  usually unnecessary).

## References

- Podman `--userns` semantics (`keep-id` init UID override, `--user`): podman
  `userns.container.md`.
- `podman compose` provider selection: `podman-compose.1`.
- podman-compose `x-podman.in_pod` and `userns_mode` constraint: `docs/Extensions.md`.
- Podman log drivers (`json-file` alias for `k8s-file`, no `max-file`): `podman-container.unit.5`
  and the `max-file` discussion (#20985).
- Tailscale userspace networking and inbound `serve` relay: Tailscale
  `docs/concepts/userspace-networking`, Docker parameters (`TS_USERSPACE` default true),
  and the userspace inbound-TCP write-up.
- Rootless GPU access via `--group-add keep-groups`: RamaLama docs and Podman GPU guides.
- Container startup contract: `docker/entrypoint-dispatch.sh`, `docker/stage2-hook.sh`,
  `docker/main-wrapper.sh`, `docker/hermes-exec-shim.sh` in `NousResearch/hermes-agent`.

#!/usr/bin/env bash
# Install the Quadlet units for this stack into the user's systemd unit search
# path, render per-service env files, and validate the generated units with
# Podman's systemd generator.
#
# Run as the user that will own the rootless containers (never with sudo).
#
# Usage: scripts/install-quadlet.sh [--dry-run] [--start]
#   --dry-run   render + validate only; do not install or reload systemd
#   --start     start hermes-web.service after installing (pulls in deps)
set -euo pipefail

cd "$(dirname "$0")/.."
repo=$PWD

dry_run=false
start=false
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) dry_run=true; shift ;;
		--start) start=true; shift ;;
		-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
		*) echo "install-quadlet: unknown argument: $1" >&2; exit 2 ;;
	esac
done

ok() { printf '  ok    %s\n' "$1"; }
warn() { printf '  warn  %s\n' "$1"; }
die() { printf 'install-quadlet: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" != 0 ] || die "run as your normal user, not root (rootless units live in the user's systemd session)"
[ -f .env ] || die ".env not found — run: cp env.example .env && edit it"
[ -d deploy/quadlet ] || die "deploy/quadlet missing"

# --- Host preflight -------------------------------------------------------
if ! command -v podman >/dev/null 2>&1; then
	die "podman is not installed"
fi

podman_version=$(podman --version 2>/dev/null | awk '{print $3}')
if [ -n "$podman_version" ] && [ "$(printf '%s\n5.4.0\n' "$podman_version" | sort -V | head -n1)" != "5.4.0" ]; then
	warn "podman $podman_version is older than 5.4; Network=<unit>.container ordering is broken before 5.4"
fi
ok "podman ${podman_version:-unknown}"

if ! podman info --format '{{.Host.Security.Rootless}}' >/dev/null 2>&1; then
	warn "podman info failed; rootless mode could not be confirmed"
elif [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "false" ]; then
	warn "podman reports rootful mode; these units are written for rootless"
fi
ok "podman is reachable"

grep -q "^$(id -un):" /etc/subuid /etc/subgid 2>/dev/null \
	&& ok "subuid/subgid range exists for $(id -un)" \
	|| warn "no /etc/subuid + /etc/subgid entry for $(id -un); rootless userns will fail"

if command -v pasta >/dev/null 2>&1; then
	ok "pasta present"
else
	warn "pasta not found; Podman 6 requires pasta (slirp4netns was removed)"
fi

if command -v loginctl >/dev/null 2>&1; then
	linger=$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)
	if [ "$linger" = "yes" ]; then
		ok "systemd linger enabled"
	else
		warn "linger is off; run: loginctl enable-linger $(id -un) (otherwise units stop at logout)"
	fi
fi

# --- Runtime directories --------------------------------------------------
install -d -m 755 runtime/hermes-home
install -d -m 700 runtime/tailscale-state
install -d -m 700 runtime/hermes-home/home/.ssh

uid=$(id -u)
gid=$(id -g)
for path in runtime/hermes-home runtime/tailscale-state; do
	if [ -e "$path" ] && [ "$(stat -c %u "$path")" != "$uid" ]; then
		die "$path is owned by uid $(stat -c %u "$path"), not $uid. Fix it as root first:
    sudo chown -R $uid:$gid $path"
	fi
done
if [ -e runtime/tailscale-state ] && \
	[ -n "$(find runtime/tailscale-state ! -user "$uid" -print -quit 2>/dev/null)" ]; then
	die "runtime/tailscale-state contains files not owned by $uid. Fix it as root first:
    sudo chown -R $uid:$gid runtime/tailscale-state"
fi
ok "runtime directories are owned by $uid:$gid"

# --- Render env files -----------------------------------------------------
bash scripts/render-quadlet-env.sh

# --- Stage and validate units --------------------------------------------
stage=$(mktemp -d "${TMPDIR:-/tmp}/hermes-quadlet.XXXXXX")
trap 'rm -rf "$stage"' EXIT

repo_escaped=${repo//|/\\|}
for src in deploy/quadlet/*; do
	[ -f "$src" ] || continue
	dest="$stage/$(basename "$src")"
	sed "s|@REPO@|$repo_escaped|g" "$src" >"$dest"
done

grep -q "@REPO@" "$stage"/* 2>/dev/null && die "unsubstituted @REPO@ left in a unit"

generator=""
validated=false
for candidate in \
	"$(command -v podman-system-generator 2>/dev/null || true)" \
	/usr/lib/systemd/system-generators/podman-system-generator \
	/usr/libexec/systemd/system-generators/podman-system-generator; do
	[ -n "$candidate" ] && [ -x "$candidate" ] && { generator=$candidate; break; }
done

if [ -n "$generator" ]; then
	if QUADLET_UNIT_DIRS="$stage" "$generator" --user --dryrun >"$stage/generated.txt" 2>"$stage/generated.err"; then
		validated=true
		ok "podman-system-generator accepted the units"
		grep -qE -- '--userns(=| )keep-id' "$stage/generated.txt" \
			&& ok "hermes-web generates keep-id userns" \
			|| warn "hermes-web generated unit does not show a keep-id userns"
		grep -qE -- '--user(=| )0' "$stage/generated.txt" \
			&& ok "hermes-web generates --user 0" \
			|| warn "hermes-web generated unit does not show --user 0"
	else
		sed -n '1,20p' "$stage/generated.err" >&2
		die "podman-system-generator rejected the units (see above)"
	fi
else
	warn "podman-system-generator not found; skipped generator validation"
fi

if $dry_run; then
	if $validated; then
		printf '\nDry run complete: units rendered and generator-checked (staging dir removed).\n'
	else
		printf '\nDry run complete: units rendered; generator validation was skipped (staging dir removed).\n'
	fi
	exit 0
fi

# --- Install --------------------------------------------------------------
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
install -d -m 755 "$unit_dir"

for src in "$stage"/*.container "$stage"/*.network; do
	[ -f "$src" ] || continue
	install -m 644 "$src" "$unit_dir/$(basename "$src")"
done
ok "installed units to $unit_dir"

# Optional extra workspace mount, as a drop-in so the base unit stays static.
dropin_dir="$unit_dir/hermes-web.container.d"
extra=$(sed -n 's/^[[:space:]]*\(export[[:space:]]*\)\{0,1\}HERMES_EXTRA_WORKSPACE[[:space:]]*=[[:space:]]*//p' .env | tail -n1)
case "$extra" in
	\"*\") extra=${extra#\"}; extra=${extra%\"} ;;
	\'*\') extra=${extra#\'}; extra=${extra%\'} ;;
esac
if [ -n "$extra" ]; then
	case "$extra" in
		/*) extra_path=$extra ;;
		*) extra_path="$repo/$extra" ;;
	esac
	extra_path=$(realpath -m "$extra_path")
	[ -d "$extra_path" ] || warn "HERMES_EXTRA_WORKSPACE=$extra does not exist; Podman will create it"
	install -d -m 755 "$dropin_dir"
	{
		printf '# Generated by scripts/install-quadlet.sh\n'
		printf '[Container]\n'
		printf 'Volume=%s:/opt/data/workspace/projects/Organize\n' "$extra_path"
	} >"$dropin_dir/10-extra-workspace.conf"
	ok "extra workspace mounted from $extra_path"
else
	rm -f "$dropin_dir/10-extra-workspace.conf"
	rmdir "$dropin_dir" 2>/dev/null || true
fi

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
	systemctl --user daemon-reload
	ok "systemctl --user daemon-reload"
	systemctl --user cat hermes-web.service >/dev/null 2>&1 \
		&& ok "generated hermes-web.service is visible" \
		|| warn "hermes-web.service not visible yet; check: systemctl --user daemon-reload"
else
	warn "systemd user manager unavailable here; run 'systemctl --user daemon-reload' on the host"
fi

if command -v podman >/dev/null 2>&1; then
	if podman ps --format '{{.Names}}' 2>/dev/null | grep -qE '^(hermes-web|hermes-tailscale)$'; then
		warn "containers with these names are already running; restart the units to pick up new definitions"
	fi
fi

cat <<EOF

Installed. Next:
  systemctl --user start hermes-web.service      # pulls in tailscale
  systemctl --user status hermes-web.service hermes-tailscale.service
  journalctl --user -u hermes-web.service -n 50

hermes-web does not start until tailscale is healthy (Notify=healthy).
EOF

if $start; then
	systemctl --user start hermes-web.service
	ok "started hermes-web.service"
fi

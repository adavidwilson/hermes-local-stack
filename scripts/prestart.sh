#!/usr/bin/env bash
# Create the runtime directories and the ssh_config mount source before the first
# `docker compose up`. Docker would otherwise create missing bind-mount sources as
# root-owned directories, which the non-root Hermes user cannot use.
#
# Needs root: runtime/tailscale-state and ssh_config stay root-owned (Tailscale keys
# and the CDP tunnel config are security-sensitive).
set -euo pipefail

cd "$(dirname "$0")/.."

# Optional .env overrides (HERMES_UID/HERMES_GID); parsed, not sourced.
env_get() {
	[ -f .env ] || return 0
	sed -n "s/^$1=//p" .env | tail -n 1
}

hermes_uid="${HERMES_UID:-$(env_get HERMES_UID)}"
hermes_gid="${HERMES_GID:-$(env_get HERMES_GID)}"
hermes_uid="${hermes_uid:-1000}"
hermes_gid="${hermes_gid:-1000}"

install -d -m 755 runtime/hermes-home
install -d -m 755 runtime/models
install -d -m 700 runtime/tailscale-state

# Mount source for the SSH config; an empty file is valid (no tunnel configured).
[ -f ssh_config ] || : >ssh_config

chown -R "${hermes_uid}:${hermes_gid}" runtime/hermes-home runtime/models
chown -R root:root runtime/tailscale-state
chown root:root ssh_config
chmod 600 ssh_config

echo "prestart: runtime/ ready (hermes-home ${hermes_uid}:${hermes_gid}, tailscale-state + ssh_config root:root)"

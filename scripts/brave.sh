#!/usr/bin/env bash
# Launch the host browser with CDP on :9222. The profile lives at the repo root
# (Browser-Profile/, git-ignored) so repeated runs keep logins and cookies.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
profile="${repo_root}/Browser-Profile"

exec brave \
	--user-data-dir="$profile" \
	--remote-debugging-port=9222 \
	--no-first-run \
	--no-default-browser-check

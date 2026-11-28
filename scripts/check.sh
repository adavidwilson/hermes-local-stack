#!/usr/bin/env bash
# Cheap invariant checks for this stack: no test framework, no dependencies beyond
# bash + grep. Every check encodes a drift that has actually occurred in this repo.
set -uo pipefail

cd "$(dirname "$0")/.."

fail=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }
warn() { printf '  warn  %s\n' "$1"; }
skip() { printf '  skip  %s\n' "$1"; }

config=runtime/hermes-home/config.yaml
presets=runtime/models/models.ini

# 1. compose syntax + interpolation (uses .env when present, else env.example).
if docker compose version >/dev/null 2>&1; then
	envf=.env
	[ -f "$envf" ] || envf=env.example
	if docker compose --env-file "$envf" -f compose.yaml config -q 2>/dev/null; then
		ok "compose.yaml validates"
	else
		bad "compose.yaml does not validate (docker compose config)"
	fi
else
	skip "docker compose unavailable — compose.yaml not validated"
fi

# 2. Every provider key_env must be a variable env.example documents, or compose's
#    LLAMA_API_KEY contract silently breaks.
missing=0
while IFS= read -r key; do
	[ -n "$key" ] || continue
	grep -q "^${key}=" env.example || { bad "key_env ${key} missing from env.example"; missing=1; }
done < <(sed -n 's/^[[:space:]]*key_env:[[:space:]]*//p' "$config" | tr -d '"' | sort -u)
[ "$missing" = 0 ] && ok "provider key_env values are documented in env.example"

# 3. Every scripts/*.sh path the docs tell the reader to run must exist.
missing=0
while IFS= read -r path; do
	[ -n "$path" ] || continue
	[ -f "$path" ] || { bad "docs reference missing ${path}"; missing=1; }
done < <(grep -ho 'scripts/[A-Za-z0-9_.-]*\.sh' README.md docs/*.md | sort -u)
[ "$missing" = 0 ] && ok "every script referenced by README/docs exists"

# 4. The configured default model must be a preset the server actually serves.
default_model=$(sed -n 's/^[[:space:]]*default_model:[[:space:]]*//p' "$config" | head -n 1 | tr -d '"')
if [ -n "$default_model" ]; then
	grep -qx "\[${default_model}\]" "$presets" \
		&& ok "default_model ${default_model} is a models.ini preset" \
		|| bad "default_model ${default_model} has no [${default_model}] preset in models.ini"
fi

# 5. Bind-mount sources under ./ should exist before `docker compose up` (prestart).
for src in runtime/hermes-home runtime/tailscale-state ssh_config; do
	[ -e "$src" ] || warn "bind source ${src} missing — run: sudo bash scripts/prestart.sh"
done

exit "$fail"

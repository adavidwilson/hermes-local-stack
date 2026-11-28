#!/usr/bin/env bash
# Cheap invariant checks for this stack: no test framework, no dependencies beyond
# bash + grep. Every check encodes a drift that has actually occurred in this repo
# or a design decision that must not silently come back (Compose, local inference).
#
# Usage: bash scripts/check.sh
set -uo pipefail

cd "$(dirname "$0")/.."

fail=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }
warn() { printf '  warn  %s\n' "$1"; }
skip() { printf '  skip  %s\n' "$1"; }

config=runtime/hermes-home/config.yaml
units=deploy/quadlet
need() { [ -f "$units/$1" ] || { bad "missing $units/$1"; return 1; }; }
contains() { grep -qxF -- "$2" "$units/$1" 2>/dev/null; }
section() { awk -v key="$1:" '$0 ~ "^"key"$"{f=1;next} /^[^[:space:]#]/{f=0} f' "$config"; }

# --- Units ---------------------------------------------------------------
for f in hermes-stack.network hermes-tailscale.container hermes-web.container; do
	need "$f" && ok "$f present"
done

# Every Quadlet reference must resolve to a unit file; the generator aborts with
# "unable to translate dependency" otherwise (e.g. inference.container vs
# hermes-inference.container).
missing_refs=0
while IFS= read -r ref; do
	[ -n "$ref" ] || continue
	[ -f "$units/$ref" ] || { bad "unit references missing $ref"; missing_refs=1; }
done < <(grep -hoE '[A-Za-z0-9_.-]+\.(container|network)' "$units"/*.container | sort -u)
[ "$missing_refs" = 0 ] && ok "every referenced container/network unit exists"

# Every container unit must be bootable, named, and use an FQ image reference.
for f in "$units"/*.container; do
	name=$(basename "$f")
	grep -q '^ContainerName=' "$f" || bad "$name has no ContainerName="
	grep -q '^\[Install\]' "$f" && grep -q '^WantedBy=default.target' "$f" \
		&& ok "$name installs into default.target" \
		|| bad "$name has no [Install] WantedBy=default.target (will not start at boot)"
	image=$(sed -n 's/^Image=//p' "$f")
	case "$image" in
		*/*:*) ok "$name has a fully qualified image reference" ;;
		*) bad "$name image '$image' is not fully qualified (registry/repo:tag)" ;;
	esac
done

# The rootless hermes-web fix is a pair: keep-id alone starts the container as the
# host UID and trips the image's s6 bootstrap guard.
contains hermes-web.container 'UserNS=keep-id' \
	&& ok "hermes-web uses UserNS=keep-id" \
	|| bad "hermes-web does not set UserNS=keep-id"
contains hermes-web.container 'User=0' \
	&& ok "hermes-web pins User=0 (init as root for s6)" \
	|| bad "hermes-web sets UserNS=keep-id without User=0 — the image's --user guard will reject startup"

# runc cannot mount sysfs in an unprivileged userns; keep-id needs one.
contains hermes-web.container 'PodmanArgs=--runtime=crun' \
	&& ok "hermes-web pins the crun OCI runtime" \
	|| bad "hermes-web lacks PodmanArgs=--runtime=crun — under runc it fails at container init with 'error mounting sysfs: operation not permitted'"

contains hermes-web.container 'Network=hermes-tailscale.container' \
	&& ok "hermes-web shares tailscale's network namespace" \
	|| bad "hermes-web is not sharing the tailscale network namespace"
contains hermes-tailscale.container 'Network=hermes-stack.network' \
	&& ok "tailscale joins the stack network" \
	|| bad "tailscale is not on the stack network"
grep -qx 'NetworkName=hermes-stack' "$units/hermes-stack.network" \
	&& ok "network name is hermes-stack" \
	|| warn "hermes-stack.network does not set NetworkName=hermes-stack"

# Notify=healthy is what makes the dependency ordering gate on readiness.
for f in hermes-tailscale.container hermes-web.container; do
	contains "$f" 'Notify=healthy' \
		&& ok "$f gates startup on health" \
		|| warn "$f does not set Notify=healthy; After= will not wait for healthy"
done

# Secrets stay out of the units.
if grep -qE '^(Environment=)?(TAILSCALE_AUTHKEY|OPENROUTER_API_KEY|DASHBOARD_PASSWORD)=' "$units"/*.container; then
	bad "a secret is set directly in a unit file; use deploy/podman/env/*.env"
else
	ok "no secrets in unit files"
fi

# --- Removed capabilities must stay removed ------------------------------
if [ -e compose.yaml ] || [ -e compose.podman.yaml ]; then
	bad "a compose file is back; the stack is Quadlet-only"
else
	ok "no compose files"
fi

if grep -rqiE '(docker|podman) compose|compose (up|down|ps|logs|pull|config)|compose\.ya?ml' --exclude=check.sh README.md docs/ scripts/ deploy/ 2>/dev/null; then
	bad "a compose command or file reference remains under README.md, docs/, scripts/ or deploy/"
else
	ok "no compose commands or file references in docs, scripts or units"
fi

if [ -e runtime/models ] || [ -e "$units/hermes-inference.container" ]; then
	bad "local inference artifacts are back (runtime/models or hermes-inference.container)"
else
	ok "no local inference artifacts"
fi

if grep -qiE 'llama|/dev/dri|models\.ini|server-vulkan' --exclude=check.sh README.md docs/*.md scripts/*.sh deploy/quadlet/* env.example 2>/dev/null; then
	bad "a local-inference reference remains (llama, /dev/dri, models.ini, server-vulkan)"
else
	ok "no local-inference references in docs, scripts, units or env.example"
fi

# --- Model provider ------------------------------------------------------
default_model=$(section model | sed -n 's/^[[:space:]]*default:[[:space:]]*//p' | head -n 1 | tr -d '"')
provider=$(section model | sed -n 's/^[[:space:]]*provider:[[:space:]]*//p' | head -n 1 | tr -d '"')
if [ "$provider" = "openrouter" ]; then
	ok "model.provider is openrouter"
else
	bad "model.provider is '${provider:-unset}'; the stack runs on OpenRouter only"
fi

case "$default_model" in
	*/*) ok "model.default ${default_model} is an OpenRouter slug" ;;
	*) bad "model.default '${default_model}' is not a provider/model slug" ;;
esac

# Routing is keyed by the exact slug, so a mismatch silently disables it.
if grep -qx "    ${default_model}:" "$config"; then
	ok "provider_routing.models has an entry for ${default_model}"
else
	warn "provider_routing.models has no entry for ${default_model}"
fi

if grep -qE '^(providers:|[[:space:]]+llama-cpp:|[[:space:]]+base_url:)' "$config"; then
	bad "config.yaml still defines a local/self-hosted provider"
else
	ok "config.yaml defines no local provider"
fi

# --- Keys and env --------------------------------------------------------
missing=0
while IFS= read -r key; do
	[ -n "$key" ] || continue
	grep -q "^${key}=" env.example || { bad "key_env ${key} missing from env.example"; missing=1; }
done < <(sed -n 's/^[[:space:]]*key_env:[[:space:]]*//p' "$config" | tr -d '"' | sort -u)
[ "$missing" = 0 ] && ok "provider key_env values are documented in env.example"

grep -q '^OPENROUTER_API_KEY=' env.example \
	&& ok "env.example documents OPENROUTER_API_KEY" \
	|| bad "env.example does not document OPENROUTER_API_KEY"
grep -q 'OPENROUTER_API_KEY' scripts/render-quadlet-env.sh \
	&& ok "env renderer passes OPENROUTER_API_KEY to hermes-web" \
	|| bad "env renderer never writes OPENROUTER_API_KEY"

# --- Docs and scripts ----------------------------------------------------
missing=0
while IFS= read -r path; do
	[ -n "$path" ] || continue
	[ -f "$path" ] || { bad "docs reference missing ${path}"; missing=1; }
done < <(grep -ho 'scripts/[A-Za-z0-9_.-]*\.sh' README.md docs/*.md | sort -u)
[ "$missing" = 0 ] && ok "every script referenced by README/docs exists"

# Bind-mount sources must exist before the units start.
for src in runtime/hermes-home runtime/tailscale-state runtime/hermes-home/home/.ssh; do
	[ -e "$src" ] || warn "bind source ${src} missing — run: bash scripts/install-quadlet.sh"
done

# Env files are generated and git-ignored; absence is not a failure on a clean
# checkout, but a present .env means they should be rendered.
if [ -f .env ]; then
	for envf in deploy/podman/env/tailscale.env deploy/podman/env/hermes-web.env; do
		[ -f "$envf" ] && ok "$envf rendered" || warn "$envf missing — run: bash scripts/render-quadlet-env.sh"
	done
	[ -f deploy/podman/env/inference.env ] && bad "deploy/podman/env/inference.env still exists"
	[ -f deploy/podman/env/hermes-web.env ] && {
		grep -q '^HERMES_UID=' deploy/podman/env/hermes-web.env \
			&& ok "hermes-web.env records HERMES_UID" \
			|| bad "hermes-web.env lacks HERMES_UID"
		grep -q '^OPENROUTER_API_KEY=' deploy/podman/env/hermes-web.env \
			&& ok "hermes-web.env carries OPENROUTER_API_KEY" \
			|| bad "hermes-web.env lacks OPENROUTER_API_KEY"
	}
else
	skip "no .env — env files not checked (copy env.example first)"
fi

# --- Generator validation (optional) -------------------------------------
generator=""
for candidate in \
	"$(command -v podman-system-generator 2>/dev/null || true)" \
	/usr/lib/systemd/system-generators/podman-system-generator \
	/usr/libexec/systemd/system-generators/podman-system-generator; do
	[ -n "$candidate" ] && [ -x "$candidate" ] && { generator=$candidate; break; }
done

if [ -n "$generator" ]; then
	stage=$(mktemp -d "${TMPDIR:-/tmp}/hermes-quadlet-check.XXXXXX")
	trap 'rm -rf "$stage"' EXIT
	repo=$PWD
	for src in "$units"/*; do
		[ -f "$src" ] && sed "s|@REPO@|$repo|g" "$src" >"$stage/$(basename "$src")"
	done
	if QUADLET_UNIT_DIRS="$stage" "$generator" --user --dryrun >"$stage/out" 2>"$stage/err"; then
		ok "generator accepted the units"
		grep -qE -- '--userns(=| )keep-id' "$stage/out" \
			&& ok "generated command has keep-id userns" \
			|| bad "generated command lacks a keep-id userns"
		grep -qE -- '--user(=| )0' "$stage/out" \
			&& ok "generated command has --user 0" \
			|| bad "generated command lacks --user 0"
	else
		bad "generator rejected the units"
		sed -n '1,10p' "$stage/err"
	fi
else
	skip "podman-system-generator unavailable — units not generated"
fi

exit "$fail"

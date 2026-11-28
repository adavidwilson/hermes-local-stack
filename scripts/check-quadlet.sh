#!/usr/bin/env bash
# Static checks for the Quadlet units. Complements scripts/check.sh (which
# validates the compose path) without requiring a running Podman.
#
# Usage: bash scripts/check-quadlet.sh [--verbose]
set -uo pipefail

cd "$(dirname "$0")/.."

fail=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }
warn() { printf '  warn  %s\n' "$1"; }
skip() { printf '  skip  %s\n' "$1"; }

units=deploy/quadlet
need() { [ -f "$units/$1" ] || { bad "missing $units/$1"; return 1; }; }
contains() { grep -qxF -- "$2" "$units/$1" 2>/dev/null; }

for f in hermes-stack.network hermes-tailscale.container hermes-inference.container hermes-web.container; do
	need "$f" && ok "$f present"
done

# Every Quadlet reference must resolve to a unit file; the generator aborts
# with "unable to translate dependency" otherwise (e.g. inference.container
# vs hermes-inference.container).
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

# The rootless hermes-web fix is a pair: keep-id alone starts the container as
# the host UID and trips the image's s6 bootstrap guard.
contains hermes-web.container 'UserNS=keep-id' \
	&& ok "hermes-web uses UserNS=keep-id" \
	|| bad "hermes-web does not set UserNS=keep-id"
contains hermes-web.container 'User=0' \
	&& ok "hermes-web pins User=0 (init as root for s6)" \
	|| bad "hermes-web sets UserNS=keep-id without User=0 — the image's --user guard will reject startup"

# Network-mode translation from compose.
contains hermes-web.container 'Network=hermes-tailscale.container' \
	&& ok "hermes-web shares tailscale's network namespace" \
	|| bad "hermes-web is not sharing the tailscale network namespace"
contains hermes-tailscale.container 'Network=hermes-stack.network' \
	&& ok "tailscale joins the stack network" \
	|| bad "tailscale is not on the stack network"
grep -qx 'NetworkName=hermes-stack' "$units/hermes-stack.network" \
	&& ok "network name preserved as hermes-stack" \
	|| warn "hermes-stack.network does not set NetworkName=hermes-stack"

# GPU access under rootless Podman.
contains hermes-inference.container 'AddDevice=/dev/dri' \
	&& ok "inference passes /dev/dri" \
	|| bad "inference does not pass /dev/dri"
contains hermes-inference.container 'GroupAdd=keep-groups' \
	&& ok "inference keeps host supplementary groups" \
	|| warn "inference lacks GroupAdd=keep-groups; /dev/dri/renderD* may be EACCES"

# Readiness ordering: Notify=healthy must exist for the dependency to be gated.
for f in hermes-tailscale.container hermes-inference.container hermes-web.container; do
	contains "$f" 'Notify=healthy' \
		&& ok "$f gates startup on health" \
		|| warn "$f does not set Notify=healthy; After= will not wait for healthy"
done

# Secrets stay out of the units.
if grep -qE '^(Environment=)?(TAILSCALE_AUTHKEY|LLAMA_API_KEY|DASHBOARD_PASSWORD)=' "$units"/*.container; then
	bad "a secret is set directly in a unit file; use deploy/podman/env/*.env"
else
	ok "no secrets in unit files"
fi

# Env files are generated and git-ignored; absence is not a failure on a clean
# checkout, but the compose .env being present means they should be rendered.
if [ -f .env ]; then
	for envf in deploy/podman/env/tailscale.env deploy/podman/env/inference.env deploy/podman/env/hermes-web.env; do
		[ -f "$envf" ] && ok "$envf rendered" || bad "$envf missing — run: bash scripts/render-quadlet-env.sh"
	done
	[ -f deploy/podman/env/hermes-web.env ] && {
		grep -q '^HERMES_UID=' deploy/podman/env/hermes-web.env \
			&& ok "hermes-web.env records HERMES_UID" \
			|| bad "hermes-web.env lacks HERMES_UID"
	}
else
	skip "no .env — env files not checked (copy env.example first)"
fi

# Generator validation when the host has podman's generator.
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

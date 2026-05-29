#!/usr/bin/env bash
# Devices key — verify that:
#   1. validate_device accepts real specs (CDI names, host /dev paths) and
#      rejects flag-injection (leading '-') and newlines.
#   2. Both the plain-service and pod-member arg builders wire `.devices[]?`
#      through to `--device`.
# Fast, no podman/daemon needed (sources the script and inspects helpers/source).

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

LAB_PODMAN_SRC="${TEST_DIR}/../lab-podman.sh"

# ── 1. validate_device behavior (source the script; the sourcing guard means
#       main does not run on source) ──────────────────────────────────────────
# shellcheck disable=SC1090
source "$LAB_PODMAN_SRC"

[[ "$(type -t validate_device)" == "function" ]] \
    || fail "validate_device not defined (sourcing guard missing?)"

# Accepts: CDI device name + host device path (+ host:container:perms form).
for ok in "nvidia.com/gpu=all" "/dev/dri/renderD128" "/dev/kvm:/dev/kvm:rwm" "amd.com/gpu=0"; do
    ( validate_device "$ok" ) >/dev/null 2>&1 \
        || fail "validate_device wrongly rejected a valid spec: $ok"
done
note "valid device specs accepted (CDI + host paths)"

# Rejects: leading dash (flag injection) and an embedded newline.
( validate_device "-rf" ) >/dev/null 2>&1 \
    && fail "validate_device accepted a leading-dash spec (-rf)" \
    || note "leading-dash spec rejected"
( validate_device $'nvidia.com/gpu=all\n--privileged' ) >/dev/null 2>&1 \
    && fail "validate_device accepted a newline-injected spec" \
    || note "newline-injected spec rejected"

# ── 2. Both arg builders wire .devices[] → --device ──────────────────────────
plain_fn="$(sed -n '/^start_service_plain()/,/^}/p' "$LAB_PODMAN_SRC")"
pod_fn="$(sed -n '/^start_services_in_pod()/,/^}/p' "$LAB_PODMAN_SRC")"

for blk_name in plain pod; do
    case "$blk_name" in
        plain) blk="$plain_fn" ;;
        pod)   blk="$pod_fn"   ;;
    esac
    grep -q 'jq -r .\.devices\[\]?.' <<<"$blk" \
        || fail "${blk_name} path does not read .devices[] from the service spec"
    grep -q 'args+=(--device' <<<"$blk" \
        || fail "${blk_name} path does not emit --device"
    grep -q 'validate_device' <<<"$blk" \
        || fail "${blk_name} path does not validate device specs"
done
note "plain + pod paths both wire .devices[] → validate_device → --device"

pass "devices key wired and validated"

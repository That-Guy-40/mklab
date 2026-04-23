#!/usr/bin/env bash
# Verify the engine-dispatch preference (incus > lxc) and that both names
# pass the engine filter.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

note "probe result"
# Reachability-aware: the script picks the binary whose daemon answers.
# Binary presence alone isn't the right predicate — incus is often
# packaged without its daemon running on hosts where snap-based lxd is
# the live engine.
incus_ok=0; lxc_ok=0
command -v incus >/dev/null 2>&1 && incus info >/dev/null 2>&1 && incus_ok=1
command -v lxc   >/dev/null 2>&1 && lxc   info >/dev/null 2>&1 && lxc_ok=1

if (( incus_ok && lxc_ok )); then
    # Both reachable — script must pick incus.
    out="$(LAB_LOG_LEVEL=debug "$LAB_LXD" list 2>&1 || true)"
    grep -q 'engine: incus' <<<"$out" \
        || fail "with both incus+lxc reachable, engine should be incus; got: $out"
    note "both reachable → incus picked OK"
elif (( incus_ok )); then
    out="$(LAB_LOG_LEVEL=debug "$LAB_LXD" list 2>&1 || true)"
    grep -q 'engine: incus' <<<"$out" || fail "incus reachable but not picked; got: $out"
    note "only incus reachable — picked OK"
elif (( lxc_ok )); then
    out="$(LAB_LOG_LEVEL=debug "$LAB_LXD" list 2>&1 || true)"
    grep -q 'engine: lxd' <<<"$out" || fail "lxc reachable but not picked; got: $out"
    note "only lxc reachable — picked OK"
else
    skip "no reachable engine"
fi

# Engine filter: a service with engine = "docker" or "podman" must be
# skipped; engine unset / "lxd" / "incus" must be claimed.  Easiest way to
# observe: up with a mixed TOML, but that requires a live daemon.  If we
# have one, exercise it.
if command -v incus >/dev/null 2>&1 || command -v lxc >/dev/null 2>&1; then
    detect_lxd_engine
    if "$LXC_CMD" info >/dev/null 2>&1; then
        cfg="$(mktemp --suffix=.toml)"
        lab="efd$$"
        trap 'rm -f "$cfg"; cleanup_lab "$lab"' EXIT
        cat > "$cfg" <<EOF
[lab]
name = "${lab}"
[[instance]]
name = "mine"
image = "images:alpine/3.21"
engine = "lxd"
[[instance]]
name = "notmine"
image = "nginx:alpine"
engine = "docker"
EOF
        out="$(LAB_LOG_LEVEL=debug "$LAB_LXD" up --config "$cfg" 2>&1)"
        grep -q "skipping instance 'notmine'" <<<"$out" \
            || fail "engine filter did not skip docker-engine service; got: $out"
        note "engine filter skipped docker row OK"
        cleanup_lab "$lab"
    else
        note "daemon not reachable — skipping filter roundtrip"
    fi
fi

pass "engine dispatch OK"

#!/usr/bin/env bash
# Verify the engine-dispatch preference (incus > lxc) and that both names
# pass the engine filter.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

note "probe result"
if command -v incus >/dev/null 2>&1 && command -v lxc >/dev/null 2>&1; then
    # Both installed — script must pick incus.  We can only observe this
    # indirectly by running a subcommand that logs the engine name at
    # debug level.
    if ! LAB_LOG_LEVEL=debug "$LAB_LXD" help 2>&1 >/dev/null | grep -q 'engine: incus'; then
        # help doesn't call probe_engine (fast path); try list instead.
        # list will also emit debug after probe_engine, without needing a
        # reachable daemon.  If list fails because daemon down, we still
        # got the [debug] line.
        out="$(LAB_LOG_LEVEL=debug "$LAB_LXD" list 2>&1 || true)"
        grep -q 'engine: incus' <<<"$out" \
            || fail "with both incus+lxc installed, engine should be incus; got: $out"
    fi
    note "both installed → incus picked OK"
elif command -v incus >/dev/null 2>&1; then
    note "only incus installed — dispatch trivially correct"
elif command -v lxc >/dev/null 2>&1; then
    note "only lxc installed — dispatch trivially correct"
else
    skip "no engine installed"
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
image = "images:alpine/3.19"
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

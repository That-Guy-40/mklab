#!/usr/bin/env bash
# Closes the last of REVIEW-phase4.md §3b: the `[[ $EUID -eq 0 ]]` EARLY-RETURNS inside
# the four rootless preflights, which are reachable only by a ROOTFUL `up` — something no
# test performed.
#
# `test-allow-root.sh` covers the GATE (`refusing to run as root`, and `--allow-root`
# bypassing it) by running `list` and `help`. It never brings a lab up, so these four
# never executed on their root path:
#
#   check_subuid_subgid              → returns 0 before looking at /etc/subuid
#   check_linger_if_quadlet          → returns 0 before warning about loginctl linger
#   check_ip_unprivileged_port_start → returns 0 before warning about a low host port
#   detect_rootless_network          → prints 'rootful' instead of probing podman
#
# Two of those are OBSERVABLE, which is what makes this a measurement and not a smoke
# test:
#
#   * `up` logs `rootless network backend: <x>`, so the fourth prints its answer.
#   * the third warns when a published host port is below
#     net.ipv4.ip_unprivileged_port_start (1024 here). Non-root MUST warn; root MUST NOT
#     — and this test asks BOTH, so the absence as root is a comparison rather than a
#     check that could never fire. It also asks about a port ABOVE the threshold, so the
#     warning is not merely unconditional.
#
# ── HOW TO RUN IT ─────────────────────────────────────────────────────────────────────
#     sudo phase4-podman/tests/test-rootful-up.sh
# It self-skips when it cannot become root, so `run-all.sh` and CI stay green either way.
#
# ── WHAT IT TOUCHES ───────────────────────────────────────────────────────────────────
# Root podman keeps its own storage (/var/lib/containers), so this pulls alpine there —
# a few MB that persist. Everything else is scoped: the state dir is a temp dir, the
# published port is checked free first, and the lab is torn down at exit.
#
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq podman
if ! command -v tomlq >/dev/null 2>&1 && ! command -v dasel >/dev/null 2>&1 \
   && ! { command -v yq >/dev/null 2>&1 && printf 'a = 1\n' | yq -p toml -o json - >/dev/null 2>&1; }; then
    skip "no TOML parser (need tomlq, dasel, or a yq supporting -p toml)"
fi

# Become root, or say exactly how to.
if [[ $EUID -eq 0 ]]; then
    SUDO=()
else
    sudo -n true 2>/dev/null \
        || skip "not root and no passwordless sudo — run it directly:  sudo $0"
    SUDO=(sudo -n)
fi

# A host port below ip_unprivileged_port_start, so the rootless warning has something to
# fire about — and free, so the rootful bind actually succeeds.
threshold=1024
[[ -r /proc/sys/net/ipv4/ip_unprivileged_port_start ]] \
    && threshold="$(</proc/sys/net/ipv4/ip_unprivileged_port_start)"
(( threshold > 1 )) || skip "net.ipv4.ip_unprivileged_port_start=$threshold — no port is 'privileged' here, so the warning under test can never fire"

lowport=""
for p in 1013 1017 1019 1021 1023 1011 1009; do
    (( p < threshold )) || continue
    if ! ss -ltn 2>/dev/null | awk '{split($4,a,":"); print a[length(a)]}' | grep -qx "$p"; then
        lowport="$p"; break
    fi
done
[[ -n "$lowport" ]] || skip "no free host port below $threshold to exercise the port preflight"

tmp="$(mktemp -d)"
lab="p4root$$"
state="$tmp/state"
on_exit '"${SUDO[@]}" env LAB_STATE_DIR="$state" PATH="$PATH" "$LAB_PODMAN" down --lab "$lab" --allow-root >/dev/null 2>&1 || true
         "${SUDO[@]}" rm -rf -- "$state" 2>/dev/null || true
         rm -rf -- "$tmp" 2>/dev/null || true'

cat > "$tmp/lab.toml" <<EOF
[lab]
name = "${lab}"

[[service]]
name    = "web"
image   = "alpine:latest"
command = "sleep 300"
ports   = ["${lowport}:80"]
EOF

run_root() { "${SUDO[@]}" env LAB_STATE_DIR="$state" PATH="$PATH" "$LAB_PODMAN" "$@" 2>&1; }

# ── 1. the gate still refuses without --allow-root, on the `up` path ───────────────
out="$(run_root up --config "$tmp/lab.toml")" && rc=0 || rc=$?
(( rc != 0 )) || fail "a rootful 'up' without --allow-root must be refused; it exited 0"
grep -qi 'refusing to run as root' <<<"$out" \
    || fail "rootful 'up' failed but not with the rootless-first refusal; got: $out"
note "the rootless-first gate refuses a rootful 'up' without --allow-root"

# ── 2. the rootless control: the low-port warning MUST fire as a normal user ───────
# Without this, the assertion below ("no warning as root") could be true of a warning
# that never fires at all.
#
# The first version of this ran a whole rootless `up`, which meant it was SKIPPED in the
# documented invocation (`sudo <this script>`) — the run is root from PID 1 of the test
# onward, so the control silently did not happen in the case that actually occurs. The
# preflight only reads /proc, needs no podman and no XDG_RUNTIME_DIR, so it can be driven
# directly as the invoking user via SUDO_USER. Same question, and it now gets asked in
# both invocation modes.
_preflight_as_user() {   # _preflight_as_user PORT → the warning text a non-root proc gets
    local port="$1"
    local snippet='. "$1" 2>/dev/null || true; check_ip_unprivileged_port_start "$2"'
    if [[ $EUID -ne 0 ]]; then
        LAB_LOG_LEVEL=warn bash -c "$snippet" _ "$LAB_PODMAN" "$port" 2>&1
    elif [[ -n "${SUDO_USER:-}" ]] && command -v runuser >/dev/null 2>&1; then
        runuser -u "$SUDO_USER" -- env LAB_LOG_LEVEL=warn \
            bash -c "$snippet" _ "$LAB_PODMAN" "$port" 2>&1
    else
        return 1
    fi
}

CONTROL_RAN=0
if ctl="$(_preflight_as_user "$lowport")"; then
    grep -q 'ip_unprivileged_port_start' <<<"$ctl" \
        || fail "control: as a NON-ROOT user, host port $lowport (< $threshold) did NOT warn — so 'no warning as root' below would prove nothing. Got: ${ctl//$'\n'/ }"
    # ...and it must not warn for a port ABOVE the threshold, or the warning is
    # unconditional and its absence as root would again mean nothing.
    hi="$(_preflight_as_user 8080 || true)"
    [[ -z "${hi//[[:space:]]/}" ]] \
        || fail "control: the non-root preflight warned about port 8080, which is above $threshold — the warning is unconditional, so this comparison cannot distinguish root from rootless. Got: ${hi//$'\n'/ }"
    CONTROL_RAN=1
    note "control: as a non-root user, port $lowport warns and port 8080 does not"
else
    note "UNKNOWN: running as root with no SUDO_USER, so the non-root comparison could not be made in this pass"
fi

# ── 3. the rootful up itself ──────────────────────────────────────────────────────
out="$(run_root up --config "$tmp/lab.toml" --allow-root)" && rc=0 || rc=$?
(( rc == 0 )) || fail "rootful 'up --allow-root' failed (rc=$rc): $out"

grep -qi 'running rootful' <<<"$out" \
    || fail "a rootful run must announce itself; got: $out"
note "rootful 'up --allow-root' succeeds and says it is rootful"

# detect_rootless_network's early return, printed
grep -q 'rootless network backend: rootful' <<<"$out" \
    || fail "REGRESSION: detect_rootless_network did not take its \$EUID-eq-0 early return — expected 'rootless network backend: rootful', got: $(grep -i 'network backend' <<<"$out")"
note "detect_rootless_network returns 'rootful' (its root early-return executed)"

# check_ip_unprivileged_port_start's early return — the observable one
grep -q 'ip_unprivileged_port_start' <<<"$out" \
    && fail "REGRESSION: the unprivileged-port warning fired as ROOT for host port $lowport; check_ip_unprivileged_port_start did not take its \$EUID-eq-0 early return"
# The note must not claim a comparison that did not happen.
if (( CONTROL_RAN )); then
    note "no unprivileged-port warning as root — and a non-root user DID warn for the same port"
else
    note "no unprivileged-port warning as root (the non-root comparison did not run in this pass)"
fi

# check_subuid_subgid's early return: root has no /etc/subuid entry, so if the guard ran
# it would have died. Reaching this line at all is the proof; assert the message's absence
# so a future change that starts dying here is caught by name.
grep -qi 'subuid/subgid entries' <<<"$out" \
    && fail "REGRESSION: check_subuid_subgid ran its rootless body as root (root has no /etc/subuid entry, so it would die)"
note "check_subuid_subgid took its root early-return (no subuid demand)"

grep -qi 'loginctl linger' <<<"$out" \
    && fail "REGRESSION: check_linger_if_quadlet warned about linger as root"
note "check_linger_if_quadlet took its root early-return"

# ── 4. it really is rootful, not a rootless container wearing the name ─────────────
cname="lab-${lab}-web"
[[ -n "$("${SUDO[@]}" podman ps --filter "name=^${cname}$" --format '{{.Names}}' 2>/dev/null)" ]] \
    || fail "the container is not visible to ROOT podman — the lab was not created rootfully"
if [[ $EUID -ne 0 ]]; then
    [[ -z "$(podman ps -a --filter "name=^${cname}$" --format '{{.Names}}' 2>/dev/null)" ]] \
        || fail "the container is visible to ROOTLESS podman too — the two storages should be separate, so this is not the rootful container"
    note "the container exists in root podman's storage and not in the user's"
else
    note "the container exists in root podman's storage"
fi

# The low port really was bound — the thing rootless could not have done.
ss -ltn 2>/dev/null | awk '{split($4,a,":"); print a[length(a)]}' | grep -qx "$lowport" \
    || fail "host port $lowport is not listening; the rootful publish did not take effect"
note "host port $lowport (privileged) is bound — something rootless podman could not do"

# ── 5. P4-1's guard holds on the path where the mitigation used to matter ──────────
# The review's reasoning was that rootless bounds a '--privileged' escalation. Rootful
# removes that bound entirely, so the guard has to hold here above all.
cat > "$tmp/inj.toml" <<EOF
[lab]
name = "${lab}i"

[[service]]
name    = "web"
image   = "--privileged"
command = "alpine:latest sleep 60"
EOF
out="$(run_root up --config "$tmp/inj.toml" --allow-root)" && rc=0 || rc=$?
priv="$("${SUDO[@]}" podman inspect "lab-${lab}i-web" --format '{{.HostConfig.Privileged}}' 2>/dev/null || true)"
[[ "$priv" != "true" ]] \
    || fail "REGRESSION: a '-'-leading image produced a ROOTFUL privileged container — the escalation P4-1 described, with nothing bounding it"
(( rc != 0 )) || fail "REGRESSION: rootful 'up' accepted a '-'-leading image (rc=0); output: $out"
note "P4-1's guard refuses a '-'-leading image under --allow-root too"

# ── 6. teardown works rootfully ───────────────────────────────────────────────────
out="$(run_root down --lab "$lab" --allow-root)" && rc=0 || rc=$?
(( rc == 0 )) || fail "rootful 'down --allow-root' failed (rc=$rc): $out"
grep -q 'torn down' <<<"$out" || fail "rootful down did not report a clean teardown; got: $out"
[[ -z "$("${SUDO[@]}" podman ps -a --filter "name=^${cname}$" --format '{{.Names}}' 2>/dev/null)" ]] \
    || fail "the rootful container survived 'down'"
note "rootful 'down' removes the lab and reports success"

pass "the rootful path works end-to-end and all four \$EUID-eq-0 preflight early-returns execute (§3b)"

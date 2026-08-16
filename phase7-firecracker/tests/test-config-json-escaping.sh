#!/usr/bin/env bash
# REGRESSION (REVIEW-phase7.md P7-2): `gen_config` interpolated every scalar into
# config.json raw — `"boot_args": "$args"`, `"kernel_image_path": "$kernel"` — so a value
# could close its own string and add siblings.
#
# Measured on the real driver, and the result was VALID JSON, not a syntax error:
#
#     append = quiet"}, "vsock": {"guest_cid": 3, "uds_path": "/tmp/INJECTED.sock"}, "x": {"a": "b
#
#   -> a top-level "vsock" device — a host unix socket the guest can reach — in the file
#      Firecracker is about to be handed, from a boot-argument string. And the provenance
#      table, whose whole job is to report what the tool did that you did not type, said
#      nothing: as far as it is concerned that text is just your append.
#
# Phases 3, 4 and 5 each grew this escaping in the fortnight before this review. Phase 7
# was the fourth emitter of a structured document from user scalars, and the only one still
# raw — the shape every one of these reviews keeps finding: a guard that exists in the
# codebase, absent from one of its call sites.
#
# ── WHY BYTE-IDENTICAL ROUND-TRIP AND NOT "NO INJECTION" ──────────────────────────────
# P5-2's lesson, paid for once already: an assertion that only checks "no injected key" and
# "the substrings are present" passes over an emitter that CORRUPTS the value — in YAML by
# folding a newline, here by dropping it into JSON where it is illegal. The value has to
# come back exactly as it went in, which is a different and stricter question.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")   # NOT a second EXIT trap — see lib.sh
fc_fixtures
export LAB_STATE_DIR="$tmp/state"

# `create --dry-run` prints the config between a bare `{` and a bare `}`.
gen() {  # gen <outfile> <spec flags...>
    run_fc "$tmp/raw" create --dry-run --name t1 --kernel "$FC_K" --rootfs "$FC_R" "$@" \
        || { cat "$tmp/raw" >&2; return 1; }
    sed -n '/^{/,/^}/p' "$tmp/raw" > "$1"
}

readq() {  # readq <file> <python-expression-over-c>
    python3 -c 'import json,sys
c=json.load(open(sys.argv[1]))
sys.stdout.write(str(eval(sys.argv[2])))' "$1" "$2"
}

# ── 1. the injection that was measured, verbatim ──────────────────────────────────────
INJ='quiet"}, "vsock": {"guest_cid": 3, "uds_path": "/tmp/INJECTED.sock"}, "x": {"a": "b'
gen "$tmp/inj.json" --append "$INJ" \
    || fail "create --dry-run refused a spec whose only oddity is punctuation in --append"

python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp/inj.json" \
    || { cat "$tmp/inj.json" >&2; fail "REGRESSION: the generated config.json is not valid JSON — an unescaped scalar broke the document (P7-2)"; }

extra="$(readq "$tmp/inj.json" "[k for k in c if k not in ('boot-source','drives','network-interfaces','mmds-config','machine-config')]")"
[[ "$extra" == "[]" ]] \
    || fail "REGRESSION: an --append value injected top-level Firecracker configuration: $extra — the config the VMM is handed is not the config the operator described (P7-2)"
note "the measured vsock injection produces valid JSON and injects nothing"

# ...and it must SURVIVE. Escaping that loses data is a different bug wearing the same tick.
back="$(readq "$tmp/inj.json" "c['boot-source']['boot_args']")"
[[ "$back" == *"$INJ" ]] \
    || fail "REGRESSION: the append did not round-trip byte-identically — the emitter mangled it instead of escaping it. want a value ending in [$INJ], got [$back]"
note "...and the value round-trips byte-identically (escaped, not mangled or dropped)"

# ── 2. every scalar the generator still emits, with values that break naive quoting ────
# kernel/rootfs are paths and cannot be arbitrary here (the file must exist), so they are
# covered by section 3. These are the free-form ones.
i=0
while IFS= read -r v; do
    i=$((i+1))
    gen "$tmp/s$i.json" --append "$v" || fail "create refused an append value [$v]"
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp/s$i.json" \
        || fail "REGRESSION: append value [$v] produced invalid JSON"
    got="$(readq "$tmp/s$i.json" "c['boot-source']['boot_args']")"
    [[ "$got" == *"$v" ]] \
        || fail "REGRESSION: append [$v] round-tripped as [...${got: -60}] — the raw \"%s\" form escaped nothing"
done <<'VALUES'
a "quoted" arg
trailing backslash \
back\slash "and" quote
unicode: café ✓
{"already": "json"}
pipe|bar and a #hash
VALUES
note "$i hostile-but-legal append values round-trip byte-identically"

# A CONTROL CHARACTER is the one shape that is REFUSED rather than escaped, and it has to
# be tested as a refusal — a fixture the code must reject cannot also be its happy path.
# (record_value_ok owns this: US is the provenance table's column separator and a newline
# would break the record stream, so they are refused at the entry point rather than escaped
# three layers down. json_str still escapes them, as the belt to that suspenders.)
run_fc "$tmp/ctl.out" create --dry-run --name t1 --kernel "$FC_K" --rootfs "$FC_R" \
    --append "$(printf 'tab\tseparated')" \
    && fail "REGRESSION: a control character in a value was accepted — it cannot survive the record or the provenance table"
grep -q 'control character' "$tmp/ctl.out" \
    || fail "a control character was refused but not NAMED as the reason; got: $(cat "$tmp/ctl.out")"
note "a control character is refused by name, not silently escaped away"

# ── 3. the tap and MAC are JSON too ───────────────────────────────────────────────────
# They land in the network-interfaces block, which the injection above never touched — a
# fix applied to boot_args alone passes everything above.
#
# Reaching that block means satisfying preflight's tap gates: the interface must EXIST, be
# owned by this uid, and carry no IPv4. `lab-fc.sh` never manufactures taps (the fabric owns
# them) and this test must not either, so the whole thing runs inside `unshare -rmn` — a
# private user+net namespace where an unprivileged caller is uid 0, `ip tuntap add` works,
# and a sysfs remount makes /sys/class/net/<tap>/owner readable. Nothing on the host is
# touched and the namespace evaporates with the subshell. (Ubuntu 24.04 gates unprivileged
# userns behind a sysctl; CI relaxes it for the phase-1 mount tests. If it is unavailable
# this section says so by name rather than passing quietly.)
if unshare -rmn true 2>/dev/null; then
    TAPQ='tap"weird'
    unshare -rmn bash -c '
        set -euo pipefail
        mount -t sysfs none /sys 2>/dev/null || exit 70
        ip tuntap add dev "$1" mode tap user 0 2>/dev/null || exit 71
        ip link set "$1" up 2>/dev/null || exit 72
        "$2" create --dry-run --name t1 --kernel "$3" --rootfs "$4" --tap "$1" --mac "$5"
    ' _ "$TAPQ" "$LAB_FC" "$FC_K" "$FC_R" 'aa"bb' > "$tmp/netraw" 2>&1 && nrc=0 || nrc=$?
    case "$nrc" in
        0)  sed -n '/^{/,/^}/p' "$tmp/netraw" > "$tmp/net.json"
            python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp/net.json" \
                || { cat "$tmp/net.json" >&2; fail "REGRESSION: a quote in the tap name or MAC produced invalid JSON — the network block is unescaped (P7-2)"; }
            [[ "$(readq "$tmp/net.json" "c['network-interfaces'][0]['host_dev_name']")" == "$TAPQ" ]] \
                || fail "REGRESSION: host_dev_name did not round-trip byte-identically"
            [[ "$(readq "$tmp/net.json" "c['network-interfaces'][0]['guest_mac']")" == 'aa"bb' ]] \
                || fail "REGRESSION: guest_mac did not round-trip byte-identically"
            note "tap and MAC are escaped too, not just boot_args (asserted on a real tap in a private netns)" ;;
        7[012]) note "UNKNOWN: could not stage a tap inside the namespace (rc=$nrc) — the network-interfaces block was NOT exercised" ;;
        *)  cat "$tmp/netraw" >&2
            fail "create refused a spec whose tap exists and is owned by this uid (rc=$nrc) — see above" ;;
    esac
else
    note "UNKNOWN: unprivileged user namespaces unavailable — the network-interfaces block was NOT exercised (kernel.apparmor_restrict_unprivileged_userns?)"
fi

# ── 4. CONTROL: a benign spec still says exactly what it used to ──────────────────────
# An escaper that quoted everything into oblivion, or one that emitted \" for a plain
# string, would pass every assertion above. This one asserts the ORDINARY case is unchanged.
gen "$tmp/ok.json" --memory 128M || fail "control: create refused an ordinary spec"
[[ "$(readq "$tmp/ok.json" "c['boot-source']['kernel_image_path']")" == "$FC_K" ]] \
    || fail "control: the kernel path is no longer emitted verbatim"
[[ "$(readq "$tmp/ok.json" "c['machine-config']['mem_size_mib']")" == "128" ]] \
    || fail "control: mem_size_mib is no longer a JSON NUMBER — the escaper quoted a numeric field"
[[ "$(readq "$tmp/ok.json" "c['drives'][0]['is_root_device']")" == "True" ]] \
    || fail "control: is_root_device is no longer a JSON boolean"
note "control: an ordinary spec is byte-for-byte what it always was (numbers still numbers, bools still bools)"

pass "every scalar in config.json is JSON-escaped: the measured vsock injection is inert, 6 hostile values round-trip byte-identically, and an ordinary spec is unchanged (P7-2)"

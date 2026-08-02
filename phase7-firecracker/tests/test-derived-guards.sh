#!/usr/bin/env bash
# The two schema constraints DERIVED from slices 1-2, and their negative controls.
# Both guard measured regressions, so both messages carry REGRESSION:.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")   # NOT a second EXIT trap — see lib.sh

# --- 1. `root=` in append must be REFUSED (plan E.4) -----------------------
# Firecracker appends its own root=/dev/vda and the kernel honours the LAST one, so a
# user root= is silently ignored. A knob that does nothing is worse than no knob.
mkspec "$tmp/root.toml" 'append = "root=/dev/vdb"'
run_fc "$tmp/root.out" preflight --config "$tmp/root.toml" || true
grep -q 'append contains root=' "$tmp/root.out" \
    || fail "REGRESSION: append containing root= was not refused — Firecracker would silently override it (plan E.4)"
note "root= in append refused"

# NEGATIVE CONTROL: an append WITHOUT root= must not trip that gate.
mkspec "$tmp/ok.toml" 'append = "mc_name=t1"'
run_fc "$tmp/ok.out" preflight --config "$tmp/ok.toml" || true
grep -q 'append contains root=' "$tmp/ok.out" \
    && fail "the root= gate fires on an append that has no root= — it is matching something always present"
note "negative control: a clean append does not trip it"

# --- 2. `ip=` with no NIC must be REFUSED (plan F.4) -----------------------
# Measured twice: 0.55s -> 12.84s, spent in kernel IP autoconfig waiting for a device that
# never appears, with NO IP-Config line and no error anywhere in dmesg.
mkspec "$tmp/ip.toml" 'ip = "10.71.0.11"'
run_fc "$tmp/ip.out" preflight --config "$tmp/ip.toml" || true
grep -q 'but no tap is configured' "$tmp/ip.out" \
    || fail "REGRESSION: ip= without a tap was not refused — this is a silent ~23x boot regression (plan F.4)"
note "ip= without a tap refused"

# NEGATIVE CONTROL: no ip= and no tap is a consistent, allowed combination.
mkspec "$tmp/noip.toml"
run_fc "$tmp/noip.out" preflight --config "$tmp/noip.toml" || true
grep -q 'but no tap is configured' "$tmp/noip.out" \
    && fail "the ip=/tap gate fires when neither is set — it is not testing what it claims"
note "negative control: neither ip= nor tap does not trip it"

# --- 3. an unknown schema key must be REFUSED, not ignored ----------------
mkspec "$tmp/bad.toml" 'rootdevice = "/dev/vdb"'
if run_fc "$tmp/bad.out" preflight --config "$tmp/bad.toml"; then
    fail "REGRESSION: an unknown schema key did not make the run fail — a dropped key is a field that appears to work and does nothing"
fi
grep -q 'unknown \[\[microvm\]\] key rootdevice' "$tmp/bad.out" \
    || fail "the unknown key was rejected but not NAMED — the operator cannot tell which key"
# ASSERT THE OUTCOME, NOT THE MESSAGE. The first version of this checked only that a
# refusal was PRINTED. It was: awk exited 3 inside a process substitution, the status was
# discarded, and the tool carried on running gates against a partial record. A refusal that
# refuses nothing passed a test written to catch exactly that.
grep -qE '^  (ok|FAIL|UNKNOWN) ' "$tmp/bad.out" \
    && fail "REGRESSION: gates ran AFTER the unknown-key refusal — the refusal did not stop the run"
note "unknown schema key refused by name AND the run stopped before any gate ran"

pass "derived schema guards refuse root=, orphan ip=, and unknown keys — each with a negative control"

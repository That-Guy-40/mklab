#!/usr/bin/env bash
# No micro-cloud instrument may NAME a host fact it should DERIVE.
#
# WHY THIS EXISTS. MICRO_CLOUD_LAB_PLAN.md §17.4 q6 worried that four instruments could
# "disagree about the same host". Measured 2026-08-05, the four were compared and they agree
# about /dev/kvm, about firecracker's pinned version, and about ext4 read-back. Exactly ONE
# disagreement was real, and it was not a divergent implementation — it was a **cached
# string**:
#
#   tools/micro-cloud-preflight.sh printed  "…live calico-node procs; vxlan.calico over lxdbr0"
#
# with the process count derived and the interface name a literal. It was already wrong on
# 2026-08-01 (the underlay was incusbr0 — plan D.1) and wrong again on 2026-08-04 (a reboot
# left both container-engine daemons down, so Calico re-selected the physical uplink —
# plan Appendix I). An instrument that RUNS TODAY and prints a fact from 2026-07-29 is not a
# dated record. It is a liar with a fresh timestamp, and it outranks an honest failure.
#
# So the fix for q6 is not a refactor that merges the instruments — q6 itself requires the
# dated spikes stay runnable, and merging would destroy the harness that produced
# Appendices A and B. The fix is this rule, enforced:
#
#     the appendix is the record and is immutable; the instrument is code and must be true
#     when it runs.
#
# WHAT IS BANNED. Names of THIS host's volatile interfaces and their addresses. They are
# never constants: bridges appear and vanish with a daemon, and the CNI re-selects every 60
# seconds (plan I.4). `br-mc0` and 10.71.0.0/24 are deliberately NOT here — those are ours,
# chosen by the fabric, and constant by design.
set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$TEST_DIR/../.." && pwd)"

_VERDICT=0
fail() { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
skip() { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
note() { printf '  - %s\n' "$*" >&2; }
_on_exit() {
    local rc=$?
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

# Volatile facts about this host. Add to this list, never to an allowlist of exceptions.
BANNED='lxdbr0|incusbr0|enx00051b8eb138|10\.45\.178|10\.216\.67|192\.168\.1\.106'

FILES=(
    tools/micro-cloud-preflight.sh
    tools/micro-cloud-preflight-p2.sh
    tools/micro-cloud-fabric-probe.sh
    examples/micro-cloud/fabric.sh
    phase7-firecracker/lab-fc.sh
)

# scan <file> -> prints offending "line:text" for non-comment lines only.
# Comments are exempt on purpose: a dated observation ("[2026-08-02] Calico was bound to
# incusbr0") is exactly the kind of record this repo wants kept, provided it is marked as
# dated and the CODE derives the live value.
scan() {
    local f="$1"
    [[ -r "$REPO/$f" ]] || return 0
    grep -nE "$BANNED" "$REPO/$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true
}

missing=0
for f in "${FILES[@]}"; do
    [[ -r "$REPO/$f" ]] || { note "absent, not scanned: $f"; missing=$((missing+1)); }
done
(( missing < ${#FILES[@]} )) || skip "none of the instruments are present"

# ── NEGATIVE CONTROL, run before the real scan ──────────────────────────────
# An all-clean result is indistinguishable from a detector that matches nothing. Prove the
# detector fires on the exact string that caused the incident, in a throwaway file.
probe_dir="$(mktemp -d)"
trap 'rm -rf "$probe_dir"; _on_exit' EXIT
mkdir -p "$probe_dir/tools"
cat > "$probe_dir/tools/micro-cloud-preflight.sh" <<'FIXTURE'
#!/usr/bin/env bash
# a dated comment mentioning incusbr0 must NOT trip the detector
row FAIL "§7,§13" no "forwarding path" "$calico procs; vxlan.calico over lxdbr0"
FIXTURE
if ! ( REPO="$probe_dir" scan tools/micro-cloud-preflight.sh | grep -q 'lxdbr0' ); then
    fail "the detector did not fire on the exact line from the 2026-08-05 incident — this test proves nothing"
fi
if ( REPO="$probe_dir" scan tools/micro-cloud-preflight.sh | grep -q '^2:' ); then
    : # line 2 is the comment; must NOT be reported
fi
ctl="$(REPO="$probe_dir" scan tools/micro-cloud-preflight.sh)"
[[ "$(printf '%s\n' "$ctl" | grep -c .)" == 1 ]] \
    || fail "the detector reported $(printf '%s\n' "$ctl" | grep -c .) lines on a fixture with exactly one offender — it is matching comments too"
note "negative control: detector fires on the real incident line, and exempts the dated comment"
rm -rf "$probe_dir"
trap _on_exit EXIT

# ── the real scan ───────────────────────────────────────────────────────────
found=""
for f in "${FILES[@]}"; do
    hits="$(scan "$f")"
    [[ -n "$hits" ]] && found+="$(printf '%s\n' "$hits" | sed "s|^|  $f:|")"$'\n'
done

if [[ -n "${found//[$' \t\n']/}" ]]; then
    printf '%s' "$found" >&2
    fail "an instrument NAMES a host fact it must DERIVE (above) — that string is a cache entry that will outlive its subject, exactly as 'vxlan.calico over lxdbr0' did"
fi

note "scanned ${#FILES[@]} instruments, 0 cached host facts outside comments"
pass "every micro-cloud instrument derives this host's interfaces rather than naming them"

#!/usr/bin/env bash
# bench-boot.sh refuses missing inputs by name, parses a real boot log, and — where a
# hypervisor exists — actually boots and produces a number.
#
# WHY THE PARSER IS TESTED AT ALL. The first version of this harness extracted the kernel
# timestamp with `sed "s/…$MARKER…/\1/p"`, and the marker is `Run /sbin/init as init
# process`. Those slashes terminate the substitution: every one of 20 boots failed to parse,
# and every one was reported as **"never reached userspace within 20s"** — which was false.
# The guests had all booted and printed the line. That is a parse failure wearing a boot
# failure's error message, and it is the exact class this repo fixes first, so it gets a
# regression guard rather than a comment.
#
# The parser is reachable headlessly through `--parse-log`, which is the SAME function the
# runs use, not a copy of it. A test against a re-implementation would prove nothing about
# the code that ships.
#
# THE BOOT HALF IS CONDITIONAL AND SAYS SO. It needs /dev/kvm, a firecracker binary, a QEMU
# with `microvm`, and slice 3's kernel + rootfs. CI has none of those, so it SKIPs — and an
# all-SKIP run of this file proves only that the refusals work.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

BENCH="$(dirname -- "${BASH_SOURCE[0]}")/../bench-boot.sh"
[[ -x "$BENCH" ]] || skip "bench-boot.sh not executable at $BENCH"

WORK="$(mktemp -d)" || fail "could not create a temp dir"
_on_exit() {
    local rc=$?
    [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf -- "$WORK"
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

# ── 1. the parser, positive: a real boot log line, slashes and all ──────────
cat > "$WORK/good.log" <<'LOG'
[    0.051399] clk: Disabling unused clocks
[    0.067320] EXT4-fs (vda): mounted filesystem with ordered data mode. Quota mode: none.
[    0.069558] Run /sbin/init as init process
SLICE3-BEGIN name=api1 peer=api2 uptime=0.05s
LOG
got="$(bash "$BENCH" --parse-log "$WORK/good.log")" || fail "REGRESSION: --parse-log failed on a log that contains the marker — this is the sed-delimiter bug returning ('/sbin/init' ends an unescaped s/// expression)"
[[ "$got" == "0.069558" ]] \
    || fail "REGRESSION: the userspace timestamp parsed as '$got', expected '0.069558' — every number this harness reports comes from here"
note "parser: '[    0.069558] Run /sbin/init as init process' → $got"

# ── 2. the parser, negative control: no marker must be an ERROR, not 0 ──────
# "I could not find it" rendered as a number would put a fabricated sample into the mean.
cat > "$WORK/bad.log" <<'LOG'
[    0.051399] clk: Disabling unused clocks
[    0.563440] input: AT Raw Set 2 keyboard as /devices/platform/i8042/serio0/input/input0
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
LOG
if out="$(bash "$BENCH" --parse-log "$WORK/bad.log" 2>&1)"; then
    fail "REGRESSION: --parse-log succeeded on a log with no userspace marker (printed '$out') — a boot that never reached userspace must not yield a timing sample"
fi
[[ "$out" == *"$(basename "$WORK/bad.log")"* || "$out" == *"Run /sbin/init"* ]] \
    || fail "the no-marker refusal did not name what it was looking for or where: '$out'"
note "parser: a panicked boot log is refused, not scored"

# ── 3. inputs are refused BEFORE anything is measured, and by name ──────────
if out="$(bash "$BENCH" --kernel "$WORK/nope-vmlinux" --runs 1 2>&1)"; then
    fail "REGRESSION: bench-boot exited 0 with a nonexistent kernel — a benchmark that silently drops an arm reports a comparison it did not make"
fi
[[ "$out" == *"nope-vmlinux"* ]] \
    || fail "the missing-kernel refusal did not name the file it could not read: '$out'"
if out="$(bash "$BENCH" --runs 0 2>&1)"; then
    fail "--runs 0 was accepted; it can only produce an empty comparison"
fi
if out="$(bash "$BENCH" --engine potato 2>&1)"; then
    fail "--engine potato was accepted"
fi
note "refusals: missing kernel, --runs 0 and an unknown engine each exit non-zero, naming the input"

# ── 4. the boot half — real numbers, or an honest skip ──────────────────────
WORKDIR="${MC_WORKDIR:-$HOME/.local/state/lab-create/micro-cloud-s3}"
[[ -r /dev/kvm && -w /dev/kvm ]] || skip "no read-write /dev/kvm: the refusals above passed, but nothing was booted"
[[ -r "$WORKDIR/vmlinux" && -r "$WORKDIR/api1.ext4" ]] \
    || skip "slice 3's kernel/rootfs are not in $WORKDIR: the refusals above passed, but nothing was booted"
[[ -x "${MC_FIRECRACKER:-$WORKDIR/firecracker}" ]] || skip "no firecracker binary: nothing was booted"
command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "no qemu-system-x86_64: nothing was booted"
qemu-system-x86_64 -machine help 2>/dev/null | grep -q '^microvm ' || skip "this QEMU has no microvm machine: nothing was booted"

JSON="$WORK/out.json"
bash "$BENCH" --runs 2 --json >"$JSON" 2>"$WORK/run.err" || {
    cat "$WORK/run.err" >&2; fail "a full four-arm run failed — see the output above"
}

read -r n_samples n_arms fc_ok qd qn <<<"$(python3 - "$JSON" <<'PY'
import json, sys, statistics
d = json.load(open(sys.argv[1]))
s = d["samples"]
by = {}
for r in s:
    by.setdefault(r["arm"], []).append(r["kernel_s"])
med = {k: statistics.median(v) for k, v in by.items()}
# fc-default must be SLOWER than fc-noi8042 by a wide margin: that gap is the i8042 finding.
fc_ok = int(med.get("fc-default", 0) > med.get("fc-noi8042", 1) * 3)
print(len(s), len(by), fc_ok, med.get("qemu-default", 0), med.get("qemu-noi8042", 0))
PY
)" || fail "could not parse --json output"

(( n_arms == 4 )) || fail "expected 4 arms in --json, got $n_arms — an arm that silently vanished is a comparison that was never made"
(( n_samples == 8 )) || fail "expected 8 samples (4 arms x 2 runs), got $n_samples"
(( fc_ok == 1 )) || fail "REGRESSION: fc-default is no longer far slower than fc-noi8042 — either the i8042 stall is gone on this kernel (re-derive Appendix J) or the arms stopped differing"

# THE CONTROL. microvm emulates no i8042, so the flags must change nothing there. If this
# ever fails, the flags are doing something else and the fc-default/fc-noi8042 gap cannot be
# attributed to the PS/2 probe.
gap="$(python3 -c 'import sys; a,b=float(sys.argv[1]),float(sys.argv[2]); print("%.4f"%abs(a-b))' "$qd" "$qn")"
ok="$(python3 -c 'import sys; print(int(abs(float(sys.argv[1])-float(sys.argv[2])) < 0.02))' "$qd" "$qn")"
(( ok == 1 )) \
    || fail "REGRESSION: the control broke — qemu-default ($qd) and qemu-noi8042 ($qn) differ by ${gap}s. microvm has no i8042, so those flags must be inert there; a gap means Appendix J's attribution of the Firecracker delta to the PS/2 probe is unsupported"
note "boot: 4 arms x 2 runs; fc-default >> fc-noi8042; control holds (qemu arms differ by ${gap}s)"

pass "bench-boot refuses bad inputs by name, parses the marker line correctly, and its four arms reproduce the i8042 finding with the control intact"

#!/usr/bin/env bash
# `inspect` must survive a disk it cannot open — which is the NORMAL state of a running VM.
#
# THE DEFECT THIS GUARDS. A running QEMU holds a write lock on its own disk, so
# `qemu-img info` on it exits 1 with `Failed to get shared "write" lock`. `cmd_inspect`
# read the virtual size like this:
#
#     vsz="$(qemu-img info --output=json "$f_disk_path" 2>/dev/null \
#          | jq -r '."virtual-size" // empty' 2>/dev/null)"
#
# and under `set -euo pipefail` that bare assignment inherits the pipeline's non-zero status
# and kills the script SILENTLY — mid-function, before a single byte reaches stdout or
# stderr. So `lab-vm.sh inspect <name>` exited 1 with NO OUTPUT AT ALL for every running VM
# with a qcow2 disk, in BOTH the human and the --json form. The code even intended the right
# thing ("report null otherwise"); it guarded `have qemu-img` — qemu-img being ABSENT — and
# not qemu-img FAILING.
#
# WHY THE EXISTING TEST NEVER SAW IT, which is the more useful half. test-inspect-json.sh
# does exercise a "running" VM — by writing the test's OWN PID into qemu.pid so `vm_running`
# returns true. That makes the STATUS FIELD say running while omitting the one thing that
# actually breaks: a real process holding a lock on the image. The fixture faked the state
# and skipped the mechanism, so `qemu-img` succeeded and the bug was invisible. A test can
# assert `process.running true` forever and never touch this.
#
# HOW THIS ONE REPRODUCES IT WITHOUT A VM. Shadow `qemu-img` on PATH with a stub that exits
# 1. That is the real failure condition — present but failing — with no KVM, no boot and no
# lock to arrange, so it runs anywhere CI does. The negative control is built in: assertion 2
# proves the stub is actually being used, or assertion 1 would pass for the wrong reason.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq

tmp="$(mktemp -d)"
# Belt and braces: this file's cleanup trap replaces the harness's, so it carries its own
# net. A test that exits non-zero without a verdict is a broken test, not a result — and
# this one managed exactly that on its first negative-control run.
_verdict_printed=0
# Mirror the micro-cloud lib's _VERDICT idiom: a test that already printed FAIL must not
# ALSO be told "no verdict was printed", or the net becomes noise a reader learns to skip.
fail() { _verdict_printed=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
skip() { _verdict_printed=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
_on_exit() {
    local rc=$?
    rm -rf "$tmp"
    if (( rc != 0 && rc != 77 )) && (( _verdict_printed == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT
export LAB_STATE_DIR="$tmp/state" LAB_CACHE_DIR="$tmp/cache"

VM=lockedvm
"$LAB_VM" create --name "$VM" --backend kernel+initrd --kernel /dev/null --initrd /dev/null \
    >"$tmp/create.log" 2>&1 || { cat "$tmp/create.log" >&2; fail "could not create the fixture VM"; }

# A disk the manifest points at, so the virtual-size branch is actually entered.
d="$LAB_STATE_DIR/vms/$VM"
printf 'not-a-real-qcow2' > "$d/disk.qcow2"
printf 'disk = "%s/disk.qcow2"\n' "$d" >> "$d/manifest.toml"
# Make vm_running true the way the sibling test does — the status field is not what is under
# test here, the qemu-img failure is.
echo $$ > "$d/qemu.pid"

# ── the stub: qemu-img exists and FAILS, exactly like a locked image ────────
mkdir -p "$tmp/bin"
cat > "$tmp/bin/qemu-img" <<'STUB'
#!/usr/bin/env bash
# Stand-in for the real refusal: qemu-img: Could not open '…': Failed to get shared
# "write" lock. Is another process using the image?
printf 'qemu-img: Could not open: Failed to get shared "write" lock\n' >&2
exit 1
STUB
chmod +x "$tmp/bin/qemu-img"
export PATH="$tmp/bin:$PATH"

command -v qemu-img >/dev/null || skip "no qemu-img on PATH even after shadowing"
qemu-img info /dev/null >/dev/null 2>&1 \
    && fail "the stub qemu-img exited 0 — this test would then prove nothing about a FAILING qemu-img"
note "stub in place: qemu-img is present and exits 1, as it does on a running VM's disk"

# ── 1. --json must still succeed, and still carry the socket paths ─────────
out="$tmp/out.json"; err="$tmp/out.err"
# `cmd; rc=$?` is NOT errexit-safe: this lib sets `set -e`, so a failing command exits the
# script THERE, before `$?` is ever read. Caught by the negative control below — with the
# defect re-injected this file exited 1 printing no verdict at all, which is precisely the
# silent exit it exists to forbid. `if` puts the command in a condition, where errexit is
# exempt.
if "$LAB_VM" inspect "$VM" --json >"$out" 2>"$err"; then rc=0; else rc=$?; fi
(( rc == 0 )) \
    || fail "REGRESSION: 'inspect --json' exited $rc when qemu-img could not open the disk — a running VM's disk is ALWAYS locked, so this is the normal case, not an error. stderr: $(head -c 200 "$err")"
[[ -s "$out" ]] \
    || fail "REGRESSION: 'inspect --json' exited 0 but printed nothing — the silent-exit bug, wearing a success code"
ser="$(jq -r '.sockets.serial.path // empty' <"$out")" \
    || fail "inspect --json emitted output that is not valid JSON"
[[ -n "$ser" ]] \
    || fail "inspect --json carried no .sockets.serial.path — the field a harness needs to attach a console reader"
note "--json: rc=0, valid JSON, serial socket path present"

# ── 2. the UNKNOWN is reported as null, not invented ───────────────────────
# This is also the control for assertion 1: if the stub were NOT being used, the real
# qemu-img would refuse this 16-byte non-qcow2 file anyway — but a REAL number here would
# mean something impossible, and a missing key would mean the schema moved.
vs="$(jq -r 'if (.files.disk|has("virtual_size_bytes")) then (.files.disk.virtual_size_bytes|tostring) else "MISSING" end' <"$out")"
[[ "$vs" != "MISSING" ]] || fail "the disk.virtual_size_bytes key vanished from the schema"
[[ "$vs" == "null" ]] \
    || fail "virtual_size is '$vs' when qemu-img could not read the disk — 'I could not look' must render as null, never as a number"
note "--json: disk.virtual_size_bytes = null — an honest UNKNOWN, not a fabricated size"

# ── 3. the human form breaks the same way, so it is asserted too ───────────
if "$LAB_VM" inspect "$VM" >"$tmp/human.out" 2>"$tmp/human.err"; then hrc=0; else hrc=$?; fi
(( hrc == 0 )) \
    || fail "REGRESSION: the human 'inspect' exited $hrc with the same locked disk — both forms share the failing statement, so both need the guard"
[[ -s "$tmp/human.out" ]] || fail "the human 'inspect' exited 0 but printed nothing"
note "human form: rc=0 and non-empty"

_verdict_printed=1; pass "inspect survives a disk qemu-img cannot open — rc=0, valid JSON, socket paths intact, and the unreadable size reported as null rather than invented"

#!/usr/bin/env bash
# Every gate on `snapshot`, with no KVM and no real VMM — so they run everywhere.
#
# The sibling `test-snapshot-round-trip.sh` proves a real guest resumes. It needs KVM, a
# kernel and a bootable rootfs, so on most machines it SKIPs — and the refusals are the half
# that must never rot, because each one stands between an operator and a silently corrupted
# guest.
#
# ── THE GATE THAT MATTERS MOST, AND WHY IT IS NOT CEREMONY ──────────────────────────────
# A Firecracker snapshot is memory + device state. It does NOT contain the disk, but the
# guest's page cache, open inodes and dirty buffers all describe the rootfs AS IT WAS at the
# pause. Restore that memory over a rootfs that has moved on and NOTHING ERRORS: you get a
# running guest whose kernel believes things about a filesystem that are no longer true.
# That is filesystem corruption with a clean exit code — the worst shape this repo knows.
#
# So the digest check here is load-bearing, and it is asserted in all three outcomes:
# tampered → refused BY NAME with both digests; intact → NOT refused by that gate; no
# manifest at all → UNKNOWN, said out loud, never rendered as a pass.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd sha256sum

tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")
export LAB_STATE_DIR="$tmp/state"
export PATH="$tmp/bin:$PATH"
# The stand-in binds the API socket and never answers, so every call here rides the tool's
# timeout to the end. 20 s x3 is a minute of a headless test doing nothing; the VALUE is not
# what is under test (that it is bounded at all is), so it is pinned short here.
export LAB_FC_API_TIMEOUT=3
N=snapref
D="$LAB_STATE_DIR/fc/$N"

# A stand-in VMM. It does NOT exec, so its own argv — which carries this instance's paths —
# stays visible in /proc, and that argv is what lab-fc.sh's identity check reads.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/firecracker" <<'SHIM'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { printf 'Firecracker v1.16.1\n'; exit 0; }
sock=""; while (( $# )); do [[ "$1" == "--api-sock" ]] && sock="$2"; shift; done
# Bind something at the socket path so `-S` is true, without implementing the API.
[[ -n "$sock" ]] && command -v python3 >/dev/null 2>&1 && python3 - "$sock" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(sys.argv[1]); s.listen(1)
time.sleep(600)
PY
sleep 600
SHIM
chmod +x "$tmp/bin/firecracker"

# The fixtures have to satisfy `create`'s own preflight, which is the point: these gates
# are reached THROUGH it, and a fixture it refuses would leave every assertion below unrun.
# So the kernel is a real ELF and the rootfs a real ext4 with an /sbin/init — the same
# staging test-lifecycle-asserts-the-outcome.sh uses.
require_cmd mke2fs debugfs
K="$tmp/vmlinux"; R="$tmp/rootfs.ext4"
cp -- "$(command -v bash)" "$K" || skip "could not stage an ELF kernel fixture"
mkdir -p "$tmp/rfs/sbin" && cp -- /bin/true "$tmp/rfs/sbin/init"
truncate -s 16M "$R" && mke2fs -q -F -t ext4 -d "$tmp/rfs" "$R" >/dev/null 2>&1 \
    || skip "mke2fs could not build the rootfs fixture"
[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] \
    || skip "/dev/kvm is not read-write for uid $EUID — preflight's KVM gate refuses, so \`create\` cannot complete"

out="$(bash "$LAB_FC" create --name "$N" --kernel "$K" --rootfs "$R" --memory 256M 2>&1)" \
    || fail "create failed, so none of the gates below could be reached: $out"
on_exit 'bash "$LAB_FC" destroy '"$N"' --force >/dev/null 2>&1 || true'

# `rc=0; ... || rc=$?` and NOT `out=$(...); rc=$?`. Every call below is EXPECTED to fail —
# they are refusals — and a failing command substitution makes the ASSIGNMENT the failing
# command, which under `set -e` ends the test before `rc=$?` is ever reached. That is how
# this file first ran: one refusal, no verdict, and only the lib's EXIT net to say so.
r() { rc=0; out="$(bash "$LAB_FC" "$@" 2>&1)" || rc=$?; }

# ── 1. create needs a RUNNING VM. There is no memory in a stopped one ───────────────────
r snapshot create "$N" s1
(( rc != 0 )) || fail "snapshot create succeeded against a STOPPED instance — there is no memory to capture"
grep -q 'not running' <<<"$out" || fail "the refusal does not say the instance is not running: $out"
[[ ! -d "$D/snapshots/s1" ]] || fail "a refused create still left a snapshot directory behind"

# ── 2. a snapshot name is a PATH COMPONENT, gated like the instance name (P7-3) ─────────
r snapshot create "$N" ../escape
(( rc != 0 )) || fail "snapshot create accepted '../escape' as a name — it is used as a directory"
grep -q 'invalid snapshot name' <<<"$out" || fail "the refusal does not name the problem: $out"
[[ ! -d "$LAB_STATE_DIR/fc/escape" && ! -d "$D/snapshots/../escape" ]] \
    || fail "REGRESSION: a traversing snapshot name created a directory outside the instance"

# ── 3. missing things are named, not guessed at ─────────────────────────────────────────
r snapshot restore "$N" nosuch
(( rc != 0 )) || fail "restore of a nonexistent snapshot succeeded"
grep -q "no snapshot 'nosuch'" <<<"$out" || fail "the refusal does not name the snapshot: $out"
r snapshot delete "$N" nosuch
(( rc != 0 )) || fail "delete of a nonexistent snapshot succeeded"
r snapshot create nosuchinstance s1
(( rc != 0 )) || fail "snapshot create against a nonexistent instance succeeded"
r snapshot bogus "$N" s1
(( rc != 0 )) || fail "an unknown snapshot action was accepted"
grep -q 'unknown snapshot action' <<<"$out" || fail "the refusal does not name the bad action: $out"

# ── 4. list says nothing rather than nothing at all ─────────────────────────────────────
r snapshot list "$N"
(( rc == 0 )) || fail "snapshot list failed on an instance with no snapshots: $out"
grep -q 'no snapshots' <<<"$out" || fail "list printed no legible answer for an empty set: $out"

# ── 5. THE DIGEST GATE, in three outcomes ───────────────────────────────────────────────
# A snapshot directory is fabricated by hand. That is the honest subject: the gate's whole
# job is to recompute digests over these files and compare, and it neither knows nor cares
# which process wrote them.
mk_snap() {  # mk_snap <name> [--no-manifest]
    local s="$D/snapshots/$1"; mkdir -p "$s"
    printf 'VMSTATE-BYTES\n' > "$s/vmstate"
    printf 'MEM-BYTES\n'     > "$s/mem"
    printf 'ROOTFS-BYTES\n'  > "$s/rootfs.ext4"
    [[ "${2:-}" == "--no-manifest" ]] && return 0
    {
        printf 'instance = "%s"\nsnapshot = "%s"\ntaken = "2026-08-18T00:00:00Z"\n' "$N" "$1"
        printf 'vmstate_sha256 = "%s"\n' "$(sha256sum "$s/vmstate"     | cut -d' ' -f1)"
        printf 'mem_sha256 = "%s"\n'     "$(sha256sum "$s/mem"         | cut -d' ' -f1)"
        printf 'rootfs_sha256 = "%s"\n'  "$(sha256sum "$s/rootfs.ext4" | cut -d' ' -f1)"
    } > "$s/snapshot.toml"
}

# (a) INTACT — must NOT be refused by the digest gate. Without this the assertion below is
#     satisfied by a gate that refuses everything, which is indistinguishable from working.
mk_snap intact
want_rootfs="$(sha256sum "$D/snapshots/intact/rootfs.ext4" | cut -d' ' -f1)"
r snapshot restore "$N" intact
grep -q 'is not the file that was captured' <<<"$out" \
    && fail "the digest gate refused an INTACT snapshot — it fires on everything and proves nothing: $out"
grep -q 'digests match' <<<"$out" || fail "an intact snapshot was not reported as matching: $out"
# It then fails at the stand-in VMM, which is expected and is not what this row asserts.

# (b) TAMPERED — one byte, refused BY NAME, with BOTH digests.
mk_snap tampered
printf 'X' >> "$D/snapshots/tampered/mem"
got_mem="$(sha256sum "$D/snapshots/tampered/mem" | cut -d' ' -f1)"
want_mem="$(sed -n 's/^mem_sha256 = "\(.*\)"$/\1/p' "$D/snapshots/tampered/snapshot.toml")"
r snapshot restore "$N" tampered
(( rc != 0 )) || fail "REGRESSION: restore proceeded with a snapshot whose memory image had changed — restoring memory onto bytes it does not describe corrupts the guest silently"
grep -q 'mem is not the file that was captured' <<<"$out" \
    || fail "REGRESSION: the refusal does not name WHICH file changed: $out"
grep -qF -- "$want_mem" <<<"$out" || fail "REGRESSION: the refusal omits the recorded digest: $out"
grep -qF -- "$got_mem"  <<<"$out" || fail "REGRESSION: the refusal omits the actual digest: $out"
[[ "$want_mem" != "$got_mem" ]] || fail "the test's own premise is broken: appending a byte did not change the digest"

# (c) NO MANIFEST — UNKNOWN. Not a match, not a mismatch, and never silence.
mk_snap unverifiable --no-manifest
r snapshot restore "$N" unverifiable
grep -q 'UNKNOWN' <<<"$out" \
    || fail "REGRESSION: a snapshot with no recorded digests was not reported as UNKNOWN — 'I could not check' must not read as 'this is fine': $out"
grep -q 'digests match' <<<"$out" \
    && fail "REGRESSION: a snapshot with NO manifest was reported as matching: $out"

# ── 6. restore refuses to run over a LIVE instance ──────────────────────────────────────
out="$(bash "$LAB_FC" start "$N" 2>&1)" || skip "the stand-in VMM did not start; the live-instance gates were NOT exercised"
r snapshot restore "$N" intact
(( rc != 0 )) || fail "REGRESSION: restore ran against a RUNNING instance — it replaces both memory and disk under a live guest"
grep -q 'is running' <<<"$out" || fail "the refusal does not say the instance is running: $out"

# ...and `create` against a running instance gets past that gate and fails at the API,
# which is the stand-in's limit, not the tool's. Asserted only as "it is not the
# not-running refusal", so this row cannot silently start passing for the wrong reason.
r snapshot create "$N" live1
grep -q 'is not running' <<<"$out" \
    && fail "create said the instance was not running while it was — the identity check no longer recognises a VMM started with an API socket (P7-5's shape, via the new verb)"

pass "every snapshot gate refuses by name: stopped/running preconditions, path-component names, missing snapshots and actions — and the digest gate fires on a tampered snapshot with BOTH digests, stays quiet on an intact one, and reports UNKNOWN when there is nothing to compare"

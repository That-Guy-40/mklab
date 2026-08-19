#!/usr/bin/env bash
# Every gate on `clone`, with NO KVM, NO firecracker and NO snapshot that was ever taken.
#
# The sibling examples/micro-cloud/tests/test-fleet-clones.sh proves five real clones come
# up from one memory image. It needs KVM, a kernel and a bootable rootfs, so on most
# machines — CI included — it SKIPs. This file is the half that must run EVERYWHERE, and it
# is deliberately built so that it can: every gate below fires BEFORE any VMM is spawned,
# so the source instance is a directory and the snapshot is four files, both fabricated
# here. That is the honest subject — `clone`'s gates are questions about paths and digests,
# and they neither know nor care which process wrote the bytes they are reading.
#
# ── WHY THE ORDER OF THESE GATES IS THE PROPERTY, NOT JUST THEIR EXISTENCE ───────────────
# `clone` copies a guest disk. On a real fleet that is hundreds of megabytes per clone, and
# a gate that fires after the copy is a post-mortem rather than a gate — the rule this repo
# wrote after watching a PCR check run after the `dd`. So each refusal below is asserted
# TWICE: that it refused, and that the new instance directory does not exist afterwards.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd sha256sum

tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")
export LAB_STATE_DIR="$tmp/state"
SRC=csrc
D="$LAB_STATE_DIR/fc/$SRC"

# A source instance and a snapshot, made by hand. `clone` requires the instance DIRECTORY to
# exist and the snapshot directory to contain the three files with matching digests; it does
# not require either to have been produced by a VMM, which is what lets this run in CI.
mk_snap() {  # mk_snap <name> [--no-manifest]
    local s="$D/snapshots/$1"; mkdir -p "$s"
    printf 'VMSTATE-BYTES\n' > "$s/vmstate"
    printf 'MEM-BYTES\n'     > "$s/mem"
    printf 'ROOTFS-BYTES\n'  > "$s/rootfs.ext4"
    [[ "${2:-}" == "--no-manifest" ]] && return 0
    {
        printf 'instance = "%s"\nsnapshot = "%s"\ntaken = "2026-08-19T00:00:00Z"\n' "$SRC" "$1"
        printf 'vmstate_sha256 = "%s"\n' "$(sha256sum "$s/vmstate"     | cut -d' ' -f1)"
        printf 'mem_sha256 = "%s"\n'     "$(sha256sum "$s/mem"         | cut -d' ' -f1)"
        printf 'rootfs_sha256 = "%s"\n'  "$(sha256sum "$s/rootfs.ext4" | cut -d' ' -f1)"
    } > "$s/snapshot.toml"
}
mkdir -p "$D"
printf 'name = "%s"\nlab = "clonetest"\n' "$SRC" > "$D/manifest.toml"
mk_snap warm

# `rc=0; … || rc=$?` and NOT `out=$(…); rc=$?`. Every call below is EXPECTED to fail, and a
# failing command substitution makes the ASSIGNMENT the failing command, which under `set -e`
# ends the test before `rc=$?` is ever reached. That is how the sibling snapshot-refusal test
# first ran: one refusal, no verdict, and only the lib's EXIT net to say so.
r() { rc=0; out="$(bash "$LAB_FC" "$@" 2>&1)" || rc=$?; }
gone() { [[ ! -e "$LAB_STATE_DIR/fc/$1" ]] || fail "REGRESSION: a refused clone left an instance directory behind at $LAB_STATE_DIR/fc/$1 — the refusal fired after the copy, not before it"; }

# ── 1. both names are path components, and BOTH are gated ───────────────────────────────
# P7-3 was exactly one un-gated positional. `clone` takes two instance names, so validating
# only the first would reopen the hole through the argument nobody was looking at.
r clone "$SRC" warm ../escape
(( rc != 0 )) || fail "clone accepted '../escape' as the new instance name — it is used as a directory"
grep -q 'invalid instance name' <<<"$out" || fail "the refusal does not name the problem: $out"
[[ ! -d "$LAB_STATE_DIR/fc/escape" && ! -d "$LAB_STATE_DIR/../escape" ]] \
    || fail "REGRESSION: a traversing clone name created a directory outside the state dir"
r clone ../escape warm w1
(( rc != 0 )) || fail "clone accepted '../escape' as the SOURCE instance name"
grep -q 'invalid instance name' <<<"$out" || fail "the source-name refusal does not name the problem: $out"
r clone "$SRC" ../escape w1
(( rc != 0 )) || fail "clone accepted '../escape' as the SNAPSHOT name — it is used as a directory"
grep -q 'invalid snapshot name' <<<"$out" || fail "the snapshot-name refusal does not name the problem: $out"

# ── 2. missing things are named, not guessed at ─────────────────────────────────────────
r clone nosuchinstance warm w1
(( rc != 0 )) || fail "clone from a nonexistent instance succeeded"
grep -q 'no such instance' <<<"$out" || fail "the refusal does not say the instance is missing: $out"
r clone "$SRC" nosuchsnap w1
(( rc != 0 )) || fail "clone from a nonexistent snapshot succeeded"
grep -q "no snapshot 'nosuchsnap'" <<<"$out" || fail "the refusal does not name the snapshot: $out"
gone w1

# ── 3. a clone needs a NEW name ─────────────────────────────────────────────────────────
# Cloning an instance onto itself is `snapshot restore` spelled wrong, and it would have
# raced the source's own state dir. The refusal names the verb that does what was meant.
r clone "$SRC" warm "$SRC"
(( rc != 0 )) || fail "clone into the SOURCE's own name succeeded — that is restore, and it would have overwritten the snapshot's own instance"
grep -q 'snapshot restore' <<<"$out" || fail "the refusal does not name the verb that does what was meant: $out"

mkdir -p "$LAB_STATE_DIR/fc/taken"
r clone "$SRC" warm taken
(( rc != 0 )) || fail "REGRESSION: clone overwrote an existing instance directory"
grep -q 'already exists' <<<"$out" || fail "the refusal does not say the name is taken: $out"

# ── 4. THE DIGEST GATE, in three outcomes, and it is the SAME gate `restore` uses ────────
# A snapshot whose bytes have moved is not clonable. Restoring a memory image onto bytes it
# does not describe is filesystem corruption with a clean exit code — and a clone multiplies
# that by N. The gate lives in one function precisely so that `clone`, added after `restore`,
# could not ship with a weaker copy of it.

# (a) INTACT — must NOT be refused by the digest gate. Without this row the assertion below
#     is satisfied by a gate that refuses everything, which is indistinguishable from working.
r clone "$SRC" warm w-intact
grep -q 'is not the file that was captured' <<<"$out" \
    && fail "the digest gate refused an INTACT snapshot — it fires on everything and proves nothing: $out"
grep -q 'digests match' <<<"$out" || fail "an intact snapshot was not reported as matching: $out"
# It then fails at `firecracker`, which is not on PATH here. That is expected and is not what
# this row asserts — but the directory it had begun must still be gone, because a clone that
# could not be resumed is not a clone.
gone w-intact

# (b) TAMPERED — one byte, refused BY NAME, with BOTH digests, and nothing copied.
mk_snap tampered
printf 'X' >> "$D/snapshots/tampered/mem"
got_mem="$(sha256sum "$D/snapshots/tampered/mem" | cut -d' ' -f1)"
want_mem="$(sed -n 's/^mem_sha256 = "\(.*\)"$/\1/p' "$D/snapshots/tampered/snapshot.toml")"
[[ "$want_mem" != "$got_mem" ]] || fail "the test's own premise is broken: appending a byte did not change the digest"
r clone "$SRC" tampered w-tamper
(( rc != 0 )) || fail "REGRESSION: clone proceeded from a snapshot whose memory image had changed"
grep -q 'mem is not the file that was captured' <<<"$out" \
    || fail "REGRESSION: the refusal does not name WHICH file changed: $out"
grep -qF -- "$want_mem" <<<"$out" || fail "REGRESSION: the refusal omits the recorded digest: $out"
grep -qF -- "$got_mem"  <<<"$out" || fail "REGRESSION: the refusal omits the actual digest: $out"
gone w-tamper

# (c) NO MANIFEST — UNKNOWN. Not a match, not a mismatch, and never silence.
mk_snap unverifiable --no-manifest
r clone "$SRC" unverifiable w-unk
grep -q 'UNKNOWN' <<<"$out" \
    || fail "REGRESSION: a snapshot with no recorded digests was not reported as UNKNOWN — 'I could not check' must not read as 'this is fine': $out"
grep -q 'digests match' <<<"$out" \
    && fail "REGRESSION: a snapshot with NO manifest was reported as matching: $out"

# ── 5. destroy refuses to pull a shared memory image out from under a clone ─────────────
# `clone` SHARES the snapshot's mem file rather than copying it, so the source instance's
# state dir is a live dependency of every clone made from it. Destroying it is the "record
# outlives its subject" shape with the subject deleted on purpose, so it is refused by name
# and --force is how you say you meant it.
#
# The clone here is fabricated, for the same reason the snapshot is: the guard's whole job is
# to read sibling manifests, and it neither knows nor cares which verb wrote them.
mkdir -p "$LAB_STATE_DIR/fc/w-dep"
{
    printf 'name = "w-dep"\ncloned_from = "%s/warm"\n' "$SRC"
    printf 'clone_mem = "%s/snapshots/warm/mem"\n' "$D"
} > "$LAB_STATE_DIR/fc/w-dep/manifest.toml"
r destroy "$SRC"
(( rc != 0 )) || fail "REGRESSION: destroy removed a memory image a clone reads out of, with no warning"
grep -q 'w-dep' <<<"$out" || fail "the refusal does not NAME the dependent clone — a count cannot say which one: $out"
[[ -d "$D" ]] || fail "REGRESSION: destroy refused and deleted the directory anyway"
# ...and --force is how you say you meant it, which must actually work or the refusal above
# is a dead end rather than a gate.
r destroy "$SRC" --force
(( rc == 0 )) || fail "destroy --force did not remove the source after the clone guard refused: $out"
[[ ! -d "$D" ]] || fail "destroy --force reported success and left $D behind"

pass "every clone gate refuses by name and BEFORE the disk copy: both instance names and the snapshot name are gated as path components, missing instances and snapshots are named, a clone onto its own name is sent to \`snapshot restore\`, an existing name is not overwritten — the digest gate (shared with restore, not a second copy) fires on a tampered snapshot with BOTH digests, stays quiet on an intact one and says UNKNOWN when there is nothing to compare, and destroy refuses to delete a memory image a clone is reading until --force"

#!/usr/bin/env bash
# REGRESSION (REVIEW-phase7.md §3): a digest nobody compares is decoration.
#
# `create` recorded `rootfs_source_sha256`, and the plan says it is there "so a re-staged
# source image is detectable instead of silent". Measured: NO verb in the tool ever read it
# back — `git grep` finds one writer, one test asserting the field is 64 hex characters, and
# no reader. The test asserted the MECHANISM (a field exists, shaped like a digest) and not
# the outcome (a swap is refused), which is the second of the two bug classes CLAUDE.md
# names, in a guard against the first.
#
# And the KERNEL — which config.json points at BY PATH rather than copying, and which this
# repo actually rebuilds between runs (micro-cloud rebuilds vmlinux) — had no digest at all.
# That is the metal-as-a-service row verbatim: *the served deployer vmlinuz vs the kernel
# rebuilt over it — `file -b` printed the identical version string, only the sha differed.*
#
# Measured before the fix: create an instance, overwrite the kernel with different bytes,
# and every verb carried on. `inspect` reprinted the same manifest, `list` said `stopped`,
# `start` launched it. Nothing in the tool could tell you the machine had changed.
#
# WHY ONLY THE KERNEL IS GATED AT `start`: the rootfs copy is booted READ-WRITE, so its
# digest is EXPECTED to differ after the first boot. A gate that fires on correct behaviour
# is a gate someone switches off. `inspect` reports the rootfs source in three outcomes
# instead — and UNKNOWN is one of them.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd sha256sum

tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")   # NOT a second EXIT trap — see lib.sh
fc_fixtures
export LAB_STATE_DIR="$tmp/state"

# A private copy of the kernel, so the swap below cannot touch the shared fixture.
K="$tmp/vmlinux-own"; cp -- "$FC_K" "$K"
R="$FC_R"
n="p7dig$$"

# A stand-in VMM that stays up, so "start was refused" and "start failed for some other
# reason" cannot be confused. See test-lifecycle-asserts-the-outcome.sh for the seam.
mkdir -p "$tmp/bin"
want_ver="$(sed -n 's/^readonly FC_PINNED_VERSION="\${FC_PINNED_VERSION:-\(v[0-9.]*\)}"$/\1/p' "$LAB_FC")"
cat > "$tmp/bin/firecracker" <<SHIM
#!/usr/bin/env bash
[[ "\$1" == "--version" ]] && { printf 'Firecracker %s\n' '$want_ver'; exit 0; }
trap 'exit 0' TERM
while :; do sleep 0.2; done
SHIM
chmod +x "$tmp/bin/firecracker"
PATH="$tmp/bin:$PATH"; export PATH
on_exit 'p="$(cat "$LAB_STATE_DIR/fc/$n/fc.pid" 2>/dev/null || true)"; [[ "$p" =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; true'

run_fc "$tmp/c.out" create --name "$n" --kernel "$K" --rootfs "$R" \
    || { cat "$tmp/c.out" >&2; fail "create refused a spec built from this test's own fixtures"; }
man="$LAB_STATE_DIR/fc/$n/manifest.toml"

# ── 1. the kernel digest is recorded at all ───────────────────────────────────────────
rec="$(sed -n 's/^kernel_sha256 = "\(.*\)"$/\1/p' "$man")"
[[ "$rec" =~ ^[0-9a-f]{64}$ ]] \
    || fail "REGRESSION: the manifest records no kernel_sha256 — the half of the boot that is NOT copied has nothing binding it to this instance (§3)"
[[ "$rec" == "$(sha256sum "$K" | cut -d' ' -f1)" ]] \
    || fail "the recorded kernel_sha256 is not the digest of the kernel that was used"
note "the kernel is bound to the instance by sha256 at create"

# ── 2. and it is COMPARED, before the irreversible step ──────────────────────────────
cp -- /bin/false "$K"        # different bytes, still a valid ELF: `file -b` cannot tell
run_fc "$tmp/s.out" start "$n" && rc=0 || rc=$?
(( rc != 0 )) \
    || fail "REGRESSION: 'start' launched an instance whose kernel had been replaced — the recorded digest is decoration again (§3)"
grep -q 'REFUSING to start' "$tmp/s.out" \
    || fail "start failed but not with the digest refusal — something else stopped it by luck. Got: $(cat "$tmp/s.out")"
grep -q "$rec" "$tmp/s.out" \
    || fail "the refusal does not print the RECORDED digest, so the operator cannot tell which artifact moved"
grep -q "$(sha256sum "$K" | cut -d' ' -f1)" "$tmp/s.out" \
    || fail "the refusal does not print the ON-DISK digest — 'they differ' without saying how is a dead end"
[[ -e "$LAB_STATE_DIR/fc/$n/fc.pid" ]] \
    && fail "REGRESSION: the refusal happened AFTER the VMM was spawned — a gate after the act is a post-mortem"
note "a swapped kernel is refused before anything is spawned, and both digests are printed"

# ── 3. inspect reports it in THREE outcomes ──────────────────────────────────────────
run_fc "$tmp/i.out" inspect "$n" || fail "inspect failed"
grep -q 'kernel_check = "CHANGED since create"' "$tmp/i.out" \
    || fail "inspect does not report the changed kernel; got: $(grep _check "$tmp/i.out")"
grep -q 'rootfs_source_check = "match"' "$tmp/i.out" \
    || fail "inspect does not report the (unchanged) rootfs source as matching; got: $(grep _check "$tmp/i.out")"
mv -- "$K" "$K.moved"
run_fc "$tmp/i2.out" inspect "$n" || fail "inspect failed with the kernel absent"
grep -q 'kernel_check = "UNKNOWN' "$tmp/i2.out" \
    || fail "REGRESSION: a MISSING kernel is not reported as UNKNOWN — 'I could not look' is being rendered as a verdict about the file (§3). Got: $(grep _check "$tmp/i2.out")"
note "inspect distinguishes match / CHANGED / UNKNOWN, and a missing artifact is UNKNOWN"

# ── 4. --force is the documented way past it, and it says so ─────────────────────────
mv -- "$K.moved" "$K"
run_fc "$tmp/f.out" start "$n" --force || { cat "$tmp/f.out" >&2; fail "'start --force' did not start an instance whose kernel changed"; }
grep -q 'mismatch' "$tmp/f.out" \
    || fail "'start --force' started silently — a bypass that says nothing is how a stale artifact gets normalised"
run_fc "$tmp/st.out" stop "$n" --force || fail "cleanup: stop failed"
note "--force starts anyway and SAYS it did"

# ── 5. CONTROL: an unchanged kernel starts without complaint ─────────────────────────
# A "verification" that refused every start would pass every assertion above.
run_fc "$tmp/c2.out" destroy "$n" --force || fail "cleanup: destroy failed"
cp -- "$FC_K" "$K"
run_fc "$tmp/c3.out" create --name "$n" --kernel "$K" --rootfs "$R" || fail "control: create failed"
run_fc "$tmp/s2.out" start "$n" || { cat "$tmp/s2.out" >&2; fail "control: 'start' refused an instance whose kernel is untouched — the digest gate refuses everything"; }
grep -q 'REFUSING' "$tmp/s2.out" && fail "control: an untouched kernel produced a refusal message"
grep -q 'kernel sha256 matches' "$tmp/s2.out" \
    || fail "control: 'start' did not report that it checked — a check nobody can see is one nobody notices stopping"
run_fc "$tmp/i3.out" inspect "$n"
grep -q 'kernel_check = "match"' "$tmp/i3.out" || fail "control: inspect does not report an untouched kernel as matching"
run_fc "$tmp/st2.out" stop "$n" --force || fail "cleanup: stop failed"
run_fc "$tmp/d.out" destroy "$n" --force || fail "cleanup: destroy failed"
note "control: an untouched kernel starts, says it was checked, and inspects as 'match'"

pass "the recorded kernel digest is compared before start and refused by name, and inspect reports both artifacts in three outcomes (§3)"

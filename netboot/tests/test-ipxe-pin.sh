#!/usr/bin/env bash
# Verdict: the iPXE build's inputs are pinned (AUDIT F5), and the pin REFUSES a moved tag
# instead of building different bytes under the same name.
#
# WHY THIS EXISTS. `--ipxe-ref` defaulted to `master` and the build container was
# `debian:bookworm` with no digest, so no artifact this pipeline produced could answer
# "which source did you come from?". F5 called that Low severity, and for a lab it is —
# until the artifact is a firmware that verifies OTHER things' signatures, which is
# exactly what --imgverify builds.
#
# THE PIN IS A HASH, NOT A NAME. A git tag is a mutable pointer. If upstream moves
# v2.0.0, `git clone --branch v2.0.0` still succeeds, still reports the ref it was asked
# for, and hands the build different source — "a version string is not an identity". So
# versions.env records the commit alongside the ref and the builder compares hashes.
#
# WHAT EACH HALF PROVES, AND WHY BOTH ARE HERE:
#   §2 the host forwards the expected commit — if it regressed to always-empty, §3's
#      check would still be present and would simply never fire. A gate that cannot
#      refuse cannot protect (same shape as MAAS's `describe` defect, 2026-08-06).
#   §3 the refusal bites: a wrong commit stops the build BEFORE make is invoked.
#   §4 THE CONTROL: the right commit gets past the gate and make IS invoked. Without it,
#      an inner script that died on every input would satisfy §3 and prove nothing.
#
# Headless: no Docker, no network, no root. `docker` and the container's toolchain are
# PATH shims that record what they were asked to do; the real build-ipxe.sh and the real
# ipxe-build-inner.sh run. The live proof that iPXE v2.0.0 actually compiles with every
# feature this pipeline switches on is in netboot/MANUAL_TESTING.md.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

BUILDER="$NETBOOT_DIR/build-ipxe.sh"
INNER="$NETBOOT_DIR/ipxe-build-inner.sh"
PINFILE="$NETBOOT_DIR/versions.env"
[[ -x "$BUILDER" ]] || fail "missing or non-executable: $BUILDER"
[[ -f "$INNER"   ]] || fail "missing: $INNER"
[[ -f "$PINFILE" ]] || fail "netboot/versions.env is missing — the pin AUDIT F5 asks for has no file to live in"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ipxe-pin.XXXXXX")"; TMPDIRS+=("$SANDBOX")

# ── 1. the pin file names a fixed ref, a full commit, and a digest ─────────
# Sourced in a subshell: it is code (AUDIT F3), and a `set -e` in it must not end us.
# shellcheck source=/dev/null
eval "$( ( . "$PINFILE" >/dev/null 2>&1
           printf 'P_REF=%q\nP_COMMIT=%q\nP_IMAGE=%q\n' \
               "${IPXE_REF:-}" "${IPXE_COMMIT:-}" "${IPXE_BUILD_IMAGE:-}" ) )"

[[ -n "$P_REF" ]] || fail "versions.env sets no IPXE_REF — build-ipxe.sh would fall back to 'master' and F5 would be open again"
case "$P_REF" in
    master|main|HEAD|origin/*)
        fail "versions.env pins IPXE_REF='$P_REF', which is a MOVING branch, not a release. That is the F5 defect wearing a pin's clothes: every build tracks upstream drift while the file claims otherwise" ;;
esac
[[ "$P_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
    || fail "versions.env's IPXE_COMMIT is '${P_COMMIT:-<unset>}', not a 40-hex commit. Without it the ref is a name, and a name is not an identity — a re-tagged '$P_REF' would build silently"
[[ "$P_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] \
    || fail "versions.env's IPXE_BUILD_IMAGE is '${P_IMAGE:-<unset>}' — no @sha256 digest, so the compiler and libc that produced the firmware are whatever the tag pointed at that day"
note "pin: $P_REF @ ${P_COMMIT:0:12} on ${P_IMAGE##*@}  ✓"

# ── 2. the host side forwards the pin — and does NOT forward it on override ──
# A `docker` shim captures the exact argv, which is the outcome that matters: the
# container is launched with the digest-pinned image and the expected commit as the
# last argument to the inner script.
SHIM="$SANDBOX/shim"; mkdir -p "$SHIM"
cat > "$SHIM/docker" <<'EOS'
#!/usr/bin/env bash
[[ "$1" == info ]] && exit 0
printf '[%s]\n' "$@" > "$DOCKER_ARGV"
exit 0
EOS
chmod +x "$SHIM/docker"

run_builder() {  # run_builder <argv-capture-file> <stderr-file> [extra args...]
    local argv="$1" errf="$2"; shift 2
    ( cd "$NETBOOT_DIR" && PATH="$SHIM:$PATH" DOCKER_ARGV="$argv" \
        ./build-ipxe.sh --output-dir "$SANDBOX/out" "$@" ) >/dev/null 2>"$errf" || true
}

run_builder "$SANDBOX/argv.default" "$SANDBOX/err.default"
[[ -s "$SANDBOX/argv.default" ]] \
    || fail "the docker shim was never invoked — build-ipxe.sh refused before launching the container, so nothing below was measured. Its stderr: $(tr '\n' ' ' < "$SANDBOX/err.default")"
grep -Fqx "[$P_IMAGE]" "$SANDBOX/argv.default" \
    || fail "REGRESSION: the build container was NOT launched from the digest-pinned image. versions.env says '$P_IMAGE'; the argv passed to docker was: $(tr '\n' ' ' < "$SANDBOX/argv.default")"
[[ "$(tail -1 "$SANDBOX/argv.default")" == "[$P_COMMIT]" ]] \
    || fail "REGRESSION: build-ipxe.sh did not forward the pinned commit to the inner script — the last argument was '$(tail -1 "$SANDBOX/argv.default")', not '[$P_COMMIT]'. The inner check would then be present and permanently inert: it only compares when it is given something to compare against"
note "default build: digest-pinned image, and $P_REF's commit forwarded for verification  ✓"

# The override half. This is not a lesser case: it is the one where a silent pass would
# mean every future build quietly stopped being checked.
run_builder "$SANDBOX/argv.master" "$SANDBOX/err.master" --ipxe-ref master
[[ "$(tail -1 "$SANDBOX/argv.master")" == "[]" ]] \
    || fail "REGRESSION: --ipxe-ref master was still handed the pinned commit ('$(tail -1 "$SANDBOX/argv.master")'). Every deliberate override would then be refused as a moved tag, which trains the operator to delete the check"
grep -q "not reproducible" "$SANDBOX/err.master" \
    || fail "an overridden --ipxe-ref built without warning that the result is unpinned. UNKNOWN is a verdict: a build nobody can trace back to a commit must say so, not look like a pinned one. Got: $(tr '\n' ' ' < "$SANDBOX/err.master")"
note "overridden ref: not verified, and the build announces that it is unpinned  ✓"

# ── 3/4. the refusal itself, run against the REAL inner script ─────────────
# The inner script is written to run inside the build container, so the container is
# what gets faked: a private /tmp (rootless user+mount namespace) plus apt-get/git/make
# shims. Everything the pin check touches is the real code.
command -v unshare >/dev/null 2>&1 \
    || skip "no unshare(1): §3/§4 need a private /tmp to run the real inner script without touching the host's. The pin file and the forwarding above are verified; the refusal is NOT — recorded as unknown, not as pass"

# The inner script travels in as TEXT, not as a path. /tmp is about to be shadowed by a
# tmpfs, and a repo checked out under /tmp (a scratch copy, a CI runner that uses it)
# would vanish along with it — the probe would then fail for a reason that has nothing to
# do with the pin, and say so in the pin's words. Measured, not imagined: the first
# negative-control sweep reported two bites that were really this.
ns_probe() {  # ns_probe <expected-sha> <sha-the-clone-resolves-to>
    unshare -rm --propagation private bash -s -- "$(cat "$INNER")" "$1" "$2" <<'NSEOF' 2>&1
set -uo pipefail
INNER_SRC="$1"; EXPECT="$2"; ACTUAL="$3"
mount -t tmpfs tmpfs /tmp 2>/dev/null || { echo "NS-NO-TMPFS"; exit 90; }
mkdir -p /tmp/shim
INNER=/tmp/inner.sh; printf '%s\n' "$INNER_SRC" > "$INNER"
printf '#!/bin/sh\nexit 0\n' > /tmp/shim/apt-get
# git: `clone` makes the tree the builder expects; `rev-parse` answers with the sha this
# probe is pretending upstream resolved to. That is the whole fault being injected.
cat > /tmp/shim/git <<'EOS'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    clone)     mkdir -p /tmp/ipxe/src/config; exit 0 ;;
    rev-parse) printf '%s\n' "$SHIM_SHA"; exit 0 ;;
  esac
done
exit 0
EOS
printf '#!/bin/sh\necho ran >> /tmp/make.log\nexit 0\n' > /tmp/shim/make
chmod +x /tmp/shim/apt-get /tmp/shim/git /tmp/shim/make
: > /tmp/make.log
export PATH="/tmp/shim:$PATH" SHIM_SHA="$ACTUAL"
bash "$INNER" http://h:8181 /kernel /initrd.gz "console=ttyS0" x86_64 v2.0.0 \
    "" "" "" "" "" "" "" "$EXPECT" > /tmp/out 2>&1
echo "INNER-RC=$?"
echo "MAKE-CALLS=$(grep -c ran /tmp/make.log || true)"
cat /tmp/out
NSEOF
}

WRONG=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
out="$(ns_probe "$WRONG" "$P_COMMIT")"
if grep -q NS-NO-TMPFS <<<"$out"; then
    skip "this kernel would not let an unprivileged user namespace mount a tmpfs, so the real inner script cannot be run without writing to the host's /tmp. §1 and §2 passed; the refusal is UNVERIFIED here — run netboot/MANUAL_TESTING.md's pin section instead"
fi
grep -q 'MAKE-CALLS=0' <<<"$out" \
    || fail "REGRESSION: a commit mismatch did not stop the build — make was invoked anyway. The gate must refuse BEFORE the work, not report it afterwards. Got: ${out//$'\n'/ }"
grep -q "$WRONG" <<<"$out" && grep -q "$P_COMMIT" <<<"$out" \
    || fail "the build was stopped, but the message does not print BOTH the expected and the actual commit, so the operator cannot tell a moved tag from a stale versions.env. Got: ${out//$'\n'/ }"
grep -q 'INNER-RC=0' <<<"$out" \
    && fail "REGRESSION: the inner script printed the mismatch and exited 0 — a false success. build-ipxe.sh would report a successful build of source it had just rejected"
note "wrong commit: refused, both hashes named, make never invoked  ✓"

# THE CONTROL. Without it, an inner script broken enough to die on any input would
# satisfy every assertion above.
out="$(ns_probe "$P_COMMIT" "$P_COMMIT")"
grep -qE 'MAKE-CALLS=[1-9]' <<<"$out" \
    || fail "the MATCHING commit did not get past the pin check either — make was never invoked. §3 therefore proved nothing: the inner script refuses everything, and the pin is not what stopped the wrong one. Got: ${out//$'\n'/ }"
note "matching commit: passes the gate and proceeds to build  ✓"

pass "the iPXE build's inputs are pinned and the pin bites: versions.env fixes $P_REF to ${P_COMMIT:0:12} on a digest-pinned base image, build-ipxe.sh forwards that commit for the pinned ref and deliberately does not for an override (announcing the build as unpinned), a mismatched commit is refused by name with both hashes before make runs, and the matching commit still builds"

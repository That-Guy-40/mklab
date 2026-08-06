#!/usr/bin/env bash
# The lab must build from the VENDORED archive, offline, and REFUSE a tampered one.
#
# WHY THIS EXISTS. TODO item 7 asks for a builder "available in whole, runnable per its own
# instructions". Vendoring the bytes only half-delivers that: if the driver still reaches
# for GitLab at build time, the archive is decorative and the lab still cannot be built
# without the network — from a repository that is RETIRED, whose last commit is 2026-03-25.
#
# It nearly stayed decorative. `fetch-kali-packer.sh` gained an offline default, but
# `build-kali-box.sh` passed `--ref "$REF"` UNCONDITIONALLY with `REF=main` as a default —
# and `--ref` implies `--upstream`, because a ref only means something against a remote. So
# every build would still have cloned, and the offline path would have existed and never
# run. One defaulted flag, and the feature is inert. Assertion 1 is aimed squarely at that.
#
# THE SECOND PROPERTY IS THAT THE ARCHIVE IS VERIFIED, NOT TRUSTED. A vendored tree is a
# cached copy of somebody else's repository; if it drifts, the compat patches, UPSTREAM.md's
# pin and the provenance table are all describing something else — this repo's bug class #1.
# So the fetcher checks SHA256SUMS on every run and REFUSES a mismatch. Assertion 3 breaks
# the archive on purpose and watches that refusal bite, because a verification step that has
# never rejected anything is not known to reject anything.
#
# Nothing here needs packer, KVM, or the network. The build is not run; only the sourcing
# of the upstream tree is.
set -uo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

_VERDICT=0
skip() { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }

command -v sha256sum >/dev/null || skip "missing required command: sha256sum"
tmp="$(mktemp -d)"
_on_exit() {
    local rc=$?
    rm -rf "$tmp"
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

[[ -d "$LAB_DIR/upstream-repo/kali-packer" ]] \
    || fail "the vendored archive is missing at upstream-repo/kali-packer — the lab cannot build offline at all"

# ── 1. the DEFAULT path is offline: no clone, no .git ──────────────────────
# A staged tree with a .git means it came from the network. That is the failure this
# assertion exists for, and it is invisible on a machine that happens to have connectivity
# — which is every machine anyone develops on.
w="$tmp/w1"
out="$("$LAB_DIR/fetch-kali-packer.sh" --workdir "$w" 2>&1)" \
    || fail "the default (offline) fetch failed: ${out//$'\n'/ }"
[[ -e "$w/kali-packer/config.pkr.hcl" ]] \
    || fail "the default fetch staged no usable tree at $w/kali-packer"
[[ ! -d "$w/kali-packer/.git" ]] \
    || fail "REGRESSION: the default fetch produced a GIT CHECKOUT — it went to the network. The vendored archive is being bypassed, so the lab still cannot build offline"
grep -qi 'vendored' <<<"$out" \
    || fail "the default fetch did not report using the vendored archive: ${out//$'\n'/ }"
grep -qi 'verif' <<<"$out" \
    || fail "the default fetch did not verify the archive — an unverified vendored tree is a cached fact nobody re-checked"
note "default fetch: offline, from the verified archive, no .git"

# ── 2. and the staged tree is byte-identical to what is committed ──────────
# Staging must not transform anything: the compat patches are applied later, to this copy,
# and the point of a byte-exact archive is that what runs is what was archived.
if ! diff -r "$LAB_DIR/upstream-repo/kali-packer" "$w/kali-packer" >"$tmp/diff" 2>&1; then
    fail "the staged tree differs from the committed archive: $(head -3 "$tmp/diff" | tr '\n' ' ')"
fi
note "staged tree is byte-identical to the committed archive"

# ── 2b. THE DRIVER must take the offline path too ──────────────────────────
# Assertions 1-2 exercise fetch-kali-packer.sh directly, and that is NOT where the bug was.
# build-kali-box.sh is what a user runs, and it passed `--ref "$REF"` with REF defaulting to
# "main" — which implies --upstream. The fetcher's offline default was therefore correct and
# never reached. Testing only the fetcher would have declared this feature working while
# every real build still cloned.
w3="$tmp/w3"
# The build stops at "packer not found" here, and that is fine: staging happens first, and
# the staged tree is the whole question. rc is deliberately ignored.
out="$("$LAB_DIR/build-kali-box.sh" --workdir "$w3" --validate-only 2>&1 || true)"
[[ -e "$w3/kali-packer/config.pkr.hcl" ]] \
    || fail "build-kali-box.sh staged no upstream tree at all: ${out//$'\n'/ }"
[[ ! -d "$w3/kali-packer/.git" ]] \
    || fail "REGRESSION: build-kali-box.sh produced a GIT CHECKOUT — the driver is still passing --ref (or --upstream) by default, so the vendored archive is bypassed and the lab cannot build offline. This is the exact defect this assertion exists for"
grep -qi 'vendored' <<<"$out" \
    || fail "build-kali-box.sh did not report staging the vendored archive: ${out//$'\n'/ }"
note "build-kali-box.sh (the thing users run) also takes the offline path by default"

# ── 3. a tampered archive is REFUSED, and nothing is staged ────────────────
# The negative control. Done on a COPY of the lab so the repo is never modified.
cp -a "$LAB_DIR" "$tmp/lab"
printf '\n# tampered by test-offline-archive.sh\n' >> "$tmp/lab/upstream-repo/kali-packer/scripts/vagrant.sh"
w2="$tmp/w2"
if out="$("$tmp/lab/fetch-kali-packer.sh" --workdir "$w2" 2>&1)"; then
    fail "REGRESSION: a TAMPERED archive was accepted — SHA256SUMS is not being checked, so the lab would build from bytes that are no longer the ones UPSTREAM.md describes"
fi
grep -qi 'does not match SHA256SUMS' <<<"$out" \
    || fail "the tampered archive was refused, but not by naming the checksum mismatch — an operator cannot act on an unexplained refusal: ${out//$'\n'/ }"
grep -q 'vagrant.sh' <<<"$out" \
    || fail "the refusal did not name WHICH file failed, so it cannot be repaired: ${out//$'\n'/ }"
[[ ! -e "$w2/kali-packer/config.pkr.hcl" ]] \
    || fail "REGRESSION: the tampered archive was refused but the tree was staged ANYWAY — a gate after the act is a post-mortem"
note "tampered archive: refused by name, naming the file, and nothing staged"

# ── 4. the repo's own archive still verifies (this test changed nothing) ───
( cd "$LAB_DIR/upstream-repo" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) \
    || fail "the committed archive no longer matches its SHA256SUMS — either this test modified the repo (it must not) or the archive was edited without regenerating the manifest"
note "the committed archive still verifies — this test modified nothing in the repo"

pass "the lab builds from the vendored archive offline by default, staging it byte-exact, and refuses a tampered archive by name before staging anything"

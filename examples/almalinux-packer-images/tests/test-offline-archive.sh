#!/usr/bin/env bash
# The vendored AlmaLinux factory must stage OFFLINE, byte-exact, and REFUSE a tampered copy.
#
# WHY. TODO item 7 wants a builder "available in whole, runnable per its own instructions".
# For the Kali sibling that is justified by upstream being retired. Here upstream is ALIVE,
# so the archive is a dated snapshot — and a snapshot that nobody verifies is strictly worse
# than a URL, because it looks authoritative while quietly being whatever someone last
# edited. Verification is what makes a snapshot honest, so it is what this test asserts.
#
# THE 563-FILE COUNT IS LOAD-BEARING, and this is the finding worth keeping. Upstream ships
# a `.gitignore` containing `*.pkrvars.hcl` AND tracks `tests/test-values.pkrvars.hcl`.
# Vendored verbatim, that `.gitignore` applies to OUR subtree — so a plain `git add` drops
# that file silently and the archive stops being complete with nothing reporting it. It is
# force-added, and assertion 2 below is what would notice if a future re-vendor forgot.
#
# Needs no network, no packer, no KVM. The build is not run; only the staging is.
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

ARCHIVE="$LAB_DIR/upstream-repo/cloud-images"
[[ -d "$ARCHIVE" ]] || fail "the vendored archive is missing at upstream-repo/cloud-images"

# ── 1. the archive matches its own manifest ────────────────────────────────
( cd "$LAB_DIR/upstream-repo" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) \
    || fail "the committed archive does not match its SHA256SUMS — it was edited without regenerating the manifest, so the pin and the provenance table now describe something else"
note "archive matches SHA256SUMS"

# ── 2. …and the manifest still covers every file, including the ignored one ─
n_manifest="$(grep -c . "$LAB_DIR/upstream-repo/SHA256SUMS")"
n_ondisk="$(find "$ARCHIVE" -type f | wc -l)"
(( n_manifest == n_ondisk )) \
    || fail "SHA256SUMS lists $n_manifest files but $n_ondisk are on disk — the archive and its manifest disagree, so 'all OK' would be checking a subset"
n_tracked="$(cd "$LAB_DIR" && git ls-files upstream-repo/cloud-images | wc -l)"
(( n_tracked == n_ondisk )) \
    || fail "git tracks $n_tracked of the $n_ondisk archived files — the vendored .gitignore (which lists *.pkrvars.hcl) is hiding files from OUR repository. They need 'git add -f'; see upstream-repo/README.md"
[[ -f "$ARCHIVE/tests/test-values.pkrvars.hcl" ]] \
    || fail "tests/test-values.pkrvars.hcl is absent — upstream tracks it, and the vendored .gitignore is exactly why it goes missing without anything reporting it"
note "$n_ondisk files: on disk == in SHA256SUMS == tracked by git (the .gitignore trap is not biting)"

# ── 3. the default path stages offline, byte-exact, with no clone ──────────
w="$tmp/w"
out="$("$LAB_DIR/fetch-cloud-images.sh" --workdir "$w" 2>&1)" \
    || fail "the default (offline) stage failed: ${out//$'\n'/ }"
[[ -e "$w/cloud-images/variables.pkr.hcl" ]] \
    || fail "the default stage produced no usable tree at $w/cloud-images"
[[ ! -d "$w/cloud-images/.git" ]] \
    || fail "REGRESSION: the default stage produced a GIT CHECKOUT — it went to the network, so the archive is bypassed and the lab cannot be built offline"
grep -qi 'verif' <<<"$out" \
    || fail "the default stage did not verify the archive: ${out//$'\n'/ }"
if ! diff -r "$ARCHIVE" "$w/cloud-images" >"$tmp/diff" 2>&1; then
    fail "the staged tree differs from the committed archive: $(head -3 "$tmp/diff" | tr '\n' ' ')"
fi
note "default stage: offline, verified, byte-identical, no .git"

# ── 4. a tampered archive is refused by name, and nothing is staged ────────
# The negative control, on a COPY so the repo is never modified.
cp -a "$LAB_DIR" "$tmp/lab"
printf '\n# tampered by test-offline-archive.sh\n' >> "$tmp/lab/upstream-repo/cloud-images/variables.pkr.hcl"
w2="$tmp/w2"
if out="$("$tmp/lab/fetch-cloud-images.sh" --workdir "$w2" 2>&1)"; then
    fail "REGRESSION: a TAMPERED archive was accepted — SHA256SUMS is not being checked, so the lab would build from bytes that are no longer the pinned factory"
fi
grep -qi 'does not match SHA256SUMS' <<<"$out" \
    || fail "the tampered archive was refused, but not by naming the checksum mismatch: ${out//$'\n'/ }"
grep -q 'variables.pkr.hcl' <<<"$out" \
    || fail "the refusal did not name WHICH file failed, so it cannot be repaired: ${out//$'\n'/ }"
[[ ! -e "$w2/cloud-images/variables.pkr.hcl" ]] \
    || fail "REGRESSION: the tampered archive was refused but the tree was staged ANYWAY — a gate after the act is a post-mortem"
note "tampered archive: refused by name, naming the file, nothing staged"

# ── 5. and this test left the repo alone ───────────────────────────────────
( cd "$LAB_DIR/upstream-repo" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) \
    || fail "the committed archive no longer verifies — this test modified the repo, which it must not"
note "the committed archive still verifies — this test modified nothing in the repo"

pass "the AlmaLinux factory stages offline from a verified 563-file archive, byte-exact, and refuses a tampered one by name before staging anything"

#!/usr/bin/env bash
# Unit test: make_seed_iso honors per-VM cloud-init overrides (packages/runcmd,
# and a full user-data override), and verify_sha256 catches tampered downloads.
# No root, no network.

# shellcheck disable=SC1090  # $LAB_VM is a dynamic source path
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq sha256sum
# make_seed_iso needs one ISO maker; skip cleanly if none.
if ! command -v genisoimage >/dev/null 2>&1 \
   && ! command -v xorrisofs >/dev/null 2>&1 \
   && ! command -v mkisofs   >/dev/null 2>&1; then
    skip "no ISO maker (genisoimage/xorrisofs/mkisofs)"
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export LAB_STATE_DIR="$tmp/state" LAB_CACHE_DIR="$tmp/cache"
source "$LAB_VM"

seed="$tmp/seed.iso"

# packages[] + runcmd[] appended to the template (grep the raw ISO).
make_seed_iso vm "$seed" "" debian '["git","htop"]' '["touch /tmp/ran"]' "" 2>/dev/null
grep -aq 'packages:'      "$seed" || fail "no packages: block"
grep -aq 'htop'           "$seed" || fail "package 'htop' missing"
grep -aq 'runcmd:'        "$seed" || fail "no runcmd: block"
grep -aq 'touch /tmp/ran' "$seed" || fail "runcmd entry missing"
grep -aq 'plain_text_passwd' "$seed" || fail "base template should still be present"
note "packages[]/runcmd[] appended to the template"

# Full user-data override replaces the template entirely.
ud="$tmp/ud.yaml"; printf '#cloud-config\nfqdn: custom.example\n' > "$ud"
make_seed_iso vm "$seed" "" debian '[]' '[]' "$ud" 2>/dev/null
grep -aq 'fqdn: custom.example' "$seed" || fail "custom user-data not used"
if grep -aq 'plain_text_passwd' "$seed"; then fail "template must be skipped under a full override"; fi
note "custom user-data fully overrides the template"

# verify_sha256: matching hash passes, wrong hash dies, empty hash warns+passes.
f="$tmp/blob"; printf 'lab-create' > "$f"; good="$(sha256sum "$f" | cut -d' ' -f1)"
verify_sha256 "$f" "$good" >/dev/null 2>&1 || fail "correct hash should verify"
( verify_sha256 "$f" "0000bad" ) >/dev/null 2>&1 && fail "wrong hash must die" || note "tampered hash rejected"
verify_sha256 "$f" "" >/dev/null 2>&1 || fail "empty expected hash should warn+skip, not die"
note "verify_sha256 match/mismatch/empty OK"

pass "cloud-init overrides + sha256 verification OK"

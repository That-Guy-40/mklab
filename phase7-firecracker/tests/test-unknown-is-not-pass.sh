#!/usr/bin/env bash
# "UNKNOWN is a verdict, distinct from PASS." A gate that cannot run must say so and must
# NOT be counted as ok -- and must not invent a specific defect either.
#
# Real incident this guards (2026-08-02): the /sbin/init gate grepped debugfs output for
# `Inode:` and read its absence as "the file is missing". On a DIRTY image debugfs never
# opened the filesystem at all, so the tool confidently reported "rootfs has no /sbin/init"
# about an image that had booted minutes earlier.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd debugfs

tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")   # NOT a second EXIT trap — see lib.sh

# A file that is emphatically not an ext4 image: debugfs cannot open it.
printf 'this is not a filesystem\n' > "$tmp/notfs.ext4"
cat > "$tmp/s.toml" <<TOML
[[microvm]]
name = "t1"
kernel = "/nonexistent/vmlinux"
rootfs = "$tmp/notfs.ext4"
TOML

run_fc "$tmp/out" preflight --config "$tmp/s.toml" || true

grep -q '^  UNKNOWN .*sbin/init NOT verified' "$tmp/out" \
    || { cat "$tmp/out" >&2; fail "REGRESSION: an unreadable rootfs did not produce an UNKNOWN for the /sbin/init gate"; }
note "unreadable image -> UNKNOWN, naming what was not verified"

grep -q 'rootfs has no /sbin/init' "$tmp/out" \
    && fail "REGRESSION: the tool invented a specific defect ('no /sbin/init') for an image it could not even open"
note "and it did NOT claim the file was missing"

grep -q '^  ok .*/sbin/init' "$tmp/out" \
    && fail "REGRESSION: an unverifiable gate was rendered as a pass"
note "and it was not silently downgraded to ok"

# The summary must carry the UNKNOWN count, so it cannot vanish between the gate and the verdict.
grep -qE 'UNKNOWN' "$tmp/out" || fail "the UNKNOWN never reached the summary line"

pass "an unrunnable gate reports UNKNOWN — not ok, and not an invented specific failure"

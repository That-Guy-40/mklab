#!/usr/bin/env bash
# REGRESSION GUARD. `create` makes a per-instance copy of the rootfs (§5.3). The config the
# VM actually boots must name THAT COPY — not the source image.
#
# The bug this guards (found 2026-08-02 reviewing slice 4): create generated config.json
# from the source record and copied the rootfs afterwards, so the manifest named
# $d/rootfs.ext4 while config.json still pointed at the original. The copy was dead weight,
# the manifest described a file the VM never touched, and two instances created from one
# source image would both have booted it read-write and corrupted each other.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd firecracker file sha256sum
[[ -r /dev/kvm && -w /dev/kvm ]] || skip "/dev/kvm not read-write for uid $EUID"
K="${FC_TEST_KERNEL:-}"; R="${FC_TEST_ROOTFS:-}"
[[ -r "$K" && -r "$R" ]] || skip "set FC_TEST_KERNEL and FC_TEST_ROOTFS"

tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")
export LAB_STATE_DIR="$tmp/state"       # never touch the caller's real instances
n="rgt$$"

# If create refuses, say WHY — lab-fc.sh has its own in-code assertion for this same
# defect, and a test that reports "create refused" while the tool is shouting
# "config.json points at the wrong file" hides the diagnosis behind a vaguer alarm.
if ! run_fc "$tmp/out" create --name "$n" --kernel "$K" --rootfs "$R" --memory 128M; then
    cat "$tmp/out" >&2
    if grep -q 'REGRESSION: config.json points at' "$tmp/out"; then
        fail "$(grep -m1 'REGRESSION: config.json points at' "$tmp/out" | sed 's/^lab-fc\.sh: //')"
    fi
    fail "create refused a spec built from the caller's own good artifacts: $(tail -1 "$tmp/out")"
fi

d="$tmp/state/fc/$n"
copy="$d/rootfs.ext4"
[[ -r "$copy" ]] || fail "no per-instance rootfs copy at $copy"

cfg_path="$(grep -o '"path_on_host": "[^"]*"' "$d/config.json" | head -1 | cut -d'"' -f4)"
[[ "$cfg_path" == "$copy" ]] \
    || fail "REGRESSION: config.json boots '$cfg_path', not the per-instance copy '$copy' — two instances would share one image"
note "config.json points at the per-instance copy"

man_path="$(sed -n 's/^rootfs = "\(.*\)"$/\1/p' "$d/manifest.toml")"
[[ "$man_path" == "$cfg_path" ]] \
    || fail "REGRESSION: manifest says '$man_path' but the VM boots '$cfg_path' — the record misdescribes its subject"
note "manifest and config name the same file"

# The copy must be a real copy of the source, and the source sha must be recorded so a
# later swap of the source image is detectable rather than silent.
[[ "$(sha256sum "$copy" | cut -d' ' -f1)" == "$(sha256sum "$R" | cut -d' ' -f1)" ]] \
    || fail "the per-instance copy does not match the source image"
grep -q '^rootfs_source_sha256 = "[0-9a-f]\{64\}"$' "$d/manifest.toml" \
    || fail "manifest records no source sha256 — a re-staged source image would be undetectable"
note "copy matches source, and the source sha is recorded"

# create must not silently overwrite an existing instance.
run_fc "$tmp/out2" create --name "$n" --kernel "$K" --rootfs "$R" --memory 128M \
    && fail "REGRESSION: create overwrote an existing instance instead of refusing"
note "create refuses to overwrite an existing instance"

pass "the rootfs the VM boots is the per-instance copy, and the manifest agrees with it"

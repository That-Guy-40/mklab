#!/usr/bin/env bash
# Unit test: the `snapshot` subcommand drives qemu-img snapshots on a VM's qcow2
# disk (create/list/restore/delete) and guards correctly.  No root; exercises a
# real qcow2 via a hand-built manifest.

# $LAB_VM is a dynamic source path; the fake-manifest fields read back via the
# sourced helpers look "unused" to shellcheck — both false positives here.
# shellcheck disable=SC1090,SC2034
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd qemu-img jq

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export LAB_STATE_DIR="$tmp/state" LAB_CACHE_DIR="$tmp/cache"
source "$LAB_VM"

# A fake VM: manifest (note the `key = "value"` spacing the parser needs) + qcow2.
d="$(vm_dir snaptest)"; mkdir -p "$d"
qemu-img create -f qcow2 "$d/disk.qcow2" 64M >/dev/null
printf 'name = "snaptest"\nbackend = "disk-image"\ndisk = "%s/disk.qcow2"\n' "$d" > "$(vm_manifest snaptest)"

snap() { POS_ARGS=("$@"); cmd_snapshot; }

snap create snaptest s1 >/dev/null 2>&1 || fail "create s1"
snap create snaptest s2 >/dev/null 2>&1 || fail "create s2"
tags="$(qemu-img snapshot -l "$d/disk.qcow2" | awk 'NR>2{print $2}' | sort | tr '\n' ' ')"
[[ "$tags" == "s1 s2 " ]] || fail "list after 2 creates: got '$tags'"
note "create + list → s1 s2"

snap restore snaptest s1 >/dev/null 2>&1 || fail "restore s1"
snap delete  snaptest s1 >/dev/null 2>&1 || fail "delete s1"
tags="$(qemu-img snapshot -l "$d/disk.qcow2" | awk 'NR>2{print $2}' | tr '\n' ' ')"
[[ "$tags" == "s2 " ]] || fail "after delete s1, expected only s2: got '$tags'"
note "restore + delete OK (only s2 remains)"

# Guards (run in a subshell so the expected die doesn't abort the test).
( snap create snaptest ) >/dev/null 2>&1 && fail "missing snap-name should error" || note "missing snap-name rejected"

# kernel+initrd VM (no disk) → snapshot refused
dk="$(vm_dir ki)"; mkdir -p "$dk"
printf 'name = "ki"\nbackend = "kernel+initrd"\ndisk = ""\n' > "$(vm_manifest ki)"
( snap list ki ) >/dev/null 2>&1 && fail "no-disk VM should be refused" || note "no-disk VM rejected"

# running VM → create refused (simulate by writing a live pidfile)
echo $$ > "$(vm_pidfile snaptest)"   # $$ is alive → vm_running true
( snap create snaptest s3 ) >/dev/null 2>&1 && fail "running VM snapshot should be refused" || note "running VM rejected"
rm -f "$(vm_pidfile snaptest)"

pass "snapshot create/list/restore/delete + guards OK"

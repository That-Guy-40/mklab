#!/usr/bin/env bash
# Test the `inspect [--json]` verb against a hand-built fake VM state tree.
#
# Phase 2's `cmd_inspect` requires `vm_exists "$name"` — a manifest at
# $LAB_VM_STATE_DIR/<name>/manifest.toml.  Unlike Phase 1's path-mode
# bypass, there is no way to inspect an arbitrary directory.  So we pin
# the script's state dir to a tmpdir, fabricate the manifest + a few
# satellite files, and assert against the resulting output.
#
# Works under root or non-root: lab-vm.sh now honors $LAB_STATE_DIR
# (matching Phases 4/5).  No real qemu, no network.  We use $$ (the
# test's own PID) in qemu.pid so vm_running's `[[ -d /proc/$pid ]]`
# check succeeds without any actual qemu process.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq

WORK="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$WORK'" EXIT

# Pin the script's state dir directly via LAB_STATE_DIR — matches the
# pattern used by the Phase 4/5 test suites.
export LAB_STATE_DIR="$WORK/lab-create"
VM_STATE_DIR="$LAB_STATE_DIR/vms"
VM_NAME="myvm"
VM_DIR="$VM_STATE_DIR/$VM_NAME"
mkdir -p "$VM_DIR"

# --- fabricate a manifest ------------------------------------------------
# Field set mirrors write_vm_manifest() and what cmd_inspect reads via
# read_manifest_field.  We deliberately keep `kernel`/`initrd` empty so
# `.files.kernel`/`.files.initrd` collapse to null in the JSON (testing
# the `if $f_kernel_path == "" then null` branch).
KERNEL_PATH="$WORK/fake-vmlinuz"
# We will exercise both the "kernel exists" and "disk missing" paths:
# disk.qcow2 is intentionally NOT created — tests files.disk.exists=false.
# kernel file IS created with non-zero content — tests size_bytes>0.
printf 'fake kernel bytes\n' > "$KERNEL_PATH"

# host arch — used to pick an arch that matches (so foreign_arch.kvm_available
# is a real boolean, not null) — we use the actual host arch.
HOST_ARCH="$(uname -m)"
# Normalize a couple of common variants the script's detect_host_arch handles.
case "$HOST_ARCH" in
    amd64) HOST_ARCH=x86_64 ;;
    arm64) HOST_ARCH=aarch64 ;;
esac

cat > "$VM_DIR/manifest.toml" <<EOF
# lab-vm manifest — synthesized by test-inspect-json.sh
name        = "${VM_NAME}"
lab         = "test-lab"
backend     = "cloud-image"
distro      = "debian"
suite       = "bookworm"
arch        = "${HOST_ARCH}"
memory      = "1G"
cpus        = 2
microvm     = false
accel       = "kvm"
ssh_port    = 2222
disk        = "${VM_DIR}/disk.qcow2"
seed        = "${VM_DIR}/seed.iso"
kernel      = "${KERNEL_PATH}"
initrd      = ""
append      = ""
ssh_user    = "lab"
created_at  = "2026-04-22T00:00:00Z"
version     = "0.1.0"
EOF

# --- drop a qemu.pid pointing at THIS shell so vm_running ⇒ true ---------
# vm_running reads the pid file then checks `[[ -d /proc/$pid ]]`.  Using $$
# (the test's PID) guarantees /proc/$$ exists for the duration of the test.
printf '%s\n' "$$" > "$VM_DIR/qemu.pid"

# --- a small qemu.log so files.log.size_bytes > 0 ------------------------
printf 'fake log line\n' > "$VM_DIR/qemu.log"

# === RUNNING VARIANT =====================================================
note "running inspect (human form, vm 'running')"
out="$("$LAB_VM" inspect "$VM_NAME" 2>&1)"

case "$out" in
    *"[manifest]"*"[live]"*) ;;
    *) fail "human form missing [manifest] / [live] sections; got:\n$out" ;;
esac
case "$out" in
    *"name        ${VM_NAME}"*) ;;
    *) fail "human form: synthesized name not surfaced" ;;
esac
case "$out" in
    *"process.running     true"*) ;;
    *) fail "human form: process.running not 'true'; got:\n$out" ;;
esac
case "$out" in
    *"files.disk          ${VM_DIR}/disk.qcow2 (exists=false"*) ;;
    *) fail "human form: files.disk path / exists=false not surfaced; got:\n$out" ;;
esac
case "$out" in
    *"files.kernel        ${KERNEL_PATH} (exists=true"*) ;;
    *) fail "human form: files.kernel path / exists=true not surfaced; got:\n$out" ;;
esac

note "running inspect --json (vm 'running')"
json="$("$LAB_VM" inspect "$VM_NAME" --json)"
echo "$json" | jq -e '.schema_version == 1' >/dev/null \
    || fail "json: schema_version != 1"

note "schema spot-checks (manifest)"
[[ "$(jq -r '.name' <<<"$json")" == "$VM_NAME" ]] \
    || fail "json: .name != $VM_NAME"
[[ "$(jq -r '.manifest.distro' <<<"$json")" == "debian" ]] \
    || fail "json: .manifest.distro != debian"
[[ "$(jq -r '.manifest.suite' <<<"$json")" == "bookworm" ]] \
    || fail "json: .manifest.suite != bookworm"
[[ "$(jq -r '.manifest.cpus' <<<"$json")" == "2" ]] \
    || fail "json: .manifest.cpus != 2 (raw)"
[[ "$(jq -r '.manifest.cpus | type' <<<"$json")" == "number" ]] \
    || fail "json: .manifest.cpus is not a number"
[[ "$(jq -r '.manifest.ssh_port | type' <<<"$json")" == "number" ]] \
    || fail "json: .manifest.ssh_port is not a number"
[[ "$(jq -r '.manifest.microvm | type' <<<"$json")" == "boolean" ]] \
    || fail "json: .manifest.microvm is not a boolean"
[[ "$(jq -r '.manifest.initrd' <<<"$json")" == "null" ]] \
    || fail "json: .manifest.initrd should be null when empty in toml"

note "schema spot-checks (process — running)"
[[ "$(jq -r '.process.running' <<<"$json")" == "true" ]] \
    || fail "json: .process.running != true"
[[ "$(jq -r '.process.pid' <<<"$json")" == "$$" ]] \
    || fail "json: .process.pid != \$\$ ($$)"
[[ "$(jq -r '.process.pid | type' <<<"$json")" == "number" ]] \
    || fail "json: .process.pid is not a number when running"

note "schema spot-checks (files)"
[[ "$(jq -r '.files.disk.exists' <<<"$json")" == "false" ]] \
    || fail "json: .files.disk.exists should be false (no disk.qcow2 was created)"
[[ "$(jq -r '.files.disk.size_bytes' <<<"$json")" == "0" ]] \
    || fail "json: .files.disk.size_bytes should be 0 when missing"
[[ "$(jq -r '.files.kernel.exists' <<<"$json")" == "true" ]] \
    || fail "json: .files.kernel.exists should be true (we created it)"
[[ "$(jq -r '.files.kernel.size_bytes | type' <<<"$json")" == "number" ]] \
    || fail "json: .files.kernel.size_bytes is not a number"
ksz="$(jq -r '.files.kernel.size_bytes' <<<"$json")"
(( ksz > 0 )) || fail "json: .files.kernel.size_bytes ($ksz) should be > 0"
# .files.initrd should be null because manifest.initrd was empty.
[[ "$(jq -r '.files.initrd' <<<"$json")" == "null" ]] \
    || fail "json: .files.initrd should be null when manifest.initrd is empty"
[[ "$(jq -r '.files.log.exists' <<<"$json")" == "true" ]] \
    || fail "json: .files.log.exists should be true"

note "schema spot-checks (sockets — none real)"
[[ "$(jq -r '.sockets.serial.exists' <<<"$json")" == "false" ]] \
    || fail "json: .sockets.serial.exists should be false (no socket created)"
[[ "$(jq -r '.sockets.monitor.exists' <<<"$json")" == "false" ]] \
    || fail "json: .sockets.monitor.exists should be false"
[[ "$(jq -r '.sockets.qmp.exists' <<<"$json")" == "false" ]] \
    || fail "json: .sockets.qmp.exists should be false"

note "schema spot-checks (foreign_arch — host-matched)"
# Same-arch path: kvm_available is a boolean iff /dev/kvm is readable; the
# script always writes a boolean here, never null.
fa_kvm="$(jq -r '.foreign_arch.kvm_available' <<<"$json")"
case "$fa_kvm" in
    true|false) ;;
    *) fail "json: .foreign_arch.kvm_available should be true|false (host-arch match), got: $fa_kvm" ;;
esac
[[ "$(jq -r '.foreign_arch.kvm_available | type' <<<"$json")" == "boolean" ]] \
    || fail "json: .foreign_arch.kvm_available type is not boolean"

# === STOPPED VARIANT =====================================================
# Same VM, but no qemu.pid → vm_running returns false.
note "stopped variant (no qemu.pid)"
rm -f "$VM_DIR/qemu.pid"
json2="$("$LAB_VM" inspect "$VM_NAME" --json)"
[[ "$(jq -r '.process.running' <<<"$json2")" == "false" ]] \
    || fail "stopped: .process.running should be false"
[[ "$(jq -r '.process.pid' <<<"$json2")" == "null" ]] \
    || fail "stopped: .process.pid should be null"
[[ "$(jq -r '.process.rss_bytes' <<<"$json2")" == "null" ]] \
    || fail "stopped: .process.rss_bytes should be null"
[[ "$(jq -r '.process.threads' <<<"$json2")" == "null" ]] \
    || fail "stopped: .process.threads should be null"

# Also confirm the human form drops the running-only fields.
out2="$("$LAB_VM" inspect "$VM_NAME" 2>&1)"
case "$out2" in
    *"process.running     false"*) ;;
    *) fail "stopped human form: process.running != false" ;;
esac
if grep -q "process.pid" <<<"$out2"; then
    fail "stopped human form: process.pid line should be omitted, got:\n$out2"
fi

# === FAILURE PATHS =======================================================
note "usage error: inspect with no arg"
if "$LAB_VM" inspect 2>/dev/null; then
    fail "inspect with no arg should fail"
fi

note "failure path: inspect nonexistent VM"
if "$LAB_VM" inspect doesnotexist 2>/dev/null; then
    fail "inspect of unknown vm should fail"
fi
# And the error message should be useful.
err="$("$LAB_VM" inspect doesnotexist 2>&1 || true)"
case "$err" in
    *"no VM named"*) ;;
    *) fail "inspect of unknown vm: error message should mention 'no VM named'; got: $err" ;;
esac

pass "inspect [--json] OK"

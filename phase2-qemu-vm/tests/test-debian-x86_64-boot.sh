#!/usr/bin/env bash
# End-to-end: create, start, ssh, stop, destroy a Debian bookworm VM.
# This downloads ~350 MB on first run (cached thereafter) and takes
# 2–4 minutes of real time depending on host speed.
#
# Generates its own throwaway SSH keypair so it doesn't depend on the
# invoking user having one configured.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq qemu-system-x86_64 qemu-img socat curl ssh-keygen

if [[ ! -e /dev/kvm ]] || [[ ! -r /dev/kvm ]] || [[ ! -w /dev/kvm ]]; then
    skip "/dev/kvm not r+w by uid=$(id -u); test would take too long under TCG"
fi

# Need at least one ISO maker.
command -v genisoimage >/dev/null 2>&1 \
    || command -v xorrisofs >/dev/null 2>&1 \
    || command -v mkisofs  >/dev/null 2>&1 \
    || skip "no ISO maker (need genisoimage or xorriso or mkisofs)"

name="t-debx64-$$"
keydir="$(mktemp -d)"
key="$keydir/id_ed25519"

cleanup() {
    cleanup_vm "$name"
    rm -rf "$keydir"
}
trap cleanup EXIT

note "generating throwaway ed25519 keypair → $key"
ssh-keygen -t ed25519 -N '' -C "lab-vm-test-$$" -f "$key" >/dev/null

note "create VM '$name'"
"$LAB_VM" create --name "$name" --distro debian --suite bookworm --arch x86_64 \
    --memory 1G --cpus 1 --pubkey "${key}.pub"

note "start"
"$LAB_VM" start "$name"

# Pull port from manifest directly (more reliable than scraping `list`).
manifest="${LAB_STATE_DIR:-${HOME}/.local/state/lab-create}/vms/${name}/manifest.toml"
[[ -r "$manifest" ]] || manifest="/var/lib/lab-create/vms/${name}/manifest.toml"
port="$(awk '$1=="ssh_port" {print $3}' "$manifest")"
[[ -n "$port" ]] || fail "could not read ssh_port from manifest"
note "ssh port: $port"

note "waiting up to 240s for ssh on port $port (cloud-init takes time on first boot)"
elapsed=0
while (( elapsed < 240 )); do
    if ssh -i "$key" -p "$port" \
           -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=2 -o BatchMode=yes \
           lab@127.0.0.1 true 2>/dev/null; then
        note "ssh up after ${elapsed}s"
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done

if (( elapsed >= 240 )); then
    note "ssh did not come up; tail of qemu.log:"
    tail -20 "$(dirname "$manifest")/qemu.log" 2>/dev/null || true
    fail "ssh never reachable"
fi

note "exec uname -m inside guest"
got="$(ssh -i "$key" -p "$port" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes \
        lab@127.0.0.1 -- uname -m)"
[[ "$got" == "x86_64" ]] || fail "guest reported uname=$got, expected x86_64"

note "graceful stop"
"$LAB_VM" stop "$name"

note "destroy"
"$LAB_VM" destroy "$name" --force

pass "Debian x86_64 cloud VM round-trip OK"

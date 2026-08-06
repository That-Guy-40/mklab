#!/usr/bin/env bash
# `--mac` must reach the spec, the manifest AND the argv — not just one of the three.
#
# WHY THIS EXISTS. `mac` was a supported field everywhere EXCEPT the one place a user could
# reach it. The spec reader had `mac: (.mac // "")`, `build_qemu_argv` appended `,mac=...`
# and validated the format — but the CLI's jq spec builder never emitted the key, and there
# was no `--mac` flag at all. So a TOML config could set it and a command line could not,
# and nothing said so.
#
# That gap is worse than it sounds, because a wrong MAC does not fail loudly. A DHCP
# RESERVATION is keyed on the MAC: hand the guest a different one and it does not error, it
# quietly takes a dynamic lease while the server keeps answering the guest's NAME with the
# reserved address nothing holds. Found 2026-08-05 while deriving what slice 5b's `edge`
# spec needed (plan Appendix L) — the same seam that had let `fabric.sh` and `lab-fc.sh`
# disagree about `api1`'s MAC for three slices.
#
# So this asserts the whole path, because the field being present at either END proves
# nothing about the middle: CLI flag -> spec JSON -> manifest.toml -> QEMU argv.

# render() sets globals consumed by the sourced build_qemu_argv (dynamic scope),
# and $LAB_VM is a dynamic source path — both are false positives here.
# shellcheck disable=SC1090,SC2034
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd qemu-system-x86_64 jq

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export LAB_STATE_DIR="$tmp/state" LAB_CACHE_DIR="$tmp/cache"

MAC="06:00:ac:47:09:03"

# ── 1. the argv end: build_qemu_argv attaches it to the NIC, not somewhere else ──
source "$LAB_VM"
render() {
    name=t arch=x86_64 microvm=false accel=tcg memory=512M cpus=1 \
        cores=0 threads=0 cpu_pin="" disk="" install_target="" seed="" \
        mac="$1" kernel=/k initrd=/i append="" ssh_port=2222 firmware="" \
        network_mode=tap bridge="" tap=mc-edge
    build_qemu_argv
    printf '%s' "${QEMU_ARGV[*]}"
}
a="$(render "$MAC")"
grep -Fq -- "virtio-net-pci,netdev=net0,mac=$MAC" <<<"$a" \
    || fail "a mac= must land on the NIC device: expected 'virtio-net-pci,netdev=net0,mac=$MAC' in the argv"
# The negative direction: no mac given must not invent one, or every VM shares an address.
b="$(render "")"
grep -Fq -- 'virtio-net-pci,netdev=net0' <<<"$b" || fail "the NIC device vanished when mac was empty"
if grep -Fq -- 'mac=' <<<"$b"; then fail "an empty mac must emit NO mac= at all (QEMU picks one); got a mac= in the argv"; fi
note "argv: mac= attaches to the NIC, and an empty mac emits none"

# ── 2. the format gate refuses garbage BEFORE a VM exists ───────────────────
# `die` is an exit, so run it in a subshell or it takes this test with it (house rule).
if ( render "not-a-mac" >/dev/null 2>&1 ); then
    fail "build_qemu_argv accepted 'not-a-mac' — an invalid MAC must be refused, not passed to QEMU"
fi
note "refusal: a malformed MAC is rejected before the VM is built"

# ── 3. the CLI end — the half that was actually missing ─────────────────────
# THE REGRESSION: --mac existed nowhere, and `mac` was absent from the CLI spec builder's
# jq object, so this path silently produced a VM with QEMU's default MAC.
out="$("$LAB_VM" create --name mactest --backend kernel+initrd \
        --kernel /dev/null --initrd /dev/null \
        --network-mode tap --tap mc-edge --mac "$MAC" 2>&1)" || {
    printf '%s\n' "$out" >&2
    fail "REGRESSION: 'create --mac' failed — the flag must exist and be accepted on the command line"
}
mf="$LAB_STATE_DIR/vms/mactest/manifest.toml"
[[ -r "$mf" ]] || fail "no manifest written at $mf"
grep -Eq "^mac[[:space:]]*=[[:space:]]*\"$MAC\"" "$mf" \
    || fail "REGRESSION: --mac did not reach the manifest. Got: $(grep -E '^mac' "$mf" 2>/dev/null || echo '<no mac line>') — a field readable by --config but not by the CLI is a gap nothing reports"
note "cli: --mac -> spec -> manifest.toml ($MAC)"

# ── 4. and the CLI's refusal is the tool's, not QEMU's, and not silence ─────
if ( "$LAB_VM" create --name macbad --backend kernel+initrd --kernel /dev/null \
        --initrd /dev/null --network-mode tap --tap mc-edge --mac "zz:zz" >/dev/null 2>&1 ); then
    fail "create accepted --mac zz:zz — a malformed MAC must be refused"
fi
note "cli: a malformed --mac is refused"

pass "--mac reaches the NIC argv, the manifest and the format gate — and an absent mac still emits none"

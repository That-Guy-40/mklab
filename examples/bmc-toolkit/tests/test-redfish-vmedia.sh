#!/usr/bin/env bash
# Verdict: Redfish VIRTUAL MEDIA is a real deploy path — `bmc.sh node3 insert-media`
# attaches an ISO and the node BOOTS it, with NO PXE/DHCP/TFTP. Fully headless & rootless
# (sushy-tools over qemu:///session). This is the lab's centerpiece (plan §4 / POC-B).
. "$(dirname "$0")/lib.sh"
need python3 curl virsh qemu-system-x86_64 genisoimage
[[ -r /dev/kvm && -w /dev/kvm ]] || skip "no writable /dev/kvm (KVM needed for the node)"
[[ -r "${HOME}/netboot/vmlinuz" ]] || skip "no kernel at ~/netboot/vmlinuz for the proof ISO"

export URI="qemu:///session"
DOM="bmc-vmedia-node"                       # must match fleet-bmc.toml node3.domain
STATE="$LAB_DIR/state/node3"; mkdir -p "$STATE"
SERIAL="$STATE/node-serial.log"; : > "$SERIAL"
ISO="$STATE/proof.iso"
MARKER="BMC_TOOLKIT_VMEDIA_TEST_$$"

cleanup() {
  "$BMC" node3 bmc-down >/dev/null 2>&1 || true
  node_destroy "$DOM"
  V pool-destroy default >/dev/null 2>&1 || true
  V pool-undefine default >/dev/null 2>&1 || true
}
on_exit 'cleanup'

note "build a bootable proof ISO (marker in kernel cmdline)"
"$LAB_DIR/make-proof-iso.sh" --marker "$MARKER" --out "$ISO" >/dev/null || fail "could not build proof ISO"

note "define the blank session node (BIOS, serial->file, sushy adds the cdrom)"
node_destroy "$DOM"
"$LAB_DIR/nodes/make-session-node.sh" --name "$DOM" --serial "file:$SERIAL" --out "$STATE/node.xml"
V define "$STATE/node.xml" >/dev/null || fail "virsh define failed"

note "bmc.sh node3 bmc-up (bootstraps sushy venv on first run — may take a minute)"
"$BMC" node3 bmc-up || fail "bmc-up (sushy-emulator) failed"

note "InsertMedia + boot=cdrom + power on, all via the Redfish backend"
"$BMC" node3 insert-media "$ISO" || fail "insert-media failed"
# control-plane proof: the domain XML now has the virtual CD
V dumpxml "$DOM" | grep -q "device='cdrom'" || fail "REGRESSION: InsertMedia did not attach a cdrom to the domain"
"$BMC" node3 bootdev cdrom || fail "bootdev cdrom failed"
"$BMC" node3 power on || fail "power on failed"

note "wait for the node to boot the virtual media (marker on serial)"
ok=""
for _ in $(seq 1 40); do grep -q "$MARKER" "$SERIAL" && { ok=1; break; }; sleep 1; done
[[ -n "$ok" ]] || { note "serial tail:"; tail -5 "$SERIAL" >&2; fail "node did not boot the virtual media (marker '$MARKER' absent)"; }

note "eject-media cleans up"
"$BMC" node3 eject-media >/dev/null || note "eject-media returned nonzero (non-fatal)"

pass "Redfish InsertMedia attached the ISO and the node BOOTED it over virtual media — no PXE/DHCP/TFTP"

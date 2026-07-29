#!/usr/bin/env bash
# Verdict: lib/tpm_xml.py turns a domain into one that can MEASURE and still NETBOOT —
# UEFI firmware, a TPM 2.0, and a NIC the UEFI firmware can actually drive.
#
# THE DEFECT THIS EXISTS TO PREVENT, found live on 2026-07-29. tpm_xml.py did the two
# obvious things (loader/nvram, <tpm>) and node3 booted straight to the EFI internal
# shell: "map: No mapping found", no PXE attempt at all, despite the NIC carrying
# bootindex=1. Nothing errored. The measured run simply waited for a quote from a
# machine sitting at a firmware prompt.
#
# The cause was a collision with the verifying option ROM. OVMF's NetworkPkg provides
# the PXE protocol stack, but the Simple Network Protocol driver for an e1000 has to
# come from the card's UEFI option ROM (QEMU's efi-e1000.rom, an iPXE image carrying
# both a legacy and an EFI driver). This lab attaches its own LEGACY-only verifying
# ROM over the top — so a UEFI firmware finds no driver, builds no network boot
# option, and falls through to the shell.
#
# The fix, asserted in §3: a measured node gets **virtio-net with no option ROM**,
# because OVMF has VirtioNetDxe built in and drives the card itself. That also lines
# up with the fleet's arch-conditional DHCP: OVMF's own PXE client does not announce
# user-class iPXE, so it is handed the verifying `ipxe.efi` rather than the script,
# and the firmware half of F2 runs on this node exactly as the option ROM provides it
# on the BIOS ones.
#
# This file had no counterpart before the incident — tpm_xml.py shipped untested,
# which is the honest reason the defect reached a live run.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need python3

TOOL="$LAB_DIR/lib/tpm_xml.py"
OVMF=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    [[ -f "$c" ]] && { OVMF="$c"; break; }
done
[[ -n "$OVMF" ]] || skip "OVMF is not installed — tpm_xml.py refuses without it, by design"

SANDBOX="$(mktemp -d)"
# shellcheck disable=SC2154
trap '_rc=$?; rm -rf "$SANDBOX"; [[ $_rc == 0 || $_rc == 77 ]] || printf "FAIL: test exited early (rc=%s)\n" "$_rc" >&2' EXIT

# A BIOS domain shaped like this fleet's: e1000 NIC carrying the verifying legacy ROM,
# which is what create-fleet.sh produces before give_tpm runs.
cat > "$SANDBOX/bios.xml" <<'XML'
<domain type='kvm'>
  <name>node9</name>
  <memory unit='KiB'>1048576</memory>
  <os><type arch='x86_64' machine='pc'>hvm</type><boot dev='network'/></os>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <interface type='network'>
      <mac address='52:54:00:aa:bb:cc'/>
      <source network='vbmc-pxe'/>
      <model type='e1000'/>
      <rom file='/var/lib/libvirt/maas-rom/ipxe-8086100e.rom'/>
    </interface>
  </devices>
</domain>
XML

python3 "$TOOL" < "$SANDBOX/bios.xml" > "$SANDBOX/out.xml" 2>"$SANDBOX/err" \
    || fail "tpm_xml.py refused a well-formed BIOS domain: $(tr '\n' ' ' < "$SANDBOX/err")"

q() { python3 - "$SANDBOX/out.xml" "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
els = root.findall(sys.argv[2])
for e in els:
    print(e.get("file") or e.get("type") or e.get("enabled") or e.get("template") or (e.text or "").strip())
PY
}

# ── 1. UEFI firmware ────────────────────────────────────────────────────────
[[ "$(q os/loader | wc -l)" == 1 ]] || fail "expected exactly one <loader>, got $(q os/loader | wc -l)"
[[ "$(q os/nvram  | wc -l)" == 1 ]] || fail "expected exactly one <nvram>, got $(q os/nvram | wc -l)"
grep -q "readonly='yes'\|readonly=\"yes\"" "$SANDBOX/out.xml" || fail "the <loader> is not readonly — libvirt rejects a pflash loader without it"
note "UEFI: one readonly pflash <loader> + one per-domain <nvram>  ✓"

# ── 2. a TPM 2.0 ────────────────────────────────────────────────────────────
[[ "$(q devices/tpm | wc -l)" == 1 ]] || fail "expected exactly one <tpm>, got $(q devices/tpm | wc -l)"
grep -q "version='2.0'\|version=\"2.0\"" "$SANDBOX/out.xml" || fail "the TPM is not version 2.0 — the PCR layout this lab reads assumes TPM 2.0"
note "TPM 2.0 (tpm-tis, emulator backend)  ✓"

# ── 3. THE REGRESSION: a NIC the UEFI firmware can actually drive ───────────
model="$(q devices/interface/model)"
[[ "$model" == "virtio" ]] \
    || fail "REGRESSION: the NIC model is '$model', not virtio. OVMF has no built-in driver for it, so the Simple Network Protocol would have to come from the card's UEFI option ROM — and §3's whole point is that this lab replaces that ROM with a legacy-only one. The domain boots to the EFI shell with no PXE attempt and no error"
[[ "$(q devices/interface/rom)" == "no" ]] \
    || fail "REGRESSION: the NIC's <rom> is not disabled (got '$(q devices/interface/rom)'). QEMU's stock iPXE oprom announces user-class iPXE, so the fleet's arch-conditional DHCP hands it the SCRIPT rather than the verifying ipxe.efi — and stock iPXE has no imgverify to run it with"
grep -q 'maas-rom' "$SANDBOX/out.xml" \
    && fail "REGRESSION: the legacy verifying option ROM survived. On a UEFI domain it DISPLACES the only UEFI NIC driver OVMF would have had — this is the exact defect that sent node3 to the EFI shell on 2026-07-29"
grep -q '52:54:00:aa:bb:cc' "$SANDBOX/out.xml" \
    || fail "the NIC's MAC was lost — the DHCP reservation and every per-node boot script are keyed to it"
note "NIC: virtio, option ROM disabled, legacy ROM removed, MAC preserved  ✓"

# ── 4. libvirt itself must accept the result ───────────────────────────────
# The strongest available check that this is a definable domain rather than XML that
# merely looks right: the failure being guarded is "libvirt accepted it and the
# machine did nothing", so schema validity is the floor, not the ceiling.
if command -v virt-xml-validate >/dev/null; then
    virt-xml-validate "$SANDBOX/out.xml" domain >/dev/null 2>&1 \
        || fail "virt-xml-validate rejects the rewritten domain — libvirt would refuse to define it"
    note "virt-xml-validate accepts the rewritten domain  ✓"
fi

# ── 5. idempotent: re-running replaces, never appends ──────────────────────
# rom_xml.py learned this the hard way; a second <tpm> or <loader> is an error
# libvirt reports unhelpfully, and a second <rom> is silently ambiguous.
python3 "$TOOL" < "$SANDBOX/out.xml" > "$SANDBOX/twice.xml" 2>/dev/null \
    || fail "re-running tpm_xml.py on its own output failed — it is not idempotent"
for tag in '<loader' '<nvram' '<tpm ' '<rom '; do
    n="$(grep -o "$tag" "$SANDBOX/twice.xml" | wc -l)"
    [[ "$n" == 1 ]] || fail "REGRESSION: re-running produced $n copies of '$tag', not 1"
done
note "idempotent: one loader, one nvram, one tpm, one rom after a second pass  ✓"

# ── 6. it refuses rather than half-applying ────────────────────────────────
# A measured node with no NIC cannot fetch the payload it is supposed to measure, so
# emitting a "working" domain would just move the failure to boot time.
python3 - "$SANDBOX/bios.xml" > "$SANDBOX/nonic.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
d = root.find("devices")
for i in d.findall("interface"):
    d.remove(i)
sys.stdout.write(ET.tostring(root, encoding="unicode"))
PY
if ( python3 "$TOOL" < "$SANDBOX/nonic.xml" >/dev/null 2>&1 ); then
    fail "a domain with no <interface> was accepted — a measured node has to netboot the payload it measures, so this must refuse rather than defer the failure to boot time"
fi
if ( printf 'not xml at all' | python3 "$TOOL" >/dev/null 2>&1 ); then
    fail "invalid input was accepted"
fi
note "refuses a domain with no NIC, and refuses non-XML  ✓"

pass "tpm_xml.py gives a domain UEFI firmware, a TPM 2.0, and a virtio NIC with no option ROM — so OVMF can drive the card, fetch the verifying ipxe.efi, and measure what it boots — replacing rather than appending on a re-run and refusing a domain it cannot honestly convert"

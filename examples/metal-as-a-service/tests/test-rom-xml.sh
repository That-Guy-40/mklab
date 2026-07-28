#!/usr/bin/env bash
# test-rom-xml.sh — lib/rom_xml.py rewrites a domain definition, so it gets a test.
#
# The failure mode being guarded is not "the ROM does not verify" (test-verifying-rom.sh
# owns that) but "the domain no longer defines": a second <rom> in one <interface>, a
# path qemu cannot read, or XML that silently loses a device. Those show up as a fleet
# that will not start, which is a much worse outcome than one that boots unverified.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

need python3
ROM_XML="$LAB_DIR/lib/rom_xml.py"
[[ -f "$ROM_XML" ]] || fail "lib/rom_xml.py is missing — create-fleet.sh's give_verifying_rom calls it"

WORK="$(mktemp -d)"
trap '_rc=$?; rm -rf "$WORK"; if [[ $_rc -ne 0 && $_rc -ne 77 ]]; then printf "FAIL: test exited early (rc=%s)\n" "$_rc" >&2; fi' EXIT

ROM="$WORK/ipxe-8086100e.rom"
printf 'not-really-a-rom\n' > "$ROM"

# A domain with TWO interfaces: a node on the PXE network and one elsewhere. Both must
# get the ROM — a node that verifies on one NIC and not the other verifies nothing.
cat > "$WORK/dom.xml" <<XML
<domain type='kvm'>
  <name>node1</name>
  <devices>
    <interface type='network'>
      <mac address='52:54:00:aa:bb:01'/>
      <source network='vbmc-pxe'/>
      <model type='e1000'/>
    </interface>
    <interface type='network'>
      <mac address='52:54:00:aa:bb:02'/>
      <source network='default'/>
      <model type='e1000'/>
    </interface>
    <serial type='file'><source path='/var/lib/libvirt/maas-console/node1.log'/></serial>
  </devices>
</domain>
XML

# ─── §1 both interfaces get the ROM, nothing else is lost ───────────────────
python3 "$ROM_XML" "$ROM" < "$WORK/dom.xml" > "$WORK/out1.xml" 2>"$WORK/err1.txt" \
    || { sed 's/^/    /' "$WORK/err1.txt" >&2; fail "rom_xml.py failed on a normal domain"; }

count_roms() { python3 -c '
import sys,xml.etree.ElementTree as ET
r=ET.parse(sys.argv[1]).getroot()
print(sum(len(i.findall("rom")) for i in r.find("devices").findall("interface")))' "$1"; }
count_ifaces() { python3 -c '
import sys,xml.etree.ElementTree as ET
r=ET.parse(sys.argv[1]).getroot()
print(len(r.find("devices").findall("interface")))' "$1"; }

[[ "$(count_roms "$WORK/out1.xml")" == 2 ]] \
    || fail "REGRESSION: expected one <rom> on each of the 2 interfaces, got $(count_roms "$WORK/out1.xml") — a node whose NICs disagree about verifying proves nothing"
[[ "$(count_ifaces "$WORK/out1.xml")" == 2 ]] \
    || fail "REGRESSION: the rewrite changed the number of interfaces (now $(count_ifaces "$WORK/out1.xml")) — it must add a ROM, not restructure the domain"
grep -q 'maas-console/node1.log' "$WORK/out1.xml" \
    || fail "REGRESSION: the rewrite dropped the file-backed serial console — every health gate reads that log"
grep -q "file=\"$ROM\"" "$WORK/out1.xml" \
    || fail "REGRESSION: the <rom> element does not carry the ROM path"
note "both interfaces carry the ROM; console and interface count survive"

# ─── §2 idempotent: re-running does not stack a second <rom> ────────────────
# create-fleet.sh is re-runnable, so this WILL be applied twice. libvirt rejects a
# second <rom> in one <interface>, and the failure would land at define time.
python3 "$ROM_XML" "$ROM" < "$WORK/out1.xml" > "$WORK/out2.xml" 2>/dev/null \
    || fail "rom_xml.py failed when re-applied to its own output"
[[ "$(count_roms "$WORK/out2.xml")" == 2 ]] \
    || fail "REGRESSION: re-applying stacked ROM elements ($(count_roms "$WORK/out2.xml") for 2 interfaces) — libvirt refuses to define that, so a second create-fleet.sh run would break the fleet"
note "idempotent: applied twice, still one <rom> per interface"

# ─── §3 NEGATIVE CONTROL: a missing ROM file must be refused ────────────────
# Refusing here is the point: libvirt reports an unreadable romfile at domain-START,
# as a permission error on a path that exists, which reads as a libvirt bug.
if python3 "$ROM_XML" "$WORK/does-not-exist.rom" < "$WORK/dom.xml" >/dev/null 2>&1; then
    fail "REGRESSION: rom_xml.py accepted a ROM path that does not exist — the failure would surface later as an unreadable-file error at domain start"
fi
note "negative control bites: a missing ROM file is refused up front"

# ─── §4 NEGATIVE CONTROL: a domain with no interface must be refused ────────
cat > "$WORK/nonic.xml" <<'XML'
<domain type='kvm'><name>node9</name><devices>
  <serial type='pty'/>
</devices></domain>
XML
if python3 "$ROM_XML" "$ROM" < "$WORK/nonic.xml" >/dev/null 2>&1; then
    fail "REGRESSION: rom_xml.py reported success on a domain with no <interface> — it would silently attach the ROM to nothing and the run would claim the node verifies"
fi
note "negative control bites: a domain with no NIC is refused, not silently unchanged"

pass "rom_xml.py attaches the ROM to every interface, is idempotent, and refuses a missing ROM or a NIC-less domain"

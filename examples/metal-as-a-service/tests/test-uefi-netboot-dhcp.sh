#!/usr/bin/env bash
# Verdict: the arch-conditional DHCP that lets a UEFI node netboot this fleet hands
# each kind of client the right thing — and, critically, does NOT hand a running
# iPXE the binary it is already running.
#
# WHAT THIS IS FOR. lib/dnsmasq_arch_xml.py teaches the PXE network to answer BIOS
# and UEFI clients differently, because the measured-boot driver needs UEFI (a BIOS
# firmware measures no payload) and this network only ever spoke BIOS. The change is
# five lines of dnsmasq configuration, four of which are obvious.
#
# THE FIFTH LINE IS WHY THIS TEST EXISTS. The form everyone writes first —
#
#     dhcp-match=set:efi64,option:client-arch,7
#     dhcp-boot=tag:efi64,ipxe.efi
#
# — chainloads forever: ipxe.efi boots, does its own DHCP, is still architecture 7,
# and is handed ipxe.efi again. §3 below runs exactly that config against a real
# dnsmasq and asserts the loop, so the guard in §2 is proven to be load-bearing
# rather than assumed to be.
#
# HOW IT IS PROVEN. Not by reading the generated config: by running a REAL dnsmasq
# and sending it REAL DHCP packets (tests/dhcp-probe.py), because the question is
# what dnsmasq does with these tags, and no reading of ours is evidence about that.
# It all happens inside a throwaway user+network namespace, so it is rootless and
# cannot touch the host's networking, the fleet, or libvirt.
#
# The options come from dnsmasq_arch_xml.py's OWN rewritten XML — not a copy typed
# into this file — so a change to the real thing is what gets tested.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need python3

have dnsmasq || DNSMASQ=/usr/sbin/dnsmasq
DNSMASQ="${DNSMASQ:-dnsmasq}"
command -v "$DNSMASQ" >/dev/null || skip "dnsmasq is not installed — the DHCP behaviour cannot be exercised"
command -v unshare >/dev/null || skip "unshare is not available — no rootless network namespace"

SANDBOX="$(mktemp -d)"
on_exit 'rm -rf "$SANDBOX"'

XMLTOOL="$LAB_DIR/lib/dnsmasq_arch_xml.py"
PROBE="$TEST_DIR/dhcp-probe.py"

# dnsmasq needs NET_ADMIN, and drops privileges on the way up. An unprivileged
# `unshare -rn` gives the first but denies setgroups(), so the drop fails; --map-auto
# maps the /etc/subuid range through newuidmap, which sets setgroups=allow. Check it
# here rather than reporting the resulting dnsmasq death as a DHCP failure.
unshare -rn --map-auto -- true 2>/dev/null \
    || skip "unprivileged user+network namespaces with subuid mapping are unavailable
  (needs /etc/subuid + newuidmap; dnsmasq cannot start without NET_ADMIN)"

# A synthetic network, not the live one: this test must not depend on, or be able to
# affect, a fleet that may or may not exist on this host.
cat > "$SANDBOX/net.xml" <<'XML'
<network>
  <name>test-pxe</name>
  <bridge name='virbr-test'/>
  <ip address='127.0.0.1' netmask='255.0.0.0'>
    <tftp root='/var/lib/libvirt/tftp-test'/>
    <dhcp>
      <range start='127.0.0.100' end='127.0.0.200'/>
      <bootp file='boot.ipxe'/>
    </dhcp>
  </ip>
</network>
XML

# conf_from_xml <net-xml> -> a dnsmasq conf carrying exactly the options libvirt
# would render from that XML. libvirt writes each <dnsmasq:option value='X'/> into
# its generated conf file verbatim, so lifting them out is a faithful reproduction
# of what the running network would have.
conf_from_xml() {
    local xml="$1" out="$2" bootfile
    # Both quote styles: libvirt writes single quotes, but this XML has been through
    # ElementTree, which re-serializes attributes with double quotes. Matching only
    # one silently yields an EMPTY untagged dhcp-boot — which looks exactly like a
    # broken BIOS path in the assertions below rather than a broken harness.
    bootfile="$(sed -nE 's/.*<bootp file=.([^"'"'"']+).*/\1/p' "$xml" | head -1)"
    [[ -n "$bootfile" ]] || fail "the harness could not read <bootp file=> out of $xml"
    cat > "$out" <<EOF
port=0
bind-interfaces
interface=lo
dhcp-alternate-port=1067,1068
dhcp-range=127.0.0.100,127.0.0.200,1h
log-dhcp
EOF
    python3 - "$xml" >> "$out" <<'PY'
import sys, xml.etree.ElementTree as ET
NS = "http://libvirt.org/schemas/network/dnsmasq/1.0"
root = ET.parse(sys.argv[1]).getroot()
block = root.find(f"{{{NS}}}options")
for el in (block.findall(f"{{{NS}}}option") if block is not None else []):
    print(el.get("value"))
PY
    printf 'dhcp-boot=%s\n' "$bootfile" >> "$out"     # libvirt's untagged <bootp file=>
}

# offers <conf> -> `label=filename` lines from a real dnsmasq in a throwaway netns
offers() {
    local conf="$1" tag="${2:-run}"
    unshare -rn --map-auto -- sh -c "
        ip link set lo up || exit 3
        '$DNSMASQ' --conf-file='$conf' --pid-file='$SANDBOX/$tag.pid' \
            --dhcp-leasefile='$SANDBOX/$tag.leases' --log-facility='$SANDBOX/$tag.log' \
            --no-hosts --no-resolv || exit 4
        sleep 1
        python3 '$PROBE' --probe bios:0 --probe efi64:7 --probe efi64alt:9 \
                         --probe efi-ipxe:7:iPXE --probe noarch:none
    " 2>>"$SANDBOX/$tag.stderr"
}
got() { printf '%s\n' "$1" | sed -nE "s/^$2=(.*)$/\1/p"; }

# ── 1. the rewrite produces a network libvirt would accept ──────────────────
python3 "$XMLTOOL" < "$SANDBOX/net.xml" > "$SANDBOX/net-arch.xml" 2>"$SANDBOX/rewrite.err" \
    || fail "dnsmasq_arch_xml.py refused a well-formed network: $(tr '\n' ' ' < "$SANDBOX/rewrite.err")"
grep -q 'dnsmasq:options' "$SANDBOX/net-arch.xml" \
    || fail "the rewritten XML carries no <dnsmasq:options> block — libvirt would render no extra config"
grep -q "xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'\|xmlns:dnsmasq=\"http://libvirt.org/schemas/network/dnsmasq/1.0\"" "$SANDBOX/net-arch.xml" \
    || fail "the dnsmasq namespace is not declared on <network> — libvirt rejects the definition"
if command -v virt-xml-validate >/dev/null; then
    virt-xml-validate "$SANDBOX/net-arch.xml" network >/dev/null 2>&1 \
        || fail "virt-xml-validate rejects the rewritten network XML"
    note "virt-xml-validate accepts the rewritten network  ✓"
fi
note "rewrote the network: <dnsmasq:options> + namespace declared  ✓"

# ── 2. a real dnsmasq answers each client correctly ─────────────────────────
conf_from_xml "$SANDBOX/net-arch.xml" "$SANDBOX/good.conf"
OUT="$(offers "$SANDBOX/good.conf" good)"
[[ -n "$OUT" ]] || fail "no reply from dnsmasq at all — the harness is broken, not the config. stderr: $(tr '\n' ' ' < "$SANDBOX/good.stderr" | tail -c 300)"
grep -q '=TIMEOUT' <<<"$OUT" \
    && fail "dnsmasq did not answer one or more probes: $(tr '\n' ' ' <<<"$OUT")"

[[ "$(got "$OUT" bios)" == "boot.ipxe" ]] \
    || fail "REGRESSION: a legacy BIOS client (arch 0) was offered '$(got "$OUT" bios)', not boot.ipxe. The three BIOS nodes and their verifying option ROM would stop netbooting"
[[ "$(got "$OUT" noarch)" == "boot.ipxe" ]] \
    || fail "REGRESSION: a client sending NO architecture option was offered '$(got "$OUT" noarch)', not boot.ipxe"
[[ "$(got "$OUT" efi64)" == "ipxe.efi" ]] \
    || fail "a UEFI x86-64 client (arch 7) was offered '$(got "$OUT" efi64)', not ipxe.efi — the measured node still cannot netboot, which is the entire point of this change"
[[ "$(got "$OUT" efi64alt)" == "ipxe.efi" ]] \
    || fail "a UEFI client announcing arch 9 was offered '$(got "$OUT" efi64alt)', not ipxe.efi (RFC 4578 assigns 7 and 9 both to EFI x86-64; real firmware sends either)"
note "BIOS -> boot.ipxe, UEFI (arch 7 and 9) -> ipxe.efi  ✓"

[[ "$(got "$OUT" efi-ipxe)" == "boot.ipxe" ]] \
    || fail "REGRESSION: a client that is ALREADY iPXE (user-class iPXE, arch 7) was offered '$(got "$OUT" efi-ipxe)'. Handing it ipxe.efi is an infinite chainload: it boots, DHCPs, is still arch 7, and loads itself forever. The tag-if line in dnsmasq_arch_xml.py is what prevents this"
note "an already-running iPXE gets the SCRIPT, not itself — no chainload loop  ✓"

# ── 3. THE NEGATIVE CONTROL: without the loop break, it really does loop ────
# The naive config is the one every write-up of this suggests, including this lab's
# own DEFERRED.md before it was measured. If this section ever stops reproducing the
# loop, §2's guard has become decoration and nobody would notice.
sed -e '/^tag-if=/d' -e 's/^dhcp-boot=tag:efi-fw,/dhcp-boot=tag:efi64,/' \
    "$SANDBOX/good.conf" > "$SANDBOX/naive.conf"
grep -q '^tag-if=' "$SANDBOX/naive.conf" \
    && fail "the negative control still has the loop break — it proves nothing"
NAIVE="$(offers "$SANDBOX/naive.conf" naive)"
[[ "$(got "$NAIVE" efi-ipxe)" == "ipxe.efi" ]] \
    || fail "the negative control did not reproduce the chainload loop (a running iPXE was offered '$(got "$NAIVE" efi-ipxe)'). Either dnsmasq's tag semantics changed or the control is no longer testing the naive config — §2's assertion is now unproven either way"
note "without tag-if, a running iPXE is offered ipxe.efi — the loop is real, and the guard earns its place  ✓"

# ── 4. it refuses rather than half-applying ─────────────────────────────────
# Each of these would produce a network that boots SOMETHING, wrongly, which is the
# failure mode this lab treats as worse than not booting at all.
sed '/<bootp/d' "$SANDBOX/net.xml" > "$SANDBOX/no-bootp.xml"
if ( python3 "$XMLTOOL" < "$SANDBOX/no-bootp.xml" >/dev/null 2>&1 ); then
    fail "a network with no <bootp file=> was accepted: UEFI clients would get a filename and BIOS clients none, trading one broken half for the other"
fi
sed '/<tftp/d' "$SANDBOX/net.xml" > "$SANDBOX/no-tftp.xml"
if ( python3 "$XMLTOOL" < "$SANDBOX/no-tftp.xml" >/dev/null 2>&1 ); then
    fail "a network serving no TFTP root was accepted: the UEFI client would be told to fetch ipxe.efi from nowhere"
fi
sed '/<dhcp>/,/<\/dhcp>/d' "$SANDBOX/net.xml" > "$SANDBOX/no-dhcp.xml"
if ( python3 "$XMLTOOL" < "$SANDBOX/no-dhcp.xml" >/dev/null 2>&1 ); then
    fail "a network with no DHCP server was accepted — there is nothing here to configure"
fi
note "refuses a network with no <bootp>, no TFTP root, or no DHCP  ✓"

# ── 5. re-running replaces, and keeps what it does not own ─────────────────
# rom_xml.py learned this the hard way: appending a second block produces a domain
# libvirt rejects with an unhelpful error. An operator's own dnsmasq options must
# also survive, or this script silently deletes local configuration.
python3 - "$SANDBOX/net-arch.xml" > "$SANDBOX/net-foreign.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
NS = "http://libvirt.org/schemas/network/dnsmasq/1.0"
ET.register_namespace("dnsmasq", NS)
root = ET.parse(sys.argv[1]).getroot()
ET.SubElement(root.find(f"{{{NS}}}options"), f"{{{NS}}}option",
              {"value": "dhcp-option=option:ntp-server,127.0.0.1"})
sys.stdout.write(ET.tostring(root, encoding="unicode"))
PY
python3 "$XMLTOOL" < "$SANDBOX/net-foreign.xml" > "$SANDBOX/net-twice.xml" 2>/dev/null \
    || fail "re-running the rewrite on its own output failed — it is not idempotent"
n_blocks="$(grep -o '<dnsmasq:options>' "$SANDBOX/net-twice.xml" | wc -l)"
[[ "$n_blocks" == 1 ]] \
    || fail "REGRESSION: re-running produced $n_blocks <dnsmasq:options> blocks, not 1 — libvirt rejects the second"
n_boot="$(grep -o 'dhcp-boot=tag:efi-fw' "$SANDBOX/net-twice.xml" | wc -l)"
[[ "$n_boot" == 1 ]] \
    || fail "REGRESSION: re-running left $n_boot copies of the dhcp-boot line, not 1"
grep -q 'ntp-server' "$SANDBOX/net-twice.xml" \
    || fail "re-running DELETED a dnsmasq option this script does not own — it must replace only its own lines"
note "idempotent: one block, one dhcp-boot, and a foreign option preserved  ✓"

pass "the arch-conditional DHCP hands BIOS clients the iPXE script and UEFI firmware ipxe.efi, hands an already-running iPXE the script rather than itself (the naive config loops — §3 reproduces it against a real dnsmasq), refuses any network where the change would half-apply, and re-runs without duplicating or deleting anything"

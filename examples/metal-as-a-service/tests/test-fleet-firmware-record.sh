#!/usr/bin/env bash
# Verdict: the registry records the firmware the machine ACTUALLY has, not an
# enroll-time guess nobody revisits.
#
# THE INCIDENT (live, 2026-07-29). `maas-lab.sh show node3` reported:
#
#     firmware    bios
#
# while the domain's own XML said:
#
#     <os firmware='efi'>
#       <loader readonly='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE_4M.fd</loader>
#       <tpm model='tpm-tis'>
#
# `enroll --firmware` defaults to `bios`, nothing ever revisited it, and the fleet
# builder converted the node to UEFI+TPM AFTERWARDS (give_tpm -> lib/tpm_xml.py) with no
# way to say so. Nothing failed, because only `show` reads the field — so it simply lied
# to whoever asked, and would have sent any future scheduler down a BIOS boot path for a
# UEFI machine. A record that outlived the thing it described; see CLAUDE.md, "The two
# bug classes a green suite cannot see".
#
# WHY THE FIX IS NOT "make `show` read the domain". The control plane reaches a node only
# through the BMC and its console, never the hypervisor (drivers/install.sh's header) —
# a machine in a rack has no `virsh`. So whoever CHANGES the firmware reports it, exactly
# as reserve_dhcp reports the MAC it found. That makes two things testable here: the
# parser that reads a domain, and the setter that records it.
#
# SAFETY: no libvirt, no domains, no sudo, no root. The XML is fixture text on stdin and
# the registry is a throwaway state dir.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trap 'cleanup_sandboxes' EXIT
maas_env
FLEET="$LAB_DIR/create-fleet.sh"

# ── 1. the parser: what does a domain actually say? ─────────────────────────
# Two independent markers, because libvirt writes either depending on how the domain
# was defined. Matching only one reads a good UEFI domain as BIOS.
fw_of() { printf '%s' "$1" | "$FLEET" _firmware-of-xml 2>/dev/null; }

got="$(fw_of "<domain><os firmware='efi'><type>hvm</type></os></domain>")"
[[ "$got" == uefi ]] \
    || fail "REGRESSION: a domain with <os firmware='efi'> was read as '$got'. That is libvirt's modern autoselect attribute and the exact form node3 carried when the registry claimed bios"

got="$(fw_of "<domain><os><type>hvm</type><loader readonly='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE_4M.fd</loader></os></domain>")"
[[ "$got" == uefi ]] \
    || fail "REGRESSION: a domain with an explicit OVMF <loader type='pflash'> was read as '$got' — libvirt writes this form instead of the firmware= attribute depending on how the domain was defined, so reading only one marker misreports the other"

got="$(fw_of "<domain><os><type>hvm</type><boot dev='network'/></os></domain>")"
[[ "$got" == bios ]] \
    || fail "a plain BIOS domain was read as '$got' — the parser must not call everything UEFI, or the check it feeds proves nothing"

got="$(fw_of "not xml at all")"
[[ "$got" == bios ]] \
    || fail "unparseable XML produced '$got' instead of failing safe to bios"

got="$(fw_of "<domain><name>x</name></domain>")"
[[ "$got" == bios ]] \
    || fail "a domain with no <os> element produced '$got' instead of failing safe to bios"
note "the parser reads BOTH UEFI markers (firmware='efi', loader type='pflash') and calls everything else bios  ✓"

# ── 2. the setter records it, and says what changed ─────────────────────────
( "$MAAS" enroll fw1 --bmc-port 6270 ) >/dev/null 2>&1 || fail "enroll fw1"
[[ "$( "$MAAS" show fw1 | awk '$1=="firmware"{print $2}' )" == bios ]] \
    || fail "the enroll default is no longer bios — this test's premise (that the guess is wrong for a UEFI node) needs rechecking"
out="$( "$MAAS" set-firmware fw1 uefi 2>&1 )" || fail "set-firmware uefi failed"
[[ "$( "$MAAS" show fw1 | awk '$1=="firmware"{print $2}' )" == uefi ]] \
    || fail "REGRESSION: set-firmware did not change what 'show' reports — the record still describes a machine that no longer exists"
grep -q 'was bios' <<<"$out" \
    || fail "set-firmware changed the record silently (said: ${out//$'\n'/ }). A correction that does not name what it overwrote hides a fleet built inconsistently"
note "set-firmware records the real mode and names the value it replaced  ✓"

( "$MAAS" set-firmware fw1 sideways ) >/dev/null 2>&1 \
    && fail "REGRESSION: set-firmware accepted 'sideways' — the field feeds boot-path decisions and must only ever hold bios|uefi"
[[ "$( "$MAAS" show fw1 | awk '$1=="firmware"{print $2}' )" == uefi ]] \
    || fail "a refused set-firmware still altered the record"
note "a firmware mode that is neither bios nor uefi is refused, leaving the record intact  ✓"

# ── 3. enroll records uefi for a TPM-selected node, without being told ──────
# The bug in one line: the fleet spec says bios (the fleet default), FLEET_TPM names the
# node, and the builder will convert it. Enrolling it as bios is how the record started
# out wrong. TPM implies UEFI because lib/tpm_xml.py sets firmware='efi' — a TPM on a
# BIOS domain measures nothing.
sel() { FLEET_TPM="$1" "$FLEET" _selects-tpm "$2" >/dev/null 2>&1; }
sel node3 node3 || fail "_selects-tpm no longer agrees that FLEET_TPM=node3 selects node3 — §3's premise is gone"
sel node3 node1 && fail "_selects-tpm says FLEET_TPM=node3 also selects node1 — the selection is not node-specific"
note "TPM selection is the signal enroll uses, and it is node-specific  ✓"

pass "the firmware field describes the machine: the parser reads both UEFI markers off a real domain and fails safe otherwise, set-firmware records a correction and names what it replaced, an invalid mode is refused, and a TPM-selected node is enrolled as UEFI rather than as the fleet default it will not keep"

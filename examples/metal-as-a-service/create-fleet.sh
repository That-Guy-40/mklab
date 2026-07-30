#!/usr/bin/env bash
# create-fleet.sh — stand up (or enroll) the Metal-as-a-Service fleet from fleet.toml.
#
# It does NOT reinvent libvirt/vbmc plumbing: it WRAPS the proven sibling anchor
# examples/virtualbmc-ipmi-lab/ (create-node.sh + vbmc-lab.sh), which is already
# parameterized by NODE/PORT/NET and whose RUNBOOK sanctions fanning out onto
# 6231/6232 in one rootful vbmcd container. One vbmcd hosts every node's BMC.
#
# Modes:
#   enroll         HEADLESS — register the fleet into maas-lab.sh's registry only
#                  (no libvirt, no root). Proves the fleet wiring + generated BMC
#                  registry. This is the increment-1 verifiable path.
#   up             AUTHOR-RUN (rootful) — build+create the 3 libvirt domains, start
#                  vbmcd, `vbmc add` each on 6230–6232, then enroll. Needs sudo +
#                  qemu:///system + rootful podman (inherited from the vbmc lab).
#   down           AUTHOR-RUN — tear the fleet's domains + BMCs down.
#   status         show the fleet via `maas-lab.sh list`.
#
# Security (AUDIT.md): BMC ports are loopback-only (F1); teardown kills by the
# container/domain lifecycle verbs, never `pkill -f` (F8); disk removal under
# /var/lib/libvirt is handed to the user.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
MAAS="$HERE/maas-lab.sh"
FLEET_PY="$HERE/lib/fleet.py"
FLEET_TOML="${FLEET_TOML:-$HERE/fleet.toml}"
VBMC_LAB="${VBMC_LAB:-$HERE/../virtualbmc-ipmi-lab}"
# Where each node's serial console is RECORDED. Under /var/lib/libvirt so libvirt's
# AppArmor helper grants qemu the path; the files are pre-created 0666 so the
# unprivileged control plane can read them back. See lib/console_xml.py for why the
# console is a file and not a pty.
CONSOLE_DIR="${MAAS_CONSOLE_DIR:-/var/lib/libvirt/maas-console}"
# The NIC the fleet's nodes present. NOT virtio, deliberately: the probe and the RAM
# payloads boot kernels that do not drive virtio-net (Debian stock has it modular, and
# an initramfs carries no modules; micro-linux's defconfig omits it), so a virtio NIC
# gives the guest NO network device at all. It boots, runs, gathers its facts and has
# nothing to send them over — which is how one live run reached "collected facts
# cpus=1" and then "FAILED to post". e1000 is built into both kernels. Proven by
# booting the probe under QEMU with each: e1000 registers eth0, virtio registers nothing.
FLEET_NIC_MODEL="${FLEET_NIC_MODEL:-e1000}"
FLEET_CONSOLE="${FLEET_CONSOLE:-file}"        # file | pty (pty = the old, unlogged behaviour)
VIRSH="virsh -c qemu:///system"

die()  { printf 'create-fleet: %s\n' "$*" >&2; exit 1; }
info() { printf '  - %s\n' "$*" >&2; }
step() { printf '==> %s\n' "$*" >&2; }

command -v python3 >/dev/null || die "python3 required (fleet.toml is TOML)"
[[ -f "$FLEET_TOML" ]] || die "no fleet spec: $FLEET_TOML"

fleet_names() { python3 "$FLEET_PY" "$FLEET_TOML" names; }
# Load one node's merged fields (defaults + per-node) into NODE_* shell vars.
load_node() {  # load_node <name>  -> sets NODE_NAME, NODE_BMC_PORT, NODE_MEMORY_MB, ...
    local line
    while IFS= read -r line; do eval "$line"; done < <(python3 "$FLEET_PY" "$FLEET_TOML" get "$1")
}

# ── enroll: headless registry population (the increment-1 verifiable path) ────
do_enroll() {
    local name
    for name in $(fleet_names); do
        load_node "$name"
        if "$MAAS" state "$name" >/dev/null 2>&1; then
            info "$name already enrolled (state=$("$MAAS" state "$name")) — skipping"
            continue
        fi
        # A TPM-selected node is a UEFI node, and that is not a coincidence: lib/tpm_xml.py
        # sets firmware='efi' because a BIOS firmware measures no payload, so a TPM on a
        # BIOS domain would attest nothing. Recording `bios` here and converting the
        # domain later is what left the registry describing a machine that no longer
        # existed (see maas-lab.sh's set-firmware, and CLAUDE.md's "record that outlives
        # the thing it describes"). Say what the node will actually be.
        local fw="${NODE_FIRMWARE:-bios}"
        if tpm_selects "$name"; then fw=uefi; fi
        "$MAAS" enroll "$name" \
            --bmc-port "${NODE_BMC_PORT}" \
            --domain "$name" \
            --firmware "$fw" \
            --uri "${NODE_URI:-qemu:///system}" \
            --bmc-user "${NODE_BMC_USER:-admin}" \
            --bmc-pass "${NODE_BMC_PASS:-password}" >/dev/null \
            || die "enroll $name failed"
        info "enrolled $name (bmc port ${NODE_BMC_PORT})"
    done
    step "fleet enrolled; generated BMC registry: $(python3 "$FLEET_PY" "$FLEET_TOML" names | wc -l) nodes"
    "$MAAS" list
}

# ── the two things a fleet needs that a single-node lab does not ─────────────
#
# Both were missing on the first live end-to-end run, and both failed the same way:
# silently, with a timeout somewhere far downstream.
#
# 1. A CONSOLE THAT IS RECORDED. Every health gate greps <node>/console.log; a pty
#    console keeps nothing when no one is attached, so the run was blind.
# 2. A DHCP RESERVATION. The PXE chain (netboot-chain.sh) resolves the per-node boot
#    script by ${hostname}, which the node learns from DHCP option 12 — dnsmasq only
#    sends it for a host it has a reservation for. Without it every node falls through
#    to the MAC-keyed name and then to default.ipxe.

# give_console <node> — swap the domain's pty console for a file, and tell the
# registry where it is (the `console` field the drivers already read).
give_console() {
    local name="$1" log="$CONSOLE_DIR/$name.log"
    if [[ "$FLEET_CONSOLE" != file ]]; then
        info "$name: FLEET_CONSOLE=$FLEET_CONSOLE — leaving the pty console (health gates that read a console log will time out)"
        return 0
    fi
    # Pre-create it 0666: qemu (uid libvirt-qemu) writes, the unprivileged control
    # plane reads. If qemu created it itself the mode would be 0600 and every gate
    # would fail on a permission error instead of on the machine's behaviour.
    sudo mkdir -p "$CONSOLE_DIR" && sudo chmod 0755 "$CONSOLE_DIR" \
        || { info "$name: could not create $CONSOLE_DIR — leaving the pty console"; return 1; }
    sudo install -m 0666 /dev/null "$log" \
        || { info "$name: could not create $log — leaving the pty console"; return 1; }
    $VIRSH dumpxml "$name" \
        | python3 "$HERE/lib/console_xml.py" "$log" \
        | sudo $VIRSH define /dev/stdin >/dev/null \
        || { info "$name: could not redefine with a file console — leaving the pty console"; return 1; }
    "$MAAS" set-console "$name" "$log" >/dev/null 2>&1 \
        || info "$name: console file created but not recorded in the registry"
    info "$name: console recorded to $log"
}

# give_verifying_rom <node> — attach the imgverify-capable iPXE ROM to the domain's
# NICs, so the on-node half of F2 can actually run. DEFAULT ON once the ROM is
# installed on this host (./build-verifying-rom.sh install):
#   FLEET_NIC_ROM unset    attach the installed default if present, else nothing
#   FLEET_NIC_ROM=1        require the installed default (die if missing)
#   FLEET_NIC_ROM=<path>   use that ROM (die if missing)
#   FLEET_NIC_ROM=0        explicitly a plain fleet (also: none, off)
# Without the ROM the nodes boot QEMU's stock one, which has no IMAGE_TRUST_CMD
# and refuses nothing — and cannot speak on the serial console either.
# rom_plan <node> [nic-model] — resolve the verifying-ROM decision for one node WITHOUT
# acting on it. Prints exactly one verdict on stdout:
#
#   attach:<path>                 attach this ROM
#   none:uefi-node                a UEFI node takes no legacy ROM (see give_verifying_rom)
#   none:opted-out                FLEET_NIC_ROM=0|none|off — deliberately a plain fleet
#   none:not-installed            unset + no ROM installed on this host -> a plain fleet
#   none:no-default-for-model     unset + no default ROM name for this NIC model
#   missing:<path>                REQUIRED but absent             <- FATAL
#   missing:no-default-for-model  FLEET_NIC_ROM=1, unknown model  <- FATAL
#
# Split out for the same reason as tpm_selects and firmware_of_xml: so do_preflight and
# give_verifying_rom reach ONE implementation of the answer, rather than two that agree
# until someone edits one of them. A pre-flight that RE-DERIVES what apply decides is a
# record that can outlive its subject (CLAUDE.md, "a record that outlives the thing it
# describes"); this one cannot, because it is the same code.
#
# Takes the model as an ARGUMENT rather than reading NODE_NIC_MODEL: load_node `eval`s
# only the keys a node declares, so an undeclared nic_model still holds the PREVIOUS
# node's value. The caller resolves it once, explicitly.
rom_plan() {
    local name="$1" model="${2:-$FLEET_NIC_MODEL}" rom="${FLEET_NIC_ROM:-}" explicit path
    # A UEFI node must NOT get the legacy option ROM. This is not a nicety: attaching
    # it replaces QEMU's efi-e1000.rom — the only UEFI NIC driver OVMF would have for
    # that card — with a legacy-only image, so the firmware finds no network device,
    # produces no boot option, and drops to the EFI shell with no PXE attempt at all.
    # (Found live 2026-07-29, on the first run after per-node FLEET_TPM landed.)
    # These nodes enforce F2 through the verifying ipxe.efi that OVMF's own PXE client
    # fetches instead; lib/tpm_xml.py switches them to virtio with no ROM.
    if tpm_selects "$name"; then printf 'none:uefi-node\n'; return 0; fi
    # Explicit opt-OUT. The ROM used to be pure opt-in (unset = silently none), and
    # this fleet lost its ROMs to a create-fleet run that forgot the var THREE
    # times — twice from this repo's own printed instructions. An opt-in security
    # default is a trap: every re-create is a chance to forget it, and the failure
    # mode is a stock ROM that cannot honour imgverify and says nothing on serial.
    case "$rom" in 0|none|off) printf 'none:opted-out\n'; return 0 ;; esac
    if [[ "$rom" == 1 || -z "$rom" ]]; then
        explicit="$rom"
        case "$model" in
            e1000)   path="${MAAS_ROM_DIR:-/var/lib/libvirt/maas-rom}/ipxe-8086100e.rom" ;;
            virtio)  path="${MAAS_ROM_DIR:-/var/lib/libvirt/maas-rom}/ipxe-1af41000.rom" ;;
            rtl8139) path="${MAAS_ROM_DIR:-/var/lib/libvirt/maas-rom}/ipxe-10ec8139.rom" ;;
            # FLEET_NIC_ROM=1 means "I require the ROM". No default name for this model
            # is then FATAL, not a shrug: silently shipping no ROM is precisely the
            # opt-in trap the paragraph above is about.
            *) if [[ -z "$explicit" ]]; then printf 'none:no-default-for-model\n'
               else                          printf 'missing:no-default-for-model\n'; fi
               return 0 ;;
        esac
        # DEFAULT ON once installed: if this host has run `build-verifying-rom.sh
        # install`, every new fleet carries the ROM unless told not to. Unset env +
        # no installed ROM stays a plain fleet (nothing to attach, nothing implied).
        if [[ -z "$explicit" && ! -f "$path" ]]; then printf 'none:not-installed\n'; return 0; fi
    else
        path="$rom"
    fi
    if [[ -f "$path" ]]; then printf 'attach:%s\n' "$path"; else printf 'missing:%s\n' "$path"; fi
}

give_verifying_rom() {
    local name="$1" model="${2:-$FLEET_NIC_MODEL}" plan rom
    plan="$(rom_plan "$name" "$model")"
    case "$plan" in
        none:uefi-node)
            info "$name: no legacy option ROM — it is a UEFI node, and one would displace the"
            info "  UEFI NIC driver OVMF needs. It enforces F2 via the TFTP'd ipxe.efi instead."
            return 0 ;;
        none:*) return 0 ;;
        # Refuse rather than half-apply: a fleet where some nodes verify and some do not
        # is worse than one where none do, because a green run then proves neither.
        # do_preflight normally catches these before anything is built; reaching them
        # here means preflight was bypassed.
        missing:no-default-for-model)
            die "FLEET_NIC_ROM=1 but there is no default ROM name for NIC model '$model'.
  Give the path explicitly:  FLEET_NIC_ROM=<path>" ;;
        missing:*)
            die "FLEET_NIC_ROM is set but ${plan#missing:} does not exist.
  Build and install it first:  ./build-verifying-rom.sh build && ./build-verifying-rom.sh install" ;;
    esac
    rom="${plan#attach:}"
    if [[ -z "${FLEET_NIC_ROM:-}" ]]; then
        info "$name: verifying ROM defaulted ON ($rom is installed on this host; FLEET_NIC_ROM=0 opts out)"
    fi
    $VIRSH dumpxml "$name" \
        | python3 "$HERE/lib/rom_xml.py" "$rom" \
        | sudo $VIRSH define /dev/stdin >/dev/null \
        || die "$name: could not attach the verifying ROM $rom"
    info "$name: verifying iPXE ROM attached ($rom)"
}

# give_tpm <node> — a TPM 2.0 device AND UEFI firmware, for `image+measured`.
# Opt-in via FLEET_TPM: unlike the verifying ROM this is NOT default-on, because it
# changes how the domain BOOTS (BIOS -> UEFI) and every payload the other three
# drivers use is BIOS-booted. A fleet-wide default would break them.
#
#   FLEET_TPM=node3          just that node        <- what you almost always want
#   FLEET_TPM=node2,node3    those nodes
#   FLEET_TPM=1 (or `all`)   the whole fleet       <- rarely right; warns
#
# WHY PER-NODE, learned live. The first measured run set FLEET_TPM=1, which switched
# node1 and node2 to UEFI as well — and their disks had been INSTALLED under BIOS, so
# they could no longer boot what was on them. Measured boot is a property of one
# node's job, not of the fleet, and the knob now says so.
#
# Both or neither, deliberately. A TPM on a BIOS domain produces quotes that
# verify, match a policy, and mean nothing: SeaBIOS measures the boot sector and
# the partition table, never the filesystem, so two completely different kernels
# measure the same (proven under swtpm — see lib/tpm_xml.py and DEFERRED.md).
# The refusal lives in tpm_xml.py, which will not emit a TPM without UEFI.
# tpm_selects <node> — does FLEET_TPM name this node? Split out from give_tpm so the
# answer is one implementation, addressable as `_selects-tpm` and therefore testable
# without libvirt, swtpm or a fleet (tests/test-fleet-tpm-selection.sh).
tpm_selects() {
    local name="$1" want="${FLEET_TPM:-0}"
    case "$want" in
        0|""|no|off) return 1 ;;
        1|all|yes)   return 0 ;;
        # Comma-separated node list; the commas around BOTH sides are what stop
        # node1 from matching node10, and an entry from matching a prefix of a name.
        *) [[ ",$want," == *",$name,"* ]] ;;
    esac
}

# validate_tpm_selection — refuse a FLEET_TPM naming a node that does not exist.
# Without this the typo gives UEFI+TPM to NOBODY and says nothing; the measured run
# then fails much later with an empty console and "the node never delivered a quote",
# which reads as a payload bug. Checked where the fleet's names are in hand.
validate_tpm_selection() {
    local n known
    case "${FLEET_TPM:-0}" in
        0|""|no|off|1|all|yes) return 0 ;;
    esac
    known=" $(fleet_names | tr '\n' ' ')"
    for n in ${FLEET_TPM//,/ }; do
        [[ "$known" == *" $n "* ]] \
            || die "FLEET_TPM names '$n', which is not a node in this fleet.
  Known nodes:$known
  A name that matches nothing would silently give UEFI+TPM to no one, and the
  measured run would fail much later with an empty console."
    done
}

# require_swtpm <what-it-selects> — the ONE swtpm check.
#
# It used to live inside give_tpm, which do_up reaches at step 9 — AFTER every node disk
# has been rewritten by `create-node.sh`'s unconditional `qemu-img convert`, after vbmcd
# is built and started, after three BMCs are registered and the whole fleet is enrolled.
# On a host without swtpm that is a half-built fleet and the previous disks gone, for an
# answer `command -v` had at step 0. do_preflight calls this before anything is touched;
# give_tpm keeps calling it as a backstop for any caller that skipped preflight.
require_swtpm() {
    command -v swtpm >/dev/null && return 0
    die "FLEET_TPM=${FLEET_TPM:-0} selects $1, but swtpm is not installed — libvirt cannot
  back an emulated TPM. Install swtpm (and swtpm-tools), or leave FLEET_TPM unset for a
  plain BIOS fleet."
}

# warn_blanket_tpm — FLEET_TPM=1/all/yes converts EVERY node to UEFI. Kept working,
# because scripts and notes already say FLEET_TPM=1, but it is the setting that broke two
# nodes, so it does not pass quietly. Said once, in preflight, where the operator can
# still change their mind — not once per node at step 9.
warn_blanket_tpm() {
    case "${FLEET_TPM:-0}" in
        1|all|yes)
            info "FLEET_TPM=${FLEET_TPM}: giving UEFI+TPM to EVERY node in this fleet. A node whose"
            info "  disk was installed under BIOS will not boot it afterwards. Measured boot is a"
            info "  property of one node's job, not the fleet's — prefer FLEET_TPM=<node>[,<node>]" ;;
    esac
}

give_tpm() {
    local name="$1"
    tpm_selects "$name" || return 0
    require_swtpm "$name"
    $VIRSH dumpxml "$name" \
        | python3 "$HERE/lib/tpm_xml.py" \
        | sudo $VIRSH define /dev/stdin >/dev/null \
        || die "$name: could not attach the TPM + UEFI firmware"
    info "$name: TPM 2.0 + UEFI attached (measured boot; swtpm is plumbing, not a trust anchor)"
}

# firmware_of_xml — domain XML on stdin -> `uefi` or `bios`.
#
# Split out from reconcile_firmware so the ANSWER is one implementation, addressable as
# `_firmware-of-xml` and therefore testable against fixture XML with no libvirt, no
# domains and no sudo (tests/test-fleet-firmware-record.sh). Same reason tpm_selects is
# split from give_tpm.
#
# Two independent markers, because libvirt writes either depending on how the domain was
# defined: the modern `<os firmware='efi'>` autoselect attribute, and the explicit
# `<loader ... type='pflash'>` OVMF pair. Matching only one of them would read a
# perfectly good UEFI domain as BIOS.
# NOTE `python3 -c`, not `python3 - <<'PY'`: a heredoc feeds the SCRIPT on stdin, which
# leaves nothing there for the XML, and the function then reports `bios` for every
# domain — including a UEFI one. Caught by this function's own test on its first run.
firmware_of_xml() {
    python3 -c '
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
except Exception:
    print("bios"); sys.exit(0)
os_el = root.find("os")
if os_el is None:
    print("bios"); sys.exit(0)
if (os_el.get("firmware") or "").lower() == "efi":
    print("uefi"); sys.exit(0)
loader = os_el.find("loader")
if loader is not None and (loader.get("type") or "").lower() == "pflash":
    print("uefi"); sys.exit(0)
print("bios")
'
}

# reconcile_firmware <node> — make the registry agree with the machine.
#
# FOUND LIVE 2026-07-29: `maas-lab.sh show node3` reported `firmware bios` for a domain
# whose XML said `<os firmware='efi'>` with an OVMF pflash loader and a TPM. `enroll
# --firmware` defaults to bios, nothing revisited it, and give_tpm converted the domain
# afterwards without telling the control plane. Nothing failed — the field is only read
# by `show` — so it simply lied to whoever asked, and would mislead any future scheduler
# that used it to pick a boot path.
#
# The registry is a CACHE of a fact the domain owns, so correct it from the source rather
# than asking the operator to keep two places in step. Loud when it changes something:
# a silent repair would hide a fleet built inconsistently.
reconcile_firmware() {
    local name="$1" actual recorded
    actual="$($VIRSH dumpxml "$name" 2>/dev/null | firmware_of_xml)"
    [[ -n "$actual" ]] || return 0
    recorded="$("$MAAS" show "$name" 2>/dev/null | awk '$1=="firmware"{print $2; exit}')"
    [[ -n "$recorded" ]] || return 0
    if [[ "$recorded" != "$actual" ]]; then
        info "$name: registry said firmware=$recorded, the domain is $actual — correcting the record"
        "$MAAS" set-firmware "$name" "$actual" >/dev/null 2>&1 \
            || info "$name: could not correct the firmware record (set-firmware failed)"
    fi
}

# reserve_dhcp <node> <net> <index> — record the domain's MAC and give it a DHCP
# reservation, so the node's own name reaches iPXE as ${hostname} (DHCP option 12).
reserve_dhcp() {
    local name="$1" net="${2:-vbmc-pxe}" idx="${3:-0}" mac gw prefix ip
    mac="$($VIRSH domiflist "$name" 2>/dev/null | awk '$3=="'"$net"'" {print $5; exit}')"
    [[ -n "$mac" ]] || mac="$($VIRSH domiflist "$name" 2>/dev/null | awk 'NR>2 && NF {print $5; exit}')"
    [[ -n "$mac" ]] || { info "$name: no MAC found on $net — skipping the DHCP reservation"; return 1; }
    "$MAAS" set-mac "$name" "$mac" >/dev/null 2>&1 || true

    # libvirt REQUIRES an IP in a static host definition ("Missing IP address in static
    # host definition"), so a mac+name reservation is rejected — which is how the first
    # attempt at this silently added nothing. Derive the subnet from the network itself
    # rather than hardcoding it, and allocate ABOVE the dynamic range (which this lab's
    # setup-pxe-net.sh puts at .10-.99) so a reservation can never collide with a lease.
    gw="$($VIRSH net-dumpxml "$net" 2>/dev/null | sed -nE "s/.*<ip address='([^']+)'.*/\1/p" | head -1)"
    [[ -n "$gw" ]] || { info "$name: could not read $net's gateway — skipping the reservation"; return 1; }
    prefix="${gw%.*}"; ip="$prefix.$((101 + idx))"

    # --live --config: apply to the running network AND persist. Re-adding an existing
    # host is an error rather than a no-op, so a re-run falls through to modify.
    if sudo $VIRSH net-update "$net" add ip-dhcp-host \
           "<host mac='$mac' name='$name' ip='$ip'/>" --live --config >/dev/null 2>&1; then
        info "$name: DHCP reservation on $net ($mac -> $name @ $ip)"
    elif sudo $VIRSH net-update "$net" modify ip-dhcp-host \
           "<host mac='$mac' name='$name' ip='$ip'/>" --live --config >/dev/null 2>&1; then
        info "$name: DHCP reservation updated on $net ($mac -> $name @ $ip)"
    else
        # Not fatal — the PXE chain falls back to the MAC-keyed script — but it is not
        # nothing either, so say what was lost instead of "continuing".
        info "$name: could NOT reserve $ip for $mac on $net. The node will not receive a"
        info "  hostname over DHCP, so the boot chain falls through to maas/\${net0/mac}.ipxe."
    fi
}

# verify_bmc_bindings — prove each node's BMC actuates THAT node before anything trusts it.
#
# The failure this catches cost two full end-to-end runs. VirtualBMC lets two domains
# register on one port; only one binds, the loser sits in `error`, and the winner
# answers IPMI for both. The sibling lab's own `alpine-node` defaults to 6230 — which is
# also node1's port — so every command the control plane sent for node1 was served,
# plausibly and successfully, by a different machine. `manage` verified creds, `power
# status` said "on", `bootdev pxe` and `power on` were accepted, and node1 never booted.
#
# The control plane cannot catch this: the BMC seam is precisely the abstraction that
# hides which machine is on the other end. So it is checked here, where we still know
# this is vbmcd.
verify_bmc_bindings() {
    local name want=() out
    for name in $(fleet_names); do
        load_node "$name"
        want+=("$name:${NODE_BMC_PORT}")
    done
    out="$( ( cd "$VBMC_LAB" && ./vbmc-lab.sh list ) 2>/dev/null )"
    if ! printf '%s\n' "$out" | python3 "$HERE/lib/vbmc_check.py" "${want[@]}"; then
        die "the fleet's BMCs are not wired to the fleet's nodes (see above). Refusing to
continue: every verb from here on would be sent to a machine that answers correctly and
is not the one you asked for — which passes every check and deploys nothing."
    fi
}

# ── preflight: refuse BEFORE the irreversible step ───────────────────────────
#
# `up` step 3 destroys running domains and step 4 runs create-node.sh, whose
#     sudo qemu-img convert -f qcow2 -O qcow2 "$base" "$disk"
# is unconditional: every node's disk is replaced. Until 2026-07-29 the two gates that
# can KILL a run — swtpm absent, a required ROM file absent — did not fire until step 9,
# so a host missing either rewrote three disks, built and started a container, registered
# three BMCs and enrolled the whole fleet, and THEN died. Both answers were available
# before anything was touched. CLAUDE.md: "Refuse BEFORE the irreversible step. A gate
# that fires after the dd is not a gate, it is a post-mortem."
#
# This is deliberately NOT a Terraform-style `plan`:
#   * there is no plan FILE and `up` does not consume one, so it cannot promise that what
#     you read is what will run;
#   * instead `up` calls this function as its FIRST act, and every answer it prints comes
#     from the same helper apply uses (tpm_selects, rom_plan, validate_tpm_selection).
#     A pre-flight that re-derives apply's decisions in a second code path is just a new
#     record able to outlive its subject — the bug class this lab keeps finding.
#   * the interesting half of the state is unplannable by construction anyway: a MAC does
#     not exist until the domain does, the firmware mode is a CONSEQUENCE of give_tpm
#     (hence reconcile_firmware), and BMC port ownership can only be checked against a
#     live vbmcd below the seam (hence verify_bmc_bindings).
#
# So: everything refusable, refused; everything else reported, not predicted.
do_preflight() {
    local name fatal=0 tpm_nodes=() plan rows=() model fw tpm romcol port

    step "preflight — checking everything that can refuse this run BEFORE any disk is rewritten"

    # ---- 1. config gates (no host, no libvirt: a typo is reported first) ----
    validate_tpm_selection
    for name in $(fleet_names); do
        tpm_selects "$name" && tpm_nodes+=("$name")
    done
    warn_blanket_tpm

    # ---- 2. host capability gates, in the order they would have killed the run ----
    if (( ${#tpm_nodes[@]} > 0 )); then
        require_swtpm "$(IFS=,; printf '%s' "${tpm_nodes[*]}")"
        info "swtpm present ($(command -v swtpm)) — required by: ${tpm_nodes[*]}"
    fi

    for name in $(fleet_names); do
        load_node "$name"
        model="${NODE_NIC_MODEL:-$FLEET_NIC_MODEL}"
        plan="$(rom_plan "$name" "$model")"
        case "$plan" in
            missing:no-default-for-model)
                info "$name: FLEET_NIC_ROM=1 but no default ROM name for NIC model '$model' — give FLEET_NIC_ROM=<path>"
                fatal=1; romcol="MISSING" ;;
            missing:*)
                info "$name: the verifying ROM ${plan#missing:} does not exist. Build and install it:"
                info "    ./build-verifying-rom.sh build && ./build-verifying-rom.sh install"
                fatal=1; romcol="MISSING" ;;
            attach:*)             romcol="$(basename "${plan#attach:}")" ;;
            none:uefi-node)       romcol="none (UEFI)" ;;
            none:opted-out)       romcol="none (opted out)" ;;
            none:not-installed)   romcol="none (not installed)" ;;
            *)                    romcol="none" ;;
        esac
        fw=bios; tpm=no
        if tpm_selects "$name"; then fw=uefi; tpm=yes; fi
        rows+=("$(printf '%-7s %-5s %-4s %-8s %-6s %-14s %s' \
            "$name" "$fw" "$tpm" "${NODE_MEMORY_MB}MiB" "${NODE_DISK_SIZE}" \
            "${NODE_NETWORK}:${NODE_BMC_PORT}" "$model / $romcol")")
    done

    # A fleet where some nodes verify and some do not is worse than one where none do,
    # because a green run then proves neither. Report every offender, then refuse once.
    (( fatal == 0 )) || die "preflight refused this run — nothing was created and no disk was touched.
  Fix the item(s) above and re-run. This is the whole point of the check: the same
  failure at step 9 would have cost you every node's disk first."

    [[ -d "$VBMC_LAB" ]] || die "sibling lab not found: $VBMC_LAB (set VBMC_LAB=)"
    $VIRSH version >/dev/null 2>&1 \
        || die "cannot reach libvirt at qemu:///system ($VIRSH version failed). \`up\` needs it
  to define every domain; without it nothing below step 2 can work."

    # ---- 3. reports, NOT gates ----
    # Console: give_console degrades to the pty on failure rather than dying, but a pty
    # console keeps nothing when no one is attached and every health gate greps the log,
    # so a run with no recorded console is blind rather than broken. Worth saying early.
    if [[ "$FLEET_CONSOLE" != file ]]; then
        info "FLEET_CONSOLE=$FLEET_CONSOLE — consoles stay ptys and are NOT recorded; every"
        info "  health gate that greps a console log will time out. Unset it for file consoles."
    elif [[ ! -d "$CONSOLE_DIR" ]]; then
        info "$CONSOLE_DIR does not exist yet — give_console will create it with sudo"
    fi
    # Ports are reported and never gated: on a re-run OUR OWN vbmcd already holds
    # 6230–6232, so refusing on "in use" would refuse the normal case. Whether the
    # listener is the right BMC for the right node is an identity question that can only
    # be answered below the seam, against a live vbmcd — verify_bmc_bindings, step 7.
    for name in $(fleet_names); do
        load_node "$name"; port="${NODE_BMC_PORT}"
        if [[ -n "$(ss -lntH "sport = :$port" 2>/dev/null)" ]]; then
            info "port $port ($name) is already listening — expected if a fleet is up; identity is"
            info "  checked after vbmcd starts (verify_bmc_bindings), not guessed here"
        fi
    done

    # ---- 4. the decisions this run will apply ----
    printf '\n  %-7s %-5s %-4s %-8s %-6s %-14s %s\n' \
        NODE FIRM TPM MEMORY DISK NET:BMC 'NIC / ROM' >&2
    printf '  %s\n' "${rows[@]}" >&2
    printf '\n' >&2
    step "preflight passed: ${#rows[@]} nodes, nothing refused. \`up\` will now DESTROY and rewrite every node disk."
}

# ── up: author-run rootful bring-up ──────────────────────────────────────────
do_up() {
    # Step 0, deliberately: every gate that can refuse this run fires here, before the
    # first `qemu-img convert`. do_preflight is the same code, not a second opinion.
    do_preflight

    step "building the vbmcd image (rootful podman) — one container hosts all BMCs"
    ( cd "$VBMC_LAB" && ./vbmc-lab.sh build ) || die "vbmc build failed"

    local name
    # STOP ANY RUNNING FLEET DOMAIN FIRST. create-node.sh rewrites the node's disk with
    # `qemu-img convert` BEFORE it destroys the domain, so a node still running from an
    # earlier attempt holds a write lock and the convert fails:
    #     qemu-img: ... error while converting qcow2: Failed to get "write" lock
    # A fleet run that ends on a health-gate failure leaves its nodes powered on, so the
    # NEXT `up` hits this every time. Use the lifecycle verb, and only on domains this
    # fleet owns.
    for name in $(fleet_names); do
        if [[ "$($VIRSH domstate "$name" 2>/dev/null)" == running ]]; then
            info "$name is still running from an earlier attempt — stopping it so its disk can be rewritten"
            $VIRSH destroy "$name" >/dev/null 2>&1 \
                || sudo $VIRSH destroy "$name" >/dev/null 2>&1 \
                || die "'$name' is running and could not be stopped; its disk is write-locked and create-node.sh would fail. Stop it by hand: virsh -c qemu:///system destroy $name"
        fi
    done
    for name in $(fleet_names); do
        load_node "$name"
        step "creating libvirt domain '$name' (${NODE_MEMORY_MB}MiB, disk ${NODE_DISK_SIZE}, net ${NODE_NETWORK})"
        ( cd "$VBMC_LAB" && \
          NODE="$name" MEMORY_MB="${NODE_MEMORY_MB:-4096}" DISK_SIZE="${NODE_DISK_SIZE:-10G}" \
          NET="${NODE_NETWORK:-default}" NIC_MODEL="${NODE_NIC_MODEL:-$FLEET_NIC_MODEL}" ./create-node.sh ) \
            || die "create-node $name failed"
    done

    step "starting vbmcd"
    ( cd "$VBMC_LAB" && ./vbmc-lab.sh up ) || die "vbmc up failed"


    for name in $(fleet_names); do
        load_node "$name"
        step "registering BMC for '$name' on port ${NODE_BMC_PORT}"
        ( cd "$VBMC_LAB" && NODE="$name" PORT="${NODE_BMC_PORT}" ./vbmc-lab.sh add ) \
            || die "vbmc add $name failed"
    done

    step "verifying each node OWNS its BMC port (not a squatter's)"
    verify_bmc_bindings

    step "enrolling the fleet into the control plane"
    do_enroll

    # AFTER enroll: both of these record something in the node's registry entry, which
    # does not exist until the node is enrolled.
    step "instrumenting the fleet: recorded consoles + DHCP reservations"
    local i=0
    for name in $(fleet_names); do
        load_node "$name"
        give_console "$name"
        # Resolve the model HERE, not inside rom_plan: load_node evals only the keys a
        # node declares, so an undeclared nic_model still holds the previous node's value.
        give_verifying_rom "$name" "${NODE_NIC_MODEL:-$FLEET_NIC_MODEL}"
        give_tpm "$name"
        reconcile_firmware "$name"   # AFTER give_tpm: it is what changes the answer
        reserve_dhcp "$name" "${NODE_NETWORK:-vbmc-pxe}" "$i"
        i=$((i+1))
    done

    step "fleet up. Verify a BMC round-trip:  $MAAS manage node1 && $MAAS power node1 status"
    info "next: ./netboot-chain.sh install — without it every node boots the network's"
    info "baked payload and the per-node scripts the drivers write are never fetched."
}

# ── down: author-run teardown ────────────────────────────────────────────────
do_down() {
    [[ -d "$VBMC_LAB" ]] || die "sibling lab not found: $VBMC_LAB"
    local name
    for name in $(fleet_names); do
        step "destroying domain + BMC for '$name'"
        # vbmc-lab.sh destroy is single-node (NODE env); loop it. It stops the
        # container on the first call, so subsequent calls just undefine domains.
        ( cd "$VBMC_LAB" && NODE="$name" ./vbmc-lab.sh destroy ) || info "(teardown of $name reported an issue — continuing)"
    done
    info "fleet domains + BMCs town down. Registry state kept under the MAAS state dir."
    info "disk images under /var/lib/libvirt/images/ are left for you to remove (F7):"
    for name in $(fleet_names); do
        printf '    sudo rm -f /var/lib/libvirt/images/%s.qcow2 /var/lib/libvirt/images/%s-seed.iso\n' "$name" "$name" >&2
    done
}

usage() {
    cat >&2 <<EOF
create-fleet.sh — stand up / enroll the MAAS fleet from fleet.toml ($FLEET_TOML)

  enroll     HEADLESS: register the fleet into maas-lab.sh (no libvirt/root) — increment-1 path
  preflight  check everything that can refuse an \`up\` and print the decisions it will
             apply, WITHOUT creating anything. \`up\` runs this as its first step, so what
             you read here is what runs — it is not a second implementation of it.
  up         AUTHOR-RUN (rootful): create 3 libvirt domains + vbmcd + BMCs on 6230–6232, then enroll
  down       AUTHOR-RUN: tear the fleet down
  status     show the fleet (maas-lab.sh list)

Wraps the sibling anchor: $VBMC_LAB (override with VBMC_LAB=).
EOF
}

case "${1:-}" in
    enroll)        do_enroll ;;
    preflight)     do_preflight ;;
    _firmware-of-xml) firmware_of_xml ;;   # stdin XML -> bios|uefi (testable, no libvirt)
    # Internal: the ROM decision for one node, without acting on it. Same seam as
    # _selects-tpm — lets a test assert what `up` would attach with no libvirt and no root.
    _rom-plan)     [[ -n "${2:-}" ]] || die "_rom-plan needs a node name"
                   rom_plan "$2" "${3:-$FLEET_NIC_MODEL}" ;;
    up)            do_up ;;
    down)          do_down ;;
    status|list)   "$MAAS" list ;;
    # Internal, for tests and for asking "would this run give node X a TPM?" without
    # building anything. Exits 0 when FLEET_TPM selects the node, 1 when it does not.
    _selects-tpm)  [[ -n "${2:-}" ]] || die "_selects-tpm needs a node name"
                   tpm_selects "$2" ;;
    _check-tpm)    validate_tpm_selection && printf 'FLEET_TPM=%s is valid for this fleet\n' "${FLEET_TPM:-0}" ;;
    ""|-h|--help)  usage ;;
    *) die "unknown mode '$1' (enroll|preflight|up|down|status)" ;;
esac

#!/usr/bin/env bash
# build-verifying-rom.sh — build the NIC firmware that can actually enforce F2.
#
# THE GAP THIS CLOSES. Payload signing (F2) is a CHAIN with two links:
#
#   host-side   `maas-lab.sh verify` / the drivers' gate — OpenSSL CMS against
#               the CA, on the control plane, BEFORE the node is touched.
#   on-node     `imgverify` inside the iPXE script — the firmware re-checks each
#               payload as it fetches it, AFTER the control plane is out of the
#               picture.
#
# Only the first has ever run on this fleet. QEMU's stock iPXE ROM (what a libvirt
# NIC boots by default) is compiled WITHOUT IMAGE_TRUST_CMD, so `imgverify` is an
# unknown command: the script aborts, nothing boots, and — because that ROM has no
# serial console either — it does so with ZERO bytes in the console log. That is
# why every green run so far has set E2E_NO_IMGVERIFY=1, and why a run that says
# "signed payloads verified" is today making half the claim it appears to make.
#
# This script builds the other half: an iPXE PCI option ROM with
#   * IMAGE_TRUST_CMD   -> `imgverify` exists
#   * TRUST=<our ca.der> -> and accepts ONLY signatures chaining to this fleet's CA
#   * CONSOLE_SERIAL    -> and says so on COM1, which is the node's console log
#   * the netboot-chain script compiled in, so the firmware asks the control plane
#     what to boot instead of carrying an answer.
#
# ON THAT SERIAL CONSOLE, and why it is not redundant. A libvirt domain's console
# log carries the guest's COM1 and nothing else: this fleet's own node1.log begins
# at "Linux version ..." and contains not one SeaBIOS or iPXE line. Everything the
# firmware said during the boot that PRODUCED that kernel was lost. So the ROM has
# to drive the port itself.
#   Beware the harness, though: `qemu -nographic` sets FW_CFG_NOGRAPHIC, SeaBIOS
# then puts ITS console on COM1 too, and a CONSOLE_SERIAL build there has two
# writers whose bytes interleave ("iiPPXXEE"). Under -nographic the stock ROM looks
# like it has a serial console and this one looks broken — the exact opposite of
# the truth on the fleet. Test with `-display none -serial ...`, as libvirt runs it.
#
# WHAT IT IS NOT. A ROM attached by libvirt XML is not a hardware root of trust —
# anyone who can edit the domain can swap it, and the same person could edit the
# CA. It is a faithful STAND-IN for one (a real fleet flashes the ROM and locks it,
# or uses the platform's Secure Boot chain). What it does prove honestly is the
# thing the lab claims and cannot currently demonstrate: that the MACHINE refuses a
# payload the fleet did not sign, with the control plane no longer in the loop.
#
# Verbs:
#   build     build the ROM (docker; several minutes) into the lab state dir
#   install   copy it where libvirt's qemu can READ it (sudo; /var/lib/libvirt)
#   show      print what is built/installed and the XML that attaches it
#
# Knobs (env): MAAS_IMAGES_DIR  MAAS_ROM_DIR  FLEET_NIC_MODEL  MAAS_NETBOOT_PORT
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../.." && pwd)"

# WHERE THE CA IS. Not where you would guess: maas-lab.sh's registry lives under
# $XDG_STATE_HOME/lab-create/metal-as-a-service, but the signed payloads and the trust
# root do NOT — run-e2e.sh:42 exports MAAS_IMAGES_DIR=~/.cache/lab-create/maas/images and
# that is what every driver has actually used. This mirrors THAT, because the CA baked
# into the ROM must be the one the drivers sign with; guessing the registry's root
# instead would bake a CA nothing signs with and every node would refuse every payload.
IMAGES_DIR="${MAAS_IMAGES_DIR:-$HOME/.cache/lab-create/maas/images}"
BUILD_DIR="${MAAS_ROM_BUILD_DIR:-$(dirname -- "$IMAGES_DIR")/ipxe}"

# ⚠️ ~/.cache is, by its own contract, a directory anything may delete — a cleaner, a
# `rm -rf ~/.cache`, an operator reclaiming disk. The fleet's SIGNING KEY lives there.
# Losing it is recoverable (re-mint, re-sign, rebuild this ROM) but silent until a
# deploy fails, so it is noted here and in DEFERRED.md rather than left to be discovered.

# WHERE THE ROM MUST LIVE. qemu runs as its own user under qemu:///system and
# reads romfile= itself. $HOME is 0750 and ~/.cache is 0700 here, so a ROM left in
# the state dir is unreadable to it and the domain fails to start with a bare
# "Permission denied" naming a path that plainly exists. /var/lib/libvirt is the
# same answer create-fleet.sh's give_console already reached for the console log.
ROM_DIR="${MAAS_ROM_DIR:-/var/lib/libvirt/maas-rom}"

NIC_MODEL="${FLEET_NIC_MODEL:-e1000}"
case "$NIC_MODEL" in
    e1000)   NIC_ID=8086100e ;;
    virtio)  NIC_ID=1af41000 ;;
    rtl8139) NIC_ID=10ec8139 ;;
    *) printf 'build-verifying-rom: no PCI id known for FLEET_NIC_MODEL=%s\n' "$NIC_MODEL" >&2; exit 1 ;;
esac
ROM_NAME="ipxe-${NIC_ID}.rom"

die()  { printf 'build-verifying-rom: %s\n' "$*" >&2; exit 1; }
info() { printf '  - %s\n' "$*" >&2; }
step() { printf '\n== %s\n' "$*" >&2; }

xml_snippet() {
    cat <<EOF
    <interface type='network'>
      <source network='vbmc-pxe'/>
      <model type='$NIC_MODEL'/>
      <rom file='$ROM_DIR/$ROM_NAME'/>
    </interface>
EOF
}

case "${1:-}" in

build)
    step "checking inputs"
    ca_crt="$IMAGES_DIR/trust/ca.crt"
    [[ -f "$ca_crt" ]] || die "no CA at $ca_crt — run 'maas-lab.sh stage' (or drivers/verify-lib.sh gen-keys) first.
  The ROM is built AROUND this CA: without it there is nothing for imgverify to trust."
    command -v openssl >/dev/null || die "openssl is required to convert the CA to DER"
    command -v docker  >/dev/null || die "docker is required (netboot/build-ipxe.sh builds iPXE in a container)"
    docker info >/dev/null 2>&1   || die "the docker daemon is not reachable — start it, or add yourself to the docker group"

    mkdir -p "$BUILD_DIR" || die "could not create $BUILD_DIR"

    # iPXE's TRUST= wants DER; verify-lib.sh/sign-payload.sh mint PEM. Converting
    # here (rather than asking the operator for a ca.der that does not exist) keeps
    # ONE CA in the lab: the same file the host-side gate verifies against.
    step "converting the fleet CA to DER (iPXE TRUST= takes DER, the lab keeps PEM)"
    ca_der="$BUILD_DIR/ca.der"
    openssl x509 -in "$ca_crt" -outform DER -out "$ca_der" \
        || die "could not convert $ca_crt to DER"
    info "$ca_der  ($(stat -c%s "$ca_der") bytes) <- $ca_crt"
    info "subject: $(openssl x509 -in "$ca_crt" -noout -subject 2>/dev/null | sed 's/^subject=//')"

    step "taking the boot script from netboot-chain.sh (one source of truth)"
    embed="$BUILD_DIR/embed.ipxe"
    "$HERE/netboot-chain.sh" emit-chain > "$embed" \
        || die "netboot-chain.sh emit-chain failed"
    head -1 "$embed" | grep -q '^#!ipxe' \
        || die "netboot-chain.sh emit-chain did not produce an iPXE script"
    info "$embed ($(wc -l < "$embed") lines) — resolves maas/\${hostname}.ipxe on the node"

    step "building iPXE + option ROM for $NIC_MODEL ($NIC_ID) — several minutes"
    "$REPO_ROOT/netboot/build-ipxe.sh" \
        --output-dir "$BUILD_DIR" \
        --nic-rom "$NIC_ID" \
        --imgverify \
        --payload-trust "$ca_der" \
        --embed-script "$embed" \
        --serial-console \
        || die "build-ipxe.sh failed — see the log above"

    [[ -f "$BUILD_DIR/$ROM_NAME" ]] || die "the build reported success but $BUILD_DIR/$ROM_NAME is missing"
    step "built"
    info "$BUILD_DIR/$ROM_NAME ($(stat -c%s "$BUILD_DIR/$ROM_NAME") bytes)"
    info "next: $0 install     (sudo — qemu cannot read \$HOME)"
    ;;

install)
    src="$BUILD_DIR/$ROM_NAME"
    [[ -f "$src" ]] || die "no ROM at $src — run '$0 build' first"
    command -v sudo >/dev/null || die "sudo required to write $ROM_DIR"
    sudo mkdir -p "$ROM_DIR" && sudo chmod 0755 "$ROM_DIR" || die "could not create $ROM_DIR"
    sudo cp -f "$src" "$ROM_DIR/$ROM_NAME" || die "could not install the ROM"
    # 0644: qemu reads it as another user. A ROM it cannot read is a domain that
    # will not start, reported as a permission error on a path that exists.
    sudo chmod 0644 "$ROM_DIR/$ROM_NAME" || die "could not chmod the installed ROM"
    info "installed: $ROM_DIR/$ROM_NAME"
    info "attach it with FLEET_NIC_ROM=$ROM_DIR/$ROM_NAME ./create-fleet.sh, or by hand:"
    xml_snippet >&2
    ;;

show)
    printf '== built ==\n'
    if [[ -f "$BUILD_DIR/$ROM_NAME" ]]; then
        printf '%s (%s bytes)\n' "$BUILD_DIR/$ROM_NAME" "$(stat -c%s "$BUILD_DIR/$ROM_NAME")"
    else
        printf '(none — run %s build)\n' "$0"
    fi
    printf '\n== installed ==\n'
    if [[ -f "$ROM_DIR/$ROM_NAME" ]]; then
        ls -l "$ROM_DIR/$ROM_NAME"
    else
        printf '(none — run %s install)\n' "$0"
    fi
    printf '\n== attaches as ==\n'
    xml_snippet
    ;;

*)
    cat >&2 <<EOF
build-verifying-rom.sh — build NIC firmware that can enforce F2 on the node

  build     build an iPXE option ROM for $NIC_MODEL ($NIC_ID) with imgverify,
            this fleet's CA as its ONLY trust root, a serial console, and the
            netboot-chain script compiled in           (docker; minutes)
  install   copy it to $ROM_DIR, where qemu can read it   (sudo)
  show      print what is built/installed and the XML that attaches it

Why: the stock ROM has no IMAGE_TRUST_CMD, so the on-node half of F2 has never
run — see DEFERRED.md item 1.

  state dir: $STATE_ROOT
  build dir: $BUILD_DIR
  CA:        $IMAGES_DIR/trust/ca.crt
EOF
    exit 2 ;;
esac

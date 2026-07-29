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

# WHERE THE CA IS. Asked of maas-lab.sh (`_images-dir`), never re-derived: the CA
# baked into this ROM must be the one the drivers sign with, and the only way to be
# sure is to ask the script that owns the answer. This file used to mirror
# run-e2e.sh's ~/.cache default instead — and that split (cache here, state root in
# maas-lab.sh) let a bare `maas-lab.sh apply` read a store that did not exist.
# The store now lives under the state root, where a signing key belongs (~/.cache
# is by contract deletable — and WAS deleted mid-session once, taking the fleet's
# whole signing chain with it).
IMAGES_DIR="${MAAS_IMAGES_DIR:-$("$HERE/maas-lab.sh" _images-dir)}"
[[ -n "$IMAGES_DIR" ]] || { echo "build-verifying-rom: maas-lab.sh _images-dir returned nothing" >&2; exit 1; }
# The ROM build tree is a rebuildable artifact, so ~/.cache IS its right home —
# unlike the keys, deleting it costs only a rebuild.
BUILD_DIR="${MAAS_ROM_BUILD_DIR:-$HOME/.cache/lab-create/maas/ipxe}"

# WHERE THE ROM MUST LIVE. qemu runs as its own user under qemu:///system and
# reads romfile= itself. $HOME is 0750 and ~/.cache is 0700 here, so a ROM left in
# the state dir is unreadable to it and the domain fails to start with a bare
# "Permission denied" naming a path that plainly exists. /var/lib/libvirt is the
# same answer create-fleet.sh's give_console already reached for the console log.
ROM_DIR="${MAAS_ROM_DIR:-/var/lib/libvirt/maas-rom}"

# WHERE THE UEFI BINARY MUST LIVE. A UEFI node has no option ROM to attach: its
# firmware TFTPs a PE binary from the network's TFTP root, so `ipxe.efi` goes there
# rather than beside the .rom. Same default as netboot-chain.sh, which owns that
# directory's other contents.
TFTP_DIR="${TFTP_DIR:-/var/lib/libvirt/tftp-vbmc}"
EFI_NAME="${MAAS_EFI_NAME:-ipxe.efi}"

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

# check_efi <file> — is this UEFI binary one that ENFORCES, or just one that boots?
#
# THE MISTAKE THIS EXISTS TO CATCH, which was live in this lab's own notes.
# DEFERRED.md said the UEFI binary was "already built, at ~/netboot/ipxe.efi". That
# file is the RAM-infra lab's generic build: no IMAGE_TRUST_CMD, no fleet CA. TFTP it
# to the measured node and everything goes green — the node boots, deploys, attests —
# while the firmware half of F2 has silently been switched off on the one node whose
# entire purpose is proving a machine refuses what the fleet did not sign. Nothing
# downstream can see the difference; only this check can.
#
# It works by reading the binary, because a claim about provenance ("I built it with
# the right flags") is not evidence about the bytes on disk.
#
# HOW THE CA IS ACTUALLY IN THERE — measured, because the first version of this
# function guessed and was wrong. iPXE's TRUST= does NOT embed the certificate: it
# embeds the SHA-256 **fingerprint** of it (crypto/rootcert.c). So searching for the
# CA's subject, or for its DER, finds nothing in a perfectly good binary. The
# fingerprint is better evidence anyway — 32 exact bytes rather than a string that
# might appear for some unrelated reason. In this fleet's own binary it sits at
# offset 976512; in ~/netboot/ipxe.efi it is absent, which is the whole point.
#
# EFI ONLY, and honestly so: the option ROM is compressed, so every one of these
# searches comes up empty on a ROM that works perfectly. A negative there would mean
# nothing at all, so this is never asked of the .rom.
check_efi() {
    local f="$1"
    [[ -f "$f" ]] || { printf 'no such file: %s\n' "$f" >&2; return 1; }
    python3 - "$f" "$IMAGES_DIR/trust/ca.crt" <<'PY'
import base64, hashlib, sys

blob = open(sys.argv[1], "rb").read()
problems = []

if b"imgverify" not in blob:
    problems.append(
        "imgverify is NOT compiled into this binary.\n"
        "    A node booting it would treat every imgverify line as an unknown command,\n"
        "    abort the boot script, and boot nothing — or boot a payload nobody checked.")

try:
    pem = open(sys.argv[2]).read()
    b64 = "".join(l for l in pem.splitlines() if "-----" not in l)
    der = base64.b64decode(b64)
except Exception as e:                       # noqa: BLE001 - any failure is "cannot tell"
    problems.append(f"could not read the fleet CA ({sys.argv[2]}): {e}")
else:
    fp = hashlib.sha256(der).digest()
    if fp not in blob:
        problems.append(
            f"this fleet's CA fingerprint ({fp.hex()[:16]}...) is NOT in this binary.\n"
            "    iPXE's TRUST= embeds the SHA-256 of each trusted root; its absence means\n"
            "    the firmware trusts some other root, or none. This is exactly the\n"
            "    ~/netboot/ipxe.efi mix-up: a binary that boots fine and verifies nothing.")

for p in problems:
    print(f"  - {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
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
    # AppArmor: virt-aa-helper builds each domain's profile from its XML but does NOT
    # parse <rom file=>, so the ROM path is never whitelisted and qemu's read is denied.
    # The failure is maximally misleading: the domain dies with "failed to find romfile"
    # on a file that exists and is world-readable, and the deny is silent — no DENIED
    # line in any log (found live, first fleet run with the ROM attached). The stock
    # abstraction's last line is `include if exists <local/abstractions/libvirt-qemu>`,
    # the supported host-level override; per-domain profiles are recompiled at every
    # domain start, so the rule takes effect on the next boot with no daemon reload.
    aa_abstraction=/etc/apparmor.d/abstractions/libvirt-qemu
    aa_local=/etc/apparmor.d/local/abstractions/libvirt-qemu
    aa_rule="\"$ROM_DIR/*.rom\" r,"
    if [[ -f "$aa_abstraction" ]] && grep -q 'local/abstractions/libvirt-qemu' "$aa_abstraction"; then
        if sudo grep -qsF "$aa_rule" "$aa_local"; then
            info "AppArmor: $aa_local already allows $ROM_DIR/*.rom"
        else
            sudo mkdir -p "$(dirname "$aa_local")" \
                && printf '  %s\n' "$aa_rule" | sudo tee -a "$aa_local" >/dev/null \
                || die "could not write $aa_local — without it qemu is denied the ROM and
the domain fails to start with 'failed to find romfile' (no denial is logged)"
            info "AppArmor: allowed qemu to read $ROM_DIR/*.rom (rule in $aa_local;"
            info "  virt-aa-helper does not parse <rom file=>, so the per-domain profile"
            info "  never whitelists it — without this the domain cannot start)"
        fi
    fi
    info "attach it with FLEET_NIC_ROM=$ROM_DIR/$ROM_NAME ./create-fleet.sh, or by hand:"
    xml_snippet >&2
    info "for a UEFI node (image+measured), also: $0 install-efi"
    ;;

check-efi)
    # Exposed as a verb so netboot-chain.sh can ask the question without duplicating
    # the answer, and so an operator can interrogate any stray binary.
    f="${2:-$BUILD_DIR/$EFI_NAME}"
    if check_efi "$f"; then
        info "$f: imgverify present, this fleet's CA embedded — it ENFORCES"
    else
        die "$f does not enforce F2 (see above). Build it: $0 build"
    fi
    ;;

install-efi)
    # The UEFI counterpart of `install`. Same build, different delivery: a UEFI node
    # has no option ROM slot, so the firmware fetches this binary over TFTP instead.
    src="$BUILD_DIR/$EFI_NAME"
    [[ -f "$src" ]] || die "no UEFI binary at $src — run '$0 build' first.
  (netboot/build-ipxe.sh emits ipxe.efi from the SAME build as the option ROM, so a
  successful 'build' has already produced it.)"

    # Refuse BEFORE the copy. Installing a non-enforcing binary is worse than
    # installing nothing: nothing fails, and the firmware half of F2 is off.
    if ! check_efi "$src"; then
        # The escape hatch exists because the check reads the binary, and a future
        # iPXE that compresses its EFI image would fail it while being perfectly
        # good. It is deliberately loud: this is the one knob here that can turn the
        # firmware half of F2 off without anything else noticing.
        [[ "${MAAS_EFI_TRUST_UNCHECKED:-0}" == 1 ]] || die "refusing to install $src — it does not enforce F2 (above).
  MAAS_EFI_TRUST_UNCHECKED=1 skips this check, but understand what it buys: the
  measured node would boot, deploy and attest with NO firmware-side signature
  verification at all, and every run would still be green."
        printf 'build-verifying-rom: WARNING — installing %s with the enforcement check OVERRIDDEN.\n' "$src" >&2
        printf '  The on-node half of F2 may be off on every UEFI node. Nothing downstream will say so.\n' >&2
    fi
    command -v sudo >/dev/null || die "sudo required to write $TFTP_DIR"
    sudo mkdir -p "$TFTP_DIR" || die "could not create $TFTP_DIR"
    sudo cp -f "$src" "$TFTP_DIR/$EFI_NAME" || die "could not install the UEFI binary"
    # 0644: dnsmasq's TFTP server reads it as another user, exactly as qemu reads the ROM.
    sudo chmod 0644 "$TFTP_DIR/$EFI_NAME" || die "could not chmod $TFTP_DIR/$EFI_NAME"
    info "installed: $TFTP_DIR/$EFI_NAME ($(stat -c%s "$src") bytes) — imgverify + this fleet's CA"
    info "next: ./netboot-chain.sh install-uefi   (teaches the network to offer it to"
    info "  UEFI clients only; without that step nothing ever fetches this file)"
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
    printf '\n== UEFI (image+measured; TFTP, not an option ROM) ==\n'
    if [[ -f "$BUILD_DIR/$EFI_NAME" ]]; then
        printf 'built:     %s (%s bytes) — ' "$BUILD_DIR/$EFI_NAME" "$(stat -c%s "$BUILD_DIR/$EFI_NAME")"
        if check_efi "$BUILD_DIR/$EFI_NAME" 2>/dev/null; then printf 'ENFORCES\n'; else printf 'does NOT enforce F2\n'; fi
    else
        printf 'built:     (none — run %s build)\n' "$0"
    fi
    if [[ -f "$TFTP_DIR/$EFI_NAME" ]]; then
        printf 'installed: %s\n' "$TFTP_DIR/$EFI_NAME"
    else
        printf 'installed: (none — run %s install-efi)\n' "$0"
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

  install-efi  copy the UEFI binary from the SAME build into the network's TFTP
               root ($TFTP_DIR), for nodes that boot UEFI —
               which the measured driver requires, because a BIOS firmware
               measures no payload. Refuses a binary that does not enforce. (sudo)
  check-efi [FILE]  does that binary carry imgverify AND this fleet's CA? Reads
               the bytes; a build log's word for it is not evidence.

  show      print what is built/installed and the XML that attaches it

Why: the stock ROM has no IMAGE_TRUST_CMD, so the on-node half of F2 has never
run — see DEFERRED.md item 1.

  state dir: $STATE_ROOT
  build dir: $BUILD_DIR
  CA:        $IMAGES_DIR/trust/ca.crt
EOF
    exit 2 ;;
esac

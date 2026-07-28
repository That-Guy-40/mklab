#!/usr/bin/env bash
# build-ipxe.sh — Build iPXE from source inside Docker and package outputs.
#
# The build runs inside a Debian bookworm container so the host is not
# polluted with compiler toolchains.  After Docker exits the USB image is
# converted to qcow2 for Phase 2 QEMU booting.
#
# Usage:
#   netboot/build-ipxe.sh \
#       --server http://10.0.2.2:8181 \
#       [--kernel-path /kernel] \
#       [--initrd-path /initrd.gz] \
#       [--append "console=ttyS0 root=/dev/ram0 rw"] \
#       [--output-dir /srv/netboot] \
#       [--arch x86_64|aarch64] \
#       [--ipxe-ref master]
#
# Outputs (in --output-dir):
#   boot.ipxe     plain-text iPXE boot script — served via TFTP for a native iPXE
#                 NIC ROM to run directly, and embedded in the .pxe/.efi binaries
#   ipxe.usb      raw disk image  →  dd if=ipxe.usb of=/dev/sdX
#   ipxe.efi      UEFI binary     →  copy to EFI partition
#   ipxe.qcow2    qcow2 of usb   →  Phase 2 QEMU -drive file=ipxe.qcow2
#
# Requires:
#   docker   (running daemon)
#   qemu-img (for qcow2 conversion; skipped with a warning if absent)
#
# Examples:
#   # QEMU slirp simulation (host is 10.0.2.2 from inside the guest):
#   netboot/build-ipxe.sh --server http://10.0.2.2:8181
#
#   # Real hardware on LAN:
#   netboot/build-ipxe.sh --server http://192.168.1.10:8181 --arch x86_64

set -euo pipefail

readonly LAB_PROG="${0##*/}"
# Resolve the directory containing this script so we can pass it into Docker
# even when called from a different working directory.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR

# ─── Logging ────────────────────────────────────────────────────────────────
_log() {
    local level="$1"; shift
    local color reset
    if [[ -t 2 ]]; then
        case "$level" in
            info)  color=$'\033[36m' ;;
            warn)  color=$'\033[33m' ;;
            error) color=$'\033[31m' ;;
            *)     color='' ;;
        esac
        reset=$'\033[0m'
    else
        color=""; reset=""
    fi
    printf '%s[%s]%s %s\n' "$color" "$level" "$reset" "$*" >&2
}
log_info()  { _log info  "$@"; }
log_warn()  { _log warn  "$@"; }
log_error() { _log error "$@"; }
die()       { _log error "$@"; exit 1; }

# ─── Usage ──────────────────────────────────────────────────────────────────
usage() {
    cat >&2 <<'EOF'
Usage: netboot/build-ipxe.sh [OPTIONS]

Build iPXE from source inside a Debian Docker container and produce USB,
EFI, and qcow2 boot images along with a plain-text boot.ipxe script.

Options:
  --server      URL   HTTP server seen by the booting machine
                      (default: http://10.0.2.2:8181  — QEMU slirp host)
  --kernel-path PATH  URL path to the kernel   (default: /kernel)
  --initrd-path PATH  URL path to the initrd   (default: /initrd.gz)
  --append      STR   kernel command-line args  (default: "console=ttyS0 root=/dev/ram0 rw")
                      Use the literal placeholder {MAC} to embed the booting
                      NIC's MAC address at runtime.  At build time {MAC} is
                      rewritten to the iPXE variable ${mac:hexhyp}; iPXE then
                      expands it to the lowercase hyphen-separated MAC of the
                      booting interface (e.g. 52-54-00-a1-9a-01).
                      Example (per-host AlmaLinux kickstart):
                        --append 'inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks'
  --output-dir  PATH  where to write outputs   (default: /srv/netboot)
  --arch        ARCH  x86_64, aarch64, or riscv64  (default: x86_64)
  --ipxe-ref    REF   git branch/tag/SHA to build from (default: master)
  --tls               compile iPXE with HTTPS download support (DOWNLOAD_PROTO_HTTPS)
  --tls-cert    PATH  DER-format cert to embed in iPXE trust store
                      (use the .der from setup-netboot-dir.sh --tls)
  --imgverify         emit a VERIFIED A/B boot script: iPXE verifies each
                      payload's detached CMS signature (imgverify) before boot
                      and rolls back current->previous on failure.  Payloads are
                      served slotted: <server>/<slot>/<file>{,.sig}.  Sign them
                      with netboot/sign-payload.sh.
  --payload-trust PATH  DER code-signing root to bake in for --imgverify
                      (the ca.der emitted by sign-payload.sh --out-trust)
  --nic-rom     ID    also build a PCI option ROM for one NIC (x86_64 only),
                      written as ipxe-<id>.rom.  ID is 8 hex digits
                      (vendor+device, e.g. 8086100e) or an alias:
                        e1000 -> 8086100e   virtio -> 1af41000   rtl8139 -> 10ec8139
                      Attach it to a QEMU/libvirt NIC with <rom file='...'/> to
                      replace the stock firmware ROM, which is built WITHOUT
                      IMAGE_TRUST_CMD and therefore cannot imgverify anything.
  --embed-script PATH use this file verbatim as the compiled-in boot script
                      instead of the one this builder generates.  Needed when the
                      firmware must ask a control plane what to boot rather than
                      carry the answer (see examples/metal-as-a-service/).
  --serial-console    compile in CONSOLE_SERIAL (COM1, 115200 8N1) so iPXE drives
                      the serial port ITSELF, rather than relying on the platform
                      to carry the BIOS console there.  Needed under libvirt:
                      measured on a real domain, a <serial> console log starts at
                      the Linux banner and contains no firmware output at all, so
                      without this every iPXE-level failure is a silence.
                      CAVEAT, also measured: `qemu -nographic` sets FW_CFG_NOGRAPHIC
                      and SeaBIOS then mirrors the BIOS console to COM1 too — so in
                      THAT invocation (only) the port has two writers and their
                      bytes interleave ("iPXE" arrives as "iiPPXXEE").  Test a
                      serial-console build with `-display none -serial ...`, which
                      is what libvirt does; never with -nographic.
  --sign              sign the EFI output with netboot/sign-ipxe.sh after building
  --use-snakeoil      sign with the system snakeoil key (QEMU Secure Boot test; not for real hw)
  --sign-key    PATH  custom signing key (PEM) for --sign
  --sign-cert   PATH  custom signing cert (PEM) for --sign
  --help              show this help and exit

Outputs written to --output-dir:
  boot.ipxe   iPXE boot script (TFTP it to a native iPXE NIC ROM, or chainload via .pxe/.efi)
  ipxe.usb    raw USB disk image (dd to a USB stick)
  ipxe.efi    UEFI binary
  ipxe.qcow2  qcow2 conversion of ipxe.usb (Phase 2 QEMU)

Examples:
  netboot/build-ipxe.sh --server http://10.0.2.2:8181
  netboot/build-ipxe.sh --server http://192.168.1.10:8181 --arch aarch64
  netboot/build-ipxe.sh --server http://10.0.2.2:8181 --ipxe-ref v1.21.1
EOF
    exit 0
}

# ─── Defaults ───────────────────────────────────────────────────────────────
server="http://10.0.2.2:8181"
kernel_path="/kernel"
initrd_path="/initrd.gz"
append="console=ttyS0 root=/dev/ram0 rw"
output_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}"
arch="x86_64"
ipxe_ref="master"
tls_mode=""
tls_cert=""
imgverify_mode=""
payload_trust=""
nic_rom=""
embed_script=""
serial_console=""
sign_mode=""
sign_snakeoil=""
sign_key=""
sign_cert=""

# ─── Arg parsing ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)      shift; server="${1:?--server requires a URL}";         shift ;;
        --kernel-path) shift; kernel_path="${1:?--kernel-path requires a path}"; shift ;;
        --initrd-path) shift; initrd_path="${1:?--initrd-path requires a path}"; shift ;;
        --append)      shift; append="${1:?--append requires a string}";      shift ;;
        --output-dir)  shift; output_dir="${1:?--output-dir requires a path}"; shift ;;
        --arch)        shift; arch="${1:?--arch requires x86_64/aarch64/riscv64}"; shift ;;
        --ipxe-ref)    shift; ipxe_ref="${1:?--ipxe-ref requires a git ref}"; shift ;;
        --tls)         tls_mode=1; shift ;;
        --tls-cert)    shift; tls_cert="${1:?--tls-cert requires a DER file}"; shift ;;
        --imgverify)   imgverify_mode=1; shift ;;
        --payload-trust) shift; payload_trust="${1:?--payload-trust requires a DER file}"; shift ;;
        --nic-rom)     shift; nic_rom="${1:?--nic-rom requires a PCI id or alias}";   shift ;;
        --embed-script) shift; embed_script="${1:?--embed-script requires a file}";   shift ;;
        --serial-console) serial_console=1; shift ;;
        --sign)        sign_mode=1; shift ;;
        --use-snakeoil) sign_mode=1; sign_snakeoil=1; shift ;;
        --sign-key)    shift; sign_key="${1:?--sign-key requires a PEM file}"; shift ;;
        --sign-cert)   shift; sign_cert="${1:?--sign-cert requires a PEM file}"; shift ;;
        --help|-h) usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

# ─── Validate arch ──────────────────────────────────────────────────────────
case "$arch" in
    x86_64|aarch64|riscv64) ;;
    *) die "unsupported arch '$arch': choose x86_64, aarch64, or riscv64" ;;
esac
if [[ -n "$tls_cert" && ! -r "$tls_cert" ]]; then
    die "--tls-cert file not readable: $tls_cert"
fi
if [[ -n "$payload_trust" && ! -r "$payload_trust" ]]; then
    die "--payload-trust file not readable: $payload_trust"
fi
if [[ -n "$embed_script" && ! -r "$embed_script" ]]; then
    die "--embed-script file not readable: $embed_script"
fi
# A compiled-in script that iPXE cannot recognise is a silent brick: iPXE runs it,
# fails to parse the first line, and drops to the BIOS boot order.  Refuse here,
# where the file is still in front of a human, rather than on the machine.
if [[ -n "$embed_script" ]] && ! head -1 "$embed_script" | grep -q '^#!ipxe'; then
    die "--embed-script '$embed_script' does not start with '#!ipxe' — iPXE would not run it as a script"
fi
# Resolve the NIC alias to the vendor+device the ROM must claim.  iPXE names the
# target after the PCI ID it registers for; a ROM built for the wrong ID is loaded
# by nothing and fails as "the machine ignored it", which is hard to read.
if [[ -n "$nic_rom" ]]; then
    case "$nic_rom" in
        e1000|82540em) nic_rom=8086100e ;;
        virtio|virtio-net) nic_rom=1af41000 ;;
        rtl8139) nic_rom=10ec8139 ;;
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
        *) die "--nic-rom '$nic_rom': expected 8 hex digits (vendor+device) or one of e1000/virtio/rtl8139" ;;
    esac
    nic_rom="${nic_rom,,}"
    [[ "$arch" == "x86_64" ]] || die "--nic-rom is a legacy BIOS PCI option ROM: x86_64 only (got '$arch')"
fi
if [[ -n "$payload_trust" && -z "$imgverify_mode" ]]; then
    log_warn "--payload-trust given without --imgverify; enabling --imgverify"
    imgverify_mode=1
fi
if [[ -n "$imgverify_mode" && -z "$payload_trust" ]]; then
    die "--imgverify requires --payload-trust <ca.der> (from sign-payload.sh --out-trust)"
fi

# ─── Pre-flight checks ──────────────────────────────────────────────────────
log_info "checking Docker daemon..."
if ! docker info &>/dev/null; then
    die "Docker daemon is not running or not accessible.
  Start it with:  sudo systemctl start docker
  Or ensure your user is in the 'docker' group:  sudo usermod -aG docker \$USER"
fi
log_info "Docker OK"

mkdir -p "$output_dir"

# ─── Build iPXE inside Docker ────────────────────────────────────────────────
# boot.ipxe is written by ipxe-build-inner.sh and copied to /out/boot.ipxe.
log_info "starting Docker build (arch=$arch ref=$ipxe_ref) — this takes several minutes..."
log_info "  output dir : $output_dir"
log_info "  build ctx  : $SCRIPT_DIR"

# Optional read-only bind-mounts (each as a proper two-token -v pair in an
# array — a single "--volume host:ctr:ro" string would reach docker as ONE arg
# and be rejected as an unknown flag).
docker_vols=(); inner_cert_path=""; inner_trust_path=""
if [[ -n "$tls_cert" ]]; then
    inner_cert_path="/tls-cert.der"
    docker_vols+=(-v "${tls_cert}:${inner_cert_path}:ro")
fi
if [[ -n "$payload_trust" ]]; then
    inner_trust_path="/payload-trust.der"
    docker_vols+=(-v "${payload_trust}:${inner_trust_path}:ro")
fi
inner_embed_path=""
if [[ -n "$embed_script" ]]; then
    inner_embed_path="/embed.ipxe"
    docker_vols+=(-v "$(readlink -f -- "$embed_script"):${inner_embed_path}:ro")
fi

docker run --rm \
    -v "$output_dir:/out" \
    -v "$SCRIPT_DIR:/build-ctx:ro" \
    "${docker_vols[@]}" \
    debian:bookworm \
    bash /build-ctx/ipxe-build-inner.sh \
        "$server" "$kernel_path" "$initrd_path" "$append" "$arch" "$ipxe_ref" \
        "${tls_mode:-}" "${inner_cert_path}" \
        "${imgverify_mode:-}" "${inner_trust_path}" \
        "${nic_rom}" "${inner_embed_path}" "${serial_console:-}"

# ─── Convert the BIOS disk image to qcow2 ────────────────────────────────────
# Prefer ipxe.hd (hard-disk image) over ipxe.usb: SeaBIOS boots the .hd reliably
# as a virtio-blk disk, whereas the .usb stick image can fail ("could not read
# the boot disk") when presented as an HDD.  Fall back to .usb if .hd is absent
# (e.g. an older builder).  Pad to a few MiB so SeaBIOS computes a sane geometry.
if command -v qemu-img &>/dev/null; then
    rom_src=""
    [[ -f "$output_dir/ipxe.hd"  ]] && rom_src="ipxe.hd"
    [[ -z "$rom_src" && -f "$output_dir/ipxe.usb" ]] && rom_src="ipxe.usb"
    if [[ -n "$rom_src" ]]; then
        # iPXE's .hd image ships with an MBR partition table but NO active
        # partition, so SeaBIOS refuses to boot it ("Could not locate active
        # partition") and never reaches the iPXE MBR code.  Set the active flag
        # on partition entry 1 (MBR offset 0x1BE = byte 446 → 0x80); SeaBIOS then
        # executes the iPXE boot sector, which loads the rest of iPXE itself.
        # Verified: this turns "No bootable device" into a working BIOS iPXE boot.
        # Patch a WRITABLE COPY (the build output can be root-owned when Docker
        # runs rootful) and convert that.  (.usb already carries an active entry,
        # so only .hd needs this.)
        conv_src="$output_dir/$rom_src"
        if [[ "$rom_src" == "ipxe.hd" ]]; then
            conv_src="$output_dir/.ipxe.hd.active"
            cp -f "$output_dir/ipxe.hd" "$conv_src"
            printf '\x80' | dd of="$conv_src" bs=1 seek=446 count=1 conv=notrunc status=none 2>/dev/null \
                || die "failed to set the active partition flag on $conv_src"
        fi
        log_info "converting ${rom_src} → ipxe.qcow2 (for Phase 2 QEMU boot)..."
        qemu-img convert -f raw -O qcow2 "$conv_src" "$output_dir/ipxe.qcow2"
        qemu-img resize "$output_dir/ipxe.qcow2" 4M >/dev/null 2>&1 || true
        [[ "$conv_src" == *".ipxe.hd.active" ]] && rm -f "$conv_src"
        log_info "converted: $output_dir/ipxe.qcow2 (from ${rom_src}, active-flagged + padded)"
    else
        log_warn "no ipxe.hd/ipxe.usb found; skipping qcow2 conversion (aarch64 only produces EFI)"
    fi
else
    log_warn "qemu-img not found; skipping qcow2 conversion"
    log_warn "  install with:  sudo apt-get install qemu-utils"
    log_warn "  or use:        dd if=$output_dir/ipxe.usb of=/dev/sdX  (USB only)"
fi

# ─── Summary ────────────────────────────────────────────────────────────────
log_info "build complete — outputs in $output_dir:"
for f in boot.ipxe ipxe.usb ipxe.efi ipxe.qcow2 ${nic_rom:+ipxe-$nic_rom.rom}; do
    fp="$output_dir/$f"
    if [[ -f "$fp" ]]; then
        size=$(du -sh "$fp" 2>/dev/null | cut -f1)
        log_info "  $f  ($size)"
    fi
done
log_info ""
if [[ -n "$sign_mode" ]]; then
    efi_out="$output_dir/ipxe.efi"
    if [[ ! -f "$efi_out" ]]; then
        log_warn "--sign: $efi_out not found; skipping signing step"
    else
        log_info "signing EFI binary: $efi_out"
        sign_args=()
        if [[ -n "$sign_snakeoil" ]]; then
            sign_args+=(--use-snakeoil)
        elif [[ -n "$sign_key" && -n "$sign_cert" ]]; then
            sign_args+=(--key "$sign_key" --cert "$sign_cert")
        else
            sign_args+=(--generate-mok)
        fi
        "$(dirname -- "$0")/sign-ipxe.sh"             "${sign_args[@]}"             --input  "$efi_out"             --output "$output_dir/ipxe-signed.efi"
    fi
fi
if [[ -n "$tls_mode" ]]; then
    log_info "  (built with HTTPS support — server URL must use https://)"
fi
log_info "next steps:"
log_info "  QEMU (Phase 2):    lab-vm.sh --disk $output_dir/ipxe.qcow2"
log_info "  USB (real hw):     sudo dd if=$output_dir/ipxe.usb of=/dev/sdX bs=4M status=progress"
log_info "  Serve artifacts:   lab-podman.sh (Phase 4 nginx on :8181)"

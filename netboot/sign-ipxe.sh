#!/usr/bin/env bash
# sign-ipxe.sh — Sign an iPXE EFI binary for Secure Boot.
#
# Three usage modes:
#
#   --use-snakeoil          Quick QEMU test: sign with the pre-installed
#                           Ubuntu/Debian snakeoil key.  The signed binary
#                           boots in QEMU when OVMF_CODE_4M.secboot.fd +
#                           OVMF_VARS_4M.snakeoil.fd are used.  No MOK
#                           enrollment step needed.  NOT for real hardware.
#
#   --generate-mok          Generate a new MOK key pair (saved to --conf-dir),
#                           sign with it, and print the mokutil enrollment
#                           command.  Use this for real hardware with Secure
#                           Boot enabled.
#
#   --key KEY --cert CERT   Sign with an existing key/cert pair.
#
# Requires: sbsign, sbverify, openssl (all in sbsigntool + openssl packages)
#
# Usage:
#   netboot/sign-ipxe.sh [--use-snakeoil | --generate-mok | --key K --cert C]
#                        [--input ~/netboot/ipxe.efi]
#                        [--output ~/netboot/ipxe-signed.efi]
#                        [--conf-dir ~/.config/lab-netboot]

set -euo pipefail

readonly LAB_PROG="${0##*/}"

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
die()       { _log error "$@"; exit 1; }

usage() {
    cat >&2 <<'EOF'
Usage: netboot/sign-ipxe.sh MODE [OPTIONS]

MODE (pick one):
  --use-snakeoil      Sign with the system snakeoil key (QEMU testing only;
                      NOT for real hardware — key is world-readable)
  --generate-mok      Generate a new MOK key pair, sign, print enrollment cmd
  --key K --cert C    Sign with an existing key (PEM) and cert (PEM)

OPTIONS:
  --input  FILE   EFI binary to sign          (default: ~/netboot/ipxe.efi)
  --output FILE   Signed output path           (default: ~/netboot/ipxe-signed.efi)
  --conf-dir DIR  Where to store generated MOK (default: ~/.config/lab-netboot)
  --help          show this help

After signing, verify with:
  sbverify --cert <cert> <signed.efi>

MOK enrollment on real hardware (after --generate-mok):
  mokutil --import ~/.config/lab-netboot/MOK.crt
  # → reboot → confirm in the MOK manager → Secure Boot will accept the binary

QEMU Secure Boot testing (after --use-snakeoil):
  lab-vm.sh create ... --secure-boot
  # Uses OVMF_CODE_4M.secboot.fd + OVMF_VARS_4M.snakeoil.fd automatically.
EOF
    exit 0
}

# ─── Defaults ───────────────────────────────────────────────────────────────
mode=""
key_file=""
cert_file=""
input_file="${LAB_NETBOOT_DIR:-$HOME/netboot}/ipxe.efi"
output_file="${LAB_NETBOOT_DIR:-$HOME/netboot}/ipxe-signed.efi"
conf_dir="${LAB_NETBOOT_CONF:-$HOME/.config/lab-netboot}"

# ─── Snakeoil key paths (Ubuntu/Debian ovmf package) ───────────────────────
SNAKEOIL_KEY="/usr/share/ovmf/PkKek-1-snakeoil.key"
SNAKEOIL_CERT="/usr/share/ovmf/PkKek-1-snakeoil.pem"

# ─── Arg parsing ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --use-snakeoil)  mode="snakeoil"; shift ;;
        --generate-mok)  mode="generate"; shift ;;
        --key)           shift; key_file="${1:?--key requires a file}"; shift ;;
        --cert)          shift; cert_file="${1:?--cert requires a file}"; shift ;;
        --input)         shift; input_file="${1:?--input requires a file}"; shift ;;
        --output)        shift; output_file="${1:?--output requires a file}"; shift ;;
        --conf-dir)      shift; conf_dir="${1:?--conf-dir requires a path}"; shift ;;
        --help|-h) usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

# Infer mode from --key/--cert if provided without explicit mode.
if [[ -n "$key_file" || -n "$cert_file" ]]; then
    mode="custom"
fi

[[ -n "$mode" ]] || die "pick a signing mode: --use-snakeoil, --generate-mok, or --key/--cert"

# ─── Tool check ─────────────────────────────────────────────────────────────
command -v sbsign   >/dev/null 2>&1 || die "sbsign not found.  Install: sudo apt-get install sbsigntool"
command -v sbverify >/dev/null 2>&1 || die "sbverify not found.  Install: sudo apt-get install sbsigntool"
command -v openssl  >/dev/null 2>&1 || die "openssl not found.  Install: sudo apt-get install openssl"

[[ -r "$input_file" ]] || die "input EFI not readable: $input_file  (did you run build-ipxe.sh first?)"

mkdir -p "$(dirname "$output_file")"

# ─── Mode: snakeoil ─────────────────────────────────────────────────────────
if [[ "$mode" == "snakeoil" ]]; then
    [[ -r "$SNAKEOIL_KEY"  ]] || die "snakeoil key not found: $SNAKEOIL_KEY
  Install: sudo apt-get install ovmf"
    [[ -r "$SNAKEOIL_CERT" ]] || die "snakeoil cert not found: $SNAKEOIL_CERT"
    log_info "signing with snakeoil key (QEMU test only — NOT for real hardware)"
    log_warn "  The snakeoil key is world-readable.  Anyone can sign binaries that"
    log_warn "  will boot under a snakeoil OVMF.  Use --generate-mok for real hardware."
    key_file="$SNAKEOIL_KEY"
    cert_file="$SNAKEOIL_CERT"
fi

# ─── Mode: generate a new MOK ───────────────────────────────────────────────
if [[ "$mode" == "generate" ]]; then
    mkdir -p "$conf_dir"
    mok_key="$conf_dir/MOK.key"
    mok_cert="$conf_dir/MOK.crt"
    if [[ -f "$mok_key" && -f "$mok_cert" ]]; then
        log_info "MOK key already exists at $mok_key — reusing"
    else
        log_info "generating MOK key pair → $conf_dir/MOK.{key,crt}"
        openssl req -newkey rsa:4096 -nodes \
            -keyout "$mok_key" \
            -new -x509 -sha256 \
            -days 3650 \
            -subj "/CN=Lab iPXE MOK $(date +%Y)" \
            -out "$mok_cert" \
            2>/dev/null
        chmod 600 "$mok_key"
        log_info "  key : $mok_key"
        log_info "  cert: $mok_cert"
    fi
    key_file="$mok_key"
    cert_file="$mok_cert"
fi

# ─── Mode: custom (--key / --cert) ──────────────────────────────────────────
if [[ "$mode" == "custom" ]]; then
    [[ -n "$key_file"  ]] || die "--key is required when not using --use-snakeoil or --generate-mok"
    [[ -n "$cert_file" ]] || die "--cert is required when not using --use-snakeoil or --generate-mok"
    [[ -r "$key_file"  ]] || die "key file not readable: $key_file"
    [[ -r "$cert_file" ]] || die "cert file not readable: $cert_file"
fi

# ─── Sign ────────────────────────────────────────────────────────────────────
log_info "signing: $input_file → $output_file"
sbsign --key "$key_file" --cert "$cert_file" \
       --output "$output_file" \
       "$input_file" \
    || die "sbsign failed"

# ─── Verify the signature ────────────────────────────────────────────────────
log_info "verifying signature..."
sbverify --cert "$cert_file" "$output_file" \
    || die "sbverify failed — the signed binary may be corrupt"
log_info "  signature valid ✓"

# ─── Summary ─────────────────────────────────────────────────────────────────
log_info "── sign-ipxe done ──"
log_info "  input   : $input_file"
log_info "  signed  : $output_file"
log_info "  cert    : $cert_file"
log_info ""

if [[ "$mode" == "snakeoil" ]]; then
    log_info "QEMU Secure Boot test:"
    log_info "  lab-vm.sh create --name pxe-sb --distro alpine --suite 3.20 \\"
    log_info "      --arch x86_64 --secure-boot --backend disk-image"
    log_info ""
    log_info "  Uses OVMF_CODE_4M.secboot.fd + OVMF_VARS_4M.snakeoil.fd automatically."
    log_info "  Replace ipxe.efi with ipxe-signed.efi before booting."
elif [[ "$mode" == "generate" ]]; then
    log_info "MOK enrollment (real hardware, requires physical presence at firmware):"
    log_info "  sudo mokutil --import $cert_file"
    log_info "  # → reboot → 'Enroll MOK' in the blue MokManager screen → reboot again"
    log_info "  # Secure Boot will now accept binaries signed with $cert_file"
    log_info ""
    log_info "QEMU testing with custom MOK (advanced — no snakeoil VARS):"
    log_info "  # Enroll the MOK into a VARS file using virt-fw-vars or efi-updatevar."
    log_info "  # See MANUAL_TESTING.md §12 for the full procedure."
fi

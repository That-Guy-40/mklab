#!/usr/bin/env bash
# sign-payload.sh — code-sign netboot payloads (kernel/initrd) so iPXE can
# verify them at boot with `imgverify`.  This closes the "reboot pulls newest"
# supply-chain gap (AUDIT.md F2): a node must boot newest *verified*, not
# "whatever the HTTP server returned".
#
# Companion to build-ipxe.sh --imgverify --payload-trust <ca.der>, which bakes
# the trust root produced here into the iPXE binary.
#
# Signatures are OpenSSL CMS, detached, DER, `-binary -noattr` — exactly what
# iPXE's imgverify expects (https://ipxe.org/appnote/codesigning).  The signing
# leaf carries a codeSigning EKU (iPXE requires it) and the CA travels *inside*
# the CMS via -certfile so iPXE can build leaf→CA→trust-root (without it,
# imgverify fails "No usable certificates", ipxe.org/err/0216eb3c).
#
# Usage:
#   netboot/sign-payload.sh --gen-keys --out-trust ~/netboot/codesign/ca.der \
#       ~/netboot/images/dns/current/vmlinuz \
#       ~/netboot/images/dns/current/initrd.gz
#   # → writes vmlinuz.sig, initrd.gz.sig alongside each input.
#
# HONEST TRUST FRAMING (F1): --gen-keys mints a *snakeoil* CA + signer, fine for
# a lab and for proving the mechanism, but NOT a real trust anchor.  In
# production the signing key is an offline/HSM-held fleet key; point --keydir at
# real material (ca.crt/ca.key + codesign.crt/codesign.key) and drop --gen-keys.

set -euo pipefail

# ─── Logging (house style, mirrors build-ipxe.sh) ────────────────────────────
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

usage() {
    cat >&2 <<'EOF'
Usage: netboot/sign-payload.sh [OPTIONS] <file> [<file>...]

Code-sign netboot payloads for iPXE imgverify.  Writes <file>.sig next to each
input (detached CMS, DER).

Options:
  --keydir DIR      code-signing material dir
                    (default: $LAB_NETBOOT_DIR/codesign or ~/netboot/codesign)
                    expects ca.crt ca.key codesign.crt codesign.key
  --gen-keys        generate a SNAKEOIL CA + codeSigning leaf into --keydir if
                    absent (lab only — not a real trust anchor)
  --out-trust PATH  also emit the CA in DER form here (feed to
                    build-ipxe.sh --payload-trust)
  --help            show this help and exit

Examples:
  # first run: mint snakeoil keys, emit the DER trust root, sign two files
  netboot/sign-payload.sh --gen-keys --out-trust ~/netboot/codesign/ca.der \
      ~/netboot/images/dns/current/vmlinuz \
      ~/netboot/images/dns/current/initrd.gz

  # later runs reuse the same keydir (no --gen-keys needed)
  netboot/sign-payload.sh ~/netboot/images/dns/current/*.gz
EOF
    exit 0
}

# ─── Defaults / args ─────────────────────────────────────────────────────────
keydir="${LAB_NETBOOT_DIR:-$HOME/netboot}/codesign"
gen_keys=""
out_trust=""
files=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keydir)    shift; keydir="${1:?--keydir requires a dir}"; shift ;;
        --gen-keys)  gen_keys=1; shift ;;
        --out-trust) shift; out_trust="${1:?--out-trust requires a path}"; shift ;;
        --help|-h)   usage ;;
        --*)         die "unknown option: $1  (try --help)" ;;
        *)           files+=("$1"); shift ;;
    esac
done

[[ ${#files[@]} -gt 0 ]] || die "no input files given (try --help)"
command -v openssl >/dev/null || die "openssl not found (needed for CMS signing)"

# ─── Ensure code-signing material ────────────────────────────────────────────
ca_crt="$keydir/ca.crt"
ca_key="$keydir/ca.key"
cs_crt="$keydir/codesign.crt"
cs_key="$keydir/codesign.key"

have_keys=1
for f in "$ca_crt" "$ca_key" "$cs_crt" "$cs_key"; do
    [[ -r "$f" ]] || have_keys=""
done

if [[ -z "$have_keys" ]]; then
    if [[ -z "$gen_keys" ]]; then
        die "code-signing material missing in $keydir
  expected: ca.crt ca.key codesign.crt codesign.key
  → pass --gen-keys to mint SNAKEOIL keys for a lab, or point --keydir at real
    (offline/HSM) material.  Snakeoil keys are NOT a real trust anchor."
    fi
    log_warn "minting SNAKEOIL code-signing material in $keydir"
    log_warn "  (lab only — a real deployment signs with an offline/HSM fleet key)"
    mkdir -p "$keydir"
    # Root CA (trust anchor; CA:TRUE).
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$ca_key" -out "$ca_crt" \
        -days 3650 -subj "/CN=RAM-Infra Lab Code-Signing CA (SNAKEOIL)" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null \
        || die "failed to generate CA"
    # Code-signing leaf — iPXE imgverify REQUIRES the codeSigning EKU.
    local_ext="$keydir/.codesign.ext"
    cat > "$local_ext" <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EXT
    openssl req -newkey rsa:2048 -nodes -keyout "$cs_key" -out "$keydir/.codesign.csr" \
        -subj "/CN=RAM-Infra Lab Payload Signer (SNAKEOIL)" 2>/dev/null \
        || die "failed to generate signer CSR"
    openssl x509 -req -in "$keydir/.codesign.csr" -CA "$ca_crt" -CAkey "$ca_key" \
        -CAcreateserial -out "$cs_crt" -days 3650 -extfile "$local_ext" 2>/dev/null \
        || die "failed to sign the leaf with the CA"
    rm -f "$keydir/.codesign.csr" "$local_ext"
    chmod 600 "$ca_key" "$cs_key"
    log_info "minted CA + codeSigning leaf in $keydir"
fi

# Confirm the leaf really has the codeSigning EKU (a wrong cert fails silently
# at boot with a chain error — catch it here instead).
if ! openssl x509 -in "$cs_crt" -noout -ext extendedKeyUsage 2>/dev/null \
        | grep -q "Code Signing"; then
    die "signer cert $cs_crt lacks the codeSigning EKU — iPXE imgverify will reject it"
fi

# ─── Sign each file ──────────────────────────────────────────────────────────
for f in "${files[@]}"; do
    [[ -r "$f" ]] || die "input not readable: $f"
    sig="$f.sig"
    log_info "signing $(basename "$f") → $(basename "$sig")"
    # -binary   : sign the raw bytes (no MIME canonicalisation)
    # -noattr   : no signed attributes (iPXE expects a bare signature)
    # -certfile : bundle the CA INTO the CMS so iPXE can build leaf→CA→root
    openssl cms -sign -binary -noattr -in "$f" \
        -signer "$cs_crt" -inkey "$cs_key" -certfile "$ca_crt" \
        -outform DER -out "$sig" 2>/dev/null \
        || die "CMS signing failed for $f"
    # Self-check: -purpose any because a codeSigning-only leaf is (correctly)
    # not valid for the default smimesign purpose openssl otherwise checks.
    openssl cms -verify -binary -purpose any -inform DER -in "$sig" \
        -content "$f" -CAfile "$ca_crt" -out /dev/null 2>/dev/null \
        || die "self-verify failed for $sig (signature does not validate)"
done

# ─── Emit the DER trust root for build-ipxe.sh --payload-trust ───────────────
if [[ -n "$out_trust" ]]; then
    mkdir -p "$(dirname "$out_trust")"
    openssl x509 -in "$ca_crt" -outform DER -out "$out_trust" \
        || die "failed to write DER trust root to $out_trust"
    log_info "wrote DER trust root: $out_trust"
    log_info "  → build-ipxe.sh --imgverify --payload-trust $out_trust"
fi

log_info "signed ${#files[@]} file(s); trust root CA: $ca_crt"

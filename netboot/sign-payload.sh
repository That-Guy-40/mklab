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
# real material (ca.crt + codesign.crt/codesign.key) and drop --gen-keys.
#
# ── --lab-ca: THE SHARED ROOT, NOT A CA PER LAB (TODO 15.4) ──────────────────
# examples/lab-ca/ is this repo's shared root, already anchoring the pxeboot
# HTTPS tier and System Transparency OSPKG signing.  Until 2026-08-30 nothing
# under netboot/ mentioned it: every run minted a fresh snakeoil root, so the
# RAM-infra family's "reboot pulls the newest VERIFIED image" chained to a key
# each lab had made for itself.  `--lab-ca <name>` signs with a leaf issued by
# that shared root instead:
#
#   examples/lab-ca/make-ca.sh                          # once, ever
#   examples/lab-ca/issue-codesign-cert.sh netboot-payload
#   netboot/sign-payload.sh --lab-ca netboot-payload --out-trust <ca.der> <file>...
#
# WHAT BLOCKED IT WAS IN HERE, and it is worth naming: the readability check
# below demanded ca.KEY as well, for every run.  So the documented "point
# --keydir at real material" seam could not be used as documented -- the ROOT
# PRIVATE KEY had to sit beside the signer, which is the one thing an offline
# root means to avoid.  Signing needs ca.crt (bundled into the CMS so iPXE can
# build leaf->CA->trust-root) and the LEAF's key.  The root key is needed only
# by --gen-keys, and is now required only there.

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
                    expects ca.crt codesign.crt codesign.key
                    (ca.key is needed ONLY by --gen-keys)
  --lab-ca NAME     sign with a leaf issued by the SHARED lab root CA
                    (examples/lab-ca/) instead of a per-lab snakeoil root:
                    ca.crt = examples/lab-ca/lab-ca.crt, leaf =
                    <keystore>/certs/NAME-codesign.{crt,key}.
                    Mint the leaf first with examples/lab-ca/issue-codesign-cert.sh
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

  # the shared root: one anchor for every lab that verifies an artifact
  examples/lab-ca/issue-codesign-cert.sh netboot-payload
  netboot/sign-payload.sh --lab-ca netboot-payload \
      --out-trust ~/netboot/codesign/ca.der ~/netboot/images/dns/current/vmlinuz
EOF
    exit 0
}

# ─── Defaults / args ─────────────────────────────────────────────────────────
keydir="${LAB_NETBOOT_DIR:-$HOME/netboot}/codesign"
gen_keys=""
out_trust=""
lab_ca_name=""
files=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keydir)    shift; keydir="${1:?--keydir requires a dir}"; shift ;;
        --lab-ca)    shift; lab_ca_name="${1:?--lab-ca requires a leaf name}"; shift ;;
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

if [[ -n "$lab_ca_name" ]]; then
    [[ -z "$gen_keys" ]] \
        || die "--lab-ca and --gen-keys are contradictory: one anchors to the SHARED lab root, the other mints a throwaway one.  Mint the leaf with examples/lab-ca/issue-codesign-cert.sh $lab_ca_name instead."
    here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    # LAB_CA_DIR is an override so the tests can drive a throwaway root: the shared
    # root's PRIVATE key is gitignored, so a test that could only use the real one
    # would SKIP everywhere except this machine — and a guard that skips in CI is an
    # UNKNOWN, not a pass.
    lab_ca_dir="${LAB_CA_DIR:-$here/../examples/lab-ca}"
    [[ -d "$lab_ca_dir" ]] || die "cannot find examples/lab-ca next to $here — --lab-ca has no shared root to anchor to"
    ca_crt="$lab_ca_dir/lab-ca.crt"
    ca_key=""                       # the root key is NOT needed to sign, and must not be
    ks="${LAB_CA_KEYDIR:-$lab_ca_dir/private}"
    cs_crt="$ks/certs/$lab_ca_name-codesign.crt"
    cs_key="$ks/certs/$lab_ca_name-codesign.key"
    [[ -r "$ca_crt" ]] \
        || die "the shared root's public anchor is missing: $ca_crt  (run examples/lab-ca/make-ca.sh)"
    [[ -r "$cs_crt" && -r "$cs_key" ]] \
        || die "no code-signing leaf '$lab_ca_name' under the shared lab CA
  expected: $cs_crt (+ .key)
  → mint one:  examples/lab-ca/issue-codesign-cert.sh $lab_ca_name
    It is ECDSA P-256 with a codeSigning EKU, which is what iPXE imgverify needs;
    issue-signing-cert.sh mints the Ed25519 NO-EKU leaf stboot needs, and the two
    are deliberately different certificates."
    log_info "anchoring to the SHARED lab root CA: $ca_crt"
    log_info "  leaf: $cs_crt"
fi

# The ROOT PRIVATE KEY is required only to MINT.  Demanding it on every run --
# which this did until 2026-08-30 -- made the documented "point --keydir at real
# (offline/HSM) material" seam unusable as documented, since it forced the root
# key to sit beside the signer.  Signing needs ca.crt and the leaf's key.
have_keys=1
for f in "$ca_crt" "$cs_crt" "$cs_key"; do
    [[ -r "$f" ]] || have_keys=""
done

if [[ -z "$have_keys" ]]; then
    if [[ -z "$gen_keys" ]]; then
        die "code-signing material missing in $keydir
  expected: ca.crt codesign.crt codesign.key   (ca.key only for --gen-keys)
  → pass --gen-keys to mint SNAKEOIL keys for a lab, point --keydir at real
    (offline/HSM) material, or use --lab-ca <name> to anchor to this repo's
    shared root in examples/lab-ca/.  Snakeoil keys are NOT a real trust anchor."
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

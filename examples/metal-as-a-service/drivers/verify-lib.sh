#!/usr/bin/env bash
# verify-lib.sh — the F2 payload-signature gate for MAAS deploy drivers.
#
# Signs/verifies deploy payloads with **OpenSSL CMS, detached, DER, `-binary
# -noattr`, codeSigning EKU** — byte-for-byte the format the repo's
# `netboot/sign-payload.sh` produces for iPXE `imgverify`
# (https://ipxe.org/appnote/codesigning). MAAS uses it as the **deploy-time**
# gate (host-side `openssl cms -verify`); iPXE's in-firmware `imgverify` at boot
# is the complement. We keep our own small copy (self-containment) and
# CITE sign-payload.sh as the production/iPXE-side companion rather than duplicating
# its whole option surface.
#
# WHAT KEEPING OUR OWN COPY COST, ONCE. The two halves of F2 read the SAME .sig
# files, so a certificate profile that satisfies one and not the other is a gap
# nothing on the host can see. That happened here: this file used to mint a leaf
# carrying `extendedKeyUsage=codeSigning` and nothing else. `openssl cms -verify`
# accepts it, so every host-side gate and every test passed — and iPXE refuses it
# outright with **"Not a signing certificate" (https://ipxe.org/022ae1)**, because
# it also requires **keyUsage=digitalSignature**. For as long as that was true, the
# fleet was signing payloads that no verifying firmware would ever have accepted,
# and the lab had no way to notice. The profile below is now the same one
# sign-payload.sh mints, and `check-keys` exists so an OLD keydir says so out loud
# instead of failing on the machine.
#
#   verify-lib.sh gen-keys --dir DIR         mint a snakeoil CA + codesign leaf (lab/tests)
#   verify-lib.sh check-keys --dir DIR       exit 0 if the leaf is one iPXE will accept
#   verify-lib.sh sign  <file> --keydir DIR  write <file>.sig (CMS DER)
#   verify-lib.sh verify <file> --ca CA [--sig S]   exit 0 if the signature is valid
#
# HONEST TRUST FRAMING (F1, carried from sign-payload.sh): `gen-keys` mints
# *snakeoil* material — fine to prove the mechanism + the refusal path, but NOT a
# real trust anchor. In production the signing key is offline/HSM-held; point
# --keydir at real ca.crt/ca.key + codesign.crt/codesign.key and skip gen-keys.
set -uo pipefail

die() { printf 'verify-lib: %s\n' "$*" >&2; exit 1; }
command -v openssl >/dev/null || die "openssl required"

cmd="${1:-}"; shift || true

case "$cmd" in
gen-keys)
    dir=""
    while [[ $# -gt 0 ]]; do case "$1" in --dir) dir="$2"; shift 2 ;; *) die "gen-keys: unknown $1" ;; esac; done
    [[ -n "$dir" ]] || die "gen-keys: --dir required"
    mkdir -p "$dir"
    if [[ -f "$dir/ca.crt" && -f "$dir/codesign.crt" ]]; then
        printf 'verify-lib: keys already present in %s (leaving them)\n' "$dir" >&2
        # Say so HERE. Existing keydirs predate the keyUsage fix, and a leaf iPXE
        # rejects is otherwise silent until a node refuses to boot.
        if ! openssl x509 -in "$dir/codesign.crt" -noout -ext keyUsage 2>/dev/null | grep -qi 'Digital Signature'; then
            printf 'verify-lib: WARNING — %s/codesign.crt has NO keyUsage=digitalSignature.\n' "$dir" >&2
            printf '  The host-side gate accepts it; iPXE imgverify REFUSES it ("Not a signing\n' >&2
            printf '  certificate", https://ipxe.org/022ae1). Payloads signed with it cannot boot\n' >&2
            printf '  on verifying firmware. Re-mint (remove %s and re-run gen-keys), then\n' "$dir" >&2
            printf '  re-sign every image — a signature is only as portable as its certificate.\n' >&2
        fi
        exit 0
    fi
    # The certificate profile below is the one netboot/sign-payload.sh mints and the
    # RAM-infra lab proved against real iPXE. Every line earns its place against a
    # specific firmware refusal, so none of it is decoration:
    #   CA:TRUE + keyCertSign      the root may sign certificates at all
    #   CA:FALSE on the leaf       a signer that is not also a CA
    #   digitalSignature           iPXE: else "Not a signing certificate"    (022ae1)
    #   codeSigning EKU            iPXE: else "Not a code-signing certificate"
    # openssl cms -verify requires NONE of them, which is exactly why they went
    # missing here once and stayed missing.
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/ca.key" -out "$dir/ca.crt" \
        -days 3650 -subj '/CN=MAAS Lab Snakeoil CA' \
        -addext 'basicConstraints=critical,CA:TRUE' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1 || die "CA generation failed"
    # codesigning leaf signed by the CA
    openssl req -newkey rsa:2048 -nodes -keyout "$dir/codesign.key" -out "$dir/codesign.csr" \
        -subj '/CN=MAAS Lab codesign' >/dev/null 2>&1 || die "leaf key generation failed"
    cat > "$dir/leaf.ext" <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EXT
    openssl x509 -req -in "$dir/codesign.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" \
        -CAcreateserial -days 3650 -extfile "$dir/leaf.ext" -out "$dir/codesign.crt" >/dev/null 2>&1 \
        || die "leaf certificate signing failed"
    rm -f "$dir/codesign.csr" "$dir/leaf.ext"
    # Fail at MINT time if the profile did not take: a leaf that is wrong here is a
    # node that refuses to boot much later, with the reason three layers away.
    "$0" check-keys --dir "$dir" >/dev/null 2>&1 \
        || die "minted a leaf that iPXE would refuse — check the openssl version's -addext support"
    printf 'verify-lib: minted snakeoil CA + codesign leaf in %s\n' "$dir" >&2
    ;;

check-keys)
    # Is this keydir's leaf one that VERIFYING FIRMWARE will accept? The host-side
    # gate cannot answer that — it does not look at key usage at all.
    dir=""
    while [[ $# -gt 0 ]]; do case "$1" in --dir) dir="$2"; shift 2 ;; *) die "check-keys: unknown $1" ;; esac; done
    [[ -n "$dir" ]] || die "check-keys: --dir required"
    leaf="$dir/codesign.crt"
    [[ -f "$leaf" ]] || die "check-keys: no codesign.crt in $dir"
    ku="$(openssl x509 -in "$leaf" -noout -ext keyUsage 2>/dev/null)"
    eku="$(openssl x509 -in "$leaf" -noout -ext extendedKeyUsage 2>/dev/null)"
    bad=""
    grep -qi 'Digital Signature' <<<"$ku"  || bad+="  keyUsage=digitalSignature is MISSING -> iPXE: 'Not a signing certificate' (https://ipxe.org/022ae1)
"
    grep -qi 'Code Signing'     <<<"$eku" || bad+="  extendedKeyUsage=codeSigning is MISSING -> iPXE: 'Not a code-signing certificate'
"
    if [[ -n "$bad" ]]; then
        printf 'verify-lib: %s is NOT a certificate verifying firmware will accept:\n%s' "$leaf" "$bad" >&2
        exit 1
    fi
    printf 'verify-lib: %s carries digitalSignature + codeSigning (iPXE imgverify will accept it)\n' "$leaf" >&2
    ;;
sign)
    file="${1:?usage: sign <file> --keydir DIR}"; shift
    keydir="" out=""
    while [[ $# -gt 0 ]]; do
        case "$1" in --keydir) keydir="$2"; shift 2 ;; --out) out="$2"; shift 2 ;; *) die "sign: unknown $1" ;; esac
    done
    [[ -f "$file" ]] || die "sign: no such file: $file"
    [[ -n "$keydir" && -f "$keydir/codesign.crt" ]] || die "sign: --keydir with codesign.crt/key required (run gen-keys)"
    out="${out:-$file.sig}"
    openssl cms -sign -binary -noattr -outform DER \
        -signer "$keydir/codesign.crt" -inkey "$keydir/codesign.key" -certfile "$keydir/ca.crt" \
        -in "$file" -out "$out" >/dev/null 2>&1 || die "signing failed for $file"
    printf 'verify-lib: signed %s -> %s\n' "$file" "$out" >&2
    ;;
verify)
    file="${1:?usage: verify <file> --ca CA [--sig S]}"; shift
    ca="" sig=""
    while [[ $# -gt 0 ]]; do
        case "$1" in --ca) ca="$2"; shift 2 ;; --sig) sig="$2"; shift 2 ;; *) die "verify: unknown $1" ;; esac
    done
    [[ -f "$file" ]] || die "verify: no such file: $file"
    [[ -n "$ca" && -f "$ca" ]] || die "verify: --ca <trust-root> required"
    sig="${sig:-$file.sig}"
    [[ -f "$sig" ]] || die "verify: no signature: $sig"
    # -purpose any: the leaf's codeSigning EKU isn't a TLS purpose; we trust the
    # chain to the lab CA, which is the point (matches iPXE's trust-root check).
    if openssl cms -verify -binary -inform DER -in "$sig" -content "$file" \
            -CAfile "$ca" -purpose any -out /dev/null >/dev/null 2>&1; then
        exit 0
    fi
    printf 'verify-lib: SIGNATURE INVALID for %s (tampered or wrong signer)\n' "$file" >&2
    exit 1
    ;;
verify-dir)
    # verify EVERY signed payload in an image dir (each file with a .sig sibling)
    # against the trust CA. exit 0 only if all pass AND at least one was checked.
    dir="${1:?usage: verify-dir <image-dir> --ca CA}"; shift
    ca=""
    while [[ $# -gt 0 ]]; do case "$1" in --ca) ca="$2"; shift 2 ;; *) die "verify-dir: unknown $1" ;; esac; done
    [[ -d "$dir" ]] || die "verify-dir: no such image dir: $dir"
    [[ -n "$ca" && -f "$ca" ]] || die "verify-dir: --ca <trust-root> required"
    checked=0
    for sig in "$dir"/*.sig; do
        [[ -f "$sig" ]] || continue
        payload="${sig%.sig}"
        [[ -f "$payload" ]] || die "verify-dir: signature $sig has no payload $payload"
        "$0" verify "$payload" --ca "$ca" --sig "$sig" || exit 1
        checked=$((checked+1))
    done
    [[ $checked -gt 0 ]] || { printf 'verify-lib: no signed payloads in %s (nothing to trust)\n' "$dir" >&2; exit 1; }
    exit 0
    ;;
*)
    die "usage: verify-lib.sh {gen-keys|sign|verify|verify-dir} …" ;;
esac

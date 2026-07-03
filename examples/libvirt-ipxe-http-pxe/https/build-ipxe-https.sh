#!/usr/bin/env bash
# build-ipxe-https.sh — the HTTPS extension: build a custom iPXE that fetches the
# kernel+initrd over **HTTPS**, its server certificate verified against the
# shared lab CA (examples/lab-ca/).
#
# WHY a custom build.  libvirt's stock iPXE ROM won't do this for two reasons,
# both baked at *build* time:
#   1. Modern iPXE *disables* HTTPS on BIOS builds — config/general.h has
#        #if defined ( PLATFORM_pcbios )
#          #undef DOWNLOAD_PROTO_HTTPS
#      so we must re-enable it.
#   2. iPXE validates TLS against certificates baked in via TRUST=.  To trust a
#      *private* CA (our lab CA), we build with TRUST=lab-ca.crt.
# We also enable CONSOLE_SERIAL so iPXE's own output shows on the serial console
# (virt-install --nographics), and EMBED a boot script so the chainloaded iPXE
# runs the HTTPS fetch with no further input.
#
# HOW it plugs in.  The DHCP bootfile stays the stock HTTP path (the stock ROM
# can't do HTTPS), so `boot.ipxe` is rewritten to *chainload* our custom
# ipxe.lkrn over HTTP; that new iPXE then does everything else over HTTPS:
#     DHCP → stock iPXE → HTTP boot.ipxe → chain HTTP ipxe-https.lkrn
#          → (custom iPXE: HTTPS + lab-CA trust) → HTTPS kernel+initrd → boot
# Run AFTER `setup-pxe-http.sh stage --iso … --variant ipxe`.
#
# Usage:
#   build-ipxe-https.sh [--ip 192.168.122.1] [--http-port 8000] [--https-port 8443]
#                       [--ca <lab-ca.crt>]
# Env: PXE_HTTP_DIR (must match setup-pxe-http.sh), IPXE_BUILD_DIR.
set -euo pipefail

IP="192.168.122.1"; HTTP_PORT="8000"; HTTPS_PORT="8443"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
CA_CRT="$REPO_ROOT/examples/lab-ca/lab-ca.crt"
HTTPDIR="${PXE_HTTP_DIR:-$HOME/.cache/lab-create/libvirt-ipxe-http-pxe/pxeserver}"
IPXE_DIR="${IPXE_BUILD_DIR:-$HOME/.cache/lab-create/libvirt-ipxe-http-pxe/ipxe}"

while (($#)); do case "$1" in
    --ip) IP="$2"; shift 2;; --http-port) HTTP_PORT="$2"; shift 2;;
    --https-port) HTTPS_PORT="$2"; shift 2;; --ca) CA_CRT="$2"; shift 2;;
    *) echo "unknown flag: $1" >&2; exit 2;; esac; done

log()  { printf '\033[1;36m[ipxe-https]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ipxe-https] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for c in git gcc make perl; do command -v "$c" >/dev/null || die "missing build dep: $c (apt: build-essential git perl)"; done
[[ -f "$CA_CRT" ]] || die "lab CA not found: $CA_CRT  (run examples/lab-ca/make-ca.sh)"
[[ -d "$HTTPDIR" ]] || die "no staged tree at $HTTPDIR — run setup-pxe-http.sh stage first"

# Locate the extracted ISO dir (…/images/pxeboot/vmlinuz).
VMLINUZ="$(find "$HTTPDIR" -maxdepth 5 -path '*/images/pxeboot/vmlinuz' | head -1)" \
    || true
[[ -n "$VMLINUZ" ]] || die "no images/pxeboot/vmlinuz under $HTTPDIR — stage a Server DVD first"
ISO_REL="${VMLINUZ#"$HTTPDIR"/}"; ISO_DIR="${ISO_REL%%/*}"      # the ISO basename dir
log "install source: $ISO_DIR"

# 1. iPXE source (shallow clone; cached)
if [[ ! -d "$IPXE_DIR/src" ]]; then
    log "cloning iPXE (shallow) …"
    git clone --depth=1 https://github.com/ipxe/ipxe.git "$IPXE_DIR"
fi

# 2. Config: re-enable HTTPS for pcbios + turn on the serial console (idempotent)
gh="$IPXE_DIR/src/config/general.h"; ch="$IPXE_DIR/src/config/console.h"
sed -i 's|^  #undef DOWNLOAD_PROTO_HTTPS|  /* DOWNLOAD_PROTO_HTTPS kept enabled for lab HTTPS PXE */|' "$gh"
grep -q '^#define DOWNLOAD_PROTO_HTTPS' "$gh" || die "HTTPS not enabled in $gh"
sed -i 's|^//#define\s*CONSOLE_SERIAL|#define CONSOLE_SERIAL|' "$ch"

# 3. The embedded boot script: kernel+initrd over HTTPS; kickstart stays HTTP
#    (Anaconda is a separate TLS trust domain — see README "Going further").
EMBED="$IPXE_DIR/boot-https.ipxe"
cat > "$EMBED" <<EOF
#!ipxe
dhcp || exit 1
echo == iPXE HTTPS boot: kernel+initrd over TLS, verified vs the lab CA ==
kernel https://$IP:$HTTPS_PORT/$ISO_DIR/images/pxeboot/vmlinuz console=ttyS0 inst.ks=http://$IP:$HTTP_PORT/kickstart.cfg
initrd https://$IP:$HTTPS_PORT/$ISO_DIR/images/pxeboot/initrd.img
boot
EOF
log "embedded script → $EMBED"

# 4. Build bin-x86_64-pcbios/ipxe.lkrn  (x86_64 avoids gcc-multilib)
log "building ipxe.lkrn (HTTPS + TRUST=$(basename "$CA_CRT") + serial + EMBED) …"
make -C "$IPXE_DIR/src" bin-x86_64-pcbios/ipxe.lkrn \
    EMBED="$EMBED" TRUST="$CA_CRT" -j"$(nproc)" >/dev/null
LKRN="$IPXE_DIR/src/bin-x86_64-pcbios/ipxe.lkrn"
[[ -f "$LKRN" ]] || die "iPXE build produced no ipxe.lkrn"

# 5. Drop the custom iPXE into the HTTP tree + rewrite boot.ipxe to chainload it
cp "$LKRN" "$HTTPDIR/ipxe-https.lkrn"
cat > "$HTTPDIR/boot.ipxe" <<EOF
#!ipxe
# HTTP bootstrap → chainload the custom iPXE that speaks HTTPS + trusts the lab CA
chain http://$IP:$HTTP_PORT/ipxe-https.lkrn
EOF
log "installed: $HTTPDIR/ipxe-https.lkrn  +  chainloader $HTTPDIR/boot.ipxe"

CERTS="$REPO_ROOT/examples/lab-ca/private/certs"
cat >&2 <<EOF

  Next (two servers — HTTP bootstraps, HTTPS carries the payload):
    # 0. issue a lab-CA leaf for the server if you haven't:
    (cd $REPO_ROOT/examples/lab-ca && ./issue-server-cert.sh $IP)
    # 1. HTTP  (boot.ipxe + ipxe-https.lkrn):
    ( cd $HTTPDIR && python3 -m http.server $HTTP_PORT )
    # 2. HTTPS (kernel + initrd):
    ./serve-https.py --dir $HTTPDIR --port $HTTPS_PORT \\
        --cert $CERTS/$IP-fullchain.crt --key $CERTS/$IP.key
    # 3. point libvirt + launch (unchanged from the HTTP lab):
    ../setup-pxe-http.sh netxml --variant ipxe   # bootfile is still http boot.ipxe
    ../setup-pxe-http.sh virtinstall
EOF

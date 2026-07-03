#!/usr/bin/env bash
# container-build.sh — entrypoint for the Containerfile: compile the custom HTTPS
# iPXE inside the disposable build box and drop the artifact on a bind mount.
# The host toolchain stays clean; you end up with just ipxe-https.lkrn.
#
# Inputs (env):  IP (required), ISOBASE (required), HTTP_PORT=8000, HTTPS_PORT=8443
# Mounts:        /ca  = the lab CA dir (read-only, holds lab-ca.crt)
#                /out = where ipxe-https.lkrn + boot.ipxe are written
set -euo pipefail
: "${IP:?set -e IP=<bridge ip, e.g. 192.168.122.1>}"
: "${ISOBASE:?set -e ISOBASE=<Fedora Server DVD basename>}"
HTTP_PORT="${HTTP_PORT:-8000}"; HTTPS_PORT="${HTTPS_PORT:-8443}"
CA="${CA:-/ca/lab-ca.crt}"; OUT="${OUT:-/out}"
[[ -f "$CA" ]]   || { echo "mount the lab CA: -v <repo>/examples/lab-ca:/ca:ro" >&2; exit 1; }
[[ -d "$OUT" ]]  || { echo "mount an output dir: -v <PXE_HTTP_DIR>:/out" >&2; exit 1; }

# The EMBED script (per-IP/ISO) is written here at run time; the HTTPS + serial
# source edits were already applied in the image (see Containerfile).
cat > /tmp/boot-https.ipxe <<EOF
#!ipxe
dhcp || exit 1
echo == iPXE HTTPS boot: kernel+initrd over TLS, verified vs the lab CA ==
kernel https://$IP:$HTTPS_PORT/$ISOBASE/images/pxeboot/vmlinuz console=ttyS0 inst.ks=http://$IP:$HTTP_PORT/kickstart.cfg
initrd https://$IP:$HTTPS_PORT/$ISOBASE/images/pxeboot/initrd.img
boot
EOF

echo "==> compiling ipxe.lkrn (HTTPS + TRUST=$(basename "$CA") + serial + EMBED)"
make -C /opt/ipxe/src bin-x86_64-pcbios/ipxe.lkrn \
    EMBED=/tmp/boot-https.ipxe TRUST="$CA" -j"$(nproc)" >/dev/null

cp /opt/ipxe/src/bin-x86_64-pcbios/ipxe.lkrn "$OUT/ipxe-https.lkrn"
cat > "$OUT/boot.ipxe" <<EOF
#!ipxe
chain http://$IP:$HTTP_PORT/ipxe-https.lkrn
EOF
echo "==> wrote $OUT/ipxe-https.lkrn  +  $OUT/boot.ipxe (chainloader)"

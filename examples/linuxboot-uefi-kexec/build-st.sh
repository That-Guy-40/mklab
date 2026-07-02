#!/usr/bin/env bash
# build-st.sh — PLAN-PXEBOOT P3: build the System Transparency toolchain (stmgr +
# stboot) from source, then assemble ONE OS-agnostic **stboot UKI** whose trust is
# anchored to the shared lab CA.
#
# System Transparency = "boot only a SIGNED operating-system package". stboot is a
# tiny Go bootloader that runs as PID 1 inside an initramfs, brings up the network,
# fetches an **OS package** (OSPKG: a .zip of kernel+initramfs+cmdline plus a .json
# descriptor carrying Ed25519 signatures), VERIFIES the signatures against a baked-in
# root certificate + threshold, and only then kexecs it. This is the strict tier of
# the lab: P1 fetched over HTTP, P2 verified the transport (HTTPS/lab-CA); P3 verifies
# the *artifact itself* is signed by a trusted key.
#
# WHY it fits this lab: stboot is a **UEFI executable packaged as a UKI** — exactly what
# Tier B already builds+boots with OVMF. So P3 runs on the genuine-UEFI/OVMF path
# (stboot's native model); coreboot-native stboot is an upstream-future frontier (P3b).
#
# WHAT this script produces (all under $WORKDIR):
#   st-p3/bin/stmgr, st-p3/bin/stboot   — the toolchain (Go 1.25, no sudo, static stboot)
#   stboot-esp.img                      — a FAT ESP holding the stboot UKI (OVMF boots it)
#   st-trust/                           — the trust policy baked into the UKI (lab-CA rooted)
#
# The UKI is **OS-agnostic**: its host config points at a fixed OSPKG URL
# (https://10.0.2.2:8443/stboot-ospkg.json); `make-ospkg.sh <os>` decides which
# installer that pointer resolves to. One UKI provisions Alma/Rocky/Kali — the same
# "one artifact, any OS" property as the P1 ROM.
#
#   ./fetch-go.sh                # Go 1.25 (shared with u-root main; ST needs >=1.24)
#   ./build-st.sh                # build toolchain + stboot UKI/ESP
#   ./make-ospkg.sh alma         # wrap+sign an installer as the OSPKG
#   ./run-stboot.sh alma         # OVMF: stboot verifies + kexecs   (see run-stboot.sh)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
LABCA="${LABCA:-$HERE/../lab-ca}"
STVER="${STVER:-v0.7.0}"                       # pinned System Transparency release (2026-07)
GLASKLAR="https://git.glasklar.is/system-transparency/core"

# --- Go toolchain (no sudo): reuse the same tree fetch-go.sh stages for u-root main ---
GOBIN_DIR="${UROOT_GOBIN:-$WORKDIR/go1.25/bin}"
[[ -x "$GOBIN_DIR/go" ]] || { echo "no Go at $GOBIN_DIR — run ./fetch-go.sh first" >&2; exit 1; }
export PATH="$GOBIN_DIR:$PATH" GOTOOLCHAIN=local
export GOPATH="$WORKDIR/st-p3/gopath" GOCACHE="$WORKDIR/st-p3/gocache" GOFLAGS=-mod=mod
SRC="$WORKDIR/st-p3"; BIN="$SRC/bin"; mkdir -p "$BIN"
echo "==> Go: $(go version)   (GOTOOLCHAIN=local)"

# --- 1. clone + build stmgr and stboot (stboot STATIC so it can be PID 1 init) ------
clone() { [[ -d "$SRC/$1" ]] || { echo "==> cloning $1 $STVER"; git clone --depth 1 -b "$STVER" "$GLASKLAR/$1.git" "$SRC/$1" 2>&1 | tail -1; }; }
clone stmgr; clone stboot
if [[ ! -x "$BIN/stmgr" ]]; then echo "==> building stmgr"; ( cd "$SRC/stmgr" && go build -o "$BIN/stmgr" . ); fi
if [[ ! -x "$BIN/stboot" ]]; then echo "==> building stboot (CGO_ENABLED=0 → static init)"; ( cd "$SRC/stboot" && CGO_ENABLED=0 go build -o "$BIN/stboot" . ); fi
file "$BIN/stboot" | grep -q 'statically linked' || { echo "stboot is not static — it must be, to run as init" >&2; exit 1; }
echo "    stmgr : $("$BIN/stmgr" 2>&1 | head -1)"
echo "    stboot: $(file "$BIN/stboot" | sed 's/.*: //; s/,.*//')"

# --- 2. an EFISTUB kernel for the stboot UKI + its e1000 driver --------------------
# The stboot bootloader itself needs a kernel with EFI_STUB (OVMF launches the UKI)
# and a NIC driver. We reuse the AlmaLinux pxeboot vmlinuz (EFISTUB ✓, same kernel the
# lab already boots at Tier B) and extract just **e1000.ko** from its initrd. e1000 is
# a single module with no loadable deps (unlike virtio-net's virtio/virtio_ring chain),
# so u-root's libinit.InstallAllModules() — which loads every *.ko it finds flat in
# /lib/modules and decompresses .xz itself — loads it with zero fuss. Hence the VM gets
# an `-device e1000` NIC (see run-stboot.sh).
KERNEL="${KERNEL:-$WORKDIR/vmlinuz}"
[[ -f "$KERNEL" ]] || { echo "no EFISTUB kernel at $KERNEL — run ./fetch-kernel.sh" >&2; exit 1; }
INITRD_SRC="${INITRD_SRC:-$HOME/netboot/initrd.img}"           # AlmaLinux pxeboot initrd (has the .ko)
KVER="$(set +o pipefail; strings "$KERNEL" | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9.]+\.el9[_0-9]*\.x86_64')"
echo "==> stboot kernel: $KERNEL  (linux $KVER, EFISTUB)"
MODDIR="$SRC/e1000"; mkdir -p "$MODDIR"
if [[ ! -f "$MODDIR/e1000.ko" ]]; then
  echo "==> extracting e1000.ko from $INITRD_SRC"
  [[ -f "$INITRD_SRC" ]] || { echo "no $INITRD_SRC — run ./fetch-netboot-os.sh alma" >&2; exit 1; }
  xz -dc "$INITRD_SRC" | ( cd "$MODDIR" && cpio -idu --no-absolute-filenames \
      "usr/lib/modules/$KVER/kernel/drivers/net/ethernet/intel/e1000/e1000.ko*" 2>/dev/null )
  KO="$(set +o pipefail; find "$MODDIR" -name 'e1000.ko*' | head -1)"
  [[ -n "$KO" ]] || { echo "e1000.ko not found in initrd" >&2; exit 1; }
  case "$KO" in *.xz) xz -dc "$KO" > "$MODDIR/e1000.ko" ;; *) cp "$KO" "$MODDIR/e1000.ko" ;; esac
  echo "    e1000.ko: $(du -h "$MODDIR/e1000.ko" | cut -f1)"
fi

# --- 3. the trust policy (lab-CA rooted) -------------------------------------------
# stboot reads these from /etc/trust_policy/ in its initramfs:
#   trust_policy.json          — how many sigs are required + where to fetch
#   ospkg_signing_root.pem     — the root the OSPKG signature must chain to  = lab-ca.crt
#   tls_roots.pem              — the root the HTTPS server cert must chain to = lab-ca.crt
# The SAME shared lab-ca.crt anchors both transport (TLS) and artifact (signature) —
# the §6b "one trust anchor" payoff. Note lab-ca is an ECDSA P-256 root signing an
# Ed25519 OSPKG-signing leaf (issue-signing-cert.sh); stboot's x509 verify accepts the
# mixed chain (ECDSA CA → Ed25519 leaf) — proven in POC-PXEBOOT-P3.md.
[[ -f "$LABCA/lab-ca.crt" ]] || { echo "no lab CA — run ../lab-ca/make-ca.sh" >&2; exit 1; }
TRUST="$SRC/st-trust"; mkdir -p "$TRUST"
cat > "$TRUST/trust_policy.json" <<'EOF'
{
  "ospkg_signature_threshold": 1,
  "ospkg_fetch_method": "network"
}
EOF
cp "$LABCA/lab-ca.crt" "$TRUST/ospkg_signing_root.pem"
cp "$LABCA/lab-ca.crt" "$TRUST/tls_roots.pem"
"$BIN/stmgr" trustpolicy check "$(cat "$TRUST/trust_policy.json")" >/dev/null && echo "==> trust_policy.json valid (threshold=1, network)"

# --- 4. the host configuration (STATIC net — u-root dhclient is dead over slirp) ----
# THE key P3 gotcha: stboot's `network_mode:dhcp` uses u-root/pkg/dhclient — the SAME
# client whose AF_PACKET broadcast emits 0 packets over QEMU slirp (the P1 blocker).
# P1 dodged it with kernel `ip=dhcp`, but stboot configures the NIC itself in Go
# userspace (no kernel-cmdline escape hatch), so P3 uses stboot's **static** mode:
# configureStatic() is pure netlink (AddrAdd + IfUp + RouteAdd, no DHCP send) and works
# over slirp exactly like a manual `ip addr add` does. slirp gives us 10.0.2.15/24,
# gateway/DNS 10.0.2.2/10.0.2.3, host at 10.0.2.2.
OSPKG_URL="${OSPKG_URL:-https://10.0.2.2:8443/stboot-ospkg.json}"
HOSTCFG="$SRC/host_configuration.json"
cat > "$HOSTCFG" <<EOF
{
  "network_mode": "static",
  "host_ip": "10.0.2.15/24",
  "gateway": "10.0.2.2",
  "dns": ["10.0.2.3"],
  "network_interfaces": null,
  "ospkg_pointer": "$OSPKG_URL"
}
EOF
"$BIN/stmgr" hostconfig check "$(cat "$HOSTCFG")" >/dev/null && echo "==> host_configuration.json valid (static 10.0.2.15 → $OSPKG_URL)"

# --- 5. assemble the stboot initramfs (unprivileged cpio) ---------------------------
# Layout mirrors upstream's integration harness, minus modules-load.d (we drop e1000.ko
# flat in /lib/modules so InstallAllModules loads it directly):
#   /init                              → the static stboot binary (PID 1)
#   /lib/modules/e1000.ko              → NIC driver, auto-loaded by libinit
#   /etc/trust_policy/*                → policy + lab-CA roots
#   /etc/host_configuration.json       → static net + OSPKG pointer
IRD="$SRC/stboot-initramfs.d"; rm -rf "$IRD"; mkdir -p "$IRD/lib/modules" "$IRD/etc/trust_policy"
cp "$BIN/stboot" "$IRD/init"; chmod +x "$IRD/init"
cp "$MODDIR/e1000.ko" "$IRD/lib/modules/e1000.ko"
cp "$TRUST/trust_policy.json" "$TRUST/ospkg_signing_root.pem" "$TRUST/tls_roots.pem" "$IRD/etc/trust_policy/"
cp "$HOSTCFG" "$IRD/etc/host_configuration.json"
CPIO="$SRC/stboot-initramfs.cpio.gz"
( cd "$IRD" && find . | cpio -o -H newc -R 0:0 2>/dev/null | gzip -9 ) > "$CPIO"
echo "==> stboot initramfs: $(du -h "$CPIO" | cut -f1)"

# --- 6. UKI (stmgr embeds its own systemd-style EFI stub) + FAT ESP -----------------
# `stmgr uki create -format uki` fuses kernel+initramfs+cmdline into ONE PE/EFI app,
# just like Tier B's ukify — but ST-native (no separate systemd-ukify needed). The
# cmdline's `--` splits kernel args from stboot's own args (--loglevel=debug so the
# verification steps are visible on the serial log).
UKI="$SRC/stboot.uki"
"$BIN/stmgr" uki create -format uki -force -out "$UKI" \
  -kernel "$KERNEL" -initramfs "$CPIO" \
  -cmdline 'console=ttyS0,115200n8 -- --loglevel=debug'
# stmgr writes <out>.uki when -format uki; normalize the name
[[ -f "$UKI" ]] || UKI="$(set +o pipefail; ls "$SRC"/stboot.uki* 2>/dev/null | head -1)"
echo "==> UKI: $UKI  ($(du -h "$UKI" | cut -f1))"

ESP="$WORKDIR/stboot-esp.img"
rm -f "$ESP"; truncate -s 96M "$ESP"; mkfs.vfat -n STBOOT "$ESP" >/dev/null
mmd -i "$ESP" ::/EFI ::/EFI/BOOT
mcopy -i "$ESP" "$UKI" ::/EFI/BOOT/BOOTX64.EFI
echo "==> stboot ESP ready: $ESP"
echo
echo "Next:  ./make-ospkg.sh <alma|rocky|kali>   then   ./run-stboot.sh <os>"

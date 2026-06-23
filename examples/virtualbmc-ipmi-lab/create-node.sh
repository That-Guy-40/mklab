#!/usr/bin/env bash
# create-node.sh — define the libvirt domain that VirtualBMC will manage.
#
# VirtualBMC's ONLY driver is libvirt: `vbmc add <domain>` registers a libvirt
# *domain* by name, and vbmcd actuates power through the libvirt API.  So before
# any IPMI can happen we need a real libvirt domain on the host.  This script
# downloads a tiny Alpine cloud image and defines a domain called "alpine-node"
# in qemu:///system, left SHUT OFF so the spike can demonstrate off -> on over
# IPMI.
#
# Runs on the HOST (needs libvirt + KVM).  Idempotent: re-running rebuilds the
# overlay disk and redefines the domain from a clean base.
#
# Knobs (env):
#   NODE        domain name           (default: alpine-node)
#   DISK_DIR    where the domain disk lives (default: /var/lib/libvirt/images)
#   ALPINE_URL  cloud-image directory (default: Alpine latest-stable / cloud)
#   MEMORY_MB   guest RAM             (default: 512)
#   VCPUS       guest vCPUs           (default: 1)
#   ROOT_PW     guest root password   (default: alpine) — throwaway lab cred
#   NET         libvirt network       (default: default; use vbmc-pxe for step 3)
#   DISK_SIZE   grow the node disk to this (e.g. 10G) — room for a PXE OS install
set -euo pipefail

NODE="${NODE:-alpine-node}"
NET="${NET:-default}"
DISK_DIR="${DISK_DIR:-/var/lib/libvirt/images}"
DISK_SIZE="${DISK_SIZE:-}"
ALPINE_URL="${ALPINE_URL:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/cloud}"
MEMORY_MB="${MEMORY_MB:-512}"
VCPUS="${VCPUS:-1}"
ROOT_PW="${ROOT_PW:-alpine}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cache="$here/cache"

command -v virsh        >/dev/null || { echo "virsh not found — apt install libvirt-clients" >&2; exit 1; }
command -v virt-install >/dev/null || { echo "virt-install not found — apt install virtinst"  >&2; exit 1; }
command -v qemu-img     >/dev/null || { echo "qemu-img not found — apt install qemu-utils"     >&2; exit 1; }
# We hand the guest a NoCloud seed ISO (see §2b) — need one ISO builder.
command -v cloud-localds >/dev/null || command -v genisoimage >/dev/null || command -v xorriso >/dev/null || {
    echo "no ISO builder found — apt install cloud-image-utils (cloud-localds) or genisoimage" >&2; exit 1; }

# Run libvirt ops against the SYSTEM instance (what the containerised vbmcd will
# also talk to via the mounted socket).  Most Ubuntu setups need root (or
# membership in the 'libvirt' group) for qemu:///system.
VIRSH="virsh -c qemu:///system"

# --- 1. fetch the Alpine base image -----------------------------------------
# Alpine's headless qcow2 is the "generic_alpine-<ver>-x86_64-bios-cloudinit-rN"
# image.  Filenames are version-stamped, so discover the current one rather than
# hardcode it (auto-tracks latest-stable).
mkdir -p "$cache"
echo "==> discovering current Alpine generic (bios) cloud image under:"
echo "    $ALPINE_URL/"
img="$(curl -fsSL "$ALPINE_URL/" \
        | grep -oE 'generic_alpine-[0-9.]+-x86_64-bios-cloudinit-r[0-9]+\.qcow2' \
        | sort -V | tail -1)"
[[ -n "$img" ]] || { echo "could not find a generic bios qcow2 at $ALPINE_URL/ — set ALPINE_URL" >&2; exit 1; }
echo "    -> $img"

base="$cache/$img"
if [[ ! -f "$base" ]]; then
    echo "==> downloading $img"
    curl -fSL --progress-bar -o "$base.part" "$ALPINE_URL/$img"
    mv "$base.part" "$base"          # atomic: a half-download never poses as complete
else
    echo "==> base already cached: $base"
fi

# --- 2. install a STANDALONE node disk into the libvirt pool ----------------
# We FLATTEN the base into the pool instead of using a CoW overlay.  Why: qemu
# runs as uid 'libvirt-qemu' and opens the *entire* backing chain at boot.  An
# overlay in the pool whose backing file sits OUTSIDE the pool (here, the
# download cache on the external COLD_STORAGE mount) fails with "Cannot access
# backing file ... Permission denied" — libvirt-qemu can't read across into
# /media/... (external mount; AppArmor only whitelists /var/lib/libvirt/images).
# `qemu-img convert` collapses the image into ONE self-contained file in the
# pool, with no out-of-pool dependency.  (Re-running rewrites it = a clean node.)
disk="$DISK_DIR/$NODE.qcow2"
echo "==> installing standalone node disk into the pool: $disk"
sudo qemu-img convert -f qcow2 -O qcow2 "$base" "$disk"

# Grow the disk if asked — a PXE OS install (Anaconda/kickstart) needs more room
# than Alpine's ~1 GB image.  qcow2 grows the *virtual* size only (sparse); the
# installer repartitions the whole disk, so the Alpine content is wiped — fine,
# the node is just a provisioning target then.
if [[ -n "$DISK_SIZE" ]]; then
    echo "==> growing node disk to $DISK_SIZE"
    sudo qemu-img resize "$disk" "$DISK_SIZE"
fi

# --- 2b. NoCloud seed: make the node usable over the SERIAL console ----------
# The VM is headless (--graphics none), so we drive it over libvirt's serial
# console.  Alpine's generic *cloud* image puts its login on the VGA console
# (tty0) — invisible here — so serial showed only the kernel boot.
#
# We can't edit the image offline (libguestfs/virt-customize dies with "passt
# exited with status 1" on this host, both libvirt and direct backends).  So
# instead we hand the guest its OWN config via a NoCloud datasource: a tiny
# CIDATA ISO that cloud-init reads at FIRST boot.  No libguestfs, no appliance.
# The cloud-config:
#   1. sets a known root password               (so we can log in);
#   2. adds a getty bound directly to ttyS0      (opens /dev/ttyS0 itself, so it
#      shows a serial login no matter which console= is primary);
#   3. allows root logins on ttyS0               (Alpine gates via securetty);
#   4. `kill -HUP 1` so busybox-init re-reads inittab and spawns the getty now
#      (no second reboot needed).
seed="$DISK_DIR/$NODE-seed.iso"
ud="$cache/user-data"; md="$cache/meta-data"

cat > "$md" <<EOF
instance-id: $NODE
local-hostname: $NODE
EOF

# Unquoted heredoc: $ROOT_PW expands; \$ stays a literal $ (the securetty anchor).
cat > "$ud" <<EOF
#cloud-config
# Throwaway lab creds — loopback/lab only, never a real or networked host.
ssh_pwauth: true
chpasswd:
  expire: false
  list: |
    root:$ROOT_PW
runcmd:
  - [ sh, -c, "grep -q '^ttyS0:' /etc/inittab   || echo 'ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100' >> /etc/inittab" ]
  - [ sh, -c, "grep -q '^ttyS0\$' /etc/securetty || echo ttyS0 >> /etc/securetty" ]
  - [ sh, -c, "kill -HUP 1" ]
EOF

echo "==> building NoCloud seed ISO: $seed"
if command -v cloud-localds >/dev/null; then
    sudo cloud-localds "$seed" "$ud" "$md"
elif command -v genisoimage >/dev/null; then
    sudo genisoimage -quiet -output "$seed" -volid cidata -joliet -rock "$ud" "$md"
else
    sudo xorriso -as mkisofs -quiet -o "$seed" -V cidata -J -r "$ud" "$md"
fi

# --- 3. (re)define the domain, SHUT OFF -------------------------------------
if $VIRSH dominfo "$NODE" >/dev/null 2>&1; then
    echo "==> existing domain $NODE found — destroying + undefining for a clean define"
    $VIRSH destroy  "$NODE" >/dev/null 2>&1 || true
    $VIRSH undefine "$NODE" --nvram >/dev/null 2>&1 || $VIRSH undefine "$NODE" >/dev/null 2>&1 || true
fi

# --graphics none gives a serial console (needed later for IPMI Serial-over-LAN);
# --import boots an existing disk (no installer); --print-xml + `virsh define`
# defines WITHOUT starting, so the node begins powered OFF.
echo "==> defining domain $NODE (off): ${MEMORY_MB}MB / ${VCPUS} vCPU / virtio / serial console"
virt-install \
    --connect qemu:///system \
    --name "$NODE" \
    --memory "$MEMORY_MB" \
    --vcpus "$VCPUS" \
    --import \
    --disk "path=$disk,format=qcow2,bus=virtio" \
    --disk "path=$seed,device=cdrom" \
    --osinfo detect=on,require=off \
    --network network=$NET,model=virtio \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole \
    --print-xml > "$cache/$NODE.xml"

sudo $VIRSH define "$cache/$NODE.xml"

echo
echo "==> defined.  current power state:"
$VIRSH domstate "$NODE"
echo
echo "    serial login (via ./vbmc-lab.sh console):  root / $ROOT_PW"
echo "    NOTE: login appears AFTER cloud-init runs on first boot (~30-60s after power on)"
echo
echo "Next: build + start the BMC and do the IPMI round-trip — see RUNBOOK.md,"
echo "or:  ./vbmc-lab.sh build && ./vbmc-lab.sh up && ./vbmc-lab.sh add && ./vbmc-lab.sh power status"

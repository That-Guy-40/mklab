#!/usr/bin/env bash
# setup-pxe-net.sh — stand up the PXE side of the lab.
#
# The hard part of "IPMI bootdev pxe -> the node netboots" is L2: PXE is a DHCP
# broadcast, so the node and a DHCP/TFTP server must share a broadcast domain.
# Rather than bridge a podman container onto a libvirt segment, we let LIBVIRT'S
# OWN dnsmasq be the PXE server: a dedicated network whose <dhcp> serves the
# range + a <bootp> file, and whose <tftp> root hands out boot.ipxe.  The heavy
# kernel/initrd come over HTTP from the repo's existing rootless nginx
# (~/netboot on :8181), reached at the network's gateway IP.
#
#   node (vbmc-pxe NIC) ──DHCP/TFTP──> libvirt dnsmasq @ <gw>      (boot.ipxe)
#                        ──HTTP──────> host nginx @ <gw>:8181      (kernel/initrd)
#
# The node's NIC already carries an iPXE option ROM (QEMU virtio), which runs
# the boot.ipxe SCRIPT we serve.  Payload is selectable:
#   PAYLOAD=busybox    (default) tiny kernel + RAM initrd -> a serial shell.
#                      Self-contained: no stage2, kickstart, or internet — it
#                      isolates and proves JUST the netboot path.
#   PAYLOAD=almalinux  the real AlmaLinux 9 Anaconda installer (reuses the
#                      almalinux-pxe-lab assets) — the faithful provisioning run.
#
# Knobs (env): NET SUBNET BRIDGE TFTP_DIR HTTP_DIR HTTP_PORT PAYLOAD
set -euo pipefail

NET="${NET:-vbmc-pxe}"
SUBNET="${SUBNET:-192.168.123}"        # /24; gateway = $SUBNET.1
GW="$SUBNET.1"
BRIDGE="${BRIDGE:-virbr-vbmc}"         # must be <= 15 chars
TFTP_DIR="${TFTP_DIR:-/var/lib/libvirt/tftp-vbmc}"   # libvirt-tree path: dnsmasq + AppArmor friendly
HTTP_DIR="${HTTP_DIR:-/home/sqs/netboot}"            # repo's nginx docroot
HTTP_PORT="${HTTP_PORT:-8181}"         # 8181 is intentional on this host (SABnzbd owns 8080)
PAYLOAD="${PAYLOAD:-busybox}"
ROOT_PW="${ROOT_PW:-alpine}"           # installed node's root pw (throwaway lab cred)
PODMAN="${PODMAN:-podman}"             # rootless: publishes the port on the host netns
VIRSH="virsh -c qemu:///system"

command -v virsh >/dev/null || { echo "virsh not found — apt install libvirt-clients" >&2; exit 1; }

# --- 1. TFTP root + boot.ipxe (gateway IP baked in, not ${next-server}) ------
# We hardcode $GW rather than rely on iPXE's ${next-server} so the script is
# deterministic regardless of how libvirt's dnsmasq fills siaddr.
echo "==> TFTP root $TFTP_DIR + boot.ipxe (payload: $PAYLOAD, http://$GW:$HTTP_PORT/)"
sudo mkdir -p "$TFTP_DIR"
case "$PAYLOAD" in
  busybox)
    # Unquoted heredoc: $GW/$HTTP_PORT expand; \${mac} stays an iPXE variable.
    sudo tee "$TFTP_DIR/boot.ipxe" >/dev/null <<EOF
#!ipxe
:start
dhcp || goto retry
echo
echo *** VirtualBMC PXE bridge: \${mac} netbooting via IPMI bootdev=pxe ***
kernel http://$GW:$HTTP_PORT/kernel console=ttyS0 root=/dev/ram0 rw || goto retry
initrd http://$GW:$HTTP_PORT/initrd.gz || goto retry
boot || goto retry
:retry
echo iPXE step failed -- retry in 3s ; sleep 3 ; goto start
EOF
    ;;
  almalinux)
    # Generate a LAB kickstart for a clean whole-disk install.  (AlmaLinux's
    # stock gencloud .ks rebuilds their cloud IMAGE and references a pre-existing
    # vda2 — it fails on a blank disk with "Partition vda2 does not exist".)
    # Written into the HTTP docroot so Anaconda fetches it over HTTP; packages
    # come from the public mirror (the node has NAT egress).
    echo "==> writing lab kickstart $HTTP_DIR/vbmc-almalinux.ks (clearpart+autopart on vda)"
    cat > "$HTTP_DIR/vbmc-almalinux.ks" <<KSEOF
text
lang en_US.UTF-8
keyboard us
timezone UTC --utc
url --url="https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/"
repo --name=AppStream --baseurl="https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/"
network --bootproto=dhcp --device=link --activate
rootpw --plaintext $ROOT_PW
firewall --disabled
selinux --permissive
clearpart --all --initlabel --drives=vda
autopart --type=plain --nohome
bootloader --location=mbr --boot-drive=vda --append="console=ttyS0,115200"
# poweroff (not reboot): bootdev is still pxe, so a reboot would loop back into
# the installer.  Powering off lets you flip bootdev=disk, then boot the
# freshly-installed OS — the full IPMI provisioning lifecycle.
poweroff
%packages
@^minimal-environment
%end
KSEOF
    sudo tee "$TFTP_DIR/boot.ipxe" >/dev/null <<EOF
#!ipxe
:start
dhcp || goto retry
kernel http://$GW:$HTTP_PORT/vmlinuz inst.stage2=http://$GW:$HTTP_PORT/ inst.ks=http://$GW:$HTTP_PORT/vbmc-almalinux.ks inst.text console=ttyS0 ip=dhcp || goto retry
initrd http://$GW:$HTTP_PORT/initrd.img || goto retry
boot || goto retry
:retry
echo iPXE step failed -- retry in 3s ; sleep 3 ; goto start
EOF
    ;;
  *) echo "PAYLOAD must be busybox|almalinux (got: $PAYLOAD)" >&2; exit 2 ;;
esac

# --- 2. libvirt network: dnsmasq DHCP + TFTP + bootp ------------------------
xml="$(mktemp)"
cat > "$xml" <<EOF
<network>
  <name>$NET</name>
  <forward mode='nat'/>
  <bridge name='$BRIDGE' stp='on' delay='0'/>
  <ip address='$GW' netmask='255.255.255.0'>
    <tftp root='$TFTP_DIR'/>
    <dhcp>
      <range start='$SUBNET.10' end='$SUBNET.99'/>
      <bootp file='boot.ipxe'/>
    </dhcp>
  </ip>
</network>
EOF

# IMPORTANT: do every libvirt read with the SAME privilege as the writes (sudo).
# A non-root `virsh -c qemu:///system net-info` can return without a clean
# "Active: yes" line (polkit/group nuance), which made an *active* network look
# inactive and then `sudo net-start` died with "network is already active".
# Structure: (1) define-if-missing, (2) start-if-not-active — both idempotent,
# and we NEVER destroy an active network (that orphans the tap of any attached
# domain — its NIC silently loses L2 until a COLD power-cycle; warm `reset` does
# NOT re-bridge it).  The net config is payload-independent — switching PAYLOAD
# only rewrote boot.ipxe in the TFTP root above, served live by dnsmasq.  (To
# change the net itself, `./vbmc-lab.sh pxe-down` first.)
SVIRSH="sudo $VIRSH"

if ! $SVIRSH net-info "$NET" >/dev/null 2>&1; then
    echo "==> defining libvirt network $NET ($GW/24, NAT, dnsmasq tftp/bootp)"
    $SVIRSH net-define "$xml"
    $SVIRSH net-autostart "$NET" 2>/dev/null || true
fi

if $SVIRSH net-info "$NET" 2>/dev/null | grep -qi 'Active:.*yes'; then
    echo "==> network $NET already active — leaving it up (boot.ipxe updated in place)"
else
    echo "==> starting libvirt network $NET"
    $SVIRSH net-start "$NET" 2>/dev/null \
        || echo "==> network $NET already active (start raced) — leaving it up"
    $SVIRSH net-autostart "$NET" 2>/dev/null || true
fi
rm -f "$xml"

# --- 3. HTTP payload server (reuse an existing :8181, else start one) --------
echo "==> ensuring HTTP payload server at http://$GW:$HTTP_PORT/ (docroot $HTTP_DIR)"
if curl -sf -o /dev/null "http://$GW:$HTTP_PORT/" 2>/dev/null; then
    echo "    something already serves $GW:$HTTP_PORT — reusing it"
else
    echo "    starting rootless nginx 'vbmc-http' bound to $GW:$HTTP_PORT"
    $PODMAN rm -f vbmc-http >/dev/null 2>&1 || true
    $PODMAN run -d --name vbmc-http \
        -p "$GW:$HTTP_PORT:80" \
        -v "$HTTP_DIR:/usr/share/nginx/html:ro" \
        docker.io/library/nginx:alpine >/dev/null
    sleep 1
    curl -sf -o /dev/null "http://$GW:$HTTP_PORT/kernel" \
        && echo "    OK: http://$GW:$HTTP_PORT/kernel reachable" \
        || echo "    WARN: $GW:$HTTP_PORT not reachable yet — check rootless port binding / firewall" >&2
fi

echo
echo "==> PXE side up:"; $VIRSH net-info "$NET" | sed 's/^/    /'
cat <<EOF

Next (put the node on this network, then netboot it over IPMI):
  NET=$NET ./create-node.sh
  ./vbmc-lab.sh up && ./vbmc-lab.sh add
  ./vbmc-lab.sh netboot             # bootdev=pxe + power on + attaches the console (watch it netboot)
Teardown:  ./vbmc-lab.sh pxe-down
EOF

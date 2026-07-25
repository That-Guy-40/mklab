#!/bin/sh
# probe-init.sh — the MAAS inspection probe's /init (busybox ash; POSIX sh).
#
# Booted as a tiny busybox initramfs over PXE (bootdev=pxe), it reads schedulable
# facts from /proc + /sys, POSTs them as JSON to the MAAS metadata service, and
# powers the node off — Ironic hardware introspection, in miniature. The node
# learns its identity + where to report from the kernel cmdline:
#     maas.node=<name>  maas.md=http://<gw>:8282
#
# The console banners are milestone anchors for `maas-lab.sh watch --profile probe`
# (see milestones.toml): "MAAS inspection probe" → "collected facts cpus=N" →
# "facts posted".
#
# HTTP client = busybox `wget --post-data` (no curl in these images; confirmed). It
# sends Content-Type form-urlencoded but the BODY is the raw JSON string, which the
# metadata service reads directly.
#
# TEST MODE: `probe-init.sh --emit` gathers facts from $PROC_ROOT/$SYS_ROOT (default
# /proc, /sys) and prints ONLY the JSON — no mount, no network, no poweroff — so the
# fact logic is unit-testable headlessly.
set -u

PROC_ROOT="${PROC_ROOT:-/proc}"
SYS_ROOT="${SYS_ROOT:-/sys}"

# gather_json — emit the schedulable-facts JSON from $PROC_ROOT/$SYS_ROOT.
gather_json() {
    cpus=$(grep -c '^processor' "$PROC_ROOT/cpuinfo" 2>/dev/null || echo 0)
    mem_kb=$(awk '/^MemTotal/{print $2; exit}' "$PROC_ROOT/meminfo" 2>/dev/null || echo 0)
    arch=$(uname -m 2>/dev/null || echo unknown)
    # first non-loopback NIC MAC
    mac=unknown
    for n in "$SYS_ROOT"/class/net/*; do
        [ -e "$n/address" ] || continue
        case "${n##*/}" in lo) continue ;; esac
        mac=$(cat "$n/address" 2>/dev/null) && break
    done
    printf '{"cpus":%s,"mem_kb":%s,"arch":"%s","mac":"%s"}\n' \
        "${cpus:-0}" "${mem_kb:-0}" "$arch" "$mac"
}

# ---- test mode: emit facts and stop -----------------------------------------
if [ "${1:-}" = "--emit" ]; then
    gather_json
    exit 0
fi

# ---- real /init -------------------------------------------------------------
mount -t proc     none /proc  2>/dev/null || true
mount -t sysfs    none /sys   2>/dev/null || true
mount -t devtmpfs none /dev   2>/dev/null || true
[ -c /dev/console ] && exec 0<>/dev/console 1>&0 2>&0

echo
echo "MAAS inspection probe: booting"

# identity + metadata URL from the kernel cmdline
node=$(sed -n 's/.*maas\.node=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null)
mdurl=$(sed -n 's/.*maas\.md=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null)
: "${node:=unknown}"
: "${mdurl:=http://192.168.123.1:8282}"

# bring up networking (busybox udhcpc) so we can reach the metadata service
ifconfig lo up 2>/dev/null || true
ifconfig eth0 up 2>/dev/null || true
udhcpc -i eth0 -t 8 -n -q 2>/dev/null || echo "MAAS inspection probe: DHCP failed (continuing)"

json=$(gather_json)
cpus=$(printf '%s' "$json" | sed -n 's/.*"cpus":\([0-9]*\).*/\1/p')
echo "MAAS inspection probe: collected facts cpus=${cpus} node=${node}"

# POST the facts to the metadata service; retry a few times
posted=no
i=0
while [ "$i" -lt 5 ]; do
    if wget -q -O- --post-data="$json" "$mdurl/facts/$node" >/dev/null 2>&1; then
        posted=yes; break
    fi
    i=$((i+1)); sleep 2
done

if [ "$posted" = yes ]; then
    echo "MAAS inspection probe: facts posted (introspection complete)"
else
    echo "MAAS inspection probe: FAILED to post facts to $mdurl (node -> error at the control plane)"
fi

sync
echo "MAAS inspection probe: powering off"
poweroff -f

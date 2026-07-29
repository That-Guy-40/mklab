#!/bin/busybox sh
# deployer-init.sh — the DEPLOYER RAMDISK's /init, for `deploy --driver image`.
#
# It netboots, streams a golden whole-disk raw over HTTP straight onto the node's
# disk, announces the result on the console, and reboots. That is the whole job.
#
# Kernel cmdline (written by drivers/image.sh into the node's iPXE script):
#   maas.node=<name>   who this machine is (console/audit only)
#   maas.image=<name>  what is being laid down (console/audit only)
#   maas.url=<url>     the raw image to stream
#   maas.disk=<dev>    optional target override (default: pick the first disk)
#
# THE MARKER CONTRACT. `drivers/image.sh` gates on this ramdisk's console output
# (WRITE_DONE_RE, mirrored by the `image` profile in milestones.toml), so the
# lines below are an interface, not logging:
#
#   MAAS-DEPLOY: ... bytes copied     -> the write finished  (the driver proceeds)
#   MAAS-DEPLOY: FAILED ...           -> it did not         (the driver times out)
#
# Failure is announced and then PARKED, never rebooted. A deployer that reboots
# after a failed write hands the node back to PXE, which re-runs this script —
# a re-imaging loop that looks, from outside, exactly like a slow install. The
# console keeps saying why, and the driver's timeout is the honest outcome.
#
# STREAMED, NOT BUFFERED: `wget -O- | dd of=<disk>` never holds the image in RAM,
# so a 4 GB golden image lays down on a node with 512 MB. Buffering it first is
# how a deployer ramdisk OOMs on exactly the images it exists to write.
set -u

say() { /bin/busybox echo "MAAS-DEPLOY: $*"; }

/bin/busybox mount -t proc     none /proc 2>/dev/null
/bin/busybox mount -t sysfs    none /sys  2>/dev/null
/bin/busybox mount -t devtmpfs none /dev  2>/dev/null

# Everything the ramdisk knows comes from the cmdline the control plane wrote.
node=""; image=""; url=""; disk=""; want_sha=""; want_bytes=""
for arg in $(/bin/busybox cat /proc/cmdline 2>/dev/null); do
    case "$arg" in
        maas.node=*)   node="${arg#maas.node=}" ;;
        maas.image=*)  image="${arg#maas.image=}" ;;
        maas.url=*)    url="${arg#maas.url=}" ;;
        maas.disk=*)   disk="${arg#maas.disk=}" ;;
        maas.sha256=*) want_sha="${arg#maas.sha256=}" ;;
        maas.bytes=*)  want_bytes="${arg#maas.bytes=}" ;;
    esac
done
say "deployer ramdisk up — node='${node:-?}' image='${image:-?}'"

if [ -z "$url" ]; then
    say "FAILED: no maas.url= on the kernel command line — nothing to write"
    say "parking (no reboot: a reboot would re-PXE and loop)"
    exec /bin/busybox sh
fi

# NETWORK — and never silently. The first live run hung HERE, with no output at
# all: the driver's cmdline lacked `ip=dhcp`, so the kernel left eth0 down, and
# udhcpc sat on it while its complaints went to the /dev/null this line used to
# carry. A deployer that stalls in silence is indistinguishable from one that is
# slowly writing a disk — the operator waits out the full write timeout for
# nothing. So: bring the link up ourselves, keep udhcpc's stderr on the console,
# and PROVE we have an address before going near the network.
/bin/busybox ifconfig eth0 up 2>&1 | /bin/busybox grep . && say "note: ifconfig eth0 up complained (above)"
if ! /bin/busybox ip addr show eth0 2>/dev/null | /bin/busybox grep -q 'inet '; then
    say "no address on eth0 yet (kernel ip= did not configure it) — running udhcpc"
    # -s explicitly: the compiled-in script path differs between busyboxes (Ubuntu
    # says /etc/udhcpc, micro-linux says /usr/share/udhcpc), and a missing script
    # means udhcpc takes the lease and applies NOTHING, with no error.
    /bin/busybox udhcpc -i eth0 -t 8 -n -q -s /usr/share/udhcpc/default.script 2>&1 \
        | /bin/busybox grep -v '^$'
fi
addr="$(/bin/busybox ip addr show eth0 2>/dev/null | /bin/busybox sed -nE 's@.*inet ([0-9.]+)/.*@\1@p' | /bin/busybox head -1)"
if [ -z "$addr" ]; then
    say "FAILED: eth0 has no IPv4 address — the image cannot be fetched."
    say "  The kernel command line needs ip=dhcp (drivers/image.sh writes it), or"
    say "  this network has no DHCP server reachable from the node."
    say "parking (no reboot: a reboot would re-PXE and loop)"
    exec /bin/busybox sh
fi
say "network up: eth0 = $addr"

# THE TARGET DISK. Guessing wrong here overwrites the wrong device, so the choice
# is explicit and printed: an operator-supplied maas.disk wins; otherwise the
# first whole disk that is not removable and not the ramdisk itself.
if [ -z "$disk" ]; then
    for d in /sys/block/vd* /sys/block/sd* /sys/block/nvme*; do
        [ -e "$d" ] || continue
        name="$(/bin/busybox basename "$d")"
        [ "$(/bin/busybox cat "$d/removable" 2>/dev/null)" = "1" ] && continue
        disk="/dev/$name"
        break
    done
fi
if [ -z "$disk" ] || [ ! -b "$disk" ]; then
    say "FAILED: no target disk found (looked for vd*/sd*/nvme*; maas.disk= overrides)"
    say "parking (no reboot: a reboot would re-PXE and loop)"
    exec /bin/busybox sh
fi
say "target disk: $disk ($(( $(/bin/busybox cat "/sys/block/$(/bin/busybox basename "$disk")/size" 2>/dev/null || echo 0) / 2048 )) MiB)"
say "streaming $url -> $disk (nothing is buffered in RAM)"

# The write. dd's own summary carries the byte count the driver greps for, so it
# is echoed under the MAAS-DEPLOY prefix rather than paraphrased.
out="$(/bin/busybox wget -q -O- "$url" 2>/dev/null | /bin/busybox dd of="$disk" bs=1M 2>&1)"
rc=$?
if [ $rc -ne 0 ]; then
    say "FAILED: the write did not complete (rc=$rc)"
    /bin/busybox echo "$out"
    say "parking (no reboot: a reboot would re-PXE and loop)"
    exec /bin/busybox sh
fi

# Flush before declaring victory: dd's exit does not guarantee the platters (or
# the virtio queue) have it, and the driver switches the boot device on this line.
/bin/busybox sync
copied="$(/bin/busybox echo "$out" | /bin/busybox grep -E 'bytes .*copied|records out' | /bin/busybox tail -1)"
# The size comes from the CONTROL PLANE (maas.bytes=), not from dd's status line.
# busybox dd prints only "N+M records out" — no byte total — so parsing it made
# the read-back check skip itself with a warning on exactly the ramdisk it was
# written for. dd's line is still shown; it is just not load-bearing.
bytes="$want_bytes"
if [ -z "$bytes" ]; then
    bytes="$(/bin/busybox echo "$out" | /bin/busybox sed -nE 's/^([0-9]+) bytes.*copied.*/\1/p' | /bin/busybox tail -1)"
fi

# VERIFY WHAT LANDED, not what was sent. The firmware cannot check this image —
# the ramdisk fetched it, not iPXE — and a host-side signature says nothing about
# the bytes that reached the platter. So read the disk BACK and hash exactly the
# bytes written. A truncated stream, a short write, or a disk that silently
# dropped the tail all look like success to `dd` and all fail here.
if [ -n "$want_sha" ] && [ -n "$bytes" ]; then
    say "verifying the written image (reading $bytes bytes back from $disk)…"
    got_sha="$(/bin/busybox dd if="$disk" bs=1M count=$(( (bytes + 1048575) / 1048576 )) 2>/dev/null \
               | /bin/busybox head -c "$bytes" | /bin/busybox sha256sum | /bin/busybox cut -d' ' -f1)"
    if [ "$got_sha" != "$want_sha" ]; then
        say "FAILED: the image on disk does NOT match what was published"
        say "  expected $want_sha"
        say "  on disk  ${got_sha:-<could not hash>}"
        say "parking (no reboot: booting a disk we know is wrong is worse than not booting)"
        exec /bin/busybox sh
    fi
    say "verified: the bytes on $disk match the published sha256"
elif [ -n "$want_sha" ]; then
    # Not a warning to shrug at: the sha was published, so verification was
    # EXPECTED, and skipping it silently is how an unverified disk gets booted
    # while the log looks fine. Refuse instead.
    say "FAILED: maas.sha256 was published but no byte count is available (maas.bytes= missing"
    say "  and dd printed none) — refusing to boot a disk this ramdisk cannot verify."
    say "parking (no reboot: an unverified image is not a successful deploy)"
    exec /bin/busybox sh
fi

say "${copied:-write completed} — image '$image' written to $disk"
say "Image written"
/bin/busybox sync
say "rebooting into the deployed image"
/bin/busybox sleep 2
/bin/busybox reboot -f

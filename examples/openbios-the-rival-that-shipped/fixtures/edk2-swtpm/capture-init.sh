#!/bin/busybox sh
# shellcheck shell=dash  # busybox ash — no bashisms (there is no bash in this initramfs)
# capture-init.sh — the /init of a throwaway guest that does ONE thing: read the
# TCG event log the firmware (OVMF/edk2) wrote to the (swtpm) TPM, and the PCRs the
# TPM itself holds, and hand both to the host over the serial console. Then power
# off. It is the subject-acquisition step for the openbios lab's `event-real` track:
# "a claim from a machine that really measured", captured once and vendored.
#
# WHAT IS REAL HERE. The log is written by edk2 as it boots (the firmware measures
# itself, its config, the boot device and what it loads); the PCR values are read
# from the TPM device through the kernel (/sys/class/tpm/tpm0/pcr-sha256/N), and
# nothing in this script can influence either. WHAT IS NOT: the TPM is swtpm, so the
# machine's "claim" is a software TPM's — good enough to be a foreign, non-authored
# subject for a replay; not a hardware root of trust (that boundary is stated by
# every track that uses this capture).
#
# Output framing (host parses these markers; everything else on the console is
# kernel noise):
#   EVLOG-B64-BEGIN / <base64, one line> / EVLOG-B64-END
#   PCR-SHA256-<n>=<64 hex>      for every PCR the sha256 bank exposes
#   PCR-SHA1-<n>=<40 hex>        for every PCR the sha1 bank exposes
#   CAPTURE-DONE                 (or CAPTURE-FAILED: <why>, then a shell)
set -u
say() { /bin/busybox echo "$*"; }

/bin/busybox mount -t proc     none /proc 2>/dev/null
/bin/busybox mount -t sysfs    none /sys  2>/dev/null
/bin/busybox mount -t devtmpfs none /dev  2>/dev/null
# binary_bios_measurements lives on SECURITYFS, which nothing mounts for us here.
/bin/busybox mkdir -p /sys/kernel/security 2>/dev/null
/bin/busybox mount -t securityfs none /sys/kernel/security 2>/dev/null

# The TPM device can appear a moment after init starts; wait for it, bounded.
i=0
while [ ! -d /sys/class/tpm/tpm0 ] && [ "$i" -lt 50 ]; do /bin/busybox sleep 0.2; i=$((i+1)); done

LOG=/sys/kernel/security/tpm0/binary_bios_measurements
if [ ! -d /sys/class/tpm/tpm0 ]; then
    say "CAPTURE-FAILED: no /sys/class/tpm/tpm0 — the kernel sees no TPM (is -tpmdev/-device tpm-tis on the QEMU line, and TCG_TIS built in?)"
    exec /bin/busybox sh
fi
# TEST THE BYTES, NOT THE STAT SIZE. binary_bios_measurements is a securityfs
# seq-file: it stats as 0 bytes even when it has thousands, so `[ -s ]` is false
# on a perfectly good log. The first draft used -s and reported "missing or empty"
# over a 6345-byte log (2026-09-03) — the mechanism (inode size) standing in for
# the outcome (bytes readable). Read it.
LOGSZ="$(/bin/busybox wc -c < "$LOG" 2>/dev/null || echo 0)"
if [ ! -r "$LOG" ] || [ "${LOGSZ:-0}" -eq 0 ]; then
    say "CAPTURE-FAILED: $LOG is unreadable or reads as 0 bytes — securityfs not mounted, or the firmware handed the kernel no event log"
    /bin/busybox ls -la /sys/kernel/security/tpm0/ 2>&1
    exec /bin/busybox sh
fi

say "EVLOG-SIZE=$LOGSZ"
say "EVLOG-B64-BEGIN"
/bin/busybox base64 -w0 "$LOG"; say ""
say "EVLOG-B64-END"
for bank in sha256 sha1; do
    d=/sys/class/tpm/tpm0/pcr-$bank
    [ -d "$d" ] || continue
    n=0
    while [ "$n" -lt 24 ]; do
        [ -r "$d/$n" ] && say "PCR-$(/bin/busybox echo "$bank" | /bin/busybox tr a-z A-Z)-$n=$(/bin/busybox cat "$d/$n")"
        n=$((n+1))
    done
done
say "CAPTURE-DONE"
/bin/busybox sleep 1
/bin/busybox poweroff -f

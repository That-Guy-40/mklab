#!/bin/busybox sh
# shellcheck shell=dash  # busybox ash — no bashisms (there is no bash in this initramfs)
# capture-init.sh — the /init of a throwaway guest that does ONE thing: read the
# TCG event log the firmware (OVMF/edk2, or measured coreboot) wrote as it booted,
# and the PCRs the (swtpm) TPM itself holds, and hand both to the host over the
# serial console. Then power off. It is the subject-acquisition step for the openbios
# lab's `event-real` and `event-bench` tracks: "a claim from a machine that really
# measured", captured once per firmware substrate and vendored — the SAME reader
# behind every substrate, so nothing but the firmware differs between captures.
#
# WHAT IS REAL HERE. The log is written by the firmware as it boots (edk2 measures
# itself, its config, the boot device and what it loads into PCR0-7; coreboot
# measures each stage and its payload into its SRTM PCR 2); the PCR values are read
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
LOGSRC=securityfs
if [ ! -r "$LOG" ] || [ "${LOGSZ:-0}" -eq 0 ]; then
    # COREBOOT'S TPM 2.0-FORMAT LOG IS NOT WHAT ACPI PUBLISHES. src/acpi/acpi.c points
    # the TPM2 table's log area at CBMEM_ID_TCPA_TCG_LOG (the TPM 1.2-format id) and
    # creates an EMPTY one when absent, while TPM_LOG_TPM2 writes the real log under
    # CBMEM_ID_TPM2_TCG_LOG (0x54504d32). So a coreboot guest reads 0 bytes here even
    # though coreboot measured everything (measured 2026-09-03). Read that cbmem entry
    # directly with coreboot's own tool instead — the same bytes coreboot wrote; the
    # kernel needs iomem=relaxed on the cmdline for /dev/mem to reach RAM.
    if [ -x /bin/cbmem ]; then
        /bin/cbmem -r 54504d32 > /tmp/evlog.bin 2>/tmp/cbmem.err
        RAWSZ="$(/bin/busybox wc -c < /tmp/evlog.bin 2>/dev/null || echo 0)"
        if [ "${RAWSZ:-0}" -gt 0 ]; then
            LOG=/tmp/evlog.bin; LOGSZ="$RAWSZ"; LOGSRC=cbmem
            say "EVLOG-NOTE: securityfs log was empty; read coreboot's TPM2 log from cbmem id 54504d32 ($RAWSZ raw bytes, host trims)"
        else
            say "CAPTURE-FAILED: securityfs log empty AND cbmem -r 54504d32 returned nothing: $(/bin/busybox cat /tmp/cbmem.err 2>/dev/null | /bin/busybox head -1) (is iomem=relaxed on the cmdline?)"
            exec /bin/busybox sh
        fi
    else
        say "CAPTURE-FAILED: $LOG is unreadable or reads as 0 bytes — securityfs not mounted, or the firmware handed the kernel no event log (and no /bin/cbmem to read coreboot's cbmem log)"
        /bin/busybox ls -la /sys/kernel/security/tpm0/ 2>&1
        exec /bin/busybox sh
    fi
fi

say "EVLOG-SRC=$LOGSRC"
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

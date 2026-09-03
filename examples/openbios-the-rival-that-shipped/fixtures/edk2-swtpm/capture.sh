#!/usr/bin/env bash
# capture.sh — capture a REAL edk2 (OVMF) TCG event log and the PCRs a real (swtpm)
# TPM holds, from a throwaway guest, into this fixture directory. Subject
# acquisition for the openbios lab's `event-real` track: a measured-boot log
# nobody in this repo authored, plus the machine's own claim of what it measured.
#
#   capture.sh [--out DIR]        (default: this directory)
#
# HOW. swtpm (socket, TPM 2.0) is started as a sidecar; QEMU boots OVMF_CODE_4M
# (which has TPM2 support and measures its boot into the TPM + the event log) with
# a tpm-tis device on that socket, and direct-boots a TPM-capable Linux kernel with
# a busybox initramfs whose /init (capture-init.sh) mounts securityfs and prints
# the log (base64) and every PCR over the serial console, then powers off. The host
# decodes the framing back into files and records sha256s. Rootless; no network.
#
# WHY THE HOST KERNEL. The linuxboot kernels on this host have no TPM drivers (they
# are minimal u-root builds). ~/.cache/mklab-kernel/vmlinuz is a world-readable copy
# of an Ubuntu generic kernel with CONFIG_TCG_TPM/TIS/CRB and SECURITYFS built in,
# so the initramfs needs no modules. Override with CAPTURE_KERNEL=.
#
# PROVENANCE IS PART OF THE OUTPUT: PROVENANCE.txt records the firmware, swtpm,
# kernel and QEMU versions and the sha256 of every captured file, so the vendored
# fixture can be re-derived and checked rather than trusted.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/../../../.." && pwd)"
OUT="$HERE"
[[ "${1:-}" == "--out" ]] && OUT="$2"
die() { printf 'capture: %s\n' "$*" >&2; exit 1; }

KERNEL="${CAPTURE_KERNEL:-$HOME/.cache/mklab-kernel/vmlinuz}"
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd
PACKER="$REPO/examples/metal-as-a-service/build-probe-initramfs.sh"
for t in swtpm qemu-system-x86_64 base64 sha256sum; do command -v "$t" >/dev/null || die "$t is required"; done
[[ -r "$KERNEL" ]]   || die "no readable TPM-capable kernel at $KERNEL (set CAPTURE_KERNEL=)"
[[ -r "$OVMF_CODE" && -r "$OVMF_VARS" ]] || die "OVMF 4M images not found under /usr/share/OVMF (apt install ovmf)"
[[ -x "$PACKER" ]]   || die "initramfs packer missing at $PACKER"
[[ -x /usr/bin/busybox ]] || die "/usr/bin/busybox (busybox-static) is required for the guest initramfs"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tpmcap.XXXXXX")"
SWPID=""; QPID=""
cleanup() {
    [[ -n "$QPID"  ]] && kill "$QPID"  2>/dev/null   # by PID, never by pattern
    [[ -n "$SWPID" ]] && kill "$SWPID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# ── the guest initramfs: busybox + capture-init.sh as /init ──────────────────
INITRD="$WORK/capture-initramfs.cpio.gz"
INIT="${CAPTURE_INIT:-$HERE/capture-init.sh}"        # a diagnostic /init can be swapped in
"$PACKER" --init "$INIT" --busybox /usr/bin/busybox --out "$INITRD" >/dev/null 2>&1 \
    || die "building the capture initramfs failed (run $PACKER by hand to see why)"
[[ -s "$INITRD" ]] || die "packer produced no initramfs"

# ── swtpm sidecar (TPM 2.0), ctrl socket for QEMU ────────────────────────────
TPMSTATE="$WORK/tpmstate"; mkdir -p "$TPMSTATE"
TPMSOCK="$WORK/swtpm.sock"
swtpm socket --tpmstate "dir=$TPMSTATE" --ctrl "type=unixio,path=$TPMSOCK" --tpm2 \
      --log "file=$WORK/swtpm.log,level=1" &
SWPID=$!
for _ in $(seq 1 50); do [[ -S "$TPMSOCK" ]] && break; sleep 0.1; done
[[ -S "$TPMSOCK" ]] || die "swtpm did not create $TPMSOCK (see $WORK/swtpm.log)"

# ── the guest: OVMF (pflash, TPM2-capable) + tpm-tis + direct kernel boot ────
cp "$OVMF_VARS" "$WORK/vars.fd"
SERIAL="$WORK/serial.log"
ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)
qemu-system-x86_64 -M "q35,accel=$ACCEL" -m 1024 -display none -no-reboot \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -chardev "socket,id=chrtpm,path=$TPMSOCK" -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device "${CAPTURE_TPMDEV:-tpm-tis},tpmdev=tpm0" \
    -kernel "$KERNEL" -initrd "$INITRD" -append "${CAPTURE_APPEND:-console=ttyS0,115200 loglevel=5}" \
    -serial "file:$SERIAL" >"$WORK/qemu.log" 2>&1 &
QPID=$!
# bounded wait for the framing; the init powers the guest off when done
for _ in $(seq 1 180); do
    grep -q "${CAPTURE_DONE_MARKER:-CAPTURE-DONE}\|CAPTURE-FAILED" "$SERIAL" 2>/dev/null && break
    kill -0 "$QPID" 2>/dev/null || break
    sleep 1
done
# KEEP THE EVIDENCE ON FAILURE. The work dir is removed on exit, and the first draft
# took the serial log — and with it the guest's own CAPTURE-FAILED reason — down
# with it, leaving only a shell prompt to diagnose from (2026-09-03). Copy it out
# first, and put the guest's stated reason in the message rather than a tail.
# DIAG MODE: with CAPTURE_INIT= pointing at a diagnostic /init and CAPTURE_DONE_MARKER=
# set to its end marker, just keep the serial log and stop — no decode, no fixture.
if [[ -n "${CAPTURE_DONE_MARKER:-}" && "${CAPTURE_DONE_MARKER}" != CAPTURE-DONE ]]; then
    mkdir -p "$OUT"; cp "$SERIAL" "$OUT/serial-diag.log"
    grep -q "$CAPTURE_DONE_MARKER" "$SERIAL" 2>/dev/null \
        || die "diag: the guest did not reach $CAPTURE_DONE_MARKER (log: $OUT/serial-diag.log)"
    printf 'diag: serial log at %s\n' "$OUT/serial-diag.log"; exit 0
fi
if ! grep -q 'CAPTURE-DONE' "$SERIAL" 2>/dev/null; then
    mkdir -p "$OUT"; cp "$SERIAL" "$OUT/serial-FAILED.log" 2>/dev/null; cp "$WORK/qemu.log" "$OUT/qemu-FAILED.log" 2>/dev/null
    die "the guest did not report CAPTURE-DONE. Guest said: $(tr -d '\r' < "$SERIAL" | grep -m1 'CAPTURE-FAILED' || echo '<no CAPTURE-FAILED line either — the init never ran or the console is not ttyS0>')  (full log: $OUT/serial-FAILED.log)"
fi

# ── decode the framing into files ─────────────────────────────────────────────
mkdir -p "$OUT"
tr -d '\r' < "$SERIAL" | sed -n '/^EVLOG-B64-BEGIN$/,/^EVLOG-B64-END$/p' | grep -vE '^EVLOG-B64-(BEGIN|END)$' \
    | tr -d '\n' | base64 -d > "$OUT/binary_bios_measurements" \
    || die "base64 decode of the event log failed"
WANT=$(tr -d '\r' < "$SERIAL" | sed -n 's/^EVLOG-SIZE=\([0-9]*\).*/\1/p' | tail -1)
GOT=$(stat -c%s "$OUT/binary_bios_measurements")
[[ -n "$WANT" && "$GOT" -eq "$WANT" ]] || die "decoded log is $GOT bytes but the guest reported $WANT — the serial framing was cut"
# The kernel prints PCR hex in UPPER case. A pattern of [0-9a-f] silently kept only
# the all-ZERO PCRs (digits pass) and dropped PCR0-7 — the ones that matter — while
# the file still looked populated (2026-09-03). Accept either case, emit lower.
pcr_lines() {  # pcr_lines <BANK> -> "n:hex" per line, lowercase
    tr -d '\r' < "$SERIAL" | sed -n "s/^PCR-$1-\([0-9]*\)=\([0-9A-Fa-f]*\)\$/\1:\2/p" | tr 'A-F' 'a-f'
}
pcr_lines SHA256 > "$OUT/pcrs-sha256.txt"
pcr_lines SHA1   > "$OUT/pcrs-sha1.txt"
[[ -s "$OUT/pcrs-sha256.txt" ]] || die "no PCR-SHA256 lines captured"
# and REFUSE a capture where the firmware PCRs (0-7) are absent or all zero — a
# machine that measured nothing has no claim worth vendoring.
grep -qE '^0:[0-9a-f]*[1-9a-f]' "$OUT/pcrs-sha256.txt" \
    || die "PCR0 (sha256) is missing or all-zero in the capture — the firmware measured nothing, or the PCR lines were not parsed: $(head -3 "$OUT/pcrs-sha256.txt" | tr '\n' '|')"
# .txt, not .log: the repo's root .gitignore drops every *.log, and the first commit of
# this fixture silently lost the raw console while the README linked to it (2026-09-03).
# A vendored source must not depend on `git add -f` to survive a re-capture.
cp "$SERIAL" "$OUT/serial-capture.txt"

{
    echo "# PROVENANCE — captured $(date -u +%Y-%m-%dT%H:%M:%SZ) by $(basename "$0")"
    echo "firmware:  $OVMF_CODE  sha256=$(sha256sum "$OVMF_CODE" | cut -d' ' -f1)"
    echo "ovmf-pkg:  $(dpkg-query -W -f='${Package} ${Version}' ovmf 2>/dev/null || echo unknown)"
    echo "swtpm:     $(swtpm --version 2>&1 | head -1)"
    echo "qemu:      $(qemu-system-x86_64 --version | head -1)"
    echo "kernel:    $KERNEL  ($(file -b "$KERNEL" | grep -oE 'version [^ ]+' ))  sha256=$(sha256sum "$KERNEL" | cut -d' ' -f1)"
    echo "tpm-dev:   tpm-tis (QEMU), swtpm --tpm2 ctrl=unixio"
    echo "accel:     $ACCEL"
    echo
    echo "# sha256 of the captured files"
    (cd "$OUT" && sha256sum binary_bios_measurements pcrs-sha256.txt pcrs-sha1.txt)
} > "$OUT/PROVENANCE.txt"

printf 'captured: %s bytes of event log, %s sha256 PCRs, %s sha1 PCRs -> %s\n' \
    "$GOT" "$(wc -l < "$OUT/pcrs-sha256.txt")" "$(wc -l < "$OUT/pcrs-sha1.txt")" "$OUT"

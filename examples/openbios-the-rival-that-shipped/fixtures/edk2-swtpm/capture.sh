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
# FIRMWARE MODE. Default: OVMF (edk2) as pflash, direct-booting KERNEL+initramfs.
# CAPTURE_FIRMWARE=coreboot:<rom> boots that ROM with `-bios` on q35 instead — the
# ROM carries its own payload (the §12 bench's measured coreboot ROMs), so no
# kernel is passed; the initramfs is still built so a Linux payload ROM can be
# rebuilt from it, and the decode/provenance path is shared with the OVMF mode.
FWMODE="${CAPTURE_FIRMWARE:-ovmf}"
COREBOOT_ROM=""; OBLEG=0
case "$FWMODE" in
  ovmf) [[ -r "$KERNEL" ]]   || die "no readable TPM-capable kernel at $KERNEL (set CAPTURE_KERNEL=)"
        [[ -r "$OVMF_CODE" && -r "$OVMF_VARS" ]] || die "OVMF 4M images not found under /usr/share/OVMF (apt install ovmf)" ;;
  coreboot:*) COREBOOT_ROM="${FWMODE#coreboot:}"
        [[ -s "$COREBOOT_ROM" ]] || die "CAPTURE_FIRMWARE names no ROM at $COREBOOT_ROM" ;;
  # coreboot-openbios:<rom> — the bench's THIRD substrate: coreboot measures and hands
  # off to OpenBIOS, which then boots the SAME Linux reader from a CD (the showcase's
  # 3-stage chain). q35 has no IDE, so a PCI piix3-ide is plugged in and the CD sits at
  # /ide@0/cdrom@0 (measured: `load` from there returns the file; /ide@1 does not).
  coreboot-openbios:*) COREBOOT_ROM="${FWMODE#coreboot-openbios:}"; OBLEG=1
        [[ -s "$COREBOOT_ROM" ]] || die "CAPTURE_FIRMWARE names no ROM at $COREBOOT_ROM"
        [[ -r "$KERNEL" ]] || die "no readable TPM-capable kernel at $KERNEL (the CD the OpenBIOS payload boots)"
        command -v genisoimage >/dev/null || die "genisoimage is required for the OpenBIOS leg's CD"
        [[ -f "$REPO/tools/drive-serial-repl.py" ]] || die "tools/drive-serial-repl.py is required to drive the OpenBIOS prompt" ;;
  *) die "CAPTURE_FIRMWARE must be 'ovmf', 'coreboot:<rom>' or 'coreboot-openbios:<rom>' (got '$FWMODE')" ;;
esac
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
# coreboot's static `cbmem` rides along when present: under a coreboot ROM the guest
# reads the TPM 2.0-format log out of cbmem with it (see capture-init.sh for why the
# securityfs file is empty there). Harmless under OVMF — it is simply never invoked.
CBMEM="${CAPTURE_CBMEM:-${COREBOOT_DIR:-$HOME/linuxboot-lab/coreboot}/util/cbmem/cbmem}"
ADDS=(); [[ -x "$CBMEM" ]] && ADDS=(--add "$CBMEM:/bin/cbmem")
"$PACKER" --init "$INIT" --busybox /usr/bin/busybox --out "$INITRD" "${ADDS[@]}" >/dev/null 2>&1 \
    || die "building the capture initramfs failed (run $PACKER by hand to see why)"
[[ -s "$INITRD" ]] || die "packer produced no initramfs"

# ── swtpm sidecar (TPM 2.0), ctrl socket for QEMU ────────────────────────────
TPMSTATE="$WORK/tpmstate"; mkdir -p "$TPMSTATE"
TPMSOCK="$WORK/swtpm.sock"
# NO --server HERE, AND THE REASON IS MEASURED: a first draft added
# `--server type=tcp,port=N` so the host could read PCRs out of the TPM over the
# swtpm TCTI after the guest was done — an observer outside the guest. QEMU then
# refused to start: "tpm-emulator: Failed to send CMD_SET_DATAFD". QEMU's TPM
# emulator backend always hands swtpm its data channel as an fd over the unix ctrl
# socket, and swtpm will not accept one once it owns a TCP data server. One swtpm
# cannot serve both (2026-09-03). The machine's claim therefore comes from the
# guest kernel reading its TPM — which is why every bench leg boots the same
# Linux reader, even behind OpenBIOS.
swtpm socket --tpmstate "dir=$TPMSTATE" --ctrl "type=unixio,path=$TPMSOCK" --tpm2 \
      --log "file=$WORK/swtpm.log,level=1" &
SWPID=$!
for _ in $(seq 1 50); do [[ -S "$TPMSOCK" ]] && break; sleep 0.1; done
[[ -S "$TPMSOCK" ]] || die "swtpm did not create $TPMSOCK (see $WORK/swtpm.log)"

# ── the guest: OVMF (pflash, TPM2-capable) + tpm-tis + direct kernel boot ────
SERIAL="$WORK/serial.log"
ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)
# the firmware half of the QEMU line differs per mode; the TPM, serial and machine
# halves are shared so the two modes differ in NOTHING but the firmware substrate.
FWARGS=()
SERIALARG=(-serial "file:$SERIAL")
if [[ "$OBLEG" == 1 ]]; then
    # coreboot → OpenBIOS → (CD) Linux: the ROM carries OpenBIOS; the reader kernel
    # and its initramfs ride a piix3-ide CD that OpenBIOS boots at the prompt, which
    # a REPL driver types over a unix serial socket (short path: AF_UNIX's 108-char
    # limit). The driver appends the console to $SERIAL, so the decode is unchanged.
    # ONE-LETTER NAMES ON PURPOSE. The boot line is TYPED at OpenBIOS's prompt, whose
    # line editor silently truncates past ~80 columns (this lab's oldest trap): with
    # vmlinuz/initrd.img and a full cmdline the line lost its `initrd=` and the kernel
    # panicked on no root fs (2026-09-03). V + I keep the whole line at 75 columns.
    mkdir -p "$WORK/cd"; cp "$KERNEL" "$WORK/cd/V"; cp "$INITRD" "$WORK/cd/I"
    genisoimage -quiet -o "$WORK/boot.iso" -V BENCH -r -J "$WORK/cd" 2>/dev/null || die "genisoimage failed for the OpenBIOS leg's CD"
    SERSOCK="/tmp/cap-$$.sock"; rm -f "$SERSOCK"
    FWARGS=(-bios "$COREBOOT_ROM"
            -device "piix3-ide,id=ide0" -drive "id=cd0,file=$WORK/boot.iso,if=none,media=cdrom,format=raw"
            -device "ide-cd,drive=cd0,bus=ide0.0")
    SERIALARG=(-serial "unix:$SERSOCK,server=on,wait=off")
elif [[ -n "$COREBOOT_ROM" ]]; then
    FWARGS=(-bios "$COREBOOT_ROM")                       # the ROM carries its payload
else
    cp "$OVMF_VARS" "$WORK/vars.fd"
    FWARGS=(-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
            -drive "if=pflash,format=raw,file=$WORK/vars.fd"
            -kernel "$KERNEL" -initrd "$INITRD"
            -append "${CAPTURE_APPEND:-console=ttyS0,115200 loglevel=5}")
fi
qemu-system-x86_64 -M "q35,accel=$ACCEL" -m 1024 -display none -no-reboot \
    "${FWARGS[@]}" \
    -chardev "socket,id=chrtpm,path=$TPMSOCK" -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device "${CAPTURE_TPMDEV:-tpm-tis},tpmdev=tpm0" \
    "${SERIALARG[@]}" >"$WORK/qemu.log" 2>&1 &
QPID=$!
if [[ "$OBLEG" == 1 ]]; then
    # Drive the OpenBIOS prompt: wait for `0 > `, type the showcase's boot line (the
    # CD path measured on q35 + piix3-ide), then wait for the Linux reader's marker.
    # The driver mirrors the whole console into $SERIAL, so the decode below is the
    # same for every substrate — nothing but the firmware differs.
    python3 "$REPO/tools/drive-serial-repl.py" "$SERSOCK" "$SERIAL" --timeout 240 \
        --expect "0 > " \
        --send 'boot /ide@0/cdrom@0:\\V console=ttyS0 iomem=relaxed initrd=/ide@0/cdrom@0:\\I\r' \
        --expect "${CAPTURE_DONE_MARKER:-CAPTURE-DONE}" >/dev/null 2>&1 || true
else
    # bounded wait for the framing; the init powers the guest off when done
    for _ in $(seq 1 180); do
        grep -q "${CAPTURE_DONE_MARKER:-CAPTURE-DONE}\|CAPTURE-FAILED" "$SERIAL" 2>/dev/null && break
        kill -0 "$QPID" 2>/dev/null || break
        sleep 1
    done
fi
# KEEP THE EVIDENCE ON FAILURE. The work dir is removed on exit, and the first draft
# took the serial log — and with it the guest's own CAPTURE-FAILED reason — down
# with it, leaving only a shell prompt to diagnose from (2026-09-03). Copy it out
# first, and put the guest's stated reason in the message rather than a tail.
# DIAG MODE: with CAPTURE_INIT= pointing at a diagnostic /init and CAPTURE_DONE_MARKER=
# set to its end marker, just keep the serial log and stop — no decode, no fixture.
if [[ -n "${CAPTURE_DONE_MARKER:-}" && "${CAPTURE_DONE_MARKER}" != CAPTURE-DONE ]]; then
    mkdir -p "$OUT"; cp "$SERIAL" "$OUT/serial-diag.log"
    grep -q "$CAPTURE_DONE_MARKER" "$SERIAL" 2>/dev/null \
        || die "diag: the guest did not reach '$CAPTURE_DONE_MARKER' (log: $OUT/serial-diag.log)"
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
LOGSRC=$(tr -d '\r' < "$SERIAL" | sed -n 's/^EVLOG-SRC=\([a-z]*\).*/\1/p' | tail -1)
if [[ "$LOGSRC" == cbmem ]]; then
    # A raw cbmem entry is the whole allocation, zero-padded past the last event. Trim
    # it to the log proper by WALKING it (SpecID header, then TCG_PCR_EVENT2 entries)
    # and cutting at the first entry that is not a well-formed event; tpm2_eventlog
    # and the Forth reader both need the exact extent.
    python3 - "$OUT/binary_bios_measurements" <<'PY' || die "trimming the cbmem log failed"
import struct, sys
p=sys.argv[1]; d=open(p,'rb').read(); n=len(d)
o=0
if n<32: sys.exit("cbmem log too short")
o+=8+20; sz,=struct.unpack_from('<I',d,o); o+=4+sz          # SpecID header event
end=o; SIZES={4:20,0xb:32,0xc:48,0xd:64}
while o+12<=n:
    pcr,typ,cnt=struct.unpack_from('<III',d,o)
    if pcr>23 or cnt==0 or cnt>8: break
    q=o+12; ok=True
    for _ in range(cnt):
        if q+2>n: ok=False; break
        alg,=struct.unpack_from('<H',d,q); q+=2
        if alg not in SIZES: ok=False; break
        q+=SIZES[alg]
    if not ok or q+4>n: break
    esz,=struct.unpack_from('<I',d,q); q+=4
    if esz>n-q: break
    q+=esz; o=q; end=o
open(p,'wb').write(d[:end]); print(f"trimmed cbmem log to {end} bytes")
PY
    GOT=$(stat -c%s "$OUT/binary_bios_measurements")
fi
# The kernel prints PCR hex in UPPER case. A pattern of [0-9a-f] silently kept only
# the all-ZERO PCRs (digits pass) and dropped PCR0-7 — the ones that matter — while
# the file still looked populated (2026-09-03). Accept either case, emit lower.
pcr_lines() {  # pcr_lines <BANK> -> "n:hex" per line, lowercase
    tr -d '\r' < "$SERIAL" | sed -n "s/^PCR-$1-\([0-9]*\)=\([0-9A-Fa-f]*\)\$/\1:\2/p" | tr 'A-F' 'a-f'
}
pcr_lines SHA256 > "$OUT/pcrs-sha256.txt"
pcr_lines SHA1   > "$OUT/pcrs-sha1.txt"
[[ -s "$OUT/pcrs-sha256.txt" ]] || die "no PCR-SHA256 lines captured"
# and REFUSE a capture where NO firmware PCR (0-7) was extended — a machine that
# measured nothing has no claim worth vendoring. Not "PCR0 must be nonzero": edk2
# extends PCR0-7, but coreboot's measured boot extends ONLY its SRTM PCR (PCR 2,
# CONFIG_PCR_SRTM) and leaves the others at zero by design — the first draft
# refused a perfectly good coreboot capture on that basis (2026-09-03).
NONZERO="$(awk -F: '$1<=7 && $2 ~ /[1-9a-f]/ {printf "%s ", $1}' "$OUT/pcrs-sha256.txt")"
[[ -n "$NONZERO" ]] \
    || die "no sha256 PCR in 0-7 is nonzero in the capture — the firmware measured nothing, or the PCR lines were not parsed: $(head -3 "$OUT/pcrs-sha256.txt" | tr '\n' '|')"
echo "capture: firmware-extended PCRs (nonzero, 0-7): $NONZERO"
# .txt, not .log: the repo's root .gitignore drops every *.log, and the first commit of
# this fixture silently lost the raw console while the README linked to it (2026-09-03).
# A vendored source must not depend on `git add -f` to survive a re-capture.
cp "$SERIAL" "$OUT/serial-capture.txt"

# (A host-side PCR read over the swtpm TCTI would be a second observer here; it
# cannot coexist with QEMU on one swtpm — see the swtpm launch above. The guest's
# claim is cross-checked instead by tpm2_eventlog's replay of the log it wrote,
# in the tracks that consume this fixture.)

{
    echo "# PROVENANCE — captured $(date -u +%Y-%m-%dT%H:%M:%SZ) by $(basename "$0")"
    if [[ -n "$COREBOOT_ROM" ]]; then
        echo "firmware:  $COREBOOT_ROM  sha256=$(sha256sum "$COREBOOT_ROM" | cut -d' ' -f1)"
        echo "coreboot:  commit $(git -C "$(dirname "$COREBOOT_ROM")/.." rev-parse --short HEAD 2>/dev/null || echo unknown)  ($(dirname "$COREBOOT_ROM")/.config-* : TPM2 + TPM_MEASURED_BOOT + TPM_LOG_TPM2, q35)"
        echo "payload:   $("$(dirname "$COREBOOT_ROM")/cbfstool" "$COREBOOT_ROM" print 2>/dev/null | grep -E '^fallback/payload' | xargs)"
    else
        echo "firmware:  $OVMF_CODE  sha256=$(sha256sum "$OVMF_CODE" | cut -d' ' -f1)"
        echo "ovmf-pkg:  $(dpkg-query -W -f='${Package} ${Version}' ovmf 2>/dev/null || echo unknown)"
    fi
    echo "swtpm:     $(swtpm --version 2>&1 | head -1)"
    echo "qemu:      $(qemu-system-x86_64 --version | head -1)"
    echo "kernel:    $KERNEL  ($(file -b "$KERNEL" | grep -oE 'version [^ ]+' ))  sha256=$(sha256sum "$KERNEL" | cut -d' ' -f1)"
    echo "tpm-dev:   tpm-tis (QEMU), swtpm --tpm2 ctrl=unixio"
    echo "accel:     $ACCEL"
    echo "log-src:   ${LOGSRC:-securityfs}  (securityfs = /sys/kernel/security/tpm0/binary_bios_measurements; cbmem = coreboot's CBMEM_ID_TPM2_TCG_LOG read with cbmem -r, trimmed by walking)"
    echo
    echo "# sha256 of the captured files"
    (cd "$OUT" && sha256sum binary_bios_measurements pcrs-sha256.txt pcrs-sha1.txt)
} > "$OUT/PROVENANCE.txt"

printf 'captured: %s bytes of event log, %s sha256 PCRs, %s sha1 PCRs -> %s\n' \
    "$GOT" "$(wc -l < "$OUT/pcrs-sha256.txt")" "$(wc -l < "$OUT/pcrs-sha1.txt")" "$OUT"

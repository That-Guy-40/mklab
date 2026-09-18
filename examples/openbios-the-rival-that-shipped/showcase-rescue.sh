#!/usr/bin/env bash
# showcase-rescue.sh [initrd|config|cmdline|all] — UKI workbench Spike 11, the
# rescue capstone: a boot artifact is DELIBERATELY BROKEN so the machine does not
# come up, then rescued with the toolkit — no USB stick, no chroot. Each act walks
# a break -> named-failure -> rescue, and THE NEGATIVE CONTROL IS THE POINT: the
# un-edited artifact is shown genuinely failing first, so reaching a rescue shell
# proves the edit is what rescued it and not that it would have booted anyway.
#
# THREE RESCUE PATHS, each grounded in a measured seam (UKI_WORKBENCH_LAB_PLAN.md
# §Spike 11, findings 2026-09-18):
#   initrd  — break: boot with NO initrd -> the kernel cannot mount a root fs and
#             panics `VFS: Unable to mount root fs on unknown-block(0,0)`; rescue:
#             supply the good initrd on the boot line -> `Welcome to u-root!`.
#             (The classic-kernel rescue seam is the boot LINE — Spike 7b: an
#             in-firmware prompt edit of the live cmd_line_ptr does not reach the
#             kernel, so the boot line is what carries the rescue here.)
#   config  — break: a bad line in a config FILE inside the initramfs; rescue:
#             dsl/cpio-edit.fth fixes it in place (Spike 10).            [TODO]
#   cmdline — break: a UKI whose .cmdline lacks the rescue param; rescue: grow
#             .cmdline (bumping VirtualSize per Q5) under OVMF (Spike 6).  [TODO]
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP. Env: OPENBIOS_WORKDIR, KERNEL, INITRD.
set -u
usage() {
    cat <<'USAGE'
showcase-rescue.sh [ACT]   UKI workbench Spike 11 — break a boot, then rescue it

ACT (default all):
  initrd    no-initrd boot panics (VFS: Unable to mount root fs); the good
            initrd on the boot line rescues it to a u-root shell
  config    a broken config inside the initramfs, fixed in place (Spike 10) [TODO]
  cmdline   a UKI .cmdline grown to add a rescue param under OVMF (Spike 6) [TODO]
  all       every implemented act; the run FAILS if any break did NOT fail
            first, or any rescue did not reach its shell

The negative control is load-bearing: each act asserts the UN-edited artifact
fails with its named signature BEFORE the rescue, so a rescue that "worked" on a
boot that would have come up anyway is caught.

Exit: 0 PASS / 1 FAIL / 77 SKIP.
Env: KERNEL (a bzImage), INITRD (a cpio), OPENBIOS_WORKDIR, COREBOOT_DIR
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
KERNEL="${KERNEL:-$HOME/linuxboot-lab/payload-bzImage}"
INITRD="${INITRD:-$HOME/linuxboot-lab/uroot.cpio}"
ACT="${1:-all}"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
# shellcheck disable=SC2154  # rc IS set by the rc=$? at the top of this same trap body
trap 'rc=$?; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: showcase-rescue.sh exited early (rc=$rc)"' EXIT

command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
command -v python3 >/dev/null            || skip "python3 not installed"
command -v genisoimage >/dev/null        || skip "genisoimage not installed"
[[ -f "$KERNEL" ]] || skip "no kernel at $KERNEL (set KERNEL=; a bzImage the OpenBIOS loader boots)"
[[ -f "$INITRD" ]] || skip "no initrd at $INITRD (set INITRD=; a cpio the kernel unpacks to a shell)"
MB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
DICT="$WORKDIR/openbios/obj-x86/openbios-x86.dict"
[[ -f "$MB" && -f "$DICT" ]] || skip "no x86 firmware at $MB — run ./build-openbios.sh x86 first"

ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)

# ── shared: one ISO with the kernel (v) and the good initrd (u), SHORT names so
#    the boot line stays under the firmware's ~75-char input buffer (POC-4). ──
RWD="$WORKDIR/rescue"; rm -rf "$RWD"; mkdir -p "$RWD/stage"
cp "$KERNEL" "$RWD/stage/V"; cp "$INITRD" "$RWD/stage/U"
ISO="$RWD/rescue.iso"
genisoimage -quiet -o "$ISO" -V RESCUE -r -J "$RWD/stage" 2>/dev/null || fail "genisoimage failed building $ISO"

# boot_openbios <log> <timeout> <boot-line> <expect...> : boot the x86 firmware,
# type ONE boot line at the 0 > prompt, and wait for the expect markers in order.
# Returns the driver's rc (0 = all markers seen, 124 = timeout). Socket lives in
# $WORKDIR (short path — AF_UNIX caps at ~108 chars and the scratch tree is longer).
boot_openbios() {
    local log="$1" secs="$2" bl="$3"; shift 3
    local sock="$WORKDIR/rescue.sock"; rm -f "$sock" "$log"
    qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB" -initrd "$DICT" \
        -cdrom "$ISO" -display none -serial "unix:$sock,server=on" -no-reboot >/dev/null 2>&1 &
    local qpid=$!
    local args=(python3 "$REPO/tools/drive-serial-repl.py" "$sock" "$log" --timeout "$secs"
                --expect "0 > " --send "$bl"$'\r')
    local e; for e in "$@"; do args+=(--expect "$e"); done
    "${args[@]}"; local rc=$?
    kill "$qpid" 2>/dev/null   # by PID, never by pattern
    return $rc
}

# ── ACT: initrd ──────────────────────────────────────────────────────────────
# BREAK boots with NO initrd= on the line, so the kernel has no initramfs and no
# root device: it panics. RESCUE adds initrd=…\u and reaches u-root. Both boot the
# SAME kernel from the SAME ISO; only the boot line differs — which is the honest
# minimal edit (the classic-kernel rescue seam, Spike 7b).
act_initrd() {
    local blog="$RWD/initrd-break.log" rlog="$RWD/initrd-rescue.log"
    note "initrd BREAK: boot with no initrd -> expect a VFS root-fs panic"
    # \\v: the driver decodes --send with unicode_escape, so the single backslash
    # of the device path must be doubled (see showcase-rival-boots-linux.sh).
    if boot_openbios "$blog" 120 'boot /ide@1/cdrom@0:\\v console=ttyS0' \
         'Loading kernel... ok' 'not syncing'; then
        grep -qaF 'Unable to mount root fs' "$blog" \
            || fail "initrd: the broken boot panicked but not with the expected root-fs signature — see $blog"
        note "initrd BREAK failed as designed: $(sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$blog" | tr -d '\r' | grep -aoE 'Kernel panic - not syncing: VFS: Unable to mount root fs[^]]*' | head -1)"
    else
        fail "initrd: the no-initrd boot did NOT reach its named panic (VFS: Unable to mount root fs) within the deadline — the negative control did not fire, so a rescue below would prove nothing — see $blog"
    fi
    note "initrd RESCUE: same kernel + the good initrd on the boot line -> expect u-root"
    if boot_openbios "$rlog" 180 'boot /ide@1/cdrom@0:\\v console=ttyS0 initrd=/ide@1/cdrom@0:\\u' \
         'Loading kernel... ok' 'Loading initrd... ok' 'Welcome to u-root'; then
        note "initrd RESCUE reached the u-root shell"
    else
        fail "initrd: supplying the good initrd did not reach 'Welcome to u-root' — the rescue itself is broken — see $rlog"
    fi
    return 0
}

ran=0
case "$ACT" in
  initrd) act_initrd; ran=1 ;;
  config) skip "the config act (Spike 10, dsl/cpio-edit.fth) is not built yet — run 'initrd' for the implemented pair" ;;
  cmdline) skip "the cmdline act (Spike 6 under OVMF) is not built yet — run 'initrd' for the implemented pair" ;;
  all)
    act_initrd; ran=1
    note "config and cmdline acts are not built yet (Spikes 10 / 6) — this run covers the initrd pair only"
    ;;
  *) echo "usage: $0 [initrd|config|cmdline|all]" >&2; exit 1 ;;
esac

(( ran )) || skip "no act ran"
pass "Spike 11 (rescue capstone), initrd path: the negative control fired — a no-initrd boot panicked with 'VFS: Unable to mount root fs on unknown-block(0,0)' — and supplying the good initrd on the boot line then reached the 'Welcome to u-root!' rescue shell. The un-edited artifact failed FIRST, so the rescue is what came up, not a boot that would have anyway. config (Spike 10) and cmdline (Spike 6) acts are the remaining build"

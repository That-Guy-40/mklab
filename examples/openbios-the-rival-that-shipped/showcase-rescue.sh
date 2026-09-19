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
  config    a broken config inside a REAL busybox initramfs (MODE=die) hangs the
            boot; the firmware (openbios-unix + dsl/cpio-edit.fth) fixes it in
            place same-length and the rescued image boots to a shell (Spike 10)
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

RWD="$WORKDIR/rescue"; rm -rf "$RWD"; mkdir -p "$RWD/stage"

# stage_iso <initrd-file> <iso-out> — a bootable CD with the kernel at `v` and the
# given initrd at `u`, SHORT names so the boot line stays under the firmware's
# ~75-char input buffer (POC-4).
stage_iso() {
    local initrd="$1" iso="$2" sdir; sdir="$(mktemp -d "$RWD/stage.XXXX")"
    cp "$KERNEL" "$sdir/V"; cp "$initrd" "$sdir/U"
    genisoimage -quiet -o "$iso" -V RESCUE -r -J "$sdir" 2>/dev/null || fail "genisoimage failed building $iso"
}

# boot_openbios <iso> <log> <timeout> <boot-line> <expect...> : boot the x86
# firmware from <iso>, type ONE boot line at the 0 > prompt, and wait for the
# expect markers in order. Returns the driver's rc (0 = all markers seen, 124 =
# timeout). Socket lives in $WORKDIR (short path — AF_UNIX caps at ~108 chars and
# the scratch tree is longer).
boot_openbios() {
    local iso="$1" log="$2" secs="$3" bl="$4"; shift 4
    local sock="$WORKDIR/rescue.sock"; rm -f "$sock" "$log"
    qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB" -initrd "$DICT" \
        -cdrom "$iso" -display none -serial "unix:$sock,server=on" -no-reboot >/dev/null 2>&1 &
    local qpid=$!
    local args=(python3 "$REPO/tools/drive-serial-repl.py" "$sock" "$log" --timeout "$secs"
                --expect "0 > " --send "$bl"$'\r')
    local e; for e in "$@"; do args+=(--expect "$e"); done
    "${args[@]}"; local rc=$?
    kill "$qpid" 2>/dev/null   # by PID, never by pattern
    return $rc
}

# the good u-root initrd on a CD, for the initrd act's rescue leg
ISO="$RWD/rescue.iso"; stage_iso "$INITRD" "$ISO"

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
    if boot_openbios "$ISO" "$blog" 120 'boot /ide@1/cdrom@0:\\v console=ttyS0' \
         'Loading kernel... ok' 'not syncing'; then
        grep -qaF 'Unable to mount root fs' "$blog" \
            || fail "initrd: the broken boot panicked but not with the expected root-fs signature — see $blog"
        note "initrd BREAK failed as designed: $(sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$blog" | tr -d '\r' | grep -aoE 'Kernel panic - not syncing: VFS: Unable to mount root fs[^]]*' | head -1)"
    else
        fail "initrd: the no-initrd boot did NOT reach its named panic (VFS: Unable to mount root fs) within the deadline — the negative control did not fire, so a rescue below would prove nothing — see $blog"
    fi
    note "initrd RESCUE: same kernel + the good initrd on the boot line -> expect u-root"
    if boot_openbios "$ISO" "$rlog" 180 'boot /ide@1/cdrom@0:\\v console=ttyS0 initrd=/ide@1/cdrom@0:\\u' \
         'Loading kernel... ok' 'Loading initrd... ok' 'Welcome to u-root'; then
        note "initrd RESCUE reached the u-root shell"
    else
        fail "initrd: supplying the good initrd did not reach 'Welcome to u-root' — the rescue itself is broken — see $rlog"
    fi
    return 0
}

# ── ACT: config ───────────────────────────────────────────────────────────────
# A REAL busybox initramfs (not u-root — u-root reads no config, so nothing can be
# broken) whose /init sources /etc/rescue.conf and boots differently by what it
# reads. BREAK ships MODE=die and the boot HANGS after printing RESCUE-FAIL, never
# reaching a shell. The RESCUE is the FIRMWARE editing the config INSIDE the
# initramfs: openbios-unix loads the cpio and dsl/cpio-edit.fth's cpio-patch
# overwrites `MODE=die\n` -> `MODE=run\n` (same 9 bytes — it refuses a length
# change), writing a fixed image the host re-reads and the firmware then boots to
# RESCUE-OK. This is Spike 10's in-place edit, carried through to a real boot.
#
# WHY A HOST-BUILT busybox INITRAMFS AND NOT A DISTRO INITRD: a real distro initrd
# is compressed (AlmaLinux's pxeboot initrd is 212 MB of XZ) — an in-firmware
# raw-newc editor cannot walk it and this firmware cannot boot it. busybox is the
# real minimal-Linux init (dracut/mkinitramfs build on it); uncompressed newc keeps
# it firmware-editable. Measured: the 2.1 MB image fits the hosted arena (alloc-mem
# ceiling is between 3 and 4 MiB), where a distro initrd never would.
act_config() {
    command -v busybox >/dev/null || skip "busybox not installed — the config act needs a static busybox for a real config-reading initramfs"
    command -v fakeroot >/dev/null || skip "fakeroot not installed — needed to author /dev/console in the initramfs without root"
    local UBIN="$WORKDIR/openbios/obj-amd64/openbios-unix" UDICT="$WORKDIR/openbios/obj-amd64/openbios-unix.dict"
    [[ -x "$UBIN" && -f "$UDICT" ]] || skip "missing $UBIN — run ./build-openbios.sh amd64 first (the hosted firmware performs the config edit)"
    local BUILDER="$HERE/fixtures/rescue/build-rescue-initramfs.sh"
    [[ -x "$BUILDER" ]] || fail "config: missing $BUILDER — this act stages the SHIPPED fixture builder"
    local f; for f in struct cpio cpio-edit; do [[ -f "$HERE/dsl/$f.fth" ]] || fail "config: missing dsl/$f.fth — this act stages the SHIPPED readers"; done

    local cwd="$RWD/config"; rm -rf "$cwd"; mkdir -p "$cwd"
    note "config: building a REAL busybox initramfs whose /init reads /etc/rescue.conf (MODE=die, broken)"
    "$BUILDER" die "$cwd/broken.cpio" >/dev/null || fail "config: could not build the broken initramfs"

    # BREAK: the broken config must hang the boot, printing its named failure and
    # NEVER reaching the shell — the negative control.
    note "config BREAK: boot the broken initramfs -> expect RESCUE-FAIL, no shell"
    local biso="$cwd/broken.iso"; stage_iso "$cwd/broken.cpio" "$biso"
    if boot_openbios "$biso" "$cwd/break.log" 120 'boot /ide@1/cdrom@0:\\v console=ttyS0 initrd=/ide@1/cdrom@0:\\u' \
         'Loading initrd... ok' 'RESCUE-FAIL'; then
        grep -qaF 'RESCUE-OK' "$cwd/break.log" \
            && fail "config: the broken initramfs reached RESCUE-OK — the bad config did NOT block boot, so the negative control is void — see $cwd/break.log"
        note "config BREAK failed as designed: $(sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$cwd/break.log" | tr -d '\r' | grep -aoE 'RESCUE-FAIL:[^"]*' | head -1)"
    else
        fail "config: the broken initramfs did not print its RESCUE-FAIL signature within the deadline — the negative control did not fire — see $cwd/break.log"
    fi

    # RESCUE: the FIRMWARE fixes the config in place. Load the cpio into a 3 MiB
    # arena buffer (the 2.1 MiB image fits; 4 MiB would exceed alloc-mem), cpio-find
    # the member, cpio-patch it SAME-LENGTH, write the fixed image out.
    note "config RESCUE: openbios-unix + dsl/cpio-edit.fth patch MODE=die -> MODE=run in place"
    local fwiso="$cwd/fw.iso" fwstage; fwstage="$(mktemp -d "$RWD/fw.XXXX")"
    cp "$HERE/dsl/struct.fth" "$fwstage/STRUCT.FTH"; cp "$HERE/dsl/cpio.fth" "$fwstage/CPIO.FTH"
    cp "$HERE/dsl/cpio-edit.fth" "$fwstage/CPIOEDIT.FTH"; cp "$cwd/broken.cpio" "$fwstage/BROKEN.CPIO"
    genisoimage -quiet -o "$fwiso" -V FW -r -J "$fwstage" 2>/dev/null || fail "config: genisoimage failed staging the edit ISO"
    local edcwd="$cwd/edit"; rm -rf "$edcwd"; mkdir -p "$edcwd"
    local edlog="$cwd/edit.log"
    ( cd "$edcwd" && printf '%s\n' \
        '300000 alloc-mem value bb' 'bb (u.) s" load-base" $setenv' \
        'load hd:\STRUCT.FTH'   'load-base load-size evaluate' \
        'load hd:\CPIO.FTH'     'load-base load-size evaluate' \
        'load hd:\CPIOEDIT.FTH' 'load-base load-size evaluate' \
        ': mkrun s" MODE=run" pad swap move 0a pad 8 + c! pad 9 ;' \
        'load hd:\BROKEN.CPIO' \
        'load-base load-size 40 s" etc/rescue.conf" mkrun cpio-patch ." PATCH=" . cr' \
        'load-base load-size s" fixed.cpio" write-file ." WROTE=" . cr' \
        'bye' | "$UBIN" -f "$fwiso" "$UDICT" 2>&1 | tr -d '\r' ) > "$edlog" 2>&1
    grep -qaE 'PATCH=-1' "$edlog" \
        || fail "config: cpio-edit.fth's cpio-patch did not report success (PATCH=-1) — $(grep -aoE 'cpio\| [A-Z-]+|panic[^ ]*' "$edlog" | head -1) — see $edlog"
    [[ -f "$edcwd/fixed.cpio" ]] || fail "config: the firmware did not write fixed.cpio (write-file failed) — see $edlog"

    # THE EDIT IS REAL OUTSIDE THE FIRMWARE'S CLAIM: host cpio extracts the member.
    local got; got="$(cpio -i --to-stdout etc/rescue.conf < "$edcwd/fixed.cpio" 2>/dev/null | tr -d '\n')"
    [[ "$got" == "MODE=run" ]] \
        || fail "config: the firmware said it patched, but host cpio reads etc/rescue.conf as '$got', not 'MODE=run' — the edit is not real on disk — see $edlog"
    cpio -it < "$edcwd/fixed.cpio" >/dev/null 2>&1 \
        || fail "config: the firmware-written fixed.cpio is not a valid cpio — the patch corrupted the archive"
    note "config: firmware patched etc/rescue.conf in place ($(stat -c%s "$edcwd/fixed.cpio") bytes, valid cpio); host confirms MODE=run"

    # RESCUE boot: the firmware-fixed initramfs must now reach the shell.
    note "config RESCUE: boot the firmware-fixed initramfs -> expect RESCUE-OK"
    local riso="$cwd/fixed.iso"; stage_iso "$edcwd/fixed.cpio" "$riso"
    if boot_openbios "$riso" "$cwd/rescue.log" 120 'boot /ide@1/cdrom@0:\\v console=ttyS0 initrd=/ide@1/cdrom@0:\\u' \
         'Loading initrd... ok' 'RESCUE-OK'; then
        note "config RESCUE reached the rescue shell (RESCUE-OK)"
    else
        fail "config: the firmware-fixed initramfs did not reach RESCUE-OK — the in-place config edit did not rescue the boot — see $cwd/rescue.log"
    fi
    return 0
}

ran=0
case "$ACT" in
  initrd) act_initrd; ran=1 ;;
  config) act_config; ran=1 ;;
  cmdline) skip "the cmdline act (Spike 6 under OVMF) is not built yet — run 'initrd' or 'config' for the implemented pairs" ;;
  all)
    act_initrd; act_config; ran=1
    note "the cmdline act is not built yet (Spike 6 under OVMF) — this run covers the initrd and config pairs"
    ;;
  *) echo "usage: $0 [initrd|config|cmdline|all]" >&2; exit 1 ;;
esac

(( ran )) || skip "no act ran"
pass "Spike 11 (rescue capstone): every requested act broke a boot, watched it FAIL FIRST with its named signature, then rescued it. initrd — a no-initrd boot panicked 'VFS: Unable to mount root fs on unknown-block(0,0)' and the good initrd on the boot line reached 'Welcome to u-root!'. config — a real busybox initramfs whose /init reads /etc/rescue.conf hung at 'RESCUE-FAIL' (MODE=die), the firmware (openbios-unix + dsl/cpio-edit.fth) patched it 'MODE=die'->'MODE=run' in place same-length (host cpio confirms the edit is real, archive still valid), and the fixed image booted to 'RESCUE-OK'. The un-edited artifact failed first in every act, so the rescue is what came up, not a boot that would have anyway. The cmdline act (Spike 6, UKI .cmdline under OVMF) is the remaining build"

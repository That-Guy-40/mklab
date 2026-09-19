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
#   config  — break: a bad line in a config FILE inside a real busybox initramfs
#             hangs the boot; rescue: the firmware (openbios-unix + dsl/cpio-edit.fth)
#             fixes it in place, same-length, and the fixed image boots (Spike 10).
#   cmdline — break: a UKI whose .cmdline lacks the rescue param hangs under OVMF;
#             rescue: uki-edit.sh GROWS .cmdline (VirtualSize bumped per Q5) and the
#             rescued UKI boots (Spike 6/8; host tool because a bootable UKI exceeds
#             the firmware arena — in-firmware pe-edit.fth is proven small-scale).
#   bzimage — the THIRD in-place editor, completing the trio (UKI/archive/bzImage):
#             the firmware follows boot_params' cmd_line_ptr and rewrites the classic
#             kernel's runtime command line in place (dsl/bootparams-edit.fth). A
#             FOREIGN decoder confirms the edit; it is oracle-proven, NOT boot-proven,
#             because Spike 7b measured this buffer is rebuilt at boot (the boot-proven
#             classic seam is the boot line — the initrd act). Reuses the cmdline-ptr
#             fixture/oracle whole.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP. Env: OPENBIOS_WORKDIR, KERNEL, INITRD.
set -u
usage() {
    cat <<'USAGE'
showcase-rescue.sh [ACT]   UKI workbench Spike 11 — break a boot, then rescue it

Three in-place editors, each turned on its native artifact type:
  config    ARCHIVE MEMBER — a broken config inside a REAL busybox initramfs
            (MODE=die) hangs the boot; the firmware (openbios-unix +
            dsl/cpio-edit.fth) fixes it in place same-length and the rescued image
            boots to a shell (Spike 10)
  cmdline   UKI SECTION — a UKI whose .cmdline lacks a rescue param hangs under
            OVMF; uki-edit.sh GROWS .cmdline to add it (VirtualSize bumped per Q5)
            and the rescued UKI boots to a shell (Spike 6/8)
  bzimage   bzImage RUNTIME COMMAND LINE — the firmware (openbios-unix +
            dsl/bootparams-edit.fth) follows boot_params' cmd_line_ptr and rewrites
            the line in place (add init=/bin/bash); a FOREIGN decoder confirms the
            edit is real in the bytes. Oracle-proven, NOT boot-proven: Spike 7b
            measured that this runtime buffer is rebuilt at boot, so the boot-proven
            classic-kernel seam is the boot line — the initrd act (Spike 7a/7b)
  initrd    BOOT LINE — a no-initrd boot panics (VFS: Unable to mount root fs); the
            good initrd on the boot line rescues it to a u-root shell (the classic
            kernel's boot-proven rescue seam, Spike 7b)
  all       every act (default); the run FAILS if any break did NOT fail first, or
            any rescue did not reach its shell / its foreign-oracle proof

The negative control is load-bearing: each act asserts the UN-edited artifact fails
(or, for bzimage, reads as the un-rescued line under a foreign decoder) BEFORE the
rescue, so a rescue that "worked" on an artifact that was fine anyway is caught.

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
# The cmdline act boots a UKI under OVMF, which needs an EFISTUB kernel (a PE, MZ
# at offset 0) — the AlmaLinux pxeboot vmlinuz the linuxboot lab fetches. The
# openbios `payload-bzImage` above is a bare bzImage and will NOT do for a UKI.
KERNEL_EFI="${KERNEL_EFI:-$HOME/linuxboot-lab/vmlinuz}"
STUB="${STUB:-/usr/lib/systemd/boot/efi/linuxx64.efi.stub}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
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
# KERNEL/INITRD are the payload the initrd/config acts BOOT; the cmdline act uses
# KERNEL_EFI and the bzimage act captures its own fixture, so those are guarded per
# act (below), not globally.
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

# uki_esp <uki.efi> <esp.img> — a FAT ESP with the UKI at the removable-media
# auto-boot path, for booting under OVMF.
uki_esp() {
    local uki="$1" esp="$2"
    rm -f "$esp"; truncate -s 96M "$esp"; mkfs.vfat -n RESCUE "$esp" >/dev/null
    mmd -i "$esp" ::/EFI ::/EFI/BOOT; mcopy -i "$esp" "$uki" ::/EFI/BOOT/BOOTX64.EFI
}

# boot_ovmf <esp> <log> <timeout> <expect...> — boot a UKI ESP under genuine OVMF
# (no -kernel/-initrd; the firmware finds \EFI\BOOT\BOOTX64.EFI), serial to <log>.
# Returns 0 if all markers were seen before the deadline. A per-run copy of the
# OVMF VARS pflash keeps runs independent.
boot_ovmf() {
    local esp="$1" log="$2" secs="$3"; shift 3
    local vars; vars="$(mktemp "$RWD/vars.XXXX.fd")"; cp "$OVMF_VARS" "$vars"; rm -f "$log"
    timeout "$secs" qemu-system-x86_64 -machine "q35,accel=$ACCEL" -cpu host -m 3072 \
        -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,unit=1,file="$vars" \
        -drive file="$esp",format=raw,if=virtio \
        -display none -serial "file:$log" >/dev/null 2>&1 || true
    local e; for e in "$@"; do grep -qaF "$e" "$log" || return 1; done
    return 0
}

# ── ACT: initrd ──────────────────────────────────────────────────────────────
# BREAK boots with NO initrd= on the line, so the kernel has no initramfs and no
# root device: it panics. RESCUE adds initrd=…\u and reaches u-root. Both boot the
# SAME kernel from the SAME ISO; only the boot line differs — which is the honest
# minimal edit (the classic-kernel rescue seam, Spike 7b).
act_initrd() {
    [[ -f "$KERNEL" ]] || skip "no kernel at $KERNEL (set KERNEL=; a bzImage the OpenBIOS loader boots)"
    [[ -f "$INITRD" ]] || skip "no initrd at $INITRD (set INITRD=; a cpio the kernel unpacks to a shell)"
    # the good u-root initrd on a CD, for the rescue leg
    local ISO="$RWD/rescue.iso"; stage_iso "$INITRD" "$ISO"
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
    [[ -f "$KERNEL" ]] || skip "no kernel at $KERNEL (set KERNEL=; a bzImage the OpenBIOS loader boots)"
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

# ── ACT: cmdline ────────────────────────────────────────────────────────────────
# A UKI (systemd EFI stub + kernel + initramfs + .cmdline), booted under genuine
# OVMF. The initramfs /init reads the KERNEL COMMAND LINE for a rescue token, so
# the UKI's .cmdline section gates the boot: BREAK ships a .cmdline WITHOUT
# rescue_ok=1 and the boot hangs at RESCUE-FAIL; the RESCUE GROWS .cmdline to add
# it. Because ukify emits .cmdline with VirtualSize == the exact string length and
# no slack (Q5, measured), growing needs the section's VirtualSize bumped — which
# the SHIPPED uki-edit.sh does by rebuilding with ukify (validated read-back), the
# persisted host deliverable a UEFI x86 box uses.
#
# WHY THE HOST TOOL AND NOT IN-FIRMWARE pe-edit.fth HERE: a bootable UKI carries a
# real EFISTUB kernel (~15 MB), and the hosted firmware's arena tops out between 3
# and 4 MiB (measured, config act), so openbios-unix cannot hold a bootable UKI to
# edit it. pe-edit.fth's in-firmware .cmdline grow is proven at small scale by the
# cmdline-edit track (Spike 6); the persisted host tool is the rescue form for a
# real UKI (Spike 8), the same honest split Spike 7b named for the classic kernel.
act_cmdline() {
    command -v ukify >/dev/null || skip "ukify not installed — needed to build the UKI (systemd-ukify)"
    command -v mkfs.vfat >/dev/null && command -v mmd >/dev/null || skip "mtools/mkfs.vfat not installed — needed to build the ESP"
    command -v busybox >/dev/null || skip "busybox not installed — the cmdline act needs a static busybox initramfs"
    command -v fakeroot >/dev/null || skip "fakeroot not installed — needed to author /dev/console without root"
    [[ -f "$STUB" ]] || skip "no systemd EFI stub at $STUB — install systemd-boot-efi"
    [[ -f "$OVMF_CODE" && -f "$OVMF_VARS" ]] || skip "no OVMF firmware at $OVMF_CODE — install ovmf"
    [[ -f "$KERNEL_EFI" ]] || skip "no EFISTUB kernel at $KERNEL_EFI — run linuxboot-uefi-kexec/fetch-kernel.sh (set KERNEL_EFI= to point elsewhere); the openbios payload-bzImage is a bare bzImage and cannot be a UKI"
    { [[ "$(od -An -tx1 -N2 "$KERNEL_EFI" | tr -d ' ')" == 4d5a ]]; } \
        || skip "$KERNEL_EFI is not a PE (no MZ) — a UKI needs an EFISTUB (CONFIG_EFI_STUB) kernel"
    local UKIEDIT="$HERE/uki-edit.sh"
    [[ -x "$UKIEDIT" ]] || fail "cmdline: missing $UKIEDIT — this act uses the SHIPPED persisted rescue tool"
    local BUILDER="$HERE/fixtures/rescue/build-rescue-initramfs.sh"
    [[ -x "$BUILDER" ]] || fail "cmdline: missing $BUILDER"

    local cwd="$RWD/cmdline"; rm -rf "$cwd"; mkdir -p "$cwd"
    note "cmdline: building a busybox initramfs whose /init reads /proc/cmdline for rescue_ok=1"
    "$BUILDER" cmdline "$cwd/init.cpio" >/dev/null || fail "cmdline: could not build the cmdline-gated initramfs"
    printf 'NAME="Lab UKI"\nID=lab-rescue\n' > "$cwd/osrel.txt"

    # BREAK: a UKI whose .cmdline lacks the rescue token -> hangs at RESCUE-FAIL.
    note "cmdline BREAK: build a UKI with .cmdline='console=ttyS0' (no rescue_ok=1) -> expect RESCUE-FAIL, no shell"
    ukify build --linux="$KERNEL_EFI" --initrd="$cwd/init.cpio" --cmdline="console=ttyS0" \
        --os-release="@$cwd/osrel.txt" --stub="$STUB" --output="$cwd/broken.efi" >/dev/null 2>&1 \
        || fail "cmdline: ukify failed building the broken UKI"
    uki_esp "$cwd/broken.efi" "$cwd/broken-esp.img"
    if boot_ovmf "$cwd/broken-esp.img" "$cwd/break.log" 90 'RESCUE-FAIL'; then
        grep -qaF 'RESCUE-OK' "$cwd/break.log" \
            && fail "cmdline: the broken UKI reached RESCUE-OK — the missing rescue param did NOT block boot, so the negative control is void — see $cwd/break.log"
        note "cmdline BREAK failed as designed: $(sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$cwd/break.log" | tr -d '\r' | grep -aoE 'RESCUE-FAIL:[^"]*' | head -1)"
    else
        fail "cmdline: the broken UKI did not print RESCUE-FAIL within the deadline — the negative control did not fire — see $cwd/break.log"
    fi

    # RESCUE: uki-edit.sh GROWS .cmdline to add the token (bumping VirtualSize).
    note "cmdline RESCUE: uki-edit.sh grows .cmdline to add rescue_ok=1 (VirtualSize bumped per Q5)"
    "$UKIEDIT" "$cwd/broken.efi" "$cwd/fixed.efi" "console=ttyS0 rescue_ok=1" > "$cwd/edit.log" 2>&1 \
        || fail "cmdline: uki-edit.sh refused or failed to grow .cmdline — $(grep -aoE 'uki-edit\| [A-Z-]+' "$cwd/edit.log" | head -1) — see $cwd/edit.log"
    # the grow is real and it is a GROW: the fixed .cmdline VirtualSize > the broken one
    local vb vf
    vb=$(objdump -h "$cwd/broken.efi" | awk '/\.cmdline/{print strtonum("0x"$3)}')
    vf=$(objdump -h "$cwd/fixed.efi"  | awk '/\.cmdline/{print strtonum("0x"$3)}')
    [[ -n "$vb" && -n "$vf" && "$vf" -gt "$vb" ]] \
        || fail "cmdline: the rescued UKI's .cmdline VirtualSize ($vf) is not larger than the broken one's ($vb) — the section did not grow, so this is not the Q5 case being exercised"
    objcopy -O binary --only-section=.cmdline "$cwd/fixed.efi" /dev/stdout 2>/dev/null | grep -qaF 'rescue_ok=1' \
        || fail "cmdline: the rescued UKI's .cmdline does not contain rescue_ok=1 under a foreign objcopy — the edit is not real"
    note "cmdline: .cmdline grown $vb -> $vf bytes, foreign objcopy confirms rescue_ok=1"

    note "cmdline RESCUE: boot the grown UKI under OVMF -> expect RESCUE-OK"
    uki_esp "$cwd/fixed.efi" "$cwd/fixed-esp.img"
    if boot_ovmf "$cwd/fixed-esp.img" "$cwd/rescue.log" 90 'RESCUE-OK'; then
        note "cmdline RESCUE reached the rescue shell (RESCUE-OK)"
    else
        fail "cmdline: the grown UKI did not reach RESCUE-OK under OVMF — the .cmdline rescue did not take — see $cwd/rescue.log"
    fi
    return 0
}

# ── ACT: bzimage ──────────────────────────────────────────────────────────────
# The THIRD in-place editor, on the third artifact type — completing the trio the
# capstone shows: UKI (.cmdline, cmdline act), archive member (cpio, config act),
# and here a bzImage's RUNTIME command line. Not every rescue target is a UKI or an
# initramfs config: a plain `kernel + initrd` boot reads its command line from a
# runtime buffer that boot_params' cmd_line_ptr names. dsl/bootparams-edit.fth
# FOLLOWS that pointer and rewrites the string in place (add `init=/bin/bash single`)
# — the classic-kernel rescue edit the readers set up.
#
# HONEST BOUNDARY (Spike 7b): this is the ONE editor the capstone does NOT carry to
# a booted shell, and that is a MEASURED fact, not a gap. cmd_line_ptr names a buffer
# the bootloader REBUILDS at each boot, so an in-firmware prompt edit does not reach
# the kernel the loader then starts (Spike 7b). The boot-proven classic-kernel seam
# is therefore the boot LINE — which is exactly the `initrd` act above. Here the edit
# is proven REAL the only honest way it can be: a FOREIGN decoder (decode-cmdline.py,
# an independent little-endian struct read) reads the firmware-written dump back and
# finds the rescue line, on BOTH ends (sentinel before, rescue after). The cmdline-ptr
# smoke track carries this across all four arches with its three refusal controls;
# this act is the capstone's one-session view, and states its own boundary.
#
# THE FIXTURE IS A PHYS-0 DUMP, reused whole from the cmdline-ptr track: cmd_line_ptr
# is 0 on disk, so the subject is guest physical memory captured from QEMU's own
# -kernel loader (a foreign producer), dumped from address 0 so the pointer is a
# direct offset. build-cmdline-ptr-fixture.sh finds a bzImage itself (BZIMAGE= or
# /boot/vmlinuz-*) and exits 77 -> SKIP when none is readable.
act_bzimage() {
    command -v file >/dev/null || skip "file not installed (libmagic) — locates the bzImage for the fixture"
    local UBIN="$WORKDIR/openbios/obj-amd64/openbios-unix" UDICT="$WORKDIR/openbios/obj-amd64/openbios-unix.dict"
    [[ -x "$UBIN" && -f "$UDICT" ]] || skip "missing $UBIN — run ./build-openbios.sh amd64 first (the hosted firmware performs the bzImage cmdline edit)"
    local BLD="$HERE/fixtures/cmdline-ptr/build-cmdline-ptr-fixture.sh"
    local DEC="$HERE/fixtures/cmdline-ptr/decode-cmdline.py"
    [[ -f "$BLD" && -f "$DEC" ]] || fail "bzimage: missing the SHIPPED cmdline-ptr fixture builder/decoder"
    local f; for f in struct bootparams bootparams-edit; do [[ -f "$HERE/dsl/$f.fth" ]] || fail "bzimage: missing dsl/$f.fth — this act stages the SHIPPED readers/editor"; done

    local cwd="$RWD/bzimage"; rm -rf "$cwd"; mkdir -p "$cwd/stage"
    note "bzimage: capturing a phys-0 boot_params dump from QEMU's -kernel loader (the foreign producer)"
    bash "$BLD" "$cwd" 2> "$cwd/fixture.err"; local frc=$?
    if [[ $frc -ne 0 ]]; then
        [[ $frc -eq 77 ]] && skip "no readable bzImage for the bzimage act — $(cat "$cwd/fixture.err") (set BZIMAGE=/path/to/bzImage)"
        fail "bzimage: the QEMU capture failed (rc=$frc) — $(cat "$cwd/fixture.err")"
    fi
    [[ -s "$cwd/CMDPTR.BIN" ]] || fail "bzimage: the dump fixture was not produced"
    local SENT RESC; SENT="$(cat "$cwd/sentinel.txt")"; RESC="$(cat "$cwd/rescue.txt")"

    # BREAK (the negative-control framing): before the edit, a FOREIGN decode of
    # cmd_line_ptr names the sentinel — a command line WITHOUT the rescue token — so
    # "the edit changed it to the rescue line" is grounded on an independent read of
    # the starting state, not assumed.
    note "bzimage BREAK: the captured cmd_line_ptr names '$SENT' — no init=/bin/bash, so it boots the normal (unrescued) system"
    local ro; ro="$(python3 "$DEC" "$cwd/CMDPTR.BIN")" || fail "bzimage: decode-cmdline could not read the fixture"
    [[ "$ro" == "$SENT" ]] || fail "bzimage: the fixture's cmd_line_ptr decodes to '$ro', not the sentinel '$SENT' — the fixture is inconsistent, so the control is void"

    # RESCUE: the firmware follows cmd_line_ptr and rewrites the line in place.
    note "bzimage RESCUE: openbios-unix + dsl/bootparams-edit.fth rewrite cmd_line_ptr in place -> '$RESC'"
    cp "$HERE/dsl/struct.fth" "$cwd/stage/STRUCT.FTH"; cp "$HERE/dsl/bootparams.fth" "$cwd/stage/BOOTPARM.FTH"
    cp "$HERE/dsl/bootparams-edit.fth" "$cwd/stage/BPEDIT.FTH"; cp "$cwd/CMDLINE-PTR.FTH" "$cwd/stage/CMDPTR.FTH"
    cp "$cwd/CMDPTR.BIN" "$cwd/stage/CMDPTR.BIN"
    local fwiso="$cwd/fw.iso"
    genisoimage -quiet -o "$fwiso" -V BZIMG -r -J "$cwd/stage" 2>/dev/null || fail "bzimage: genisoimage failed staging the edit ISO"
    local edcwd="$cwd/edit"; rm -rf "$edcwd"; mkdir -p "$edcwd"; local edlog="$cwd/edit.log"
    # 5 loads, well under the hosted grubfs ~16-load/process ceiling. Markers print
    # on their OWN line (leading cr) and the edit flag is parked in `ceok` before it
    # is printed, so the REPL's echo is never mistaken for the output (pe track).
    ( cd "$edcwd" && printf '%s\n' \
        '80000 alloc-mem value lb  lb (u.) s" load-base" $setenv' \
        'load hd:\STRUCT.FTH'   'load-base load-size evaluate' \
        'load hd:\BOOTPARM.FTH' 'load-base load-size evaluate' \
        'load hd:\BPEDIT.FTH'   'load-base load-size evaluate' \
        'load hd:\CMDPTR.FTH'   'load-base load-size evaluate' \
        'load hd:\CMDPTR.BIN' \
        'variable ceok' \
        'load-base load-size cle-open cr ." OPEN=" . cr' \
        'cr ." CMD=" bp-cmdline type cr' \
        'rescue-cmdline bp-cmdline-set ceok !' \
        'cr ceok @ if ." EDITOK" else ." EDITBAD" then cr' \
        'cr ." NEW=" bp-cmdline type cr' \
        'load-base load-size s" edited.bin" write-file drop' \
        'bye' | "$UBIN" -f "$fwiso" "$UDICT" 2>&1 | tr -d '\r' ) > "$edlog" 2>&1
    local open; open="$(grep -aoE '^OPEN=[0-9a-f]+' "$edlog" | head -1 | cut -d= -f2)"
    [[ "$open" == "0" ]] || fail "bzimage: cle-open returned status 0x${open:-<none>}, expected 0 — boot_params not found/validated in the dump — see $edlog"
    grep -qaE '^EDITOK' "$edlog" || fail "bzimage: bp-cmdline-set returned false on a valid edit — $(grep -aoE 'bp\| [A-Z-]+' "$edlog" | head -1) — see $edlog"
    [[ -f "$edcwd/edited.bin" ]] || fail "bzimage: the firmware did not write edited.bin (write-file failed) — see $edlog"

    # THE EDIT IS REAL OUTSIDE THE FIRMWARE'S CLAIM: an independent little-endian
    # struct decode of the firmware-written dump reads the rescue line — Spike 7b's
    # honest proof, the foreign oracle, since a boot cannot verify this seam here.
    local got; got="$(python3 "$DEC" "$edcwd/edited.bin")" || fail "bzimage: decode-cmdline could not read the edited dump — the pointer no longer resolves"
    [[ "$got" == "$RESC" ]] || fail "bzimage: the firmware said it edited, but a foreign decode of cmd_line_ptr reads '$got', not '$RESC' — the edit is not real in the bytes — see $edlog"
    note "bzimage: firmware rewrote cmd_line_ptr in place; a FOREIGN decoder confirms '$SENT' -> '$RESC' in the bytes (boot-proof forecloses here per Spike 7b — the boot-proven classic seam is the initrd act)"
    return 0
}

ran=0
case "$ACT" in
  initrd) act_initrd; ran=1 ;;
  config) act_config; ran=1 ;;
  cmdline) act_cmdline; ran=1 ;;
  bzimage) act_bzimage; ran=1 ;;
  all) act_initrd; act_config; act_cmdline; act_bzimage; ran=1 ;;
  *) echo "usage: $0 [initrd|config|cmdline|bzimage|all]" >&2; exit 1 ;;
esac

(( ran )) || skip "no act ran"
pass "Spike 11 (rescue capstone): the toolkit's THREE in-place editors, each turned on its native artifact type, each rescuing a broken boot with no USB stick and no chroot. config (ARCHIVE MEMBER) — a real busybox initramfs whose /init reads /etc/rescue.conf hung at 'RESCUE-FAIL' (MODE=die), the firmware (openbios-unix + dsl/cpio-edit.fth) patched it 'MODE=die'->'MODE=run' in place same-length (host cpio confirms the edit is real, archive still valid), and the fixed image booted to 'RESCUE-OK'. cmdline (UKI SECTION) — a UKI whose .cmdline lacked rescue_ok=1 hung at RESCUE-FAIL under OVMF, uki-edit.sh grew .cmdline to add it (VirtualSize bumped per Q5; foreign objcopy confirms), and the grown UKI booted to RESCUE-OK. bzimage (bzImage RUNTIME COMMAND LINE) — the firmware (openbios-unix + dsl/bootparams-edit.fth) followed boot_params' cmd_line_ptr and rewrote the line in place, and a FOREIGN little-endian decoder confirmed the sentinel became the rescue line in the bytes; this seam is oracle-proven, not boot-proven, because Spike 7b measured the runtime buffer is rebuilt at boot. initrd (BOOT LINE) — the boot-proven classic-kernel seam: a no-initrd boot panicked 'VFS: Unable to mount root fs on unknown-block(0,0)' and the good initrd on the boot line reached 'Welcome to u-root!'. The un-edited artifact failed (or read as the un-rescued line) FIRST in every act, so the rescue is what came up, not an artifact that was fine anyway"

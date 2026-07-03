#!/usr/bin/env bash
# build-minimal-arm.sh — operationalize David Corvoysier's
# "Build and boot a minimal Linux system with qemu" (kaizou.org, 23 Sep 2016) on
# a modern Debian host.
#
#   Upstream HOWTO : upstream-tutorial/  (byte-exact archive + provenance)
#   Canonical URL  : https://www.kaizou.org/2016/09/boot-minimal-linux-qemu.html
#   License        : CC BY-NC-SA 3.0 (the tutorial)
#
# The post cross-builds a whole tiny ARM Linux for QEMU's Mainstone board
# (Intel PXA270): a kernel, a hand-written static C /init that prints one line,
# an initramfs, and boots it with qemu-system-arm -M mainstone.  This script is
# the modern, non-interactive, **rootless** equivalent.
#
# Deliberate adaptations (each called out in README.md):
#   * Kernel 6.1.x LTS instead of the post's 4.7.5.  6.1 is the LAST kernel that
#     still ships arch/arm/mach-pxa/mainstone.c + mainstone_defconfig (PXA board
#     files were dropped in 6.2–6.6 when PXA went device-tree-only), so QEMU's
#     hardcoded -M mainstone still has a board to match — while building cleanly
#     with a current GCC.  The 2016 4.7.5 tarball is also long gone from the CDN.
#   * Debian's arm-linux-gnueabi cross toolchain (an ARMv5TE soft-float EABI
#     target — a match for PXA270/XScale) instead of the post's crosstool-NG
#     uClibc build.  No `sudo make install` of a toolchain; one apt line.
#   * menuconfig → a scripted `scripts/config` pass (BLK_DEV_INITRD + AEABI) with
#     a grep-assert that ABORTS if a load-bearing symbol didn't stick.  AEABI is
#     essential: mainstone_defconfig is an OABI-era config, but our toolchain is
#     EABI — mismatch and /init never runs.
#   * The initramfs bakes /dev/console via `fakeroot mknod` (rootless: a real
#     mknod needs CAP_MKNOD).  Without a console, the kernel wires /init's stdio
#     to nothing, and the post's line-buffered printf never flushes → no output.
#     (The post's bare `echo init | cpio` silently relies on the board giving it
#     a console; belt-and-suspenders, we provide one.)
#   * Two 32 MiB flash images, not the post's 64 MiB: modern QEMU's mainstone
#     rejects any other size ("device requires 33554432 bytes").
#
# THROWAWAY LAB: the "system" is one static binary that prints "Tiny init ..."
# and then spins forever (the tutorial's exact program).  There is no shell, no
# login, no network — it exists to prove a from-scratch cross-built kernel boots
# your own PID 1 on an emulated board.  Quit QEMU with Ctrl-A x.
#
# Usage:
#   build-minimal-arm.sh [build]   fetch + configure + compile kernel, build init,
#                                  pack initramfs, make flash images
#   build-minimal-arm.sh pack      rebuild init + initramfs + flash from the
#                                  already-compiled kernel (resume; no toolchain
#                                  recompile)
#   build-minimal-arm.sh test      headless boot; assert "Tiny init ..." on serial
#   build-minimal-arm.sh boot      interactive boot (serial on your terminal;
#                                  Ctrl-A x to quit)
#   build-minimal-arm.sh clean     remove the build tree
#   build-minimal-arm.sh help
#
# Env overrides: MINIMAL_ARM_BUILD_DIR (default ~/.cache/lab-create/minimal-arm-linux),
#                KERNEL_VER (default 6.1.176), CROSS (default arm-linux-gnueabi-),
#                JOBS (default nproc), TEST_TIMEOUT (default 60s).
set -euo pipefail

KERNEL_VER="${KERNEL_VER:-6.1.176}"
CROSS="${CROSS:-arm-linux-gnueabi-}"
JOBS="${JOBS:-$(nproc)}"
TEST_TIMEOUT="${TEST_TIMEOUT:-60}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

OUT="${MINIMAL_ARM_BUILD_DIR:-$HOME/.cache/lab-create/minimal-arm-linux}"
KSRC="$OUT/linux"
KBUILD="$OUT/build"
ZIMAGE="$KBUILD/arch/arm/boot/zImage"
INITRAMFS="$OUT/initramfs"
FLASH0="$OUT/mainstone-flash0.img"
FLASH1="$OUT/mainstone-flash1.img"

log()  { printf '\033[1;36m[minimal-arm]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[minimal-arm] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[minimal-arm] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ─── Host preflight (print apt-get hints; never auto-install) ────────────────
# mode "build" → the cross toolchain + kbuild deps; mode "boot" → just QEMU.
preflight() {
    local mode="${1:-build}" missing=()
    if [[ "$mode" == build ]]; then
        declare -A pkg=(
            [git]=git [cpio]=cpio [fakeroot]=fakeroot
            [bc]=bc [bison]=bison [flex]=flex
            [make]=build-essential [gcc]=build-essential
            [${CROSS}gcc]=gcc-arm-linux-gnueabi
        )
        local c
        for c in "${!pkg[@]}"; do
            command -v "$c" >/dev/null 2>&1 || missing+=("${pkg[$c]}")
        done
        # The static /init needs the ARM static libc (libc.a), shipped separately.
        if command -v "${CROSS}gcc" >/dev/null 2>&1; then
            [[ "$("${CROSS}gcc" -print-file-name=libc.a)" == /* ]] \
                || missing+=(libc6-dev-armel-cross)
        else
            missing+=(libc6-dev-armel-cross)
        fi
        if ((${#missing[@]})); then
            local uniq; uniq="$(printf '%s\n' "${missing[@]}" | sort -u | tr '\n' ' ')"
            die "missing build packages. Install with:
    sudo apt-get install -y $uniq libssl-dev libelf-dev"
        fi
    else
        command -v qemu-system-arm >/dev/null 2>&1 \
            || die "missing QEMU. Install with:
    sudo apt-get install -y qemu-system-arm"
    fi
}

# ─── 1. Kernel: mainstone_defconfig + initrd/EABI, cross-compiled, verified ──
build_kernel() {
    if [[ ! -d "$KSRC/.git" ]]; then
        log "cloning linux v$KERNEL_VER (shallow) from git.kernel.org"
        git clone --depth=1 --branch "v$KERNEL_VER" \
            https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$KSRC"
    fi
    local mk=(make -C "$KSRC" ARCH=arm O="$KBUILD")

    log "configuring kernel (mainstone_defconfig + initrd + EABI)"
    "${mk[@]}" mainstone_defconfig >/dev/null
    # initrd support (for -initrd) + the latest ARM EABI (must match our toolchain)
    "$KSRC/scripts/config" --file "$KBUILD/.config" -e BLK_DEV_INITRD -e AEABI
    "${mk[@]}" olddefconfig >/dev/null

    local sym
    for sym in CONFIG_BLK_DEV_INITRD=y CONFIG_AEABI=y; do
        grep -qx "$sym" "$KBUILD/.config" \
            || die "kernel config missing $sym — mainstone_defconfig changed?"
    done
    grep -qx '# CONFIG_OABI_COMPAT is not set' "$KBUILD/.config" \
        || warn "OABI compat is on; harmless but the target is pure EABI"

    log "compiling zImage (ARCH=arm CROSS_COMPILE=$CROSS -j$JOBS) — this takes a while"
    "${mk[@]}" CROSS_COMPILE="$CROSS" -j"$JOBS" zImage
    [[ -f "$ZIMAGE" ]] || die "kernel built but $ZIMAGE missing"
    log "kernel: $(du -h "$ZIMAGE" | cut -f1) → $ZIMAGE"
}

# ─── 2. The tiny init (byte-exact from the tutorial) + initramfs ─────────────
build_initramfs() {
    command -v "${CROSS}gcc" >/dev/null 2>&1 || die "missing ${CROSS}gcc (run: build)"
    mkdir -p "$OUT"

    # The tutorial's program, verbatim.
    cat > "$OUT/init.c" <<'EOF'
#include <stdio.h>

void main()
{
	printf("Tiny init ...\n");
	while(1);
}
EOF
    log "compiling static ARM /init (armv5te / xscale)"
    "${CROSS}gcc" -static -march=armv5te -mtune=xscale -Wa,-mcpu=xscale \
        "$OUT/init.c" -o "$OUT/init"
    if command -v file >/dev/null 2>&1; then
        file "$OUT/init" | grep -q 'statically linked' \
            || die "init is not static — check libc6-dev-armel-cross"
    fi

    # Pack the cpio.  Bake /dev/console under fakeroot so the kernel can wire up
    # /init's stdio (rootless: a real mknod needs CAP_MKNOD).
    local root="$OUT/initramfs-root"
    rm -rf "$root"; mkdir -p "$root/dev"; cp "$OUT/init" "$root/init"
    log "packing initramfs (newc cpio, with /dev/console via fakeroot)"
    fakeroot sh -c "mknod '$root/dev/console' c 5 1
                    cd '$root' && find . | cpio -o --quiet --format=newc" > "$INITRAMFS"
    log "initramfs: $(du -h "$INITRAMFS" | cut -f1) → $INITRAMFS"
}

# ─── 3. Mainstone flash banks — EXACTLY 32 MiB each (modern QEMU) ────────────
make_flash() {
    local f
    for f in "$FLASH0" "$FLASH1"; do
        dd if=/dev/zero of="$f" bs=1024 count=32768 status=none
    done
    log "flash: two 32 MiB banks ($FLASH0, $FLASH1)"
}

# ─── QEMU launch (shared by boot/test) ──────────────────────────────────────
qemu_cmd() {
    printf '%s\0' qemu-system-arm -M mainstone \
        -kernel "$ZIMAGE" -append 'console=ttyS0' \
        -drive "if=pflash,format=raw,file=$FLASH0" \
        -drive "if=pflash,format=raw,file=$FLASH1" \
        -initrd "$INITRAMFS"
}

check_artifacts() {
    [[ -f "$ZIMAGE"    ]] || die "no kernel — run: build-minimal-arm.sh build"
    [[ -f "$INITRAMFS" ]] || die "no initramfs — run: build-minimal-arm.sh pack"
    [[ -f "$FLASH0" && -f "$FLASH1" ]] || make_flash
}

do_boot() {
    preflight boot; check_artifacts
    log "booting (serial on this terminal; quit with Ctrl-A x)"
    mapfile -d '' -t cmd < <(qemu_cmd)
    exec "${cmd[@]}" -nographic
}

do_test() {
    preflight boot; check_artifacts
    local logf="$OUT/serial-test.log"
    log "headless boot, up to ${TEST_TIMEOUT}s, expecting 'Tiny init ...'"
    mapfile -d '' -t cmd < <(qemu_cmd)
    timeout --foreground "$TEST_TIMEOUT" "${cmd[@]}" -nographic > "$logf" 2>&1 &
    local qpid=$!
    local ok=1
    # poll the log; kill QEMU by its recorded PID the instant we see the marker
    for _ in $(seq 1 "$TEST_TIMEOUT"); do
        if grep -q 'Tiny init' "$logf" 2>/dev/null; then ok=0; break; fi
        kill -0 "$qpid" 2>/dev/null || break
        sleep 1
    done
    kill "$qpid" 2>/dev/null || true
    wait "$qpid" 2>/dev/null || true
    if [[ "$ok" == 0 ]]; then
        log "PASS — 'Tiny init ...' printed (full serial: $logf)"
    else
        die "FAIL — marker not seen in ${TEST_TIMEOUT}s (serial: $logf)"
    fi
}

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'; }

main() {
    case "${1:-build}" in
        build)  preflight build; build_kernel; build_initramfs; make_flash
                log "done. Boot it: $0 test   (or: $0 boot)";;
        pack)   preflight build; build_initramfs; make_flash;;
        test)   do_test;;
        boot)   do_boot;;
        clean)  log "removing $OUT"; rm -rf "$OUT";;
        help|-h|--help) usage;;
        *) die "unknown command '${1}' (try: help)";;
    esac
}
main "$@"

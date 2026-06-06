#!/usr/bin/env bash
# build-floppinux.sh — operationalize Krzysztof "w0jcik" Jankowski's FLOPPINUX
# ("An Embedded Linux on a Single Floppy") on a Debian host.
#
#   Upstream HOWTO : https://krzysztofjankowski.com/floppinux/floppinux-2025.html
#   FLOPPINUX      : v0.3.1 (Dec 2025) — kernel 6.14.11 + BusyBox 1.36.1
#
# The upstream guide is an Arch/Omarchy *menuconfig* walkthrough.  This script
# is the Debian, non-interactive, **rootless** equivalent: it produces the exact
# same three artifacts (bzImage + rootfs.cpio.xz + a bootable 1.44 MB floppy)
# with no `sudo` and no interactive config.
#
# Deliberate Debian adaptations (each called out in README.md):
#   * Host deps are apt-get names, and the script only PRINTS the install line —
#     it never installs anything (repo convention).
#   * The kernel is cross-compiled with the SAME i486-musl toolchain we already
#     fetch for BusyBox, so a 64-bit Debian host needs no `gcc-multilib`.  The
#     upstream guide builds the kernel with the host gcc; reusing the cross
#     toolchain makes the build self-contained.
#   * `menuconfig` → a tracked `kernel.config-fragment` merged onto tinyconfig,
#     plus a post-config grep that ABORTS if a load-bearing symbol didn't stick.
#   * Device nodes (/dev/console, /dev/null) are baked into the cpio under
#     `fakeroot` instead of `sudo mknod` — the standard rootless-initramfs trick
#     (fakeroot fakes the mknod, cpio records the faked char-dev in the archive).
#   * The floppy is populated with `mtools` (mcopy/mmd) instead of a root-only
#     `mount -o loop`.  syslinux installs its boot sector straight onto the
#     image file (no loopback needed).
#
# Usage:
#   build-floppinux.sh [build]     fetch + build everything → $OUT/floppinux.img
#   build-floppinux.sh pack        re-pack rootfs + floppy from already-compiled
#                                  bzImage + BusyBox (resume after `build`; no toolchain)
#   build-floppinux.sh boot        faithful graphical boot (-fda, needs a display)
#   build-floppinux.sh test        headless boot for verification (serial, -nographic)
#   build-floppinux.sh clean       remove the build tree
#   build-floppinux.sh help
#
# Env overrides: FLOPPINUX_BUILD_DIR (default ~/.cache/lab-create/floppinux),
#                KERNEL_VER, BB_VER, JOBS.
#
# THROWAWAY LAB: the booted system drops straight to a root shell with no
# password and no network.  That is fine for a floppy you boot in QEMU; do not
# treat it as a hardened system.
set -euo pipefail

# ─── Pinned versions (match FLOPPINUX 0.3.1) ─────────────────────────────────
KERNEL_VER="${KERNEL_VER:-6.14.11}"      # final i486-friendly stable release
BB_VER="${BB_VER:-1.36.1}"               # BusyBox tag is 1_36_1
FLOPPINUX_VER="0.3.1"
TOOLCHAIN_URL="https://musl.cc/i486-linux-musl-cross.tgz"
TOOLCHAIN_DIR_NAME="i486-linux-musl-cross"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
FRAGMENT="$SCRIPT_DIR/kernel.config-fragment"

OUT="${FLOPPINUX_BUILD_DIR:-$HOME/.cache/lab-create/floppinux}"
TOOLCHAIN="$OUT/$TOOLCHAIN_DIR_NAME"
CROSS="$TOOLCHAIN/bin/i486-linux-musl-"
KSRC="$OUT/linux"
BBSRC="$OUT/busybox-${BB_VER//./_}"
FS="$OUT/filesystem"
JOBS="${JOBS:-$(nproc)}"

log()  { printf '\033[1;36m[floppinux]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[floppinux] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[floppinux] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ─── Host preflight (print apt-get hints; never auto-install) ────────────────
# Debian package → a command it provides that we probe for.
preflight() {
    local need_boot="${1:-0}" missing=()
    declare -A pkg=(
        [wget]=wget [tar]=tar [xz]=xz-utils [cpio]=cpio
        [bc]=bc [bison]=bison [flex]=flex [make]=build-essential [gcc]=build-essential
        [fakeroot]=fakeroot [mkfs.fat]=dosfstools [mcopy]=mtools [syslinux]=syslinux
    )
    # Note: a no-module tinyconfig kernel does NOT need libssl-dev/libelf-dev, so
    # we don't hard-block on them. If `make bzImage` ever complains about missing
    # <openssl/*.h> or <libelf.h>, `apt-get install libssl-dev libelf-dev`.
    local c
    for c in "${!pkg[@]}"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("${pkg[$c]}")
    done
    if [[ "$need_boot" == 1 ]]; then
        command -v qemu-system-i386 >/dev/null 2>&1 || missing+=(qemu-system-x86)
    fi
    if ((${#missing[@]})); then
        # de-dup
        local uniq; uniq="$(printf '%s\n' "${missing[@]}" | sort -u | tr '\n' ' ')"
        die "missing host packages. Install with:
    sudo apt-get install -y $uniq"
    fi
    [[ -f "$FRAGMENT" ]] || die "missing kernel.config-fragment next to this script"
}

# ─── 0. Cross toolchain (i486-linux-musl, ~40 MB; cached) ────────────────────
fetch_toolchain() {
    if [[ -x "${CROSS}gcc" ]]; then log "toolchain present: ${CROSS}gcc"; return; fi
    mkdir -p "$OUT"
    log "fetching i486-musl cross toolchain"
    wget -q --show-progress -O "$OUT/toolchain.tgz" "$TOOLCHAIN_URL"
    tar -xf "$OUT/toolchain.tgz" -C "$OUT"
    rm -f "$OUT/toolchain.tgz"
    [[ -x "${CROSS}gcc" ]] || die "toolchain extracted but ${CROSS}gcc not found"
}

# ─── 1. Kernel: tinyconfig + fragment, cross-compiled, verified ──────────────
build_kernel() {
    if [[ ! -d "$KSRC/.git" ]]; then
        log "cloning linux v$KERNEL_VER (shallow)"
        git clone --depth=1 --branch "v$KERNEL_VER" \
            https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$KSRC"
    fi
    local mk=(make -C "$KSRC" ARCH=x86 CROSS_COMPILE="$CROSS")

    log "configuring kernel (tinyconfig + fragment + olddefconfig)"
    "${mk[@]}" tinyconfig >/dev/null
    "$KSRC/scripts/kconfig/merge_config.sh" -m -O "$KSRC" "$KSRC/.config" "$FRAGMENT" >/dev/null
    "${mk[@]}" olddefconfig >/dev/null

    verify_kconfig "$KSRC/.config"

    log "compiling bzImage (-j$JOBS) — this is the long part"
    "${mk[@]}" -j"$JOBS" bzImage >/dev/null
    cp "$KSRC/arch/x86/boot/bzImage" "$OUT/bzImage"
    log "kernel: $(du -h "$OUT/bzImage" | cut -f1) → $OUT/bzImage"
}

# Abort if any load-bearing symbol failed to stick (renamed/cross-version).
verify_kconfig() {
    local cfg="$1" sym miss=()
    local want=(
        CONFIG_PRINTK CONFIG_BLK_DEV_INITRD CONFIG_RD_XZ CONFIG_XZ_DEC
        CONFIG_TTY CONFIG_VT CONFIG_VT_CONSOLE CONFIG_VGA_CONSOLE
        CONFIG_SERIAL_8250_CONSOLE
        CONFIG_BINFMT_ELF CONFIG_BINFMT_SCRIPT
        CONFIG_BLOCK CONFIG_BLK_DEV_FD CONFIG_BLK_DEV_RAM
        CONFIG_FAT_FS CONFIG_MSDOS_FS CONFIG_NLS_CODEPAGE_437
    )
    for sym in "${want[@]}"; do
        grep -q "^${sym}=y" "$cfg" || miss+=("$sym")
    done
    # 32-bit check (must NOT be 64-bit).
    ! grep -q '^CONFIG_64BIT=y' "$cfg" || miss+=("CONFIG_64BIT(should be unset)")
    # CPU: accept whatever 486 symbol this kernel uses.
    grep -qE '^CONFIG_M486(SX)?=y' "$cfg" || {
        warn "no CONFIG_M486* set — the 486 CPU choice may have been renamed."
        warn "Candidates in this tree:"; grep -nE 'config M[0-9]' "$KSRC/arch/x86/Kconfig.cpu" >&2 || true
        miss+=("CONFIG_M486*")
    }
    if ((${#miss[@]})); then
        die "kernel .config is missing required symbols: ${miss[*]}
The fragment (kernel.config-fragment) likely needs the v$KERNEL_VER name for these.
Inspect with: make -C '$KSRC' ARCH=x86 menuconfig"
    fi
    log "kernel .config verified (console + initrd + floppy + FAT symbols all set)"
}

# ─── 2. BusyBox: static, cross-compiled, curated applet set ──────────────────
build_busybox() {
    if [[ ! -d "$BBSRC" ]]; then
        log "fetching BusyBox $BB_VER"
        wget -q -O "$OUT/busybox.tar.gz" \
            "https://github.com/mirror/busybox/archive/refs/tags/${BB_VER//./_}.tar.gz"
        tar -xzf "$OUT/busybox.tar.gz" -C "$OUT"
        rm -f "$OUT/busybox.tar.gz"
    fi
    local cfg="$BBSRC/.config"
    log "configuring BusyBox (allnoconfig + curated applets, static)"
    make -C "$BBSRC" allnoconfig >/dev/null

    # Settings: static binary + large-file support, cross toolchain.
    bb_set "$cfg" CONFIG_STATIC y
    bb_set "$cfg" CONFIG_LFS y
    bb_set "$cfg" CONFIG_CROSS_COMPILER_PREFIX "\"$CROSS\""
    bb_set "$cfg" CONFIG_SYSROOT "\"$TOOLCHAIN\""
    bb_set "$cfg" CONFIG_EXTRA_CFLAGS "\"-I$TOOLCHAIN/include\""
    bb_set "$cfg" CONFIG_EXTRA_LDFLAGS "\"-L$TOOLCHAIN/lib\""

    # Applets the HOWTO lists, PLUS the few its own rc/inittab actually invoke
    # (ln, the halt/reboot trio) which the upstream checklist quietly omits.
    local app
    for app in CAT CP DF ECHO LS MKDIR MV RM SYNC TEST LN \
               CLEAR VI INIT MDEV MOUNT UMOUNT ASH HALT; do
        bb_set "$cfg" "CONFIG_$app" y
    done
    # ash with aliases; mount with -o flags + --bind support.
    bb_set "$cfg" CONFIG_ASH_ALIAS y
    bb_set "$cfg" CONFIG_FEATURE_MOUNT_FLAGS y
    bb_set "$cfg" CONFIG_FEATURE_MDEV_CONF n   # -s scan doesn't need a conf

    yes '' | make -C "$BBSRC" oldconfig >/dev/null 2>&1 || true
    grep -q '^CONFIG_STATIC=y' "$cfg" || die "BusyBox CONFIG_STATIC didn't stick"

    log "compiling BusyBox (-j$JOBS)"
    make -C "$BBSRC" -j"$JOBS" >/dev/null
    make -C "$BBSRC" install >/dev/null     # populates $BBSRC/_install
    # Must be self-contained for the initramfs (no libs to load there). A musl
    # toolchain with -static yields a "static-pie linked" binary — still has no
    # INTERP and no NEEDED libs, so accept that spelling too.
    file "$BBSRC/_install/bin/busybox" | grep -qE 'statically linked|static-pie' \
        || warn "busybox links dynamically — it won't run in the initramfs (check CONFIG_STATIC)"

    # Verify the PRODUCED tree, not just the .config: if `make oldconfig` ever
    # dropped a boot-critical applet (an unmet CONFIG_* dependency in some future
    # BusyBox), it shows up as a missing symlink here — before we build a floppy
    # that won't boot. (Validated against 1.36.1: all of these survive a plain
    # allnoconfig+enable, so this is a forward-compat guard, not a known issue.)
    # BusyBox installs applets across bin/sbin/usr/bin/usr/sbin — check all four
    # (e.g. `clear` lands in usr/bin, not bin).
    local a d found
    for a in sh mount umount mdev ln cat mkdir clear init; do
        found=0
        for d in bin sbin usr/bin usr/sbin; do
            [[ -e "$BBSRC/_install/$d/$a" ]] && { found=1; break; }
        done
        [[ $found == 1 ]] || die "BusyBox applet '$a' missing from _install — it was dropped at oldconfig.
Check its CONFIG_$a dependency chain (run: make -C '$BBSRC' menuconfig)."
    done
    log "busybox: $(du -h "$BBSRC/_install/bin/busybox" | cut -f1) self-contained, boot applets present"
}

# Set a kconfig symbol in-place: drop any existing line, append the new value.
# Works for both `=y/=n` and string values; for `n` we write the canonical
# "# CONFIG_X is not set" form.
bb_set() {
    local cfg="$1" sym="$2" val="$3"
    sed -i "/^${sym}=/d;/^# ${sym} is not set/d" "$cfg"
    if [[ "$val" == n ]]; then
        printf '# %s is not set\n' "$sym" >> "$cfg"
    else
        printf '%s=%s\n' "$sym" "$val" >> "$cfg"
    fi
}

# ─── 3. Root filesystem → rootfs.cpio.xz (device nodes via fakeroot) ─────────
assemble_rootfs() {
    log "assembling root filesystem"
    rm -rf "$FS"
    cp -a "$BBSRC/_install" "$FS"
    mkdir -p "$FS"/{dev,proc,sys,tmp,home,mnt,etc/init.d}

    # /etc/inittab — busybox init's job list (verbatim from FLOPPINUX 0.3.1).
    cat > "$FS/etc/inittab" <<'EOF'
::sysinit:/etc/init.d/rc
::askfirst:/bin/sh
::restart:/sbin/init
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF

    # /etc/init.d/rc — the boot script (verbatim from FLOPPINUX 0.3.1): mount
    # the kernel vfs, let mdev populate /dev, then mount the floppy's own FAT
    # area and bind its /data onto /home before dropping to a shell.
    cat > "$FS/etc/init.d/rc" <<'EOF'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mdev -s
ln -s /proc/mounts /etc/mtab
mkdir -p /mnt /home
mount -t msdos -o rw /dev/fd0 /mnt
mkdir -p /mnt/data
mount --bind /mnt/data /home
clear
cat welcome
cd /home
/bin/sh
EOF
    chmod +x "$FS/etc/init.d/rc"

    # /welcome — the 0.3.1 splash (cat'd by rc at the end of boot).
    cat > "$FS/welcome" <<'EOF'
                    _________________
                   /_/ FLOPPINUX  /_/;
                  / ' boot disk  ' //
                 / '------------' //
                /   .--------.   //
               /   /         /  //
              .___/_________/__//   1440KiB
              '===\_________\=='   3.5"

_______FLOPPINUX_V_0.3.1 __________________________________
_______AN_EMBEDDED_SINGLE_FLOPPY_LINUX_DISTRIBUTION _______
_______BY_KRZYSZTOF_KRYSTIAN_JANKOWSKI ____________________
_______2025.12 ____________________________________________
EOF

    # Bake /dev/console + /dev/null and root-own everything INSIDE one fakeroot
    # session, then pack — so the faked char-devs and uid 0 land in the archive.
    log "packing rootfs.cpio.xz (fakeroot: mknod + chown + cpio)"
    # $1/$2 are the inner bash's positional args (FS, OUT) — not outer expansion.
    # shellcheck disable=SC2016
    fakeroot bash -c '
        set -e
        cd "$1"
        mknod dev/console c 5 1
        mknod dev/null    c 1 3
        chown -R 0:0 .
        find . | cpio -H newc -o --quiet | xz --check=crc32 --lzma2=dict=512KiB -e > "$2/rootfs.cpio.xz"
    ' _ "$FS" "$OUT"

    # Cheap, no-boot proof that /dev/console survived as a char device 5,1 —
    # if it didn't, init would have no stdio and the VM would look dead.
    local nodes; nodes="$(xz -dc "$OUT/rootfs.cpio.xz" | cpio -itv --quiet 2>/dev/null | grep -E ' dev/(console|null)$' || true)"
    grep -q '^crw.* 5,  *1 .* dev/console' <<<"$nodes" \
        || die "/dev/console is NOT a char 5,1 in the cpio — fakeroot pack failed:
$nodes"
    log "rootfs: $(du -h "$OUT/rootfs.cpio.xz" | cut -f1) (/dev/console verified as char 5,1)"
}

# ─── 4. Bootable 1.44 MB floppy (mkdosfs → syslinux → mtools) ────────────────
make_floppy() {
    log "building floppinux.img (1.44 MB, rootless via mtools)"
    local img="$OUT/floppinux.img"

    # syslinux.cfg — faithful 0.3.1 (graphical VGA console).
    cat > "$OUT/syslinux.cfg" <<EOF
DEFAULT floppinux
LABEL floppinux
SAY [ BOOTING FLOPPINUX VERSION $FLOPPINUX_VER ]
KERNEL bzImage
INITRD rootfs.cpio.xz
APPEND root=/dev/ram rdinit=/etc/init.d/rc console=tty0 tsc=unstable
EOF
    printf 'Hello, FLOPPINUX user!\n' > "$OUT/hello.txt"

    dd if=/dev/zero of="$img" bs=1k count=1440 status=none
    mkfs.fat -F 12 -n FLOPPINUX "$img" >/dev/null
    syslinux --install "$img"           # writes the boot sector + ldlinux.sys

    # Populate via mtools — no loop mount, no root.  Order matters only in that
    # syslinux must run before we copy (it rewrites the boot sector).
    MTOOLS_SKIP_CHECK=1 mmd   -i "$img" ::data
    MTOOLS_SKIP_CHECK=1 mcopy -i "$img" "$OUT/bzImage"        ::bzImage
    MTOOLS_SKIP_CHECK=1 mcopy -i "$img" "$OUT/rootfs.cpio.xz" ::rootfs.cpio.xz
    MTOOLS_SKIP_CHECK=1 mcopy -i "$img" "$OUT/syslinux.cfg"   ::syslinux.cfg
    MTOOLS_SKIP_CHECK=1 mcopy -i "$img" "$OUT/hello.txt"      ::data/hello.txt

    log "floppy ready: $img"
    log "free space:"; MTOOLS_SKIP_CHECK=1 mdir -i "$img" :: >&2 || true
}

# ─── boot / test ─────────────────────────────────────────────────────────────
# Faithful graphical boot (needs a display / VNC). This is the upstream command.
do_boot() {
    preflight 1
    [[ -f "$OUT/floppinux.img" ]] || die "no floppinux.img — run 'build' first"
    log "booting (graphical, -cpu 486 -m 20M). Close the window to exit."
    exec qemu-system-i386 -fda "$OUT/floppinux.img" -m 20M -cpu 486
}

# Headless verification boot.  Bypasses syslinux so we can force the serial
# console, but still attaches the floppy as /dev/fd0 so the rc script's
# `mount /dev/fd0` exercises the real FAT-data path.  Auto-poweroffs.
do_test() {
    preflight 1
    [[ -f "$OUT/bzImage" && -f "$OUT/rootfs.cpio.xz" && -f "$OUT/floppinux.img" ]] \
        || die "missing artifacts — run 'build' first"
    log "headless boot test (serial console, -nographic). Ctrl-A X to abort."
    qemu-system-i386 \
        -kernel "$OUT/bzImage" -initrd "$OUT/rootfs.cpio.xz" \
        -fda "$OUT/floppinux.img" \
        -append "root=/dev/ram rdinit=/etc/init.d/rc console=ttyS0 tsc=unstable" \
        -m 20M -cpu 486 -nographic -no-reboot
}

do_clean() { log "removing $OUT"; rm -rf "$OUT"; }

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ─── main ────────────────────────────────────────────────────────────────────
case "${1:-build}" in
    build|all)
        preflight 0
        fetch_toolchain
        build_kernel
        build_busybox
        assemble_rootfs
        make_floppy
        log "DONE. Boot it:  $0 boot     (graphical)"
        log "       or test: $0 test     (headless serial)"
        ;;
    pack)
        # Resume: re-pack rootfs + floppy from artifacts `build` already
        # compiled. No toolchain fetch, no recompile.
        [[ -f "$OUT/bzImage" ]] || die "no bzImage — run 'build' first"
        [[ -x "$BBSRC/_install/bin/busybox" ]] || die "no compiled BusyBox at $BBSRC/_install — run 'build' first"
        assemble_rootfs
        make_floppy
        log "DONE. Boot it:  $0 boot     (graphical)"
        log "       or test: $0 test     (headless serial)"
        ;;
    boot)  do_boot ;;
    test)  do_test ;;
    clean) do_clean ;;
    help|-h|--help) usage ;;
    *) die "unknown command: $1 (try: build | boot | test | clean | help)" ;;
esac

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
#                KERNEL_VER, BB_VER, JOBS,
#                FLOPPY_KB ∈ {1440 (default), 1680, 2880} — floppy size in KiB.
#                  1440 = 1.44 MB HD, 2880 = 2.88 MB ED (both boot in QEMU);
#                  1680 = 1.68 MB DMF (valid media, but does NOT boot in QEMU).
#                BUSYBOX_FULL=1 — build the FULL ~400-applet BusyBox (defconfig)
#                  instead of the ~20-applet curated set. ~1 MB binary → needs
#                  FLOPPY_KB=2880 (won't fit 1.44 MB). Network applets are inert
#                  (the kernel has no net stack); file/text/archive utils work.
#                  Also merges kernel-apm.config-fragment so `poweroff` really
#                  powers off (APM); the curated build stays APM-free (faithful 20M).
#                FLOPPINUX_MEM — QEMU RAM for boot/test (default 20M; auto-256M
#                  when the initramfs is large, e.g. BUSYBOX_FULL).
#                QOL=1 — bake in a quality-of-life pack: BusyBox-init login shell
#                  (job control, `exit` respawns), /etc/profile (PATH incl /sbin,
#                  prompt, aliases, persistent history), passwd/group, hostname,
#                  motd. Pairs with BUSYBOX_FULL; see QUALITY_OF_LIFE.md.
#                LOGIN=1 — (needs QOL=1 + BUSYBOX_FULL=1) replace the auto-spawned
#                  root shell with a real `login:` prompt: init respawns getty,
#                  which hands off to /bin/login. Account: root / password "lab"
#                  (throwaway). See QUALITY_OF_LIFE.md "Add a login prompt".
#
# THROWAWAY LAB: the booted system drops straight to a root shell with no
# password and no network (with LOGIN=1: a `login:` prompt, root / "lab" — still
# a throwaway credential).  That is fine for a floppy you boot in QEMU; do not
# treat it as a hardened system or expose it on an untrusted network.
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
APM_FRAGMENT="$SCRIPT_DIR/kernel-apm.config-fragment"   # merged only for BUSYBOX_FULL

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
    local frags=("$FRAGMENT")
    # APM (real `poweroff`) only for BUSYBOX_FULL — that build has the poweroff
    # applet and already runs at higher RAM. Out of the default kernel, the
    # curated build stays faithful (boots in ~20 MB). See kernel-apm.config-fragment.
    if [[ "${BUSYBOX_FULL:-0}" == 1 ]]; then
        frags+=("$APM_FRAGMENT")
        log "BUSYBOX_FULL: + APM power-off (kernel-apm.config-fragment)"
    fi
    "$KSRC/scripts/kconfig/merge_config.sh" -m -O "$KSRC" "$KSRC/.config" "${frags[@]}" >/dev/null
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
    # APM (real `poweroff`) is merged only for BUSYBOX_FULL — assert it there.
    [[ "${BUSYBOX_FULL:-0}" == 1 ]] && want+=(CONFIG_APM)
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
    if [[ "${BUSYBOX_FULL:-0}" == 1 ]]; then
        # FULL applet set: `make defconfig` enables BusyBox's whole standard
        # toolbox (~400 applets — grep/sed/awk/find/tar/gzip/less/…). A symlink
        # alone can't enable an applet; the code must be COMPILED IN, which is
        # exactly what defconfig does (and `make install` then makes the ~400
        # symlinks). The full static binary is ~1 MB, so this only fits a larger
        # floppy — pair it with FLOPPY_KB=2880 (see floppinux-2.88mb/).
        log "configuring BusyBox (defconfig — FULL ~400-applet set, static)"
        make -C "$BBSRC" defconfig >/dev/null
        # A few defconfig settings break this static-musl / static-PIE build.
        # None are real losses (networking is inert here; SHA falls back to C):
        bb_set "$cfg" CONFIG_TC n                    # tc.c won't COMPILE against musl
        bb_set "$cfg" CONFIG_FEATURE_NSLOOKUP_BIG n  # nslookup BIG uses ns_* resolver API
                                                     # musl lacks; small getaddrinfo form stays
        # The x86 SHA-NI hand-written .S has absolute text relocations, which a
        # static-PIE link rejects ("read-only segment has dynamic relocations").
        # Turn HWACCEL off → those .S compile empty; sha1sum/sha256sum use C.
        bb_set "$cfg" CONFIG_SHA1_HWACCEL n
        bb_set "$cfg" CONFIG_SHA256_HWACCEL n
        warn "BUSYBOX_FULL: ~1 MB binary — use FLOPPY_KB=2880 (won't fit 1.44 MB)."
        warn "Applets needing networking (wget/ping/ifconfig…) are built but inert:"
        warn "the FLOPPINUX kernel has no network stack. File/text/archive utils work."
    else
        log "configuring BusyBox (allnoconfig + curated applets, static)"
        make -C "$BBSRC" allnoconfig >/dev/null
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
    fi

    # Common to BOTH modes: static binary + large-file support, cross toolchain.
    # (defconfig builds DYNAMIC, so forcing STATIC here is load-bearing for full.)
    bb_set "$cfg" CONFIG_STATIC y
    bb_set "$cfg" CONFIG_LFS y
    bb_set "$cfg" CONFIG_CROSS_COMPILER_PREFIX "\"$CROSS\""
    bb_set "$cfg" CONFIG_SYSROOT "\"$TOOLCHAIN\""
    bb_set "$cfg" CONFIG_EXTRA_CFLAGS "\"-I$TOOLCHAIN/include\""
    bb_set "$cfg" CONFIG_EXTRA_LDFLAGS "\"-L$TOOLCHAIN/lib\""

    if [[ "${QOL:-0}" == 1 ]]; then
        # BusyBox features the QoL pack relies on. All are on in defconfig (the
        # full build); these bb_set lines are no-ops there and enable QoL in the
        # curated set.
        bb_set "$cfg" CONFIG_FEATURE_USE_INITTAB y        # init must read /etc/inittab
        bb_set "$cfg" CONFIG_FEATURE_INIT_SCTTY y         # ctty for a leading-dash (login) cmd
        bb_set "$cfg" CONFIG_FEATURE_EDITING y            # up-arrow history + line edit
        bb_set "$cfg" CONFIG_FEATURE_EDITING_SAVEHISTORY y
        bb_set "$cfg" CONFIG_FEATURE_TAB_COMPLETION y
        bb_set "$cfg" CONFIG_FEATURE_LS_COLOR y
        bb_set "$cfg" CONFIG_ASH_EXPAND_PRMT y            # PS1 \u \h \w escapes
        bb_set "$cfg" CONFIG_SETSID y                     # for the live job-control demo
    fi

    yes '' | make -C "$BBSRC" oldconfig >/dev/null 2>&1 || true
    grep -q '^CONFIG_STATIC=y' "$cfg" || die "BusyBox CONFIG_STATIC didn't stick"

    log "compiling BusyBox (-j$JOBS)"
    # Capture to a log: BusyBox links via scripts/trylink, which prints the
    # "undefined reference" diagnostics to STDOUT — so a bare >/dev/null hides
    # exactly the errors you need when a defconfig applet hits a musl gap.
    if ! make -C "$BBSRC" -j"$JOBS" >"$OUT/busybox-build.log" 2>&1; then
        warn "BusyBox build failed. Undefined references (musl gaps), if any:"
        grep -ioE 'undefined reference to .*' "$OUT/busybox-build.log" | sort -u | sed 's/^/    /' >&2 || true
        die "BusyBox compile/link failed — full log: $OUT/busybox-build.log
Map an undefined symbol to its applet (grep the BusyBox source) and disable that
applet with CONFIG_<APPLET>=n in this script's BUSYBOX_FULL branch, then rebuild."
    fi
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
    log "busybox: $(du -h "$BBSRC/_install/bin/busybox" | cut -f1) self-contained, $(find "$BBSRC/_install" -type l | wc -l) applets"
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

# QoL rootfs (QOL=1): hand PID 1 to BusyBox init, which respawns a *login* shell
# (`-/bin/sh`) with a controlling tty — so job control works, `exit` respawns
# instead of panicking, and /etc/profile is sourced. Plus passwd/group (names),
# hostname, motd, and a friendly profile (PATH incl /sbin, prompt, aliases,
# history persisted to /home). Needs the QoL BusyBox features (build_busybox).
write_qol_rootfs() {
    # rc runs the same setup, sets the hostname, then EXECs init (no shell drop).
    # The QoL inittab has NO ::sysinit, so init does not re-run rc.
    cat > "$FS/etc/init.d/rc" <<'EOF'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mdev -s
ln -s /proc/mounts /etc/mtab
[ -r /etc/hostname ] && hostname "$(cat /etc/hostname)"
mkdir -p /mnt /home
mount -t msdos -o rw /dev/fd0 /mnt
mkdir -p /mnt/data
mount --bind /mnt/data /home
clear
cat welcome
exec /sbin/init || exec /bin/sh
EOF
    if [[ "${LOGIN:-0}" == 1 ]]; then
        # LOGIN=1: init respawns getty → /bin/login (a real `login:` prompt).
        # getty's TTY arg "-" reuses init's already-open /dev/console, so the same
        # entry works on the tty0 graphical console AND the ttyS0 serial console.
        # No TERMTYPE arg → TERM stays unset and /etc/profile's ${TERM:-linux}
        # default holds (passing e.g. vt100 would downgrade the VGA console).
        cat > "$FS/etc/inittab" <<'EOF'
# QoL+login boot: rc (rdinit) does setup then execs init; init respawns getty,
# which shows /etc/issue + a login: prompt and hands off to /bin/login.
# No ::sysinit — rc already ran the setup.
::respawn:/sbin/getty -L 0 -
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF
    else
        cat > "$FS/etc/inittab" <<'EOF'
# QoL boot: rc (rdinit) does setup then execs init; init respawns a login shell
# with a controlling tty. No ::sysinit — rc already ran the setup.
::respawn:-/bin/sh
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF
    fi
    cat > "$FS/etc/profile" <<'EOF'
# FLOPPINUX QoL — sourced by login shells, and re-sourced by interactive
# subshells via $ENV (so aliases/prompt survive a nested `sh`).
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/home
export TERM="${TERM:-linux}"
export PAGER=less EDITOR=vi
export ENV=/etc/profile
export HISTFILE=/home/.ash_history HISTSIZE=500
alias ls='ls --color=auto' ll='ls -alF' la='ls -A' l='ls -CF'
alias grep='grep --color=auto' df='df -h' ..='cd ..'
# Graceful poweroff/reboot as shell functions. BusyBox init's signal-driven
# shutdown can't fire as PID 1 here: init installs no handler for SIGUSR2/SIGTERM
# (it relies on sigtimedwait over a blocked set), and the kernel won't DELIVER a
# SIG_DFL signal whose default action is fatal to PID 1 — so the signal queues
# but is never dispatched, and bare poweroff/reboot no-op. (SIGCHLD works only
# because its default action is "ignore", which is why respawn works.) So we do
# the graceful cleanup ourselves — leave /home, sync, unmount the floppy (clean
# FAT, no "not properly unmounted") — then the direct -f. See QUALITY_OF_LIFE.md.
poweroff() { cd /; sync; umount /home 2>/dev/null; umount /mnt 2>/dev/null; command poweroff -f "$@"; }
reboot()   { cd /; sync; umount /home 2>/dev/null; umount /mnt 2>/dev/null; command reboot   -f "$@"; }
PS1='\u@\h:\w\$ '
EOF
    # Greet tail: cd to $HOME once per login. With LOGIN=1, /bin/login already
    # prints /etc/motd, so the profile must NOT cat it again (avoid a double
    # banner); without login (auto-spawned shell) the profile shows it.
    if [[ "${LOGIN:-0}" == 1 ]]; then
        cat >> "$FS/etc/profile" <<'EOF'
# Greet: cd home once per login (login already printed /etc/motd).
if [ -z "$_FLOPPINUX_GREETED" ]; then
	export _FLOPPINUX_GREETED=1
	cd "$HOME" 2>/dev/null
fi
EOF
    else
        cat >> "$FS/etc/profile" <<'EOF'
# Greet + cd home once per login (not on every subshell).
if [ -z "$_FLOPPINUX_GREETED" ]; then
	export _FLOPPINUX_GREETED=1
	cd "$HOME" 2>/dev/null
	[ -f /etc/motd ] && cat /etc/motd
fi
EOF
    fi
    if [[ "${LOGIN:-0}" == 1 ]]; then
        # Inline MD5-crypt hash of "lab" (= busybox `cryptpw -m md5 -S floppinx lab`,
        # the same pw_encrypt /bin/login uses). get_passwd() returns this field
        # directly — no /etc/shadow needed (it only redirects to shadow when the
        # field is exactly "x"/"*"). No /etc/securetty either: when that file is
        # absent every tty counts as "secure", so root may log in on console.
        # THROWAWAY credential — never expose this on an untrusted network.
        # shellcheck disable=SC2016  # the $1$..$.. crypt hash is literal, must NOT expand
        printf 'root:$1$floppinx$2WKWnHcP/VZpbTpD57PW30:0:0:root:/home:/bin/sh\n' > "$FS/etc/passwd"
        # getty prints /etc/issue above the login: prompt. busybox getty expands
        # \\ and % escapes here, so keep it plain (no stray backslashes).
        cat > "$FS/etc/issue" <<'EOF'

 FLOPPINUX (QoL + login).  Log in as  root  (password: lab)

EOF
    else
        printf 'root:x:0:0:root:/home:/bin/sh\n' > "$FS/etc/passwd"
    fi
    printf 'root:x:0:\n'                     > "$FS/etc/group"
    printf 'floppinux\n'                     > "$FS/etc/hostname"
    cat > "$FS/etc/motd" <<'EOF'

 Welcome to FLOPPINUX (QoL build).  `busybox --list` shows every applet.
 Job control is on; `exit` respawns the shell; history persists to /home.
 To leave QEMU: `poweroff` (full build), `reboot`, or Ctrl-A then X.

EOF
}

# ─── 3. Root filesystem → rootfs.cpio.xz (device nodes via fakeroot) ─────────
assemble_rootfs() {
    # LOGIN=1 rides the QoL init handoff (needs QOL=1) and needs getty+login,
    # which only the FULL BusyBox carries. Verify the applets are actually in the
    # built tree (truer than trusting the BUSYBOX_FULL flag) and fail early.
    if [[ "${LOGIN:-0}" == 1 ]]; then
        [[ "${QOL:-0}" == 1 ]] || die "LOGIN=1 needs QOL=1 (the login prompt rides the QoL BusyBox-init handoff)."
        local ap d found
        for ap in getty login; do
            found=0
            for d in bin sbin usr/bin usr/sbin; do
                [[ -e "$BBSRC/_install/$d/$ap" ]] && { found=1; break; }
            done
            [[ $found == 1 ]] || die "LOGIN=1 needs BUSYBOX_FULL=1 — '$ap' applet missing from the built BusyBox (the curated set omits it)."
        done
    fi
    log "assembling root filesystem"
    rm -rf "$FS"
    cp -a "$BBSRC/_install" "$FS"
    mkdir -p "$FS"/{dev,proc,sys,tmp,home,mnt,etc/init.d}

    if [[ "${QOL:-0}" == 1 ]]; then
        log "QOL=1: init-handoff login shell + /etc/{profile,passwd,group,hostname,motd}"
        write_qol_rootfs
    else
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
    fi
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

# ─── 4. Bootable floppy (mkdosfs/mformat → syslinux → mtools) ────────────────
# Size knob: FLOPPY_KB ∈ {1440 (default, 1.44 MB HD), 1680 (1.68 MB DMF),
# 2880 (2.88 MB ED)}.  bzImage/rootfs are size-independent, so this only
# changes make_floppy.  NOTE: there is ONE $OUT/floppinux.img — building a new
# size REPLACES it (boot/test always act on that single file).
make_floppy() {
    local kb="${FLOPPY_KB:-1440}" desc
    case "$kb" in
        1440) desc="1.44 MB (standard high-density)" ;;
        1680) desc="1.68 MB (DMF/superformat — real hardware only)" ;;
        2880) desc="2.88 MB (extended density)" ;;
        *)    die "FLOPPY_KB must be 1440, 1680, or 2880 (got: '$kb')" ;;
    esac
    log "building floppinux.img — $desc, rootless via mtools"
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

    dd if=/dev/zero of="$img" bs=1k count="$kb" status=none
    if [[ "$kb" == 1680 ]]; then
        # mkfs.fat has no table entry for the 1.68 MB superformat, so it would
        # write a hard-disk-style BPB.  Force the DMF floppy geometry (80 cyl,
        # 2 heads, 21 sectors/track) with mformat instead.
        MTOOLS_SKIP_CHECK=1 mformat -i "$img" -t 80 -h 2 -s 21 -v FLOPPINUX ::
        warn "1.68 MB is a real-hardware DMF format — it does NOT boot under QEMU/SeaBIOS"
        warn "(the emulated floppy/BIOS path can't read the 21-sector DMF layout)."
        warn "For QEMU use FLOPPY_KB=1440 (default) or FLOPPY_KB=2880."
    else
        # mkfs.fat auto-detects the 1.44 MB (18 spt) and 2.88 MB (36 spt) geometries.
        mkfs.fat -F 12 -n FLOPPINUX "$img" >/dev/null
    fi
    syslinux --install "$img"           # writes the boot sector + ldlinux.{sys,c32}

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
# Pick the VM RAM. Upstream's 20M is right for the tiny curated image, but a big
# (BUSYBOX_FULL) initramfs — ~1.7 MB unpacked — can't be placed/unpacked in 20M
# (kernel panics: "invalid magic ... looks like an initrd"). Auto-bump when the
# initramfs is large; override either way with FLOPPINUX_MEM.
floppy_mem() {
    local def=20M
    if [[ -f "$OUT/rootfs.cpio.xz" && $(stat -c%s "$OUT/rootfs.cpio.xz") -gt 262144 ]]; then
        def=256M    # full BusyBox (>256 KiB compressed) needs the headroom
    fi
    printf '%s' "${FLOPPINUX_MEM:-$def}"
}

# Faithful graphical boot (needs a display / VNC). This is the upstream command.
do_boot() {
    preflight 1
    [[ -f "$OUT/floppinux.img" ]] || die "no floppinux.img — run 'build' first"
    local mem; mem="$(floppy_mem)"
    log "booting (graphical, -cpu 486 -m $mem). Close the window to exit."
    exec qemu-system-i386 -fda "$OUT/floppinux.img" -m "$mem" -cpu 486
}

# Headless verification boot.  Bypasses syslinux so we can force the serial
# console, but still attaches the floppy as /dev/fd0 so the rc script's
# `mount /dev/fd0` exercises the real FAT-data path.  Auto-poweroffs.
do_test() {
    preflight 1
    [[ -f "$OUT/bzImage" && -f "$OUT/rootfs.cpio.xz" && -f "$OUT/floppinux.img" ]] \
        || die "missing artifacts — run 'build' first"
    local mem; mem="$(floppy_mem)"
    log "headless boot test (serial console, -m $mem, -nographic). Ctrl-A X to abort."
    qemu-system-i386 \
        -kernel "$OUT/bzImage" -initrd "$OUT/rootfs.cpio.xz" \
        -fda "$OUT/floppinux.img" \
        -append "root=/dev/ram rdinit=/etc/init.d/rc console=ttyS0 tsc=unstable" \
        -m "$mem" -cpu 486 -nographic -no-reboot
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

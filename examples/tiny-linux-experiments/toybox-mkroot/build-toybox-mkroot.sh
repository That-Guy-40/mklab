#!/usr/bin/env bash
#
# build-toybox-mkroot.sh — operationalize toybox + mkroot (Rob Landley's
# BSD-licensed multicall binary and its built-in tiny-distro builder).
#
# toybox is the "start over and do it better" answer to BusyBox: one static
# multicall binary, ~240 commands, an Android-friendly licence. It ships its
# OWN system builder, mkroot ("make root"), which bakes a kernel + a toybox
# initramfs + a run-qemu.sh wrapper into a bootable Linux you can run in QEMU —
# the toybox sibling of this dir's floppinux (BusyBox) and micro-linux tracks.
#
# Four things this script can do, cheapest first:
#
#   --binary          build ONLY the multicall binary (`make defconfig && make`)
#                     and print the applet list. Seconds. No kernel, no QEMU.
#   --rootfs-only     build a from-source toybox initramfs (`make root`, native,
#                     host gcc — NO cross toolchain) and boot it on a kernel.
#   (default)         build a FULLY from-source bootable image for the host arch
#                     (`make root LINUX=<kernel-src>`, native) and boot it.
#   --prebuilt <arch> download Landley's prebuilt mkroot image for ANY of ~22
#                     architectures and boot its run-qemu.sh. No toolchain, no
#                     compile — the multi-arch fast lane.
#
# Cross-compiling from source for a FOREIGN arch (--arch <arch>) auto-fetches
# Landley's prebuilt "ccc/" toolchain, builds, and boots it under TCG — e.g.
# --arch sh4 (Dreamcast), m68k (Mac Quadra 800), mips (PS1/N64), or1k (open ISA).
# Because it fetches+runs a third-party prebuilt toolchain it is AUTHOR-RUN (the
# repo's toolchain-fetch gate): run it on your own host. See README.md.
#
# Rootless. Artifacts live under $WORKDIR (default ~/toybox-mkroot-build),
# OUTSIDE this repo. Nothing here needs sudo.
#
set -euo pipefail

# ---- pinned upstream (cite-don't-mirror; see UPSTREAM.md) --------------------
TOYBOX_REPO_DEFAULT="https://github.com/landley/toybox.git"
TOYBOX_REF_DEFAULT="0.8.13"                 # release tag; matches the mkroot 'latest' binaries
KERNEL_DEFAULT="6.1.176"                     # a current longterm; mkroot itself tracks mainline
MKROOT_BIN_BASE="https://landley.net/toybox/downloads/binaries/mkroot/latest"
TOOLCHAIN_BASE="https://landley.net/toybox/downloads/binaries/toolchains/latest"

# The ~22 architectures Landley publishes prebuilt mkroot images for (and that
# `make root CROSS=<arch>` builds given a ccc/ toolchain). Resolved live too.
PREBUILT_ARCHES="aarch64 armv4l armv5l armv7l i486 i686 m68k microblaze mips \
mips64 mipsel or1k powerpc powerpc64 powerpc64le riscv32 riscv64 s390x sh2eb \
sh4 sh4eb x86_64"

# ---- knobs ------------------------------------------------------------------
WORKDIR="${WORKDIR:-$HOME/toybox-mkroot-build}"
TOYBOX_REPO="$TOYBOX_REPO_DEFAULT"
TOYBOX_REF="$TOYBOX_REF_DEFAULT"
KERNEL="$KERNEL_DEFAULT"
MODE="build"          # build | binary | rootfs-only | prebuilt | cross
PREBUILT_ARCH=""
CROSS_ARCH=""
DO_BOOT=1
ACCEL="auto"          # auto | kvm | tcg
MEM="256"
SMOKE=0               # non-interactive: drive the shell, grep a marker, exit
FORCE=0
FETCH_TOOLCHAIN=1     # --arch: auto-fetch Landley's prebuilt ccc toolchain
BOOT_TIMEOUT=90       # --smoke timeout (bumped for slow foreign-arch TCG)

# ---- pretty -----------------------------------------------------------------
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
[ -t 2 ] || { c_g=; c_y=; c_r=; c_b=; c_0=; }
log()  { printf '%s[toybox]%s %s\n' "$c_g" "$c_0" "$*" >&2; }
warn() { printf '%s[toybox] WARN:%s %s\n' "$c_y" "$c_0" "$*" >&2; }
die()  { printf '%s[toybox] ERROR:%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }

usage() {
  # print the leading comment block (after the shebang) up to the first code line
  awk 'NR==1{next} /^#/{l=$0; sub(/^# ?/,"",l); print l; next} {exit}' "$0"
  cat <<EOF

Usage: $(basename "$0") [MODE] [options]

Modes (default is a full from-source bootable image for the host arch):
  --binary                Build only the multicall binary; list applets; stop.
  --rootfs-only           Build a from-source toybox initramfs (no kernel) and
                          boot it on a kernel (needs --prebuilt-kernel or a
                          prior full build to borrow a kernel from).
  --prebuilt <arch>       Fetch + boot Landley's prebuilt image for <arch>.
  --arch <arch>           Cross-compile from source for <arch>: auto-fetches
                          Landley's prebuilt toolchain, builds, boots under TCG
                          (author-run — fetch+exec of a prebuilt toolchain).
  --list-arches           Print the supported architectures and exit.

Options:
  --kernel <ver>          Kernel version to fetch from kernel.org (default $KERNEL_DEFAULT).
  --toybox-ref <ref>      toybox git tag/branch/commit (default $TOYBOX_REF_DEFAULT).
  --no-boot               Build only; do not launch QEMU.
  --no-fetch-toolchain    With --arch: use an existing ccc/ instead of fetching.
  --smoke                 Non-interactive: drive the shell, assert a marker, exit.
  --accel kvm|tcg         Force acceleration (default: kvm if /dev/kvm, else tcg).
  --memory <MB>           Guest RAM (default $MEM).
  --workdir <dir>         Artifact dir (default $WORKDIR).
  --force                 Re-fetch / rebuild even if artifacts exist.
  -h, --help              This help.

Examples:
  $(basename "$0") --binary                 # just the toybox binary + applet list
  $(basename "$0")                          # full from-source x86_64 distro, boot it
  $(basename "$0") --kernel 6.1.176 --smoke # reproducible, non-interactive check
  $(basename "$0") --prebuilt aarch64       # boot a foreign arch under TCG, no toolchain
  $(basename "$0") --arch sh4               # Dreamcast SuperH from source (auto-fetches ccc)
  $(basename "$0") --arch m68k              # Motorola 68040 → QEMU emulates a Mac Quadra 800
EOF
}

# ---- args -------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --binary)        MODE="binary" ;;
    --rootfs-only)   MODE="rootfs-only" ;;
    --prebuilt)      MODE="prebuilt"; PREBUILT_ARCH="${2:?--prebuilt needs an arch}"; shift ;;
    --arch)          MODE="cross"; CROSS_ARCH="${2:?--arch needs an arch}"; shift ;;
    --list-arches)   printf '%s\n' $PREBUILT_ARCHES | column 2>/dev/null || printf '%s\n' $PREBUILT_ARCHES; exit 0 ;;
    --kernel)        KERNEL="${2:?}"; shift ;;
    --toybox-ref)    TOYBOX_REF="${2:?}"; shift ;;
    --no-boot)       DO_BOOT=0 ;;
    --no-fetch-toolchain) FETCH_TOOLCHAIN=0 ;;
    --smoke)         SMOKE=1 ;;
    --accel)         ACCEL="${2:?}"; shift ;;
    --memory)        MEM="${2:?}"; shift ;;
    --workdir)       WORKDIR="${2:?}"; shift ;;
    --force)         FORCE=1 ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "unknown argument: $1  (see --help)" ;;
  esac
  shift
done

# ---- helpers ----------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
have() { command -v "$1" >/dev/null 2>&1; }

resolve_accel() {          # sets global ACCEL (kvm|tcg); echoes the qemu flag
  if [ "$ACCEL" = auto ]; then
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL=kvm; else ACCEL=tcg; fi
  fi
  [ "$ACCEL" = kvm ] && echo "-enable-kvm" || true
}

fetch_toybox() {
  local tb="$WORKDIR/toybox"
  if [ ! -d "$tb/.git" ]; then
    log "cloning toybox ($TOYBOX_REPO)"
    git clone --quiet "$TOYBOX_REPO" "$tb"
  fi
  ( cd "$tb"
    git fetch --tags --quiet origin || true
    git checkout --quiet "$TOYBOX_REF" 2>/dev/null || git checkout --quiet "tags/$TOYBOX_REF"
  )
  # sanity: the mkroot machinery must be present
  for f in Makefile main.c mkroot/mkroot.sh; do
    [ -e "$tb/$f" ] || die "toybox checkout missing $f — bad ref '$TOYBOX_REF'?"
  done
  local desc; desc=$(cd "$tb" && (git describe --tags 2>/dev/null || git rev-parse --short HEAD))
  log "toybox @ $desc"
  echo "$tb"
}

build_binary() {   # $1 = toybox dir ; builds the defconfig multicall binary
  local tb="$1"
  ( cd "$tb"
    [ "$FORCE" = 1 ] && make distclean >/dev/null 2>&1 || true
    log "make defconfig && make  (the multicall binary)"
    make defconfig >/dev/null 2>&1
    make >/dev/null 2>&1
  )
  [ -x "$tb/toybox" ] || die "toybox binary not produced"
  local n; n=$("$tb/toybox" | tr ' ' '\n' | grep -c . || true)
  log "built $(du -h "$tb/toybox" | cut -f1) multicall binary — $n applets"
  ( cd "$tb" && ./toybox echo "  sample: toybox echo works" >&2
    printf '  sample: '; echo -n 'toybox' | ./toybox sha256sum ) >&2 || true
}

fetch_kernel() {   # echoes the extracted kernel source dir
  local ver="$1" base="linux-$1"
  local src="$WORKDIR/$base"
  if [ ! -d "$src" ]; then
    local url="https://cdn.kernel.org/pub/linux/kernel/v${ver%%.*}.x/$base.tar.xz"
    log "fetching kernel source $base.tar.xz (source fetch — allowed)"
    curl -fSL --retry 3 -o "$WORKDIR/$base.tar.xz" "$url" \
      || die "kernel $ver not on kernel.org (EOL/pruned?). Pass --kernel <current-longterm>; see kernel.org/releases.json"
    ( cd "$WORKDIR" && tar xf "$base.tar.xz" )
  fi
  echo "$src"
}

# A dash of retro trivia per target — mkroot boots each on a real emulated board.
arch_note() {
  case "$1" in
    sh4)     echo "Hitachi/Renesas SuperH-4 — the Dreamcast's CPU family (QEMU 'r2d' SH4 board)." ;;
    sh4eb)   echo "big-endian SuperH-4 — the Sega Saturn ran dual big-endian SH-2." ;;
    m68k)    echo "Motorola 68040 — QEMU '-M q800' emulates a Macintosh Quadra 800 (1993)." ;;
    mips|mipsel|mips64) echo "MIPS — the ISA behind the PlayStation 1/2, N64 and PSP (QEMU 'malta')." ;;
    or1k)    echo "OpenRISC 1000 — a fully open-source ISA, years before RISC-V." ;;
    powerpc) echo "PowerPC — QEMU '-M g3beige' is a beige Power Mac G3 (1997)." ;;
    powerpc64|powerpc64le) echo "64-bit POWER — QEMU 'pseries', IBM's server line (HVC console)." ;;
    s390x)   echo "IBM Z mainframe — the polar opposite of a game console." ;;
    microblaze) echo "Xilinx MicroBlaze — a soft-core CPU that only exists inside an FPGA." ;;
    armv4l|armv5l) echo "classic ARM — the Game Boy Advance (ARMv4T) / Nintendo DS (ARMv5) era." ;;
    *)       echo "one of mkroot's ~22 targets." ;;
  esac
}

# Resolve Landley's toolchain tarball for an arch (names vary: -musl- vs -musleabihf-).
resolve_toolchain_tarball() {   # $1 = arch ; echoes the tarball basename
  local a="$1" cand="$1-linux-musl-cross.tar.xz"
  if curl -o /dev/null -sfIL "$TOOLCHAIN_BASE/$cand" >/dev/null 2>&1; then echo "$cand"; return; fi
  # fall back to grepping the directory index (covers aarch64/armv* eabi variants)
  local hit
  hit=$(curl -fsSL "$TOOLCHAIN_BASE/" 2>/dev/null \
        | grep -oE "${a}-[a-z0-9]*-cross\.tar\.xz" | sort -u | head -1)
  [ -n "$hit" ] && echo "$hit"
}

# Fetch + lay out a prebuilt cross toolchain so `make root CROSS=<arch>` finds it.
# NOTE: this fetches AND runs a third-party prebuilt toolchain — that's why --arch
# is author-run under the repo's toolchain-fetch gate. Runs fine on YOUR host.
fetch_toolchain() {   # $1 = arch ; sets up $WORKDIR/ccc/<arch>-*-cross + toybox/ccc symlink
  local a="$1" tb dir="$WORKDIR/ccc"
  mkdir -p "$dir"
  if ! ls -d "$dir/$a"-*-cross >/dev/null 2>&1 || [ "$FORCE" = 1 ]; then
    tb=$(resolve_toolchain_tarball "$a") || true
    [ -n "$tb" ] || die "no prebuilt toolchain for '$a' at $TOOLCHAIN_BASE/ (try --list-arches)"
    log "fetching cross toolchain $tb (~40-70 MB; prebuilt musl-cross)"
    curl -fSL -o "$dir/$tb" "$TOOLCHAIN_BASE/$tb"
    ( cd "$dir" && tar xf "$tb" )
  fi
  ls -d "$dir/$a"-*-cross >/dev/null 2>&1 || die "toolchain for '$a' did not extract as expected"
  ln -sfn "$dir" "$WORKDIR/toybox/ccc"     # mkroot looks for ./ccc in the toybox tree
  log "ccc ready: $(ls -d "$dir/$a"-*-cross)"
}

# mkroot's arg parser trips on make's -j/--jobserver flags — it self-parallelizes.
# NEVER pass -j to `make root`. (Learned the hard way; see MANUAL_TESTING.md.)
make_root() {      # $1 = toybox dir ; rest = extra VAR=val (e.g. LINUX=, CROSS=)
  local tb="$1"; shift
  ( cd "$tb"; log "make root $*"; make root "$@" )
}

boot_image() {     # $1 = dir containing run-qemu.sh (linux-kernel + initramfs)
  local d="$1" acc=""
  resolve_accel >/dev/null       # in-shell: sets global ACCEL
  [ "$ACCEL" = kvm ] && acc="-enable-kvm"
  [ -x "$d/run-qemu.sh" ] || die "no run-qemu.sh in $d (build a kernel image first, or use --prebuilt)"
  log "booting: $d/run-qemu.sh  (accel=$ACCEL, ${MEM}M)  — type 'exit' to power off"
  if [ "$SMOKE" = 1 ]; then
    # sacrificial first line absorbs the pre-prompt byte; then assert a marker
    printf '# warmup\ntoybox --version\nuname -mrs\necho TOYBOX_MKROOT_SMOKE_OK\necho "commands: $(ls /usr/bin | wc -l)"\nexit\n' \
      | timeout "$BOOT_TIMEOUT" "$d/run-qemu.sh" $acc -m "$MEM" 2>&1 | sed 's/\r$//' \
      | tee "$WORKDIR/smoke.log" | grep -aE 'toybox 0|Linux|TOYBOX_MKROOT_SMOKE_OK|commands:' || true
    grep -aq TOYBOX_MKROOT_SMOKE_OK "$WORKDIR/smoke.log" \
      && log "SMOKE OK — booted to a toybox shell" \
      || die "SMOKE FAILED — no marker (see $WORKDIR/smoke.log)"
  else
    exec "$d/run-qemu.sh" $acc -m "$MEM"
  fi
}

# ---- main -------------------------------------------------------------------
need git; need make; need gcc; need curl
have qemu-system-x86_64 || warn "qemu-system-x86_64 not found — boot steps will fail; --binary/--no-boot still work"
mkdir -p "$WORKDIR"
log "workdir: $WORKDIR"

case "$MODE" in
  # -- prebuilt: fetch a published image and boot it (any arch, no toolchain) --
  prebuilt)
    echo "$PREBUILT_ARCHES" | tr ' ' '\n' | grep -qx "$PREBUILT_ARCH" \
      || warn "'$PREBUILT_ARCH' not in the known list — trying anyway"
    have "qemu-system-${PREBUILT_ARCH}" || \
      warn "qemu-system-$PREBUILT_ARCH not found — run-qemu.sh may pick a different binary; install the matching qemu-system-*"
    d="$WORKDIR/prebuilt/$PREBUILT_ARCH"
    if [ ! -f "$d/run-qemu.sh" ] || [ "$FORCE" = 1 ]; then
      mkdir -p "$WORKDIR/prebuilt"
      log "fetching prebuilt $PREBUILT_ARCH.tgz"
      curl -fSL -o "$WORKDIR/prebuilt/$PREBUILT_ARCH.tgz" "$MKROOT_BIN_BASE/$PREBUILT_ARCH.tgz"
      ( cd "$WORKDIR/prebuilt" && rm -rf "$PREBUILT_ARCH" && tar xzf "$PREBUILT_ARCH.tgz" )
    fi
    log "prebuilt $PREBUILT_ARCH ready ($(cat "$d/docs/README" 2>/dev/null | head -1))"
    [ "$DO_BOOT" = 1 ] && boot_image "$d" || log "built only (--no-boot): $d"
    ;;

  # -- cross: from-source for a FOREIGN arch (needs a ccc/ toolchain) ----------
  cross)
    tb=$(fetch_toybox)
    log "target: ${c_b}$CROSS_ARCH${c_0} — $(arch_note "$CROSS_ARCH")"
    if [ "$FETCH_TOOLCHAIN" = 1 ]; then
      warn "--arch fetches + runs a prebuilt cross toolchain — ${c_b}author-run${c_0} under the"
      warn "repo's toolchain-fetch gate (fine on your host; an agent must hand this to you)."
      fetch_toolchain "$CROSS_ARCH"
    elif [ ! -e "$tb/ccc" ]; then
      warn "no ccc/ toolchain and --no-fetch-toolchain set. Point ccc/ at your toolchains:"
      cat >&2 <<EOF
  cd "$tb"
  ln -sf /path/to/ccc ccc            # a dir of <arch>-*-cross toolchains
  make root CROSS=$CROSS_ARCH LINUX="$WORKDIR/linux-$KERNEL"   # (no -j!)
  ./root/$CROSS_ARCH/run-qemu.sh
Prebuilt toolchains: $TOOLCHAIN_BASE/   ·   or: $(basename "$0") --prebuilt $CROSS_ARCH
EOF
      exit 3
    fi
    src=$(fetch_kernel "$KERNEL")
    make_root "$tb" "CROSS=$CROSS_ARCH" "LINUX=$src"
    d="$tb/root/$CROSS_ARCH"
    [ -x "$d/run-qemu.sh" ] || die "cross build produced no $d/run-qemu.sh (check the log above)"
    # foreign arch → no KVM (TCG only), and TCG boots are slow → give it room
    ACCEL=tcg; BOOT_TIMEOUT=300
    qb=$(grep -oE 'qemu-system-[a-z0-9_]+' "$d/run-qemu.sh" | head -1)
    have "$qb" || warn "$qb not installed — 'apt install qemu-system-misc' (or -mips/-ppc). Image built at $d."
    if [ "$DO_BOOT" = 1 ]; then
      log "booting $CROSS_ARCH under TCG (slow — it's a foreign CPU). 'exit' powers off."
      boot_image "$d"
    else
      log "built: $d   (boot by hand: $d/run-qemu.sh)"
    fi
    ;;

  # -- binary: just the multicall binary --------------------------------------
  binary)
    tb=$(fetch_toybox); build_binary "$tb"
    log "done: $tb/toybox   (try: $tb/toybox  |  $tb/toybox sed --help)"
    ;;

  # -- rootfs-only: from-source initramfs, no kernel --------------------------
  rootfs-only)
    tb=$(fetch_toybox); build_binary "$tb"
    make_root "$tb"                      # no LINUX= → initramfs only
    ir="$tb/root/host/initramfs.cpio.gz"
    [ -f "$ir" ] || die "initramfs not produced"
    log "from-source initramfs: $ir ($(du -h "$ir" | cut -f1))"
    if [ "$DO_BOOT" = 1 ]; then
      # borrow a kernel: prefer a prior prebuilt x86_64, else tell the user
      k="$WORKDIR/prebuilt/x86_64/linux-kernel"
      [ -f "$k" ] || { warn "no kernel to boot this initramfs; fetch one:  $(basename "$0") --prebuilt x86_64 --no-boot"; exit 0; }
      acc=$(resolve_accel)
      log "booting from-source initramfs on the prebuilt x86_64 kernel"
      printf '# warmup\ntoybox --version\necho ROOTFS_ONLY_OK\nexit\n' \
        | timeout 90 qemu-system-x86_64 $acc -m "$MEM" -nographic -no-reboot \
            -kernel "$k" -initrd "$ir" -append "HOST=x86_64 console=ttyS0" 2>&1 \
        | sed 's/\r$//' | grep -aE 'toybox 0|ROOTFS_ONLY_OK' || true
    fi
    ;;

  # -- build (default): full from-source bootable image for the host arch -----
  build)
    need qemu-system-x86_64
    tb=$(fetch_toybox); build_binary "$tb"
    src=$(fetch_kernel "$KERNEL")
    make_root "$tb" "LINUX=$src"         # native x86_64, host gcc, no ccc needed
    d="$tb/root/host"
    [ -f "$d/linux-kernel" ] || die "kernel image not produced (check the LINUX= build)"
    log "from-source image: $d  (kernel $(file -b "$d/linux-kernel" | grep -oE 'version [0-9.]+' | head -1))"
    [ "$DO_BOOT" = 1 ] && boot_image "$d" || log "built only (--no-boot): $d"
    ;;
esac

#!/usr/bin/env bash
# mlbuild.sh — Micro-Linux from-scratch builder.  See ../MICRO_LINUX_LAB_PLAN.md.
#
# Compiles a kernel + a tiny userspace from upstream source inside a rootless
# build container, verifies every download against a VENDORED signing key
# (never a fetched-and-trusted checksum — plan §6.0/§8), records the verified
# sha256 in versions.lock, packs an initramfs, and leaves kernel + initramfs in
# micro-linux/out/<arch>/ ready for Phase 2 (lab-vm.sh kernel+initrd backend).
#
# Tracks:
#   x86_64 / aarch64  → static BusyBox userspace + gen_init_cpio pack   (§6)
#   riscv64           → u-root userspace, plain cpio ("faithful track", §11)
#
# Usage:
#   mlbuild.sh image                      build the toolchain container image
#   mlbuild.sh build [--arch LIST] [opt]  fetch + verify + compile   (runs in container)
#   mlbuild.sh pack  [--arch LIST] [opt]  build the initramfs        (runs in container)
#   mlbuild.sh all   [--arch LIST] [opt]  build + pack
#   mlbuild.sh hashes [--arch LIST]       print sha256 of the built artifacts (host)
#   mlbuild.sh clean [--arch LIST|--all]  remove out/ artifacts (F7-guarded; host)
#
# Options:
#   --arch  LIST       comma list of {x86_64,aarch64,riscv64,ppc64le,s390x}  (default: x86_64,aarch64)
#   --engine ENG       podman | docker          (default: podman if present, else docker)
#   --offline          do not download; require tarballs already cached in out/_cache
#   --musl             also build musl-static BusyBox → initramfs-musl.cpio.gz
#   --tiny             also build tinyconfig kernel → kernel-tiny (microvm-only, ~3-5× smaller)
#   --baked            also build baked-in kernel → kernel-baked (initramfs embedded, no -initrd)
#   --all-variants     shorthand for --musl --tiny --baked --compare
#   --compare          print a side-by-side size table for all built variants
#   --help
#
# Nothing here needs root: the container runs rootless (--userns=keep-id) and the
# initramfs is packed without mknod (gen_init_cpio bakes /dev/console).
#
# STATUS: working — exercised end-to-end on 2026-05-21. All three arches compile,
# pack, and boot in QEMU (x86_64 + aarch64 → BusyBox shell; riscv64 → u-root).
# The verify/gpgv/lock flow, the F7 clean guard, and the orchestration are real.
# Keep the pinned digest/fingerprints (versions.env, keys/) current and re-vet the
# keys out-of-band (keys/README.md) before relying on it beyond a throwaway lab.
set -euo pipefail

# BASH_SOURCE (not $0) so paths resolve correctly when sourced by unit tests.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly REPO_ROOT="${SCRIPT_DIR%/*}"
# OUT_DIR is overridable so tests can point destructive ops (clean/safe_rm) at a
# throwaway tree — a unit test must never rm the real build artifacts.
readonly OUT_DIR="${MLBUILD_OUT_DIR:-$SCRIPT_DIR/out}"
readonly CACHE_DIR="$OUT_DIR/_cache"
readonly LOCK_FILE="${MLBUILD_LOCK_FILE:-$SCRIPT_DIR/versions.lock}"
readonly IMAGE="${MLBUILD_IMAGE:-micro-linux-builder:bookworm}"

# BusyBox-track login credentials (getty + login). THROWAWAY-LAB creds — safe
# ONLY because the VM is network=false (AUDIT F1). They are advertised in
# /etc/issue so they're discoverable at the prompt. Edit to taste.
readonly LAB_USER="${MLBUILD_LAB_USER:-root}"
readonly LAB_PASSWORD="${MLBUILD_LAB_PASSWORD:-micro}"

# ─── Logging (matches netboot/build-ipxe.sh) ─────────────────────────────────
_log() {
    local level="$1"; shift
    local color reset
    if [[ -t 2 ]]; then
        case "$level" in
            info)  color=$'\033[36m' ;;
            warn)  color=$'\033[33m' ;;
            error) color=$'\033[31m' ;;
            *)     color='' ;;
        esac
        reset=$'\033[0m'
    else
        color=""; reset=""
    fi
    printf '%s[%s]%s %s\n' "$color" "$level" "$reset" "$*" >&2
}
log_info()  { _log info  "$@"; }
log_warn()  { _log warn  "$@"; }
log_error() { _log error "$@"; }
die()       { _log error "$@"; exit 1; }

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" &>/dev/null || die "required command not found: $c"
    done
}

usage() {
    # print the header comment block (skip the shebang; stop at the first code line)
    awk 'NR==1 {next} /^[^#]/ {exit} {sub(/^# ?/, ""); print}' "$0"
    exit 0
}

# ─── versions.env ─────────────────────────────────────────────────────────────
load_versions() {
    local f="$SCRIPT_DIR/versions.env"
    [[ -r "$f" ]] || die "missing $f  (see plan §4 and keys/README.md)"
    # shellcheck source=/dev/null
    source "$f"
    : "${LINUX_VER:?set LINUX_VER in versions.env}"
    : "${LINUX_MAJOR:?set LINUX_MAJOR in versions.env}"
    : "${BUSYBOX_VER:?set BUSYBOX_VER in versions.env}"
    : "${UROOT_REF:?set UROOT_REF in versions.env}"
    : "${KERNEL_KEYRING:?}" "${KERNEL_FPR:?}" "${BUSYBOX_KEYRING:?}" "${BUSYBOX_FPR:?}"
}

# Reproducible builds (plan §8): export a fixed build identity + timestamp so the
# compilers embed nothing machine- or time-specific.  The kernel reads
# KBUILD_BUILD_{USER,HOST,TIMESTAMP} from the environment for include/generated/
# compile.h (the `#N SMP … <date>` version string); busybox reads
# SOURCE_DATE_EPOCH for its banner date.  Defaults here are a safety net — the
# real values are pinned in versions.env (already sourced by load_versions).
export_repro_env() {
    : "${SOURCE_DATE_EPOCH:=1700000000}"
    export SOURCE_DATE_EPOCH
    export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-mklab}"
    export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-micro-linux}"
    # LC_ALL=C so the embedded timestamp string is identical regardless of the
    # builder's locale (e.g. 24-hour "22:13:20 UTC", never a localized "10:13:20 PM").
    export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-$(LC_ALL=C date -u -d "@$SOURCE_DATE_EPOCH")}"
}

# ════════════════════════════════════════════════════════════════════════════
# Verification — the supply-chain core (plan §6.0)
# ════════════════════════════════════════════════════════════════════════════

# Confirm the vendored keyring contains EXACTLY the fingerprint pinned in
# versions.env, so a swapped keyring is caught before we trust any signature.
assert_keyring_fpr() {
    # assert_keyring_fpr KEYRING "FPR [FPR ...]" LABEL
    # Every pinned PRIMARY fingerprint must be present in the keyring (a release
    # may be signed by any of several pinned signers). A swapped keyring, an
    # unpinned (PIN-ME) value, or a missing key all fail closed.
    local keyring="$1" want="$2" label="$3"
    require_cmd gpg
    [[ -r "$keyring" ]] || die "$label keyring not found: $keyring  (see keys/README.md)"
    # gpg (unlike gpgv) insists on a homedir and writes a trustdb there; keep it
    # under out/ (gitignored, cleanable) instead of polluting $HOME / the repo.
    local gnupghome="$OUT_DIR/.gnupg"; install -d -m 700 "$gnupghome"
    local have
    have="$(gpg --homedir "$gnupghome" --no-default-keyring --keyring "$keyring" --with-colons --list-keys 2>/dev/null \
            | awk -F: '$1=="pub"{p=1;next} $1=="fpr"&&p{print toupper($10);p=0}')"
    [[ -n "$have" ]] || die "$label keyring $keyring contains no keys"
    local -a fprs; read -ra fprs <<< "$want"
    local fpr norm n=0
    for fpr in "${fprs[@]}"; do
        case "$fpr" in ''|PIN-ME*) die "$label fingerprint not pinned in versions.env  (see keys/README.md)";; esac
        norm="${fpr//[[:space:]]/}"; norm="${norm^^}"
        grep -qxF "$norm" <<<"$have" || die "$label keyring is missing a pinned fingerprint:
  pinned : $norm
  keyring: $(tr '\n' ' ' <<<"$have")
  refusing to trust this keyring — re-vet out-of-band per keys/README.md"
        n=$((n+1))
    done
    log_info "  $label keyring OK ($n pinned key(s) present)"
}

# Verify a detached signature with gpgv against the vendored keyring.
# mode=xz → the signature covers the *uncompressed* tar (kernel.org), so we
# decompress on the fly; mode=plain → signature covers the file as-is (busybox).
verify_sig() {
    local file="$1" sig="$2" keyring="$3" mode="${4:-plain}"
    require_cmd gpgv
    [[ -r "$sig" ]] || die "signature not found: $sig"
    if [[ "$mode" == "xz" ]]; then
        require_cmd xz
        xz -dc "$file" | gpgv --keyring "$keyring" "$sig" - >&2 \
            || die "PGP verification FAILED (uncompressed): $file"
    else
        gpgv --keyring "$keyring" "$sig" "$file" >&2 \
            || die "PGP verification FAILED: $file"
    fi
    log_info "  signature OK: ${file##*/}"
}

# TOFU-lock: record the verified sha256 on first sight; on later builds, fail
# loudly if a pinned version's hash changed (drift detection). versions.lock is
# committed to git, like uv.lock.
lock_check_or_record() {
    local name="$1" file="$2"
    require_cmd sha256sum
    local sha; sha="$(sha256sum "$file" | cut -d' ' -f1)"
    if [[ ! -f "$LOCK_FILE" ]]; then
        printf '# name  sha256 — auto-recorded on first verified build; commit this file.\n' > "$LOCK_FILE"
    fi
    local pinned
    pinned="$(awk -v n="$name" '$1==n {print $2; exit}' "$LOCK_FILE")"
    if [[ -n "$pinned" ]]; then
        [[ "$pinned" == "$sha" ]] || die "LOCK MISMATCH for $name
  versions.lock: $pinned
  downloaded   : $sha
  A pinned version changed upstream — investigate before proceeding."
        log_info "  $name: sha256 matches versions.lock"
    else
        printf '%s  %s\n' "$name" "$sha" >> "$LOCK_FILE"
        log_info "  $name: recorded sha256 in versions.lock"
    fi
}

# Download to cache (skip if present; refuse if --offline and missing).
fetch() {
    local url="$1" dest="$2"
    if [[ -f "$dest" ]]; then
        log_info "  cached: ${dest##*/}"
        return 0
    fi
    [[ -z "${MLBUILD_OFFLINE:-}" ]] || die "--offline: ${dest##*/} not in $CACHE_DIR"
    require_cmd curl
    log_info "  downloading ${dest##*/} …"
    # --proto =https / --tlsv1.2 defend against an HTTP-downgrade mirror (F2).
    curl -fSL --proto '=https' --tlsv1.2 --progress-bar -o "$dest" "$url"
}

# ════════════════════════════════════════════════════════════════════════════
# Per-arch toolchain knobs
# ════════════════════════════════════════════════════════════════════════════
kernel_arch()  {
    case "$1" in
        x86_64)  echo x86_64   ;; aarch64) echo arm64    ;;
        riscv64) echo riscv    ;; ppc64le) echo powerpc  ;;
        s390x)   echo s390     ;;
    esac
}
kernel_cross() {
    case "$1" in
        x86_64)  echo "" ;; aarch64) echo aarch64-linux-gnu-      ;;
        riscv64) echo riscv64-linux-gnu-   ;;
        ppc64le) echo powerpc64le-linux-gnu- ;;
        s390x)   echo s390x-linux-gnu-       ;;
    esac
}
kernel_image() {
    case "$1" in
        x86_64)  echo arch/x86/boot/bzImage     ;; aarch64) echo arch/arm64/boot/Image     ;;
        riscv64) echo arch/riscv/boot/Image      ;;
        # ppc64le: QEMU pseries takes the uncompressed ELF (vmlinux) directly.
        ppc64le) echo vmlinux                    ;;
        # s390x:   s390 Makefile produces bzImage under arch/s390/boot/.
        s390x)   echo arch/s390/boot/bzImage     ;;
    esac
}
kernel_cons()  {
    # Returns the CONFIG_ name for the arch's primary serial console driver.
    # Used in assert_kconfig (build_kernel) and set_kconfig (build_kernel_tiny).
    case "$1" in
        aarch64) echo CONFIG_SERIAL_AMBA_PL011_CONSOLE  ;;
        # ppc64le pseries: hypervisor virtual console (hvc0).
        ppc64le) echo CONFIG_HVC_CONSOLE                ;;
        # s390x s390-ccw-virtio: SCLP VT220 emulation appears as ttyS0.
        s390x)   echo CONFIG_SCLP_VT220_CONSOLE         ;;
        *)       echo CONFIG_SERIAL_8250_CONSOLE         ;;
    esac
}

# make wrapper that injects ARCH and (when cross) CROSS_COMPILE
kmake() {
    local arch="$1" dir="$2"; shift 2
    local cross; cross="$(kernel_cross "$arch")"
    local -a args=(ARCH="$(kernel_arch "$arch")")
    [[ -n "$cross" ]] && args+=(CROSS_COMPILE="$cross")
    make -C "$dir" "${args[@]}" "$@"
}

# Out-of-tree variant: adds O=<builddir> so the source tree stays unmodified.
# Used by build_kernel_tiny and pack_busybox_baked to avoid clobbering the
# in-tree default build (defconfig .config + bzImage already in out/$arch/).
kmake_oot() {
    local arch="$1" src="$2" bdir="$3"; shift 3
    local cross; cross="$(kernel_cross "$arch")"
    local -a args=(ARCH="$(kernel_arch "$arch")" O="$bdir")
    [[ -n "$cross" ]] && args+=(CROSS_COMPILE="$cross")
    make -C "$src" "${args[@]}" "$@"
}

assert_kconfig() {
    local dir="$1"; shift
    local sym
    for sym in "$@"; do
        grep -q "^${sym}=y" "$dir/.config" || die "kernel .config missing ${sym}=y"
    done
}

# Force a single, authoritative value for a Kconfig symbol in a .config.
# Appending alone is UNSAFE: if the symbol is already defined (defconfig writes
# "# CONFIG_FOO is not set"), oldconfig sees the symbol twice, warns "trying to
# reassign symbol FOO", and KEEPS THE FIRST value — so the append is silently
# dropped.  Strip every prior definition first, then write exactly one line.
#   set_kconfig <file> <SYM-without-CONFIG_> <value | n>
set_kconfig() {
    local file="$1" sym="$2" val="$3"
    sed -i -E "/^(# )?CONFIG_${sym}(=.*| is not set)\$/d" "$file"
    if [[ "$val" == n ]]; then
        printf '# CONFIG_%s is not set\n' "$sym" >> "$file"
    else
        printf 'CONFIG_%s=%s\n' "$sym" "$val" >> "$file"
    fi
}

# ════════════════════════════════════════════════════════════════════════════
# Fetch + verify + extract sources (inside the container)
# ════════════════════════════════════════════════════════════════════════════
prepare_kernel() {                          # echoes the extracted source dir
    local arch="$1"
    local tb="linux-${LINUX_VER}.tar.xz" sig="linux-${LINUX_VER}.tar.sign"
    local base="https://cdn.kernel.org/pub/linux/kernel/${LINUX_MAJOR}"
    fetch "$base/$tb"  "$CACHE_DIR/$tb"
    fetch "$base/$sig" "$CACHE_DIR/$sig"
    assert_keyring_fpr "$SCRIPT_DIR/$KERNEL_KEYRING" "$KERNEL_FPR" "kernel.org"
    verify_sig "$CACHE_DIR/$tb" "$CACHE_DIR/$sig" "$SCRIPT_DIR/$KERNEL_KEYRING" xz
    lock_check_or_record "$tb" "$CACHE_DIR/$tb"
    local b="$OUT_DIR/$arch/build"; install -d "$b"
    [[ -d "$b/linux-${LINUX_VER}" ]] || tar -C "$b" -xf "$CACHE_DIR/$tb"
    echo "$b/linux-${LINUX_VER}"
}

prepare_busybox() {                         # echoes the extracted source dir
    local arch="$1"
    local tb="busybox-${BUSYBOX_VER}.tar.bz2" sig="busybox-${BUSYBOX_VER}.tar.bz2.sig"
    local base="https://busybox.net/downloads"
    fetch "$base/$tb"  "$CACHE_DIR/$tb"
    fetch "$base/$sig" "$CACHE_DIR/$sig"
    assert_keyring_fpr "$SCRIPT_DIR/$BUSYBOX_KEYRING" "$BUSYBOX_FPR" "BusyBox"
    verify_sig "$CACHE_DIR/$tb" "$CACHE_DIR/$sig" "$SCRIPT_DIR/$BUSYBOX_KEYRING" plain
    lock_check_or_record "$tb" "$CACHE_DIR/$tb"
    require_cmd bzip2
    local b="$OUT_DIR/$arch/build"; install -d "$b"
    [[ -d "$b/busybox-${BUSYBOX_VER}" ]] || tar -C "$b" -xf "$CACHE_DIR/$tb"
    echo "$b/busybox-${BUSYBOX_VER}"
}

# ════════════════════════════════════════════════════════════════════════════
# Compile
# ════════════════════════════════════════════════════════════════════════════
build_kernel() {
    local arch="$1" src="$2"
    log_info "[$arch] kernel: defconfig + build (this takes minutes) …"
    kmake "$arch" "$src" defconfig    >/dev/null
    # defconfig gives us virtio-PCI; QEMU's 'microvm' machine (and arm/riscv 'virt'
    # with -device virtio-*-device) speak virtio-MMIO instead.  Force MMIO on so ONE
    # kernel boots on q35/virt AND on microvm — PCI stays enabled too, making this a
    # universal-transport kernel.  We use set_kconfig rather than the
    # scripts/kconfig/merge_config.sh the old TODO suggested: it already rewrites the
    # "# CONFIG_X is not set" line defconfig emits, needs no writable CWD/tempfiles,
    # and is the same helper the busybox build trusts below.  CMDLINE_DEVICES lets the
    # kernel consume the 'virtio_mmio.device=' args QEMU's microvm auto-appends; it is
    # harmless on virt, so we set it but don't gate on it (it could be renamed upstream).
    # s390x uses Channel Command Word (CCW) for VirtIO, not MMIO.  Setting
    # VIRTIO_MMIO on s390x would silently fail (depends on HAS_IOMEM which
    # s390 disables), so skip it for that arch.  All others get the universal
    # PCI+MMIO transport kernel so one image boots on q35/virt AND microvm.
    case "$arch" in
        s390x) : ;;
        *)
            set_kconfig "$src/.config" VIRTIO_MMIO y
            set_kconfig "$src/.config" VIRTIO_MMIO_CMDLINE_DEVICES y
            ;;
    esac
    kmake "$arch" "$src" olddefconfig >/dev/null
    local -a want=(CONFIG_DEVTMPFS CONFIG_BLK_DEV_INITRD "$(kernel_cons "$arch")")
    case "$arch" in
        # busybox track gzips its cpio + auto-mounts devtmpfs.
        x86_64|aarch64) want+=(CONFIG_DEVTMPFS_MOUNT CONFIG_RD_GZIP CONFIG_VIRTIO CONFIG_VIRTIO_MMIO CONFIG_VIRTIO_PCI) ;;
        # ppc64le pseries: VirtIO over the VIO bus + MMIO; HVC_DRIVER is the hvc0 prereq.
        ppc64le) want+=(CONFIG_DEVTMPFS_MOUNT CONFIG_RD_GZIP CONFIG_VIRTIO CONFIG_VIRTIO_MMIO CONFIG_HVC_DRIVER) ;;
        # s390x: VirtIO-CCW (channel subsystem) + SCLP for the console.
        s390x)   want+=(CONFIG_DEVTMPFS_MOUNT CONFIG_RD_GZIP CONFIG_VIRTIO_CCW CONFIG_SCLP) ;;
    esac
    assert_kconfig "$src" "${want[@]}"
    kmake "$arch" "$src" -j"$(nproc)"
    install -Dm0644 "$src/$(kernel_image "$arch")" "$OUT_DIR/$arch/kernel"
    log_info "[$arch] kernel → out/$arch/kernel"
}

build_busybox() {
    local arch="$1" src="$2"
    local cross; cross="$(kernel_cross "$arch")"
    local -a bb=()
    [[ -n "$cross" ]] && bb+=(CROSS_COMPILE="$cross")
    log_info "[$arch] busybox: static config + build …"
    make -C "$src" "${bb[@]}" defconfig >/dev/null
    # Enable static linking robustly.  A bare append is silently dropped:
    # defconfig already wrote "# CONFIG_STATIC is not set", and a duplicate makes
    # oldconfig "reassign" → keep-first → our value lost.  set_kconfig replaces
    # the existing line so there is exactly one definition (a silent miss here =
    # a dynamic busybox that dies exec-ing in the libc-less initramfs).
    set_kconfig "$src/.config" STATIC y
    set_kconfig "$src/.config" TC     n   # tc.c breaks vs kernel >=6.8 (CBQ removed); fixed in busybox 1.37.0
    make -C "$src" "${bb[@]}" oldconfig >/dev/null
    grep -q '^CONFIG_STATIC=y'   "$src/.config" || die "[$arch] CONFIG_STATIC didn't take"
    grep -q '^CONFIG_CTTYHACK=y' "$src/.config" || log_warn "[$arch] CONFIG_CTTYHACK not set — /init handoff may fail (§6.4)"
    grep -q '^CONFIG_SETSID=y'   "$src/.config" || log_warn "[$arch] CONFIG_SETSID not set — /init handoff may fail (§6.4)"
    make -C "$src" "${bb[@]}" -j"$(nproc)"
    # THE gate: a silently-dynamic busybox can't exec in a libc-less initramfs.
    require_cmd file
    file "$src/busybox" | grep -q 'statically linked' || die "[$arch] busybox is NOT static — refusing"
    make -C "$src" "${bb[@]}" CONFIG_PREFIX="$OUT_DIR/$arch/_install" install >/dev/null
    log_info "[$arch] busybox → out/$arch/_install"
}

# ── Variant: tinyconfig kernel ("truly micro") ───────────────────────────────
# Uses make tinyconfig (near-empty) then enables only what's needed to reach a
# BusyBox shell via QEMU microvm (virtio-mmio, no PCI).  The result is 3-5×
# smaller than a defconfig kernel.  Uses an out-of-tree build so the in-tree
# default build is untouched.
# Output: out/$arch/kernel-tiny
build_kernel_tiny() {
    local arch="$1" src="$2"
    local bdir="$OUT_DIR/$arch/build-tiny"; install -d "$bdir"
    log_info "[$arch] kernel-tiny: tinyconfig + microvm-only drivers (out-of-tree: $bdir) …"
    kmake_oot "$arch" "$src" "$bdir" tinyconfig >/dev/null

    # Enable only what's needed for our use case:
    #   initramfs  — BLK_DEV_INITRD + RD_GZIP
    #   /dev       — DEVTMPFS + DEVTMPFS_MOUNT (+ implied TMPFS)
    #   console    — arch-specific serial driver
    #   virtio-mmio only (no PCI) — microvm / minimized virt
    #   TTY + PRINTK — terminal + kernel messages
    local cfg="$bdir/.config"
    set_kconfig "$cfg" BLK_DEV_INITRD           y
    set_kconfig "$cfg" RD_GZIP                  y
    set_kconfig "$cfg" DEVTMPFS                 y
    set_kconfig "$cfg" DEVTMPFS_MOUNT           y
    set_kconfig "$cfg" TTY                      y
    set_kconfig "$cfg" PRINTK                   y
    # VirtIO transport: MMIO for all arches except s390x (uses CCW).
    case "$arch" in
        s390x) set_kconfig "$cfg" VIRTIO_CCW y ;;
        *)
            set_kconfig "$cfg" VIRTIO                      y
            set_kconfig "$cfg" VIRTIO_MMIO                 y
            set_kconfig "$cfg" VIRTIO_MMIO_CMDLINE_DEVICES y
            ;;
    esac
    # Arch-specific console driver.
    case "$arch" in
        x86_64)
            set_kconfig "$cfg" SERIAL_8250         y
            set_kconfig "$cfg" SERIAL_8250_CONSOLE y
            ;;
        aarch64)
            set_kconfig "$cfg" SERIAL_AMBA_PL011         y
            set_kconfig "$cfg" SERIAL_AMBA_PL011_CONSOLE y
            ;;
        ppc64le)
            # pseries HVC console (hypervisor virtual console).
            set_kconfig "$cfg" HVC_DRIVER  y
            set_kconfig "$cfg" HVC_CONSOLE y
            ;;
        s390x)
            # SCLP VT220 emulation → /dev/ttyS0 inside the guest.
            set_kconfig "$cfg" SCLP            y
            set_kconfig "$cfg" SCLP_VT220_CONSOLE y
            ;;
    esac
    kmake_oot "$arch" "$src" "$bdir" olddefconfig >/dev/null
    # s390x: assert CCW instead of MMIO.
    case "$arch" in
        s390x) assert_kconfig "$bdir" CONFIG_BLK_DEV_INITRD CONFIG_DEVTMPFS CONFIG_VIRTIO_CCW ;;
        *)     assert_kconfig "$bdir" CONFIG_BLK_DEV_INITRD CONFIG_DEVTMPFS CONFIG_VIRTIO_MMIO ;;
    esac
    kmake_oot "$arch" "$src" "$bdir" -j"$(nproc)"
    install -Dm0644 "$bdir/$(kernel_image "$arch")" "$OUT_DIR/$arch/kernel-tiny"
    log_info "[$arch] kernel-tiny → out/$arch/kernel-tiny ($(du -h "$OUT_DIR/$arch/kernel-tiny" | cut -f1))"
}

# ── Variant: musl-static BusyBox ─────────────────────────────────────────────
# Builds BusyBox against musl libc instead of glibc.  musl avoids the glibc
# static-NSS caveat (glibc dlopen()s libnss_*.so at runtime for name resolution;
# musl has a self-contained resolver — no runtime plugins, smaller binary).
#
# x86_64: uses musl-gcc (from Debian's musl-tools package).
# aarch64: uses aarch64-linux-musl-gcc — a wrapper built in the Containerfile by
#   cross-compiling musl 1.2.3 with gcc-aarch64-linux-gnu and generating a GCC
#   specs file via musl's tools/musl-gcc.specs.sh.
#
# Output: out/$arch/_install-musl/ + initramfs-musl.cpio.gz
build_busybox_musl() {
    local arch="$1" src="$2"
    local musl_cc cross
    case "$arch" in
        x86_64)
            musl_cc="musl-gcc"
            cross=""
            ;;
        aarch64)
            musl_cc="aarch64-linux-musl-gcc"
            # BusyBox uses $(CROSS_COMPILE)ld/ar/nm etc.; keep the gnu- prefix for
            # those tools while CC is overridden to the musl wrapper.
            cross="aarch64-linux-gnu-"
            ;;
        *)
            log_warn "[$arch] musl variant: no musl cross-compiler defined for $arch — skipping"
            return 0
            ;;
    esac
    command -v "$musl_cc" >/dev/null 2>&1 \
        || die "[$arch] $musl_cc not found — run 'mlbuild.sh image' to rebuild the toolchain"
    local -a bb=(CC="$musl_cc")
    [[ -n "$cross" ]] && bb+=(CROSS_COMPILE="$cross")
    log_info "[$arch] busybox-musl: musl-static config + build (CC=$musl_cc) …"
    make -C "$src" "${bb[@]}" defconfig >/dev/null
    set_kconfig "$src/.config" STATIC y
    set_kconfig "$src/.config" TC     n
    make -C "$src" "${bb[@]}" oldconfig >/dev/null
    grep -q '^CONFIG_STATIC=y' "$src/.config" || die "[$arch] musl CONFIG_STATIC didn't take"
    make -C "$src" "${bb[@]}" -j"$(nproc)"
    require_cmd file
    file "$src/busybox" | grep -q 'statically linked' \
        || die "[$arch] musl busybox is NOT static — check $musl_cc linkage"
    # Confirm musl linkage: a genuine musl binary has "musl" in its interpreter
    # string (dynamic) or in its symbol table (static).  Missing means glibc crept in.
    if ! file "$src/busybox" | grep -qi 'musl\|uclibc' \
       && ! strings "$src/busybox" 2>/dev/null | grep -q 'musl'; then
        log_warn "[$arch] could not confirm musl linkage — inspect with: strings $src/busybox | grep musl"
    fi
    make -C "$src" "${bb[@]}" CONFIG_PREFIX="$OUT_DIR/$arch/_install-musl" install >/dev/null
    log_info "[$arch] busybox-musl → out/$arch/_install-musl"
}

pack_busybox_musl() {
    local arch="$1" src="$2"
    [[ -d "$OUT_DIR/$arch/_install-musl" ]] \
        || { log_warn "[$arch] musl _install missing — skipping musl pack"; return 0; }
    local init="$SCRIPT_DIR/init"
    [[ -r "$init" ]] || die "missing $init"
    local gic; gic="$(build_gen_init_cpio "$src")"
    local img="$OUT_DIR/$arch/initramfs-musl.cpio.gz"
    local etc; etc="$(stage_etc)"
    log_info "[$arch] packing initramfs-musl …"
    emit_cpio_spec "$init" "$OUT_DIR/$arch/_install-musl" "$etc" \
        | "$gic" -t "${SOURCE_DATE_EPOCH:-1700000000}" - \
        | gzip -9 -n > "$img"
    require_cmd cpio
    local entries; entries="$(gzip -dc "$img" | cpio -t 2>/dev/null)"
    grep -qE '(^|/)bin/busybox$' <<<"$entries" || die "[$arch] musl initramfs has no /bin/busybox"
    log_info "[$arch] initramfs-musl → out/$arch/initramfs-musl.cpio.gz ($(du -h "$img" | cut -f1))"
}

# ── Variant: baked-in initramfs (CONFIG_INITRAMFS_SOURCE) ────────────────────
# Embeds the initramfs directly into the kernel image, so no -initrd flag is
# needed at QEMU boot — a single -kernel file is sufficient.
# Uses an out-of-tree build (build-baked/) so the in-tree default is intact.
# Output: out/$arch/kernel-baked  (no separate initramfs file)
pack_busybox_baked() {
    local arch="$1" src="$2"
    [[ -d "$OUT_DIR/$arch/_install" ]] || die "[$arch] no _install — run build first"
    local init="$SCRIPT_DIR/init"
    [[ -r "$init" ]] || die "missing $init"
    local bdir="$OUT_DIR/$arch/build-baked"; install -d "$bdir"
    log_info "[$arch] kernel-baked: embedding initramfs via INITRAMFS_SOURCE (out-of-tree) …"

    # Start from the same defconfig the normal kernel uses so the resulting
    # binary is compatible with the same QEMU configurations.
    kmake_oot "$arch" "$src" "$bdir" defconfig >/dev/null
    local cfg="$bdir/.config"
    set_kconfig "$cfg" VIRTIO_MMIO              y
    set_kconfig "$cfg" VIRTIO_MMIO_CMDLINE_DEVICES y
    kmake_oot "$arch" "$src" "$bdir" olddefconfig >/dev/null

    # Generate the cpio SPEC to a file (not gzipped — the kernel's usr/Makefile
    # runs gen_init_cpio internally and then optionally compresses).
    local spec="$OUT_DIR/$arch/initramfs.spec"
    local etc; etc="$(stage_etc)"
    emit_cpio_spec "$init" "$OUT_DIR/$arch/_install" "$etc" > "$spec"
    log_info "[$arch] cpio spec → out/$arch/initramfs.spec ($(wc -l < "$spec") lines)"

    # CONFIG_INITRAMFS_SOURCE tells the kernel's usr/Makefile to pack the cpio
    # and link it into the final bzImage/Image.  The path must be valid at
    # kernel build time — since we build inside the container with the repo at
    # /work, these paths resolve correctly.
    set_kconfig "$cfg" INITRAMFS_SOURCE "\"$spec\""
    # Compress the embedded initramfs (gzip, ~50% smaller than raw cpio).
    set_kconfig "$cfg" INITRAMFS_COMPRESSION_NONE n
    set_kconfig "$cfg" INITRAMFS_COMPRESSION_GZIP y
    kmake_oot "$arch" "$src" "$bdir" olddefconfig >/dev/null
    grep -q "INITRAMFS_SOURCE=\"$spec\"" "$bdir/.config" \
        || log_warn "[$arch] CONFIG_INITRAMFS_SOURCE not in .config — may not have taken"

    # Build: the kernel's usr/ target packs the cpio, the final link embeds it.
    kmake_oot "$arch" "$src" "$bdir" -j"$(nproc)"
    install -Dm0644 "$bdir/$(kernel_image "$arch")" "$OUT_DIR/$arch/kernel-baked"
    log_info "[$arch] kernel-baked → out/$arch/kernel-baked ($(du -h "$OUT_DIR/$arch/kernel-baked" | cut -f1), no -initrd needed)"
    log_info "[$arch]   boot with:  -kernel out/$arch/kernel-baked   (no -initrd required)"
}

# ── Size comparison table ─────────────────────────────────────────────────────
compare_sizes() {
    local arch
    printf '\n%-12s  %-8s  %-8s  %-10s  %-8s  %-12s\n' \
        "arch" "kernel" "initramfs" "initramfs" "kernel" "kernel"
    printf '%-12s  %-8s  %-8s  %-10s  %-8s  %-12s\n' \
        "" "(defcfg)" "(glibc)" "-musl" "-tiny" "-baked"
    printf '%s\n' "$(printf '%0.s─' {1..70})"
    for arch in "${ARCHES[@]}"; do
        local k it im kt kb
        k="$(du -h  "$OUT_DIR/$arch/kernel"                 2>/dev/null | cut -f1 || echo "—")"
        it="$(du -h "$OUT_DIR/$arch/initramfs.cpio.gz"      2>/dev/null | cut -f1 || echo "—")"
        im="$(du -h "$OUT_DIR/$arch/initramfs-musl.cpio.gz" 2>/dev/null | cut -f1 || echo "—")"
        kt="$(du -h "$OUT_DIR/$arch/kernel-tiny"            2>/dev/null | cut -f1 || echo "—")"
        kb="$(du -h "$OUT_DIR/$arch/kernel-baked"           2>/dev/null | cut -f1 || echo "—")"
        printf '%-12s  %-8s  %-8s  %-10s  %-8s  %-12s\n' \
            "$arch" "$k" "$it" "$im" "$kt" "$kb"
    done >&2
    printf '\n' >&2
}

build_uroot() {                              # faithful track (§11); riscv64 only
    log_info "[riscv64] u-root: build initramfs (Go modules, go.sum-verified) …"
    require_cmd go
    install -d "$OUT_DIR/riscv64"
    # Keep the Go module + build cache under out/ (gitignored, removed by `clean`)
    # rather than polluting $HOME/go and $HOME/.cache.
    export GOPATH="$OUT_DIR/go" GOCACHE="$OUT_DIR/go/build-cache"
    # u-root's default command set is "./cmds/core/..." resolved RELATIVE to the
    # u-root source tree, whose go.sum pins every cmd's transitive deps.  Running
    # `go run pkg@ver` from an unrelated dir can't resolve cmds/core or its deps
    # ("no Go commands match"/"invalid package name").  So fetch the pinned module
    # (integrity via go.sum — plan §11), copy it somewhere writable, drop its
    # stale vendored tree (forces -mod=mod resolution), and run u-root from inside.
    local moddir
    moddir="$(GOFLAGS=-mod=mod go mod download -json "github.com/u-root/u-root@${UROOT_REF}" \
                | sed -n 's/.*"Dir": "\(.*\)".*/\1/p')"
    [[ -n "$moddir" && -d "$moddir" ]] || die "[riscv64] u-root: cannot locate module ${UROOT_REF} in cache"
    local tree="$OUT_DIR/riscv64/uroot-src"
    rm -rf "$tree"
    cp -a "$moddir" "$tree"
    chmod -R u+w "$tree"
    rm -rf "$tree/vendor"
    ( cd "$tree" && GOFLAGS=-mod=mod GOARCH=riscv64 GOOS=linux CGO_ENABLED=0 \
        go run . -o "$OUT_DIR/riscv64/initramfs.cpio" )
    [[ -s "$OUT_DIR/riscv64/initramfs.cpio" ]] || die "[riscv64] u-root produced no initramfs"
    log_info "[riscv64] u-root → out/riscv64/initramfs.cpio (plain cpio; go.sum-verified)"
}

# ════════════════════════════════════════════════════════════════════════════
# Pack — gen_init_cpio (kernel's own tool): no kernel-in-initramfs, /dev/console
# baked without root, uid/gid 0 for reproducibility (plan §5 option B).
# ════════════════════════════════════════════════════════════════════════════
build_gen_init_cpio() {                      # echoes path to the compiled tool
    local src="$1" bin="$OUT_DIR/_tools/gen_init_cpio"
    if [[ ! -x "$bin" ]]; then
        install -d "$OUT_DIR/_tools"
        require_cmd cc
        cc -O2 -o "$bin" "$src/usr/gen_init_cpio.c"
    fi
    echo "$bin"
}

stage_etc() {                                # echoes a staged /etc dir for the login setup
    local etc="$OUT_DIR/_etc"
    rm -rf "$etc"; install -d "$etc"
    # One root account.  passwd points login at /bin/sh; the real secret lives in
    # shadow (FEATURE_SHADOWPASSWDS=y).
    printf '%s:x:0:0:root:/root:/bin/sh\n' "$LAB_USER" > "$etc/passwd"
    printf '%s:x:0:\n'                      "$LAB_USER" > "$etc/group"
    # securetty: with FEATURE_SECURETTY=y, login refuses root on any line NOT
    # listed here.  Cover the consoles every arch might use.
    printf 'console\nttyS0\nttyAMA0\nhvc0\ntty1\n'   > "$etc/securetty"
    # shadow: derive the crypt() hash from the known lab password.  python3 is in
    # the builder image; a fixed salt keeps the artifact reproducible.
    require_cmd python3
    # NB: python's crypt module is deprecated in 3.11 and removed in 3.13; the
    # pinned bookworm image ships 3.11, so this is fine. -W ignore silences the
    # noise. If a newer image drops crypt, the $6$ guard below fails loudly.
    local hash
    hash="$(python3 -W ignore -c 'import crypt,sys; print(crypt.crypt(sys.argv[1], "$6$micr0lab$"))' "$LAB_PASSWORD")"
    [[ "$hash" == \$6\$* ]] || die "stage_etc: crypt() did not return a SHA-512 hash"
    printf '%s:%s:19000:0:99999:7:::\n' "$LAB_USER" "$hash" > "$etc/shadow"
    # /etc/issue — getty prints this BEFORE the login: prompt.  \s \r \m are getty
    # escapes (system / kernel release / machine).  Advertise the creds.
    cat > "$etc/issue" <<EOF
Welcome to micro-linux (\\s \\r \\m)

Throwaway OFFLINE lab VM.  Log in with:
    login:    $LAB_USER
    password: $LAB_PASSWORD

EOF
    echo "$etc"
}

emit_cpio_spec() {                           # stdout: gen_init_cpio spec
    local init="$1" tree="$2" etc="$3"
    cat <<EOF
dir /proc 0755 0 0
dir /sys 0755 0 0
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
dir /root 0700 0 0
dir /etc 0755 0 0
file /etc/passwd $etc/passwd 0644 0 0
file /etc/group $etc/group 0644 0 0
file /etc/shadow $etc/shadow 0600 0 0
file /etc/securetty $etc/securetty 0644 0 0
file /etc/issue $etc/issue 0644 0 0
file /init $init 0755 0 0
EOF
    # busybox _install tree → dir/slink/file lines, all uid/gid 0 (reproducible),
    # LC_ALL=C sorted for determinism.
    ( cd "$tree" && find . -mindepth 1 \( -type d -o -type l -o -type f \) -print0 \
        | LC_ALL=C sort -z \
        | while IFS= read -r -d '' p; do
              rel="/${p#./}"
              if   [[ -d "$p" ]]; then printf 'dir %s 0755 0 0\n'        "$rel"
              elif [[ -L "$p" ]]; then printf 'slink %s %s 0777 0 0\n'   "$rel" "$(readlink "$p")"
              else                     printf 'file %s %s 0755 0 0\n'    "$rel" "$tree/${p#./}"
              fi
          done )
    # The udhcpc lease handler, at the path BusyBox's udhcpc execs
    # (CONFIG_UDHCPC_DEFAULT_SCRIPT=/usr/share/udhcpc/default.script).  Harmless
    # when unused, so it ships in every initramfs; the network demo (§10) invokes
    # udhcpc from /init only when the `mllab.net` cmdline token is present.
    # Emitted AFTER the _install walk so /usr already exists (/usr/share is not
    # part of the busybox install tree).
    cat <<EOF
dir /usr/share 0755 0 0
dir /usr/share/udhcpc 0755 0 0
file /usr/share/udhcpc/default.script $SCRIPT_DIR/udhcpc.script 0755 0 0
EOF
}

pack_busybox() {
    local arch="$1" src="$2"
    local init="$SCRIPT_DIR/init"
    [[ -r "$init" ]] || die "missing $init (the /init script — plan §6.4)"
    [[ -d "$OUT_DIR/$arch/_install" ]] || die "[$arch] no _install — run 'mlbuild.sh build' first"
    local gic; gic="$(build_gen_init_cpio "$src")"
    log_info "[$arch] packing initramfs (gen_init_cpio: kernel not embedded, /dev/console baked) …"
    # gen_init_cpio reads the spec from a FILE argument; "-" selects stdin.
    # Omitting it makes the tool print usage + exit 1 (an empty archive) — caught
    # by pipefail, but pass "-" so the piped spec is actually consumed.
    # -t SOURCE_DATE_EPOCH: gen_init_cpio otherwise stamps every entry with the
    # wall-clock time (time(NULL)) — non-reproducible.  It doesn't read
    # SOURCE_DATE_EPOCH itself (the kernel's usr/Makefile passes -t for it), so we
    # pass it explicitly to pin all mtimes (plan §8).  gzip -n already drops the
    # gzip header's own name+timestamp.
    local img="$OUT_DIR/$arch/initramfs.cpio.gz"
    local etc; etc="$(stage_etc)"
    emit_cpio_spec "$init" "$OUT_DIR/$arch/_install" "$etc" \
        | "$gic" -t "${SOURCE_DATE_EPOCH:-1700000000}" - \
        | gzip -9 -n > "$img"
    # A near-empty archive (e.g. a pack mishap) kernel-panics at boot rather than
    # failing here, so assert the essentials are actually inside.
    require_cmd cpio
    local entries; entries="$(gzip -dc "$img" | cpio -t 2>/dev/null)"
    grep -qE '(^|/)init$'        <<<"$entries" || die "[$arch] initramfs has no /init — pack failed"
    grep -qE '(^|/)bin/busybox$' <<<"$entries" || die "[$arch] initramfs has no /bin/busybox — pack failed"
    grep -qE '(^|/)etc/passwd$'  <<<"$entries" || die "[$arch] initramfs has no /etc/passwd — login would fail"
    log_info "[$arch] initramfs → out/$arch/initramfs.cpio.gz ($(gzip -dc "$img" | cpio -t 2>/dev/null | wc -l) entries)"
}

# ════════════════════════════════════════════════════════════════════════════
# Inner entrypoints (run inside the container; MLBUILD_IN_CONTAINER=1)
# ════════════════════════════════════════════════════════════════════════════
inner_build() {
    load_versions
    export_repro_env
    install -d "$OUT_DIR" "$CACHE_DIR"
    local arch
    for arch in "${ARCHES[@]}"; do
        install -d "$OUT_DIR/$arch"
        if [[ "$arch" == riscv64 ]]; then
            build_kernel riscv64 "$(prepare_kernel riscv64)"
            build_uroot                                      # produces the initramfs directly
        else
            local ksrc bbsrc
            ksrc="$(prepare_kernel  "$arch")"
            bbsrc="$(prepare_busybox "$arch")"
            build_kernel  "$arch" "$ksrc"
            build_busybox "$arch" "$bbsrc"
            [[ -n "${OPT_MUSL:-}"  ]] && build_busybox_musl "$arch" "$bbsrc"
            [[ -n "${OPT_TINY:-}"  ]] && build_kernel_tiny  "$arch" "$ksrc"
        fi
    done
}

inner_pack() {
    load_versions
    export_repro_env
    local arch
    for arch in "${ARCHES[@]}"; do
        if [[ "$arch" == riscv64 ]]; then
            [[ -f "$OUT_DIR/riscv64/initramfs.cpio" ]] \
                && log_info "[riscv64] initramfs already produced by u-root (build step)" \
                || die "[riscv64] no initramfs — run 'mlbuild.sh build' first"
            continue
        fi
        local ksrc="$OUT_DIR/$arch/build/linux-${LINUX_VER}"
        pack_busybox        "$arch" "$ksrc"
        [[ -n "${OPT_MUSL:-}"  ]] && pack_busybox_musl  "$arch" "$ksrc"
        [[ -n "${OPT_BAKED:-}" ]] && pack_busybox_baked "$arch" "$ksrc"
    done
}

# ════════════════════════════════════════════════════════════════════════════
# Host orchestration
# ════════════════════════════════════════════════════════════════════════════
detect_engine() {
    if [[ -n "${ENGINE:-}" ]]; then
        command -v "$ENGINE" &>/dev/null || die "engine not found: $ENGINE"
        return
    fi
    if   command -v podman &>/dev/null; then ENGINE=podman
    elif command -v docker &>/dev/null; then ENGINE=docker
    else die "need podman or docker on PATH"; fi
}

build_image() {                              # (re)build unconditionally; layer cache makes a no-op fast
    log_info "building toolchain image $IMAGE …"
    local -a bargs=()
    [[ -n "${BASE_IMAGE:-}" ]] && bargs+=(--build-arg "BASE=$BASE_IMAGE")
    [[ -n "${GO_VER:-}"     ]] && bargs+=(--build-arg "GO_VER=$GO_VER")
    [[ -n "${GO_SHA256:-}"  ]] && bargs+=(--build-arg "GO_SHA256=$GO_SHA256")
    "$ENGINE" build -t "$IMAGE" "${bargs[@]}" "$SCRIPT_DIR"
}

ensure_image() {                             # auto path (build/pack/all): build only if absent
    "$ENGINE" image inspect "$IMAGE" &>/dev/null && return 0
    log_info "(first run) "
    build_image
}

run_in_builder() {
    load_versions          # so BASE_IMAGE is available to ensure_image
    ensure_image
    local -a mount envs
    if [[ "$ENGINE" == podman ]]; then
        mount=(-v "$REPO_ROOT:/work:Z" --userns=keep-id)        # keep-id → host artifacts owned by you
    else
        mount=(-v "$REPO_ROOT:/work" -u "$(id -u):$(id -g)")
    fi
    # Forward the knobs the in-container build reads (pack's stage_etc needs the
    # lab creds, so a host-side override actually reaches it).
    envs=(-e MLBUILD_IN_CONTAINER=1)
    [[ -n "${MLBUILD_OFFLINE:-}"      ]] && envs+=(-e "MLBUILD_OFFLINE=1")
    [[ -n "${MLBUILD_LAB_USER:-}"     ]] && envs+=(-e "MLBUILD_LAB_USER=${MLBUILD_LAB_USER}")
    [[ -n "${MLBUILD_LAB_PASSWORD:-}" ]] && envs+=(-e "MLBUILD_LAB_PASSWORD=${MLBUILD_LAB_PASSWORD}")
    # Forward variant flags so inner_build/inner_pack see them.
    [[ -n "${OPT_MUSL:-}"    ]] && envs+=(-e "OPT_MUSL=1")
    [[ -n "${OPT_TINY:-}"    ]] && envs+=(-e "OPT_TINY=1")
    [[ -n "${OPT_BAKED:-}"   ]] && envs+=(-e "OPT_BAKED=1")
    [[ -n "${OPT_COMPARE:-}" ]] && envs+=(-e "OPT_COMPARE=1")
    "$ENGINE" run --rm "${mount[@]}" -w /work/micro-linux \
        "${envs[@]}" \
        "$IMAGE" bash mlbuild.sh "$@"
}

# F7: refuse any rm -rf that isn't squarely inside out/.
safe_rm() {
    local p="$1" real
    real="$(realpath -m -- "$p")"
    [[ -n "$real"               ]] || die "refusing rm: empty path"
    [[ "$real" != "/"           ]] || die "refusing rm: /"
    [[ "$real" != "$HOME"       ]] || die "refusing rm: \$HOME"
    [[ "$real" != "$REPO_ROOT"  ]] || die "refusing rm: repo root"
    [[ "$real" != "$SCRIPT_DIR" ]] || die "refusing rm: micro-linux/ itself"
    [[ "$real" == "$OUT_DIR" || "$real" == "$OUT_DIR"/* ]] \
        || die "refusing rm outside out/: $real"
    [[ ! -L "$p" ]] || die "refusing rm: $p is a symlink"
    log_info "rm -rf $real"
    rm -rf -- "$real"
}

cmd_clean() {
    if [[ "${CLEAN_ALL:-}" == 1 ]]; then
        [[ -e "$OUT_DIR" ]] && safe_rm "$OUT_DIR" || log_info "nothing to clean ($OUT_DIR absent)"
        return 0
    fi
    local arch
    for arch in "${ARCHES[@]}"; do
        [[ -e "$OUT_DIR/$arch" ]] && safe_rm "$OUT_DIR/$arch" || log_info "[$arch] nothing to clean"
    done
}

summarize() {
    log_info "artifacts in $OUT_DIR:"
    local arch f
    for arch in "${ARCHES[@]}"; do
        for f in kernel kernel-tiny kernel-baked initramfs.cpio.gz initramfs-musl.cpio.gz initramfs.cpio; do
            if [[ -f "$OUT_DIR/$arch/$f" ]]; then
                log_info "  $arch/$f  ($(du -h "$OUT_DIR/$arch/$f" | cut -f1))"
            fi
        done
    done
    print_hashes
    [[ -n "${OPT_COMPARE:-}" ]] && compare_sizes
}

# Print sha256 of each built artifact — for reproducible-build attestation
# (plan §8 / REPRODUCIBLE.md).  Two independent builders, same pinned source +
# digest-pinned toolchain, must get matching hashes here.
print_hashes() {
    require_cmd sha256sum
    local arch f hdr=0
    for arch in "${ARCHES[@]}"; do
        for f in kernel kernel-tiny kernel-baked initramfs.cpio.gz initramfs-musl.cpio.gz initramfs.cpio; do
            [[ -f "$OUT_DIR/$arch/$f" ]] || continue
            if [[ "$hdr" == 0 ]]; then
                log_info "artifact sha256 (compare across independent builds — plan §8):"
                hdr=1
            fi
            printf '  %s  %s/%s\n' \
                "$(sha256sum "$OUT_DIR/$arch/$f" | cut -d' ' -f1)" "$arch" "$f" >&2
        done
    done
    [[ "$hdr" == 1 ]] || log_warn "no artifacts to hash — run 'mlbuild.sh all' first"
}

# ─── Arg parsing + dispatch ───────────────────────────────────────────────────
parse_arches() {
    IFS=',' read -r -a ARCHES <<< "${ARCHES_RAW:-x86_64,aarch64}"
    local a
    for a in "${ARCHES[@]}"; do
        case "$a" in x86_64|aarch64|riscv64|ppc64le|s390x) ;; *) die "unknown arch: $a (try --help)";; esac
    done
}

main() {
    [[ $# -gt 0 ]] || usage
    case "$1" in --help|-h) usage ;; esac
    local subcmd="$1"; shift
    ARCHES_RAW="x86_64,aarch64"
    OPT_MUSL="" OPT_TINY="" OPT_BAKED="" OPT_COMPARE=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --arch)         shift; ARCHES_RAW="${1:?--arch needs a comma list}"; shift ;;
            --engine)       shift; ENGINE="${1:?--engine needs podman|docker}";  shift ;;
            --offline)      MLBUILD_OFFLINE=1; shift ;;
            --all)          CLEAN_ALL=1; shift ;;
            --musl)         OPT_MUSL=1; shift ;;
            --tiny)         OPT_TINY=1; shift ;;
            --baked)        OPT_BAKED=1; shift ;;
            --compare)      OPT_COMPARE=1; shift ;;
            --all-variants) OPT_MUSL=1; OPT_TINY=1; OPT_BAKED=1; OPT_COMPARE=1; shift ;;
            --help|-h) usage ;;
            *) die "unknown option: $1 (try --help)" ;;
        esac
    done
    parse_arches

    case "$subcmd" in
        image)
            detect_engine; load_versions; build_image ;;
        build|pack|all)
            if [[ -n "${MLBUILD_IN_CONTAINER:-}" ]]; then
                case "$subcmd" in
                    build) inner_build ;;
                    pack)  inner_pack ;;
                    all)   inner_build; inner_pack ;;
                esac
            else
                detect_engine
                run_in_builder "$subcmd" --arch "$ARCHES_RAW"
                summarize
                log_info "next: phase2-qemu-vm/lab-vm.sh create --config examples/micro-linux-<arch>.toml"
            fi ;;
        hashes) print_hashes ;;
        clean) cmd_clean ;;
        *) die "unknown subcommand: $subcmd (try --help)" ;;
    esac
}

# Run only when executed directly; allow `source mlbuild.sh` from unit tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

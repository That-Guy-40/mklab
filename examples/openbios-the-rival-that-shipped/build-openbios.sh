#!/usr/bin/env bash
# build-openbios.sh [x86|ppc|unix|all] — build OpenBIOS (the *other* IEEE 1275)
# in a container, with the lab's revival patch applied.
#
#   x86   → obj-x86/openbios.multiboot + openbios-x86.dict  (QEMU -kernel track;
#           the ARCH dict, which is openbios.dict PLUS arch/x86/init.fs)
#           obj-x86/openbios-builtin.elf                 (coreboot payload track)
#   ppc   → obj-ppc/openbios-qemu.elf                    (swap-in for qemu-system-ppc)
#   unix  → obj-amd64/openbios-unix + .dict              (the firmware as a host process)
#   all   → all three                                    [default]
#
# State lives in ${OPENBIOS_WORKDIR:-$HOME/openbios-lab}: clones of
# github.com/openbios/openbios and github.com/openbios/fcode-utils (toke is a
# hard build prereq — built from source in the image, no prebuilt pulls).
#
# patches/01-x86-revival.patch is applied to the openbios clone first: eight
# small fixes that resurrect the never-finished x86 paths (multiboot header,
# dictionary-module loading, load-base, grubfs seek/tell, boot→linux_load,
# ctx->esp, modern zero page, coreboot forwarding tables) plus auto-boot?=false
# on x86 (the unconditional auto-boot detonates when IDE media is attached).
# Each fix's story: POC-2/POC-4. Idempotent: skipped when already applied.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
IMG=localhost/openbios-build
TARGET="${1:-all}"

mkdir -p "$WORKDIR"
[[ -d "$WORKDIR/openbios/.git" ]] || \
    git clone https://github.com/openbios/openbios.git "$WORKDIR/openbios"
[[ -d "$WORKDIR/fcode-utils/.git" ]] || \
    git clone https://github.com/openbios/fcode-utils.git "$WORKDIR/fcode-utils"

echo "==> applying the revival patch (idempotent)"
# THE "ALREADY APPLIED?" TEST ASKS FOR THE CAUSE, NOT FOR THE DIFF.
#
# It used to ask `git apply --reverse --check`, i.e. *"is exactly this diff
# present"* -- and that broke the day a LATER patch edited a region patch 01
# had touched (Spike 1 added an amd64 arm to the same `auto-boot?` block in
# forth/admin/nvram.fs). Patch 01 was still fully in effect; the reverse check
# said the tree had diverged and the build refused to run. A patch is a diff,
# which is a cache of a state; the state is what matters. Exactly the lesson
# the nvram smoke track already carries.
#
# So: one marker per file the patch touches -- a string it ADDS that nothing
# since has had a reason to remove. All eight present = applied. None present =
# apply it. A MIXTURE is the interesting case and it stops the build by name,
# because a half-applied tree is the one that builds and then misbehaves.
REVIVAL_MARKERS=(
    "arch/x86/boot.c:[x86] Booting file"
    "arch/x86/builtin.c:#define DICTIONARY_SIZE (1024 * 1024 / sizeof(ucell))"
    "arch/x86/linux_load.c:kernel_info_offset"
    "arch/x86/multiboot.h:#define MULTIBOOT_HEADER_FLAGS		0x00000003"
    "arch/x86/openbios.c:load_dictionary((char *)sys_info.dict_start"
    'forth/admin/nvram.fs:s" load-base"'
    "fs/grubfs/grubfs_fs.c:grubfs_files_tell"
    "libopenbios/linuxbios_info.c:forward_lb_table"
)
present=(); absent=()
for m in "${REVIVAL_MARKERS[@]}"; do
    f="${m%%:*}"; pat="${m#*:}"
    if grep -qF -- "$pat" "$WORKDIR/openbios/$f" 2>/dev/null; then
        present+=("$f")
    else
        absent+=("$f")
    fi
done
if [[ ${#absent[@]} -eq 0 ]]; then
    echo "    already applied (all ${#present[@]} markers present)"
elif [[ ${#present[@]} -eq 0 ]]; then
    if git -C "$WORKDIR/openbios" apply "$HERE/patches/01-x86-revival.patch"; then
        echo "    applied"
    else
        echo "ERROR: no revival marker is present and the patch does not apply —" >&2
        echo "       upstream moved. Inspect $WORKDIR/openbios against" >&2
        echo "       patches/01-x86-revival.patch." >&2
        exit 1
    fi
else
    echo "ERROR: the revival patch is HALF applied — ${#present[@]} of ${#REVIVAL_MARKERS[@]} markers present." >&2
    printf '       missing: %s\n' "${absent[@]}" >&2
    echo "       A partly-revived tree builds and then fails somewhere else." >&2
    exit 1
fi

echo "==> building the build-box image ($IMG)"
# Context = WORKDIR so the Containerfile can COPY the fcode-utils clone.
podman build -q -t openbios-build -f "$HERE/Containerfile" "$WORKDIR" >/dev/null

obuild() { # obuild <switch-arch target...>
    podman run --rm -v "$WORKDIR/openbios:/src" --userns=keep-id -w /src \
        "$IMG" sh -c "config/scripts/switch-arch $* && make"
}

case "$TARGET" in
  x86)  obuild x86 ;;
  ppc)  obuild qemu-ppc ;;
  unix) obuild unix-amd64 ;;
  amd64) obuild amd64 ;;      # Spike 1: the BARE-METAL 64-bit target, not unix-amd64
  all)  obuild x86; obuild qemu-ppc; obuild unix-amd64; obuild amd64 ;;
  *) echo "usage: $0 [x86|ppc|unix|amd64|all]" >&2; exit 1 ;;
esac

echo "==> artifacts:"
ls -1 "$WORKDIR"/openbios/obj-amd64/openbios.multiboot32 \
      "$WORKDIR"/openbios/obj-amd64/openbios-amd64.dict \
      "$WORKDIR"/openbios/obj-x86/openbios.multiboot \
      "$WORKDIR"/openbios/obj-x86/openbios-x86.dict \
      "$WORKDIR"/openbios/obj-x86/openbios-builtin.elf \
      "$WORKDIR"/openbios/obj-ppc/openbios-qemu.elf \
      "$WORKDIR"/openbios/obj-amd64/openbios-unix 2>/dev/null || true

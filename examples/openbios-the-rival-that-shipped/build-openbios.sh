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
# patches/TESTED-TREE.patch is applied to the openbios clone first: the whole
# of this lab's divergence from the pinned upstream commit, in one generated
# diff -- the x86 revival (multiboot header, dictionary-module loading,
# load-base, grubfs seek/tell, boot→linux_load, ctx->esp, modern zero page,
# coreboot forwarding tables, auto-boot?=false), the amd64 port, and the
# 2026-08 fixes. Idempotent: skipped when already applied.
#
# patches/NN-*.patch are the RECORD -- one annotated diff per change, for
# reading. They are NOT applied, and they are not a linear series; see the long
# comment above TESTED_TREE_MARKERS for the measurement that settled it.
set -euo pipefail
usage() {
    cat <<'USAGE'
build-openbios.sh [TARGET]      clone + patch + container-build OpenBIOS

TARGET:
  x86      32-bit PC firmware: openbios.multiboot + openbios-x86.dict
  amd64    the 64-bit port (Spikes 0-3): openbios.multiboot + openbios-amd64.dict
  ppc      openbios-qemu.elf, for the -bios swap-in track
  unix     openbios-unix, the firmware as an ordinary host process
  all      x86 + ppc + unix (the default; amd64 is opt-in, it is a separate port)

patches/TESTED-TREE.patch (the full divergence from the pinned commit) is
applied by MARKER, not by `git apply --check`, so a rerun after unrelated edits
to the same regions still says "already applied" instead of refusing to build.
A partial application is an error naming the missing files -- including the
case where the x86 revival is present and the amd64 port is absent, which is
what a clean checkout silently produced until 2026-08-27.

Env: OPENBIOS_WORKDIR   (default ~/openbios-lab)
     OPENBIOS_ARCHIVE=1 snapshot the patched tree after a successful build,
                        via tools/openbios-archive-tree.sh. Content-addressed
                        and deduplicating, so it is free when nothing changed.
USAGE
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
IMG=localhost/openbios-build
TARGET="${1:-all}"

# THE CLONE IS PINNED, and patches/TESTED-TREE.patch is a diff against these
# two commits. Unpinned, this script tracked upstream HEAD: two people running it a
# month apart built different firmware from the same repo, every `Arch-tested:`
# line named a tree that no longer existed, and any CI job would have gone red
# on somebody else's commit rather than on a change in this lab.
#
# A TAG WOULD NOT DO. A version string is not an identity — a tag can be moved,
# and the whole point is that the bytes the patches were written against are the
# bytes that get built. These are commit SHAs.
#
# TO MOVE THE PIN: bump the SHA, run ./smoke-openbios.sh for every track, and
# expect every patch to need re-reading rather than assuming they still
# apply. `tools/openbios-pin-check.sh` reports when upstream has moved past it,
# so the bump is a decision someone makes and not a surprise mid-build.
# Regenerate TESTED-TREE.patch from the re-based tree; do not hand-edit it.
OPENBIOS_PIN=e5ac46dd24e6216c36aa80462af25457e7029440
FCODE_UTILS_PIN=6e563ee54aa9f60e538d90eedaa012ae77610344

mkdir -p "$WORKDIR"

# checkout_pinned <dir> <url> <sha>
#
# Fetches the exact object when the clone is missing it, then checks it out
# DETACHED. The `rev-parse HEAD` gate is what makes a rerun cheap and a drifted
# tree loud: a working copy already at the pin is left completely alone, so
# uncommitted local work — which is how this lab develops the divergence before
# a patch is extracted — is never touched.
checkout_pinned() {
    local dir="$1" url="$2" sha="$3" name; name="$(basename "$dir")"
    if [[ ! -d "$dir/.git" ]]; then
        git clone "$url" "$dir"
    fi
    local at; at="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo none)"
    if [[ "$at" == "$sha" ]]; then
        echo "==> $name pinned at ${sha:0:7} (already there)"
        return 0
    fi
    if ! git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null; then
        echo "==> $name: fetching pinned ${sha:0:7}"
        git -C "$dir" fetch --quiet origin "$sha" 2>/dev/null || git -C "$dir" fetch --quiet origin
    fi
    if ! git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null; then
        echo "ERROR: $name has no commit $sha — the pin names an object this" >&2
        echo "       remote does not carry. Upstream rewrote history, or the" >&2
        echo "       SHA is wrong. Do not build against whatever HEAD is." >&2
        exit 1
    fi
    # A dirty tree is the lab mid-divergence; moving HEAD under it would discard
    # exactly the work the next patch is extracted from.
    if [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
        echo "ERROR: $name is at ${at:0:7}, the pin is ${sha:0:7}, and the tree" >&2
        echo "       has uncommitted changes. Refusing to move HEAD under them." >&2
        echo "       Stash or commit in $dir, then rerun." >&2
        exit 1
    fi
    echo "==> $name: checking out pinned ${sha:0:7} (was ${at:0:7})"
    git -C "$dir" -c advice.detachedHead=false checkout --quiet "$sha"
}

checkout_pinned "$WORKDIR/openbios"     https://github.com/openbios/openbios.git     "$OPENBIOS_PIN"
checkout_pinned "$WORKDIR/fcode-utils"  https://github.com/openbios/fcode-utils.git  "$FCODE_UTILS_PIN"

echo "==> applying the lab's divergence (idempotent)"
# THE PATCH THAT IS APPLIED IS NOT ONE OF THE NUMBERED ONES.
#
# patches/NN-*.patch are the RECORD: 34 annotated diffs, one per change, each
# written so a reader can follow one fix at a time. They are not a linear
# series and never were. Every one of them was extracted as a diff against a
# tree that ALREADY had the others applied, so its context lines describe the
# finished tree rather than the tree as it stood at that step.
#
# Measured 2026-08-27, because "apply them in order" was the obvious fix and it
# does not work: applying 01..34 to a pristine pin lands 19 of 34, and `git
# apply -3` lands the same 19 -- a merge strategy cannot recover context that
# was never written. Reverse-walking from the finished tree reverses 23 of 34
# before the early ones stop. The intermediate trees that would make the series
# linear do not exist anywhere any more.
#
# So what gets applied is patches/TESTED-TREE.patch: the CUMULATIVE divergence
# from OPENBIOS_PIN to the tree every smoke track has actually been run
# against. It is generated (`git diff` at the pin) rather than written, and it
# is verified by reproducing that tree -- 722 of 722 source files identical by
# sha256, the sole difference being config-host.mak, which switch-arch
# generates. tools/check-patch-hygiene.sh binds the record to it, so a change
# recorded in a numbered patch but missing from what is built is a failure.
#
# HOW THE GAP WAS FOUND. Until today this script applied 01-x86-revival.patch
# and nothing else -- 1 of 34. A clean checkout therefore built the x86 revival
# and NO amd64 port at all: patch 02 is what adds
# <executable name="openbios.multiboot"> to arch/amd64/build.xml, so the file
# every amd64 track boots was never produced. Meanwhile smoke-openbios.sh
# asserts amd64 behaviour in 21 tracks. Every working copy here had been
# patched by hand since the day it was made, so the cold path had no exercise
# and three green CI runs said nothing about it. Tier B's first cold build is
# what found it, on the first run that ever started from nothing.

# THE "ALREADY APPLIED?" TEST ASKS FOR THE CAUSE, NOT FOR THE DIFF.
#
# Not `git apply --reverse --check`, which asks *"is exactly this diff
# present"*. This tree is where the lab DEVELOPS the next change, so it is
# routinely the patch plus uncommitted work; a reverse check calls that
# "diverged" and refuses to build the thing the developer is mid-way through.
# A patch is a diff, which is a cache of a state; the state is what matters.
#
# So: one marker per area of the divergence -- a string it ADDS that nothing
# since has had a reason to remove, and that is ABSENT from the pinned upstream
# file (tools/check-patch-hygiene.sh A3b re-derives that against the real
# upstream blob rather than trusting this list). All present = applied. None =
# apply it. A MIXTURE stops the build BY NAME, because a half-applied tree is
# the one that builds and then misbehaves somewhere else entirely.
#
# The list spans all three eras of the divergence on purpose -- the x86
# revival, the amd64 port, and the 2026-08 fixes -- so that the failure Tier B
# found (x86 present, amd64 entirely absent) reads as a MIXTURE and stops here,
# instead of building an amd64 target that silently has no multiboot image.
TESTED_TREE_MARKERS=(
    # -- the x86 revival (patch 01) --
    "arch/x86/openbios.c:load_dictionary((char *)sys_info.dict_start"
    "fs/grubfs/grubfs_fs.c:grubfs_files_tell"
    "libopenbios/linuxbios_info.c:forward_lb_table"
    # NOT `s" load-base"`: that string is in the PRISTINE nvram.fs three times
    # already (the ppc, sparc32 and sparc64 arms), so it matched an unpatched
    # tree and reported "1 of 8 markers present -- HALF applied" on every cold
    # clone. A marker's whole semantics are "present => applied", so a string
    # the patch adds is not enough; it must be one that did not exist before.
    "forth/admin/nvram.fs:Every other arch defines load-base"
    # -- the amd64 port (patches 02+) --
    # THIS is the marker whose absence was the bug: without patch 02 there is no
    # openbios.multiboot rule for amd64 at all, and the gate downstream fails on
    # a missing file with nothing explaining why.
    "arch/amd64/build.xml:openbios.multiboot"
    "arch/amd64/exception.c:exception"
    # -- the 2026-08 fixes (patches 20-34) --
    'arch/x86/context.c:feval("fcode"); t_fcode = POP();'
    "forth/device/property.fs:l-fits?"
    'drivers/pci.c:set_int_property(phandle, "#address-cells", 3);'
    "libopenbios/init.c:eword_report_selftest"
    "config/scripts/switch-arch:TODO 13.3(C): -fno-builtin, not the two"
    # -- TODO 17.1: two address cells on the amd64 root (patches 42-43) --
    # Both are in files the patch already touched for other reasons, so neither
    # is a NEW file: A3b will fetch them at the pin and require these strings to
    # be absent there, which is the check that caught the `s" load-base"` marker.
    "drivers/ide.c:ide_node_parent"
    "arch/amd64/init.fs:TODO 17.1: TWO ADDRESS CELLS"
    # -- TODO 17.3: /memory's available, and the claim it describes (44-45) --
    "arch/amd64/openbios.c:ciface_claim_amd64"
    "libopenbios/init.c:publish_memory_available"
    # -- TODO 17.4: number() agrees with C99 (patch 46) --
    "libc/vsprintf.c:unsigned long long unum;"
    # -- TODO 17.5: reproducible on request (patch 47) --
    "Makefile.target:BUILD_DATE := "
)
present=(); absent=()
for m in "${TESTED_TREE_MARKERS[@]}"; do
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
    if git -C "$WORKDIR/openbios" apply "$HERE/patches/TESTED-TREE.patch"; then
        echo "    applied patches/TESTED-TREE.patch ($(grep -c '^+++ b/' "$HERE/patches/TESTED-TREE.patch") files)"
    else
        echo "ERROR: no marker is present and patches/TESTED-TREE.patch does not" >&2
        echo "       apply. The clone is not at the pin, or upstream rewrote it." >&2
        echo "       Inspect $WORKDIR/openbios against" >&2
        echo "       patches/TESTED-TREE.patch." >&2
        exit 1
    fi
else
    echo "ERROR: the divergence is HALF applied -- ${#present[@]} of ${#TESTED_TREE_MARKERS[@]} markers present." >&2
    printf '       missing: %s\n' "${absent[@]}" >&2
    echo "       A partly-patched tree builds and then fails somewhere else." >&2
    echo "       This is the shape Tier B found: an x86 revival with no amd64" >&2
    echo "       port behind it, which builds fine and produces no multiboot." >&2
    exit 1
fi

echo "==> building the build-box image ($IMG)"
# Context = WORKDIR so the Containerfile can COPY the fcode-utils clone.
podman build -q -t openbios-build -f "$HERE/Containerfile" "$WORKDIR" >/dev/null

obuild() { # obuild <switch-arch target...>
    # TODO 17.5: SOURCE_DATE_EPOCH is forwarded when the caller set it, and
    # NOT invented when they did not. Setting it here unconditionally would
    # make every build reproducible and, in the same move, delete the ppc
    # track's identity check -- it proves the running firmware is OURS by
    # comparing the build-date banner against the distro blob's, and two blobs
    # stamped from a constant would compare equal.
    local envargs=()
    [[ -n "${SOURCE_DATE_EPOCH:-}" ]] && envargs+=(-e "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH")
    podman run --rm -v "$WORKDIR/openbios:/src" --userns=keep-id -w /src \
        "${envargs[@]}" "$IMG" sh -c "config/scripts/switch-arch $* && make"
}

case "$TARGET" in
  x86)  obuild x86 ;;
  ppc)  obuild qemu-ppc ;;
  unix) obuild unix-amd64 ;;
  amd64) obuild amd64 ;;      # Spike 1: the BARE-METAL 64-bit target, not unix-amd64
  all)  obuild x86; obuild qemu-ppc; obuild unix-amd64; obuild amd64 ;;
  *) echo "usage: $0 [x86|ppc|unix|amd64|all]" >&2; exit 1 ;;
esac

# OPTIONAL, OPT-IN, AND LOUD IF IT FAILS. Set OPENBIOS_ARCHIVE=1 to snapshot the
# patched tree after a successful build. It is content-addressed and deduplicates,
# so running it on every build costs nothing while the tree is unchanged -- which
# is what makes it safe to leave switched on.
#
# It fails the build if it fails. A build that says it archived and did not is a
# false success, and this repo's rule is that a false success outranks an honest
# failure: you cannot debug through a lying oracle.
if [[ "${OPENBIOS_ARCHIVE:-0}" == 1 ]]; then
    echo "==> archiving the patched tree (OPENBIOS_ARCHIVE=1)"
    "$HERE/../../tools/openbios-archive-tree.sh" --workdir "$WORKDIR/openbios"
fi

echo "==> artifacts:"
ls -1 "$WORKDIR"/openbios/obj-amd64/openbios.multiboot32 \
      "$WORKDIR"/openbios/obj-amd64/openbios-amd64.dict \
      "$WORKDIR"/openbios/obj-x86/openbios.multiboot \
      "$WORKDIR"/openbios/obj-x86/openbios-x86.dict \
      "$WORKDIR"/openbios/obj-x86/openbios-builtin.elf \
      "$WORKDIR"/openbios/obj-ppc/openbios-qemu.elf \
      "$WORKDIR"/openbios/obj-amd64/openbios-unix 2>/dev/null || true

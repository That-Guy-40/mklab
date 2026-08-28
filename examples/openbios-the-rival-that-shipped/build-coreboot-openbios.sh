#!/usr/bin/env bash
# build-coreboot-openbios.sh — coreboot ROM carrying openbios-builtin.elf as
# its payload (OpenBIOS's birthplace: it began life as a LinuxBIOS payload).
#
# Reuses the linuxboot lab's cached coreboot tree + crossgcc with FULL
# isolation: our config/objdir are .config-openbios + build-openbios/, so the
# kept artifacts of BOTH sibling labs survive untouched:
#   linuxboot: .config + build/coreboot.rom
#   OFW lab:   .config-ofw + build-ofw/coreboot.rom
# A sha guard proves it (written on first run, checked on every run).
set -euo pipefail

# THIS SCRIPT USED TO START A COREBOOT BUILD WHEN ASKED FOR HELP. It takes no
# arguments, so `--help` fell straight through to the build -- exiting 0 after
# several minutes of make, having written cmocka warnings to stderr. That is a
# worse shape than the four flavor scripts here, which at least refused: asking
# a tool to describe itself should never be the thing that does the work.
#
# The delimiter is QUOTED, so nothing in the text below can execute. See
# tools/check-usage-is-data.sh -- an unquoted one makes help text a program.
usage() {
    cat <<'USAGE'
build-coreboot-openbios.sh [ARCH]   a coreboot ROM carrying openbios-builtin.elf

ARCH:
  x86      32-bit payload, obj-x86/openbios-builtin.elf   (the default)
  amd64    64-bit firmware entered 32-bit, obj-amd64/openbios-builtin.elf32

OpenBIOS began life as a LinuxBIOS payload, and this builds
it back into that shape: coreboot with CONFIG_PAYLOAD_ELF pointing at our own
openbios-builtin.elf, bootable with `qemu -bios`.

Reuses the linuxboot lab's cached coreboot tree and crossgcc with FULL
isolation -- our config and objdir are .config-openbios and build-openbios/ --
so the kept ROMs of both sibling labs survive untouched:
  linuxboot: .config      + build/coreboot.rom
  OFW lab:   .config-ofw  + build-ofw/coreboot.rom
A sha guard proves it: written on first run, checked on every run after.

Run ./build-openbios.sh x86 first -- the payload has to exist.
Then: ./smoke-openbios.sh coreboot  and  ./showcase-rival-boots-linux.sh coreboot

Env: OPENBIOS_WORKDIR (default ~/openbios-lab), COREBOOT_DIR
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
CB="${COREBOOT_DIR:-$HOME/linuxboot-lab/coreboot}"
ARCH="${1:-x86}"

# TWO ARCHES, TWO OUTPUT TREES, and nothing shared but the coreboot checkout.
# The amd64 payload is the ELF32 produced by the objcopy in arch/amd64/build.xml:
# coreboot enters a payload in 32-bit protected mode, and the firmware goes long
# mode itself. Each arch gets its own DOTCONFIG, its own obj= dir and its own
# guard file, so building one cannot quietly replace the other's ROM -- which is
# the same clobbering question the guard below has always been about, one arch wider.
case "$ARCH" in
  x86)   PAYLOAD="$WORKDIR/openbios/obj-x86/openbios-builtin.elf"
         OBJDIR=build-openbios;       DOTCONFIG=.config-openbios ;;
  amd64) PAYLOAD="$WORKDIR/openbios/obj-amd64/openbios-builtin.elf32"
         OBJDIR=build-openbios-amd64; DOTCONFIG=.config-openbios-amd64 ;;
  *) echo "usage: $0 [x86|amd64]" >&2; exit 1 ;;
esac
GUARD="$WORKDIR/coreboot-guard-$ARCH.sha"

[[ -f "$PAYLOAD" ]] || { echo "no payload at $PAYLOAD — run ./build-openbios.sh $ARCH first" >&2; exit 1; }
[[ -d "$CB" ]] || { echo "no coreboot tree at $CB (set COREBOOT_DIR=; the linuxboot lab builds one)" >&2; exit 1; }

# Sha-guard the sibling labs' kept artifacts (only the ones that exist).
if [[ ! -f "$GUARD" ]]; then
    # A loop, not `ls … | xargs`: the four names are literals, so `ls` was only ever
    # answering "which of these exist" -- a question `[[ -f ]]` answers without handing
    # filenames through a pipe. Order is irrelevant to the `sha256sum -c` below.
    # `if`, NOT `[[ -f … ]] && sha256sum …`: this script runs under `set -e`, and a `&&`
    # whose left side is false on the LAST iteration makes the whole subshell exit 1 and
    # takes the build with it. An `if` with no `else` is 0 when its condition is false.
    # ONLY ARTIFACTS THIS LAB NEVER WRITES. The first version of the amd64 support
    # listed the OTHER arch's ROM here too, reasoning that it is a sibling artifact
    # -- but this lab OWNS both of those and rebuilds them on demand, while the
    # guard file is written ONCE and then cached. So rebuilding x86 left amd64's
    # guard describing a ROM that had legitimately changed, and the next amd64
    # build failed its own guard check. A cached expectation about a thing that is
    # supposed to change: bug class #1 in CLAUDE.md, committed while fixing bug
    # class #1. The two arches never needed the guard for isolation anyway --
    # separate DOTCONFIG and obj= dirs are what actually keep them apart.
    (cd "$CB" && for f in .config build/coreboot.rom .config-ofw build-ofw/coreboot.rom; do
        if [[ -f "$f" ]]; then sha256sum "$f"; fi
    done) > "$GUARD"
    echo "==> wrote guard $GUARD"
elif grep -q 'build-openbios' "$GUARD"; then
    # SELF-HEAL A GUARD WRITTEN BY THAT VERSION. It names ROMs this lab rebuilds, so
    # it fails the moment either arch is rebuilt -- and a guard nobody can satisfy
    # gets deleted by hand, after which nobody has one at all. Rewriting it keeps
    # the protection for the artifacts it is actually about, and says so out loud.
    echo "==> $GUARD named this lab's own ROMs (which it rebuilds) — rewriting it to cover only the sibling labs' artifacts"
    (cd "$CB" && for f in .config build/coreboot.rom .config-ofw build-ofw/coreboot.rom; do
        if [[ -f "$f" ]]; then sha256sum "$f"; fi
    done) > "$GUARD"
fi

echo "==> isolated config/build ($DOTCONFIG + $OBJDIR/) — sibling artifacts untouched"
cat > "$CB/$DOTCONFIG" <<EOF
CONFIG_VENDOR_EMULATION=y
CONFIG_BOARD_EMULATION_QEMU_X86_I440FX=y
CONFIG_COREBOOT_ROMSIZE_KB_4096=y
CONFIG_PAYLOAD_ELF=y
CONFIG_PAYLOAD_FILE="$PAYLOAD"
EOF
make -C "$CB" DOTCONFIG="$DOTCONFIG" obj="$OBJDIR" olddefconfig >/dev/null
make -C "$CB" DOTCONFIG="$DOTCONFIG" obj="$OBJDIR" -j"$(nproc)" \
    | tail -3

echo "==> guard check:"
(cd "$CB" && sha256sum -c "$GUARD")
# BIND THE ROM TO THE PAYLOAD THAT WENT INTO IT. The guard above protects the
# SIBLING labs' ROMs from being clobbered — a different question, and it was the
# only sha check here. Nothing recorded which openbios build is inside THIS ROM, so
# the smoke track booted it and reported on whatever firmware happened to be baked
# in months ago. coreboot transforms the ELF on the way in, so the pairing cannot be
# re-derived afterwards; it has to be recorded as it is made.
"$REPO/tools/openbios-rom-provenance.sh" --stamp "$CB/$OBJDIR/coreboot.rom" "$PAYLOAD"
echo "==> $CB/$OBJDIR/coreboot.rom"

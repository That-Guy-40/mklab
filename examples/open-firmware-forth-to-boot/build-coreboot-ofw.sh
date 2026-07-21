#!/usr/bin/env bash
# build-coreboot-ofw.sh — wrap ofwlb.elf into a coreboot ROM (i440fx board).
#
# Reuses an existing coreboot tree WITHOUT touching its default .config or
# build/ (isolated via DOTCONFIG= + obj=): the linuxboot lab's cached tree at
# ~/linuxboot-lab/coreboot — crossgcc already built — makes this a ~1-minute
# build. With no tree present, a fresh clone is made under the OFW workdir
# (first build then also compiles crossgcc-i386: ~15 min).
#
# Board = i440fx, NOT q35: OFW's device set is PIIX-era (its legacy IDE lives
# at the i440fx's port addresses). See POC-3-COREBOOT-PAYLOAD.md.
set -euo pipefail
WORKDIR="${OFW_WORKDIR:-$HOME/ofw-lab}"
CB="${COREBOOT_DIR:-$HOME/linuxboot-lab/coreboot}"
PAYLOAD="$WORKDIR/openfirmware/cpu/x86/pc/biosload/build/ofwlb.elf"
JOBS="$(nproc)"

[[ -f "$PAYLOAD" ]] || { echo "no $PAYLOAD — run ./build-ofw.sh coreboot first" >&2; exit 1; }

if [[ ! -d "$CB/.git" ]]; then
  CB="$WORKDIR/coreboot"
  echo "==> no coreboot tree found; cloning into $CB"
  [[ -d "$CB/.git" ]] || git clone --depth 1 https://github.com/coreboot/coreboot.git "$CB"
  git -C "$CB" submodule update --init --checkout 3rdparty/vboot 3rdparty/libgfxinit 2>/dev/null || true
fi
if [[ ! -x "$CB/util/crossgcc/xgcc/bin/i386-elf-gcc" ]]; then
  echo "==> building coreboot crossgcc-i386 (one-time, ~15 min)"
  make -C "$CB" crossgcc-i386 CPUS="$JOBS"
fi

echo "==> isolated config/build (.config-ofw + build-ofw/) — default .config and build/ untouched"
printf '%s\n' \
  'CONFIG_VENDOR_EMULATION=y' \
  'CONFIG_BOARD_EMULATION_QEMU_X86_I440FX=y' \
  'CONFIG_COREBOOT_ROMSIZE_KB_4096=y' \
  'CONFIG_PAYLOAD_ELF=y' \
  "CONFIG_PAYLOAD_FILE=\"$PAYLOAD\"" > "$CB/.config-ofw"
make -C "$CB" DOTCONFIG=.config-ofw obj=build-ofw olddefconfig >/dev/null
make -C "$CB" DOTCONFIG=.config-ofw obj=build-ofw -j"$JOBS" 2>&1 | tail -3
echo "==> $CB/build-ofw/coreboot.rom"
sha256sum "$CB/build-ofw/coreboot.rom"

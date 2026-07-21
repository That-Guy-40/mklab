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
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
CB="${COREBOOT_DIR:-$HOME/linuxboot-lab/coreboot}"
PAYLOAD="$WORKDIR/openbios/obj-x86/openbios-builtin.elf"
GUARD="$WORKDIR/coreboot-guard.sha"

[[ -f "$PAYLOAD" ]] || { echo "no payload at $PAYLOAD — run ./build-openbios.sh x86 first" >&2; exit 1; }
[[ -d "$CB" ]] || { echo "no coreboot tree at $CB (set COREBOOT_DIR=; the linuxboot lab builds one)" >&2; exit 1; }

# Sha-guard the sibling labs' kept artifacts (only the ones that exist).
if [[ ! -f "$GUARD" ]]; then
    (cd "$CB" && ls .config build/coreboot.rom .config-ofw build-ofw/coreboot.rom 2>/dev/null \
        | xargs -r sha256sum) > "$GUARD"
    echo "==> wrote guard $GUARD"
fi

echo "==> isolated config/build (.config-openbios + build-openbios/) — sibling artifacts untouched"
cat > "$CB/.config-openbios" <<EOF
CONFIG_VENDOR_EMULATION=y
CONFIG_BOARD_EMULATION_QEMU_X86_I440FX=y
CONFIG_COREBOOT_ROMSIZE_KB_4096=y
CONFIG_PAYLOAD_ELF=y
CONFIG_PAYLOAD_FILE="$PAYLOAD"
EOF
make -C "$CB" DOTCONFIG=.config-openbios obj=build-openbios olddefconfig >/dev/null
make -C "$CB" DOTCONFIG=.config-openbios obj=build-openbios -j"$(nproc)" \
    | tail -3

echo "==> guard check:"
(cd "$CB" && sha256sum -c "$GUARD")
echo "==> $CB/build-openbios/coreboot.rom"

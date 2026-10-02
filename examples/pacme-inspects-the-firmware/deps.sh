#!/usr/bin/env bash
# deps.sh — name and CHECK this lab's external dependencies, and print what is
# missing with the exact command to get it. It installs nothing that needs root
# (my shell cannot sudo) and builds nothing it has not verified: it reports
# readiness and hands you the recipes.
#
# Two tiers:
#   REQUIRED NOW (Spike 0 + Spike 1, the bridge foundation):
#     GNU poke (poke/poked/pe.pk) · qemu-system-x86_64 · qemu-nbd · libnbd · python3
#     + a built OpenBIOS x86 firmware.
#   NEEDED FROM SPIKE 3 (the acme UI — not built in PR1):
#     pacme (source build from sourceware) · tmux · Capstone (optional, plet-cpu-disasm).
#
# Exit: 0 if the REQUIRED tier is satisfied, 77 if something required is missing
# (so a harness can SKIP by name). The Spike-3 tier never fails this script.
set -u

ok() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
no() { printf '  \033[31mMISSING\033[0m %s\n' "$*"; MISS=1; }
note() { printf '       %s\n' "$*"; }
MISS=0

WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
FW="$WORKDIR/openbios/obj-x86/openbios.multiboot"

echo "== REQUIRED NOW — Spike 0 (bridge) + Spike 1 (seam) =="

if command -v poke >/dev/null; then ok "GNU poke — $(poke --version 2>&1 | head -1)"
else no "GNU poke — install:  sudo apt-get install -y poke   (brings poke, poked, pe.pk; needs root, so run it yourself)"; fi
command -v poked >/dev/null && ok "poked (the daemon, for the Spike-3 UI)" || note "poked absent (part of the poke package)"
[[ -f /usr/share/poke/pickles/pe.pk ]] && ok "pe.pk pickle (/usr/share/poke/pickles/pe.pk)" || note "pe.pk absent (part of the poke package)"

command -v qemu-system-x86_64 >/dev/null && ok "qemu-system-x86_64" || no "qemu-system-x86_64 — install qemu-system-x86"
command -v qemu-nbd >/dev/null && ok "qemu-nbd" || no "qemu-nbd — install qemu-utils"
if ldconfig -p 2>/dev/null | grep -q 'libnbd\.so'; then ok "libnbd (poke's NBD backend)"
else no "libnbd — install libnbd0 (poke's nbd:// backend needs it)"; fi
command -v python3 >/dev/null && ok "python3 (QMP client + the serial driver)" || no "python3"

if [[ -f "$FW" ]]; then ok "OpenBIOS x86 firmware ($FW)"
else no "OpenBIOS x86 firmware — build it:  (cd ../openbios-the-rival-that-shipped && ./build-openbios.sh x86)"; fi

echo
echo "== NEEDED FROM SPIKE 3 — the acme UI (NOT built or required in PR1) =="
command -v tmux >/dev/null && ok "tmux (pacme's screen manager)" || note "tmux absent — needed for the Spike-3 UI"
if command -v pacme >/dev/null || [[ -x "$(dirname "$0")/.pacme/bin/plet-repl" ]]; then
    ok "pacme present"
else
    note "pacme not built — it is unpackaged; when Spike 3 lands, build it from source (no sudo, into a lab-local prefix):"
    note "    git clone https://sourceware.org/git/pacme.git"
    note "    cd pacme && ./bootstrap && ./configure --prefix=\"\$PWD/../.pacme\" && make && make install"
    note "  (the pokelets talk to poked over a Unix socket; Spike 1's bridge is what they will inspect)"
fi
if ldconfig -p 2>/dev/null | grep -qi capstone; then ok "Capstone (optional — plet-cpu-disasm only)"
else note "Capstone absent — OPTIONAL, only plet-cpu-disasm needs it (sudo apt-get install -y libcapstone-dev); every other pokelet runs without it"; fi

echo
if [[ "$MISS" -eq 0 ]]; then
    echo "READY: the bridge foundation (Spike 0 + Spike 1) can run — ./bridge.sh and ./smoke-pacme-seam.sh"
    exit 0
else
    echo "NOT READY: install the MISSING required items above, then re-run ./deps.sh"
    exit 77
fi

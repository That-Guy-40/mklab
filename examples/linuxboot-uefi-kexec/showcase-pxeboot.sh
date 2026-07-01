#!/usr/bin/env bash
# showcase-pxeboot.sh — the whole PLAN-PXEBOOT P1 story, end to end, in one run.
#
# This is the "watch it all work" driver: it exercises EVERY piece the lab builds
# and narrates each stop, then network-installs one OS per requested family from
# the REAL coreboot ROM and prints a proof grid. It orchestrates the other scripts
# (it does not re-implement them):
#
#   serve-netboot.sh    -> the :8181 nginx netboot server (reuses the podman TOML)
#   fetch-netboot-os.sh -> stage Rocky/Kali installers + render boot-<os>.ipxe
#   run-coreboot-pxe.sh -> boot coreboot.rom, drive `pxeboot -file`, capture serial
#   drive-boot.py       -> type the pxeboot command at the u-root shell
#   coreboot.rom        -> built by build-coreboot.sh w/ coreboot-qemu-q35-pxeboot.config
#
# The chain each OS proves:
#   coreboot ROM -> Linux (kernel DHCP, ip=dhcp) -> u-root main -> pxeboot -file
#     -> fetch boot-<os>.ipxe (HTTP :8181) -> fetch kernel+initrd -> kexec
#     -> the OS installer runs its automated kickstart/preseed.
#
#   ./showcase-pxeboot.sh [os ...]        (default: alma rocky kali)
#   ./showcase-pxeboot.sh alma            (just the already-staged one — fastest)
#
# AlmaLinux needs no fetch (staged at ~/netboot). Rocky/Kali are staged on demand
# via fetch-netboot-os.sh (Rocky pulls a ~1.2 GB stage2 the first time).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
ROM="${ROM:-$WORKDIR/coreboot/build/coreboot.rom}"
NETBOOT_DIR="${NETBOOT_DIR:-$HOME/netboot}"
OSES=("$@"); [[ ${#OSES[@]} -eq 0 ]] && OSES=(alma rocky kali)

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
rule() { printf '%s\n' "────────────────────────────────────────────────────────────────────"; }
step() { echo; rule; bold "▶ $*"; rule; }

# ── Stage 0: the ROM (built offline; we don't rebuild a 16 MB ROM in a demo) ──
step "Stage 0 — the coreboot ROM (firmware with a LinuxBoot payload)"
if [[ ! -f "$ROM" ]]; then
  echo "  ✗ no ROM at $ROM"
  echo "    Build it once (author-run, ~20 min):"
  echo "      ./fetch-go.sh"
  echo "      CBCONFIG=coreboot-qemu-q35-pxeboot.config \\"
  echo "        UROOT_GOBIN=$WORKDIR/go1.25/bin ./build-coreboot.sh"
  exit 1
fi
# Ground-truth that it's the pxeboot ROM (u-root main + ip=dhcp), not the disk one.
CFG="$WORKDIR/coreboot/.config"
if grep -q 'CONFIG_LINUX_COMMAND_LINE=.*ip=dhcp' "$CFG" 2>/dev/null \
   && grep -q '^CONFIG_LINUXBOOT_UROOT_MAIN=y' "$CFG" 2>/dev/null; then
  echo "  ✓ $ROM ($(du -h "$ROM" | cut -f1)) — pxeboot config (u-root main + ip=dhcp)"
else
  echo "  ⚠ ROM present but .config isn't the pxeboot one (ip=dhcp / UROOT_MAIN)."
  echo "    Rebuild with CBCONFIG=coreboot-qemu-q35-pxeboot.config (see Stage 0 above)."
fi

# ── Stage 1: the netboot server (the HTTP source pxeboot fetches from) ──
step "Stage 1 — the :8181 netboot server (nginx, serves the big HTTP artifacts)"
"$HERE/serve-netboot.sh" up || { echo "  ✗ could not bring up :8181"; exit 1; }

# ── Stage 2: stage each OS installer + iPXE script ──
step "Stage 2 — stage the installers pxeboot will fetch (per OS family)"
need_fetch=()
for os in "${OSES[@]}"; do
  case "$os" in
    alma) [[ -f "$NETBOOT_DIR/boot-alma.ipxe" ]] && echo "  ✓ alma: boot-alma.ipxe present (pre-staged AlmaLinux 9)" \
            || { echo "  ✗ alma: boot-alma.ipxe missing (expected pre-staged)"; } ;;
    rocky) [[ -f "$NETBOOT_DIR/boot-rocky.ipxe" ]] && echo "  ✓ rocky: already staged" || need_fetch+=(rocky) ;;
    kali)  [[ -f "$NETBOOT_DIR/boot-kali.ipxe"  ]] && echo "  ✓ kali: already staged"  || need_fetch+=(kali) ;;
    *) echo "  ? unknown os '$os' (known: alma rocky kali)"; ;;
  esac
done
for os in "${need_fetch[@]:-}"; do
  [[ -z "$os" ]] && continue
  echo "  → staging $os (fetch-netboot-os.sh $os) …"
  "$HERE/fetch-netboot-os.sh" "$os" || { echo "  ✗ fetch $os failed"; exit 1; }
done

# ── Stage 3: boot the ROM once per OS; capture the serial ──
declare -A RESULT
for os in "${OSES[@]}"; do
  step "Stage 3/$os — coreboot ROM → u-root → pxeboot -file → kexec → $os installer"
  bf="boot-$os.ipxe"
  if [[ ! -f "$NETBOOT_DIR/$bf" ]]; then echo "  ✗ $bf not staged — skipping"; RESULT[$os]="skipped"; continue; fi
  # run-coreboot-pxe.sh does the QEMU launch + drive-boot.py + prints its own proof.
  "$HERE/run-coreboot-pxe.sh" "$os" || true
  RESULT[$os]="ran"
done

# ── Stage 4: the proof grid (parse each captured serial log) ──
step "Stage 4 — proof grid: what each OS reached, straight off the ROM"
# label|extended-regex ; Anaconda (alma/rocky) vs debian-installer (kali) differ
# only in the last two rows, so we match either installer's banner/start.
checks=(
  "kernel DHCP (ip=dhcp)|IP-Config: Got DHCP answer"
  "u-root (PID 1)|Welcome to u-root"
  "pxeboot -file (skip DHCP)|Skipping DHCP for manual target"
  "fetched boot-<os>.ipxe|Boot URI:"
  "kexec into installer|Linux version [0-9]"
  "installer running|anaconda .* started|Loading additional components|Configuring the network|Starting the partitioner|debian-installer"
  "automated install started|Starting automated install|Installing the base system|Preconfiguring packages|Installing boot loader"
)
# Clean each per-OS serial log ONCE into a var (not per cell). We then grep from a
# here-string, NOT `sed … | grep -q`: under `set -o pipefail`, grep -q exits on the
# first match and SIGPIPEs sed, so the pipeline reports failure and a real match reads
# as a miss. A here-string keeps grep a single command, immune to that.
declare -A CLEAN
for os in "${OSES[@]}"; do
  log="$WORKDIR/pxe-$os-boot.log"
  CLEAN[$os]="$( [[ -f "$log" ]] && sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r/\n/g' "$log" || true )"
done
printf '  %-30s' "stage \\ os"
for os in "${OSES[@]}"; do printf '%-8s' "$os"; done; echo
for c in "${checks[@]}"; do
  label="${c%%|*}"; rx="${c#*|}"
  printf '  %-30s' "$label"
  for os in "${OSES[@]}"; do
    if [[ -n "${CLEAN[$os]}" ]] && grep -qiE "$rx" <<<"${CLEAN[$os]}"; then
      printf '%-8s' "  ✓"
    else
      printf '%-8s' "  ·"
    fi
  done
  echo
done
echo
echo "  logs: $WORKDIR/pxe-<os>-boot.log   •   server: ./serve-netboot.sh down to stop :8181"
bold "Firmware booted Linux, which fetched an OS over the network and kexec'd into an unattended install. That's LinuxBoot."

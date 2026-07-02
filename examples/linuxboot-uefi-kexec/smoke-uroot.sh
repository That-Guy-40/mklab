#!/usr/bin/env bash
# smoke-uroot.sh [main|v0.14.0] — boot the u-root LinuxBoot shell on the fast -kernel
# loop and probe what kind of rescue/boot environment it actually is.
#
# The LinuxBoot tiers all drop to (or pass through) a u-root shell — the interactive
# environment a human lands in if no boot policy fires. This harness drives that shell
# through a battery of probes (smoke-uroot.py) and slices the transcript, so we can
# state — from evidence, not folklore — how it handles `exit` at PID 1, job control,
# pipes, signals, and which commands ship. Findings live in SMOKE-TESTS.md.
#
# Uses the Tier-C fast loop (qemu -kernel <payload> -initrd <u-root cpio>) with a plain
# u-root cpio (NOT the stage-1-kexec one) so it idles at a shell we can type at.
#
#   ./smoke-uroot.sh main       # u-root main (what the pxeboot ROM ships)  [default]
#   ./smoke-uroot.sh v0.14.0    # u-root v0.14.0 (what the disk-boot tier pins)
set -euo pipefail
VARIANT="${1:-main}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
KERNEL="${KERNEL:-$WORKDIR/payload-bzImage}"
case "$VARIANT" in
  main)    INITRD="$WORKDIR/uroot-main.cpio" ;;
  v0.14.0) INITRD="$WORKDIR/uroot.cpio" ;;
  *) echo "usage: $0 [main|v0.14.0]" >&2; exit 1 ;;
esac
[[ -f "$KERNEL" ]] || { echo "no payload kernel at $KERNEL (extract from the coreboot build)" >&2; exit 1; }
[[ -f "$INITRD" ]] || { echo "no u-root cpio at $INITRD (build-uroot.sh / the pxeboot build)" >&2; exit 1; }

SOCK="$WORKDIR/smoke-uroot.sock"; LOG="$WORKDIR/smoke-uroot-$VARIANT.log"; rm -f "$SOCK" "$LOG"
ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)
echo "==> booting u-root $VARIANT on the fast -kernel loop (accel=$ACCEL) → $LOG"

qemu-system-x86_64 -machine q35 -accel "$ACCEL" -m 2048 \
  -kernel "$KERNEL" -initrd "$INITRD" -append "console=ttyS0" \
  -chardev socket,id=s0,path="$SOCK",server=on,wait=on -serial chardev:s0 \
  -display none -monitor none -no-reboot >/dev/null 2>&1 &
QPID=$!
python3 "$HERE/smoke-uroot.py" "$SOCK" "$LOG" 3 || true
kill "$QPID" 2>/dev/null || true            # stop the VM by PID (never by pattern)

# --- slice the transcript per probe + headline findings ----------------------------
clean() { sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r/\n/g' "$LOG"; }
echo; echo "======================= PROBE TRANSCRIPT ======================="
clean | awk '/===PROBE:/{p=1} p' | grep -avE '^\s*$' | sed 's/^/  /' | head -120

echo; echo "======================= HEADLINE FINDINGS ======================="
echo -n "exit at PID 1 → kernel panic?  "
clean | grep -qiE 'Kernel panic|Attempted to kill init|not syncing' && echo "YES (panic on exit — as expected for PID 1)" || echo "no panic seen"
echo -n "commands in /bbin:             "
clean | sed -n '/===PROBE:commands-in-bbin===/,/===PROBE:/p' | grep -m1 -oE '^[0-9]+' | head -1 || echo "?"
echo -n "background job (&) accepted?   "
clean | sed -n '/===PROBE:background-job===/,/===PROBE:not-found/p' | grep -qiE '\[[0-9]+\]|pid|Job' && echo "yes (job control markers present)" || echo "see transcript"
echo
echo "    full serial log: $LOG"

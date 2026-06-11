#!/usr/bin/env bash
# reset-demo.sh — HANDS-OFF proof of the Kali (linuxconfig) root-password reset on a
# real, preseed-installed Kali.  Calls setup-kali-target.sh to build + pre-stage the
# target (unless one is already prepared), then serial-drives the reset and verifies
# it: OLD password rejected, NEW password logs in (uid=0).
#
# This is the automated counterpart to hand-walking RUNBOOK-init-shell.md.  The
# reset itself is driven at the GRUB *command line* (per CLAUDE.md: deterministic,
# unlike fragile in-line menu editing) so the resulting /proc/cmdline is byte-
# identical to linuxconfig's `ro`→`rw`, `quiet`→`init=/bin/bash` edit.
#
# Usage:   ./reset-demo.sh            # setup if needed, then reset + verify
#          SKIP_SETUP=1 ./reset-demo.sh   # reuse an already-prepared target
# Env:     NEW_PW (default toor).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

VM="kali-preseed-install"
DRIVER="$HERE/tools/serial-drive.py"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/lab-create/vms/$VM"
SERIAL="$STATE/serial.sock"
BOOTINFO="$STATE/.rpr-bootinfo"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
NEW_PW="${NEW_PW:-toor}"

log() { printf '\n\033[1;36m[demo]\033[0m %s\n' "$*" >&2; }
die() { printf '\n\033[1;31m[demo] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
# Power-cycle, attach, run the DSL.  RETURNS serial-drive.py's exit code: 0 iff every
# EXPECT matched (the live verdict — far more reliable than grepping the transcript
# afterward, which can race the final flush).  A non-zero rc means some step's marker
# never appeared (the failing EXPECT is logged as "[[EXPECT TIMEOUT: …]]").
cycle_and_drive() {
    local logf="$1" rc=0
    phase2-qemu-vm/lab-vm.sh stop  "$VM" --force >/dev/null 2>&1 || true
    phase2-qemu-vm/lab-vm.sh start "$VM" >/dev/null 2>&1
    for _ in $(seq 1 40); do [ -S "$SERIAL" ] && break; sleep 0.1; done
    : > "$logf"
    python3 "$DRIVER" "$SERIAL" --timeout 60 --log "$logf" || rc=$?
    return "$rc"
}

[ -x "$DRIVER" ] || die "missing serial driver: $DRIVER"

# ── ensure a prepared target exists ───────────────────────────────────────────
if [ "${SKIP_SETUP:-0}" != 1 ] && { [ ! -f "$BOOTINFO" ] || ! phase2-qemu-vm/lab-vm.sh inspect "$VM" >/dev/null 2>&1; }; then
    log "no prepared target found — running setup-kali-target.sh first (~20 min)"
    "$HERE/setup-kali-target.sh"
fi
[ -f "$BOOTINFO" ] || die "no $BOOTINFO — run setup-kali-target.sh (or unset SKIP_SETUP)"
# shellcheck source=/dev/null
. "$BOOTINFO"          # UUID, VER, FORGOTTEN_PW
[ -n "${UUID:-}" ] && [ -n "${VER:-}" ] && [ -n "${FORGOTTEN_PW:-}" ] || die "incomplete $BOOTINFO"
log "target $VM  root_uuid=$UUID  kernel=$VER  old_pw=$FORGOTTEN_PW  new_pw=$NEW_PW"

# ── drive the reset over serial, with a RETRY loop ────────────────────────────
# Serial automation is inherently flaky (GRUB input has no flow control; boot timing
# varies), so each step is EXPECT-confirmed *live* by serial-drive.py and the whole
# reset is retried up to 3× on any unconfirmed step.  rc==0 ⟺ every marker appeared.
# Boot uses `search --file` + root=/dev/vda1 (shorter typed lines, no UUID needed).
log "resetting: catch GRUB → command line → rw init=/bin/bash → passwd root → exec /sbin/init → verify"
R="$WORK/reset.log"
rc=1
for attempt in 1 2 3; do
    rc=0
    cycle_and_drive "$R" <<DSL || rc=$?
EXPECT[60] automatically in
SEND c
SLEEP 1
SENDLN search --no-floppy --file /boot/vmlinuz-$VER --set=root
SLEEP 0.7
SENDLN linux /boot/vmlinuz-$VER root=/dev/vda1 rw init=/bin/bash console=ttyS0,115200n8
SLEEP 0.7
SENDLN initrd /boot/initrd.img-$VER
SLEEP 0.7
SENDLN boot
EXPECT[120] root@(none)
SLEEP 1
SENDLN export PATH=/usr/sbin:/usr/bin:/sbin:/bin
SLEEP 0.6
SENDLN echo PID-IS-\$\$
EXPECT[15] PID-IS-1
SLEEP 0.5
SENDLN cat /proc/cmdline
SLEEP 0.5
SENDLN grep -q 'init=/bin/bash' /proc/cmdline && echo CMDLINE-INITBASH-OK
EXPECT[15] CMDLINE-INITBASH-OK
SLEEP 0.5
SENDLN mount -o remount,rw /
SLEEP 1
SENDLN echo 'root:$NEW_PW' | chpasswd
SLEEP 0.5
SENDLN echo CHPW-RC-\$?
EXPECT[15] CHPW-RC-0
SLEEP 1
SENDLN exec /sbin/init
EXPECT[120] login:
SLEEP 2
SENDLN root
EXPECT[20] assword
SLEEP 1
SENDLN $FORGOTTEN_PW
EXPECT[25] ncorrect
EXPECT[20] login:
SLEEP 1
SENDLN root
EXPECT[20] assword
SLEEP 1
SENDLN $NEW_PW
EXPECT[30] Linux kali
SLEEP 1
SENDLN id
EXPECT[20] uid=0(root)
SLEEP 1
SENDLN echo DEMO-DONE
EXPECT[15] DEMO-DONE
SLEEP 1
DSL
    phase2-qemu-vm/lab-vm.sh stop "$VM" --force >/dev/null 2>&1 || true
    cp "$R" "$STATE/.rpr-last-demo.log" 2>/dev/null || true
    [ "$rc" -eq 0 ] && break
    miss="$(grep -aoE "EXPECT TIMEOUT: '[^']*'" "$R" | head -1 | sed "s/.*: '//")"
    log "attempt $attempt did not confirm a step (stuck before: ${miss:-unknown}); retrying…"
done

# ── verdict — rc==0 means serial-drive.py confirmed EVERY step live this attempt ──
log "verification (each step confirmed live by serial-drive.py):"
if [ "$rc" -eq 0 ]; then
    while IFS= read -r s; do printf '  \033[1;32m✓\033[0m %s\n' "$s" >&2; done <<'STEPS'
bash ran as PID 1 (init=/bin/bash)      → PID-IS-1
kernel /proc/cmdline carried init=/bin/bash → CMDLINE-INITBASH-OK
root password changed (chpasswd rc 0)   → CHPW-RC-0
OLD password rejected                   → Login incorrect
NEW password logged in                  → uid=0(root)
reached end of demo                     → DEMO-DONE
STEPS
    printf '\n\033[1;32m[demo] PASS\033[0m — the Kali reset is verified end-to-end on a real installed Kali.\n' >&2
    printf '       OLD "%s" rejected; NEW "%s" logs in as uid=0.  (transcript: %s)\n' \
           "$FORGOTTEN_PW" "$NEW_PW" "$STATE/.rpr-last-demo.log" >&2
    exit 0
else
    miss="$(grep -aoE "EXPECT TIMEOUT: '[^']*'" "$R" | head -1 | sed "s/.*: '//")"
    die "reset did not confirm after 3 attempts (last stuck before: ${miss:-unknown}); transcript: $STATE/.rpr-last-demo.log"
fi

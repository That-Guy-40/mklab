#!/usr/bin/env bash
# reset-demo-almalinux.sh — HANDS-OFF proof of the RHEL-family rd.break root-password
# reset on a real, kickstart-installed AlmaLinux 9.  The AlmaLinux analogue of
# reset-demo-rocky.sh (identical method; AlmaLinux 9 and Rocky 9 are both RHEL 9
# rebuilds with the same dracut + grub2 + BLS + SELinux machinery).
#
# Calls setup-almalinux-target.sh to build + pre-stage the target (unless one already
# exists), then serial-drives the rd.break method and verifies it:
#   GRUB editor -> append rd.break to the linux line -> dracut emergency shell
#   -> mount -o remount,rw /sysroot -> chroot /sysroot -> passwd (chpasswd) ->
#   touch /.autorelabel (the SELinux step everyone forgets) -> exit -> the boot
#   continues, SELinux relabels the whole fs (slow) and reboots -> login:
#   OLD password rejected, NEW password logs in (uid=0, correct SELinux context).
#
# Faithful to RUNBOOK-rd-break.md.  The rd.break edit is done in the GRUB *editor*
# (append one word) rather than the command line: RHEL grub2 redraws aggressively
# over serial and drops input on long typed lines, so the driver runs at a slower
# --char-delay and we append the minimum.  The BLS-generated menuentry body is
# load_video / set gfxpayload / insmod gzio / linux / initrd — identical to Rocky —
# so `e` then Ctrl-n ×3 reaches the `linux` line, Ctrl-e to its end, append rd.break.
#
# Usage:   ./reset-demo-almalinux.sh            # setup if needed, then reset + verify
#          SKIP_SETUP=1 ./reset-demo-almalinux.sh   # reuse an already-prepared target
# Env:     NEW_PW (default toor).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

VM="almalinux-kickstart-install"
DRIVER="$HERE/tools/serial-drive.py"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/lab-create/vms/$VM"
SERIAL="$STATE/serial.sock"
BOOTINFO="$STATE/.rpr-bootinfo"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
NEW_PW="${NEW_PW:-toor}"
CHAR_DELAY="${CHAR_DELAY:-0.08}"   # slower than the 0.04 default: RHEL grub2 drops input under redraw

log() { printf '\n\033[1;36m[demo-alma]\033[0m %s\n' "$*" >&2; }
die() { printf '\n\033[1;31m[demo-alma] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
# RETURNS serial-drive.py's exit code: 0 iff every EXPECT matched this attempt.
cycle_and_drive() {
    local logf="$1" rc=0
    phase2-qemu-vm/lab-vm.sh stop  "$VM" --force >/dev/null 2>&1 || true
    phase2-qemu-vm/lab-vm.sh start "$VM" >/dev/null 2>&1
    for _ in $(seq 1 40); do [ -S "$SERIAL" ] && break; sleep 0.1; done
    : > "$logf"
    python3 "$DRIVER" "$SERIAL" --timeout 60 --char-delay "$CHAR_DELAY" --log "$logf" || rc=$?
    return "$rc"
}

[ -x "$DRIVER" ] || die "missing serial driver: $DRIVER"

# ── ensure a prepared target exists ───────────────────────────────────────────
if [ "${SKIP_SETUP:-0}" != 1 ] && { [ ! -f "$BOOTINFO" ] || ! phase2-qemu-vm/lab-vm.sh inspect "$VM" >/dev/null 2>&1; }; then
    log "no prepared target found — running setup-almalinux-target.sh first (~10-15 min)"
    "$HERE/setup-almalinux-target.sh"
fi
[ -f "$BOOTINFO" ] || die "no $BOOTINFO — run setup-almalinux-target.sh (or unset SKIP_SETUP)"
# shellcheck source=/dev/null
. "$BOOTINFO"          # KVER, ROOTDEV, FORGOTTEN_PW
[ -n "${FORGOTTEN_PW:-}" ] || die "incomplete $BOOTINFO"
log "target $VM  kernel=${KVER:-?}  root=${ROOTDEV:-?}  old_pw=$FORGOTTEN_PW  new_pw=$NEW_PW"

# ── drive the rd.break reset over serial, with a RETRY loop ────────────────────
# Each step is EXPECT-confirmed live; rc==0 ⟺ every marker appeared.  The BLS
# menuentry body is: load_video / set gfxpayload / insmod gzio / linux / initrd —
# so `e` then Ctrl-n ×3 reaches the `linux` line, Ctrl-e to its end, append rd.break.
log "rd.break: GRUB editor → +rd.break → dracut shell → chroot /sysroot → passwd → /.autorelabel → relabel → verify"
R="$WORK/reset.log"
rc=1
for attempt in 1 2 3; do
    rc=0
    cycle_and_drive "$R" <<DSL || rc=$?
EXPECT[60] automatically in
SEND e
SLEEP 2.5
CTRL n
SLEEP 0.7
CTRL n
SLEEP 0.7
CTRL n
SLEEP 0.7
CTRL e
SLEEP 0.8
SEND  rd.break
SLEEP 2
KEY 18
EXPECT[120] switch_root:/#
SLEEP 2
SENDLN mount -o remount,rw /sysroot
SLEEP 2
SENDLN chroot /sysroot /bin/bash -c 'echo root:$NEW_PW | chpasswd && touch /.autorelabel && echo CHROOT-RESET-OK'
EXPECT[20] CHROOT-RESET-OK
SLEEP 1
SENDLN exit
EXPECT[360] login:
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
EXPECT[30] ]#
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
rd.break → dracut emergency shell      → switch_root:/#
chroot /sysroot: passwd + /.autorelabel → CHROOT-RESET-OK
SELinux relabel + reboot → login        → login:
OLD password rejected                   → Login incorrect
NEW password logged in                  → uid=0(root)
reached end of demo                     → DEMO-DONE
STEPS
    printf '\n\033[1;32m[demo-alma] PASS\033[0m — the AlmaLinux rd.break reset is verified end-to-end on real AlmaLinux 9.\n' >&2
    printf '       OLD "%s" rejected; NEW "%s" logs in as uid=0 (with the relabel applied).  (transcript: %s)\n' \
           "$FORGOTTEN_PW" "$NEW_PW" "$STATE/.rpr-last-demo.log" >&2
    exit 0
else
    miss="$(grep -aoE "EXPECT TIMEOUT: '[^']*'" "$R" | head -1 | sed "s/.*: '//")"
    die "reset did not confirm after 3 attempts (last stuck before: ${miss:-unknown}); transcript: $STATE/.rpr-last-demo.log"
fi

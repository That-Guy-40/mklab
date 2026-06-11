#!/usr/bin/env bash
# setup-rocky-target.sh — build a REAL Rocky Linux 9 install and pre-stage it as a
# root-password-reset target, then stop it so you can HAND-WALK the rd.break reset.
#
# The Rocky analogue of setup-kali-target.sh.  Where the Kali method is
# init=/bin/bash, the RHEL-family method is rd.break (break into the dracut
# initramfs → chroot /sysroot → passwd → touch /.autorelabel) — see
# RUNBOOK-rd-break.md.  The reset TARGET is a real Anaconda/kickstart install from
# examples/rocky-kickstart-gallery/ (variant: GenericCloud-Base), which — unlike the
# Kali desktop 7z — is already serial-ready (the kickstart bakes console=ttyS0) and
# sets the "forgotten" root password directly (rootpw S0meForgottenPass).  So the
# only pre-stage is widening the 1-second GRUB menu to an interruptible 5 seconds.
#
#   stage (installer + kickstarts --root-pw + select GenericCloud-Base) -> nginx :8181
#   -> Anaconda install (unattended, ~10-15 min) -> log in root/S0meForgottenPass ->
#      set GRUB_TIMEOUT=5 + grub2-mkconfig -> capture kver/root dev -> stop.
#
# After it finishes, HAND-WALK the reset:  RUNBOOK-rd-break.md
#   phase2-qemu-vm/lab-vm.sh console rocky-kickstart-install
# or run the hands-off proof:  ./reset-demo-rocky.sh
#
# Re-runnable: it destroys any prior install VM first.
# Env overrides:  FORGOTTEN_PW (default S0meForgottenPass), INSTALL_TIMEOUT (1500s).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

GALLERY_TOML="examples/rocky-kickstart-gallery/rocky-kickstart-gallery.toml"
VARIANT="GenericCloud-Base"
VM="rocky-kickstart-install"
DRIVER="$HERE/tools/serial-drive.py"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/lab-create/vms/$VM"
SERIAL="$STATE/serial.sock"
BOOTINFO="$STATE/.rpr-bootinfo"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FORGOTTEN_PW="${FORGOTTEN_PW:-S0meForgottenPass}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-1500}"

log()  { printf '\n\033[1;36m[setup-rocky]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[setup-rocky] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Power-cycle, attach, run the DSL.  RETURNS serial-drive.py's exit code (0 iff every
# EXPECT matched — the live verdict, more reliable than grepping the transcript).
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
command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not found"
[ -e /dev/kvm ] || log "WARNING: /dev/kvm absent — install will be slow (TCG)"

# ── 1. stage the Rocky installer + kickstart catalog, select GenericCloud-Base ──
log "1/6 staging the Rocky installer + kickstarts (root pw = $FORGOTTEN_PW), selecting $VARIANT"
examples/rocky-pxe-lab/fetch-rocky-installer.sh --release 9 --arch x86_64 >/dev/null
examples/rocky-kickstart-gallery/fetch-kickstarts.sh --root-pw "$FORGOTTEN_PW" >/dev/null
examples/rocky-kickstart-gallery/select-kickstart.sh "$VARIANT" >/dev/null

# ── 2. nginx artifact server + verify the artifacts serve 200 ──────────────────
log "2/6 starting the nginx artifact server on :8181"
phase4-podman/lab-podman.sh up --config "$GALLERY_TOML" >/dev/null
for u in vmlinuz initrd.img images/install.img "rocky-kickstart/Rocky-9-$VARIANT.ks"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:8181/$u" || true)"
    [ "$code" = 200 ] || die "artifact http://localhost:8181/$u → HTTP $code (want 200)"
done

# ── 3. (re)create + start the installer VM ─────────────────────────────────────
log "3/6 installing Rocky via Anaconda (unattended; this takes ~10-15 min)"
phase2-qemu-vm/lab-vm.sh destroy "$VM" --force >/dev/null 2>&1 || true
phase2-qemu-vm/lab-vm.sh create  --config "$GALLERY_TOML" >/dev/null
phase2-qemu-vm/lab-vm.sh start   "$VM" >/dev/null
for _ in $(seq 1 40); do [ -S "$SERIAL" ] && break; sleep 0.1; done

# ── 4. wait for Anaconda to finish + reboot into the installed system ──────────
# GenericCloud is serial-ready (console=ttyS0), so the post-install getty's "login:"
# is the signal (Anaconda itself never prints one).
log "4/6 waiting for the install to finish (watching serial for the post-install login:)"
INSTALL_LOG="$WORK/install.log"; : > "$INSTALL_LOG"
python3 "$DRIVER" "$SERIAL" --capture "$INSTALL_TIMEOUT" --log "$INSTALL_LOG" &
CAP=$!
deadline=$((SECONDS + INSTALL_TIMEOUT))
until grep -qa 'login:' "$INSTALL_LOG" 2>/dev/null; do
    kill -0 "$CAP" 2>/dev/null || die "serial capture died during install (see $INSTALL_LOG)"
    [ "$SECONDS" -lt "$deadline" ] || { kill "$CAP" 2>/dev/null||true; die "install timed out after ${INSTALL_TIMEOUT}s"; }
    if grep -qaiE 'Pane is dead|installation failed|Traceback|dracut: FATAL|kernel panic' "$INSTALL_LOG"; then
        kill "$CAP" 2>/dev/null || true; die "Anaconda reported an install failure (see $INSTALL_LOG)"
    fi
    sleep 10
done
kill "$CAP" 2>/dev/null || true; wait "$CAP" 2>/dev/null || true
log "    install finished — Rocky is on disk and booting"

# ── 5. pre-stage: widen the 1s GRUB menu to an interruptible 5s, capture boot info.
#       Rocky logs in as root directly (the kickstart unlocked it to the forgotten
#       pw); no sudo, no console baking.  Retried up to 3x without re-installing.
log "5/6 pre-staging: GRUB_TIMEOUT 1 -> 5 (grub2-mkconfig); capturing kver/root dev"
KVER=""; ROOTDEV=""; ok=0
for attempt in 1 2 3; do
    prc=0
    cycle_and_drive "$WORK/prestage.log" <<DSL || prc=$?
EXPECT[180] login:
SLEEP 2
SENDLN root
EXPECT[20] assword
SLEEP 1
SENDLN $FORGOTTEN_PW
EXPECT[25] ]#
SLEEP 1
SENDLN sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub; grep -q TIMEOUT_STYLE /etc/default/grub || echo GRUB_TIMEOUT_STYLE=menu >> /etc/default/grub
SLEEP 1
SENDLN grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1; echo MKGRUB-RC-\$?
EXPECT[40] MKGRUB-RC-0
SLEEP 1
SENDLN echo RPRINFO KVER=\$(uname -r) ROOT=\$(findmnt -no SOURCE /)
EXPECT[15] RPRINFO KVER=
SLEEP 1
SENDLN poweroff
SLEEP 5
DSL
    if [ "$prc" -ne 0 ]; then
        miss="$(grep -aoE "EXPECT TIMEOUT: '[^']*'" "$WORK/prestage.log" | head -1 | sed "s/.*: '//")"
        log "    attempt $attempt: pre-stage didn't confirm (stuck before: ${miss:-unknown}); retrying"; continue
    fi
    P="$(tr -d '\000' < "$WORK/prestage.log" | tr '\r' '\n')"
    KVER="$(printf '%s' "$P" | grep -aoE 'KVER=[^ ]+ ROOT=' | head -1 | sed -E 's/KVER=//; s/ ROOT=//')"
    ROOTDEV="$(printf '%s' "$P" | grep -aoE 'ROOT=/dev/[a-z0-9]+' | head -1 | cut -d= -f2)"
    if [ -z "$KVER" ] || [ -z "$ROOTDEV" ]; then log "    attempt $attempt: couldn't read kver/root dev; retrying"; continue; fi
    ok=1; break
done
[ "$ok" = 1 ] || die "pre-stage failed after 3 attempts (see $WORK/prestage.log)"
log "    kernel=$KVER  root=$ROOTDEV  GRUB menu now 5s"

phase2-qemu-vm/lab-vm.sh stop "$VM" --force >/dev/null 2>&1 || true
printf 'KVER=%s\nROOTDEV=%s\nFORGOTTEN_PW=%s\n' "$KVER" "$ROOTDEV" "$FORGOTTEN_PW" > "$BOOTINFO"

# ── 6. done ────────────────────────────────────────────────────────────────────
log "6/6 DONE — $VM is installed + pre-staged and stopped."
cat >&2 <<EOF

  Target ready:  $VM   (root pw is "$FORGOTTEN_PW" — pretend you forgot it; SELinux enforcing)
  Boot info:     $BOOTINFO

  Hand-walk the rd.break reset (the point of this lab):
    phase2-qemu-vm/lab-vm.sh console $VM        # then follow RUNBOOK-rd-break.md
  …or run the hands-off proof:
    examples/root-password-reset/reset-demo-rocky.sh   # serial-drives rd.break + verifies

  Teardown:
    phase4-podman/lab-podman.sh down --lab rocky-kickstart
    phase2-qemu-vm/lab-vm.sh destroy $VM --force
EOF

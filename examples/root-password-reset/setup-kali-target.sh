#!/usr/bin/env bash
# setup-kali-target.sh — build a REAL headless Kali and pre-stage it as a
# root-password-reset target, then stop it so you can HAND-WALK the reset.
#
# Why this exists: Kali's prebuilt desktop 7z (kali.toml's old spec) boot-loops at
# GRUB on lab-vm.sh's headless serial-only QEMU.  A d-i + preseed install lays down
# a normal grub-pc whose menu IS serial-reachable.  So the reset target is a
# preseed-installed Kali from examples/kali-preseed-gallery/ (headless-default).
# This script automates the documented kali.toml workflow end to end:
#
#   stage (fetch d-i + bake preseed)  →  nginx :8181  →  PXE-install (unattended)
#   →  discover the install's root UUID from GRUB  →  pre-stage over serial
#      (console=ttyS0 + 5s menu + a "forgotten" root password)  →  stop.
#
# After it finishes, HAND-WALK the reset:  RUNBOOK-init-shell.md (Kali variation)
#   phase2-qemu-vm/lab-vm.sh console kali-preseed-install
# or run the hands-off proof:  ./reset-demo.sh  (which calls this script first).
#
# All serial driving uses tools/serial-drive.py (char-by-char 40ms send; GRUB has
# no flow control).  Re-runnable: it destroys any prior install VM first.
#
# Env overrides:  FORGOTTEN_PW (default S0meForgottenPass), INSTALL_TIMEOUT (2700s).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

GALLERY_TOML="examples/kali-preseed-gallery/kali-preseed-gallery.toml"
VM="kali-preseed-install"
DRIVER="$HERE/tools/serial-drive.py"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/lab-create/vms/$VM"
SERIAL="$STATE/serial.sock"
BOOTINFO="$STATE/.rpr-bootinfo"          # UUID/VER handoff for reset-demo.sh
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FORGOTTEN_PW="${FORGOTTEN_PW:-S0meForgottenPass}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-2700}"

log()  { printf '\n\033[1;36m[setup]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[setup] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
# strip CCSI/OSC noise so grep/parse sees plain text
denoise() { sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][0-9;]*[^\x07\x1b]*(\x07|\x1b\\)?//g; s/\]3008;[^\\]*\\//g; s/\x0f//g; s/\x00//g'; }

# Power-cycle, then attach IN THE SAME STEP so GRUB's 5s window isn't missed.
# Reads a serial-drive DSL on stdin; writes the transcript to $1.
cycle_and_drive() {
    local logf="$1"; shift
    phase2-qemu-vm/lab-vm.sh stop  "$VM" --force >/dev/null 2>&1 || true
    phase2-qemu-vm/lab-vm.sh start "$VM" >/dev/null 2>&1
    for _ in $(seq 1 40); do [ -S "$SERIAL" ] && break; sleep 0.1; done
    : > "$logf"
    # RETURN serial-drive.py's exit code: 0 iff every EXPECT matched (the live verdict
    # — more reliable than grepping the transcript afterward, which can race the flush).
    local rc=0
    python3 "$DRIVER" "$SERIAL" --timeout 60 --log "$logf" || rc=$?
    return "$rc"
}

[ -x "$DRIVER" ] || die "missing serial driver: $DRIVER"
command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not found"
[ -e /dev/kvm ] || log "WARNING: /dev/kvm absent — install will be slow (TCG)"

# ── 1. stage the d-i installer + bake boot.ipxe for headless-default ──────────
log "1/6 staging d-i kernel/initrd + headless-default preseed (reusing the gallery)"
examples/kali-pxe-lab/fetch-kali-installer.sh --arch amd64 >/dev/null
examples/kali-preseed-gallery/select-preseed.sh headless-default >/dev/null

# ── 2. nginx artifact server + verify the three artifacts serve 200 ───────────
log "2/6 starting the nginx artifact server on :8181"
phase4-podman/lab-podman.sh up --config "$GALLERY_TOML" >/dev/null
for u in kali/linux kali/initrd.gz kali-preseed/headless-default; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:8181/$u" || true)"
    [ "$code" = 200 ] || die "artifact http://localhost:8181/$u → HTTP $code (want 200)"
done

# ── 3. (re)create + start the installer VM ────────────────────────────────────
log "3/6 PXE-installing $VM (unattended d-i; this takes ~20 min)"
phase2-qemu-vm/lab-vm.sh destroy "$VM" --force >/dev/null 2>&1 || true
phase2-qemu-vm/lab-vm.sh create  --config "$GALLERY_TOML" >/dev/null
phase2-qemu-vm/lab-vm.sh start   "$VM" >/dev/null
for _ in $(seq 1 40); do [ -S "$SERIAL" ] && break; sleep 0.1; done

# ── 4. wait for d-i to finish + reboot — the installed GRUB menu is the signal ─
# d-i netboots via iPXE (no GRUB); the FIRST "automatically in" countdown only
# appears once the installed grub-pc runs post-reboot → install is done.
log "4/6 waiting for the install to finish (watching serial for the post-install GRUB menu)"
INSTALL_LOG="$WORK/install.log"; : > "$INSTALL_LOG"
python3 "$DRIVER" "$SERIAL" --capture "$INSTALL_TIMEOUT" --log "$INSTALL_LOG" &
CAP=$!
deadline=$((SECONDS + INSTALL_TIMEOUT))
until denoise < "$INSTALL_LOG" 2>/dev/null | grep -qa 'automatically in'; do
    kill -0 "$CAP" 2>/dev/null || die "serial capture died during install (see $INSTALL_LOG)"
    [ "$SECONDS" -lt "$deadline" ] || { kill "$CAP" 2>/dev/null||true; die "install timed out after ${INSTALL_TIMEOUT}s"; }
    if denoise < "$INSTALL_LOG" | grep -qaiE 'Installation step failed|No bootable device|reboot into the installer'; then
        kill "$CAP" 2>/dev/null || true; die "d-i reported an install failure (see $INSTALL_LOG)"
    fi
    sleep 10
done
kill "$CAP" 2>/dev/null || true; wait "$CAP" 2>/dev/null || true
log "    install finished — Kali is on disk and booting"

# ── 5. read the kernel VERSION from the GRUB editor.  We deliberately do NOT parse
#       root=UUID here: the long `linux` line WRAPS at 80 cols and splits the UUID
#       across rows (root=UUID=xxxx-…\<wrap>…), so a contiguous match fails.  The
#       vmlinuz path is at the START of the line (pre-wrap) → it parses clean.  We
#       then boot via `search --file` + root=/dev/vda1 (no UUID needed) and read the
#       UUID cleanly from the running system with findmnt.  Per CLAUDE.md we drive
#       the GRUB *command line*, not the (fragile, wrapping) menu editor.
#       VER discovery + pre-stage are wrapped in a RETRY loop so a flaky GRUB catch
#       retries WITHOUT re-installing (the install above is the expensive part).  Each
#       step is EXPECT-confirmed live; the pre-stage's rc==0 ⟺ it fully landed.
log "5/6 reading the kernel version from GRUB, then booting + pre-staging over serial"
VER_LOG="$WORK/ver.log"; PRESTAGE_LOG="$WORK/prestage.log"
VER=""; UUID=""; ok=0
for attempt in 1 2 3; do
    # 5a. read the kernel VERSION from the GRUB editor (vmlinuz path is pre-wrap →
    #     parses clean; we deliberately do NOT parse the wrap-split root=UUID here).
    cycle_and_drive "$VER_LOG" <<'DSL' || true
EXPECT[60] automatically in
SEND e
SLEEP 5
KEY 1b
SLEEP 1
DSL
    VER="$(denoise < "$VER_LOG" | grep -aoE '/boot/vmlinuz-[^ ]+' | head -1 | sed 's#/boot/vmlinuz-##' || true)"
    if [ -z "$VER" ]; then log "    attempt $attempt: couldn't read the kernel version; retrying"; continue; fi

    # 5b. boot WITH console=ttyS0 (serial login), log in kali/kali, pre-stage (bake
    #     console+menu permanently, set the "forgotten" root password), read the root
    #     UUID via findmnt.  Append-only /etc/default/grub edits dodge the serial
    #     char-drop.  Boot uses `search --file` + root=/dev/vda1 (no UUID needed).
    prc=0
    cycle_and_drive "$PRESTAGE_LOG" <<DSL || prc=$?
EXPECT[60] automatically in
SEND c
SLEEP 1
SENDLN search --no-floppy --file /boot/vmlinuz-$VER --set=root
SLEEP 0.7
SENDLN linux /boot/vmlinuz-$VER root=/dev/vda1 ro quiet console=tty0 console=ttyS0,115200n8
SLEEP 0.7
SENDLN initrd /boot/initrd.img-$VER
SLEEP 0.7
SENDLN boot
EXPECT[150] login:
SLEEP 2
SENDLN kali
EXPECT[20] assword
SLEEP 1
SENDLN kali
EXPECT[25] kali@kali
SLEEP 0.5
SENDLN sudo -v
SLEEP 1.5
SENDLN kali
SLEEP 2
SENDLN echo 'GRUB_CMDLINE_LINUX="console=ttyS0,115200n8"' | sudo tee -a /etc/default/grub
SLEEP 1.5
SENDLN echo 'GRUB_TIMEOUT_STYLE=menu' | sudo tee -a /etc/default/grub
SLEEP 1.2
SENDLN echo 'GRUB_TIMEOUT=5' | sudo tee -a /etc/default/grub
SLEEP 1.2
SENDLN echo 'root:$FORGOTTEN_PW' | sudo chpasswd
SLEEP 1.5
SENDLN echo RPR-ROOT-UUID=\$(findmnt -no UUID /)
SLEEP 1.5
SENDLN sudo update-grub
SLEEP 35
SENDLN echo PRESTAGE-RC-\$?
EXPECT[40] PRESTAGE-RC-0
SLEEP 1
SENDLN sudo poweroff
SLEEP 5
DSL
    if [ "$prc" -ne 0 ]; then
        miss="$(grep -aoE "EXPECT TIMEOUT: '[^']*'" "$PRESTAGE_LOG" | head -1 | sed "s/.*: '//")"
        log "    attempt $attempt: pre-stage didn't confirm (stuck before: ${miss:-unknown}); retrying"; continue
    fi
    # findmnt output is contiguous (a unique hex pattern, unlike the wrap-split GRUB
    # line) → parses unambiguously; the EXPECT PRESTAGE-RC-0 above already confirmed
    # every sudo step (incl. update-grub) succeeded.
    UUID="$(tr -d '\000' < "$PRESTAGE_LOG" | grep -aoE 'RPR-ROOT-UUID=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 | cut -d= -f2 || true)"
    if [ -z "$UUID" ]; then log "    attempt $attempt: couldn't read the root UUID; retrying"; continue; fi
    ok=1; break
done
[ "$ok" = 1 ] || die "pre-stage failed after 3 attempts (see $PRESTAGE_LOG)"
log "    kernel=$VER  root UUID=$UUID (clean, via findmnt)"

# Persist the boot info so reset-demo.sh can drive the reset deterministically.
phase2-qemu-vm/lab-vm.sh stop "$VM" --force >/dev/null 2>&1 || true
printf 'UUID=%s\nVER=%s\nFORGOTTEN_PW=%s\n' "$UUID" "$VER" "$FORGOTTEN_PW" > "$BOOTINFO"

# ── 6. done ───────────────────────────────────────────────────────────────────
log "6/6 DONE — $VM is installed + pre-staged and stopped."
cat >&2 <<EOF

  Target ready:  $VM   (root pw is now "$FORGOTTEN_PW" — pretend you forgot it)
  Boot info:     $BOOTINFO

  Hand-walk the reset (the point of this lab):
    phase2-qemu-vm/lab-vm.sh console $VM        # then follow RUNBOOK-init-shell.md (Kali)
  …or run the hands-off proof:
    examples/root-password-reset/reset-demo.sh   # serial-drives the reset + verifies

  Teardown:
    phase4-podman/lab-podman.sh down --lab kali-preseed-gallery
    phase2-qemu-vm/lab-vm.sh destroy $VM --force
EOF

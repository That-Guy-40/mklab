#!/bin/bash
# prestage.sh — one-time LAB SETUP for the root-password-reset lab.  Run INSIDE
# the guest, as root (e.g. `lab-vm.sh ssh <vm> -- 'sudo bash -s' < setup/prestage.sh`).
# This is NOT part of the reset — it just puts the VM into a realistic state.
#
# It does two things:
#
#   1. Restore a NORMAL, interruptible boot menu on the SERIAL console.  Cloud
#      images generate their grub.cfg with `timeout=0`, so GRUB boots the default
#      instantly and you can never reach the editor.  A real installed or physical
#      machine shows an interruptible menu — we restore exactly that
#      (GRUB_TIMEOUT=5 + GRUB_TIMEOUT_STYLE=menu, then regenerate grub.cfg).
#      Debian/Kali cloud images already point GRUB at the serial line
#      (GRUB_TERMINAL="console serial"); on others we add it.
#
#   2. Give root a password we then PRETEND TO HAVE FORGOTTEN, so the lab starts
#      from a realistic "locked out" state — and so there is an OLD password that
#      must STOP working after the reset (proof the reset really took effect).
#
# The reset technique (RUNBOOK-*.md) assumes ONLY console/boot access — the real
# threat model.  The defense is in README.md "Mitigations" (set a GRUB password,
# encrypt the disk); this lab shows precisely why that matters.
#
# Verified end-to-end on Debian 12 (bookworm) cloud image; the Rocky branch is
# author-run (grub2-mkconfig path) — see MANUAL_TESTING.md.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"

FORGOTTEN_PW="${FORGOTTEN_PW:-S0meForgottenPass}"   # the "lost" root password

if command -v update-grub >/dev/null 2>&1; then
    # ── Debian / Kali (grub.d drop-ins, sourced in sorted order; last wins) ──
    # Cloud image ships /etc/default/grub.d/15_timeout.cfg with GRUB_TIMEOUT=0;
    # a 99- drop-in overrides it cleanly and is reversible (rm + update-grub).
    install -d -m 0755 /etc/default/grub.d
    cat > /etc/default/grub.d/99-lab-reset.cfg <<'CFG'
# root-password-reset lab — override 15_timeout.cfg so GRUB pauses and SHOWS its
# menu (cloud images set GRUB_TIMEOUT=0).  Reverse with:
#   sudo rm /etc/default/grub.d/99-lab-reset.cfg && sudo update-grub
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
CFG
    update-grub
elif command -v grub2-mkconfig >/dev/null 2>&1; then
    # ── Rocky / RHEL family (no grub.d sourcing; edit /etc/default/grub) ──
    GRUBDEF=/etc/default/grub
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' "$GRUBDEF" || echo 'GRUB_TIMEOUT=5' >> "$GRUBDEF"
    sed -i '/^GRUB_TIMEOUT_STYLE=/d' "$GRUBDEF"; echo 'GRUB_TIMEOUT_STYLE=menu' >> "$GRUBDEF"
    grep -q '^GRUB_TERMINAL' "$GRUBDEF" || echo 'GRUB_TERMINAL="console serial"' >> "$GRUBDEF"
    grep -q '^GRUB_SERIAL_COMMAND' "$GRUBDEF" || echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"' >> "$GRUBDEF"
    # regenerate whichever grub.cfg this machine boots (BIOS vs UEFI)
    if [ -d /sys/firmware/efi ]; then
        grub2-mkconfig -o "$(find /boot/efi/EFI -name grub.cfg | head -1)"
    else
        grub2-mkconfig -o /boot/grub2/grub.cfg
    fi
else
    echo "prestage: neither update-grub nor grub2-mkconfig found" >&2; exit 1
fi

echo "root:${FORGOTTEN_PW}" | chpasswd

cat <<EOF

[prestage] done.
  - GRUB now pauses 5s and shows its menu on the serial console.
  - root's password is set to the "forgotten" value: ${FORGOTTEN_PW}
    (pretend you DON'T know it — that's the whole point).
Next:  reboot, attach the console (lab-vm.sh console <vm>), and follow a RUNBOOK.
EOF

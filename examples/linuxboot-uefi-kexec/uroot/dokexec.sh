#!/bin/sh
# dokexec.sh — the LinuxBoot "boot policy": u-root's /init runs THIS, and this is
# what makes u-root a *bootloader* instead of just a shell.
#
# It is embedded into the stage-1 u-root initramfs (see build-uroot.sh) and wired
# to /bin/uinit via `-uinitcmd="gosh /bin/dokexec.sh"`, so u-root runs it
# automatically as PID 1's first job — before dropping to a shell.
#
# The kernel (/boot/bzImage) and the second-stage initramfs (/boot/initramfs2.cpio)
# were baked into THIS initramfs by build-uroot.sh's `-files`. Here we just kexec
# them — a real LinuxBoot policy would instead probe disks/net and pick a target
# (u-root ships `localboot`/`pxeboot` for exactly that; see RUNBOOK.md "Going
# further"). We keep it deterministic so the handoff is unmistakable in the log.
#
# u-root's `kexec <kernel>` defaults to load+exec in one call (kexec_linux.go:
# `if !load && !exec { load = exec = true }`). We try the modern kexec_file_load
# first and fall back to the legacy kexec_load syscall (-L, no signature check)
# for hosts/kernels where file_load is refused (e.g. Secure Boot enforcement).
set -u
STAGE2_CMDLINE="console=ttyS0 LINUXBOOT_STAGE2=reached"

echo "=== LINUXBOOT_STAGE1: u-root init is now the bootloader; kexec-ing stage 2 ==="
kexec -i /boot/initramfs2.cpio -c "$STAGE2_CMDLINE" /boot/bzImage || {
  echo "=== LINUXBOOT_STAGE1: file_load failed; trying kexec_load syscall (-L) ==="
  kexec -L -i /boot/initramfs2.cpio -c "$STAGE2_CMDLINE" /boot/bzImage
}
# If kexec took over, we never get here. Reaching this line means it failed.
echo "=== LINUXBOOT_STAGE1: kexec did NOT take over (failure) — dropping to shell ==="

#!/bin/bash
# provision-kdump.sh — turn a fresh Debian (lab-vm.sh cloud image) into the
# kdump/kexec crash-debugging box from Petros Koutoupis's Linux Journal article
# "Oops! Debugging Kernel Panics".  Run it INSIDE the guest, then reboot once.
#
#   Upstream: ./upstream-tutorial/  ·  https://www.linuxjournal.com/content/oops-debugging-kernel-panics-0
#   By-hand : see RUNBOOK.md (this script is the automated equivalent of its §1-§3)
#
# It is the article's install+configure steps, made non-interactive, plus ONE
# faithfulness-driven divergence forced by the cloud image (explained inline):
# we move from the cloud kernel to Debian's *generic* `-amd64` kernel — the
# article's exact flavor — because (a) the article uses `-amd64`, and (b) the
# stock cloud image runs a stale `-cloud-amd64` point release whose debug
# symbols (needed by `crash`) are not in Debian's debug archive, while the
# newest generic `-amd64` ships matching headers AND `-dbg`.
#
# After this script finishes: `sudo reboot`.  The reboot is what actually
# reserves the crashkernel memory region (a boot-time reservation) and boots you
# into the generic kernel.  Then follow RUNBOOK.md §4 onward (verify -> panic).
set -euo pipefail

CRASHKERNEL="${CRASHKERNEL:-128M}"   # article's value; bump to 256M if capture OOMs
log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || exec sudo -E CRASHKERNEL="$CRASHKERNEL" bash "$0" "$@"
export DEBIAN_FRONTEND=noninteractive

log "0. stop unattended-upgrades (so it can't re-pull a -cloud-amd64 kernel mid-lab)"
# If it races us and installs a newer cloud kernel, GRUB may default back to the
# cloud flavor on reboot — whose headers/-dbg we don't install — breaking the
# module build and crash analysis.  Disable it before we touch anything.
systemctl disable --now unattended-upgrades.service 2>/dev/null || true
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

log "1. apt sources: add debian-debug (kernel -dbg symbols) + enable deb-src (apt source)"
echo 'deb http://deb.debian.org/debian-debug bookworm-debug main' \
    > /etc/apt/sources.list.d/debian-debug.list
# cloud images ship a deb822 .sources with only 'Types: deb' — add deb-src so
# the article's `apt source linux-image-...` (RUNBOOK §5) works.
if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
fi
apt-get update -qq

log "2. preseed debconf so the two kdump-tools/kexec-tools prompts don't hang"
# The article answers these by hand ("kexec at shutdown? no"; "kdump at boot? yes").
echo 'kdump-tools  kdump-tools/use_kdump   boolean true'  | debconf-set-selections
echo 'kexec-tools  kexec-tools/load_kexec  boolean false' | debconf-set-selections

log "3. install the generic -amd64 kernel + its headers (the article's flavor)"
apt-get install -y --no-install-recommends linux-image-amd64 linux-headers-amd64
# Resolve the concrete generic version the metapackage pulled (e.g. 6.1.0-49-amd64)
GVER="$(apt-cache depends linux-image-amd64 | awk -F'linux-image-' '/Depends: linux-image-[0-9]/{print $2; exit}')"
[ -n "$GVER" ] || { echo "could not resolve generic kernel version"; exit 1; }
echo "generic kernel = $GVER"

log "3b. remove the -cloud-amd64 kernel so GRUB boots the generic one we just installed"
# The cloud image runs a -cloud-amd64 kernel; with both flavors present GRUB can
# default back to cloud (esp. if unattended-upgrades pulled a newer cloud point
# release).  We installed headers + -dbg for the GENERIC flavor only, so the box
# MUST boot generic or the module build (no cloud headers) and `crash` (no cloud
# symbols) fail.  Purge every installed cloud kernel image/headers/meta — generic
# stays installed, so removing the running cloud kernel non-interactively is safe
# (it's in RAM); the next reboot lands on generic.
mapfile -t CLOUD_PKGS < <(dpkg-query -W -f='${Package}\n' 2>/dev/null \
    | grep -E '^linux-(image|headers)-([0-9].*-)?cloud-amd64$' || true)
if [ "${#CLOUD_PKGS[@]}" -gt 0 ]; then
    echo "purging cloud kernel: ${CLOUD_PKGS[*]}"
    apt-get purge -y "${CLOUD_PKGS[@]}"
fi

log "4. install the article's toolchain: build + crash + kdump + matching debug symbols"
# == the article's `apt install gcc make binutils linux-headers-$(uname -r) \
#                    kdump-tools crash $(uname -r)-dbg`, retargeted at $GVER ==
# NOTE: makedumpfile is a *Recommends* of kdump-tools and is what actually writes
# (filters+compresses) /proc/vmcore to disk.  We use --no-install-recommends to
# stay lean, so it MUST be named explicitly — without it the crash kernel logs
# "makedumpfile: not found" and saves a 0-byte dump.  (The article's plain
# `apt install kdump-tools` pulls it in via Recommends.)
apt-get install -y --no-install-recommends \
    gcc make binutils \
    "linux-headers-${GVER}" \
    kdump-tools crash makedumpfile \
    "linux-image-${GVER}-dbg"

log "5. enable panic_on_oops via /etc/default/kdump-tools (article step)"
sed -i 's/^#\?USE_KDUMP=.*/USE_KDUMP=1/' /etc/default/kdump-tools
if grep -q '^#\?KDUMP_SYSCTL=' /etc/default/kdump-tools; then
    sed -i 's|^#\?KDUMP_SYSCTL=.*|KDUMP_SYSCTL="kernel.panic_on_oops=1"|' /etc/default/kdump-tools
else
    echo 'KDUMP_SYSCTL="kernel.panic_on_oops=1"' >> /etc/default/kdump-tools
fi

log "6. enable SysRq via /etc/sysctl.d/99-sysctl.conf (article step)"
# echo 'c' > /proc/sysrq-trigger needs the 'crash' SysRq function enabled.
if [ -f /etc/sysctl.d/99-sysctl.conf ] && grep -q 'kernel.sysrq' /etc/sysctl.d/99-sysctl.conf; then
    sed -i 's/^#\?kernel.sysrq.*/kernel.sysrq=1/' /etc/sysctl.d/99-sysctl.conf
else
    echo 'kernel.sysrq=1' > /etc/sysctl.d/99-sysctl.conf
fi

log "7. set crashkernel=$CRASHKERNEL on the kernel cmdline (article step) + update-grub"
# The article edits /etc/default/grub.d/kdump-tools.default, changing the stock
# 'crashkernel=384M-:128M' to a plain 'crashkernel=128M'.  kdump-tools on bookworm
# ships that line in a grub.d drop-in; rewrite whichever file carries it, else
# write our own drop-in so the value is unambiguous.
KDUMP_GRUB="$(grep -rl 'crashkernel' /etc/default/grub.d/ 2>/dev/null | head -1 || true)"
if [ -n "$KDUMP_GRUB" ]; then
    sed -i "s/crashkernel=[^\" ]*/crashkernel=${CRASHKERNEL}/" "$KDUMP_GRUB"
    echo "patched $KDUMP_GRUB"
else
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT crashkernel=%s"\n' \
        "$CRASHKERNEL" > /etc/default/grub.d/kdump-crashkernel.cfg
    echo "wrote /etc/default/grub.d/kdump-crashkernel.cfg"
fi
update-grub

cat <<EOF

== provisioning complete ==
  generic kernel : $GVER   (debug symbols: /usr/lib/debug/.../vmlinux-$GVER)
  crashkernel    : $CRASHKERNEL
  panic_on_oops  : 1     sysrq : 1     kdump : enabled at boot

NEXT:  sudo reboot
Then verify (RUNBOOK §4): the box must come up on $GVER with the crashkernel
region reserved.  After that, trigger the panic (RUNBOOK §5).
EOF

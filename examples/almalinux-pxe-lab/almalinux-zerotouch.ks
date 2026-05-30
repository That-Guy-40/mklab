# AlmaLinux 9 zero-touch install — throwaway lab posture.
# Rendered per-host by netboot/gen-almalinux-ks.sh; served at /ks/<mac>.ks.
#
# ─── Security posture ────────────────────────────────────────────────────────
# This kickstart is intentionally configured for a throwaway, disposable lab:
#
#   WARNING: uses plaintext lab credentials (root: lab, user: lab).
#   NEVER expose this VM or the server that serves this .ks file to an
#   untrusted network.  Anyone who can reach the nginx server can download
#   the kickstart and learn the root password.
#
#   For real deployments:
#     - Replace --plaintext with --iscrypted and a salted SHA-512 hash:
#         python3 -c "import crypt; print(crypt.crypt('yourpass', crypt.mksalt(crypt.METHOD_SHA512)))"
#     - Restrict nginx to loopback (127.0.0.1) or a private VLAN.
#     - Rotate credentials after the first boot.
#
# ─── Disk layout rationale ───────────────────────────────────────────────────
# The QEMU target VM uses a two-disk boot trick:
#   disk0 (vda) = blank 20 GB qcow2,   bootindex=0  ← Anaconda installs here
#   disk1 (vdb) = ipxe.qcow2 ROM disk, bootindex=1  ← fallback iPXE chainloader
#
# On the first boot, vda has no boot sector so BIOS falls through to vdb (iPXE).
# iPXE fetches this kickstart and boots Anaconda, which installs to vda.
# After the kickstart `reboot`, vda is now bootable and wins the boot race;
# iPXE (vdb) is never reached again.  True zero-touch — no manual disk swap.
#
#   ignoredisk --only-use=vda   ← CRITICAL: prevents Anaconda from wiping vdb
#                                   (the iPXE ROM disk).  Without this, Anaconda
#                                   would overwrite both disks during clearpart.
#
# ─── Package source and integrity ────────────────────────────────────────────
# RPMs are pulled from the upstream AlmaLinux HTTPS mirror at
# repo.almalinux.org.  TLS verification is implicit via curl; Anaconda enforces
# RPM GPG signature checking (gpgcheck=1) by default.  This addresses audit
# finding F2 (unverified downloads) for the package layer.
#
# The installer kernel (vmlinuz) and initrd (initrd.img) are fetched separately
# by examples/almalinux-pxe-lab/fetch-almalinux-installer.sh, which verifies them against
# AlmaLinux's published CHECKSUM file (sha256sum).
# ─────────────────────────────────────────────────────────────────────────────

text
eula --agreed

# Package repository: upstream HTTPS mirror.  Anaconda derives inst.stage2 from
# the url= directive automatically; no separate stage2 server is needed.
url  --url="https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/"
repo --name="AppStream" --baseurl="https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/"

network  --bootproto=dhcp --device=link --activate
firewall --enabled --service=ssh
services --enabled=sshd
timezone Etc/UTC --utc

# Install only to vda (the blank target disk). vdb is the iPXE ROM — never touch it.
ignoredisk --only-use=vda
clearpart  --all --initlabel --drives=vda
autopart   --type=lvm
bootloader --location=mbr --boot-drive=vda --append="console=ttyS0"

# Throwaway lab credentials — consistent with the rest of mklab.
# NEVER expose this VM to an untrusted network.
# Swap --plaintext for --iscrypted (with a SHA-512 hash) for real deployments.
rootpw --plaintext lab
user   --name=lab --password=lab --groups=wheel --plaintext

%packages
@^minimal-environment
openssh-server
%end

# The bootindex=0 target disk now boots; iPXE (bootindex=1) is never reached again.
reboot

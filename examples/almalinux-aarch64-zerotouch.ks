# AlmaLinux 9 zero-touch install — aarch64 variant.
#
# Identical posture to almalinux-zerotouch.ks (throwaway lab credentials,
# two-disk boot-loop) with the following aarch64-specific differences:
#
#   1. Mirror URLs use the aarch64 tree.
#   2. bootloader uses console=ttyAMA0 (PL011 UART on QEMU virt machine)
#      instead of ttyS0 (8250 ISA serial, x86-only).
#   3. boot drive remains vda (QEMU virtio-blk exposes the same device name
#      on all arches; only the UART name differs).
#
# SECURITY WARNING: see almalinux-zerotouch.ks header.  Same throwaway posture.
#
# Workflow (aarch64):
#   1. examples/almalinux-pxe-lab/fetch-almalinux-installer.sh --arch aarch64 --release 9
#      # -> ~/netboot/vmlinuz  ~/netboot/initrd.img (aarch64 binaries)
#
#   2. netboot/gen-almalinux-ks.sh --mac 52:54:00:AA:64:01 [--default]
#      # template = examples/almalinux-aarch64-zerotouch.ks
#
#   3. netboot/build-ipxe.sh --arch aarch64 --server http://10.0.2.2:8181 \
#          --kernel-path /vmlinuz --initrd-path /initrd.img \
#          --append 'inst.stage2=http://10.0.2.2:8181/ inst.repo=https://repo.almalinux.org/almalinux/9/BaseOS/aarch64/os/ inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks inst.text console=ttyAMA0 ip=dhcp'
#
#   4. phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml
#
#   5. phase2-qemu-vm/lab-vm.sh create --config examples/vm-almalinux-aarch64-pxe.toml
#      phase2-qemu-vm/lab-vm.sh start  almalinux-aarch64-pxe

text
eula --agreed

url  --url="https://repo.almalinux.org/almalinux/9/BaseOS/aarch64/os/"
repo --name="AppStream" --baseurl="https://repo.almalinux.org/almalinux/9/AppStream/aarch64/os/"

network  --bootproto=dhcp --device=link --activate
firewall --enabled --service=ssh
services --enabled=sshd
timezone Etc/UTC --utc

ignoredisk --only-use=vda
clearpart  --all --initlabel --drives=vda
autopart   --type=lvm
# aarch64 QEMU virt machine boots via AAVMF (ARM UEFI); autopart creates an
# EFI system partition automatically when UEFI is detected.
bootloader --location=boot --boot-drive=vda --append="console=ttyAMA0"

rootpw --plaintext lab
user   --name=lab --password=lab --groups=wheel --plaintext

%packages
@^minimal-environment
openssh-server
%end

reboot

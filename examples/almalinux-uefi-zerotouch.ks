# AlmaLinux 9 zero-touch install — UEFI variant.
#
# Uses the pxe-install VM backend: no iPXE ROM disk; OVMF (UEFI firmware)
# does network boot directly via QEMU slirp TFTP, fetches ipxe.efi, which
# chainloads Anaconda.  After install, UEFI boots from the EFI partition on vda.
#
# Differences from almalinux-zerotouch.ks (BIOS):
#   - bootloader --location=boot  (UEFI EFI path, not MBR)
#   - autopart creates an EFI System Partition automatically
#   - ignoredisk --only-use=vda   (only the install target; no iPXE ROM disk)
#   - No bootindex=1 fallback disk (UEFI handles network boot natively)
#
# SECURITY WARNING: see almalinux-zerotouch.ks header.  Same throwaway posture.
#
# Workflow (UEFI x86_64):
#   1. netboot/build-ipxe.sh --server http://10.0.2.2:8181 \
#          --kernel-path /vmlinuz --initrd-path /initrd.img \
#          --append 'inst.repo=https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/ inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks inst.text console=ttyS0 ip=dhcp'
#      # ipxe.efi is placed in ~/netboot/ alongside ipxe.usb
#
#   2. netboot/gen-almalinux-ks.sh --mac 52:54:00:UE:FI:01 \
#          --template examples/almalinux-uefi-zerotouch.ks [--default]
#
#   3. phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml
#
#   4. phase2-qemu-vm/lab-vm.sh create --config examples/vm-almalinux-uefi-pxe.toml
#      phase2-qemu-vm/lab-vm.sh start  almalinux-uefi-pxe
#
# For UEFI Secure Boot: add --sign --use-snakeoil to build-ipxe.sh,
# and secure_boot = true to the [[vm]] TOML.

text
eula --agreed

url  --url="https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/"
repo --name="AppStream" --baseurl="https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/"

network  --bootproto=dhcp --device=link --activate
firewall --enabled --service=ssh
services --enabled=sshd
timezone Etc/UTC --utc

# UEFI mode: only the install target disk; no iPXE ROM disk (unlike BIOS variant).
ignoredisk --only-use=vda
clearpart  --all --initlabel --drives=vda
# autopart creates EFI System Partition (ESP) + boot + root LVM when UEFI
# is detected.  No need to declare the ESP explicitly.
autopart   --type=lvm
# UEFI boot loader path (not MBR).
bootloader --location=boot --boot-drive=vda --append="console=ttyS0"

rootpw --plaintext lab
user   --name=lab --password=lab --groups=wheel --plaintext

%packages
@^minimal-environment
openssh-server
%end

reboot

## Cheat-sheet:
##   ## Check config
##   $ packer validate config.pkr.hcl
##   $ packer fmt -check -diff config.pkr.hcl
##
##   ## Build all/everything only
##   PS C:\> ./packer.exe build `
##             -force `
##             -var "build_iso_url=https://cdimage.kali.org/current/kali-linux-YYYY.X-installer-amd64.iso" `
##             -var "build_iso_checksum=sha256:5723d46414b45575aa8e199740bbfde49e5b2501715ea999f0573e94d61e39d3" `
##             -except vagrant-cloud `
##             config.pkr.hcl
##
##   ## Build and upload QEMU
##   $ packer build \
##       -force \
##       -var "build_iso_url=https://cdimage.kali.org/current/kali-linux-YYYY.X-installer-amd64.iso" \
##       -var "build_iso_checksum=file:https://kali.download/base-images/current/SHA256SUMS" \
##       -var "cloud_box_version=YYYY.X.Z" \
##       -var "cloud_token=aaa" \
##       -only qemu.kalirolling \
##       config.pkr.hcl
##
## - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
##
## REF:
##   - https://gitlab.alpinelinux.org/alpine/cloud/alpine-cloud-images/-/blob/main/alpine.pkr.hcl
##   - https://github.com/kubernetes-sigs/image-builder/tree/main/images/capi/packer/qemu
##   - https://github.com/maroskukan/packer-cookbook
##   - https://github.com/LKummer/packer-debian
##
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

#
## Plugins
#

packer {
  required_plugins {
    ## REF: https://developer.hashicorp.com/packer/integrations/hashicorp/vagrant
    vagrant = {
      source  = "github.com/hashicorp/vagrant"
      version = "~> 1"
    }

    ## REF: https://developer.hashicorp.com/packer/integrations/hashicorp/hyperv
    hyperv = {
      source  = "github.com/hashicorp/hyperv"
      version = "~> 1"
    }

    ## REF: https://developer.hashicorp.com/packer/integrations/hashicorp/qemu
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1"
    }

    ## REF: https://developer.hashicorp.com/packer/integrations/hashicorp/virtualbox
    virtualbox = {
      source  = "github.com/hashicorp/virtualbox"
      version = "~> 1"
    }

    ## REF: https://developer.hashicorp.com/packer/integrations/hashicorp/vmware
    vmware = {
      source  = "github.com/hashicorp/vmware"
      version = "~> 1"
    }
  }
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

#
## Variables
##   Can be overwritten using cli arguments/flags, or `kali.pkrvars.hcl`
#

variable "build_iso_url" {
  type    = string
  default = ""
}

variable "build_iso_checksum" {
  type    = string
  default = ""
}

variable "build_qemu_accelerator" {
  type    = string
  default = "kvm"
}

variable "build_headless" {
  type    = string
  default = "false"
}

variable "build_ssh_timeout" {
  type    = string
  default = "60m"
}

variable "cloud_box_name" {
  type    = string
  default = "kalilinux/rolling"
}

variable "cloud_box_version" {
  type    = string
  default = ""
}

variable "cloud_token" {
  type      = string
  default   = "${env("VAGRANT_CLOUD_TOKEN")}"
  sensitive = true
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

locals {
  #  ## WHPX workaround: Disabling kernel-irqchip otherwise QEMU will "freeze" when on GRUB boot menu (no input & countdown doesn't move)
  #  ##                  > Qemu stderr: whpx: injection failed, MSI (0, 0) delivery: 0, dest_mode: 0, trigger mode: 0, vector: 0, lost (c0350005)
  #  ## Base command came from ~ https://github.com/hashicorp/packer-plugin-qemu/blob/0594b0d0cc17882e7740ff13ac5c546fd1963690/builder/qemu/step_run.go#L108
  #  ##   Packer doesn't do "-accel [...]", but uses "-machine". qemuargs then overwrites, which would disable hw acc
  #  qemu_args = var.build_qemu_accelerator == "whpx" ? [["-machine", "type=pc,accel=${var.build_qemu_accelerator},kernel-irqchip=off"]] : []
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

## REF: https://developer.hashicorp.com/packer/integrations/hashicorp/hyperv/latest/components/builder/iso
source "hyperv-iso" "kalirolling" {
  ## UEFI (Legacy)
  #boot_command     = [
  #                      "e <wait>",
  #                      "<leftShiftOn><down><down><down><leftShiftOff>",
  #                      "<leftShiftOn><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><leftShiftOff>",
  #                      "<bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs>",
  #                      "locale=en_US ",
  #                      "keymap=us ",
  #                      "hostname=kali ",
  #                      "domain='' ",
  #                      "preseed/url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ",
  #                      "<leftCtrlOn>x<leftCtrlOff>"
  #                   ]
  ## UEFI
  boot_command = [
    "e<wait>",                                                                     # Edit & Let the menu load
    "<leftShiftOn><down><down><down><leftShiftOff>",                               # Down to line starting "linux /". leftShift, otherwise get "2" for each "down"
    "<leftCtrlOn>a<leftCtrlOff>",                                                  # Go to start of line
    "<leftCtrlOn>k<leftCtrlOff>",                                                  # Delete rest of the line (aka all of the line)
    "linux /install.amd/vmlinuz ",                                                 # /boot/grub/grub.cfg: linux    /install.amd/vmlinuz net.ifnames=0 preseed/file=/cdrom/simple-cdd/default.preseed simple-cdd/profiles=kali desktop=xfce vga=788 --- quiet
    "net.ifnames=0 ",                                                              # REF: https://gitlab.com/kalilinux/build-scripts/kali-installer/-/blob/main/simple-cdd/simple-cdd.conf $KERNEL_PARAMS
    "auto=true priority=critical interface=auto debconf/frontend=noninteractive ", # Unattended setup install
    "preseed/url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ",               # ./http/preseed.cfg
    "<f10>",                                                                       # Boot!
  ]
  cpus             = "2"
  generation       = "2"
  headless         = "${var.build_headless}"
  http_directory   = "http"
  iso_checksum     = "${var.build_iso_checksum}"
  iso_url          = "${var.build_iso_url}"
  memory           = "2048"
  shutdown_command = "echo 'packer' | sudo -S shutdown -P now"
  ssh_password     = "vagrant"
  ssh_timeout      = "${var.build_ssh_timeout}"
  ssh_username     = "vagrant"
  switch_name      = "Default Switch" # Internal network
}

## REF: https://developer.hashicorp.com/packer/integrations/hashicorp/qemu/latest/components/builder/qemu
##      https://github.com/hashicorp/packer-plugin-qemu/blob/main/example/build.pkr.hcl
##      https://github.com/hashicorp/packer-plugin-qemu/blob/main/example/source.pkr.hcl
source "qemu" "kalirolling" {
  accelerator        = "${var.build_qemu_accelerator}"
  boot_command       = ["<tab><wait>", " language=en country=US locale=en_US.UTF-8 keymap=us auto=true priority=critical url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg", "<enter>"] # BIOS
  cpus               = "2"                                                                                                                                                                 # var.build_qemu_accelerator == "whpx" ? "1" : "2" # WHPX workaround: Try and reduce the amount of "soft lockup CPU" (Happens between boot menu and Debian installer)
  disk_cache         = "unsafe"
  disk_compression   = true
  disk_detect_zeroes = "unmap"
  disk_discard       = "unmap"
  disk_image         = false
  disk_interface     = "virtio-scsi"
  format             = "qcow2"
  headless           = "${var.build_headless}"
  http_directory     = "http"
  iso_checksum       = "${var.build_iso_checksum}"
  iso_url            = "${var.build_iso_url}"
  memory             = "2048"
  net_device         = "virtio-net"
  shutdown_command   = "echo 'packer' | sudo -S shutdown -P now"
  ssh_password       = "vagrant"
  ssh_timeout        = "${var.build_ssh_timeout}"
  ssh_username       = "vagrant"
  #qemuargs           = local.qemu_args
}

## https://developer.hashicorp.com/packer/integrations/hashicorp/virtualbox/latest/components/builder/iso
source "virtualbox-iso" "kalirolling" {
  ## BIOS (Legacy)
  #boot_command           = ["<esc><wait>", "install <wait>", "preseed/url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ", "locale=en_US ", "keymap=us ", "hostname=kali ", "domain='' ", "<enter>"]
  ## BIOS (Troubleshooting)
  #boot_command           = ["<down><tab><wait>","<bs><bs><bs><bs><bs><bs>", " language=en country=US locale=en_US.UTF-8 keymap=us auto=true priority=critical url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg", "<enter>"] # Text mode, and remove "quiet "
  ## BIOS
  boot_command            = ["<tab><wait>", " language=en country=US locale=en_US.UTF-8 keymap=us auto=true priority=critical url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg", "<enter>"] # BIOS
  cpus                    = "2"
  guest_additions_mode    = "disable"
  guest_os_type           = "Debian_64"
  headless                = "${var.build_headless}"
  http_directory          = "http"
  iso_checksum            = "${var.build_iso_checksum}"
  iso_url                 = "${var.build_iso_url}"
  memory                  = "2048"
  shutdown_command        = "echo 'packer' | sudo -S shutdown -P now"
  ssh_password            = "vagrant"
  ssh_timeout             = "${var.build_ssh_timeout}"
  ssh_username            = "vagrant"
  vboxmanage              = [["modifyvm", "{{ .Name }}", "--clipboard-mode", "bidirectional"], ["modifyvm", "{{ .Name }}", "--draganddrop", "bidirectional"], ["modifyvm", "{{ .Name }}", "--nat-localhostreachable1", "on"]]
  virtualbox_version_file = ""
}

## REF: https://developer.hashicorp.com/packer/integrations/hashicorp/vmware/latest/components/builder/iso
##      https://github.com/hashicorp/packer-plugin-vmware/blob/main/example/sources.pkr.hcl
source "vmware-iso" "kalirolling" {

  boot_command         = ["<tab><wait>", " language=en country=US locale=en_US.UTF-8 keymap=us auto=true priority=critical url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg", "<enter>"] # BIOS
  cpus                 = "2"
  guest_os_type        = "debian10-64" # Alt: debian12-64, debian11-64, other3xlinux-64, otherLinux-64   # REF: https://sanbarrow.com/vmx/vmx-guestos.html
  headless             = "${var.build_headless}"
  http_directory       = "http"
  iso_checksum         = "${var.build_iso_checksum}"
  iso_url              = "${var.build_iso_url}"
  memory               = "2048"
  network              = "nat"
  network_adapter_type = "vmxnet3"
  shutdown_command     = "echo 'packer' | sudo -S shutdown -P now"
  ssh_password         = "vagrant"
  ssh_timeout          = "${var.build_ssh_timeout}"
  ssh_username         = "vagrant"
  vmx_data_post = {
    "ide0:0.clientDevice"   = "TRUE"
    "ide0:0.deviceType"     = "cdrom-raw"
    "ide0:0.fileName"       = "emptyBackingString"
    "ide0:0.present"        = "FALSE"
    "ide0:0.startConnected" = "FALSE"
  }
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

build {
  sources = [
    "source.hyperv-iso.kalirolling",
    "source.qemu.kalirolling",
    "source.virtualbox-iso.kalirolling",
    "source.vmware-iso.kalirolling"
  ]

  provisioner "shell" {
    execute_command = "echo 'vagrant' | {{ .Vars }} sudo -S bash -euxo pipefail '{{ .Path }}'"
    scripts         = ["scripts/vagrant.sh", "scripts/minimize.sh"]
  }

  post-processors {
    ## REF: https://developer.hashicorp.com/packer/integrations/hashicorp/vagrant/latest/components/post-processor/vagrant
    post-processor "vagrant" {
      vagrantfile_template = "Vagrantfile.tpl"

      ## QEMU supports WHPX to build. But LibVirt doesn't support it
      ##   - QEMU   : Linux & Windows
      ##   - LibVirt: Linux only (LibVirt Server/Demon Linux, which runs the VM, Linux only.  LibVirt Client/viewer, which views the VM, Linux & Windows)
      ##   > The libvirt provider supports QEMU artifacts built using any these accelerators: none, kvm, tcg, or hvf.
      ##   REF: https://developer.hashicorp.com/packer/integrations/hashicorp/vagrant/latest/components/post-processor/vagrant#qemulibvirt
      ## WHPX workaround, switching to HyperV as WHPX (Windows Hypervisor Platform) can use it on the backend anyway
      ##   > Valid options are: digitalocean, virtualbox, azure, vmware, libvirt, docker, lxc, scaleway, hyperv, parallels, aws, or google
      ##   REF: https://developer.hashicorp.com/packer/integrations/hashicorp/vagrant/latest/components/post-processor/vagrant#configuration
      provider_override = source.type == "qemu" && var.build_qemu_accelerator == "whpx" ? "hyperv" : ""
    }

    ## REF: https://developer.hashicorp.com/packer/integrations/hashicorp/vagrant/latest/components/post-processor/vagrant-cloud
    post-processor "vagrant-cloud" {
      access_token = "${var.cloud_token}"
      box_tag      = "${var.cloud_box_name}"
      version      = "${var.cloud_box_version}"
      no_release   = "true"
    }
  }
}

# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  ## REF: https://developer.hashicorp.com/vagrant/docs/providers/hyperv/configuration


  ## REF: https://vagrant-libvirt.github.io/vagrant-libvirt/boxes.html
  config.vm.provider :libvirt do |qemu|
    qemu.disk_bus = "virtio"
    qemu.driver = "kvm"
    qemu.video_vram = 256
  end

  ## REF: https://developer.hashicorp.com/vagrant/docs/providers/virtualbox/configuration
  config.vm.provider :virtualbox do |vbox, override|
    vbox.gui = false
    vbox.customize ["modifyvm", :id, "--vram", "128"]
    vbox.customize ["modifyvm", :id, "--graphicscontroller", "vmsvga"]
  end

  ## REF: https://developer.hashicorp.com/vagrant/docs/providers/vmware/configuration
  config.vm.provider :vmware_desktop do |vmware|
    vmware.gui = false
    vmware.vmx["ide0:0.clientdevice"] = "FALSE"
    vmware.vmx["ide0:0.devicetype"] = "cdrom-raw"
    vmware.vmx["ide0:0.filename"] = "auto detect"
  end
end

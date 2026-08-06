# Kali-Vagrant

_[Vagrant](https://developer.hashicorp.com/vagrant): Command line utility for managing the lifecycle of virtual machines. Isolate dependencies and their configuration within a single disposable and consistent environment_.

[Packer](README.packer.md) builds, [Vagrant](README.vagrant.md) runs.

- - -

Vagrant wraps around various hypervisors such as: [Hyper-V](https://developer.hashicorp.com/vagrant/docs/providers/hyperv/boxes), [LibVirt (QEMU)](https://vagrant-libvirt.github.io/vagrant-libvirt/), [VirtualBox](https://developer.hashicorp.com/vagrant/docs/providers/virtualbox/boxes) & [VMware (Desktop)](https://developer.hashicorp.com/vagrant/docs/providers/virtualbox/boxes), allowing you to spin up and access a VM all with a command line interface.

## System Setup

The first thing to do is figure out which virtualization software are we wanting to use:

- Hyper-V _(Windows only)_
- LibVirt (QEMU) _(Linux only)_
- VirtualBox
- VMware (Desktop)

<!--
- QEMU != LibVirt

Recommendations/Summary: QEMU is free & powerful. VirtualBox is free, stable and straightforward. HyperV isn't stable. VMware itself is stable, but the interaction/wrapping at times is flaky
-->

Afterwards, need to install [Vagrant](https://developer.hashicorp.com/vagrant/install?product_intent=vagrant) itself, and any necessary Vagrant plugins.

### Linux Host

If we are using a Debian-based OS and wanting to use LibVirt for QEMU, its straight forward:

```console
$ sudo apt update
[...]
$
$ sudo apt install -y libvirt-daemon
[...]
$
```

_`virt-manager` may be useful if you want a GUI._

<!--
May want to think how the QEMU VMs will run: current user or as "system" (root)

```console
$ ls -lah /var/run/libvirt/libvirt-sock
srw-rw-rw- 1 root root 0 Jul  1 18:22 /var/run/libvirt/libvirt-sock
$

$ sudo usermod -aG libvirt $(whoami)
$

$ systemctl status libvirtd polkit
[...]
$
$ sudo vim /etc/polkit-1/rules.d/49-libvirt.rules
$
$ sudo cat /etc/polkit-1/rules.d/49-libvirt.rules
polkit.addRule(function(action, subject) {
    if (action.id == "org.libvirt.unix.manage" &&
        subject.isInGroup("libvirt")) {
        return polkit.Result.YES;
    }
});
$
```
-->

- - -

If we are wanting VirtualBox, we may want to enable a 3rd party network repository:

```console
$ sudo apt -y install curl sudo gpg
[...]
$
$ curl https://www.virtualbox.org/download/oracle_vbox_2016.asc | sudo gpg --yes --output /usr/share/keyrings/oracle-virtualbox-2016.gpg --dearmor
$
$ echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] https://download.virtualbox.org/virtualbox/debian $(grep -oP '(?<=VERSION_CODENAME=).*' /etc/os-release) contrib" | sudo tee /etc/apt/sources.list.d/virtualbox.list
$
$ sudo apt update
[...]
$
$ sudo apt install -y virtualbox-7.1 linux-headers-$(uname -r)
[...]
$
$ VBOX_VERSION=$(VBoxManage --version | awk -F 'r' '/^[0-9]/ {print $1}')
$
$ curl -OJ "https://download.virtualbox.org/virtualbox/${VBOX_VERSION}/Oracle_VirtualBox_Extension_Pack-${VBOX_VERSION}.vbox-extpack"
[...]
$
$ sudo VBoxManage extpack install ./Oracle_VirtualBox_Extension_Pack-${VBOX_VERSION}.vbox-extpack
[...]
Do you agree to these license terms and conditions (y/n)? y
[...]
Successfully installed "Oracle VirtualBox Extension Pack".
$



## Kali users
$ sudo apt install -y virtualbox virtualbox-ext-pack linux-headers-$(uname -r)
```

<!--
REF: https://tracker.debian.org/pkg/virtualbox
REF: https://fasttrack.debian.net/debian-fasttrack/pool/contrib/v/virtualbox/
  As of 2025-07-01, virtualbox is in unstable & FastTrack

```console
$ sudo /sbin/vboxconfig
vboxdrv.sh: Stopping VirtualBox services.
vboxdrv.sh: Starting VirtualBox services.
vboxdrv.sh: Building VirtualBox kernel modules.
$
```
-->

- - -

If we want to support VMware (Desktop), then we will need to [download VMware Workstation](https://www.vmware.com/products/workstation-player/workstation-player-evaluation.html).

```console
$ chmod 0755 -v VMware-Workstation-*.x86_64.bundle
$
$ sudo ./VMware-Workstation-*.x86_64.bundle
[...]
$
$ sudo apt install -y gcc make linux-headers-$(uname -r)
[...]
$
$ vmware
```

- - -

Finally, to install Vagrant, we can either use the OS package (preferred way), pull down a static binary, or we can trust a 3rd party network repository:

```console
## OS package
$ sudo apt update
[...]
$
$ sudo apt install -y vagrant
[...]
$



## Static Binary
$ curl https://releases.hashicorp.com/vagrant/2.4.7/vagrant_2.4.7_linux_amd64.zip > /tmp/vagrant.zip
[...]
$
$ sudo unzip -o -d /usr/local/bin/ /tmp/vagrant.zip vagrant && rm -v /tmp/vagrant.zip
[...]
$



## Network Repository (recommended way)
$ curl https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
[...]
$
$ echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=VERSION_CODENAME=).*' /etc/os-release) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
[...]
$
$ sudo apt update
[...]
$
$ sudo apt install -y vagrant
[...]
$
```

<!--
- Static binaries needs to be manually updated
- Static binaries may be an AppImage - so may have issues with plugins (needing OS libraries to compile/install)
- Kali is rolling, so needs a static binary (VERSION_CODENAME isn't right)
- If using OS network repo for the source, may be behind if then using 3rd party sources for another (e.g. OS: vagrant, 3rd party: VirtualBox)
-->

<!--
```console
$ apt-cache madison vagrant

$ sudo apt install -t $(grep -oP '(?<=VERSION_CODENAME=).*' /etc/os-release) -y vagrant
```
-->

<!--
TODO:
  - How to setup vagrant plugins (VMware and LibVirt)
    - `$ apt install vagrant-vmware-utility` // `$ vagrant plugin install vagrant-vmware-utility`
    - `$ vagrant plugin install vagrant-libvirt`


```console
$ vagrant plugin install vagrant-libvirt
Installing the 'vagrant-libvirt' plugin. This can take a few minutes...
Fetching xml-simple-1.1.9.gem
Fetching racc-1.8.1.gem
Building native extensions. This could take a while...
Vagrant failed to properly resolve required dependencies. These
errors can commonly be caused by misconfigured plugin installations
or transient network issues. The reported error is:

ERROR: Failed to build gem native extension.

    current directory: /home/debian/.vagrant.d/gems/3.3.8/gems/racc-1.8.1/ext/racc/cparse
/opt/vagrant/embedded/bin/ruby extconf.rb
creating Makefile

current directory: /home/debian/.vagrant.d/gems/3.3.8/gems/racc-1.8.1/ext/racc/cparse
make DESTDIR\= sitearchdir\=./.gem.20250701-16467-vq0cp5 sitelibdir\=./.gem.20250701-16467-vq0cp5 clean
current directory: /home/debian/.vagrant.d/gems/3.3.8/gems/racc-1.8.1/ext/racc/cparse
make DESTDIR\= sitearchdir\=./.gem.20250701-16467-vq0cp5 sitelibdir\=./.gem.20250701-16467-vq0cp5
make failedNo such file or directory - make

Gem files will remain installed in /home/debian/.vagrant.d/gems/3.3.8/gems/racc-1.8.1 for inspection.
Results logged to /home/debian/.vagrant.d/gems/3.3.8/extensions/x86_64-linux/3.3.0/racc-1.8.1/gem_make.out
$


$ vagrant plugin install vagrant-libvirt
[...]
current directory: /home/debian/.vagrant.d/gems/3.3.8/gems/racc-1.8.1/ext/racc/cparse
make DESTDIR\= sitearchdir\=./.gem.20250701-16882-vdg1eh sitelibdir\=./.gem.20250701-16882-vdg1eh
compiling cparse.c
make: gcc: No such file or directory
make: *** [Makefile:244: cparse.o] Error 127
[...]
$

$ vagrant plugin install vagrant-libvirt
[...]
Vagrant failed to install the requested plugin because it depends
on development files for a library which is not currently installed
on this system. The following library is required by the 'vagrant-libvirt'
plugin:

  libvirt

If a package manager is used on this system, please install the development
package for the library. The name of the package will be similar to:

  libvirt-dev or libvirt-devel

After the library and development files have been installed, please
run the command again.
$



$ sudo apt install make gcc libvirt-dev
[...]
$
$ vagrant plugin install vagrant-libvirt
Installing the 'vagrant-libvirt' plugin. This can take a few minutes...
Building native extensions. This could take a while...
Building native extensions. This could take a while...
Fetching formatador-1.1.0.gem
Fetching fog-core-2.6.0.gem
Fetching fog-xml-0.1.5.gem
Fetching fog-json-1.2.0.gem
Fetching fog-libvirt-0.13.2.gem
Fetching diffy-3.4.4.gem
Fetching vagrant-libvirt-0.12.2.gem
Installed the plugin 'vagrant-libvirt (0.12.2)'!
$
```

_May not work if using the static binary_
-->

### Windows Host

If we are on a Windows host we can [enable Hyper-V](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/quick-start/enable-hyper-v), install [VirtualBox](https://www.virtualbox.org/wiki/Downloads) and [VMware Workstation](https://www.vmware.com/products/desktop-hypervisor/workstation-and-fusion).
Please note that in order to run all three software without needing to change any settings you must be using Windows 10 20H1 build 19041.264 or higher or using Windows 11, VMWare 15.5.5 or higher, and VirtualBox 6.0 or higher.

- - -

If you have [Chocolatey](https://chocolatey.org/) installed, we can quickly do VirtualBox and VMware:

```console
PS C:\> choco install virtualbox vmwareworkstation
```

<!-- VirtualBox also needs: Microsoft Visual C++ Redistributable ~ https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170 -->

- - -

For Hyper-V, do either of:

```console
## Windows Desktop (10/11)
PS C:\> Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
PS C:\>
PS C:\> Add-LocalGroupMember -Group "Hyper-V Administrators" -Member "$env:USERNAME"



## Windows Servers
PS C:\> Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart
PS C:\>
PS C:\> Add-LocalGroupMember -Group "Hyper-V Administrators" -Member "$env:USERNAME"
```

- - - -

Finally, we need to [download Vagrant](https://developer.hashicorp.com/vagrant/install), and installed it.

<!--
```console
PS C:\> choco install vagrant
```
-->

- - -

## Released Images

If you don't wish to build your own images, you can use our Pre-Built/Pre-Made/Pre-Generated images, which are hosted on [HashiCorp's Vagrant-Cloud discovery section <!--Marketplace? Store? -->, `kalilinux/rolling`](https://portal.cloud.hashicorp.com/vagrant/discover/kalilinux/rolling):

```console
$ vagrant box add kalilinux/rolling
==> box: Loading metadata for box 'kalilinux/rolling'
    box: URL: https://vagrantcloud.com/api/v2/vagrant/kalilinux/rolling
This box can work with multiple providers! The providers that it
can work with are listed below. Please review the list and choose
the provider you will be working with.

1) hyperv
2) libvirt
3) virtualbox
4) vmware_desktop

Enter your choice: 3
==> box: Adding box 'kalilinux/rolling' (v2025.1.0) for provider: virtualbox
    box: Downloading: https://vagrantcloud.com/kalilinux/boxes/rolling/versions/2025.1.0/providers/virtualbox/amd64/vagrant.box
    box: Calculating and comparing box checksum...
==> box: Successfully added box 'kalilinux/rolling' (v2025.1.0) for 'virtualbox'!
$
$ vagrant box list
kalilinux/rolling (virtualbox, 2025.1.0)
$
$ mkdir -pv vagrant-demo/; cd vagrant-demo/
$
$ vagrant init --force --minimal kalilinux/rolling
[...]
$
$ cat Vagrantfile
# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "kalilinux/rolling"
end
$
$ vagrant up --provider virtualbox
Bringing machine 'default' up with 'virtualbox' provider...
==> default: Importing base box 'test-virtualbox'...
==> default: Generating MAC address for NAT networking...
==> default: Setting the name of the VM: test_default_1751371216586_7953
==> default: Clearing any previously set network interfaces...
==> default: Preparing network interfaces based on configuration...
    default: Adapter 1: nat
==> default: Forwarding ports...
    default: 22 (guest) => 2222 (host) (adapter 1)
==> default: Running 'pre-boot' VM customizations...
==> default: Booting VM...
==> default: Waiting for machine to boot. This may take a few minutes...
    default: SSH address: 127.0.0.1:2222
    default: SSH username: vagrant
    default: SSH auth method: private key
    default:
    default: Vagrant insecure key detected. Vagrant will automatically replace
    default: this with a newly generated keypair for better security.
    default:
    default: Inserting generated public key within guest...
    default: Removing insecure key from the guest if it's present...
    default: Key inserted! Disconnecting and reconnecting using new SSH key...
==> default: Machine booted and ready!
==> default: Checking for guest additions in VM...
==> default: Mounting shared folders...
    default: /tmp/vagrant-demo => /vagrant
$
$ vagrant ssh
Linux kali 6.12.25-amd64 #1 SMP PREEMPT_DYNAMIC Kali 6.12.25-1kali1 (2025-04-30) x86_64

The programs included with the Kali GNU/Linux system are free software;
the exact distribution terms for each program are described in the
individual files in /usr/share/doc/*/copyright.

Kali GNU/Linux comes with ABSOLUTELY NO WARRANTY, to the extent
permitted by applicable law.
┏━(Message from Kali developers)
┃
┃ This is a minimal installation of Kali Linux, you likely
┃ want to install supplementary tools. Learn how:
┃ ⇒ https://www.kali.org/docs/troubleshooting/common-minimum-setup/
┃
┗━(Run: “touch ~/.hushlogin” to hide this message)
┌──(vagrant㉿kali)-[~]
└─$
```

## Self-Generated

Its possible to [build/compile/self-generate](README.packer.md) either stock or custom images, and then use them.
Take the output, `packer_kalirolling_*.box`, and add it into Vagrant before performing the same as above:

```console
$ vagrant box add kali-test ~/kali-packer/packer_kalirolling_libvirt_amd64.box
==> box: Box file was not detected as metadata. Adding it directly...
==> box: Adding box 'kali-test' (v0) for provider:
    box: Unpacking necessary files from: file:///home/kali/kali-packer/packer_kalirolling_libvirt_amd64.box
==> box: Successfully added box 'kali-test' (v0) for ''!
$
$ mkdir -pv ~/vagrant-demo/; cd ~/vagrant-demo/
$
$ vagrant init -f -m kali-test && vagrant up && vagrant ssh
[...]
┌──(vagrant㉿kali)-[~]
└─$
```

<!--
```console
$ vagrant box add --force --provider virtualbox --box-version 1337 --name kali-test kali-linux-rolling-virtualbox-amd64.box
$
$ vagrant box list -i
kali-test     (virtualbox, 0)
  - author: Kali Linux
  - homepage: https://www.kali.org/
  - build-script: https://gitlab.com/kalilinux/build-scripts/kali-vm
  - vagrant-cloud: https://portal.cloud.hashicorp.com/vagrant/discover/kalilinux
$
```
-->

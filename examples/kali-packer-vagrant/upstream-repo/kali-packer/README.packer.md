# Kali-Packer

_[Packer](https://developer.hashicorp.com/packer): A tool that lets you create identical machine images for multiple platforms from a single source template_.

[Packer](README.packer.md) builds, [Vagrant](README.vagrant.md) runs.

- - -

Packer uses "integrations" to support/wrap around various hypervisors such as: [Hyper-V](https://developer.hashicorp.com/packer/integrations/hashicorp/hyperv), [QEMU (LibVirt)](https://developer.hashicorp.com/packer/integrations/hashicorp/qemu), [VirtualBox](https://developer.hashicorp.com/packer/integrations/hashicorp/virtualbox) & [VMware (Desktop)](https://developer.hashicorp.com/packer/integrations/hashicorp/vmware).

Packer starts by automating the system's hypervisor to-do an unattended setup of [Kali Linux](https://www.kali.org/) via [preseeding](https://gitlab.com/kalilinux/recipes/kali-preseed-examples).

Finally Packer, can do various post build items which is necessary for [Vagrant](https://developer.hashicorp.com/packer/integrations/hashicorp/vagrant) to make a Kali "[Base Box](https://developer.hashicorp.com/vagrant/docs/boxes/base)", such as running [shell scripts](https://gitlab.com/kalilinux/build-scripts/kali-packer/-/tree/master/scripts), [re-configuring the VM](https://gitlab.com/kalilinux/build-scripts/kali-packer/-/blob/master/Vagrantfile.tpl) and [uploading the artifacts](https://portal.cloud.hashicorp.com/vagrant/discover/kalilinux).

### Alternatives for CI to Support Vagrant

As Packer requires the hypervisor to be installed, it is very difficult to get Hyper-V support with [GitLab CI SaaS Hosted Runners](https://docs.gitlab.com/ci/runners/hosted_runners/windows/).<!-- The CPU flag for nested virtualization on Google Cloud Platform (GCP) is enabled but KVM module isn't loaded for the containers, nor is the Linux kernel headers sources available to compile any modules, nor wanting to maintain Windows containers. Means we can really only use QEMU without KVM acceleration or self-host a runner. -->

Alternative ways to generate a Virtual Machine (VM) image, without using Packer:

 - [DebOS](https://github.com/go-debos/debos) (Debian OS image builder), wraps around for [FakeMachine](https://github.com/go-debos/fakemachine)
   - Example: [Kali-VM](https://gitlab.com/kalilinux/build-scripts/kali-vm)
 - [FAI](https://fai-project.org/), which uses [fai-diskimage](https://fai-project.org/doc/man/fai-diskimage.html)
   - Example: [Kali-Cloud](https://gitlab.com/kalilinux/build-scripts/kali-cloud) & [Debian's Vagrant Base Box](https://salsa.debian.org/cloud-team/debian-vagrant-images) <!-- Alt: https://wiki.debian.org/Teams/Cloud/VagrantBaseBoxes -->

As a result, for **how Kali generates its Vagrant images, see [Kali-VM](https://gitlab.com/kalilinux/build-scripts/kali-vm/-/blob/main/.gitlab-ci.yml)**.

## Configuration Files

Over the years, there have been various formats and versions when it comes to Packer's configuration files.
Packer's original format was in `*.JSON` using HCL, but since [v1.7.0](https://github.com/hashicorp/packer/releases/tag/v1.7.0) _(2021-02-17)_, become `*.HCL` using [HCL2](https://developer.hashicorp.com/packer/guides/hcl):

- JSON: JavaScript Object Notation
- HCL: HashiCorp Configuration Language

Looking at filenames, it should be possible to identify this:

- `*.pkr.hcl`
  - [HCL2 Configuration](https://developer.hashicorp.com/packer/docs/templates/hcl_templates/syntax)
  - Default, current standard
- `*.pkr.json`
  - [HCL2 Configuration, in JSON](https://developer.hashicorp.com/packer/docs/templates/hcl_templates/syntax-json)
  - Current standard, meant to be programmatically generated
- `*.json`
  - [HCL Configuration](https://developer.hashicorp.com/packer/docs/templates/legacy_json_templates)
  - Original, older standard
  - Other/unofficial names & terms: Legacy JSON, JSON-only, HCL1

You can find Kali's older version in: `./Legacy/`.

## System Setup

<!--

## Benchmarking

- Machine 1 (Linux)  : Intel Xeon E5-1650 v3 @ 3.50 GHz, 128GB DDR4 @ 2133 MHZ, LSI MR9271-4i HDD @ Hardware RAID 10, Debian "Bookworm" 12   (Same as machine 2, just a different OS)
- Machine 2 (Windows): Intel Xeon E5-1650 v3 @ 3.50 GHz, 128GB DDR4 @ 2133 MHZ, LSI MR9271-4i HDD @ Hardware RAID 10, Window Server 2019     (Same as machine 1, just a different OS)
- Machine 3 (Linux)  : AMD Ryzen 9 3900X     @ 3.80 GHz,  16GB DDR4 @ 2666 MHZ, Western Digital WD30EZRX-00D HDD,     Debian "Bookworm" 12
- Machine 4 (Windows): AMD Ryzen 9 3900X     @ 3.80 GHz,  16GB DDR4 @ 2666 MHZ, Samsung 860 QVO SSD,                  Windows 10

### Hyper-V

- Machine 1 (Linux)  : N/A
- Machine 2 (Windows): 16 minutes 40 seconds
- Machine 3 (Linux)  : N/A
- Machine 4 (Windows): 21 minutes 2 seconds

### QEMU

Debian "Bookworm" 12 - QEMU v7.2
Windows *            - QEMU v10.0

- Machine 1 (Linux):
  - none/tcg: 3 hours 32 minutes    (aka Restricted environments - GitLab SaaS hosted runners)
  - kvm     : 39 minutes 46 seconds (aka Privileged environments - GitLab self-hosted runners)
- Machine 2 (Windows):
  - none/tcg: 2 hours 46 minutes
  - whpx    : 36 minutes 15 seconds
- Machine 3 (Linux):
  - none/tcg: 1 hour 29 minutes     (aka Restricted environments - GitLab SaaS hosted runners)
  - kvm     : 21 minutes 3 seconds  (aka Privileged environments - GitLab self-hosted runners)
- Machine 4 (Windows):
  - none/tcg: 1 hour 50 minutes
  - whpx    : Fails =(

### VirtualBox

VirtualBox 7.1.10 r169112 (Qt6.5.3) // 7.1.10-dfsg-1 (7.1.10_Debianr169112)

- Machine 1 (Linux)  : 25 minutes 48 seconds
- Machine 2 (Windows): 41 minutes 44 seconds
- Machine 3 (Linux)  : 22 minutes 6 seconds
- Machine 4 (Windows): 28 minutes 49 seconds

### VMware (Desktop)

VMware Workstation Pro 17.6.2 build-24409262

- Machine 1 (Linux)  : 23 minutes 29 seconds
- Machine 2 (Windows): 22 minutes 50 seconds
- Machine 3 (Linux)  : 38 minutes 23 seconds
- Machine 4 (Windows): 30 minutes 16 seconds
-->

The first thing to do is figure out where we are wanting to create our Packer boxes (for Vagrant) and what platforms we want to support. If we are using a Windows system, we can support Hyper-V, however QEMU performance will be worse than if used on a Linux system. On the flip side, if we are on a Linux system, we won't be able to support Hyper-V.
<!--
Not 100% true:
  https://www.qemu.org/docs/master/system/i386/hyperv.html
  https://libvirt.org/formatdomain.html#hypervisor-features
 -->

After deciding what our host system will be, we can install [Packer](https://developer.hashicorp.com/packer/install?product_intent=packer), [Vagrant](https://developer.hashicorp.com/vagrant/install?product_intent=vagrant), and our desired virtualization software (Hyper-V, QEMU (LibVirt), VirtualBox and/or VMware (Desktop)).

<!--
- QEMU != LibVirt
- Hyper-V != whpx

Recommendations/Summary: QEMU is free & powerful. VirtualBox is free, stable and straightforward. HyperV isn't stable. VMware itself is stable, but the interaction/wrapping at times is flaky
-->

### Linux Host

If we are using a Debian-based OS and wanting to support QEMU, it is straight forward:

```console
$ sudo apt update
[...]
$
$ sudo apt install -y qemu-system-x86
[...]
$
```

We will have a better time if KVM is accessible, as then we can use hardware acceleration:

```console
$ lsmod | grep '^kvm'
kvm_intel             380928  0
kvm                  1146880  1 kvm_intel
$
$ ls -lah /dev/kvm
crw-rw---- 1 root kvm 10, 232 Jun 30 10:09 /dev/kvm
$
$ sudo usermod -aG kvm $(whoami)
$
$ logout   # And then afterwards, log back in
```

<!--
$ id
uid=1000(debian) gid=1000(debian) groups=1000(debian),4(adm),20(dialout),24(cdrom),25(floppy),27(sudo),29(audio),30(dip),44(video),46(plugdev)
$
$ logout
%
% !ssh
[...]
$
$ id
uid=1000(debian) gid=1000(debian) groups=1000(debian),4(adm),20(dialout),24(cdrom),25(floppy),27(sudo),29(audio),30(dip),44(video),46(plugdev),103(kvm)
$
-->

Happy days!

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

Finally, to install Packer, we can either pull down a static binary, or we can trust a 3rd party network repository (preferred way):

```console
## Static Binary
$ sudo apt -y install unzip
[...]
$
$ curl https://releases.hashicorp.com/packer/1.13.1/packer_1.13.1_linux_amd64.zip > /tmp/packer.zip
[...]
$
$ sudo unzip -o -d /usr/local/bin/ /tmp/packer.zip packer && rm -v /tmp/packer.zip
[...]
$



## Network Repository (recommended way)
$ sudo apt -y install curl sudo gpg
[...]
$
$ curl https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
[...]
$
$ echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=VERSION_CODENAME=).*' /etc/os-release) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
[...]
$
$ sudo apt update
[...]
$
$ sudo apt install -y packer
[...]
$
```

<!--
- Static binaries needs to be manually updated
- Static binaries may be an AppImage - so may have issues with plugins (needing OS libraries to compile/install)
- Kali is rolling, so needs a static binary (VERSION_CODENAME isn't right)
- If using OS network repo for the source, may be behind if then using 3rd party sources for another (e.g. OS: vagrant, 3rd party: VirtualBox)
-->

### Windows Host

If we are on a Windows host we can [enable Hyper-V](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/quick-start/enable-hyper-v), install [VirtualBox](https://www.virtualbox.org/wiki/Downloads and [VMware Workstation](https://www.vmware.com/products/desktop-hypervisor/workstation-and-fusion).
Please note that in order to run all three software without needing to change any settings, you must be using Windows 10 20H1 build 19041.264 or higher or using Windows 11, VMWare 15.5.5 or higher, and VirtualBox 6.0 or higher.

QEMU is also possible.

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

<!--
Otherwise, you get:

```plaintext
hyperv-iso.kalirolling: Failed creating Hyper-V driver: PS Hyper-V module is not loaded. Make sure Hyper-V feature is on.
```

- - -

Had issues with switch not getting created, not sure if the following fixed it (or the restart):

```console
PS C:\> Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V,VirtualMachinePlatform -All
```

Didn't have it on Windows 10, but Windows Server 2019:

```plaintext
==> hyperv-iso.kalirolling: Error getting host adapter ip address: No ip address.
```

Windows 10, has "Default Switch" set to "Default Network". Windows Server 2019 doesn't have a default switch.
Manually setup switch and add DHCP:

```console
PS C:\> Install-WindowsFeature -Name 'DHCP' -IncludeManagementTools
[...]
PS C:\>
PS C:\> New-VMSwitch -Name "Default Switch" -SwitchType Internal

Name           SwitchType NetAdapterInterfaceDescription
----           ---------- ------------------------------
Default Switch Internal

PS C:\>
PS C:\> Get-VMSwitch

Name           SwitchType NetAdapterInterfaceDescription
----           ---------- ------------------------------
Default Switch Internal

PS C:\>
PS C:\> (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "vEthernet (Default Switch)").IPAddress
192.168.100.1
PS C:\>
PS C:\> Add-DhcpServerv4Scope `
          -Name "LAB" `
          -StartRange 192.168.100.50 `
          -EndRange 192.168.100.200 `
          -SubnetMask 255.255.255.0 `
          -State Active

PS C:\>
PS C:\> Set-DhcpServerv4OptionValue `
          -ScopeId 192.168.100.0 `
          -Router 192.168.100.1 `
          -DnsServer 8.8.8.8 `
          -DnsDomain "lab.local"
PS C:\>
PS C:\> Get-DhcpServerv4Scope

ScopeId         SubnetMask      Name           State    StartRange      EndRange        LeaseDuration
-------         ----------      ----           -----    ----------      --------        -------------
192.168.100.0   255.255.255.0   LAB            Active   192.168.100.50  192.168.100.200 8.00:00:00

PS C:\>
```
-->

- - -

If we choose to try and support QEMU we can also install [QEMU](https://www.qemu.org/download/#windows). If we do so, we will have to later change the variable `build_qemu_accelerator` , to be a different accelerator that is supported on Windows.
For more information, we can consult the Packer documentation on [QEMU building](https://developer.hashicorp.com/packer/integrations/hashicorp/qemu/latest/components/builder/qemu#optional:).
During our testing we found the following work: `tcg` (preferred as stable and [easier to setup](https://gitlab.com/qemu-project/qemu/-/work_items/346)) and `whpx` (quicker, but not as stable).

<!--
```console
PS C:\> choco install Qemu
```
-->

```console
PS C:\> & "C:\Program Files\qemu\qemu-system-x86_64.exe" -accel ?
Accelerators supported in QEMU binary:
tcg
whpx
PS C:\>
```

Make sure to add QEMU to PATH:

```console
PS C:\> set PATH="%PATH%;C:\Program Files\qemu\"
PS C:\>
PS C:\> setx PATH "%PATH%;C:\Program Files\qemu"
SUCCESS: Specified value was saved.
PS C:\>
```

<!--
```console
PS C:\> systeminfo | findstr /B /C:"OS Name" /C:"OS Version"
OS Name:                   Microsoft Windows Server 2019 Standard Evaluation
OS Version:                10.0.17763 N/A Build 17763
PS C:\>
PS C:\> Get-CimInstance -ClassName Win32_Processor | Select-Object -Property Name, VirtualizationFirmwareEnabled

Name                                      VirtualizationFirmwareEnabled
----                                      -----------------------------
Intel(R) Xeon(R) CPU E5-1650 v3 @ 3.50GHz                          True


PS C:\>
PS C:\> Get-WindowsOptionalFeature -Online | Where-Object {$_.FeatureName -like "*Hyper-V*" -or $_.FeatureName -like "*Platform*"}


FeatureName : Microsoft-Hyper-V
State       : Disabled

FeatureName : Microsoft-Hyper-V-Offline
State       : Disabled

FeatureName : Microsoft-Hyper-V-Online
State       : Disabled

FeatureName : RSAT-Hyper-V-Tools-Feature
State       : Disabled

FeatureName : Microsoft-Hyper-V-Management-Clients
State       : Disabled

FeatureName : Microsoft-Hyper-V-Management-PowerShell
State       : Disabled

FeatureName : HypervisorPlatform
State       : Disabled

FeatureName : VirtualMachinePlatform
State       : Disabled



PS C:\>
PS C:\> qemu-system-x86_64 -accel ?
Accelerators supported in QEMU binary:
tcg
whpx
PS C:\>
PS C:\> & "C:\Program Files\qemu\qemu-system-x86_64.exe" -accel whpx
C:\Program Files\qemu\qemu-system-x86_64.exe: -accel whpx: Could not load library WinHvPlatform.dll.
C:\Program Files\qemu\qemu-system-x86_64.exe: -accel whpx: failed to initialize whpx: Function not implemented
PS C:\>
PS C:\> Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All
Do you want to restart the computer to complete this operation now?
[Y] Yes  [N] No  [?] Help (default is "Y"): Y

PS C:\> & "C:\Program Files\qemu\qemu-system-x86_64.exe" -accel whpx
C:\Program Files\qemu\qemu-system-x86_64.exe: -accel whpx: WHPX: No accelerator found, hr=00000000
C:\Program Files\qemu\qemu-system-x86_64.exe: -accel whpx: failed to initialize whpx: No space left on device
PS C:\>
PS C:\> Disable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
[...]
PS C:\>
PS C:\> Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All
Do you want to restart the computer to complete this operation now?
[Y] Yes  [N] No  [?] Help (default is "Y"): Y

PS C:\> & "C:\Program Files\qemu\qemu-system-x86_64.exe" -nographic -accel whpx
Windows Hypervisor Platform accelerator is operational
c[?7l[2J[0mSeaBIOS (version rel-1.16.3-0-ga6ed6b701f0a-prebuilt.qemu.org)


iPXE (http://ipxe.org) 00:03.0 CA00 PCI2.10 PnP PMM+06FD1090+06F31090 CA00



Booting from Hard Disk...
Boot failed: could not read the boot disk
[...]
```

Working (not sure if its because the CPU is Intel and below is AMD?)
-->

<!--
REF: https://gitlab.com/qemu-project/qemu/-/work_items/346
     https://gitlab.com/qemu-project/qemu/-/work_items/1043
     https://gitlab.com/qemu-project/qemu/-/work_items/430
     https://gitlab.com/qemu-project/qemu/-/work_items/2877

Starts up, but "frozen" (able to see boot menu, but can't input anything, nor does the countdown move. Like the first frame only?):

```console
PS C:\> systeminfo | findstr /B /C:"OS Name" /C:"OS Version"
OS Name:                   Microsoft Windows 10 Pro N
OS Version:                10.0.19045 N/A Build 19045
PS C:\>
PS C:\> & 'C:\Program Files\qemu\qemu-system-x86_64.exe' `
  -machine type=pc,accel=whpx `
  -drive file=$env:USERPROFILE\kali-vagrant\packer_cache\8368eccf04dc0d8baefaf01921c3580e28d622c7.iso,media=cdrom,if=ide,format=raw
WHPX: setting APIC emulation mode in the hypervisor
Windows Hypervisor Platform accelerator is operational
whpx: injection failed, MSI (0, 0) delivery: 0, dest_mode: 0, trigger mode: 0, vector: 0, lost (c0350005)
```

- - -

Boots, but slooooooow (tcg speeds, if not slower?)

```console
PS C:\> & 'C:\Program Files\qemu\qemu-system-x86_64.exe' `
  -machine type=pc,accel=whpx,kernel-irqchip=off `
  -drive file=$env:USERPROFILE\kali-vagrant\packer_cache\8368eccf04dc0d8baefaf01921c3580e28d622c7.iso,media=cdrom,if=ide,format=raw
Windows Hypervisor Platform accelerator is operational
```

However, will run into other issues such as "watchdog: BUG: soft lockup - CPU#0 stuck for 22s! [kworker]" and "Timed out for waiting the udev queue being empty", between boot menu and installer opening

- - -

- Out of the box, able to boot, if downgrade to QEMU 5.2.0 (v5.2.0-11852-g66075e5998-dirty) aka qemu-w64-setup-20210208.exe // 2021-02-08 ~ https://qemu.weilnetz.de/w64/2021/
  - However, its even slower than whpx with `kernel-irqchip=off` flag been added
- Was previously on QEMU 10.0.0 (v10.0.0-12080-g252feb9469-dirty) aka qemu-w64-setup-20250422.exe // 2025-04-22 ~ https://qemu.weilnetz.de/w64/2025/
  - PS C:\> Get-WmiObject -Class Win32_Processor -ComputerName. | Select-Object -Property Name     AMD Ryzen 9 3900X 12-Core Processor
  - PS C:\> systeminfo | findstr /B /C:"OS Name" /B /C:"OS Version"                                Microsoft Windows 10 Pro N ~ 10.0.19045 N/A Build 19045
  - PS C:\> (Get-Item "C:\Windows\System32\vmms.exe").VersionInfo                                  10.0.19041.1
-->

- - - -

Once we download Packer, we must take note of where `packer.exe` is, as we must move this file to our cloned repository later:

```console
PS C:\> iwr -Uri "https://releases.hashicorp.com/packer/1.13.1/packer_1.13.1_windows_amd64.zip" -OutFile "$env:TEMP\packer.zip"
PS C:\>
PS C:\> tar -xvf "$env:TEMP\packer.zip" -C "." packer.exe
x packer.exe
PS C:\>
PS C:\> rm "$env:TEMP\packer.zip"
PS C:\>
```

<!-- iwr == Invoke-WebRequest -->

<!--
```console
PS C:\> choco install packer
```
-->

- - -

Once everything has been installed, **don't forget to restart**!

## Packer Configuration

After cloning [this repository](https://gitlab.com/kalilinux/build-scripts/kali-packer) locally, we can begin to edit the files so we can build our own Packer boxes (for Vagrant). If we are on Windows, now would be a good time to move `packer.exe` to the directory and install [Git](https://git-scm.com/downloads/win):

```console
$ sudo apt install -y git
[...]
$
$ git clone https://gitlab.com/kalilinux/build-scripts/kali-packer
[...]
$
$ cd kali-packer/
$



PS C:\> git clone https://gitlab.com/kalilinux/build-scripts/kali-packer
[...]
PS C:\>
PS C:\> cd .\kali-packer\
PS C:\kali-packer>
PS C:\kali-packer> mv "$HOME\Downloads\packer.exe" .
```

- - -

First, we will copy the file `kali.pkrvars.hcl.template` and remove the trailing `.template`, before editing to add the required information to every field:

```console
$ cp -v kali.pkrvars.hcl{.template,}
kali.pkrvars.hcl.template -> kali.pkrvars.hcl
$
$ vim kali.pkrvars.hcl



PS C:\kali-packer> cp kali.pkrvars.hcl.template kali.pkrvars.hcl
PS C:\kali-packer>
PS C:\kali-packer> notepad.exe kali.pkrvars.hcl
```

- - -

We will need to supply a URL for the ISO we want to be used to install our systems and its matching SHA256 checksum hash (to make sure its valid).

For the URL, we recommend either using `https://cdimage.kali.org/current/` (latest version) or `https://cdimage.kali.org/kali-YYYY.X/` (fixed version).

Moving on to the checksum, we can either calculate it locally, or we can trust what is listed on the download page. To locally get the SHA256 sum on Linux, use the command `sha256sum kali-linux-*.iso` and on Windows we can open a PowerShell terminal and use the command `Get-FileHash kali.iso` (be sure to replace `kali.iso` with the correct ISO filename):

```console
$ curl -s -L https://cdimage.kali.org/current/SHA256SUMS | grep "kali-linux-.*-installer-amd64\.iso$"
5723d46414b45575aa8e199740bbfde49e5b2501715ea999f0573e94d61e39d3  kali-linux-YYYY.X-installer-amd64.iso
$
$ sha256sum kali-linux-YYYY.X-installer-amd64.iso
5723d46414b45575aa8e199740bbfde49e5b2501715ea999f0573e94d61e39d3  kali-linux-YYYY.X-installer-amd64.iso
$



PS C:\> (iwr -Uri "https://cdimage.kali.org/current/SHA256SUMS" -UseBasicParsing).Content -split "`r?`n" | Select-String "kali-linux-.*-installer-amd64\.iso$"

5723d46414b45575aa8e199740bbfde49e5b2501715ea999f0573e94d61e39d3  kali-linux-YYYY.X-installer-amd64.iso

PS C:\>
PS C:\> Get-FileHash -Algorithm SHA256 kali-linux-YYYY.X-installer-amd64.iso

Algorithm       Hash                                                                   Path
---------       ----                                                                   ----
SHA256          5723D46414B45575AA8E199740BBFDE49E5B2501715EA999F0573E94D61E39D3       C:\kali-linux-YYYY.X-installer-amd64.iso


PS C:\>
```

- - -

We also supply a [cloud token](https://developer.hashicorp.com/vagrant/vagrant-cloud/users/authentication#authentication-tokens) and box that we wish to upload the box to.

**If we are just wanting to create a local box, we can remove these parts and also remove the following from the file `kali.pkrvars.hcl` to prevent attempting to upload**.

## Running the Build

Depending on what system and providers we are building for our command to run the build will be a bit different. The list of [providers](https://developer.hashicorp.com/vagrant/docs/providers) Kali Linux currently supports includes:

- `hyperv-iso.kalirolling`    : Hyper-V _(Windows only)_ <!-- Not 100%! -->
- `qemu.kalirolling`          : QEMU
- `virtualbox-iso.kalirolling`: VirtualBox
- `vmware-iso.kalirolling`    : VMware (Desktop)

For us to use these providers, we can install Packer's plugins:

```console
$ packer init .
Installed plugin github.com/hashicorp/virtualbox v1.1.2 in "/home/kali/.config/packer/plugins/github.com/hashicorp/virtualbox/packer-plugin-virtualbox_v1.1.2_x5.0_linux_amd64"
Installed plugin github.com/hashicorp/vmware v1.1.0 in "/home/kali/.config/packer/plugins/github.com/hashicorp/vmware/packer-plugin-vmware_v1.1.0_x5.0_linux_amd64"
Installed plugin github.com/hashicorp/vagrant v1.1.5 in "/home/kali/.config/packer/plugins/github.com/hashicorp/vagrant/packer-plugin-vagrant_v1.1.5_x5.0_linux_amd64"
Installed plugin github.com/hashicorp/hyperv v1.1.4 in "/home/kali/.config/packer/plugins/github.com/hashicorp/hyperv/packer-plugin-hyperv_v1.1.4_x5.0_linux_amd64"
Installed plugin github.com/hashicorp/qemu v1.1.3 in "/home/kali/.config/packer/plugins/github.com/hashicorp/qemu/packer-plugin-qemu_v1.1.3_x5.0_linux_amd64"
$



PS C:\kali-packer> .\packer.exe init .
[...]
PS C:\kali-packer>
```

<!--
```console
Error: Missing plugins

The following plugins are required, but not installed:

* github.com/hashicorp/virtualbox ~> 1
* github.com/hashicorp/vmware ~> 1
* github.com/hashicorp/vagrant ~> 1
* github.com/hashicorp/hyperv ~> 1
* github.com/hashicorp/qemu ~> 1

Did you run packer init for this project ?
```
-->

- - -

If we wish to build only QEMU we can do the following:

```console
$ packer build -var-file=kali.pkrvars.hcl -except=vagrant-cloud -only=qemu.kalirolling config.pkr.hcl
qemu.kalirolling: output will be in this color.

==> qemu.kalirolling: Retrieving ISO
==> qemu.kalirolling: Trying https://cdimage.kali.org/current/kali-linux-YYYY.X-installer-amd64.iso
==> qemu.kalirolling: Trying https://cdimage.kali.org/current/kali-linux-YYYY.X-installer-amd64.iso?checksum=sha256%3A5723d46414b45575aa8e199740bbfde49e5b2501715ea999f0573e94d61e39d3
    qemu.kalirolling: kali-linux-YYYY.X-installer-amd64.iso 4.17 GiB / 4.17 GiB [===========================================================================================================] 100.00% 1m4s
==> qemu.kalirolling: https://cdimage.kali.org/current/kali-linux-YYYY.X-installer-amd64.iso?checksum=sha256%3A5723d46414b45575aa8e199740bbfde49e5b2501715ea999f0573e94d61e39d3 => /home/kali/.cache/packer/8368eccf04dc0d8baefaf01921c3580e28d622c7.iso
==> qemu.kalirolling: Starting HTTP server on port 8709
==> qemu.kalirolling: Found port for communicator (SSH, WinRM, etc): 4016.
==> qemu.kalirolling: Creating temporary RSA SSH key for instance...
==> qemu.kalirolling: Looking for available port between 5900 and 6000 on 127.0.0.1
==> qemu.kalirolling: Starting VM, booting from CD-ROM
==> qemu.kalirolling: The VM will be run headless, without a GUI. If you want to
==> qemu.kalirolling: view the screen of the VM, connect via VNC without a password to
==> qemu.kalirolling: vnc://127.0.0.1:5946
==> qemu.kalirolling: Waiting 10s for boot...
==> qemu.kalirolling: Connecting to VM via VNC (127.0.0.1:5946)
==> qemu.kalirolling: Typing the boot commands over VNC...
==> qemu.kalirolling: Not using a NetBridge -- skipping StepWaitGuestAddress
==> qemu.kalirolling: Using SSH communicator to connect: 127.0.0.1
==> qemu.kalirolling: Waiting for SSH to become available...
==> qemu.kalirolling: Connected to SSH!
==> qemu.kalirolling: Provisioning with shell script: scripts/vagrant.sh
==> qemu.kalirolling: [sudo] password for vagrant: + mkdir /home/vagrant/.ssh
==> qemu.kalirolling: + wget -O /home/vagrant/.ssh/authorized_keys https://raw.githubusercontent.com/hashicorp/vagrant/master/keys/vagrant.pub
==> qemu.kalirolling: --2025-07-01 12:23:26--  https://raw.githubusercontent.com/hashicorp/vagrant/master/keys/vagrant.pub
==> qemu.kalirolling: Resolving raw.githubusercontent.com (raw.githubusercontent.com)... 185.199.108.133, 185.199.109.133, 185.199.110.133, ...
==> qemu.kalirolling: Connecting to raw.githubusercontent.com (raw.githubusercontent.com)|185.199.108.133|:443... connected.
==> qemu.kalirolling: HTTP request sent, awaiting response... 200 OK
==> qemu.kalirolling: Length: 409 [text/plain]
==> qemu.kalirolling: Saving to: ‘/home/vagrant/.ssh/authorized_keys’
==> qemu.kalirolling:
==> qemu.kalirolling:      0K                                                       100% 9.65M=0s
==> qemu.kalirolling:
==> qemu.kalirolling: 2025-07-01 12:23:26 (9.65 MB/s) - ‘/home/vagrant/.ssh/authorized_keys’ saved [409/409]
==> qemu.kalirolling:
==> qemu.kalirolling: + chmod 0700 /home/vagrant/.ssh/
==> qemu.kalirolling: + chmod 0600 /home/vagrant/.ssh/authorized_keys
==> qemu.kalirolling: + chown -R vagrant:vagrant /home/vagrant/.ssh/
==> qemu.kalirolling: + echo 'vagrant ALL=(ALL) NOPASSWD: ALL'
==> qemu.kalirolling: + chmod 0440 /etc/sudoers.d/vagrant
==> qemu.kalirolling: + echo 'UseDNS no'
==> qemu.kalirolling: + echo -e 'auto eth0\niface eth0 inet dhcp'
==> qemu.kalirolling: Provisioning with shell script: scripts/minimize.sh
==> qemu.kalirolling: ++ df --sync -kP /
==> qemu.kalirolling: ++ tail -n1
==> qemu.kalirolling: ++ awk -F ' ' '{print $4}'
==> qemu.kalirolling: + count=22056808
==> qemu.kalirolling: + count=22056807
==> qemu.kalirolling: + dd if=/dev/zero of=/tmp/whitespace bs=1M count=22056807
==> qemu.kalirolling: dd: error writing '/tmp/whitespace': No space left on device
==> qemu.kalirolling: dd exit code 1 is suppressed
==> qemu.kalirolling: 987+0 records in
==> qemu.kalirolling: 986+0 records out
==> qemu.kalirolling: 1034731520 bytes (1.0 GB, 987 MiB) copied, 0.477535 s, 2.2 GB/s
==> qemu.kalirolling: + echo 'dd exit code 1 is suppressed'
==> qemu.kalirolling: + rm /tmp/whitespace
==> qemu.kalirolling: ++ df --sync -kP /boot
==> qemu.kalirolling: ++ tail -n1
==> qemu.kalirolling: ++ awk -F ' ' '{print $4}'
==> qemu.kalirolling: + count=22056808
==> qemu.kalirolling: + count=22056807
==> qemu.kalirolling: + dd if=/dev/zero of=/boot/whitespace bs=1M count=22056807
==> qemu.kalirolling: dd: error writing '/boot/whitespace': No space left on device
==> qemu.kalirolling: 23486+0 records in
==> qemu.kalirolling: 23485+0 records out
==> qemu.kalirolling: 24626249728 bytes (25 GB, 23 GiB) copied, 12.0282 s, 2.0 GB/s
==> qemu.kalirolling: dd exit code 1 is suppressed
==> qemu.kalirolling: + echo 'dd exit code 1 is suppressed'
==> qemu.kalirolling: + rm /boot/whitespace
==> qemu.kalirolling: + set +e
==> qemu.kalirolling: ++ /sbin/blkid -o value -l -s UUID -t TYPE=swap
==> qemu.kalirolling: + swapuuid=63fd64d2-613a-4329-b715-59079d67627f
==> qemu.kalirolling: + case "$?" in
==> qemu.kalirolling: + set -e
==> qemu.kalirolling: + '[' x63fd64d2-613a-4329-b715-59079d67627f '!=' x ']'
==> qemu.kalirolling: ++ readlink -f /dev/disk/by-uuid/63fd64d2-613a-4329-b715-59079d67627f
==> qemu.kalirolling: + swappart=/dev/sda5
==> qemu.kalirolling: + /sbin/swapoff /dev/sda5
==> qemu.kalirolling: + dd if=/dev/zero of=/dev/sda5 bs=1M
==> qemu.kalirolling: dd: error writing '/dev/sda5': No space left on device
==> qemu.kalirolling: 2046+0 records in
==> qemu.kalirolling: 2045+0 records out
==> qemu.kalirolling: 2144337920 bytes (2.1 GB, 2.0 GiB) copied, 1.10556 s, 1.9 GB/s
==> qemu.kalirolling: dd exit code 1 is suppressed
==> qemu.kalirolling: + echo 'dd exit code 1 is suppressed'
==> qemu.kalirolling: + /sbin/mkswap -U 63fd64d2-613a-4329-b715-59079d67627f /dev/sda5
==> qemu.kalirolling: Setting up swapspace version 1, size = 2 GiB (2144333824 bytes)
==> qemu.kalirolling: no label, UUID=63fd64d2-613a-4329-b715-59079d67627f
==> qemu.kalirolling: + sync
==> qemu.kalirolling: Gracefully halting virtual machine...
==> qemu.kalirolling: Converting hard drive...
==> qemu.kalirolling: Running post-processor:  (type vagrant)
==> qemu.kalirolling (vagrant): Creating a dummy Vagrant box to ensure the host system can create one correctly
==> qemu.kalirolling (vagrant): Creating Vagrant box for 'libvirt' provider
==> qemu.kalirolling (vagrant): Copying from artifact: output-kalirolling/packer-kalirolling
==> qemu.kalirolling (vagrant): Using custom Vagrantfile: Vagrantfile.tpl
==> qemu.kalirolling (vagrant): Compressing: Vagrantfile
==> qemu.kalirolling (vagrant): Compressing: box_0.img
==> qemu.kalirolling (vagrant): Compressing: metadata.json
Build 'qemu.kalirolling' finished after 31 minutes.

==> Wait completed after 31 minutes

==> Builds finished. The artifacts of successful builds are:
--> qemu.kalirolling: 'libvirt' provider box: packer_kalirolling_libvirt_amd64.box
$
$ ls -lah *.box
-rw-r--r-- 1 kali kali 5.7G Jul  1 16:46 packer_kalirolling_libvirt_amd64.box
$



PS C:\kali-packer> .\packer.exe build -var-file .\kali.pkrvars.hcl -except=vagrant-cloud -only="qemu.kalirolling" .\config.pkr.hcl
[...]
PS C:\kali-packer>
```

<!--
Files may be cached to: `./packer_cache/` (static binary)



## Debug packer

PS C:\kali-packer> $env:PACKER_LOG=1
PS C:\kali-packer> .\packer.exe build [...]

$ PACKER_LOG=1 packer build [...]



## Debug Kali install/installer/setup

> EnableEscapeCommandline: `~C` escape key
  [enter down] [enter up] [shift down] [`] [c] [shift up]
  new line -> ~ + C
  - new line: [enter down] [enter up]
  - `~` [shift down] [`]
  - `C` [c]  (Shift should still be down from last time)
% ssh -L 5900:127.0.0.1:5946 [...]
$ ss -antup | grep :5946

% open vnc://:@127.0.0.1:5900    # Or use something like RealVNC

CTRL + ALT + F2   (osx/macOS: Fn + Cmd + F2    == Fn/Function/Globe // Cmd/Command)
# tail -f /var/log/syslog
# nc <IP> 1337 -e /bin/sh

$ nc -lvp 1337

# mount --bind /dev /target/dev
# mount --bind /sys /target/sys
# mount --bind /proc /target/proc
# id   #> uid=0(root) gid=0(root)
# chroot /target
# id   #> uid=0(root) gid=0(root) groups=0(root)
# #python -c 'import pty; pty.spawn("/bin/bash")' # > "out of pty devices" (on VNC/stderr)
-->

- - -

Or if we wish to build all but Hyper-V:

```console
$ packer build -var-file=kali.pkrvars.hcl -except=hyperv-iso.kalirolling,vagrant-cloud config.pkr.hcl



PS C:\kali-packer> .\packer.exe build -var-file .\kali.pkrvars.hcl -except="hyperv-iso.kalirolling,vagrant-cloud" .\config.pkr.hcl
```

- - -

If we want to force a rebuild of VirtualBox, headless (without GUI), and use cli arguments for variables:

```console
$ packer build \
    -force \
    -var "build_iso_url=https://cdimage.kali.org/current/kali-linux-YYYY.X-installer-amd64.iso" \
    -var "build_iso_checksum=sha256:5723d46414b45575aa8e199740bbfde49e5b2501715ea999f0573e94d61e39d3" \
    -var "build_headless=true" \
    -except=vagrant-cloud \
    -only=virtualbox-iso.kalirolling \
    config.pkr.hcl



PS C:\kali-packer> .\packer.exe build `
    -force `
    -var "build_iso_url=https://cdimage.kali.org/current/kali-linux-YYYY.X-installer-amd64.iso" `
    -var "build_iso_checksum=sha256:5723d46414b45575aa8e199740bbfde49e5b2501715ea999f0573e94d61e39d3" `
    -var "build_headless=true" `
    -except=vagrant-cloud `
    -only="virtualbox-iso.kalirolling" `
    config.pkr.hcl
```

- - -

On Windows if we wish to only build Hyper-V:

```console
PS C:\kali-packer> .\packer.exe build -var-file .\kali.pkrvars.hcl -except=vagrant-cloud -only="hyperv-iso.kalirolling" .\config.pkr.hcl
```

- - -

Or if we wish to build everything:

```console
PS C:\kali-packer> .\packer.exe build -var-file .\kali.pkrvars.hcl -except=vagrant-cloud .\config.pkr.hcl
```

- - -

These are just some examples, to provide an idea of what flags are necessary to choose providers and how to build them.

The output, `*.box`, can then be passed over to [Vagrant](README.vagrant.md).

## Uploading the Build

Same as above, expect we need to drop `-except=vagrant-cloud` and make sure `cloud_token` variable is set. A token can be created [here](https://developer.hashicorp.com/vagrant/vagrant-cloud/users/authentication#authentication-tokens).

### Running the Build (Headless VirtualBox)

To run headless builds of VirtualBox, you will need to ensure you have the VirtualBox Extension Pack installed and then set `build_headless` variable to true in either `kali.pkrvars.hcl` or `-var "build_headless=true"`.

## Misc Notes

- `build_ssh_timeout` variable can be extended if the systems are running slow (Using `tcg`), as that will allow for more time during the installation step and prevent Packer from erroring out.
- For VMware (Desktop), if the last stage is `Starting virtual machine...` and never you never see `Connecting to VNC`, so the GRUB boot menu finishes the 30 second timeout and boots into Speech Synthesis setup, [reinstall VMware workstation](https://github.com/hashicorp/packer-plugin-vmware/-/work_items/84#issuecomment-1281225953) (uninstall, reboot, install). <!-- Alt: https://github.com/hashicorp/packer/-/work_items/982#issuecomment-231186161    Something else to try, make sure 3D Acceleration is globally enabled-->
- For Hyper-V, we build using the default network switch but do not enforce this when pulling it from Vagrant Cloud. The user will choose which option works best for them if they have multiple switches.
- We use Hyper-V generation 2 for our images as generation 1 has been known to have problems that are corrected in generation 2.
- If the setup "hangs" during the "Configure the network" stage, without a button or progress bar, check any Firewalls configurations. <!-- Windows & VMware -->
- For advance users, it is possible to customize package selections, choose a different desktop environment, or be used to change system settings such as language or keymapping.
  - This can be done either by manually installing Kali or altering the [`preseed.conf` file](https://gitlab.com/kalilinux/build-scripts/kali-packer/-/blob/master/http/preseed.cfg).
  - To perform a manual installation, in `config.pkr.hcl`, adjust a `source`'s by removing/commenting out `boot_command`.
- Under the [`./scripts/` directory](https://gitlab.com/kalilinux/build-scripts/kali-packer/-/tree/master/scripts) there are further adjustments made to the system.
  - These create the Vagrant user, setup SSH, allow for sudo, adjust DHCP, and slim down the VM to have a smaller file size for uploading.
<!--
- The `boot_command` portion of the config can be tweaked depending on needs. By default it will install Kali Linux with all default options selected. For a list of special keys, refer [here](https://developer.hashicorp.com/packer/integrations/hashicorp/vmware/latest/components/builder/iso#boot-configuration).
  - Please note that as of December 2023 there is a [bug which may require the enabling of leftShift](https://github.com/hashicorp/packer/-/work_items/7315) to use certain actions.
 -->

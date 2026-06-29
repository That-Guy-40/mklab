# MANUAL_TESTING — captured transcripts

Real output from building and verifying this lab end-to-end on the host (Linux +
QEMU/KVM, real FreeBSD 14.3). Trimmed for length, never edited. The honest split:
**Parts 1–6 are machine-verified**; the **client Anaconda install is author-run**
(wired + documented, not executed in the build session — see the note at the end).

| Check | Status |
|---|---|
| FreeBSD `BASIC-CLOUDINIT` qcow2 downloads + boots (KVM) | ✅ |
| nuageinit applies ssh key + hostname; ssh in as `freebsd` | ✅ |
| nuageinit does **not** do `packages:`/`runcmd:`/`write_files:` | ✅ (documented) |
| root via `su` (chpasswd) → passwordless `sudo` | ✅ |
| `pkg install nginx cdrtools sudo` | ✅ |
| nginx serves the AlmaLinux tree over HTTP (autoindex, real `repodata`) | ✅ |
| `kickstart.sh` → rendered `ks.cfg` + `OEMDRV` ISO (Linux **and** FreeBSD) | ✅ |
| `ksvalidator -v RHEL9` on the rendered kickstart | ✅ VALID |
| AlmaLinux client Anaconda install from the FreeBSD repo | 📝 author-run |

---

## FreeBSD boots and is driveable

```
$ qemu-img info FreeBSD-14.3-cloudinit-ufs.qcow2 | grep -i 'virtual size'
virtual size: 6.03 GiB (6477709312 bytes)

$ ssh -p 2222 -i id_lab freebsd@127.0.0.1 'uname -srm; hostname; whoami'
FreeBSD 14.3-RELEASE-p15 amd64
www
freebsd
```

## It's nuageinit, not cloud-init

```
$ ssh ... freebsd@127.0.0.1 'ls /var/log/cloud-init*.log 2>&1; ls -l /usr/libexec/nuageinit; sysrc -n nuageinit_enable; ifconfig -l'
ls: /var/log/cloud-init*.log: No such file or directory      # no cloud-init at all
-r-xr-xr-x  1 root wheel 9910 Jun  6 2025 /usr/libexec/nuageinit
YES
vtnet0 lo0

# proof it ignored packages/runcmd/write_files: nginx absent, /etc/rc.local never written
$ ssh ... freebsd@127.0.0.1 'pkg info | grep -ci nginx; ls /etc/rc.local 2>&1'
0
ls: /etc/rc.local: No such file or directory
```

## Root via su (chpasswd) → passwordless sudo

```
# su driven over a PTY (su reads the password from the tty); password: freebsd
# the one privileged bootstrap: install sudo + a NOPASSWD sudoers drop-in
$ ssh -p 2222 -i id_lab freebsd@127.0.0.1 'sudo -n id'
uid=0(root) gid=0(wheel) groups=0(wheel),5(operator)
```

## Provisioned: nginx + mkisofs

```
$ ssh ... freebsd@127.0.0.1 'which mkisofs sudo; pgrep -x nginx >/dev/null && echo nginx-running'
/usr/local/bin/mkisofs
/usr/local/bin/sudo
nginx-running
```

## FreeBSD serves a real AlmaLinux repo over HTTP

```
$ ssh ... freebsd@127.0.0.1 'fetch -qo - http://localhost/almalinux/9/PROBE'
hello-from-freebsd-nginx

# real upstream BaseOS repodata, dropped in and served back:
$ ssh ... freebsd@127.0.0.1 'fetch -qo - http://localhost/almalinux/9/BaseOS/x86_64/os/repodata/repomd.xml | grep -c "<data type="'
8
$ ssh ... freebsd@127.0.0.1 'ls -lh /usr/local/www/nginx/almalinux/9/BaseOS/x86_64/os/repodata/'
-rw-r--r--  1 root wheel  9.4M  ...-primary.xml.gz
-rw-r--r--  1 root wheel  3.8K  repomd.xml
```

## The templating engine — render, build, validate

On the Linux host:

```
$ cd templating && sh kickstart.sh
INFO: kickstart config copied to 'files/kickme.config' location
INFO: kickstart file 'files/kickme.cfg' generated
INFO: ISO image 'iso/kickme.oemdrv.iso' generated

$ grep -E 'url --url|network --bootproto|server .* iburst' files/kickme.cfg
url --url=http://10.0.10.210/almalinux/9/BaseOS/x86_64/os
network --bootproto=static --device=enp0s3 --ip=10.0.10.199 --netmask=255.255.255.0 --gateway=10.0.10.1 --nameserver=1.1.1.1,9.9.9.9 --noipv6 --activate
server 132.163.97.6 iburst

$ isoinfo -d -i iso/kickme.oemdrv.iso | grep -i 'volume id'
Volume id: OEMDRV
$ isoinfo -f -i iso/kickme.oemdrv.iso
/KS.CFG;1

$ ksvalidator -v RHEL9 files/kickme.cfg && echo VALID
VALID
```

The **same `kickstart.sh` on the real FreeBSD VM** (BSD `sed`, cdrtools `mkisofs`)
produces an identical OEMDRV ISO:

```
www$ cd ~/templating && sh kickstart.sh
INFO: ISO image 'iso/kickme.oemdrv.iso' generated
www$ isoinfo -d -i iso/kickme.oemdrv.iso | grep -i 'volume id'
Volume id: OEMDRV
www$ sed --version          # confirms BSD sed, not GNU
sed: illegal option -- -
```

---

## Author-run: the client Anaconda install

The final hop — `run-kickme-client.sh` booting an AlmaLinux VM that installs
unattended from the FreeBSD box — was **not executed in the build session**. It is
shipped ready-to-run and documented ([RUNBOOK Part 6](RUNBOOK.md#part-6--boot-the-client-anaconda-installs-unattended-author-run)),
and the Anaconda-kickstart install mechanics it relies on are themselves verified
end-to-end in this repo:

- [`../almalinux-pxe-lab/MANUAL_TESTING.md`](../almalinux-pxe-lab/MANUAL_TESTING.md) — AlmaLinux 9 kickstart install via Anaconda
- [`../rocky-pxe-lab/`](../rocky-pxe-lab/README.md) — the Rocky counterpart

What this lab adds and verifies is everything *upstream* of that install: the
**FreeBSD** server, the HTTP **serving**, and the **`sed` templating → OEMDRV**
pipeline that produces a valid AlmaLinux 9 kickstart.

# WALKTHROUGH — how I actually built this, soup to nuts

This is the **first-person lab journal**: exactly how I stood up a FreeBSD VM,
wrestled its cloud-init (which turned out *not* to be cloud-init), provisioned
nginx, and wired vermaden's `sed` kickstart-templating engine — with a **checkpoint
+ verification command** at every step, and the dead-ends left in on purpose,
because the dead-ends are where the learning is.

It complements the other docs: [RUNBOOK.md](RUNBOOK.md) is the clean by-hand
operational walk; this file is *the story of getting there*, with the warts. Every
command below is one I ran; the outputs are real (trimmed for length).

Conventions: `host$` = my Linux host; `www#` / `www$` = inside the FreeBSD VM
(root / the `freebsd` user). The lab's working dir on the host is
`$WORKDIR` (default `~/freebsd-kickstart-lab`); while building I used
`/media/sqs/COLD_STORAGE/freebsd-kickstart-spike`.

---

## Part 0 — Why this is shaped the way it is

vermaden's tutorial runs the **server on FreeBSD**: nginx serves the RHEL/clone
DVD over HTTP, and the kickstart is handed to Anaconda on a tiny ISO whose volume
label is **`OEMDRV`** (Anaconda auto-mounts any `OEMDRV` volume and reads
`/ks.cfg` from it — no PXE, no `inst.ks=` needed). The clever, reusable bit is the
**templating engine**: one `sed` pass turns a skeleton + a per-host config into a
ready kickstart, then `mkisofs` wraps it.

Two facts forced the design:

1. **FreeBSD can't be an LXD/Incus container** (it isn't Linux), and this repo's
   `phase2-qemu-vm/lab-vm.sh` has **no FreeBSD backend**. So I drive QEMU directly.
2. The server and the install client must share a network. Rather than a
   root-owned bridge, I gave the FreeBSD VM **two NICs**: user-mode slirp (internet
   for `pkg`) + a rootless **`-netdev socket`** L2 segment that the AlmaLinux
   client joins. That mirrors vermaden's two-interface host and needs no root.

---

## Part 1 — Get a FreeBSD image that can be automated

FreeBSD publishes ready VM images. The plain one boots fine but has no
provisioning hook; the **`BASIC-CLOUDINIT`** flavour ships a cloud-init-ish agent,
so I picked that:

```
host$ URL=https://download.freebsd.org/releases/VM-IMAGES/14.3-RELEASE/amd64/Latest/FreeBSD-14.3-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2.xz
host$ curl -fSL -o FreeBSD-14.3-cloudinit-ufs.qcow2.xz "$URL"
host$ xz -dk -T0 FreeBSD-14.3-cloudinit-ufs.qcow2.xz
```

**Checkpoint 1 — image is real and the size makes sense:**

```
host$ ls -lh FreeBSD-14.3-cloudinit-ufs.qcow2.xz   # ~524M compressed
host$ qemu-img info FreeBSD-14.3-cloudinit-ufs.qcow2 | grep -iE 'virtual size|format'
file format: qcow2
virtual size: 6.03 GiB (6477709312 bytes)
```

Always work on an **overlay** so the base image stays pristine and re-runs are
disposable:

```
host$ qemu-img create -f qcow2 -F qcow2 -b FreeBSD-14.3-cloudinit-ufs.qcow2 www-overlay.qcow2 16G
```

---

## Part 2 — Seed it (NoCloud) and first boot

cloud-init-style images read a **NoCloud** datasource: a second disk labelled
`cidata` holding `meta-data` + `user-data`. I generated an ssh key and built the
seed ISO:

```
host$ ssh-keygen -t ed25519 -N '' -f id_lab -C lab@freebsd
host$ cat > meta-data <<EOF
instance-id: freebsd-www-01
local-hostname: www
EOF
host$ cat > user-data <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat id_lab.pub)
chpasswd:
  expire: false
  users:
    - {name: root,    password: freebsd, type: text}
    - {name: freebsd, password: freebsd, type: text}
EOF
host$ genisoimage -quiet -output seed.iso -volid cidata -joliet -rock user-data meta-data
```

Boot headless, serial to a logfile, with an ssh hostfwd so I can poke at it:

```
host$ qemu-system-x86_64 \
    -name freebsd-www -machine q35 -accel kvm -cpu host -m 2048 -smp 2 \
    -drive file=www-overlay.qcow2,if=virtio,format=qcow2 \
    -drive file=seed.iso,if=virtio,format=raw,readonly=on \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
    -device virtio-net-pci,netdev=net0 \
    -display none -serial file:console.log -monitor none &
```

**Checkpoint 2 — it boots and configures itself.** Watch the serial log:

```
host$ tail -f console.log
...
Starting devd.
Updating motd:.
Starting syslogd.
freebsd-update ... Fetching metadata signature for 14.3-RELEASE ...
```

That `freebsd-update` line is important and bit me later (Part 3): the cloud image
runs a **security update on first boot and then REBOOTS**. Note that and move on.

**Checkpoint 3 — I can log in.** The default user is **`freebsd`** (not root; root
ssh is disabled), and my key landed because nuageinit honours
`ssh_authorized_keys`:

```
host$ ssh -p 2222 -i id_lab freebsd@127.0.0.1 'uname -srm; hostname; whoami'
FreeBSD 14.3-RELEASE-p15 amd64
www
freebsd
```

`hostname` is `www` — so the NoCloud `meta-data` was read too. Good.

---

## Part 3 — The cloud-init that isn't: meeting nuageinit

Here is the detour that cost me the most time, and the most useful thing in this
file. I first wrote a normal cloud-config with `packages:` and `runcmd:` to install
nginx. **It silently did nothing.** No packages, no logs:

```
www$ pkg info | grep -i nginx          # nothing
www$ ls /var/log/cloud-init*.log       # No such file or directory
```

No `cloud-init` logs **at all** — yet the ssh key and hostname worked. That's the
tell: this image does **not** run cloud-init. It runs FreeBSD's native
**`nuageinit`**:

```
www$ ls -l /usr/libexec/nuageinit          # -r-xr-x... a 9 KB lua script (flua)
www$ sysrc -n nuageinit_enable             # YES
www$ ifconfig -l                           # vtnet0 lo0   (virtio NIC is vtnet0)
```

I read the agent itself to learn what it actually supports:

```
www$ grep -nE 'cloud-config|public_key|ssh_authorized_keys|write_files|runcmd|os.execute' /usr/libexec/nuageinit
229: if line == "#cloud-config" then        -- it DOES parse cloud-config...
302: if obj.ssh_authorized_keys then        -- ...for ssh keys
355: if obj.ssh_pwauth ~= nil then
367: os.execute(path .. "/" .. ud)          -- non-cloud-config user-data: EXECUTED as a script
```

**What nuageinit reliably does:** `ssh_authorized_keys`, the default user, hostname,
and `chpasswd`. **What it does NOT do dependably:** `packages:`, `runcmd:`,
`write_files:`. I confirmed each the hard way:

- A `#cloud-config` with `write_files:` for `/etc/rc.local` → file never appeared
  (`www$ ls /etc/rc.local` → not found).
- A `user-data` shell script (nuageinit *executes* non-cloud-config user-data,
  line 367) → it failed because the file on the `cidata` ISO wasn't executable:

```
host$ grep -n 'user-data' console.log
141: sh: /media/nuageinit/user-data: Permission denied
142: nuageinit: error executing user-data script: exit
```

Even after `chmod +x` on the script before building the ISO, the **firstboot
`freebsd-update` reboot** (Checkpoint 2) raced/interrupted nuageinit, which runs
**once per instance-id** and does not retry. Two villains, one symptom.

### The recipe that actually works

Stop fighting the agent. Use nuageinit for the *one* thing it does reliably —
**install the ssh key and set passwords (`chpasswd`)** — then provision over SSH:

```
host$ ssh -p 2222 -i id_lab freebsd@127.0.0.1     # key works
www$ groups                                        # freebsd wheel  -> can su
```

`chpasswd` set root's password to `freebsd`, and `freebsd` is in `wheel`, so I can
become root with `su`. `su` insists on a real terminal, so I drove it over a PTY
(a tiny `python3 pty.fork()` that types `freebsd` at the `Password:` prompt). The
*only* thing I do as root via that PTY is bootstrap **passwordless sudo**; after
that, plain `ssh + sudo` works for everything:

```
# (driven over a PTY because su reads the password from the tty)
www# pkg install -y sudo
www# echo 'freebsd ALL=(ALL) NOPASSWD: ALL' > /usr/local/etc/sudoers.d/freebsd
www# chmod 440 /usr/local/etc/sudoers.d/freebsd
```

**Checkpoint 4 — root on tap without a tty:**

```
host$ ssh -p 2222 -i id_lab freebsd@127.0.0.1 'sudo -n id'
uid=0(root) gid=0(wheel) groups=0(wheel),5(operator)
```

> In the shipped lab this is exactly what [`freebsd-server/setup-freebsd.sh`](freebsd-server/setup-freebsd.sh)
> automates (run it as root on the VM); the cloud-config that sets the key +
> password is [`freebsd-server/cloud-init/user-data`](freebsd-server/cloud-init/user-data).
> Lesson worth keeping: **"cloud image" ≠ "cloud-init"; read the agent before you
> trust a directive.**

---

## Part 4 — Provision the server: nginx + mkisofs

Now that `sudo` works, the rest is ordinary FreeBSD admin. `mkisofs` lives in the
`cdrtools` package:

```
host$ S='ssh -p 2222 -i id_lab freebsd@127.0.0.1'
host$ $S 'sudo env ASSUME_ALWAYS_YES=yes pkg install -y nginx cdrtools sudo'
```

**Checkpoint 5 — the three tools the lab needs are present:**

```
host$ $S 'which mkisofs; nginx -v; sudo -n true && echo sudo-ok'
/usr/local/bin/mkisofs
nginx version: nginx/1.28.x
sudo-ok
```

Point nginx at a docroot with **`autoindex on`** (Anaconda/dnf *walk* the repo, so
directory listing must be enabled), enable it, start it:

```
host$ $S 'sudo cp /tmp/nginx.conf /usr/local/etc/nginx/nginx.conf && sudo nginx -t'
nginx: configuration file /usr/local/etc/nginx/nginx.conf test is successful
host$ $S 'sudo sysrc nginx_enable=YES && sudo service nginx restart'
```

**Checkpoint 6 — FreeBSD is serving HTTP:**

```
host$ $S 'echo hello-from-freebsd-nginx | sudo tee /usr/local/www/nginx/almalinux/9/PROBE >/dev/null
          fetch -qo - http://localhost/almalinux/9/PROBE'
hello-from-freebsd-nginx
```

And it serves a **real, dnf-consumable AlmaLinux repo** — I dropped genuine
upstream `repodata` in and fetched it back:

```
host$ $S 'B=/usr/local/www/nginx/almalinux/9/BaseOS/x86_64/os
          sudo mkdir -p $B/repodata
          fetch -qo /tmp/repomd.xml https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/repodata/repomd.xml
          sudo cp /tmp/repomd.xml $B/repodata/
          fetch -qo - http://localhost/almalinux/9/BaseOS/x86_64/os/repodata/repomd.xml | grep -c "<data type="'
8
```

Eight `<data>` sections — a valid `repomd.xml` served off FreeBSD. The full tree is
populated the faithful way (mount the DVD) by
[`fetch-almalinux.sh serve-dvd`](fetch-almalinux.sh).

---

## Part 5 — The templating engine, in detail

This is vermaden's "neat thing", and the part most worth understanding. Three
files (in [`templating/`](templating/)):

- **`kickstart.config`** — a plain shell file of `NAME=value` lines (hostname, the
  repo server IP, the NIC, addresses, NTP servers…).
- **`kickstart.skel`** — a kickstart with **ALL-CAPS tokens** where per-host values
  go: `url --url=http://REPO_SERVER_IP/almalinux/ALMA_MAJOR/BaseOS/ALMA_ARCH/os`,
  `network ... --ip=IP_ADDRESS1 ...`, `server NTP1 iburst`, etc.
- **`kickstart.sh`** — the engine. It `.`-sources the config (so every `NAME`
  becomes a shell variable), then runs **one `sed`** with a `-e s@TOKEN@${TOKEN}@g`
  per variable, writing `files/<SYSTEM_NAME>.cfg`, and finally `mkisofs`-wraps that
  file as `/ks.cfg` on an ISO **labelled `OEMDRV`**:

```sh
. "$(pwd)/kickstart.config"
sed -e s@SYSTEM_NAME@${SYSTEM_NAME}@g \
    -e s@REPO_SERVER_IP@${REPO_SERVER_IP}@g \
    ... one -e per variable ...                 \
    kickstart.skel > files/${SYSTEM_NAME}.cfg
mkisofs -J -R -l -graft-points -V "OEMDRV" \
        -o iso/${SYSTEM_NAME}.oemdrv.iso \
        ks.cfg=files/${SYSTEM_NAME}.cfg ksfloppy
```

Two things make it tick: the **`@` delimiter** for `s` (so the `/` characters in
URLs and paths don't need escaping), and **`-V "OEMDRV"`** + the
**`ks.cfg=files/...` graft-point** (which places the rendered file at `/ks.cfg` on
the ISO). `OEMDRV` is the magic label Anaconda auto-scans.

**Checkpoint 7 — render + build, then prove the substitution and the label:**

```
host$ cd templating && sh kickstart.sh
INFO: kickstart file 'files/kickme.cfg' generated
INFO: ISO image 'iso/kickme.oemdrv.iso' generated

host$ grep -E 'url --url|network --bootproto|server .* iburst' files/kickme.cfg
url --url=http://10.0.10.210/almalinux/9/BaseOS/x86_64/os
network --bootproto=static --device=enp0s3 --ip=10.0.10.199 --netmask=255.255.255.0 ...
server 132.163.97.6 iburst

host$ isoinfo -d -i iso/kickme.oemdrv.iso | grep -i 'volume id'
Volume id: OEMDRV
host$ isoinfo -f -i iso/kickme.oemdrv.iso
/KS.CFG;1
```

**Checkpoint 8 — the rendered kickstart is actually valid** (not just
substituted). `ksvalidator` from `pykickstart` checks it against the AlmaLinux 9
grammar:

```
host$ python3 -m venv venv && . venv/bin/activate && pip install -q pykickstart
host$ ksvalidator -v RHEL9 files/kickme.cfg && echo VALID
VALID
```

**Checkpoint 9 — it's portable to *real* FreeBSD `sed`** (vermaden's engine is
POSIX; FreeBSD's `sed` is BSD `sed`, not GNU). I ran the very same `kickstart.sh`
on the FreeBSD VM:

```
www$ cd ~/templating && sh kickstart.sh
INFO: ISO image 'iso/kickme.oemdrv.iso' generated
www$ isoinfo -d -i iso/kickme.oemdrv.iso | grep -i 'volume id'
Volume id: OEMDRV
www$ sed --version            # proves it's BSD sed, not GNU
sed: illegal option -- -
```

Identical OEMDRV ISO on glibc/GNU and on musl-free BSD `sed`. The templating layer
is genuinely portable — which is *why* you can author kickstarts on your laptop and
build them on the FreeBSD box unchanged.

---

## Part 6 — The install client (ready-to-run; author-run)

The last hop — booting an AlmaLinux VM that installs unattended from the FreeBSD
box — I did **not** run in the build session (it's a multi-GB DVD fetch + a
minutes-long Anaconda run, and this repo already proves the Anaconda-kickstart
mechanics in [`../almalinux-pxe-lab/`](../almalinux-pxe-lab/README.md)). It is
shipped ready-to-run and fully wired:

```
host$ ./run-freebsd-server.sh up                 # FreeBSD server, slirp + socket LAN
host$ # provision it (Part 3-4) + populate the DVD (fetch-almalinux.sh serve-dvd)
host$ ./fetch-almalinux.sh boot-iso              # AlmaLinux boot ISO for the client
host$ ( cd templating && sh kickstart.sh )       # build the OEMDRV ISO
host$ OEMDRV_ISO=templating/iso/kickme.oemdrv.iso ./run-kickme-client.sh
```

The client boots the AlmaLinux **boot ISO** (CD0) with the **OEMDRV ISO** (CD1).
Anaconda finds `OEMDRV`/`ks.cfg` automatically (no `inst.ks=`), brings up the NIC
per the kickstart's `network` line (10.0.10.199 on the socket LAN), and pulls
packages from `http://10.0.10.210/almalinux/9/...` on the FreeBSD box. See
[RUNBOOK.md](RUNBOOK.md#part-6) for the exact steps and the headless-console note,
and [MANUAL_TESTING.md](MANUAL_TESTING.md) for what is machine-verified vs
author-run.

---

## The whole thing, as a checklist

| # | Step | Verify it worked |
|---|------|------------------|
| 1 | Download + decompress the FreeBSD `BASIC-CLOUDINIT` qcow2 | `qemu-img info` shows 6 GiB virtual |
| 2 | Seed (NoCloud `cidata`) + boot headless | serial log shows boot + `freebsd-update` reboot |
| 3 | SSH in as `freebsd` (key from nuageinit) | `ssh … 'whoami'` → `freebsd`, `hostname` → `www` |
| 4 | Realise it's **nuageinit**; provision via `su`→sudo | `ssh … 'sudo -n id'` → `uid=0(root)` |
| 5 | `pkg install nginx cdrtools sudo` | `which mkisofs`; `nginx -v` |
| 6 | nginx `autoindex` serves the repo | `fetch http://localhost/almalinux/9/...repomd.xml` → 8 `<data>` |
| 7 | `kickstart.sh` renders + builds OEMDRV ISO | `isoinfo` → `Volume id: OEMDRV`, `/KS.CFG` |
| 8 | `ksvalidator -v RHEL9` | `VALID` |
| 9 | Same engine on real BSD `sed` | identical OEMDRV ISO on the FreeBSD VM |
| — | Client Anaconda install (author-run) | `run-kickme-client.sh` + RUNBOOK Part 6 |

Steps 1–9 are machine-verified in this lab. Step "—" is the ready-to-run,
documented finish line.

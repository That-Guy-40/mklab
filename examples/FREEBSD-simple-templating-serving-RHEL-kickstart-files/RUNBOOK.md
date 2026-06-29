# RUNBOOK — stand up the FreeBSD kickstart server and install a client, by hand

The clean, operational by-hand walk, with the *why* at each step. For the full
narrated build (and the dead-ends), see [WALKTHROUGH.md](WALKTHROUGH.md); for the
concept, [README.md](README.md). This lab drives **QEMU directly** (no FreeBSD
backend in `lab-vm.sh`); run commands from this directory unless noted.

`$WORKDIR` defaults to `~/freebsd-kickstart-lab`. The host needs QEMU/KVM,
`genisoimage`/`mkisofs`, `xz`, `curl`, OVMF, and `pykickstart` for validation.

## Part 1 — Build the kickstart + OEMDRV ISO (no VM needed)

The templating engine is pure `sed` + `mkisofs`; build first so you understand the
artifact before serving it. Edit [`templating/kickstart.config`](templating/kickstart.config)
for your host (at least `SYSTEM_NAME`, `REPO_SERVER_IP`, `INTERFACE1`,
`IP_ADDRESS1`), then:

```bash
cd templating && sh kickstart.sh && cd -
```

This writes `templating/files/<name>.cfg` and `templating/iso/<name>.oemdrv.iso`.
Verify the substitution, the ISO label, and the kickstart's validity:

```bash
grep -E 'url --url|network --bootproto' templating/files/kickme.cfg
isoinfo -d -i templating/iso/kickme.oemdrv.iso | grep -i 'volume id'   # -> OEMDRV
isoinfo -f -i templating/iso/kickme.oemdrv.iso                          # -> /KS.CFG
ksvalidator -v RHEL9 templating/files/kickme.cfg && echo VALID         # pykickstart
```

> Tokens are ALL-CAPS in the skeleton and `NAME=value` in the config; one
> `sed -e s@NAME@${NAME}@g` per variable substitutes them. The `@` delimiter avoids
> escaping `/` in URLs. `mkisofs -V OEMDRV ... ks.cfg=...` is what makes Anaconda
> auto-load it.

## Part 2 — Boot the FreeBSD server VM

```bash
./run-freebsd-server.sh up
```

First run downloads the FreeBSD 14.3 `BASIC-CLOUDINIT` image (~524 MB) and
decompresses it, generates an ssh key + NoCloud seed, makes an overlay, and boots
QEMU with **two NICs**: user-mode slirp (internet + ssh on `127.0.0.1:2222`) and a
rootless **socket LAN** (port 12377) the client will join. **First boot runs a
FreeBSD security update and reboots once** (~2–4 min) — expected.

```bash
ssh -p 2222 -i "$WORKDIR/id_lab" freebsd@127.0.0.1 'uname -srm; hostname'
# FreeBSD 14.3-RELEASE-p15 amd64 / www
```

## Part 3 — Provision the server (nginx + mkisofs + LAN IP)

The cloud image runs **nuageinit**, which installs the ssh key and sets passwords
but does **not** install packages (see
[WALKTHROUGH Part 3](WALKTHROUGH.md#part-3--the-cloud-init-that-isnt-meeting-nuageinit)).
So provision as root on the VM:

```bash
scp -P 2222 -i "$WORKDIR/id_lab" freebsd-server/setup-freebsd.sh freebsd-server/nginx.conf freebsd@127.0.0.1:/tmp/
ssh -p 2222 -i "$WORKDIR/id_lab" freebsd@127.0.0.1 'su -'      # password: freebsd
# as root on the VM:
sh /tmp/setup-freebsd.sh        # installs nginx+cdrtools+sudo, LAN IP 10.0.10.210, nginx autoindex
```

Verify HTTP serving (from the VM):

```bash
ssh -p 2222 -i "$WORKDIR/id_lab" freebsd@127.0.0.1 \
  'echo hi | sudo tee /usr/local/www/nginx/almalinux/9/PROBE >/dev/null; fetch -qo - http://localhost/almalinux/9/PROBE'
# -> hi
```

## Part 4 — Populate the AlmaLinux repo (faithful: mount the DVD)

On the FreeBSD VM, as root, fetch the AlmaLinux DVD, mount it, and graft its
`BaseOS`/`AppStream` into the docroot where the kickstart's `url`/`repo` lines point:

```bash
ssh -p 2222 -i "$WORKDIR/id_lab" freebsd@127.0.0.1 'sudo sh /tmp/fetch-almalinux.sh serve-dvd'
# -> http://<server>/almalinux/9/BaseOS/x86_64/os/  and  .../AppStream/x86_64/os/
```

(The DVD is ~10 GB. For a smaller run you can `reposync` only the groups your
kickstart installs; the lab's `@^minimal-environment` needs BaseOS + a little
AppStream.)

## Part 5 — Copy the OEMDRV ISO where the client can boot it

The OEMDRV ISO built in Part 1 goes to the host `$WORKDIR` so the client launcher
finds it (the client boots on the host, not on the FreeBSD VM):

```bash
cp templating/iso/kickme.oemdrv.iso "$WORKDIR/kickme.oemdrv.iso"
./fetch-almalinux.sh boot-iso        # AlmaLinux boot ISO -> $WORKDIR/almalinux-boot.iso
```

## Part 6 — Boot the client; Anaconda installs unattended (author-run)

> **Author-run:** the steps above are machine-verified in this lab; this final
> install was not run in the build session (multi-GB + minutes). It is wired and
> ready; the Anaconda-kickstart mechanics are proven in
> [`../almalinux-pxe-lab/`](../almalinux-pxe-lab/README.md).

```bash
OEMDRV_ISO="$WORKDIR/kickme.oemdrv.iso" ./run-kickme-client.sh
```

The client joins the socket LAN, boots the AlmaLinux **boot ISO** (CD0) with the
**OEMDRV ISO** (CD1). Anaconda auto-scans `OEMDRV` for `/ks.cfg` (no `inst.ks=`),
configures `10.0.10.199` per the kickstart, and pulls packages from
`http://10.0.10.210/almalinux/9/...` on the FreeBSD box. The kickstart ends with
`reboot --eject`, so the VM reboots into the installed system.

**Headless note:** with `DISPLAY_MODE=none` the installer runs on the (hidden) VGA
console. To watch or drive the boot menu, re-run with `DISPLAY_MODE=gtk`, or at the
boot menu append `inst.text console=ttyS0` to put Anaconda on the serial log
(`$WORKDIR/kickme-console.log`).

Confirm afterwards (once it reboots and you can log in as `root`/`alma`):

```bash
ip -br addr            # 10.0.10.199 on the LAN NIC
cat /etc/almalinux-release
```

## Alternative: `inst.ks=` over HTTP

The OEMDRV ISO is vermaden's faithful method, but the *same* rendered `ks.cfg` works
delivered over HTTP — serve it from the FreeBSD nginx and point the installer at it
on the kernel line (handy for PXE/iPXE like
[`../almalinux-pxe-lab/`](../almalinux-pxe-lab/README.md)):

```bash
# on the FreeBSD VM: publish the rendered kickstart
sudo cp ~/templating/files/kickme.cfg /usr/local/www/nginx/kickme.cfg
```

```
# at the AlmaLinux installer boot menu, append:
inst.ks=http://10.0.10.210/kickme.cfg inst.repo=http://10.0.10.210/almalinux/9/BaseOS/x86_64/os inst.text console=ttyS0
```

Then no OEMDRV ISO is needed. Both routes feed Anaconda the identical templated
kickstart.

## Teardown

```bash
./run-freebsd-server.sh stop
rm -rf "$WORKDIR"       # disposable: image, overlays, seed, key, ISOs
```

## Gotchas

- **`pkg`/nginx didn't install at boot** — that's nuageinit (not cloud-init); it
  ignores `packages:`/`runcmd:`. Provision in Part 3. See WALKTHROUGH Part 3.
- **`su` says wrong password** — the cloud-config `chpasswd` sets `root`/`freebsd`;
  the `freebsd` user must be in `wheel` (it is) to `su`.
- **Client can't reach the repo** — both VMs must share the socket LAN (same
  `LAN_PORT`); the server's 2nd NIC must hold `10.0.10.210` (Part 3) and the
  kickstart's `REPO_SERVER_IP` must match.
- **NIC name mismatch** — the kickstart's `INTERFACE1` (`enp0s3`) must match the
  client's actual NIC; check with `ip link` at the installer shell and adjust
  `kickstart.config`, or use the NIC's MAC in the `network --device=` line.
- **OVMF not found** — install the `ovmf` package; `run-kickme-client.sh` searches
  the common paths.

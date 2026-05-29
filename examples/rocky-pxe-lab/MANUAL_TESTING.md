# Rocky PXE lab — full install walkthrough (the ~15-minute Anaconda run)

> **⚠️ Boot mechanism updated (this runbook predates it).** The lab now boots via
> QEMU **`pxe-install`** (the NIC's PXE ROM TFTP-chainloads `ipxe.pxe`), **not**
> the two-disk iPXE-ROM-on-a-disk boot-loop described below — that never booted in
> QEMU (SeaBIOS only tries the first hard disk; disk-image x86_64 defaults to OVMF,
> which can't boot a BIOS-MBR disk). The **Anaconda + kickstart** steps are
> unchanged and still valid; ignore the `vdb` "iPXE ROM disk" / ROM-survival
> material (there is no second disk now). For the current pxe-install boot checks
> see [`../kali-preseed-gallery/MANUAL_TESTING.md`](../kali-preseed-gallery/MANUAL_TESTING.md).

This is the end-to-end, copy-pasteable runbook for actually *watching* a Rocky
Linux 9 zero-touch PXE install complete in QEMU — from a blank disk to an SSH
login, hands-off. It expands `README.md` Path A with what you should see at
each stage and how to tell it's working vs. wedged.

Budget ~15–25 minutes wall-clock on a KVM-capable x86_64 host (longer under
TCG emulation). Most of that is Anaconda pulling RPMs from the upstream mirror.

> Run everything from the repo root:
> ```bash
> cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
> ```
> Edit `examples/rocky-pxe-lab/rocky-pxe-lab.toml` and replace `/home/sqs` with
> your `$HOME` first (TOML does not expand `~` or `$HOME`).

---

## 0. Preflight — confirm the host can do this

```bash
# Tools:
command -v qemu-system-x86_64 qemu-img podman docker jq curl || \
  echo "install: qemu-system-x86 qemu-utils podman docker.io jq curl"

# KVM (optional but ~5x faster than TCG):
[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM available" || \
  echo "no KVM — install will still work under TCG, just slower"

# Free space: the install target is a 20 GB sparse qcow2; the installer
# initrd is ~210 MB.  ~3 GB actually written is typical for a minimal install.
df -h "$HOME" | tail -1
```

There must be a free TCP port `8181` on the host (the nginx artifact server
publishes there). Check:

```bash
ss -ltn 2>/dev/null | grep -q ':8181 ' && echo "8181 IN USE — pick another port" || echo "8181 free"
```

---

## 1. Fetch + verify the installer (≈1–2 min)

```bash
examples/rocky-pxe-lab/fetch-rocky-installer.sh --release 9 --arch x86_64
```

**Expect** — the last lines:

```
[info]   vmlinuz: checksum OK
[info]   initrd.img: checksum OK
[info] done — Rocky 9 installer artifacts ready in /home/<you>/netboot:
[info]   vmlinuz  (15M)
[info]   initrd.img  (213M)
```

If you see `CHECKSUM MISMATCH`, the download was truncated or tampered — re-run
(it's safe to re-run; a verified file is skipped).

Sanity-check the files landed where nginx will look:

```bash
ls -lh ~/netboot/vmlinuz ~/netboot/initrd.img
```

---

## 2. Render the per-host kickstart (instant)

The VM's NIC MAC is pinned to `52:54:00:cc:09:09`, so iPXE will request
`/ks/52-54-00-cc-09-09.ks`. Generate exactly that file:

```bash
netboot/gen-almalinux-ks.sh \
    --mac 52:54:00:cc:09:09 \
    --template examples/rocky-pxe-lab/rocky9-zerotouch.ks
```

**Expect:**

```
[info] kickstart written: /home/<you>/netboot/ks/52-54-00-cc-09-09.ks
```

Verify it's the Rocky kickstart (not a stale AlmaLinux one):

```bash
grep -m1 download.rockylinux.org ~/netboot/ks/52-54-00-cc-09-09.ks && echo OK
```

---

## 3. Build the iPXE ROM (≈1–3 min, uses Docker)

```bash
netboot/build-ipxe.sh \
    --server http://10.0.2.2:8181 \
    --kernel-path /vmlinuz --initrd-path /initrd.img \
    --append 'inst.repo=https://download.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/ inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks inst.text console=ttyS0 ip=dhcp'
```

**Expect** — at the end, a qcow2 ROM:

```
[info] ... ipxe.qcow2 ...
ls -lh ~/netboot/ipxe.qcow2   # → a few hundred KB
```

The first run pulls a Debian build image; subsequent runs are cached and fast.

> Why `10.0.2.2`? That's the host as seen from inside a QEMU slirp guest. The
> nginx container publishes on the host's `8181`, and slirp NATs the guest's
> `10.0.2.2:8181` to it. `{MAC}` is rewritten to iPXE's runtime `${mac:hexhyp}`
> so the booting NIC fetches its own kickstart.

---

## 4. Start the artifact server (instant)

```bash
phase4-podman/lab-podman.sh up --config examples/rocky-pxe-lab/rocky-pxe-lab.toml
```

**Verify all three artifacts are actually served** before booting the VM —
this is the single most common failure point (wrong `$HOME`, wrong port,
SELinux label):

```bash
curl -sI http://localhost:8181/vmlinuz                       | head -1   # HTTP/1.1 200 OK
curl -sI http://localhost:8181/initrd.img                    | head -1   # HTTP/1.1 200 OK
curl -sI http://localhost:8181/ks/52-54-00-cc-09-09.ks       | head -1   # HTTP/1.1 200 OK
```

All three must be `200`. A `404` means the file isn't under `~/netboot/` (or
the volume path in the TOML still says `/home/sqs`). A `403` on an SELinux
host means the `:Z` relabel didn't happen — `lab-podman.sh` adds it
automatically, but if you mounted by hand, add `:Z` to the volume.

---

## 5. Create + start the installer VM

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/rocky-pxe-lab/rocky-pxe-lab.toml
phase2-qemu-vm/lab-vm.sh start  rocky-pxe-install
```

`create` provisions two disks (you'll see both in the log):
- `…/rocky-pxe-install-target.qcow2` — the blank 20 GB install target (vda, bootindex 0)
- the `ipxe.qcow2` ROM (vdb, bootindex 1)

Now attach the serial console to watch the whole thing:

```bash
phase2-qemu-vm/lab-vm.sh console rocky-pxe-install
# detach any time with Ctrl-]  — the install keeps running without you
```

---

## 6. What you should see, stage by stage

This is the heart of the walkthrough — the boot-loop in motion:

| Phase | On the console | Roughly |
|---|---|---|
| **a. firmware** | SeaBIOS tries the blank target (vda) first, finds no boot sector, falls through to the iPXE ROM (vdb). | 0:00 |
| **b. iPXE** | `iPXE initialising devices...`, a DHCP line (`Configuring (net0 …)… ok`), then `http://10.0.2.2:8181/vmlinuz… ok` and `…/initrd.img… ok`. | 0:05 |
| **c. kernel + dracut** | Linux boots; dracut unpacks the 210 MB initrd into RAM. Some `[ OK ]` lines. | 0:30 |
| **d. Anaconda fetch ks** | `Reading kickstart from http://10.0.2.2:8181/ks/52-54-00-cc-09-09.ks`. If you mistyped the MAC, this is where it 404s — see Troubleshooting. | 1:00 |
| **e. stage2 + repos** | Anaconda pulls `install.img` (stage2) and reaches the upstream BaseOS/AppStream repos. `Setting up the installation environment`. | 1:30 |
| **f. partition + install** | `Installing software` with a running package count. This is the long pole — RPMs over the network. | 3:00–15:00 |
| **g. bootloader + finish** | `Performing post-installation setup tasks`, `Installing boot loader`, then `Configuring installed system`. | varies |
| **h. reboot** | The kickstart's `reboot` fires. iPXE does **not** run this time — vda is now bootable, wins the boot order. | +0:10 |
| **i. installed Rocky** | GRUB → kernel → systemd → a `rocky-pxe-install login:` prompt on the serial console. **Done.** | — |

The transition from (h) to (i) is the proof the boot-loop worked: the second
boot lands in the *installed* system, not back in iPXE.

---

## 7. Verify the installed system

Detach the console (`Ctrl-]`) and SSH in (cloud-init is not involved — Anaconda
created the accounts from the kickstart):

```bash
phase2-qemu-vm/lab-vm.sh ssh rocky-pxe-install     # login: lab / lab
```

Inside:

```bash
cat /etc/rocky-release         # → Rocky Linux release 9.x ...
lsblk                          # → vda partitioned (LVM); vdb present but untouched
sudo dnf repolist              # → baseos, appstream
systemctl is-system-running    # → running (or degraded — fine for a minimal box)
```

`vdb` (the iPXE ROM) should show **no partitions** — proof the kickstart's
`ignoredisk --only-use=vda` protected it.

---

## 8. Tear down

```bash
phase4-podman/lab-podman.sh down    --lab rocky-pxe
phase2-qemu-vm/lab-vm.sh    destroy rocky-pxe-install --force
# Optional: reclaim the installer artifacts (~225 MB):
#   rm -f ~/netboot/vmlinuz ~/netboot/initrd.img ~/netboot/.treeinfo ~/netboot/ipxe.qcow2
#   rm -rf ~/netboot/ks
```

---

## 9. Troubleshooting

**Stuck at iPXE `Configuring (net0)…` / no DHCP.**
Slirp always answers DHCP, so this usually means the VM has no NIC — confirm
`network = true` in the TOML and that `lab-vm.sh` logged a `-netdev user,…`
line. Re-run `start` after `stop`.

**Anaconda: `Cannot access the kickstart` / 404 on the ks URL.**
The MAC the VM booted with doesn't match the kickstart filename. Confirm:
```bash
grep mac examples/rocky-pxe-lab/rocky-pxe-lab.toml      # → 52:54:00:cc:09:09
ls ~/netboot/ks/                                        # → 52-54-00-cc-09-09.ks
```
They must correspond (colons → hyphens, lowercased). Re-run step 2 if not.

**Anaconda starts but can't reach the repos / DNS fails.**
Slirp provides DNS at `10.0.2.3`. If your host is behind a proxy, Anaconda
won't inherit it. Add `inst.proxy=http://host:port` to the `--append` in step 3
and rebuild iPXE.

**Console shows the install finished but `ssh` is refused.**
The VM may still be on its post-install first boot. Give it ~30 s, or attach
the console to confirm you're at the *installed* login prompt (step 6i), not
still in Anaconda.

**It booted back into Anaconda a second time (boot-loop didn't break).**
The target disk didn't become bootable — almost always a bootloader-install
failure in the kickstart. Re-attach the console during phase (g) and look for
a `bootloader` error; confirm the kickstart has
`bootloader --location=mbr --boot-drive=vda`.

**Want to watch without blocking your terminal.**
Skip the `console` attach; tail the QEMU log instead:
```bash
tail -F ~/.local/state/lab-create/vms/rocky-pxe-install/qemu.log   # path varies; lab-vm.sh prints it
```

---

## Notes

- **The AlmaLinux lab is identical in shape.** Swap the fetch script
  (`netboot/fetch-almalinux-installer.sh`), the kickstart template
  (`examples/almalinux-zerotouch.ks`), the MAC (`52:54:00:a1:9a:01`), and the
  repo URL (`repo.almalinux.org`). Everything else — iPXE build, nginx serve,
  boot-loop — is the same. See `examples/almalinux-pxe-lab.toml`.
- **This is a network install.** It pulls packages live from
  `download.rockylinux.org`. There's no local RPM mirror; only the kernel,
  initrd, and kickstart are served locally. That keeps the lab small but means
  install time tracks your bandwidth to the mirror.

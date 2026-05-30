# QUICKSTART — zero-touch PXE install: Rocky Linux 9 & AlmaLinux 9

Boot a blank VM over the (virtual) network and have it install **Rocky Linux 9**
or **AlmaLinux 9** with no keystrokes:

```
SeaBIOS → NIC's iPXE ROM → TFTP boot.ipxe (run directly) → HTTP(vmlinuz+initrd+stage2) → Anaconda → kickstart → reboot into the installed OS
```

The two labs are twins — identical flow, only three values differ (fetch script,
MAC/repo, config path). Each section below is self-contained and copy-pasteable
from the **repo root**. Each lab also has a self-contained standalone copy of its
half: `examples/rocky-pxe-lab/QUICKSTART.md` and
`examples/almalinux-pxe-lab/QUICKSTART.md`. For the full design write-ups see each
lab's `README.md`; for deep debugging logs see each lab's `MANUAL_TESTING.md`.

---

## Prerequisites (once)

```bash
cd /path/to/LAB_CREATE_V2          # repo root — run everything from here
sudo apt-get install -y qemu-system-x86 qemu-utils ovmf podman docker.io jq curl
ls /dev/kvm && echo "KVM present (installs run much faster)"
```

> **`$HOME` note.** The lab TOMLs hardcode `/home/sqs/netboot` in two places (the
> nginx `volumes =` line and `pxe_dir =`). TOML does no shell expansion, so if your
> `$HOME` is not `/home/sqs`, edit the TOML and replace `/home/sqs` with your home
> path. The `fetch-*` scripts already write to `~/netboot` automatically.

> **`build-ipxe.sh` needs Docker.** It builds iPXE in a throwaway Docker container.
> If Docker is the **snap** package, it can only bind-mount paths under `$HOME`
> (not `/tmp`) — keep `~/netboot` in your home directory.

| | Rocky Linux 9 | AlmaLinux 9 |
|---|---|---|
| Fetch script | `examples/rocky-pxe-lab/fetch-rocky-installer.sh` | `examples/almalinux-pxe-lab/fetch-almalinux-installer.sh` |
| Pinned MAC | `52:54:00:cc:09:09` → `ks/52-54-00-cc-09-09.ks` | `52:54:00:a1:9a:01` → `ks/52-54-00-a1-9a-01.ks` |
| Kickstart template | `examples/rocky-pxe-lab/rocky9-zerotouch.ks` (`--template`) | `examples/almalinux-pxe-lab/almalinux-zerotouch.ks` (the gen-ks default) |
| `inst.repo` | `https://download.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/` | `https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/` |
| Config (TOML) | `examples/rocky-pxe-lab/rocky-pxe-lab.toml` | `examples/almalinux-pxe-lab/almalinux-pxe-lab.toml` |
| Lab name / VM | `rocky-pxe` / `rocky-pxe-install` | `almalinux-pxe` / `almalinux-pxe-install` |
| nginx container | `lab-rocky-pxe-http` | `lab-almalinux-pxe-http` |

Both labs serve on host **port 8181** and log in as **`lab` / `lab`** (set by the
kickstart). Both run at **4096M RAM** by design (see [Notes](#notes--why-it-is-built-this-way)).

---

## Rocky Linux 9

```bash
# 1. Fetch + verify vmlinuz, initrd.img, AND the ~1.2 GB stage2 (images/install.img).
#    Resumable: if the CDN drops the big transfer, just re-run — it continues.
examples/rocky-pxe-lab/fetch-rocky-installer.sh --release 9 --arch x86_64

# 2. Render the per-MAC kickstart (the VM's NIC is pinned to 52:54:00:cc:09:09).
netboot/gen-almalinux-ks.sh --mac 52:54:00:cc:09:09 \
    --template examples/rocky-pxe-lab/rocky9-zerotouch.ks

# 3. Build the iPXE boot programs.  inst.stage2 points at the LOCAL install.img.
netboot/build-ipxe.sh --server http://10.0.2.2:8181 \
    --kernel-path /vmlinuz --initrd-path /initrd.img \
    --append 'inst.stage2=http://10.0.2.2:8181/ inst.repo=https://download.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/ inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks inst.text console=ttyS0 ip=dhcp'

# 4. Serve the artifacts (rootless nginx on :8181).
phase4-podman/lab-podman.sh up --config examples/rocky-pxe-lab/rocky-pxe-lab.toml

#    >>> Verify ALL FOUR are served — this is the #1 failure point <<<
for u in vmlinuz initrd.img images/install.img ks/52-54-00-cc-09-09.ks; do
    printf '%-32s ' "$u"; curl -sI "http://localhost:8181/$u" | head -1
done   # every line must say HTTP/1.1 200 OK

# 5. Create + start the installer VM (unattended; ~15–25 min).
phase2-qemu-vm/lab-vm.sh create  --config examples/rocky-pxe-lab/rocky-pxe-lab.toml
phase2-qemu-vm/lab-vm.sh start   rocky-pxe-install
phase2-qemu-vm/lab-vm.sh console rocky-pxe-install     # watch the install; Ctrl-] detaches
```

**Confirm success** (the netboot fetches happen exactly once → the disk booted →
the boot-loop terminated):

```bash
podman logs lab-rocky-pxe-http 2>&1 | grep -a 'iPXE.*GET /vmlinuz'   # one timestamp only
phase2-qemu-vm/lab-vm.sh ssh rocky-pxe-install      # login: lab / lab
cat /etc/rocky-release                               # → Rocky Linux release 9.x
```

**Tear down:**

```bash
phase4-podman/lab-podman.sh down    --lab rocky-pxe
phase2-qemu-vm/lab-vm.sh    destroy rocky-pxe-install --force
```

---

## AlmaLinux 9

Identical flow — only the fetch script, MAC, repo, and config path differ:

```bash
# 1. Fetch + verify vmlinuz, initrd.img, AND the stage2 install.img (resumable).
examples/almalinux-pxe-lab/fetch-almalinux-installer.sh --release 9 --arch x86_64

# 2. Per-MAC kickstart (NIC pinned to 52:54:00:a1:9a:01; default template = almalinux-zerotouch.ks).
netboot/gen-almalinux-ks.sh --mac 52:54:00:a1:9a:01

# 3. Build iPXE.  inst.stage2 points at the LOCAL install.img.
netboot/build-ipxe.sh --server http://10.0.2.2:8181 \
    --kernel-path /vmlinuz --initrd-path /initrd.img \
    --append 'inst.stage2=http://10.0.2.2:8181/ inst.repo=https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/ inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks inst.text console=ttyS0 ip=dhcp'

# 4. Serve + verify the four artifacts.
phase4-podman/lab-podman.sh up --config examples/almalinux-pxe-lab/almalinux-pxe-lab.toml
for u in vmlinuz initrd.img images/install.img ks/52-54-00-a1-9a-01.ks; do
    printf '%-32s ' "$u"; curl -sI "http://localhost:8181/$u" | head -1
done   # every line must say HTTP/1.1 200 OK

# 5. Create + start.
phase2-qemu-vm/lab-vm.sh create  --config examples/almalinux-pxe-lab/almalinux-pxe-lab.toml
phase2-qemu-vm/lab-vm.sh start   almalinux-pxe-install
phase2-qemu-vm/lab-vm.sh console almalinux-pxe-install
```

**Confirm success:**

```bash
podman logs lab-almalinux-pxe-http 2>&1 | grep -a 'iPXE.*GET /vmlinuz'   # one timestamp only
phase2-qemu-vm/lab-vm.sh ssh almalinux-pxe-install   # login: lab / lab
cat /etc/almalinux-release                            # → AlmaLinux release 9.x
```

**Tear down:**

```bash
phase4-podman/lab-podman.sh down    --lab almalinux-pxe
phase2-qemu-vm/lab-vm.sh    destroy almalinux-pxe-install --force
# Reclaim the big artifacts when fully done:
#   rm -rf ~/netboot/{vmlinuz,initrd.img,images,ks,ipxe.*,.treeinfo}
```

---

## What you should see on the console

1. **SeaBIOS** tries the blank target disk (`vda`, bootindex 0) → "no bootable
   device" → **"Booting from ROM…"** (the NIC's option ROM — which on QEMU *is*
   iPXE).
2. That **native iPXE** DHCPs over QEMU slirp and **TFTP-fetches `boot.ipxe`**;
   because the file starts with `#!ipxe` it runs it as a script (no second iPXE
   binary), which fetches `vmlinuz` + `initrd.img` over HTTP. *(In the nginx log
   you'll see the `vmlinuz`/`initrd.img` GETs carry the `iPXE/1.21.1` user-agent —
   the NIC ROM itself, not a chainloaded 2.0.0.)*
3. **dracut** loads the stage2 (`install.img`) from the **local** nginx — the step
   that needs the 4 GB RAM.
4. **Anaconda** runs the kickstart, partitions and installs to `/dev/vda`, then the
   kickstart's `reboot` fires.
5. **Second boot:** `vda` is now bootable (bootindex 0) → boots the installed OS;
   the NIC ROM is never reached again. **Done.**

---

## Notes — why it is built this way

These are the fixes baked into the configs; you don't need to do anything, but
here's the reasoning:

- **`firmware = "bios"`** — disk-image x86_64 VMs default to **OVMF/UEFI**, which
  cannot boot a BIOS-MBR iPXE ROM. `firmware = "bios"` selects QEMU's **SeaBIOS**,
  which network-boots via the NIC's option ROM. SeaBIOS only tries the *first* hard
  disk, so the old "two-disk boot-loop" trick does **not** work here — this NIC-PXE
  path replaces it.
- **`pxe_bootfile = "boot.ipxe"` (not `ipxe.pxe`)** — QEMU's virtio-net option ROM
  *is already* iPXE, so we hand it the **script** directly: it TFTP-fetches
  `boot.ipxe`, sees `#!ipxe`, and runs it in its native (already-DHCP'd) context.
  Pointing it at `ipxe.pxe` instead would chainload a *second* iPXE binary that
  re-initialises the NIC over **UNDI** and DHCPs again — that re-DHCP is the flaky
  step that drops to **"No bootable device."** Serving the script removes it
  entirely. *(On real hardware whose firmware PXE is **not** iPXE, set
  `pxe_bootfile = "ipxe.pxe"` / `"ipxe.efi"` to chainload the iPXE binary — which
  embeds this same `boot.ipxe` — first.)*
- **`boot.ipxe` is hardened** — `build-ipxe.sh` collapses the `--append` to a single
  line (a stray newline from a copy-paste-wrapped `--append` used to split the
  `kernel` command) and wraps `dhcp`/`kernel`/`initrd`/`boot` in a retry loop, so a
  single transient failure retries instead of aborting to the BIOS boot order.
- **`memory = "4096M"`** — Anaconda downloads the ~1.2 GB `install.img` stage2 into
  the initramfs **tmpfs** (~½ of RAM). At 2.5 GB the tmpfs filled at ~814 MB →
  `dracut: FATAL: No space left`. 4 GB (≈2 GB tmpfs) is the floor; raise it for a
  heavier package set.
- **`inst.stage2=http://10.0.2.2:8181/`** — serving `install.img` **locally** (via
  nginx) instead of streaming it from a remote mirror. Over QEMU slirp the big
  remote transfer truncates (`curl 18`) and the install dies at dracut.
- **Resumable `install.img` download** — the fetch scripts use
  `curl -fSL -C - --retry 8 --retry-all-errors`, because the public CDNs routinely
  drop that ~1.2 GB transfer partway. Re-running the fetch resumes it.

### UEFI instead of BIOS

`build-ipxe.sh` writes `boot.ipxe` and builds **both** `ipxe.pxe` (BIOS) and
`ipxe.efi` (UEFI), so switching is just a config change:

- **AlmaLinux** has a ready-made UEFI lab: `examples/vm-almalinux-uefi-pxe.toml`
  (`backend = "pxe-install"`, `pxe_bootfile = "ipxe.efi"`, no `firmware` line → OVMF
  PXE-boots `ipxe.efi`). Uses `examples/almalinux-uefi-zerotouch.ks`
  (`bootloader --location=boot`).
- **Rocky / any lab** — delete the `firmware = "bios"` line and set
  `pxe_bootfile = "ipxe.efi"`. For Secure Boot add `secure_boot = true` and build
  iPXE with `--sign --use-snakeoil`. (OVMF's NIC ROM is also iPXE, so
  `pxe_bootfile = "boot.ipxe"` works under UEFI too; the dedicated lab uses
  `ipxe.efi` as the verified path.)

### Real hardware (not QEMU)

Rebuild iPXE with `--server http://<your-LAN-IP>:8181`, generate a kickstart per
NIC MAC, and use a dnsmasq ProxyDHCP + TFTP setup (`netboot/setup-dhcp-tftp.sh`)
instead of QEMU's slirp. See `examples/rocky-pxe-lab/README.md` §"Path B".

### Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `curl -sI` on any of the four URLs ≠ `200` | nginx volume path wrong (the `$HOME` note), or the fetch step didn't complete. Fix that before booting. |
| Install dies at dracut "No space left" | RAM too low — keep `memory = "4096M"` (or higher). |
| Install dies fetching stage2 from a mirror | The `--append` lost `inst.stage2=…` — it must serve the **local** install.img. |
| A second `iPXE 2.0.0+` banner appears, then "Booting from Floppy" / "No bootable device" | You're chainloading the `ipxe.pxe` **binary** (the old failure). Confirm `pxe_bootfile = "boot.ipxe"` in the TOML and that `~/netboot/boot.ipxe` exists (re-run `build-ipxe.sh`). |
| `kernel` args look truncated / `console=ttyS0: command not found` in iPXE | A newline crept into `--append` on paste, splitting the `kernel` line. Re-run `build-ipxe.sh` (current builds collapse `--append` to one line); keep the whole `--append '…'` on a single line. |

> **Verification status:** re-verified directly on KVM after this fix — the NIC's
> native iPXE ran `boot.ipxe` and fetched `vmlinuz` + `initrd.img` + the **full
> 1.2 GB** `install.img` stage2 + the kickstart (nginx confirmed; no 814 MB cutoff
> at 4 GB RAM), and Anaconda proceeded into the install. The resumable
> `install.img` download (resumes to a complete, checksum-verified 1.17 GB) and the
> local stage2 serve are likewise proven directly. From the kickstart onward,
> Anaconda pulls packages from the upstream mirror (not nginx) and finishes the
> install + reboot — the network-dependent tail, unchanged by this fix.

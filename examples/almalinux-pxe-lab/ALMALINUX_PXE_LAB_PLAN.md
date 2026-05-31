# AlmaLinux Zero-Touch PXE Install Lab — Design Plan v1

> **Status**: Draft v1 — derived from Kenneth Finnegan's "Installing AlmaLinux
> Over the Network With No Hands" (Jan 2026) and adapted to LAB_CREATE_V2's
> existing phase machinery.
> **Decisions locked (this session):** faithful **multi-host** (per-host
> MAC-named kickstart, like Kenneth's); RPM repo served from the **upstream
> AlmaLinux HTTPS mirror** (only kernel/initrd/kickstart served locally).
> **Scope of this doc:** design only — no lab files created yet.

---

## 1. What we're building

A fully unattended ("no hands") AlmaLinux installer driven over HTTP-iPXE.
Unlike the existing `NETBOOT_LAB_PLAN.md` pipeline — which boots a Debian
rootfs **in RAM** — this lab runs the **Anaconda installer** and performs a
**kickstart-driven install to disk**, then reboots into the installed system.

```
                          iPXE build container  (netboot/build-ipxe.sh — REUSE + extend)
                            └─ ipxe.usb   (dd → USB → real HW)
                            └─ ipxe.qcow2 (Phase 2 QEMU boot ROM)
                                  │  embedded script: dhcp → fetch kernel/initrd →
                                  │  inst.ks=http://SRV/ks/${mac:hexhyp}.ks
                                  ▼
   Phase 4 rootless nginx ──► http://HOST:8181/
   (REUSE podman-netboot-server.toml)   ├── vmlinuz          (AlmaLinux installer kernel)
                                         ├── initrd.img       (AlmaLinux installer initrd)
                                         └── ks/aa-bb-cc-dd-ee-ff.ks   (per-host kickstart)
                                  │
                                  ▼
   Anaconda fetches RPMs from   https://repo.almalinux.org/almalinux/9/...  (upstream, TLS)
                                  │
                                  ▼
   Phase 2 QEMU target VM  (lab-vm.sh — REUSE + small extension)
     disk0 = blank target (install destination, bootindex=0)
     disk1 = ipxe.qcow2   (fallback ROM,           bootindex=1)
       1st boot: target empty → falls through to iPXE → Anaconda installs → reboot
       2nd boot: target now bootable → boots AlmaLinux; iPXE never reached again
```

---

## 2. How it maps onto LAB_CREATE_V2

| Pipeline step | mklab component | Status |
|---|---|---|
| iPXE binary + embedded chainboot script | `netboot/build-ipxe.sh`, `netboot/ipxe-build-inner.sh` | **Reuse + extend** (per-host MAC token) |
| Serve `vmlinuz` / `initrd.img` / `ks/*.ks` over HTTP | `examples/podman-netboot-server.toml` (Phase 4, rootless nginx) | **Reuse** (drop artifacts into served dir) |
| Target machine that PXE-boots and installs to disk | `phase2-qemu-vm/lab-vm.sh` (QEMU) | **Reuse + small extension** (blank target disk + boot order + pinned MAC) |
| AlmaLinux installer artifacts (`vmlinuz`, `initrd.img`) | — | **New** fetch helper |
| Kickstart template + per-MAC generation | — | **New** |
| RPM repository | upstream `repo.almalinux.org` over HTTPS | **No local mirror** (per decision) |

**Phase 1 (chroot/debootstrap) is intentionally NOT used** — AlmaLinux ships a
ready-made installer kernel + initrd; we download them rather than build a
rootfs.

---

## 3. The boot-loop design (the crux)

An installer needs (a) a blank disk to install onto and (b) a way to avoid
reinstalling on every subsequent boot. The clean single-VM solution uses
**QEMU bootindex ordering**:

- **disk0 = blank install target** (e.g. 20 GB qcow2), `bootindex=0`
- **disk1 = `ipxe.qcow2`** (iPXE ROM), `bootindex=1`

| Boot | Target disk state | What happens |
|---|---|---|
| 1st | empty (no boot sector) | BIOS skips it → boots iPXE (disk1) → Anaconda installs to the target → kickstart `reboot` |
| 2nd+ | bootable | BIOS boots the target (disk0); iPXE is never reached again |

Result: **true zero-touch** — `create` then `start`, walk away, come back to an
installed, running AlmaLinux. No manual disk swap, no second VM definition.

QEMU slirp user-mode networking (`10.0.2.2` = host, NAT + DNS) lets iPXE and
Anaconda reach both the local nginx (`:8181`) and the upstream mirror.

---

## 4. Required code changes (kept minimal)

### 4.1 Phase 2 — blank target disk + boot order + pinned MAC  *(new)*

`lab-vm.sh`'s `disk-image` backend currently attaches exactly one qcow2
(`lab-vm.sh:1772-1782`) and sets no `-boot`/`bootindex`. Add:

- **`install_target = "20G"`** spec field → `qemu-img create -f qcow2` a blank
  disk at create time; persist its path in the manifest.
- Attach **both** disks with explicit `bootindex` (target=0, ipxe=1) in the
  QEMU argv (the `-device virtio-blk-${suffix},drive=…,bootindex=N` lines).
- **`mac = "52:54:00:..."`** spec field → pass `-netdev … -device
  virtio-net-…,mac=$MAC` so we can pre-generate the matching per-host
  kickstart. Falls back to a deterministic default if unset.

Estimated ~25–40 lines, contained to the spec parser + the qemu-argv section.

### 4.2 build-ipxe.sh — emit iPXE *runtime* `${mac}` for per-host kickstart  *(new)*

The embedded `boot.ipxe` is written via an **unquoted** bash heredoc
(`netboot/ipxe-build-inner.sh:86-92`), so `$`-tokens are expanded by **bash at
build time** — `${mac:hexhyp}` would be eaten (→ empty). To support Kenneth's
per-host MAC kickstart faithfully, add a literal-token escape hatch:

- Let `--append` contain a `{MAC}` placeholder, e.g.
  `inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks`.
- In `ipxe-build-inner.sh`, **after** the heredoc, rewrite the literal token
  `{MAC}` → `${mac:hexhyp}` (iPXE's lowercase hyphen-separated MAC) so the
  *iPXE* runtime — not bash — expands it at boot. (`${mac:hexhyp}` →
  `aa-bb-cc-dd-ee-ff`.)
- This sidesteps the bash-expansion problem entirely and needs no quoting
  gymnastics. ~3–5 lines.

### 4.3 Per-host kickstart generation  *(new helper)*

`netboot/gen-almalinux-ks.sh --mac <MAC> [--template examples/almalinux-pxe-lab/almalinux-zerotouch.ks] [--out ~/netboot/ks/]`
→ renders the template to `ks/<mac:hexhyp>.ks` (lowercase, `-`-separated). For
QEMU, feed it the VM's pinned MAC (§4.1); for real hardware, run once per NIC
MAC. A 404 on an unknown MAC simply means "no kickstart for this host" — we'll
document shipping a `default.ks` symlink fallback as an option.

---

## 5. New files summary

| File | Type | Notes |
|---|---|---|
| `phase2-qemu-vm/lab-vm.sh` | edit | `install_target`, `mac`, bootindex ordering |
| `netboot/ipxe-build-inner.sh` | edit | `{MAC}` → `${mac:hexhyp}` token rewrite |
| `netboot/build-ipxe.sh` | edit | document `{MAC}` placeholder in `--append` |
| `examples/almalinux-pxe-lab/fetch-almalinux-installer.sh` | new | curl `images/pxeboot/{vmlinuz,initrd.img}` from `--mirror`; chown for rootless nginx |
| `netboot/gen-almalinux-ks.sh` | new | render per-MAC kickstart from template |
| `examples/almalinux-pxe-lab/almalinux-zerotouch.ks` | new | kickstart template (see §6) |
| `examples/almalinux-pxe-lab/vm-almalinux-pxe-install.toml` | new | Phase 2 install-target VM (§7) |
| `examples/almalinux-pxe-lab/almalinux-pxe-lab.toml` | new | unified cross-phase lab (Phase 4 + Phase 2) |
| `netboot/SHOWCASE.md` | edit | add an AlmaLinux zero-touch section |
| `README.md` | edit | add a quick-start entry |
| `phase2-qemu-vm/tests/…` | new | unit test: `install_target` creates a blank disk + argv has two bootindexed drives |

---

## 6. Kickstart template (`examples/almalinux-pxe-lab/almalinux-zerotouch.ks`)

```kickstart
# AlmaLinux 9 zero-touch install — throwaway lab posture (see AUDIT.md F1).
# Rendered per-host by netboot/gen-almalinux-ks.sh; served at /ks/<mac>.ks.
text
eula --agreed
# Packages pulled from the upstream HTTPS mirror (TLS-verified, gpgcheck on).
url      --url="https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/"
repo --name="AppStream" --baseurl="https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/"
network  --bootproto=dhcp --device=link --activate
firewall --enabled --service=ssh
services --enabled=sshd
timezone Etc/UTC --utc
# Disk: install to the bootindex=0 target (first virtio disk).
ignoredisk --only-use=vda
clearpart  --all --initlabel --drives=vda
autopart   --type=lvm
bootloader --location=mbr --boot-drive=vda --append="console=ttyS0"
# Throwaway 'lab' credentials — consistent with the rest of mklab.
# NEVER expose this VM to an untrusted network. Swap to --iscrypted for real use.
rootpw --plaintext lab
user   --name=lab --password=lab --groups=wheel --plaintext
%packages
@^minimal-environment
openssh-server
%end
# bootindex makes the freshly-installed disk win on the next boot, so a plain
# reboot completes the zero-touch loop (no manual disk swap needed).
reboot
```

**Notes**
- `inst.stage2` is derived from `inst.repo` automatically; no separate stage2
  server needed.
- `ignoredisk --only-use=vda` is what makes the two-disk (target + iPXE) layout
  safe — Anaconda only ever touches the target.
- Keeping `gpgcheck` implicit-on + HTTPS mirror partially addresses audit
  finding **F2** (unverified downloads) for this lab.

---

## 7. Phase 2 install-target VM (`examples/almalinux-pxe-lab/vm-almalinux-pxe-install.toml`)

```toml
# Zero-touch AlmaLinux installer target.  Boots iPXE (fallback), which chainloads
# Anaconda; kickstart installs to the blank target disk and reboots into it.
#
# Prereqs (run in order):
#   netboot/setup-netboot-dir.sh
#   examples/almalinux-pxe-lab/fetch-almalinux-installer.sh --mirror https://repo.almalinux.org/almalinux --release 9 --arch x86_64
#   netboot/gen-almalinux-ks.sh --mac 52:54:00:a1:9a:01     # → ~/netboot/ks/52-54-00-a1-9a-01.ks
#   netboot/build-ipxe.sh --server http://10.0.2.2:8181 \
#       --kernel-path /vmlinuz --initrd-path /initrd.img \
#       --append 'inst.repo=https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/ inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks inst.text console=ttyS0 ip=dhcp'
#   phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml
#
# Then:
#   phase2-qemu-vm/lab-vm.sh create --config examples/almalinux-pxe-lab/vm-almalinux-pxe-install.toml
#   phase2-qemu-vm/lab-vm.sh start  almalinux-pxe-install     # walk away; comes back installed

[[vm]]
name           = "almalinux-pxe-install"
backend        = "disk-image"
image          = "/home/USER/netboot/ipxe.qcow2"   # the iPXE ROM (bootindex=1, fallback)
install_target = "20G"                              # blank disk, bootindex=0 (install dest)
mac            = "52:54:00:a1:9a:01"                # pinned so the per-MAC ks matches
arch           = "x86_64"
memory         = "2560M"                            # Anaconda needs ~2 GB+
cpus           = 2
network        = true
cloud_init     = false                              # iPXE ROM has no cloud-init datasource
```

---

## 8. Full workflow (the lab's documented happy path)

```bash
# 1. One-time host setup (artifact dir + nginx MIME config)
netboot/setup-netboot-dir.sh

# 2. Fetch the AlmaLinux installer kernel + initrd into ~/netboot/
examples/almalinux-pxe-lab/fetch-almalinux-installer.sh \
    --mirror https://repo.almalinux.org/almalinux --release 9 --arch x86_64

# 3. Generate a per-host kickstart for the VM's pinned MAC
netboot/gen-almalinux-ks.sh --mac 52:54:00:a1:9a:01

# 4. Build iPXE with the per-host {MAC} kickstart URL embedded
netboot/build-ipxe.sh --server http://10.0.2.2:8181 \
    --kernel-path /vmlinuz --initrd-path /initrd.img \
    --append 'inst.repo=https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/ inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks inst.text console=ttyS0 ip=dhcp'

# 5. Serve artifacts (rootless nginx on :8181)
phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml

# 6. Create + start the target VM — unattended install, reboot into AlmaLinux
phase2-qemu-vm/lab-vm.sh create --config examples/almalinux-pxe-lab/vm-almalinux-pxe-install.toml
phase2-qemu-vm/lab-vm.sh start  almalinux-pxe-install
phase2-qemu-vm/lab-vm.sh ssh    almalinux-pxe-install   # lab / lab
```

**Real hardware:** rebuild with `--server http://<LAN-IP>:8181`, generate a
kickstart per NIC MAC, `dd ~/netboot/ipxe.usb of=/dev/sdX`, boot the target
from USB. Same flow; only the server URL and MACs change.

---

## 9. Security notes (cross-referenced with AUDIT.md)

- **Throwaway credentials (audit F1).** Kickstart uses `lab`/`lab` for root and
  the `lab` user, matching the rest of mklab. Documented as
  **disposable-lab-only; never expose to an untrusted network.** The template
  carries a comment pointing at `--iscrypted` for real deployments.
- **Download integrity (audit F2).** Packages come from `repo.almalinux.org`
  over **HTTPS** with `gpgcheck` on, so RPM signatures are verified — better
  than the unverified-image path. The fetch helper should additionally verify
  `vmlinuz`/`initrd.img` against AlmaLinux's published `CHECKSUM` file.
- **Port exposure (audit F4).** The nginx server should bind loopback for the
  QEMU-only path; only widen to `0.0.0.0` for the real-hardware LAN path.
- **Kickstart is sensitive.** A `.ks` is effectively a root provisioning
  script; treat the served `ks/` dir as trust-sensitive (don't serve it on an
  open network without auth).

---

## 10. Implementation order (dependency-aware)

1. **Phase 2 extension** (`install_target`, `mac`, bootindex) — nothing
   installs without a target disk + boot order.
2. **build-ipxe.sh `{MAC}` token** — needed for the per-host kickstart URL.
3. **`fetch-almalinux-installer.sh`** — needed before any boot.
4. **`almalinux-zerotouch.ks` + `gen-almalinux-ks.sh`** — kickstart path.
5. **Example TOMLs** (`vm-almalinux-pxe-install.toml`, `almalinux-pxe-lab.toml`).
6. **Tests + docs** (Phase 2 unit test, SHOWCASE, README) — last.

---

## 11. v0.2 additions (done)

- **default.ks fallback:** `gen-almalinux-ks.sh --default` writes
  `ks/default.ks` (same content as the per-MAC file).  `examples/almalinux-pxe-lab/nginx-ks-fallback.conf`
  provides a `try_files $uri /ks/default.ks =404;` nginx snippet to enable the
  fallback.  Safety note in both: enabling default.ks installs *any* unknown
  machine — only use on an isolated lab network.
- **aarch64 AlmaLinux:** `fetch-almalinux-installer.sh --arch aarch64` already
  works (AlmaLinux publishes the aarch64 pxeboot tree).  Added:
  `examples/almalinux-pxe-lab/almalinux-aarch64-zerotouch.ks` (console=ttyAMA0, aarch64 mirrors),
  `examples/almalinux-pxe-lab/vm-almalinux-aarch64-pxe.toml` (arch=aarch64, TCG, AAVMF auto-selected).
  Build with `netboot/build-ipxe.sh --arch aarch64`.
- **UEFI / Secure Boot targets:**
  - New `pxe-install` backend in `lab-vm.sh`: creates a blank install-target disk
    only (no iPXE ROM disk); OVMF network-boots directly via QEMU slirp TFTP.
    After Anaconda installs, OVMF boots from the EFI partition — clean UEFI path.
  - `examples/almalinux-pxe-lab/almalinux-uefi-zerotouch.ks` (bootloader --location=boot, EFI autopart).
  - `examples/almalinux-pxe-lab/vm-almalinux-uefi-pxe.toml` (backend=pxe-install, pxe_dir, pxe_bootfile=ipxe.efi).
  - Secure Boot: `secure_boot = true` in TOML + `netboot/sign-ipxe.sh --use-snakeoil`.
- **Phase 6 TUI surfacing:** `lab_tui/backends/vm.py` now classifies VMs with
  `backend=pxe-install` or `install_target` as `type="pxe-install"`.  These
  appear with a distinct label in the resource tree and expose a `_ks_file_hint`
  (e.g. `ks/52-54-00-a1-9a-01.ks`) in the detail view.  The `almalinux-pxe-lab.toml`
  surfaces as a single correlated lab (Phase 4 nginx + Phase 2 pxe-install VM).

## Open items

- **inst.stage2 pinning / proxy:** optionally cache stage2 + a thin local repo
  proxy for flaky-network installs (the "full local mirror" variant we deferred).

---

## Sources

- [Installing AlmaLinux Over the Network With No Hands — The Life of Kenneth (Jan 2026)](https://blog.thelifeofkenneth.com/2026/01/almalinux-pxe-zerotouh.html)
- [PXE Booting the AlmaLinux Installer — netboot.xyz](https://netboot.xyz/docs/kb/pxe/almalinux/)
- [Kickstart installation of EL Linux systems — DTU IT wiki](https://wiki.fysik.dtu.dk/ITwiki/Kickstart/)

# Netboot Lab Pipeline — Design Plan v2

> **Status**: Draft v2 — refined from user Q&A session 2026-05-05.
> Scope: full automation of HTTP-netboot pipeline using existing LAB_CREATE_V2
> machinery, targeting both QEMU (local validation) and real hardware
> (thin clients / SBCs). Build iPXE from source inside a container.

---

## What we're building

A fully automated "boot Linux over HTTP" pipeline:

```
Phase 1 (debootstrap)
  └─ export-initrd [NEW VERB]
       ├─ /srv/netboot/kernel
       └─ /srv/netboot/initrd.gz
             │
             │          iPXE build container [NEW]
             │            └─ ipxe.usb  (dd → USB stick → real HW)
             │            └─ ipxe.qcow2 (Phase 2 QEMU boot target)
             │
             ├─ Phase 4 (rootless nginx) ──► http://HOST:8080/
             │   ├── kernel
             │   ├── initrd.gz
             │   └── boot.ipxe   [generated iPXE chainboot script]
             │
             └─ Phase 2 (QEMU)
                 ├─ Direct boot  (-kernel / -initrd, instant validation)
                 └─ iPXE simulation (boot ipxe.qcow2 → DHCP → HTTP → RAM)
```

---

## Decisions locked in

| # | Question | Answer |
|---|---|---|
| 1 | Boot target | **Both**: QEMU first (fully validate), then real hardware (thin client / SBC) |
| 2 | Boot protocol | **HTTP-only** — modern iPXE chainloading. HTTPS left as follow-up. |
| 3 | iPXE binary | **Build from source** (embedded script; required for offline/hardware path). Build runs inside a **Docker** container — no host pollution. |
| 4 | Initrd content | **Both**: minimal busybox path (fast iteration) + full Debian path (Kenneth's approach, what we'd deploy) |
| 5 | Network config | **DHCP** — iPXE runs `dhcp`; booted system runs `udhcpc`/`dhclient` |
| 6 | export-initrd | **New verb on `lab-chroot.sh`**, following `export-tarball` pattern |
| A | `/init` handling | **Both default AND explicit**: `export-initrd` auto-writes a sensible default if `$target/init` is absent (auto-detects busybox vs systemd); PLUS `init_script` TOML field in `[[chroot]]` applied at `create` time |
| B | iPXE build container | **Docker** (`docker run --rm`) |

---

## New components

### 1. `lab-chroot.sh export-initrd` (Phase 1, new verb) + `init_script` TOML field

Add `cmd_export_initrd()` to `phase1-chroot/lab-chroot.sh`, following the
existing `cmd_export_tarball()` pattern (lines 1100–1144).

**CLI:**
```bash
sudo lab-chroot.sh export-initrd netboot-full \
    --output /srv/netboot/initrd.gz \
    --kernel  /srv/netboot/kernel \
    [--strip-modules]      # optional: omit /lib/modules/ for smaller image
```

**CLI:**
```bash
sudo lab-chroot.sh export-initrd <name> \
    --kernel /srv/netboot/kernel \
    --output /srv/netboot/initrd.gz \
    [--init-script /path/to/init | --init-flavor busybox|systemd] \
    [--strip-modules]
```

**`init_script` TOML field** (applied at `create` time, before `export-initrd`):
```toml
[[chroot]]
name        = "netboot-minimal"
...
init_script = "busybox"    # "busybox" | "systemd" | "/host/path/to/custom-init.sh"
```
- `"busybox"` preset writes a busybox-sh `/init` with `mount` + `udhcpc` + `exec /bin/sh`
- `"systemd"` preset writes a POSIX-sh `/init` with `mount` + `exec /sbin/init`
- A host path copies that file verbatim into `$target/init` and `chmod 755`
- Applied inside `cmd_create()` as the last step, after the backend finishes

**`export-initrd` `/init` auto-detection** (fallback when no `init_script` set):
- If `$target/init` already exists → use it as-is, emit `[info] using existing /init`
- If not → detect: `[[ -x "$target/bin/busybox" ]]` → write busybox preset; else write systemd preset
- Emit `[warn] no /init found; writing auto-detected default (busybox|systemd)` so users know

**Busybox `/init` default:**
```sh
#!/bin/busybox sh
/bin/busybox --install -s
mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
mount -t devtmpfs devtmpfs /dev
ip link set eth0 up
udhcpc -i eth0 -t 5 -n || true
exec /bin/sh
```

**Systemd `/init` default:**
```sh
#!/bin/sh
mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
mount -t devtmpfs devtmpfs /dev
exec /sbin/init
```

**`export-initrd` internals:**
1. Resolve chroot name → `$target` (same manifest lookup as `export-tarball`)
2. Find `vmlinuz-*` in `$target/boot/` → copy to `--kernel` path
3. Ensure `/init` exists (write default if missing, as above)
4. `cd "$target" && find . | cpio -H newc -o | gzip -9 -n > "$output"`
   - Exclude same paths as `export-tarball`: `./proc/*`, `./sys/*`, `./dev/*`,
     `./run/*`, `./tmp/*`, `./.lab-chroot-mounts`
   - If `--strip-modules`: also exclude `./lib/modules/`
5. `chown "$invoker_uid:$invoker_gid"` on both kernel and initrd outputs
   (so rootless Phase 4 nginx can read them)
6. Print summary: `[info] kernel: $kernel_path (N KB); initrd: $output (M MB)`

**Test:** `phase1-chroot/tests/test-export-initrd.sh`
- Build a tiny fake chroot tree (no real debootstrap needed)
- Create fake `boot/vmlinuz-6.1.0-dummy` file
- Run `export-initrd` and verify kernel + initrd.gz both created
- Verify gzip header present: `file initrd.gz | grep 'gzip compressed data'`
- Verify cpio content: `zcat initrd.gz | cpio -t | grep boot/vmlinuz`
- Verify ownership transferred (stat uid == invoker)

---

### 2. Two chroot TOML examples

**`examples/chroot-netboot-minimal.toml`** — busybox-only, fast:
```toml
# Minimal Debian chroot for netboot initrd: busybox + network tools + kernel.
# Total compressed initrd: ~80–150 MB (most of that is kernel modules).
# To strip modules and get a smaller image, add --strip-modules to export-initrd.
#
# Workflow:
#   sudo lab-chroot.sh create --config examples/chroot-netboot-minimal.toml
#   sudo lab-chroot.sh export-initrd netboot-minimal \
#       --kernel /srv/netboot/kernel --output /srv/netboot/initrd.gz
#
# The custom /init script is required — add it after create:
#   sudo tee /var/chroots/netboot-minimal/init <<'INIT'
#   #!/bin/busybox sh
#   /bin/busybox mount -t proc     proc     /proc
#   /bin/busybox mount -t sysfs    sysfs    /sys
#   /bin/busybox mount -t devtmpfs devtmpfs /dev
#   /bin/busybox udhcpc -i eth0
#   exec /bin/busybox sh
#   INIT
#   sudo chmod 755 /var/chroots/netboot-minimal/init

[[chroot]]
name    = "netboot-minimal"
backend = "debootstrap"
distro  = "debian"
suite   = "bookworm"
arch    = "x86_64"
target  = "/var/chroots/netboot-minimal"
variant = "minbase"
include = [
    "linux-image-amd64",   # kernel + modules (extracted by export-initrd)
    "busybox-static",      # shell + udhcpc + mount + all the tools
    "kmod",                # modprobe
]
manager = "none"
```

**`examples/chroot-netboot-full.toml`** — full Debian (Kenneth's approach):
```toml
# Full Debian bookworm chroot for netboot — systemd as PID 1, full apt, ~300-500 MB.
# This is Kenneth Finnegan's approach: the whole distro runs in RAM.
# Reference: https://blog.thelifeofkenneth.com/2020/03/booting-linux-over-http.html
#
# Workflow:
#   sudo lab-chroot.sh create --config examples/chroot-netboot-full.toml
#   # Add the custom /init (runs before systemd hands off to PID 1):
#   sudo tee /var/chroots/netboot-full/init <<'INIT'
#   #!/bin/sh
#   mount -t proc     proc     /proc
#   mount -t sysfs    sysfs    /sys
#   mount -t devtmpfs devtmpfs /dev
#   exec /sbin/init
#   INIT
#   sudo chmod 755 /var/chroots/netboot-full/init
#   sudo lab-chroot.sh export-initrd netboot-full \
#       --kernel /srv/netboot/kernel --output /srv/netboot/initrd-full.gz
#
# NOTE: The initrd will be several hundred MB. This is intentional — the
# entire Debian system lives in RAM. Ensure boot target has enough RAM (≥1 GB).

[[chroot]]
name    = "netboot-full"
backend = "debootstrap"
distro  = "debian"
suite   = "bookworm"
arch    = "x86_64"
target  = "/var/chroots/netboot-full"
variant = "minbase"
include = [
    "linux-image-amd64",           # kernel + modules
    "systemd", "systemd-sysv",     # PID 1 (exec'd by /init)
    "udev",                        # device manager
    "iproute2",                    # ip addr, ip route
    "dhcpcd5",                     # DHCP client (brings up eth0 via netplan/dhcpcd)
    "iputils-ping", "curl", "wget",
    "openssh-server",              # remote access after boot
    "ca-certificates",             # HTTPS trust roots
    "vim-tiny", "less",
]
manager = "none"
```

---

### 3. iPXE build container

New directory: `netboot/`

**`netboot/build-ipxe.sh`** — builds iPXE from source inside a container.

```bash
#!/usr/bin/env bash
# Build iPXE from source inside a container with an embedded boot script.
# Outputs: ipxe.usb (raw disk image) + ipxe.efi (UEFI binary).
#
# Usage:
#   netboot/build-ipxe.sh \
#       --server http://10.0.2.2:8080 \
#       --kernel  /kernel \
#       --initrd  /initrd.gz \
#       --append  "console=ttyS0 root=/dev/ram0 rw" \
#       --output-dir /srv/netboot
#
# Then:
#   dd if=/srv/netboot/ipxe.usb of=/dev/sdX   # → USB stick for real HW
#   qemu-img convert -f raw -O qcow2 /srv/netboot/ipxe.usb /srv/netboot/ipxe.qcow2
```

**Generated embedded script (template):**
```
#!ipxe
dhcp
kernel ${SERVER}${KERNEL_PATH} ${APPEND}
initrd ${SERVER}${INITRD_PATH}
boot
```

**Build deps (inside container):**
`gcc`, `make`, `git`, `liblzma-dev`, `mtools`, `perl`, `isolinux` (for x86 USB)

**Container invocation:**
```bash
# Use Docker (rootful, builder image)
docker run --rm \
    -v "$output_dir:/out" \
    -v "$netboot_dir:/build-ctx:ro" \
    debian:bookworm bash /build-ctx/ipxe-build-inner.sh \
        "$server_url" "$kernel_path" "$initrd_path" "$append_args"
```

**Outputs:**
- `ipxe.usb` — raw disk image (MBR + iPXE binary); `dd` to USB/disk
- `ipxe.efi` — UEFI binary for Secure Boot-capable hardware
- `boot.ipxe` — the plain-text chainboot script (served by nginx)
- `ipxe.qcow2` — qcow2 conversion of `ipxe.usb` (for Phase 2 QEMU boot)

---

### 4. nginx container with iPXE MIME types

**`examples/podman-netboot-server.toml`** (Phase 4, primary — rootless):
```toml
# Rootless nginx serving kernel + initrd + iPXE chain script over HTTP.
# The nginx config adds the application/x-ipxe MIME type so iPXE clients
# accept the .ipxe script file.
#
# After `lab-chroot.sh export-initrd` and `netboot/build-ipxe.sh`:
#   lab-podman.sh up --config examples/podman-netboot-server.toml
#   curl -sI http://localhost:8080/kernel      # → 200 OK
#   curl -sI http://localhost:8080/initrd.gz   # → 200 OK
#   curl -s  http://localhost:8080/boot.ipxe   # → #!ipxe\ndhcp\n...

[lab]
name        = "netboot-srv"
description = "Rootless HTTP server for netboot artifacts (kernel + initrd + iPXE script)"
tags        = ["netboot", "http", "ipxe"]

[[service]]
name    = "http"
engine  = "podman"
image   = "docker.io/library/nginx:alpine"
ports   = ["8080:80"]
volumes = [
    "/srv/netboot:/usr/share/nginx/html:ro",
    "/etc/lab-netboot/ipxe-mime.conf:/etc/nginx/conf.d/ipxe-mime.conf:ro",
]
```

**`/etc/lab-netboot/ipxe-mime.conf`** (written by setup helper — see below):
```nginx
types {
    application/x-ipxe  ipxe;
}
```

**`netboot/setup-netboot-dir.sh`** — creates `/srv/netboot/` and `/etc/lab-netboot/`:
```bash
#!/usr/bin/env bash
# One-time setup: create artifact directories and write nginx MIME config.
# Run once before `lab-podman.sh up --config examples/podman-netboot-server.toml`.
#
# Usage: sudo netboot/setup-netboot-dir.sh [--dir /srv/netboot]
```

**`examples/docker-netboot-server.toml`** (Phase 3, secondary — rootful):
- Same structure as podman variant but `engine = "docker"` and `[lab] name = "netboot-srv-docker"`

---

### 5. Phase 2 TOML variants

**`examples/vm-netboot-direct.toml`** — direct `-kernel`/`-initrd` (no iPXE, instant):
```toml
# QEMU boot from a local kernel + initrd — equivalent to what iPXE does after
# downloading, but without the HTTP step. Good for validating the initrd works
# before wiring up the full iPXE chain.
#
# Prereq: run export-initrd first:
#   sudo lab-chroot.sh export-initrd netboot-minimal \
#       --kernel /srv/netboot/kernel --output /srv/netboot/initrd.gz

[[vm]]
name    = "netboot-direct"
backend = "kernel+initrd"
arch    = "x86_64"
memory  = "512M"
cpus    = 1
microvm = true
kernel  = "/srv/netboot/kernel"
initrd  = "/srv/netboot/initrd.gz"
append  = "console=ttyS0 root=/dev/ram0 rw"
network = true
```

**`examples/vm-netboot-ipxe.toml`** — full iPXE simulation (boots ipxe.qcow2, chainloads via HTTP):
```toml
# QEMU boots the iPXE disk image exactly as a thin client would boot from
# a USB stick. iPXE gets a DHCP lease (from QEMU slirp at 10.0.2.2),
# downloads kernel + initrd from the nginx container at http://10.0.2.2:8080/,
# and boots the system in RAM.
#
# Prereqs:
#   1. netboot/setup-netboot-dir.sh
#   2. sudo lab-chroot.sh create --config examples/chroot-netboot-minimal.toml
#   3. sudo lab-chroot.sh export-initrd netboot-minimal \
#          --kernel /srv/netboot/kernel --output /srv/netboot/initrd.gz
#   4. netboot/build-ipxe.sh --server http://10.0.2.2:8080 --output-dir /srv/netboot
#   5. lab-podman.sh up --config examples/podman-netboot-server.toml
#
# Phase 2 will need a small extension to support booting from a raw/qcow2
# disk image without cloud-init (see "Phase 2 extension" section below).

[[vm]]
name    = "netboot-ipxe"
backend = "disk-image"
image   = "/srv/netboot/ipxe.qcow2"
arch    = "x86_64"
memory  = "512M"
cpus    = 1
network = true
# Note: no cloud-init seeding for this image — it's a raw iPXE ROM, not a cloud image
cloud_init = false   # new field needed in Phase 2 (see extension notes)
```

---

### 6. Phase 2 extension — bare disk-image boot (no cloud-init)

Currently Phase 2's `disk-image` backend always seeds a cloud-init NoCloud ISO.
For the iPXE qcow2, that would be harmless (iPXE ignores extra drives) but
may confuse QEMU's boot ordering.

**Proposed change** (`phase2-qemu-vm/lab-vm.sh`):
- Add `cloud_init` field to spec (default: `true`)
- When `cloud_init = false` (or backend is non-cloud): skip `build_cloud_init_seed()`
  and skip `-drive file=seed.iso,...` from the QEMU argv
- This is a small, contained change

**Alternative**: Add `"bare"` as a new backend alias for `"disk-image"` with
`cloud_init` implicitly false. Cleaner for the TOML but more code.

---

### 7. Unified cross-phase TOML

**`examples/netboot-lab.toml`** — drives the whole pipeline:
```toml
# Unified netboot lab: Phase 1 chroot → Phase 4 nginx → Phase 2 QEMU.
# One file, three phase tools, one lab name for the Phase 6 TUI to correlate.
#
# Full workflow in dependency order:
#
#   # 1. Build the initrd rootfs:
#   sudo phase1-chroot/lab-chroot.sh create --config examples/netboot-lab.toml
#
#   # 2. Add /init script and package as initrd (see chroot-netboot-minimal.toml
#   #    header for the /init text):
#   sudo phase1-chroot/lab-chroot.sh export-initrd netboot-minimal \
#       --kernel /srv/netboot/kernel --output /srv/netboot/initrd.gz
#
#   # 3. Build iPXE and convert to qcow2:
#   netboot/build-ipxe.sh --server http://10.0.2.2:8080 --output-dir /srv/netboot
#   qemu-img convert -f raw -O qcow2 /srv/netboot/ipxe.usb /srv/netboot/ipxe.qcow2
#
#   # 4. Serve artifacts (rootless):
#   phase4-podman/lab-podman.sh up --config examples/netboot-lab.toml
#
#   # 5. Boot via iPXE simulation:
#   sudo phase2-qemu-vm/lab-vm.sh create --config examples/netboot-lab.toml
#   phase2-qemu-vm/lab-vm.sh start netboot-ipxe
#
#   # For real hardware: dd /srv/netboot/ipxe.usb to a USB stick, boot the target.

[lab]
name        = "netboot"
description = "HTTP netboot pipeline: debootstrap initrd → rootless nginx → QEMU iPXE simulation"
tags        = ["netboot", "ipxe", "http", "initrd"]

# ─── Phase 1: build the initrd rootfs ────────────────────────────────────────
[[chroot]]
name    = "netboot-minimal"
backend = "debootstrap"
distro  = "debian"
suite   = "bookworm"
arch    = "x86_64"
target  = "/var/chroots/netboot-minimal"
variant = "minbase"
include = ["linux-image-amd64", "busybox-static", "kmod"]
manager = "none"

# ─── Phase 4: rootless nginx serving the artifacts ───────────────────────────
[[service]]
name    = "http"
engine  = "podman"
image   = "docker.io/library/nginx:alpine"
ports   = ["8080:80"]
volumes = [
    "/srv/netboot:/usr/share/nginx/html:ro",
    "/etc/lab-netboot/ipxe-mime.conf:/etc/nginx/conf.d/ipxe-mime.conf:ro",
]

# ─── Phase 2: QEMU boots from the iPXE disk image ────────────────────────────
[[vm]]
name       = "netboot-ipxe"
backend    = "disk-image"
image      = "/srv/netboot/ipxe.qcow2"
arch       = "x86_64"
memory     = "512M"
cpus       = 1
network    = true
cloud_init = false
```

---

## Phase 2 iPXE simulation — QEMU networking note

QEMU's slirp user-mode network provides:
- Guest IP: `10.0.2.15` (DHCP from QEMU's internal DHCP server)
- Host IP (as seen from guest): `10.0.2.2`
- Internet access: yes (via host NAT)

So if the nginx container is published on the host at `0.0.0.0:8080`, the
embedded iPXE script should use `http://10.0.2.2:8080/` as the server URL.
`netboot/build-ipxe.sh --server http://10.0.2.2:8080` is the right invocation
for the QEMU simulation path.

For real hardware on a LAN, the server URL changes to the host's LAN IP.
`build-ipxe.sh` regenerates the iPXE binary for each deployment target.

---

## Real hardware path (post-QEMU validation)

1. Run `netboot/build-ipxe.sh --server http://<LAN-IP>:8080 --output-dir /srv/netboot`
2. `dd if=/srv/netboot/ipxe.usb of=/dev/sdX bs=4M status=progress`
3. Plug USB into thin client / SBC, boot from USB
4. iPXE gets DHCP from LAN router → downloads kernel + initrd from nginx → boots in RAM

For SBCs (aarch64): need `ipxe.efi` (UEFI) or an aarch64-specific boot chain.
`build-ipxe.sh` will support `--arch aarch64` (targets `bin-arm64-efi/ipxe.efi`).

---

## New files summary

| File | Type | Notes |
|---|---|---|
| `phase1-chroot/lab-chroot.sh` | edit | Add `export-initrd` verb |
| `phase1-chroot/tests/test-export-initrd.sh` | new | Unit tests, no live debootstrap |
| `phase2-qemu-vm/lab-vm.sh` | edit | Add `cloud_init` field support |
| `netboot/build-ipxe.sh` | new | iPXE build + embed + convert |
| `netboot/ipxe-build-inner.sh` | new | Inner script run inside container |
| `netboot/setup-netboot-dir.sh` | new | Create dirs + write nginx MIME config |
| `examples/chroot-netboot-minimal.toml` | new | Busybox initrd chroot |
| `examples/chroot-netboot-full.toml` | new | Full Debian initrd chroot |
| `examples/podman-netboot-server.toml` | new | Phase 4 nginx (primary) |
| `examples/docker-netboot-server.toml` | new | Phase 3 nginx (secondary) |
| `examples/vm-netboot-direct.toml` | new | Phase 2 direct -kernel/-initrd |
| `examples/vm-netboot-ipxe.toml` | new | Phase 2 iPXE disk image boot |
| `examples/netboot-lab.toml` | new | Unified cross-phase |
| `phase1-chroot/SHOWCASE.md` | edit | Add initrd pipeline section |
| `phase2-qemu-vm/SHOWCASE.md` | edit | Add netboot section |
| `phase3-docker/SHOWCASE.md` | edit | Add HTTP server section |
| `phase4-podman/SHOWCASE.md` | edit | Add rootless server section |
| `phase6-tui/SHOWCASE.md` | edit | Add netboot cross-phase example |
| `README.md` | edit | Add netboot quick-start |

---

## Implementation order (dependency-aware)

1. **Phase 1 `export-initrd` verb** — needed before any end-to-end testing
2. **`netboot/` scripts** (`setup-netboot-dir.sh`, `build-ipxe.sh`, `ipxe-build-inner.sh`) — needed before Phase 4 + Phase 2 iPXE path
3. **Phase 4/3 nginx TOMLs** — can be done in parallel with (2)
4. **Phase 2 cloud_init=false extension** — needed for `vm-netboot-ipxe.toml`
5. **Example TOMLs** — can be done in parallel once schemas are locked
6. **Docs + unified TOML** — last, after all interfaces settled

---

## v0.2 additions (done)

- **HTTPS / `--tls`**: `setup-netboot-dir.sh --tls` generates a self-signed
  cert (PEM + DER).  `build-ipxe.sh --tls [--tls-cert netboot.der]` compiles
  iPXE with `DOWNLOAD_PROTO_HTTPS` and embeds the cert in the binary trust
  store.  Use an `https://` `--server` URL with both flags together.
- **aarch64 iPXE**: `build-ipxe.sh --arch aarch64` → `bin-arm64-efi/ipxe.efi`
  (cross-compiled with `gcc-aarch64-linux-gnu` inside the Docker build container).
- **riscv64 iPXE**: `build-ipxe.sh --arch riscv64` → `bin-riscv-efi/ipxe.efi`
  (cross-compiled with `gcc-riscv64-linux-gnu`, `ARCH=riscv`).  Requires a
  2023+ iPXE commit (`--ipxe-ref master`).  Experimental upstream — no USB
  image, EFI only.  Boot via OpenSBI + U-Boot-EFI on QEMU `virt` or a
  RISC-V SBC with a UEFI firmware.
- **Phase 1 `write_files`**: `[[chroot.write_files]]` TOML table array writes
  arbitrary files into the chroot tree at `create` time (host-side, no
  `chroot exec`).  Replaces the "manual `/init` edit" step — specify
  `path = "/init"`, `mode = "0755"`, and `content = '''...'''` in TOML.
- **`lab-vm.sh publish-netboot`**: copies a `kernel+initrd`-backend VM's
  kernel and initrd to a netboot directory.  Optional `--generate-script
  --server URL` re-writes `boot.ipxe`.

## Open items / future work

- **DHCP/TFTP server** (traditional PXE): Not in scope — HTTP-only iPXE
  doesn't need it.
- **Signed iPXE** (Secure Boot): `bin-x86_64-efi/ipxe.efi` can be signed with
  a custom MOK key. Out of scope.
- **riscv64 real-hardware PXE**: Verified in QEMU; physical SBC boot depends
  on the board's UEFI/OpenSBI firmware chain.

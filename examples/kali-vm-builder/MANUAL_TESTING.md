# Kali VM factory — build & run, step by step

Two paths: a fast **headless smoke build** to prove the toolchain end-to-end,
then the **full graphical** image. Both produce a QCOW2 you boot with
`run-graphical.sh`.

## 0. Prereqs (host)

Pick an engine (see README "Choosing where the build runs"):

```bash
# Container path (recommended on Ubuntu/non-Kali hosts):
sudo apt install -y podman qemu-system-x86 qemu-utils
# Host-native path (Debian/Kali hosts, where debos is packaged):
sudo apt install -y 7zip debos dosfstools qemu-utils zerofree qemu-system-x86

# KVM access (needed by the debos build VM AND the graphical runner):
ls -l /dev/kvm                       # must exist
id -nG | tr ' ' '\n' | grep -qx kvm && echo "in kvm group" || echo "run: sudo adduser \$USER kvm ; then re-login"
```

Decide where the build lives (needs tens of GB free):

```bash
export KALI_VM_DIR=$HOME/kali-vm-build      # or a roomy disk, e.g. /media/.../kali-vm-build
```

## 1. Fetch the upstream builder (optional — build auto-fetches)

```bash
examples/kali-vm-builder/fetch-kali-vm.sh           # clones into $KALI_VM_DIR/kali-vm
examples/kali-vm-builder/fetch-kali-vm.sh --ref main --force   # pin/refresh
```

## 2. Headless smoke build (do this first)

```bash
examples/kali-vm-builder/build-kali-vm.sh --headless -y
```

What to expect, roughly in order:

1. `[build] engine: …  profile: headless` — engine resolved (podman/docker/host).
2. (container path, first run only) Podman/Docker **builds the Kali builder
   image** from the upstream Dockerfile — a one-time pull + apt.
3. The kali-vm summary box (`┏━━(Kali Linux VM Build)`), then **debos** boots its
   build VM and runs the recipe: debootstrap → apt the toolset → install GRUB →
   export QCOW2 → zerofree.
4. `[build] built image: …/images/kali-linux-rolling-qemu-amd64.qcow2` + the
   exact `run-graphical.sh` command.

If it dies with `No space left on device`, bump the scratch area:
`… build-kali-vm.sh --headless -y -- -- --scratchsize=60G` (the second `--`
forwards to debos).

## 3. Run it graphically

```bash
examples/kali-vm-builder/run-graphical.sh           # newest image, gtk window
```

- A QEMU window opens → GRUB → Kali boots → **log in `kali`/`kali`**.
- Confirm it's a real Kali (in the guest terminal):
  ```bash
  cat /etc/os-release | grep -i kali
  uname -r
  ```
- SSH route (optional): in the guest `sudo systemctl enable --now ssh`, then from
  the host `ssh -p 2222 kali@127.0.0.1`.

The runner boots a **copy-on-write overlay** under `$KALI_VM_DIR/run/`, so the
master image is untouched. `--snapshot` for a throwaway session; `--no-overlay`
to mutate the master; `--fresh` to reset the overlay.

## 4. Full graphical build (the real thing)

```bash
examples/kali-vm-builder/build-kali-vm.sh --full -y      # XFCE + default toolset — large, slow
examples/kali-vm-builder/run-graphical.sh --memory 6G --cpus 4
```

You should land in the **XFCE desktop** (the runner uses `usb-tablet`, so the
mouse tracks the window without capture). Customise at build time, e.g.:

```bash
examples/kali-vm-builder/build-kali-vm.sh --full -y -- -P metasploit-framework -U hacker:hunter2
```

## 5. Tear down

```bash
rm -rf "$KALI_VM_DIR/run"                 # overlays (cheap to recreate)
rm -f  "$KALI_VM_DIR"/kali-vm/images/*    # built images (multi-GB)
rm -rf "$KALI_VM_DIR"                      # everything incl. the upstream checkout
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| host build: `could not open kernel file … Permission denied` | Ubuntu/Debian ship `/boot/vmlinuz*` as `0600 root:root`; `debos`/`fakemachine` can't read the host kernel as your user. **Use a container engine** (`--engine podman`/`docker`) — it ships its own readable kernel — or `sudo chmod +r /boot/vmlinuz-$(uname -r)` (resets on kernel upgrades). `build-kali-vm.sh` now pre-checks this and stops early with the same advice. |
| built image vanished / `run-graphical.sh` can't find it after a **sudo** host build | `sudo` set `$HOME=/root`, so it built into `/root/kali-vm-build/…` (root-owned). `build-kali-vm.sh` now defaults to the invoking user's workdir (via `$SUDO_USER`) and chowns artifacts back. For one already stranded in `/root`: `sudo mv /root/kali-vm-build/kali-vm/images/*.qcow2 ~/kali-vm-build/kali-vm/images/ && sudo chown $USER ~/kali-vm-build/kali-vm/images/*.qcow2`, or just rebuild with `--engine podman` (rootless — writes as you). |
| `no usable engine` | install `debos` (host) or `podman`/`docker` (container), and ensure `/dev/kvm` exists. |
| debootstrap dies: `The certificate of '<mirror>' is not trusted` / `doesn't have a known issuer` | A mirror's HTTPS cert isn't trusted in the build VM. `build-kali-vm.sh` now **defaults** to Kali's Cloudflare CDN (`http://kali.download/kali`), which avoids this — you'd only hit it if you overrode the mirror back to the `http.kali.org` redirector. Re-pin a reliable mirror with `--mirror URL`. |
| background build reported "failed" with **exit 141** but the log says `Successful build!` | Old `yes \| build.sh` + `set -o pipefail`: `yes` gets SIGPIPE (141) when the build finishes. Fixed — `-y` now closes stdin (`< /dev/null`) instead, which auto-confirms without a pipe. |
| container build: KVM permission denied | add yourself to `kvm` (`sudo adduser $USER kvm`) and re-login; the runner passes `/dev/kvm` in. |
| build: `No space left on device` | scratch too small — append `-- --scratchsize=60G` (forwarded to debos), or free space / move `--workdir`. |
| runner drops to a **UEFI shell** | you booted it under UEFI — `run-graphical.sh` is BIOS-only by design; use it (don't add OVMF). |
| QEMU: `Could not access KVM` | `/dev/kvm` missing/inaccessible — the runner falls back to slow TCG with a warning; fix KVM for speed. |
| no window appears | `--display` needs an X/Wayland session; over SSH use `--display none` + the `--ssh-port` forward instead. |
| SSH refused | enable it in the guest first: `sudo systemctl enable --now ssh` (Kali ships sshd off). |

> **Verification status:** scripts are syntax-checked and option handling is
> exercised; a full end-to-end build/boot has **not** been run here yet.

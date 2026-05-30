# Kali non-root chroot

A **Phase-1 chroot** of Kali `kali-rolling` whose defining feature is a **non-root
user** (`kali`/`kali`, sudo; root login locked), plus a representative slice of the
Kali **top-10** security tools.

> ⚠️ **Authorized use only.** This builds a chroot containing offensive security
> tools (nmap, sqlmap, hydra, …). Use it only against systems you own or are
> explicitly authorized to test, on an isolated network. The `kali`/`kali`
> credential is a throwaway lab default — never ship it.

## Lineage

Adapted from Kali's live-build recipe
[`kali-linux-mate-top10-nonroot.sh`](https://gitlab.com/kalilinux/recipes/live-build-config-examples/-/blob/main/kali-linux-mate-top10-nonroot.sh).
That recipe builds a **live ISO** — MATE 1.8 desktop + `kali-linux-top10` tools —
and its whole point is enabling a **non-root** user (Kali's old default was to log
in as root; the recipe sets `passwd/root-login boolean false` and `make-user
boolean true` in the installer preseed).

This lab keeps that spirit but trades the heavy live-build/ISO pipeline for a
plain **chroot** built by `phase1-chroot/lab-chroot.sh`:

| Upstream recipe (live ISO) | This lab (chroot) |
|---|---|
| `lb build` → bootable Kali Live ISO | `lab-chroot.sh create` → a Kali chroot tree |
| MATE 1.8 from dead `mate-desktop.org/1.8` wheezy repos | (optional) `kali-desktop-mate` from kali-rolling — only meaningful once exported to a VM (a chroot has no GUI) |
| `kali-linux-top10` (commented out "for brevity") | a lean `nmap` + `sqlmap` slice by default; full `kali-tools-top10` documented below |
| preseed: `root-login false`, `make-user true` | `users = [kali]` + `passwd -l root` (root locked) |

## Two senses of "non-root"

1. **The result is non-root** — the chroot has a `kali` sudo user and the root
   password is locked, so `kali` is the only login. (The recipe's meaning.)
2. **The build can be non-root** — `lab-chroot.sh create --rootless` builds via
   `fakechroot` + `fakeroot`, no host root. See "Non-root build" below.

## What's in this directory

| File | Role |
|---|---|
| `kali-nonroot-chroot.toml` | The chroot spec: Kali kali-rolling, the `kali` non-root user, root locked, the top-10 tool slice. |
| `README.md` / `MANUAL_TESTING.md` | This file + the build/verify walkthrough. |

Everything else is the shared `phase1-chroot/lab-chroot.sh`.

## Build

A normal build uses `debootstrap`, which needs **root**:

```bash
sudo phase1-chroot/lab-chroot.sh create --config examples/kali-nonroot-chroot/kali-nonroot-chroot.toml
# → /var/chroots/kali-nonroot   (Kali base + kali user + nmap + sqlmap)

# enter as the non-root user and run a tool:
phase1-chroot/lab-chroot.sh enter kali-nonroot -- su - kali -c 'whoami; id; nmap --version'
# root is locked — `su - root` / login as root fails.
```

Prereq: the host needs the **`kali-archive-keyring`** package installed
(lab-chroot uses `/usr/share/keyrings/kali-archive-keyring.gpg` and will not
download the key) — see the [Kali FAQ](https://www.kali.org/docs/general-use/kali-linux-faq/).

### Non-root build (`--rootless`)

```bash
phase1-chroot/lab-chroot.sh create --rootless --backend debootstrap \
  --distro kali --suite kali-rolling --arch x86_64 \
  --target ~/kali-nonroot --include sudo,ca-certificates --user kali:kali
```

`--rootless` builds with `fakechroot`+`fakeroot` (no host root). **Caveat:** on
recent `debootstrap`/`dpkg` (e.g. Ubuntu 24.04), fakechroot can fail at the
core-package install step (`dpkg --install base-passwd`) — a known fakechroot
limitation, not a config problem. If you hit that, use the normal root build above.

### Full recipe (top-10 + MATE desktop)

For the complete upstream experience, install the full metapackages and turn the
chroot into a bootable VM (a chroot can't run a desktop):

```bash
# add to the TOML's post_commands apt-get install line:
#   kali-tools-top10     # the real top-10 (~3 GB — includes metasploit, burpsuite…)
#   kali-desktop-mate    # the MATE desktop
# heads-up: hydra + much of kali-tools-top10 pull heavy, transition-prone deps
# (e.g. hydra -> libfreerdp3 -> a mid-flight gcc-16 base).  On a freshly
# debootstrapped — therefore slightly stale — rolling chroot, run an upgrade first:
phase1-chroot/lab-chroot.sh enter kali-nonroot -- apt-get full-upgrade -y
# then boot it as a VM to get the actual MATE GUI:
phase2-qemu-vm/lab-vm.sh create --backend from-chroot --chroot /var/chroots/kali-nonroot ...
# (see examples/vm-from-chroot-debian.toml for the from-chroot pattern)
```

## What's verified

Built end-to-end with `sudo phase1-chroot/lab-chroot.sh create --config …` on
Ubuntu 24.04 → a Kali `kali-rolling` chroot with the **`kali` non-root sudo user**
(root password **locked**) and **`nmap` 7.99 + `sqlmap`** installed and **running
as `kali`** (`su - kali -c 'nmap --version'`).

Two non-obvious things were needed to get the tools in, both now handled by the
TOML (so a fresh `create` works unattended):

1. **`kali-archive-keyring` in `include`** — `lab-chroot` uses the *host* keyring
   only to verify the debootstrap *download*; the chroot's own apt needs the Kali
   key installed *inside* it or `apt-get update` fails OpenPGP verification
   ("Missing key …"). A `minbase` debootstrap doesn't pull it.
2. **Enable `contrib non-free non-free-firmware`** — debootstrap writes a
   `main`-only sources.list, but `nmap` lives in **`non-free`** (its NPSL license
   isn't DFSG-free), so `main`-only gives "Package 'nmap' has no installation
   candidate". A `post_commands` `sed` adds the components before the install.

`hydra` and the full `kali-tools-top10` are *not* in the default set: on this
date they hit a transient `kali-rolling` gcc-16 transition (via
`hydra -> libfreerdp3 -> libgomp1 -> gcc-16-base`) and need an `apt-get
full-upgrade` first (see "Full recipe").

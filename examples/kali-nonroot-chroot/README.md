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
| `kali-linux-top10` (commented out "for brevity") | a lean `nmap`/`sqlmap`/`hydra` slice by default; full `kali-tools-top10` documented below |
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
# → /var/chroots/kali-nonroot   (Kali base + kali user + nmap/sqlmap/hydra)

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
# add to the TOML's include (or post_commands apt-get install):
#   kali-tools-top10     # the real top-10 (~3 GB — includes metasploit, burpsuite…)
#   kali-desktop-mate    # the MATE desktop
# then boot it as a VM to get the actual MATE GUI:
phase2-qemu-vm/lab-vm.sh create --backend from-chroot --chroot /var/chroots/kali-nonroot ...
# (see examples/vm-from-chroot-debian.toml for the from-chroot pattern)
```

## What's verified

On this host (Ubuntu 24.04): the TOML parses and matches `lab-chroot.sh`'s spec
(`distro=kali` accepted, `users[]` + `post_commands[]` schema correct), the
`kali-archive-keyring` prereq is present, and a `--rootless` attempt confirmed the
Kali `kali-rolling` base **fetches + extracts** correctly (mirror + keyring +
suite all good) — it only stopped at fakechroot's `dpkg` core-install limitation
(above). A full root build needs `sudo` (debootstrap); this environment has no
passwordless sudo, so the end-to-end build wasn't run here — run the `sudo`
command above to complete it.

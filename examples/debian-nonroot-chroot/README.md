# Debian non-root chroot

A **Phase-1 chroot** of Debian whose defining feature is a **non-root user**
(`debian`/`debian`, sudo; root login locked) — and a hard look at building it
**without host root**. The Debian sibling of
[`../kali-nonroot-chroot/`](../kali-nonroot-chroot/).

## Two senses of "non-root"

1. **The result is non-root** — the chroot has a `debian` sudo user and the root
   password is locked, so `debian` is the only login.
2. **The build can be non-root** — `lab-chroot.sh create --rootless` builds via
   `fakechroot` + `fakeroot`, no host root. See [Non-root build](#non-root-build---rootless).

Unlike the Kali lab, Debian needs **no keyring/component gymnastics**: the demo
tools live in `main`, and `debian-archive-keyring` is standard — so there's no
`non-free` `sed` and no extra key to install (the Kali lab needs both, because
`nmap` is in `non-free` and Kali's archive key isn't on a Debian host).

## What's in this directory

| File | Role |
|---|---|
| `debian-nonroot-chroot.toml` | The chroot spec: Debian bookworm, the `debian` non-root user, root locked, a small `jq` + `cowsay` slice. |
| `README.md` / `MANUAL_TESTING.md` | This file + the build/verify walkthrough. |
| `ADDING-PACKAGES.md` | How to add a package (it's the last `post_commands` line). |

Everything else is the shared `phase1-chroot/lab-chroot.sh`.

## Build (normal — needs root for debootstrap)

```bash
sudo phase1-chroot/lab-chroot.sh create --config examples/debian-nonroot-chroot/debian-nonroot-chroot.toml
# → /var/chroots/debian-nonroot   (Debian base + debian user + root locked + jq + cowsay)

# enter as the non-root user:
phase1-chroot/lab-chroot.sh enter debian-nonroot -- su - debian -c 'whoami; id; cowsay "I am non-root"; jq --version'
# root is locked — `su - root` / login as root fails.
```

## Non-root build (`--rootless`)

```bash
phase1-chroot/lab-chroot.sh create --rootless --backend debootstrap \
  --distro debian --suite bookworm --arch x86_64 \
  --target ~/debian-nonroot --include sudo,ca-certificates --user debian:debian
```

`--rootless` runs `debootstrap --variant=fakechroot` under `fakechroot`+`fakeroot`
(the [muxup.com](https://muxup.com/2022q3/fully-userspace-managed-pristine-debootstrap-chroots-with-no-root-needed)
pattern) — **no real uid 0, no mounts**.

> **fakechroot is a CONVENIENCE wrapper, not a security sandbox** — a process that
> escapes the LD_PRELOAD jail runs as *you*, not root. Don't use `--rootless` to
> contain untrusted code.

### Honest caveat — the rootless "vise" (this is the lab's real lesson)

On a host whose **glibc is newer than the chroot's**, a full Debian base does
**not** finish rootless. fakechroot path-remaps the host's `chroot`/`fakeroot`
binaries onto the *chroot's* libc, so the chroot's glibc must be **≥** the host's;
but a glibc that new comes from a Debian release that also pulls **systemd**, whose
maintainer-script helpers die under fakechroot. There is no Debian release in the
sweet spot on a recent host. Measured here (Ubuntu 24.04, **glibc 2.39**,
**fakechroot 2.20.1**):

| distro / suite | glibc | `--rootless` result |
|---|---|---|
| **Debian bookworm 12** | 2.36 | base tree **builds** (no host root), but **can't be entered** — host `chroot` needs `GLIBC_2.38`, the bookworm libc only has 2.36 |
| Debian trixie 13 | 2.41 | build **fails**: `cron` postinst → `systemd-sysusers` → `libsystemd-shared-…so` not found under fakechroot |
| Ubuntu noble 24.04 | 2.39 | build **fails**: `mawk` postinst aborts (`SIGABRT`) under fakechroot |
| Kali kali-rolling | 2.41 | build **fails** at `base-passwd` (see [`../kali-nonroot-chroot/`](../kali-nonroot-chroot/)) |

So **bookworm is the suite whose rootless build gets furthest** — the base tree
debootstraps with **no host root at all** (verified). To actually *use* it
rootless you need a host whose glibc is **≤** the chroot's (a Debian 12 / Ubuntu
22.04 box), or the `from-chroot` VM bridge. On a newer host, finish the chroot
(the `debian` user, the root lock, the tools) with the **sudo** build above — which
runs the same `post_commands` under real root, where none of this applies.

> **Rule of thumb:** rootless `fakechroot` debootstrap is happiest when the
> **target distro == the host distro** (matching glibc) *and* the base is minimal
> (no systemd helpers). For a full systemd base on a mismatched host, use `sudo`.

## What's verified

- **The non-root *build*** — `--rootless` debootstrap of the **bookworm base tree**
  completes with **no host root** (a 356 MB tree owned by the invoking user, on
  this Ubuntu 24.04 host). The subsequent user/lock/tools steps hit the glibc wall
  above; that's the host, not the config.
- **The non-root *result*** — the **sudo** build produces the full chroot
  (confirmed 2026-06-11): a `debian` sudo user (`uid=1000(debian) …,sudo`), **root
  locked** (`passwd -S root → root L`), `Debian GNU/Linux 12 (bookworm)`, and `jq` +
  `cowsay` installed and running **as `debian`**. (See
  [`MANUAL_TESTING.md`](MANUAL_TESTING.md) for the exact checks.)

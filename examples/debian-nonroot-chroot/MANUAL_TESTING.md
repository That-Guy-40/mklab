# Debian non-root chroot — build & verify

Build the chroot and confirm both senses of "non-root": the **non-root result**
(sudo user, root locked) and the **non-root build** (`--rootless`).

## 0. Prereqs

```bash
command -v debootstrap fakechroot fakeroot || echo "install: debootstrap fakechroot fakeroot"
# No archive keyring to install on the host: Debian's is standard (the Kali lab
# needs kali-archive-keyring; Debian does not).
```

## 1. Build the full chroot (sudo — debootstrap needs root)

```bash
sudo phase1-chroot/lab-chroot.sh create \
  --config examples/debian-nonroot-chroot/debian-nonroot-chroot.toml
```

You should see: debootstrap of the `bookworm` base → `users: creating 'debian'`
→ post_commands: `passwd -l root` → `apt-get update && apt-get install … jq cowsay`.

## 2. Verify the non-root posture

```bash
# the debian user exists, is in sudo, /bin/bash:
phase1-chroot/lab-chroot.sh enter debian-nonroot -- id debian
# → uid=1000(debian) … groups=…,sudo

# root is LOCKED:
phase1-chroot/lab-chroot.sh enter debian-nonroot -- passwd -S root
# → root L …   (L = locked).  `su - root` would be refused.

# it IS a Debian tree:
phase1-chroot/lab-chroot.sh enter debian-nonroot -- grep PRETTY_NAME /etc/os-release
# → PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
```

## 3. Verify the tools run as the non-root user

```bash
phase1-chroot/lab-chroot.sh enter debian-nonroot -- su - debian -c 'whoami; jq --version; cowsay "I am non-root"'
# whoami → debian ; jq + cowsay run as the unprivileged user.
```

## 4. The non-root build (`--rootless`) — what works, and the wall

```bash
phase1-chroot/lab-chroot.sh create --rootless --backend debootstrap \
  --distro debian --suite bookworm --arch x86_64 \
  --target ~/debian-nonroot --include sudo,ca-certificates --user debian:debian
```

**Verified here (Ubuntu 24.04, glibc 2.39):** the **bookworm base tree
debootstraps with no host root** —

```
I: Base system installed successfully.
[info] debootstrap complete: … → /home/you/debian-nonroot          ← a ~356 MB tree, owned by YOU
```

— then the post-build step that re-enters the tree hits the glibc wall:

```
[warn] users: useradd 'debian' returned non-zero …
/usr/sbin/chroot: …/libc.so.6: version `GLIBC_2.38' not found (required by /usr/sbin/chroot)
```

That's the **vise** (README's matrix): the host's `chroot` binary, path-remapped
onto the chroot's older libc (2.36), needs symbols it doesn't have. To finish the
chroot rootless you need a host with **glibc ≤ the chroot's** (Debian 12 / Ubuntu
22.04), or the `from-chroot` VM bridge; otherwise use the **sudo** build (step 1).

## 5. Tear down

```bash
sudo phase1-chroot/lab-chroot.sh destroy debian-nonroot --force   # removes /var/chroots/debian-nonroot
rm -rf ~/debian-nonroot                                            # the rootless tree, if you built it
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| build needs root / `sudo` prompts | debootstrap requires root; expected. Use `--rootless` for a root-free build (caveats below). |
| `--rootless`: `chroot: … GLIBC_2.x not found` after "Base system installed" | the chroot's glibc is **older** than the host's; fakechroot remapped the host `chroot`/`fakeroot` onto it. Build on a host whose glibc ≤ the chroot's, or `sudo`. (Debian bookworm 2.36 vs an Ubuntu-24.04 host's 2.39.) |
| `--rootless` trixie/noble/kali: `systemd-sysusers`/`mawk`/`base-passwd` errors mid-build | a maintainer script runs a helper fakechroot 2.20.1 can't (systemd's private lib, a SIGABRT, dpkg's core install). Full systemd bases don't finish rootless here — use `sudo`. |
| want a bootable VM, not just a chroot | export via the `from-chroot` bridge — see [`../offsec-awae-vm/`](../offsec-awae-vm/) / [`../kali-nonroot-chroot/ADDING-PACKAGES.md`](../kali-nonroot-chroot/ADDING-PACKAGES.md). |

> **Verified (2026-06-11, Ubuntu 24.04 host, glibc 2.39) — both senses of non-root:**
> - **Non-root *build*** — `--rootless` debootstraps the bookworm **base tree** with
>   **no host root** (a 356 MB tree owned by the invoking user). The rootless
>   *finish* (user/lock/tools) hits the glibc wall (README matrix); that's the host.
> - **Non-root *result*** — the **sudo** build produces the full chroot:
>   ```
>   id debian        → uid=1000(debian) gid=1000(debian) groups=1000(debian),27(sudo)
>   passwd -S root    → root L …                          # locked
>   /etc/os-release   → PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
>   su - debian -c …  → whoami=debian ; jq-1.6 ; cowsay "non-root" (runs as the user)
>   ```

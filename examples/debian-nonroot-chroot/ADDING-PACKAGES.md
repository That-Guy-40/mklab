# Adding a package — `debian-nonroot-chroot`

This lab is a **Phase-1 chroot only** (`backend = "debootstrap"`, no `[[vm]]`).
Packages are installed by **`apt` inside the chroot**, driven by the last entry of
the `[[chroot]] post_commands` array. So "add a package" = edit that line (for a
correct from-scratch rebuild) **and** install it into the chroot you already have
(so you don't re-debootstrap).

## Where packages are declared

`debian-nonroot-chroot.toml`, the install line in `post_commands`:

```toml
"export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8; apt-get update && apt-get install -y --no-install-recommends jq cowsay",
```

Debian's `main` is enabled by the bare debootstrap sources.list, so anything in
`main` installs with no extra setup — **no `non-free`/`sed` and no extra key**
(the Kali lab needs both for `nmap`). If you want a package from `contrib`,
`non-free`, or `non-free-firmware`, add an earlier `post_commands` `sed` first:

```toml
"sed -i 's/ main$/ main contrib non-free non-free-firmware/' /etc/apt/sources.list",
```

## Add one

1. **Edit the TOML install line** — append the package name(s), space-separated,
   before the closing quote. To add `tree` and `htop`:
   ```toml
   "… apt-get update && apt-get install -y --no-install-recommends jq cowsay tree htop",
   ```

2. **Install into the existing chroot** (fast — no re-debootstrap). The chroot is
   named `debian-nonroot`:
   ```bash
   sudo phase1-chroot/lab-chroot.sh enter debian-nonroot -- sh -c 'apt-get update && apt-get install -y --no-install-recommends tree htop'
   ```

3. **Verify** — `dpkg -l … | grep ^ii` inside the chroot:
   ```bash
   sudo phase1-chroot/lab-chroot.sh enter debian-nonroot -- dpkg -l tree htop | grep ^ii
   ```

## Notes

- **Avoid systemd-heavy packages in a `--rootless` build.** Maintainer scripts that
  call systemd helpers (e.g. `systemd-sysusers`) fail under `fakechroot`. In a
  `sudo` (real-root) build they're fine. Keep the rootless set minimal (the base +
  `main` CLI tools like `jq`, `cowsay`, `tree`); see the README's rootless matrix.
- **Optional: turn the chroot into a bootable VM** via the `from-chroot` bridge —
  see [`../offsec-awae-vm/`](../offsec-awae-vm/). The chroot must live under the
  lab state dir for that backend; rebuild with the target there first.

## TL;DR

```bash
# 1. add the pkg to the TOML install line (keeps from-scratch builds correct)
# 2. install into the existing chroot:
sudo phase1-chroot/lab-chroot.sh enter debian-nonroot -- sh -c 'apt-get update && apt-get install -y <pkg>'
# 3. verify:
sudo phase1-chroot/lab-chroot.sh enter debian-nonroot -- dpkg -l <pkg> | grep ^ii
```

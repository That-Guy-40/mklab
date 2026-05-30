# Adding a package — `kali-nonroot-chroot`

This lab is a **Phase-1 chroot only** (`backend = "debootstrap"`, no `[[vm]]`).
Packages are installed by **`apt` inside the chroot**, driven by the last entry
of the `[[chroot]] post_commands` array. So "add a package" = edit that line
(for a correct from-scratch rebuild) **and** install it into the chroot you
already have (so you don't re-debootstrap).

> This is the closest lab to the `offsec-awae-vm` workflow, with one difference:
> there's **no VM step** here — the artifact is the chroot tree itself. (Turning
> it into a bootable VM is an optional bridge; see the bottom of this file.)

## Where packages are declared

`kali-nonroot-chroot.toml`, the install line in `post_commands`:

```toml
"export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8; apt-get update && apt-get install -y --no-install-recommends nmap sqlmap",
```

All four apt components (`main contrib non-free non-free-firmware`) are already
enabled by an earlier `post_commands` `sed`, so non-free tools (e.g. `nmap`,
whose NPSL license isn't DFSG-free) install fine.

## Add one

1. **Edit the TOML install line** — append the package name(s), space-separated,
   before the closing quote. To add `wpscan` and `hydra`:
   ```toml
   "… apt-get update && apt-get install -y --no-install-recommends nmap sqlmap wpscan hydra",
   ```
   This keeps a future from-scratch rebuild correct.

2. **Install into the existing chroot** (fast — no re-debootstrap). The chroot is
   named `kali-nonroot`:
   ```bash
   sudo phase1-chroot/lab-chroot.sh enter kali-nonroot -- sh -c 'apt-get update && apt-get install -y --no-install-recommends wpscan hydra'
   ```

3. **Verify** — `dpkg -l … | grep ^ii` inside the chroot:
   ```bash
   sudo phase1-chroot/lab-chroot.sh enter kali-nonroot -- dpkg -l wpscan hydra | grep ^ii
   ```

## Notes

- **Heavy / transition-prone deps.** `hydra` and the full `kali-tools-top10` pull
  large, fast-moving deps (e.g. `hydra → libfreerdp3 → a mid-flight gcc base`).
  On a freshly-debootstrapped (therefore slightly stale) rolling chroot, run an
  upgrade first if an install won't resolve:
  ```bash
  sudo phase1-chroot/lab-chroot.sh enter kali-nonroot -- apt-get full-upgrade -y
  ```
- **Optional: turn the chroot into a bootable VM** via the `from-chroot` bridge
  (see `examples/offsec-awae-vm/`). Caveat: that backend requires the chroot to
  live under `/var/lib/lab-create/chroots/`, but this lab's `target` is
  `/var/chroots/kali-nonroot` — so you'd rebuild with the target under the state
  dir first. After that it's the offsec-awae flow (`firmware = "bios"`, generic
  dracut initramfs, a kernel in the chroot — see that lab's `README.md` and
  `INITRAMFS-TROUBLESHOOTING.md`).

## TL;DR

```bash
# 1. add the pkg to the TOML install line (keeps from-scratch builds correct)
# 2. install into the existing chroot:
sudo phase1-chroot/lab-chroot.sh enter kali-nonroot -- sh -c 'apt-get update && apt-get install -y <pkg>'
# 3. verify:
sudo phase1-chroot/lab-chroot.sh enter kali-nonroot -- dpkg -l <pkg> | grep ^ii
```

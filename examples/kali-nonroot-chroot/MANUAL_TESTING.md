# Kali non-root chroot — build & verify

Build the chroot and confirm the non-root posture + the tools, with the host-side
checks for each stage.

## 0. Prereqs

```bash
# debootstrap + the Kali keyring on the host (lab-chroot won't fetch the key):
dpkg -s kali-archive-keyring >/dev/null 2>&1 && echo "keyring present" || \
  echo "install it: sudo apt-get install kali-archive-keyring  (see the Kali FAQ)"
command -v debootstrap || echo "install debootstrap"
```

## 1. Build (needs root for debootstrap)

```bash
sudo phase1-chroot/lab-chroot.sh create \
  --config examples/kali-nonroot-chroot/kali-nonroot-chroot.toml
```

You should see: debootstrap fetch/extract of the `kali-rolling` base (it pulls
`kali-archive-keyring`, so the chroot's apt is trusted) → `users: creating 'kali'`
→ post_commands: `passwd -l root` → a `sed` enabling `contrib non-free
non-free-firmware` → `apt-get update && apt-get install … nmap sqlmap`.

## 2. Verify the non-root posture

```bash
C=/var/chroots/kali-nonroot

# the kali user exists, is in sudo, /bin/bash:
phase1-chroot/lab-chroot.sh enter kali-nonroot -- id kali
# → uid=1000(kali) … groups=…,sudo

# root is LOCKED (the recipe's "root-login false"):
phase1-chroot/lab-chroot.sh enter kali-nonroot -- passwd -S root
# → root L …   (L = locked).  `su - root` would be refused.

# it IS a Kali tree:
phase1-chroot/lab-chroot.sh enter kali-nonroot -- cat /etc/os-release | grep -i kali
```

## 3. Verify the tools run as the non-root user

```bash
phase1-chroot/lab-chroot.sh enter kali-nonroot -- su - kali -c 'whoami; nmap --version; sqlmap --version'
# whoami → kali ; the top-10 tools run as the unprivileged user.
```

## 4. Tear down

```bash
sudo phase1-chroot/lab-chroot.sh destroy kali-nonroot --force   # removes /var/chroots/kali-nonroot
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `missing /usr/share/keyrings/kali-archive-keyring.gpg` (host) | install `kali-archive-keyring` on the **host** (lab-chroot won't download the key — it verifies the debootstrap *download*). |
| apt in the chroot: `OpenPGP signature verification failed … Missing key …` | the **chroot's** apt has no Kali key — `kali-archive-keyring` wasn't installed *inside* it. The lab now puts it in `include`; rebuild, or for an existing chroot `apt-get install --reinstall kali-archive-keyring`. |
| `Package 'nmap' has no installation candidate` (verification OK) | `nmap` is in **`non-free`**, but a debootstrap sources.list only enables `main`. The lab now enables the full component set via a `post_commands` `sed`; for an existing chroot, add `contrib non-free non-free-firmware` to `/etc/apt/sources.list` then `apt-get update`. |
| `hydra`/`kali-tools-top10`: unmet deps / `gcc-16-base … not installable` | a transient `kali-rolling` transition pulled in by hydra's heavy chain (`libfreerdp3 → libgomp1 → gcc-16-base`). Run `apt-get full-upgrade -y` first, then install. (Why the default tool set is just `nmap`+`sqlmap`.) |
| build needs root / `sudo` prompts | debootstrap requires root; this is expected. Use `--rootless` for a root-free build (caveat below). |
| `--rootless` fails at `dpkg --install base-passwd` | fakechroot can't run dpkg's core-package install on recent debootstrap/dpkg — a known fakechroot limitation, not a config issue. Use the normal root build. |
| want the MATE desktop | a chroot has no GUI — add `kali-desktop-mate` + export to a VM via `from-chroot` (see README "Full recipe"). |

> **Verified end-to-end** with `sudo lab-chroot.sh create --config …` on Ubuntu
> 24.04: the Kali `kali-rolling` chroot built with the **`kali` non-root sudo user**
> (root **locked**) and **`nmap` 7.99 + `sqlmap`** installed and **running as
> `kali`**. The two things needed to get the tools in — `kali-archive-keyring` in
> `include` (chroot apt key) and enabling `contrib non-free non-free-firmware`
> (`nmap` is in `non-free`) — are now both in the TOML.

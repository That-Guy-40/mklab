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

You should see: debootstrap fetch/extract of the `kali-rolling` base from
`http.kali.org` → `users: creating 'kali'` → `post_command[0]: passwd -l root`
→ `post_command[1]: … apt-get install … nmap sqlmap hydra`.

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
phase1-chroot/lab-chroot.sh enter kali-nonroot -- su - kali -c 'whoami; nmap --version; sqlmap --version; hydra -h 2>&1 | head -1'
# whoami → kali ; the top-10 tools run as the unprivileged user.
```

## 4. Tear down

```bash
sudo phase1-chroot/lab-chroot.sh destroy kali-nonroot --force   # removes /var/chroots/kali-nonroot
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `missing /usr/share/keyrings/kali-archive-keyring.gpg` | install `kali-archive-keyring` on the **host** (lab-chroot won't download the key — it verifies the *download*). |
| post-install apt fails: `OpenPGP signature verification failed … Missing key …` / `Package 'nmap' has no installation candidate` | the **chroot's** apt has no Kali key — `kali-archive-keyring` wasn't installed *inside* it. It's now in this lab's `include`, so rebuild. To fix an **existing** chroot in place: `sudo cp /usr/share/keyrings/kali-archive-keyring.gpg /var/chroots/kali-nonroot/etc/apt/trusted.gpg.d/` then `sudo lab-chroot.sh enter kali-nonroot -- bash -c 'apt-get update && apt-get install -y --no-install-recommends kali-archive-keyring nmap sqlmap hydra'`. |
| build needs root / `sudo` prompts | debootstrap requires root; this is expected. Use `--rootless` for a root-free build (caveat below). |
| `--rootless` fails at `dpkg --install base-passwd` | fakechroot can't run dpkg's core-package install on recent debootstrap/dpkg — a known fakechroot limitation, not a config issue. Use the normal root build. |
| want the MATE desktop | a chroot has no GUI — add `kali-desktop-mate` + export to a VM via `from-chroot` (see README "Full recipe"). |

> **Verified on this host (Ubuntu 24.04):** TOML parses + matches lab-chroot's
> spec; `kali-archive-keyring` present; a `--rootless` attempt confirmed the Kali
> `kali-rolling` base fetches + extracts (mirror/keyring/suite correct), stopping
> only at fakechroot's dpkg limitation. The full root build needs `sudo`
> (debootstrap) — not run end-to-end here (no passwordless sudo); the `sudo`
> command in step 1 completes it.

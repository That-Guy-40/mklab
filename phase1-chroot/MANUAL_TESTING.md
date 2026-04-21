# Phase 1 — Manual Testing Walkthrough

A copy-pasteable, step-by-step manual exercise of `lab-chroot.sh`. Run top
to bottom on a clean Debian / Ubuntu host (most thorough coverage). Each
step says what to expect and how to recognise breakage.

> **Set up a working dir for the run:**
> ```bash
> cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
> alias lc='sudo phase1-chroot/lab-chroot.sh'
> sudo mkdir -p /var/chroots /var/jails /srv/ftpjail /var/lib/lab-create
> ```

## 0. Preflight — install the host packages you'll need

Pick what you want to exercise; not everything is required for every test.

```bash
sudo apt-get update
sudo apt-get install -y \
    jq file \
    debootstrap \
    debian-archive-keyring ubuntu-keyring \
    schroot systemd-container \
    qemu-user-static binfmt-support \
    dnf rpm
# pick ONE TOML parser:
sudo apt-get install -y yq                 # mikefarah/yq (preferred)
# or:  pipx install yq                     # kislyuk/yq → tomlq
# or:  grab dasel from https://github.com/tomwright/dasel
```

> `sudo` is assumed already present and is not installed by these steps — every
> chroot operation needs root. If you're already root, drop the `sudo` prefix
> from the rest of this walkthrough.
>
> `file` is only used by `test-host-copy-static-binary.sh` to detect static
> binaries; the test has a fallback if it's missing, but having `file` makes
> the test take the fast path.
>
> The `dnf` backend additionally needs `rpm` on the host: dnf shells out to
> `rpmkeys` to verify RPM GPG signatures, and on Debian/Ubuntu the `dnf`
> package alone only pulls `rpm-common` (no `rpmkeys` binary). Without
> `rpm` installed, the dnf bootstrap downloads every package successfully
> and then explodes with "Cannot find rpmkeys executable to verify
> signatures." for each one. The script's preflight catches this and
> tells you exactly what to install.

Verify:

```bash
phase1-chroot/lab-chroot.sh version       # → "lab-chroot.sh 0.1.0"
phase1-chroot/lab-chroot.sh help          # → full usage
phase1-chroot/lab-chroot.sh list          # → empty table + schroot/machinectl sections
```

## 1. host-copy backend (no network, fastest smoke test)

Builds a chroot containing one binary plus everything `ldd` says it needs.

```bash
lc create \
    --backend host-copy \
    --target  /var/jails/ls-only \
    --binaries /bin/ls
```

**Expect:** "host-copy: copied N files (binaries + libs + loader)" and
"host-copy complete: ls-only → /var/jails/ls-only".

**Inspect:**

```bash
sudo ls -la /var/jails/ls-only/{bin,lib*,lib64} 2>/dev/null
lc list                                   # → row for "ls-only"
lc verify ls-only                         # → reports target / no os-release / exec test OK
```

**Enter and use it:**

```bash
lc enter ls-only -- /bin/ls /
```

**Expect:** lists the chroot root (which is mostly empty — that's the point).

**Destroy (with prompt):**

```bash
lc destroy ls-only                         # answer y
lc list                                    # → row gone
ls /var/jails/ls-only 2>&1                 # → No such file
```

## 2. host-copy with extras (vsftpd-jail style, busybox)

```bash
lc create \
    --backend host-copy \
    --target /var/jails/busybox \
    --binaries /bin/busybox \
    --extras  /etc/resolv.conf,/etc/nsswitch.conf,/etc/passwd,/etc/group
```

**Expect:** copies busybox, all required libs, the loader, and the `extras`.

```bash
lc enter busybox -- /bin/busybox sh -c 'ls / && echo --- && cat /etc/resolv.conf'
lc destroy busybox --force
```

## 3. host-copy via TOML config (parity check)

```bash
lc create --config examples/chroot-host-copy-busybox.toml
lc list                                    # → "minimal-busybox"
lc enter minimal-busybox -- /bin/busybox echo hello
lc destroy minimal-busybox --force
```

**Expect:** identical behavior to step 2. The `test-cli-vs-config-parity.sh`
test compares trees byte-for-byte; you can run it to mechanise this:

```bash
sudo phase1-chroot/tests/test-cli-vs-config-parity.sh
```

## 4. Native debootstrap (Debian bookworm)

This pulls ~150 MB from the network and takes 1–3 minutes.

```bash
lc create \
    --backend debootstrap --distro debian --suite bookworm \
    --arch x86_64 --target /var/chroots/bookworm-amd64 \
    --variant minbase
```

**Expect:**
- A `[info]` line at start: "debootstrap (native): debian/bookworm arch=x86_64 ..."
- Many lines of debootstrap progress (validating, retrieving, extracting, etc.)
- Final "debootstrap complete: bookworm-amd64 → ..."

**Inspect:**

```bash
lc verify bookworm-amd64
# → os: Debian GNU/Linux 12 (bookworm)
# → uname -m: x86_64
# → exec test: /bin/ls OK
```

**Enter, install something, exit:**

```bash
lc enter bookworm-amd64
# inside the chroot:
apt-get update && apt-get install -y vim-tiny
which vim.tiny
exit
```

Leave this one in place; we'll reuse it below.

## 5. Foreign-arch debootstrap (aarch64 from x86_64 host)

Needs `qemu-user-static` and `binfmt-support`. Verify first:

```bash
ls /proc/sys/fs/binfmt_misc/qemu-aarch64    # must exist
sudo update-binfmts --enable qemu-aarch64    # if it doesn't
```

Build:

```bash
lc create \
    --backend debootstrap --distro debian --suite bookworm \
    --arch aarch64 --target /var/chroots/bookworm-arm64 \
    --variant minbase
```

**Expect:**
- "debootstrap (foreign first stage)" then
- "debootstrap (foreign second stage)"
- Total time: 5–10 minutes (everything in stage 2 runs under qemu-user emulation)

**Verify the arch is real:**

```bash
sudo chroot /var/chroots/bookworm-arm64 /usr/bin/uname -m   # → aarch64
sudo chroot /var/chroots/bookworm-arm64 /usr/bin/file /bin/ls   # → ARM aarch64
```

**Cleanup:**

```bash
lc destroy bookworm-arm64 --force
```

## 6. Rocky 9 via dnf (native arch)

Needs `dnf` on the host (works on Debian: `apt-get install dnf`).

```bash
lc create \
    --backend dnf --distro rocky --suite 9 \
    --arch x86_64 --target /srv/rocky9-base \
    --include bash,coreutils,vim-minimal
```

**Expect:**
- "dnf install (9/x86_64) → /srv/rocky9-base"
- A few minutes of dnf output
- "dnf complete: rocky9-base → /srv/rocky9-base"

**Verify and use:**

```bash
lc verify rocky9-base
# → os: Rocky Linux 9.x ...
# → uname -m: x86_64
sudo chroot /srv/rocky9-base /bin/rpm -q rocky-release
```

## 7. Rocky 9 vsftpd jail (TOML config example)

```bash
lc create --config examples/chroot-rocky9-vsftpd.toml
lc verify rocky9-vsftpd
sudo chroot /srv/ftpjail /usr/sbin/vsftpd -version 2>&1 | head -1
```

**Expect:** vsftpd version line. The chroot has the FTP server and its
runtime deps.

```bash
lc destroy rocky9-vsftpd --force
lc destroy rocky9-base    --force
```

## 8. Manager: schroot (round-trip)

Re-use the bookworm chroot from step 4, or build a fresh one with
`--manager schroot`:

```bash
lc create \
    --backend host-copy --target /var/jails/sc-test \
    --binaries /bin/busybox \
    --manager schroot
```

**Expect:** plus the usual host-copy output:
- "schroot: writing /etc/schroot/chroot.d/sc-test.conf"
- The conf file exists with `[sc-test]`, `type=directory`, `directory=...`

**Verify schroot sees it:**

```bash
schroot -l                                 # → chroot:sc-test
# Direct schroot needs --directory / because schroot otherwise tries to
# chdir to your shell's CWD inside the chroot (which usually doesn't exist
# there). Our `lc enter` wrapper passes this flag automatically.
sudo schroot -c sc-test --directory / -- /bin/busybox echo hello
sudo lc enter sc-test -- /bin/busybox echo hello   # equivalent, no -d needed
```

**Destroy cleans up the conf:**

```bash
lc destroy sc-test --force
ls /etc/schroot/chroot.d/sc-test.conf 2>&1   # → No such file
```

## 9. Manager: systemd-nspawn (round-trip)

```bash
lc create \
    --backend host-copy --target /var/jails/ns-test \
    --binaries /bin/busybox \
    --manager nspawn
```

**Expect:** plus host-copy output:
- "nspawn: registered as machinectl image: /var/lib/machines/ns-test → /var/jails/ns-test"

**Verify machinectl sees it:**

```bash
machinectl list-images                     # → ns-test row
sudo systemd-nspawn --quiet -D /var/jails/ns-test -- /bin/busybox echo hello
```

**Destroy:**

```bash
lc destroy ns-test --force
ls -l /var/lib/machines/ns-test 2>&1       # → No such file
```

## 10. Manager: nspawn with `boot = true` (full systemd inside)

This requires a chroot with systemd installed. Build one:

```bash
lc create --config examples/chroot-nspawn-managed.toml
```

**Expect:** debootstrap pulls systemd + dbus, then nspawn registers it.

**Boot it under nspawn:**

```bash
sudo systemd-nspawn -b -M bookworm-nspawn
# wait for the login prompt; default credentials per nspawn are the host's
# (login as root, no password by default in fresh nspawn debian images
#  — or use the `passwd root` step inside the chroot first if locked down)
```

To shut down cleanly from another terminal:

```bash
sudo machinectl poweroff bookworm-nspawn
```

**Tear down:**

```bash
lc destroy bookworm-nspawn --force
```

## 11. Validation guardrails

These should all fail **before** any I/O happens.

**Unknown backend:**
```bash
lc create --backend bogus --target /tmp/x
# → [error] spec (x) unknown backend: bogus
```

**Unknown manager:**
```bash
lc create --backend host-copy --target /tmp/x --binaries /bin/ls --manager bogus
# → [error] spec (x) unknown manager: bogus
```

**Rocky armv7l (unsupported upstream):**
```bash
lc create --backend dnf --distro rocky --suite 9 --arch armv7l --target /tmp/x
# → [error] spec (...) Rocky Linux does not publish builds for arch=armv7l.
```

**Kali keyring missing** (only meaningful if `kali-archive-keyring` is **not** installed):
```bash
lc create --backend debootstrap --distro kali --suite kali-rolling \
          --arch x86_64 --target /tmp/x
# → [error] missing /usr/share/keyrings/kali-archive-keyring.gpg ...
```

**Target already non-empty:**
```bash
mkdir -p /tmp/notempty && touch /tmp/notempty/foo
lc create --backend host-copy --target /tmp/notempty --binaries /bin/ls
# → [error] /tmp/notempty already exists and is not empty
rm -rf /tmp/notempty
```

## 12. Bookworm chroot bind-mount cleanup (manager=none)

```bash
lc create --backend host-copy --target /var/jails/bm-test --binaries /bin/busybox

# Start an enter, then ctrl-c the shell instead of exiting cleanly:
lc enter bm-test         # ctrl-c immediately at the prompt

# The trap should still unmount; verify:
mount | grep /var/jails/bm-test     # → empty
cat /var/jails/bm-test/.lab-chroot-mounts 2>&1   # → No such file (cleared)

lc destroy bm-test --force
```

If you ever see leftover mounts, `lc destroy <name>` (or running `enter`
then exiting cleanly) will clear them.

## 13. Run the automated suite to mechanise the rest

```bash
sudo phase1-chroot/tests/run-all.sh
```

Each test self-skips (exit 77) if its preconditions aren't met. Expect:

- `test-host-copy.sh` — pass
- `test-debootstrap-amd64.sh` — pass on x86_64 hosts with debootstrap
- `test-debootstrap-arm64-foreign.sh` — pass with `qemu-user-static` + binfmt
- `test-dnf-rocky9.sh` — pass with `dnf` on host
- `test-schroot-integration.sh` — pass with `schroot`
- `test-nspawn-integration.sh` — pass with `systemd-nspawn`
- `test-cli-vs-config-parity.sh` — pass
- `test-kali-keyring-missing.sh` — skips if keyring is installed; passes otherwise
- `test-rocky-armv7l-rejection.sh` — pass

## 14. Final cleanup

```bash
lc list                                    # any leftovers?
# destroy each by name
sudo rm -rf /var/lib/lab-create/chroots    # nuke all state if you want a clean slate
```

## When something goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| `[error] no TOML parser found` | None of `tomlq`, `yq` (mikefarah), `dasel` on host | `apt-get install yq` |
| `[error] qemu-aarch64-static not found` | `qemu-user-static` not installed | `apt-get install qemu-user-static binfmt-support` |
| Foreign-arch second stage hangs/segfaults | binfmt not registered with `--fix-binary` flag | `update-binfmts --enable qemu-<arch>`; if persists, restart `systemd-binfmt` |
| `[error] missing kali-archive-keyring.gpg` | Working as designed — install the host package | `apt-get install kali-archive-keyring` (Debian sid/Kali) |
| `dnf` fails with GPG check on Rocky | Repo metadata transient issue | retry; if persistent, check `download.rockylinux.org` reachability |
| Leftover bind-mounts after a crash | `enter` was killed before its trap ran | `lc destroy <name> --force` reverses everything tracked in `<target>/.lab-chroot-mounts` |

Reach for `LAB_LOG_LEVEL=debug` to see the underlying commands the script
runs (`debootstrap` invocation, `dnf` flags, qemu-static copy path, etc.):

```bash
LAB_LOG_LEVEL=debug lc create ...
```

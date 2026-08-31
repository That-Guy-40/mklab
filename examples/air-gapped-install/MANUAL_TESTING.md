# air-gapped-install — Manual Testing

## Part 1 — the automated half  ✅ verified (host-only, no root, 2026-08-30)

```bash
examples/air-gapped-install/airgap.sh mirror     # the only step that needs the network
examples/air-gapped-install/tests/run-all.sh
```

```
=== test-airgap-install.sh ===
  - installed Debian 13.6 — 78 packages, all from the loopback mirror
  - 5 rows: the air gap, three refusals each on its own reason, one success
PASS: a Debian 13.6 base system (78 packages) installed from the local signed mirror inside a
      namespace whose only interface is loopback, and all five control rows behaved …

=== test-the-air-gap-is-real.sh ===
  - the designed catch fired: upstream answered, and the run refused to print a result that
    would be read as an offline install
PASS: with the network namespace removed, the same control rows refuse to produce a verdict …

summary: 4/4 discovered tests ran (4 test files on disk) — 4 passed, 0 skipped, 0 failed
```

Requires `debootstrap`, `unshare`, `ip`, `python3`, `curl`, `gpg`/`gpgv`, and a
`/etc/subuid` + `/etc/subgid` range for your user (`unshare --map-auto` needs it to map the
ids `debootstrap` unpacks — without it `tar` aborts partway through the base system, and
the failure looks like a corrupt mirror). Each of those is checked by name and produces a
`SKIP` with a reason rather than a confusing failure.

**Watch a control fire.** The point of the suite is that its assertions are attached to
something. Two you can break by hand:

```bash
# 1. the air gap. Same code, no namespace: it must refuse to print a verdict at all.
examples/air-gapped-install/airgap.sh __inside controls    # -> "THE AIR GAP IS OPEN"

# 2. the signature. Hand the installer a key that did not sign this mirror.
#    (This is exactly control row C2, which `controls` runs for you.)
```

---

## Part 2 — the rooted full install  ⏳ author-run

`airgap.sh install` runs `debootstrap --foreign`, which stops after downloading and
unpacking. The **second stage** (`dpkg --configure`) needs real root — and does no network
I/O at all, which is why the rootless half is the half that answers the mirror question.
To finish the tree you already have:

```bash
sudo chroot examples/air-gapped-install/state/rootfs /debootstrap/debootstrap --second-stage
sudo chroot examples/air-gapped-install/state/rootfs dpkg -l | tail -5
```

To do the **whole** install as root, through the phase-1 driver rather than a one-off — this
is what `--keyring` was added for (TODO 15.5), and it is the only way in the repo to install
from a mirror signed by a key that is not the distro's:

```bash
# serve the mirror on loopback (a separate terminal, or background it)
examples/air-gapped-install/airgap.sh serve &

sudo phase1-chroot/lab-chroot.sh create \
    --backend debootstrap --distro debian --suite trixie --arch x86_64 \
    --variant minbase \
    --mirror  http://127.0.0.1:8099 \
    --keyring "$PWD/examples/air-gapped-install/state/mirror-key.gpg" \
    --target  /var/chroots/airgap --name airgap

sudo phase1-chroot/lab-chroot.sh enter airgap    # a fully configured base system
```

> This one is **not** air-gapped — it runs on the host, which has a route. It closes the
> *second stage*, not the *isolation*; Part 1 is what proves the isolation. Saying which
> question each half answers is the whole reason they are separate sections.

To have it be both, run the `create` inside the namespace:

```bash
sudo unshare -n --  sh -c 'ip link set lo up; exec …'      # the mirror server must be
                                                            # started inside it too
```

**Cleanup:** `sudo phase1-chroot/lab-chroot.sh destroy airgap --force`, then
`examples/air-gapped-install/airgap.sh clean` (removes `state/`: the mirror, the throwaway
key, the bootstrapped trees and the control logs). Kill the `serve` process **by PID** —
`pgrep -f 'http.server 8099'`, eyeball the hit, then `kill <pid>`; its cmdline carries the
mirror path, and so would anything else this lab is running.

---

## Part 3 — the d-i / preseed half against `package-mirror-ram`  ⏳ author-run

This is claim 5 in the README, and the one that makes
[`package-mirror-ram`](../package-mirror-ram/README.md)'s ⏳ half consumer-proven at full
fidelity: a real Debian installer, over PXE, onto a real disk, from a mirror served by a
RAM-resident node over NFS or iSCSI.

Three things it needs that Part 1 does not:

**3a. A fuller mirror.** `airgap.sh` mirrors the 79-package `minbase` closure, which is
what `debootstrap` needs and *not* what d-i needs: `pkgsel`, `tasksel standard`, a kernel
and `grub` are a much larger set. Build the real thing with `debmirror` or `apt-mirror`
into the same layout (`dists/` + `pool/` at the tree root, which is what
`package-mirror-ram`'s nginx `root /srv/mirror;` serves):

```bash
debmirror --nosource --method=http --host=deb.debian.org --root=/debian \
          --dist=trixie --section=main --arch=amd64 \
          --keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
          /srv/mirror
```

Then re-sign it with your lab key the way `airgap.sh mirror` does — a mirror the installer
will trust has to be signed by something the installer was told to trust.

**3b. The installer has to be given the key.** There is no
`debian-installer/allow_unauthenticated` in [`preseed-local-mirror.cfg`](preseed-local-mirror.cfg)
on purpose: switching verification off would make the install succeed against a mirror
anyone could rewrite, which is the opposite of what an air gap is for. Two ways in:

- a `d-i preseed/early_command` that fetches the public key and `apt-key add`s it into the
  installer's keyring before `choose-mirror` runs; or
- rebuild the netboot `initrd` with the key baked into
  `/usr/share/keyrings/debian-archive-keyring.gpg` — the honest one, because it means the
  trust arrives with the installer rather than over the network it is meant not to trust.

**3c. A network with no default route.** The whole claim. A libvirt isolated network (no
`<forward/>`) or a QEMU socket netdev — [`phase2-qemu-vm`'s `peer_link`](../../phase2-qemu-vm/README.md)
is a private two-VM wire that needs no root. Boot the installer chain from
[`debian-pxe-lab/`](../debian-pxe-lab/README.md) on that network, substitute the mirror
host for `@MIRROR_HOST@`, and serve the preseed alongside.

**Success signature**, and it is deliberately not "the installer finished":

```bash
# on the installed machine, first boot:
cat /etc/apt/sources.list          # -> the lab mirror, and NOTHING else
apt-get update                     # -> succeeds, from the lab mirror
apt-get install -y file            # -> installs, with no route to deb.debian.org
ip route                           # -> no default route
```

The last two lines together are the result. `apt-get update` succeeding on a machine that
has a route to the internet proves nothing about the mirror; on a machine with no default
route it proves the whole chain — the preseed, the mirror layout, the signing key, and the
`apt-setup/services-select` change that keeps the installed system from being pointed back
at `security.debian.org`.

---

## Cleanup

`airgap.sh clean` removes everything Part 1 created. Part 2's chroot is removed with
`lab-chroot.sh destroy`. Part 3's mirror, VM and network are yours to tear down with the
tools that made them — and `iscsiadm --logout` / `tgtadm --op delete` if you used
`package-mirror-ram`'s block variant, since those touch host-global kernel state.

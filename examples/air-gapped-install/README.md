# Air-gapped install — a Debian base system from a local mirror, with nowhere else to go

[`examples/package-mirror-ram/`](../package-mirror-ram/README.md) serves a Debian mirror
tree. Until this lab, **nothing in the repo installed from it** — all four zero-touch
install labs (`debian-pxe-lab/`, `debian-preseed-gallery/`, `rocky-pxe-lab/`,
`almalinux-pxe-lab/`) point at public mirrors. A mirror with no consumer is a producer
nobody has checked. This lab is the consumer.

> ## The lesson
> **"The config names a local mirror" is not the same claim as "this install had no
> other source," and only the second one is worth anything.** A machine that can still
> reach `deb.debian.org` will fall back to it, or was never using the local mirror at
> all, and from the outside both look exactly like success. So the install here runs
> inside `unshare -rn` — a network namespace whose only interface is loopback — and the
> mirror is served from *inside* that namespace on 127.0.0.1. There is no route to
> anywhere. Then the air gap itself is measured, because a namespace nobody checked and
> a namespace that works print the same PASS.

---

## The two-second version

```bash
examples/air-gapped-install/airgap.sh mirror     # the ONLY step that touches the network
examples/air-gapped-install/airgap.sh install
examples/air-gapped-install/airgap.sh controls
```

```
  installed: 78 packages unpacked into …/state/rootfs, Debian 13.6

  row                                outcome
  ------------------------------------------------------------------
  C0 the air gap itself              upstream is unreachable, mirror is
  C1 upstream, from inside the ns    refused on the network as required (rc=1)
  C2 our mirror, Debian's keyring    refused the signature as required (rc=1)
  C3 a corrupted .deb in the tree    refused the bad hash as required (rc=1)
  C4 repaired tree (positive)        passed, as it must

  5 rows behaved: the air gap itself, three refusals each on its OWN reason, and one success
```

No root, no daemon, no VM, ~5 seconds after the mirror exists. The mirror is 79 packages
and 32 MB — the exact `minbase` closure `debootstrap` asks for, derived from upstream
rather than written down.

---

## What is proven, and what is not

| | claim | status |
|---|---|---|
| **1** | a **signed** partial mirror can be built and every byte in it traced to a verified upstream index | ✅ [`airgap.sh mirror`](airgap.sh) |
| **2** | a Debian base system installs from it with **no route to upstream** | ✅ [`tests/test-airgap-install.sh`](tests/test-airgap-install.sh) |
| **3** | the isolation is real, not assumed — take the namespace away and the same rows refuse to produce a verdict | ✅ [`tests/test-the-air-gap-is-real.sh`](tests/test-the-air-gap-is-real.sh) |
| **4** | a driver in this repo can be told to trust a **local** signing key | ✅ `lab-chroot.sh --keyring`, [`phase1-chroot/tests/test-keyring-override.sh`](../../phase1-chroot/tests/test-keyring-override.sh) |
| **5** | the same tree, mounted by [`package-mirror-ram`](../package-mirror-ram/README.md) over NFS/iSCSI, serves a **d-i** install onto a real disk | ⏳ **author-run** — [`MANUAL_TESTING.md` §3](MANUAL_TESTING.md) |

**The half that is missing, named.** `debootstrap --foreign` stops after downloading and
unpacking; the second stage (`dpkg --configure`) needs real root, which a rootless run does
not have. That stage does **no network I/O at all**, so the mirror-consuming half of the
install is precisely the half covered — but it is a half, and saying "an install" without
that sentence would be an overclaim. The rooted full install is two commands in
[`MANUAL_TESTING.md` §2](MANUAL_TESTING.md).

---

## Three things this cost, all of them in the instrument

Per this repo's standing observation that the defects turn up in the checker and its
control far more often than in the subject:

- **C1 refused for the wrong reason, in exactly the scenario it existed to catch.** The
  first draft proved isolation by pointing `debootstrap` at `deb.debian.org` and watching
  it fail. Run *outside* the namespace as a control it still printed *"failed as
  required"* — because a non-root `debootstrap` refuses before it ever opens a socket
  (`E: debootstrap can only run as root`). A **more** capable tool is not a stand-in for
  the seam; neither is a **less** capable one. `C0` now asks `curl`, whose network-class
  exit codes (6/7/28/35) *are* the answer, and the run stops rather than grading anything
  against an unknown.
- **`gpgv`'s exit status is the wrong question — the one place in this repo where parsing
  the output is correct.** A Debian `InRelease` carries several signatures; `gpgv` exits
  non-zero when it could not check *every* one. This host's `debian-archive-keyring` stops
  at bookworm, so trixie's `InRelease` yields one `GOODSIG` and two `NO_PUBKEY`, and
  `gpgv` exits 2 on a perfectly trustworthy file. `debootstrap` says so in its own source
  (`read_gpg_status`, `/usr/share/debootstrap/functions`): *"Don't worry about the exit
  status from gpgv; parsing the output will take care of that."* `--status-fd` is gpg's
  machine-readable interface, and the rule used here is debootstrap's, so the builder
  accepts exactly what the installer will.
- **A successful install reported `rc=1`, because a teardown supplied the exit status.**
  The server-reaping `trap` named a `local` variable, which is out of scope by the time an
  EXIT trap runs; under `set -u` the trap died on `srv: unbound variable`, left the server
  running *and* overwrote a clean exit. The install log showed a complete base system while
  the driver called it a failure.

And one in the test: `"$DRIVER" status | grep -q …` **skipped the most important test in
the lab** while the mirror sat on disk — `grep -q` exits at the first match, `SIGPIPE`s the
still-printing `status`, and `pipefail` reports 141. A skip is the quiet direction of that
bug.

---

## Where the boundaries are

- **The mirror build is the only step that touches the network**, and it is a cache, so
  it is bound to its subject: the stamp carries the suite, the arch, the upstream it was
  cut from and the **sha256 of the upstream `InRelease`**. `status` prints the provenance;
  `mirror --refresh` moves it.
- **Nothing is trusted because it arrived over the wire.** Upstream `InRelease` is checked
  against Debian's keyring, the `Packages` hash comes out of *that verified file*, and every
  `.deb` is checked against a hash out of `Packages`. The mirror is then re-signed with a
  throwaway lab key, and the installer is given that key by path.
- **`--no-check-gpg` is deliberately not offered** by `lab-chroot.sh`, and a test asserts
  that it is neither passed nor accepted. It would turn every result here into theatre, and
  it is always one flag away.
- **The port cannot collide.** `8099` is bound inside the namespace, so nothing on the host
  can reach it and it cannot conflict with anything the host is running. `serve` is the
  deliberate exception — it binds a real address, for the author-run d-i half.
- **The signing key is throwaway and gitignored.** A real air-gapped site's mirror key is
  the trust anchor for every machine it installs; it belongs offline or in an HSM, not in
  `state/`. Contrast [`lab-ca/`](../lab-ca/README.md), which is this repo's *shared* X.509
  anchor — a mirror is signed with OpenPGP, a different chain entirely, and conflating the
  two is the kind of thing this repo tries to say out loud rather than imply.

## What's in here

| File | What |
|---|---|
| [`airgap.sh`](airgap.sh) | build the signed mirror, install from it in a namespace, run the five rows |
| [`preseed-local-mirror.cfg`](preseed-local-mirror.cfg) | the **d-i** form — the gallery base with the four changes an air gap needs, so the diff is the lesson |
| [`tests/test-airgap-install.sh`](tests/test-airgap-install.sh) | the install, asserted on the tree; the rows, read by name |
| [`tests/test-the-air-gap-is-real.sh`](tests/test-the-air-gap-is-real.sh) | the negative control on the harness: no namespace → no verdict |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | the rooted full install, and the author-run d-i half against `package-mirror-ram` |

## Provenance

Follows Debian's official preseed and `debootstrap` documentation (**cite, don't mirror** —
this tracks upstream tooling, not one write-up): the `d-i mirror/*` and `apt-setup/*`
directives are from Debian's own example preseed, vendored byte-exact by a sibling lab at
[`../debian-preseed-gallery/upstream-preseed/`](../debian-preseed-gallery/upstream-preseed/)
(retrieved 2026-08-30). The signature-acceptance rule is read from the installed
`debootstrap`'s `read_gpg_status`, named in the source rather than copied.

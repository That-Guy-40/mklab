# `keys/` — vendored signing keys (the trust anchor for `mlbuild.sh`)

This directory holds the **public** PGP keys used to verify the kernel and
BusyBox source tarballs. They are the entire point of the plan's supply-chain
posture (§6.0 / §8):

> Verification trust comes from a key obtained **out-of-band** and committed
> here — **never** from a checksum or key fetched alongside the tarball. A
> checksum from the same server an attacker tampered with is worthless
> (Trust-On-First-Use). A signature only means something if you already trust
> the key independently.

`mlbuild.sh` does two things with these files, per download:

1. **`assert_keyring_fpr`** — confirms the keyring contains *exactly* the
   fingerprint pinned in `../versions.env` (so a swapped keyring is caught).
2. **`gpgv --keyring <this>`** — verifies the upstream detached signature
   (`linux-*.tar.sign`, `busybox-*.tar.bz2.sig`). The kernel signs the
   *uncompressed* tar, so mlbuild pipes `xz -dc … | gpgv`.

Only **public** keyrings live here — they are safe to commit. Never commit a
private key.

---

## Currently vendored

| File | Key(s) | Primary fingerprint | How it was verified |
|---|---|---|---|
| `kernel.gpg` | Greg Kroah-Hartman | `647F2865 4894E3BD 457199BE 38DBBDC8 6092693E` | kernel.org **WKD** + cross-checked against `kernel.org/category/signatures.html` |
| `kernel.gpg` | Sasha Levin | `E27E5D8A 3403A2EF 66873BBC DEA66FF7 97772CDC` | same two channels |
| `busybox.gpg` | Denys Vlasenko | `C9E9416F 76E610DB D09D040F 47B70C55 ACC9965B` | key-id read from the release `.sig`, fetched from a keyserver |

Pins live in [`../versions.env`](../versions.env) (`KERNEL_FPR`, `BUSYBOX_FPR`);
`mlbuild.sh` asserts every pinned primary fingerprint is present in the keyring
before trusting any signature.

> **⚠️ The BusyBox key is verified more weakly than the kernel keys.** kernel.org
> publishes its signing fingerprints on an authoritative page (a true second
> channel); BusyBox does not, so the key id was learned from the signature
> itself and the key fetched from a keyserver. That's effectively trust-on-first-
> use. Before relying on it beyond a throwaway lab, cross-check
> `C9E9416F…ACC9965B` against an independent source.

---

## Files this directory should contain

| File | Keyring for | Fingerprint pinned in `versions.env` |
|---|---|---|
| `kernel.gpg`  | kernel.org stable-release signer(s) | `KERNEL_FPR`  |
| `busybox.gpg` | BusyBox release signer              | `BUSYBOX_FPR` |

Both are **binary** keyrings (what `gpgv --keyring` wants), produced with
`gpg --export`.

---

## How to obtain & pin a key (do this out-of-band)

The integrity of this whole lab rests on getting the *right* fingerprint. Do
**not** just `gpg --recv-keys` and trust whatever arrives — cross-check the
fingerprint against **two or more independent channels** before pinning it.

### 1. kernel.org

Stable tarballs are signed by the stable maintainers (e.g. Greg Kroah-Hartman,
Sasha Levin). The authoritative fingerprints are published at:

- <https://www.kernel.org/category/signatures.html>
- the maintainers' keys via WKD: `gpg --locate-keys gregkh@kernel.org`

Cross-check the fingerprint shown there against a second source (a previously
trusted keyring, the printed fingerprint in kernel.org docs, a colleague's
copy). Then export and pin:

```bash
# after you have verified the fingerprint independently:
FPR=<the-40-hex-fingerprint-you-verified>
gpg --export "$FPR" > kernel.gpg
gpg --no-default-keyring --keyring ./kernel.gpg --list-keys --with-colons \
  | awk -F: '$1=="fpr"{print $10}'        # sanity: should print $FPR
# paste $FPR into ../versions.env as KERNEL_FPR
```

> Tip: whichever release line you pin (`LINUX_VER`), confirm *that* tarball's
> `.tar.sign` actually verifies against the key before trusting it for builds.

### 2. BusyBox

Releases are signed by the BusyBox release manager. Get the key from a trusted
channel (busybox.net release announcements, a distro's vendored copy), verify
the fingerprint independently, then:

```bash
FPR=<the-40-hex-fingerprint-you-verified>
gpg --export "$FPR" > busybox.gpg
# paste $FPR into ../versions.env as BUSYBOX_FPR
```

---

## Rotating / updating

The fingerprint pin in `versions.env` is the durable trust anchor. Changing it
is a **reviewed git change** — that is the feature: a silent key swap shows up
as a diff. Re-vet the new fingerprint out-of-band before merging.

## Why not just trust the upstream `SHA256SUMS`?

Because integrity ≠ authenticity. See plan §6.0: a fetched checksum proves only
that the bytes weren't corrupted in transit (TLS already does that). The signed
tarball + a key you vetted out-of-band is what survives a compromised
mirror/CDN. The same pattern is how Phase 2 should "trust the Kali repo": fetch
its *signed* `SHA256SUMS` + `SHA256SUMS.gpg`, verify against the already-vendored
`kali-archive-keyring`, then `sha256sum -c`.

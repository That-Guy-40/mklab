# Installing `kali-archive-keyring` on Debian / Ubuntu

`test-kali-bootstrap.sh` requires the Kali archive keyring to be present at
`/usr/share/keyrings/kali-archive-keyring.gpg`. The package is **not** in
Debian or Ubuntu repos, so you have to fetch it from Kali directly.

This document walks through downloading the `.deb` and (optionally)
verifying its SHA256 against Kali's published `Packages.gz` index before
installing. `apt-key` and other deprecated/insecure paths are intentionally
avoided.

> **Trust note:** the keyring `.deb` is itself **unsigned by definition** —
> it carries the keys you'd use to verify other Kali packages. So the only
> integrity check available pre-install is matching its SHA256 against the
> hash Kali publishes in its (HTTPS-served) `Packages.gz` index. That's
> Step 2 below; skipping it means trusting only the TLS chain to
> `http.kali.org`.

---

## Step 1 — discover the current version and download

```bash
# Discover the latest .deb filename in Kali's pool:
LATEST=$(curl -fsSL https://http.kali.org/kali/pool/main/k/kali-archive-keyring/ \
    | grep -oE 'kali-archive-keyring_[0-9.]+(_all)?\.deb' \
    | sort -uV | tail -1)
echo "Latest: $LATEST"
# example: kali-archive-keyring_2024.1_all.deb

# Download into the current directory:
curl -fLO "https://http.kali.org/kali/pool/main/k/kali-archive-keyring/${LATEST}"

# Quick sanity-inspect (should list /usr/share/keyrings/*.gpg + maintainer scripts only):
dpkg-deb -c "${LATEST}"
```

## Step 2 — verify the SHA256 against Kali's Packages.gz (recommended)

```bash
# Fetch the package index over HTTPS:
INDEX=$(curl -fsSL https://http.kali.org/kali/dists/kali-rolling/main/binary-all/Packages.gz | gunzip)

# Pull the stanza for kali-archive-keyring and extract the published hash:
EXPECTED=$(printf '%s\n' "$INDEX" \
    | awk '/^Package: kali-archive-keyring$/,/^$/' \
    | awk '/^SHA256:/ {print $2}')
echo "Expected SHA256: $EXPECTED"

# Hash the file you downloaded:
ACTUAL=$(sha256sum "${LATEST}" | awk '{print $1}')
echo "Actual SHA256:   $ACTUAL"

# Compare and exit on mismatch:
[[ "$EXPECTED" == "$ACTUAL" ]] || { echo "SHA256 mismatch — DO NOT INSTALL"; exit 1; }
echo "SHA256 OK"
```

If the hashes don't match, **stop**. Either the file in transit was
tampered with, or Kali rebuilt the package between your two `curl`
invocations and the index has moved on — re-download and re-check.

## Step 3 — install

```bash
sudo apt-get install -y "./${LATEST}"
```

`apt-get install ./file.deb` is preferable to raw `dpkg -i` — it lets apt
resolve any (in this case zero) deps and integrates the install into apt's
usual transaction handling.

## Step 4 — verify install

```bash
ls -l /usr/share/keyrings/kali-archive-keyring.gpg
gpg --no-default-keyring \
    --keyring /usr/share/keyrings/kali-archive-keyring.gpg \
    --list-keys
```

You should see the keyring file present and one or more long-lived Kali
signing keys (typical keyid: `ED444FF07D8D0BF6`, fingerprint ending
`...44C1 9DA5 ED44 4FF0 7D8D 0BF6`).

## Step 5 — re-run the bootstrap test

```bash
sudo phase1-chroot/tests/test-kali-bootstrap.sh
```

Expect a green `PASS: native debootstrap produced a working kali-rolling
chroot` after 1–3 min (network-bound). The chroot is destroyed by the
test's trap when it exits, so nothing lingers afterwards.

---

## Removing it again

```bash
sudo apt-get remove -y kali-archive-keyring
```

Leaves no Kali repo lines on the host (this package only installs the
`.gpg` file under `/usr/share/keyrings/`; it does not touch
`/etc/apt/sources.list.d/`).

## All-in-one script

If you want to copy-paste a single block:

```bash
set -euo pipefail
LATEST=$(curl -fsSL https://http.kali.org/kali/pool/main/k/kali-archive-keyring/ \
    | grep -oE 'kali-archive-keyring_[0-9.]+(_all)?\.deb' \
    | sort -uV | tail -1)
echo "Latest: $LATEST"

curl -fLO "https://http.kali.org/kali/pool/main/k/kali-archive-keyring/${LATEST}"

INDEX=$(curl -fsSL https://http.kali.org/kali/dists/kali-rolling/main/binary-all/Packages.gz | gunzip)
EXPECTED=$(printf '%s\n' "$INDEX" \
    | awk '/^Package: kali-archive-keyring$/,/^$/' \
    | awk '/^SHA256:/ {print $2}')
ACTUAL=$(sha256sum "${LATEST}" | awk '{print $1}')

if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    echo "SHA256 mismatch — DO NOT INSTALL"
    echo "  expected: $EXPECTED"
    echo "  actual:   $ACTUAL"
    exit 1
fi
echo "SHA256 OK ($ACTUAL)"

sudo apt-get install -y "./${LATEST}"
ls -l /usr/share/keyrings/kali-archive-keyring.gpg
```

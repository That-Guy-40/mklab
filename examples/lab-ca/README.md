# examples/lab-ca — the shared mklab lab root CA

A **reusable, highly-trusted root CA** for the lab, established as shared infrastructure
(sibling to the netboot servers) so every lab that needs **real TLS** or **signed
artifacts** anchors to *one* root instead of scattering self-signed/snakeoil certs. It
is consumed by the LinuxBoot lab's HTTPS + System Transparency tiers
([`../linuxboot-uefi-kexec/PLAN-PXEBOOT.md`](../linuxboot-uefi-kexec/PLAN-PXEBOOT.md)
P2/P3) and is available to any other netboot/PXE lab that wants non-`-k` HTTPS.

## The teachable PKI split (why the key isn't in git)

| Material | In git? | Where |
|---|---|---|
| **`lab-ca.crt`** + **`lab-ca.fingerprint`** — the PUBLIC trust anchor | ✅ **tracked** | here |
| scripts (`make-ca.sh`, `issue-*.sh`) + this README | ✅ tracked | here |
| root **private key** + issued **leaf keys**/serial | 🚫 **gitignored** | `private/` (keystore) |

The whole point of the HTTPS (P2) and System Transparency (P3) tiers is *verifiable*
boot. A committed CA key would let anyone forge a "trusted" server cert or signed OSPKG
the ROM accepts — defeating the demonstration. So this models real PKI hygiene: **public
anchor shared freely, private key guarded.** `make-ca.sh` writes a `.gitignore` that makes
staging the key impossible by accident. Lose the key? Re-run `make-ca.sh` (new root) and
re-bake the new `lab-ca.crt` in the consumers.

The root is **preserved locally** so the *same* anchor persists across labs and runs
(that's the reuse payoff) — regenerable, but stable.

Current root fingerprint (SHA-256):
`4F:A6:9C:1A:72:FD:3F:0B:AE:90:23:8E:55:86:97:5C:B6:44:3B:96:58:D5:EF:E7:B8:1A:42:CA:F0:07:0A:61`
(always check `lab-ca.fingerprint` — it changes if the root is regenerated.)

## Use it

```bash
./make-ca.sh                          # generate the root once (idempotent; --force to rotate)
./issue-server-cert.sh 10.0.2.2 netboot.lab   # a TLS server leaf (SANs) for serve-netboot.sh --tls
./issue-signing-cert.sh ospkg-signer          # an Ed25519 code-signing leaf for System Transparency (P3)
./issue-codesign-cert.sh netboot-payload      # an ECDSA P-256 codeSigning leaf for iPXE imgverify
```

The root is ECDSA P-256; leaves are ECDSA P-256 (TLS, iPXE code signing) or Ed25519
(System Transparency), signed directly by the root (a single-level CA — plenty for a
lab). Issued material lands in the gitignored `private/` keystore; server certs also get
a `*-fullchain.crt` (leaf+root) for nginx.

## Consume it

- **TLS (P2 + any netboot lab):** point the server at `private/certs/<cn>-fullchain.crt`
  + `<cn>.key`; give **clients** `lab-ca.crt` as the trust root. For u-root/Go clients,
  bake `lab-ca.crt` at `/etc/ssl/certs/ca-certificates.crt` (Go's `SystemCertPool` reads
  it). Verify with `curl --cacert lab-ca.crt https://…` — **no `-k`**.
- **Signing (P3, System Transparency):** the OSPKG signing key chains to this root;
  the ROM's trust policy / `tls_roots.pem` is `lab-ca.crt`.
- **Signed netboot payloads (iPXE `imgverify`, since 2026-08-30):**
  `netboot/sign-payload.sh --lab-ca netboot-payload --out-trust <ca.der> <file>…`
  signs with the leaf above and emits **this root** as the DER trust root baked into the
  firmware. Verified by booting it, not by `openssl verify` —
  [`netboot/MANUAL_TESTING.md` §13.3](../../netboot/MANUAL_TESTING.md).

### Two leaf profiles, one root — and they are NOT interchangeable

This is the part to read before "simplifying" the two signing scripts into one. The
two consumers demand **contradictory** certificates:

| | System Transparency (`issue-signing-cert.sh`) | iPXE `imgverify` (`issue-codesign-cert.sh`) |
|---|---|---|
| key | Ed25519 (what ST/`stmgr` uses) | ECDSA P-256 |
| EKU | **none at all** | **`codeSigning`**, critical |
| why | stboot's `descriptor.Verify()` leaves `KeyUsages` unset, so Go defaults to requiring `serverAuth`; a `codeSigning` leaf is rejected as *"incompatible key usage"* | iPXE requires `codeSigning` **and** `keyUsage=digitalSignature`, and refuses a leaf without them |

Give either consumer the other's leaf and it fails **at boot**, where the message is
least useful. `netboot/tests/test-sign-payload-lab-ca.sh` asserts the refusal here
instead, in both directions.

**iPXE could not use this root at all before v2.0.0.** The root is ECDSA, and
`crypto/ecdsa.c`/`p256.c`/`p384.c` first ship in v2.0.0 — upstream's first release
since 2020, which `netboot/versions.env` pins by commit.

## Its own tests

[`tests/run-all.sh`](tests/) — driving
[`tests/test-anchor-and-profiles.sh`](tests/test-anchor-and-profiles.sh): the tracked
anchor matches its tracked fingerprint, the keystore is unstageable, and the two leaf
profiles are what their consumers require (Ed25519 with **no** EKU for stboot's Go x509,
ECDSA with `codeSigning` + `digitalSignature` for iPXE's `imgverify` — incompatible on
purpose, and the shape somebody will one day "simplify" into a single issuer).

## Key hygiene assertion

`make-ca.sh` refuses to leak the key: the generated `.gitignore` excludes `private/`,
`*.key`, `*key.pem`, `*.srl`. Confirm nothing private is staged with
`git check-ignore private/lab-ca.key` (should echo the path = ignored).

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
```

Everything is ECDSA P-256 (TLS) / Ed25519 (signing), signed directly by the root
(a single-level CA — plenty for a lab). Issued material lands in the gitignored
`private/` keystore; server certs also get a `*-fullchain.crt` (leaf+root) for nginx.

## Consume it

- **TLS (P2 + any netboot lab):** point the server at `private/certs/<cn>-fullchain.crt`
  + `<cn>.key`; give **clients** `lab-ca.crt` as the trust root. For u-root/Go clients,
  bake `lab-ca.crt` at `/etc/ssl/certs/ca-certificates.crt` (Go's `SystemCertPool` reads
  it). Verify with `curl --cacert lab-ca.crt https://…` — **no `-k`**.
- **Signing (P3, System Transparency):** the OSPKG signing key chains to this root;
  the ROM's trust policy / `tls_roots.pem` is `lab-ca.crt`.

## Key hygiene assertion

`make-ca.sh` refuses to leak the key: the generated `.gitignore` excludes `private/`,
`*.key`, `*key.pem`, `*.srl`. Confirm nothing private is staged with
`git check-ignore private/lab-ca.key` (should echo the path = ignored).

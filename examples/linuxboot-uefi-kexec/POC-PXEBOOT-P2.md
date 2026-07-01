# POC-PXEBOOT-P2 — HTTPS provisioning from the ROM, verified against a lab CA

> **Status: PROVEN, positive + negative, on the real ROM** (Ubuntu 24.04 + QEMU 8.2.2 /
> KVM). The ROM fetches an OS installer's kernel+initrd over **HTTPS**, with the server
> cert **verified against a CA baked into the initramfs**, then `kexec`s it — and a
> **rogue (untrusted) cert is refused**. All with **stock u-root** (no patched payload).
> P2 of [`PLAN-PXEBOOT.md`](PLAN-PXEBOOT.md); the plaintext-HTTP tier is
> [`POC-PXEBOOT.md`](POC-PXEBOOT.md) (P1).

## The finding: `pxeboot` can't do HTTPS — but `wget` can

The obvious P2 was "point `pxeboot -file` at an `https://` URL." It can't: u-root's
`pxeboot` fetches via `curl.DefaultSchemes`, which registers only **`tftp`, `http`,
`file`** — there is **no `https` scheme**, and `pxeboot` has no `-tls`/`-cacert` flag.
Upstream even comments that HTTPS needs a caller-built client with a private cert pool.

But u-root's **`wget`** *does* register `https` → `curl.DefaultHTTPClient` →
`http.DefaultClient` → Go's **`x509.SystemCertPool`**. On Linux that reads
`/etc/ssl/certs/ca-certificates.crt`. So the recipe (chosen over patching `pxeboot`):

| Piece | How |
|---|---|
| **Trust anchor in the ROM** | bake `lab-ca.crt` → `/etc/ssl/certs/ca-certificates.crt` in the initramfs (`CONFIG_LINUXBOOT_UROOT_FILES`), from the shared [`examples/lab-ca`](../lab-ca/README.md) |
| **`kexec` command** | add `cmds/core/kexec` to `CONFIG_LINUXBOOT_UROOT_COMMANDS` (pxeboot kexecs internally, but there's no standalone `kexec` for the shell) |
| **Fetch over TLS** | `wget https://10.0.2.2:8443/…` — trusts the baked CA via SystemCertPool |
| **Boot it** | `kexec -l /tmp/k -i /tmp/i -c "<cmdline>" ; kexec -e` |
| **Server** | `serve-netboot.sh --tls` — nginx on :8443 with a lab-CA server cert for `10.0.2.2` |

Both additions are **additive** to the P1 ROM: `pxeboot -file http://…` (P1) still works;
one ROM carries both tiers.

## Positive — verified on the real ROM (AlmaLinux 9.8)

`./serve-netboot.sh up --tls` then `./run-coreboot-pxe-https.sh alma` drives, at the
u-root shell:

```
wget -O /tmp/k https://10.0.2.2:8443/vmlinuz
wget -O /tmp/i https://10.0.2.2:8443/initrd.img
kexec -l /tmp/k -i /tmp/i -c "inst.stage2=http://…:8181/ inst.ks=http://…:8181/… ip=dhcp console=ttyS0"
kexec -e
```

```
Got DHCP answer from 10.0.2.2, my address is 10.0.2.15
Welcome to u-root!
[    0.000000] Linux version 5.14.0-687.5.3.el9_8.x86_64 …        ← wget'd over HTTPS, then KEXEC
Welcome to AlmaLinux 9.8 (Olive Jaguar)!
anaconda … for AlmaLinux 9.8 started.
Starting automated install.
```

No TLS error anywhere: `wget` verified the server cert against the baked lab CA, wrote
the kernel/initrd, and `kexec` booted them into the unattended install.

## Negative — a rogue cert is refused (verification is real, not skip-verify)

Re-serve `10.0.2.2:8443` with a **self-signed cert NOT issued by the lab CA**, boot the
same ROM, and `wget` the kernel:

```
wget: … failed to download https://10.0.2.2:8443/vmlinuz: … tls: failed to verify
      certificate: x509: certificate signed by unknown authority
WGET_EXIT=1
lstat /tmp/vmlinuz: no such file or directory
```

`wget` refused, exited non-zero, wrote no kernel — so there is nothing to `kexec` and no
OS boots. The ROM trusts **only** certificates chaining to the baked lab CA.

## Scope — what P2 secures (and what it doesn't, yet)

P2 secures the **ROM's trust boundary**: the LinuxBoot payload (u-root) fetches the
kernel+initrd it is about to `kexec` over a **verified** channel. That is the decision
LinuxBoot exists to make. The installer's *own* later downloads — Anaconda's
`inst.stage2`/`inst.ks`, d-i's `preseed/url` — stay on plain **http :8181** here;
teaching Anaconda/d-i to trust the lab CA is a separate, distro-specific exercise
(RHEL `inst.ks` CA injection / d-i late-command), noted as future. The `kexec`'d kernel
is fetched over HTTPS; the userspace install that follows is out of the ROM's hands.

## Files

| File | Role |
|---|---|
| [`../lab-ca/`](../lab-ca/README.md) | the shared lab root CA (`make-ca.sh`, `issue-server-cert.sh`) |
| [`serve-netboot.sh`](serve-netboot.sh) | `--tls` → nginx HTTPS :8443 with a lab-CA server cert |
| [`coreboot-qemu-q35-pxeboot.config`](coreboot-qemu-q35-pxeboot.config) | now also: `kexec` command + `CONFIG_LINUXBOOT_UROOT_FILES` (bake lab-ca.crt) |
| [`build-coreboot.sh`](build-coreboot.sh) | §3c stages `lab-ca.crt` into the tree; §3d invalidates the stale initramfs cache so `-files`/command changes take effect |
| [`run-coreboot-pxe-https.sh`](run-coreboot-pxe-https.sh) | boot the ROM + drive `wget https://… ; kexec` (reuses `boot-<os>.ipxe`) |

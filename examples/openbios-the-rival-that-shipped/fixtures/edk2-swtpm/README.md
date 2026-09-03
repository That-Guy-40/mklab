# `fixtures/edk2-swtpm/` — a REAL measured-boot event log, and the machine's own claim

A TCG PC Client event log **written by edk2 (OVMF)** as it booted a guest with a
**TPM 2.0 (swtpm)**, plus the PCR values **the TPM itself held** afterwards, read out
by the guest kernel. Captured once by [`capture.sh`](capture.sh) and vendored
byte-exact so the openbios lab's `event-real` track has a subject **nobody in this
repo authored** — the plan's "a claim from a machine that really measured".

| file | what | bytes |
|---|---|---|
| [`binary_bios_measurements`](binary_bios_measurements) | `/sys/kernel/security/tpm0/binary_bios_measurements` from the guest — 30 events (1 SpecID header + 29 crypto-agile `TCG_PCR_EVENT2`), **four digest banks per event** (sha1 · sha256 · sha384 · sha512, as swtpm 0.7.3 enables) | 6345 |
| [`pcrs-sha256.txt`](pcrs-sha256.txt) | `n:hex` for PCR 0–23 from `/sys/class/tpm/tpm0/pcr-sha256/` — **the machine's claim** | 1622 |
| [`pcrs-sha1.txt`](pcrs-sha1.txt) | the same for the sha1 bank | 1046 |
| [`PROVENANCE.txt`](PROVENANCE.txt) | firmware / swtpm / QEMU / kernel versions and sha256 of the files above — the record the track binds to | — |
| [`serial-capture.log`](serial-capture.log) | the raw guest console the files were decoded from | 12146 |
| [`capture.sh`](capture.sh) · [`capture-init.sh`](capture-init.sh) | the recipe: swtpm sidecar + OVMF (pflash) + a TPM-capable kernel + a busybox `/init` that prints the log (base64) and PCRs over serial, decoded on the host | — |

**What is in the log** (from `tpm2_eventlog`): `EV_S_CRTM_VERSION`, `EV_EFI_PLATFORM_FIRMWARE_BLOB`,
`EV_EFI_VARIABLE_DRIVER_CONFIG` ×5, `EV_PLATFORM_CONFIG_FLAGS` ×4, `EV_EFI_VARIABLE_BOOT` ×2,
`EV_EFI_ACTION` ×3, `EV_EVENT_TAG` ×2, `EV_SEPARATOR` ×8 — the standard edk2 measured-boot
sequence into PCR 0–7. **Internally consistent, measured at capture:** `tpm2_eventlog`'s replay of
the log equals the guest's own `pcrs-sha256.txt` for PCR 0–7, **8/8**.

## What is real here, and what is not

- **REAL:** the log — edk2 wrote it as it measured itself, its configuration and what it
  loaded; nothing in this repo authored a byte of it. **REAL:** the PCRs — read from the TPM
  device through the kernel; the firmware extended them without asking.
- **NOT a hardware root of trust:** the TPM is `swtpm`, so this is a *software* TPM's claim.
  It is a genuine, foreign, non-authored subject for a **replay** — which is what the track
  proves — and it says nothing about a physical machine. The hardware-signed **quote stays
  UNKNOWN** (plan §2), stated on every run.

## Re-capturing

```console
$ ./capture.sh            # rewrites the files here, and PROVENANCE.txt
```
Needs `swtpm`, `ovmf` (the 4M images), `qemu-system-x86_64`, `busybox-static`, and a
readable TPM-capable kernel (default `~/.cache/mklab-kernel/vmlinuz`, an Ubuntu generic
kernel with `CONFIG_TCG_TIS/CRB` and `SECURITYFS` built in — the linuxboot kernels on this
host have no TPM drivers). Rootless, no network, ~90 s. A fresh capture will differ in **PCR4**
(the EFI stub measures the initramfs, whose packed timestamps differ per build) — the track
binds to `PROVENANCE.txt`, so re-capture and commit together.

Two things the capture taught, both now guarded in the scripts: `binary_bios_measurements`
is a securityfs seq-file that **stats as 0 bytes** even with 6 KiB in it (`[ -s ]` is false
on a good log — read the bytes); and the kernel prints PCR hex in **upper case**, so a
`[0-9a-f]` pattern silently keeps only the all-zero PCRs and drops the ones that matter.

`CAPTURE_INIT=… CAPTURE_DONE_MARKER=…` swap in a diagnostic `/init`; `CAPTURE_TPMDEV=tpm-crb`
and `CAPTURE_APPEND=…` change the device and kernel command line.

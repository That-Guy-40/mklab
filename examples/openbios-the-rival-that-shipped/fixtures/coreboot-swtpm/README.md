# `fixtures/coreboot-swtpm/` — measured coreboot, two payloads, one reader (plan §12(2))

The two coreboot legs of the **comparison bench**: the same measured coreboot ROM bytes
(q35, TPM 2.0 over TIS, measured boot, TCG 2.0-format log) carrying **two different
payloads**, each booted with a swtpm TPM and read by the **same Linux reader** as the
UEFI leg in [`../edk2-swtpm/`](../edk2-swtpm/README.md). Nothing but the firmware
substrate differs between the three legs, and the toolkit is pointed at all of them
by the `event-bench` track.

| leg | ROM payload | how the Linux reader gets there | dir |
|---|---|---|---|
| coreboot → Linux | the TPM-capable capture kernel + initramfs (`CONFIG_PAYLOAD_LINUX`) | it *is* the payload | [`leg-linux/`](leg-linux/) |
| coreboot → OpenBIOS → Linux | OpenBIOS amd64 (`obj-amd64/openbios-builtin.elf32`) | OpenBIOS `boot`s the same kernel + initramfs off a `piix3-ide` CD at `/ide@0/cdrom@0` | [`leg-openbios/`](leg-openbios/) |
| UEFI (edk2) → Linux | — | OVMF direct-boots it | [`../edk2-swtpm/`](../edk2-swtpm/README.md) |

Each leg dir holds `binary_bios_measurements` (the TCG 2.0 log — 680 bytes: a SpecID
header + six `EV_ACTION` entries on **PCR 2**, one sha256 bank, each entry's event data the
name of what was measured), `pcrs-sha256.txt` / `pcrs-sha1.txt` (the guest kernel's read
of the TPM — **the machine's claim**), `serial-capture.txt` (the raw console, including
coreboot's own log of every measurement) and `PROVENANCE.txt` (firmware, coreboot commit,
payload line, swtpm/QEMU/kernel versions, log source, and sha256 of every file — the
track refuses a mismatch by name).

**What the bench measured (2026-09-03):** the two coreboot logs are **identical in entries
1–5** — `FMAP: FMAP`, `CBFS: bootblock`, `CBFS: fallback/romstage`, `CBFS: fallback/postcar`,
`CBFS: fallback/ramstage` — and **differ in exactly one entry, `CBFS: fallback/payload`**
(`391fd6c6…` for the Linux payload, `75f5ef77…` for OpenBIOS), and so in PCR 2
(`18eb963e…` vs `c8f4a188…`). The replay of each leg's log reproduces that leg's own PCR 2.
And the Linux leg's log with that *one* digest swapped for OpenBIOS's replays to exactly
the OpenBIOS leg's PCR 2 — the payload is the whole difference, and `dsl/eventlog.fth` +
`dsl/sha256.fth` show it from inside the firmware.

## Rebuilding and re-capturing

```console
$ make -C ~/linuxboot-lab/coreboot/util/cbmem LDFLAGS=-static     # a STATIC cbmem; build-rom.sh strips a copy
$ ./build-rom.sh linux && ./build-rom.sh openbios       # ~4 min each; isolated .config-bench-<leg> + build-bench-<leg>/
$ ( cd ../edk2-swtpm && CAPTURE_FIRMWARE=coreboot:$HOME/linuxboot-lab/coreboot/build-bench-linux/coreboot.rom \
      ./capture.sh --out ../coreboot-swtpm/leg-linux )
$ ( cd ../edk2-swtpm && CAPTURE_FIRMWARE=coreboot-openbios:$HOME/linuxboot-lab/coreboot/build-bench-openbios/coreboot.rom \
      ./capture.sh --out ../coreboot-swtpm/leg-openbios )
```
Re-capture both legs together and commit them together with their `PROVENANCE.txt`.

## What it took — every line below was measured, not assumed

- **The prerequisite is not VBOOT.** Plan §12(2)/review F4 named "a coreboot build with
  `CONFIG_VBOOT` + a TPM". An event log needs *measured* boot: `TPM2 + TPM_MEASURED_BOOT +
  TPM_LOG_TPM2` (which selects only the vboot *library*), on **q35** — it `select`s
  `MEMORY_MAPPED_TPM` (TIS at 0xfed40000); the lab's i440fx ROMs cannot (`MEMORY_MAPPED_TPM`
  is select-only). coreboot extends **only its SRTM PCR (2)**; PCR 0/1/3–7 stay zero by
  design — edk2 extends 0–7.
- **coreboot's TPM 2.0-format log is not what its ACPI table publishes.** `src/acpi/acpi.c`
  points the TPM2 table's log area at `CBMEM_ID_TCPA_TCG_LOG` (the TPM 1.2-format id) and
  *creates an empty one* when absent, while `TPM_LOG_TPM2` writes to `CBMEM_ID_TPM2_TCG_LOG`
  — so the guest's `binary_bios_measurements` reads 0 bytes although coreboot logged every
  measurement to its console. The capture initramfs therefore carries coreboot's own static
  `cbmem` and reads that entry directly (`cbmem -r 54504d32`, which needs `iomem=relaxed`
  against Ubuntu's `STRICT_DEVMEM`); the host trims the raw allocation by walking events.
- **Size.** The 15 MiB kernel plus a gzip initramfs carrying `cbmem` was 36 KB over a 16 MiB
  ROM's slot; cbfstool's LZMA cannot shrink an already-compressed bzImage (`LzmaEnc_Encode
  failed 9`); a 32 MiB ROM makes cbfstool SIGABRT in this tree (QEMU would take a 32 MiB
  `-bios` as-is, and refuses `max-fw-size=32M`). The initramfs is re-packed as **xz**.
- **q35 has no IDE**, so the OpenBIOS leg plugs in `-device piix3-ide`; OpenBIOS sees the CD
  at `/ide@0/cdrom@0` (a failed `load` says `ok` with `load-size` 0 — check the size, not
  the prompt). The boot line is *typed* at OpenBIOS's prompt, whose line editor truncates
  past ~80 columns — one-letter CD names (`\V`, `\I`) and `console=ttyS0` keep it at 75.
- **A benign duplicate:** coreboot on QEMU q35 declares the TIS TPM twice in ACPI;
  `MSFT0101:00` binds and `MSFT0101:01` fails EBUSY on the same region, in both legs.
- **No host-side PCR read:** one swtpm cannot serve QEMU's data fd and a TCP TCTI at once
  (`Failed to send CMD_SET_DATAFD`), so every leg's claim comes from the guest kernel — which
  is why even the OpenBIOS leg ends in Linux.

**Boundary:** every TPM here is `swtpm`. The bench proves the replays reproduce three
firmwares' measurements and explains their difference; it does not establish a hardware root
of trust — the AK **quote is UNKNOWN**, stated on every run.

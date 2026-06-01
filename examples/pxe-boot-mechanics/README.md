# PXE boot mechanics — Secure Boot & TFTP delivery

Two small QEMU labs that exercise *how* a VM boots over PXE, rather than *what*
it installs. Both reuse the shared iPXE builder
([`../../netboot/build-ipxe.sh`](../../netboot/build-ipxe.sh)) and boot via
[`../../phase2-qemu-vm/lab-vm.sh`](../../phase2-qemu-vm/lab-vm.sh)'s `pxe-install`
backend — they're the boot-transport / firmware counterpart to the
*distro-install* PXE labs ([`../almalinux-pxe-lab/`](../almalinux-pxe-lab/),
[`../rocky-pxe-lab/`](../rocky-pxe-lab/), [`../kali-pxe-lab/`](../kali-pxe-lab/)).

| File | What it demonstrates |
|---|---|
| [`vm-pxe-tftp-boot.toml`](vm-pxe-tftp-boot.toml) | Traditional **DHCP + TFTP** network boot: QEMU's slirp hands out DHCP options 66/67, the VM pulls `ipxe.efi` over TFTP, then iPXE fetches kernel+initrd over HTTP. No install media, no USB stick. |
| [`vm-pxe-secureboot.toml`](vm-pxe-secureboot.toml) | PXE boot with **UEFI Secure Boot enforced** — OVMF `*.secboot.fd` firmware + a pre-enrolled snakeoil test key. The iPXE binary must be **signed** with that key first or the firmware refuses it. |

## Run

Serve the artifacts first (e.g. [`../podman-netboot-server.toml`](../podman-netboot-server.toml))
so HTTP/TFTP have something to hand out, then:

```bash
# TFTP delivery:
netboot/build-ipxe.sh --server http://10.0.2.2:8181 ...          # builds boot.ipxe + ipxe.efi
phase2-qemu-vm/lab-vm.sh create --config examples/pxe-boot-mechanics/vm-pxe-tftp-boot.toml

# Secure Boot (sign iPXE with the snakeoil key):
netboot/build-ipxe.sh --server http://10.0.2.2:8181 --sign --use-snakeoil
phase2-qemu-vm/lab-vm.sh create --config examples/pxe-boot-mechanics/vm-pxe-secureboot.toml
```

See the [examples index](../00-INDEX.md) for the full netboot/PXE picture.

## Probe the transports by hand

The labs above boot a VM the real way. To instead *watch* the individual
TFTP/HTTP fetches a PXE boot does — and record/replay them — use the probes in
[`tools/`](tools/):

```bash
tools/pxe-fetch.sh probe                          # what's actually served?
tools/pxe-fetch.sh from-ipxe ~/netboot/boot.ipxe  # replay iPXE's exact GETs
```

`tools/pxe-fetch.sh` is a quick `curl`-based probe; `tools/socwrap.sh` (vendored)
is a guided, asciicast-recordable walkthrough driven by
[`tools/macros/pxe-fetch.json`](tools/macros/pxe-fetch.json). Run these from the
**host** (the client vantage point), not the artifact server — see
[`tools/README.md`](tools/README.md) for why `localhost` ≠ `10.0.2.2` here.

For a step-by-step **TFTP & HTTPS testing** walkthrough — standing up the
server, running the probes, expected output, and a troubleshooting matrix
keyed on `curl` exit codes — see
[`TFTP-HTTPS-TESTING.md`](TFTP-HTTPS-TESTING.md).

## ⚠️ Security

The Secure Boot demo uses a **snakeoil** (well-known, public) test key purely so
the chain validates under QEMU — it provides **no** real trust. Never enroll it
on real hardware or sign anything you care about with it. Keep these on an
isolated lab network.

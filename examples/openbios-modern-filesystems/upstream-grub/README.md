# Vendored GRUB 2.12 filesystem drivers — provenance & license

This directory holds the four GRUB 2.12 `grub-core/fs/` source files that the
`grub2fs` read shim (Seam 1, §2.1 of the [design notes](../../../DESIGN-NOTES-modern-filesystems-for-a-frozen-firmware.md))
transliterates and builds against — the **specification** for the shim, vendored
byte-exact so the lab is reproducible offline and its provenance is explicit.

## Provenance

| | |
|---|---|
| Project | GNU GRUB (GRand Unified Bootloader) |
| Version | **2.12** (released 2023-12-20) |
| Author / copyright | Free Software Foundation, Inc. (and GRUB contributors) |
| Canonical source | <https://ftp.gnu.org/gnu/grub/grub-2.12.tar.xz> |
| Retrieved | 2026-09-19 |
| Tarball `sha256` | `f3c97391f7c4eaa677a78e090c7e97e6dc47b16f655f04683ebd37bef7fe0faa` |
| Signature | GPG **Good signature**, GRUB release manager Daniel Kiper, key fingerprint `BE5C 2320 9ACD DACE B20D  B0A2 8C81 89F1 988C 2166` (from `keyserver.ubuntu.com`) |
| Content-confirmed | `configure.ac` → `AC_INIT([GRUB],[2.12],…)` |

The tarball itself is **not** committed (it is 6.4 MB and its headers/build system
are cited, not mirrored — see below); the `sha256` above reproduces it from the
canonical URL.

## The vendored files (byte-exact from `grub-2.12/grub-core/fs/`)

| file | lines | `sha256` |
|---|---|---|
| `ext2.c` | 1133 | `1a23a4c05f4094462b58a9b56cbfadf28d0651466ad1a2afaef37eb356233260` |
| `fat.c` | 1326 | `5da2eea5b9f39ee4909d6208e9495985c1d15470e7f77f63bbec4b85f3bc0817` |
| `iso9660.c` | 1257 | `da5dd9209af0985b6b3fbaa87a1bf5650d4a234871341cb0ae64c21594f1448c` |
| `fshelp.c` | 441 | `284235163fb3f633626ebd8cc4b2b2ba178d7027b7f1a00f6f9bdf32ea4b04a6` |

These are exactly the four files §1(2) of the design notes names: the three
filesystem readers the shim's first tier targets (ext2/3/4, FAT, ISO 9660) plus
the `fshelp` directory-walk helper they share.

## What is **not** vendored (cited, per the repo's provenance rule for upstream code)

GRUB's headers (`include/grub/*.h`), byte-order shims (`byteorder.h`), and build
system are **not** copied here — they are cited via the pinned tarball `sha256`
above and reconstructed at build time from it. Only the driver source proper — the
code the shim ports — is vendored, so the license footprint below is as small as
the specification requires.

## License — GPLv3-or-later, and why this stays **lab-only**

Every file here carries GRUB's header: *"GNU General Public License … either
version 3 of the License, or (at your option) any later version."* — i.e.
**GPL-3.0-or-later**. All rights remain with the Free Software Foundation and GRUB
contributors; these files are archived here for offline reference and as the
port's specification. `git rm -r examples/openbios-modern-filesystems/upstream-grub/`
removes them.

This license is **the whole reason the `grub2fs` shim is lab-only** and cannot be
shipped upstream into OpenBIOS. As §2.1c of the design notes measured (2026-09-16),
OpenBIOS's package interface is **GPLv2-only** in the directories the shim would
sit beside (0 of 14 `packages/`, 0 of 22 `libopenbios/`, 0 of 6 `kernel/` files
carry "any later version"). GPLv3+ code **cannot combine** with GPLv2-only, so the
shippable filesystem combination the plan selects is **U-Boot (GPL-2.0-or-later) +
FreeBSD `libsa` (BSD)**, with GRUB 2 kept **in the lab** as the widest-coverage
reader and the CBFS/cpio oracle. This vendored source is that lab copy: a
reference and a build input, never a shippable dependency. That boundary is the
point, not an oversight — see §2.1c and §2.6.

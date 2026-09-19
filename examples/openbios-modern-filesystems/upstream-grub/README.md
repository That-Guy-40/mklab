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

### Two on-disk-struct headers (POC-3, byte-exact from `grub-2.12/include/grub/`)

| file | lines | `sha256` |
|---|---|---|
| `fat.h` | 77 | `d674a60b6ee3f73d1e4a0212ddc34ed7ff6e68621d6ec9d3558d97e2f1e154a9` |
| `exfat.h` | 53 | `ebe7783fcf16f5de7f72e6db518227617a6b6d745813efefc7f7ad2c56aca1f6` |

`fat.c` includes `<grub/fat.h>` + `<grub/exfat.h>`, which define the FAT/exFAT BPB
and directory-entry **on-disk layouts**. These are vendored **verbatim** (not
hand-written into a shim) precisely because a byte-off struct layout would
mis-parse a real filesystem; they include only `<grub/types.h>` + `<grub/disk.h>`,
both of which the shim provides. `build-grub2fs.sh` stages them into `include/grub/`
beside the shim headers.

## What is **not** vendored (cited, per the repo's provenance rule for upstream code)

GRUB's *environment* headers — memory, error, disk, fs, dl, misc, byte order,
etc. — are **not** copied here: the shim in `../grub2fs/grub/` re-implements just
what the drivers call (the small `grub_*` surface), the way OpenBIOS's own
`fs/grubfs/` ships adapted headers rather than GRUB's originals. Two self-contained
inlines the drivers need (`grub_utf16_to_utf8`, `grub_datetime2unixtime`) are copied
into those shims with attribution. The full GRUB build system is cited via the
pinned tarball `sha256` above. Only the driver source + the on-disk-struct headers
are vendored, keeping the GPLv3 footprint as small as the specification requires.

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

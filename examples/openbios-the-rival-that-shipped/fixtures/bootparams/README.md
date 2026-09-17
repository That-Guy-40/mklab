# `fixtures/bootparams/` — an x86 setup image for the `bootparams` track

[`build-bootparams-fixture.sh`](build-bootparams-fixture.sh) takes the first
**64 KiB of a real bzImage** at run time (derived, never cached — the repo's
rule): its real-mode *"zero page"* (`struct boot_params` + `setup_header` at
offset `0x1f1`) and the version string, which is all
[`dsl/bootparams.fth`](../../dsl/bootparams.fth) reads. The full kernel is tens
of MiB and would not fit in the firmware's load window; the setup prefix is
~20 KiB and carries every field, and **`file`(1) decodes the prefix exactly as it
decodes the whole image** (it only touches the header and follows the version
pointer). So `file` stays a faithful oracle of the exact bytes the reader walks.

The subject is a **real, foreign-authored kernel**, so the builder *locates* one
rather than minting it (a kernel build is far too heavy for a fixture): `$BZIMAGE`
if set, then a short list of paths this host carries, then any readable
`/boot/vmlinuz-*`. If none is found it fails by name and the track **SKIPs**.

Two independent oracles grade the reader, neither sharing code with it:

| oracle | what it checks |
|---|---|
| **`file`** (libmagic) | the **version string** — it follows the `kernel_version` pointer (`0x20e`) by the same boot protocol the firmware does; two decoders, one pointer, one string |
| **`python3 struct.unpack('<…')`** | the numeric fields, read **explicitly little-endian** — `boot_flag` 0xAA55, `header` 0x53726448 (`"HdrS"`), the protocol version, `code32_start`, `kernel_alignment`, `init_size` |

**The `bootparams` track ([`smoke-openbios.sh bootparams`](../../smoke-openbios.sh))
walks the header on unix, x86, amd64 and ppc** and asserts every field equals the
oracle **on every arch**. That last row is the point: the x86 boot protocol is
**little-endian**, so — unlike cpio's ASCII-hex — there *is* a byte order to get
wrong. A native `l@` on **ppc** (big-endian) would read `"HdrS"` as `0x48647253`;
the reader uses `le-field:`, so ppc reads `0x53726448` like every other arch, and
the four-arch row proves it.

**Controls (unix):** a zeroed `boot_flag` → `bp| BAD-BOOTFLAG` and `false`; a
zeroed `"HdrS"` → `bp| BAD-HDRS` and `false`; a buffer cut before the header →
`bp| TRUNCATED` and `false`. A non-kernel is **refused by name**, never read as a
kernel.

Rebuild by hand:

```sh
./build-bootparams-fixture.sh /tmp/setup.bin      # or BZIMAGE=/path/to/bzImage ./build-…
file /tmp/setup.bin                               # the version-string oracle
python3 -c 'import struct;d=open("/tmp/setup.bin","rb").read();print("HdrS=%08x"%struct.unpack_from("<I",d,0x202))'
```

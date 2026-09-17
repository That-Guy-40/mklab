# `fixtures/cpio/` — a newc cpio archive for the `cpio` track

[`build-cpio-fixture.sh`](build-cpio-fixture.sh) authors a small `newc` cpio
archive **at run time** (derived, never cached — the repo's rule) with the
host's own GNU `cpio`, so the `cpio -itv` that lists it is a faithful oracle of
the exact bytes [`dsl/cpio.fth`](../../dsl/cpio.fth) walks. This is our own
authored fixture, not a vendored upstream artifact, so there is nothing to
mirror: the builder *is* the provenance.

Three members, fixed order, known sizes:

| member | bytes | why |
|---|---|---|
| `greet.txt` | 6 (`hello\n`) | a plain member |
| `data.bin` | 4 (`ABCD`) | `cpio-find`'s subject — the track checks the returned size **and** the four data bytes |
| `etc/conf` | 4 (`x=1\n`) | a nested path, so a name is not bare 8.3 |

The `cpio` track ([`smoke-openbios.sh cpio`](../../smoke-openbios.sh)) stages
this archive on an ISO beside `struct.fth` and `cpio.fth`, walks it on
**unix, x86, amd64 and ppc**, and asserts the member names and sizes the
firmware prints equal `cpio -itv`'s, in order — on every arch. The `newc`
header fields are ASCII **hex text**, so there is no byte order to get wrong:
ppc reads the same values as x86, not a byte-swap of them, and that is what the
four-arch row proves.

**Controls (unix):** a corrupted magic byte → `cpio| BAD-MAGIC` and `false`; a
buffer cut short of a member → `cpio| TRUNCATED` and `false`. A corrupt archive
is **refused by name**, never read wrong and reported as success.

Rebuild by hand:

```sh
./build-cpio-fixture.sh /tmp/initrd.cpi
cpio -itv < /tmp/initrd.cpi          # the oracle
```

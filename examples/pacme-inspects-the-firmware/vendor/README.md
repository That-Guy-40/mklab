# Vendored upstream header — `libpoke.h`

`gdb-iod.c` (the Spike-5 `pokegdb` tool) embeds **libpoke** and so needs its
public header, `libpoke.h`. The Debian/Ubuntu `poke` package installs the
runtime library (`libpoke.so.N`) but **not** a `-dev` header or a pkg-config
file, and this lab installs nothing that needs root. So the one header is
vendored here, byte-exact, and the tool links the shipped `libpoke.so.N`
directly (see [`../build-gdb-iod.sh`](../build-gdb-iod.sh)).

`libpoke.h` is self-contained — it includes only `<stdlib.h>`, `<stdint.h>`,
`<stdarg.h>`, and its `LIBPOKE_API` macro expands to nothing unless you are
*building* libpoke — so it compiles as-is against the installed runtime. The
IOD interface the tool fills (`struct pk_iod_if`, `pk_register_iod`,
`pk_iod_off`, the `PK_IOD_*`/`PK_IOS_F_*` constants) lives entirely in this one
header; `ios-dev.h` and the rest of the source tree are **not** needed.

## Provenance

| | |
|---|---|
| Project | GNU poke — the extensible editor for structured binary data |
| File | `libpoke/libpoke.h` |
| Version | poke **4.0** (matches the ABI of the installed `libpoke.so.1`) |
| Source tarball | `https://ftp.gnu.org/gnu/poke/poke-4.0.tar.gz` |
| Author | Jose E. Marchesi and the poke authors |
| Retrieved | 2026-10-02 |

`sha256` of the vendored copy:

```
2acd91b1ade1bd94c5ec895bbde2c7b14eb32801bc722cd98779bbbf6c646ae2  libpoke.h
```

To re-verify it is byte-identical to upstream:

```sh
curl -fsSL https://ftp.gnu.org/gnu/poke/poke-4.0.tar.gz | tar xzO poke-4.0/libpoke/libpoke.h \
  | sha256sum   # must print the sha256 above
```

## License

`libpoke.h` is part of GNU poke and is **GPLv3-or-later** (its copyright header
is intact in the file). This lab already runs poke only on the **host**, beside
QEMU, never linked into the GPLv2-only firmware — the standing GPLv3 wall
(see the lab [`README.md`](../README.md) and
[`DESIGN-NOTES`](../../../DESIGN-NOTES-pacme-a-live-firmware-inspector.md) §1). All
rights remain with the authors; this copy is archived for offline, reproducible
builds. `git rm` to remove.

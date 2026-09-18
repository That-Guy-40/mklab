# `fixtures/initrd-swap/` — a rescue initramfs for the `initrd-swap` track (Spike 9)

[`build-rescue-initrd.sh`](build-rescue-initrd.sh) authors a small **rescue
initramfs at run time** (derived, never cached — the repo's rule): a `newc` cpio
with **distinct** members (`rescue`, `init` — names the UKI's own `.initrd` does
not carry, so the swap is visibly a change), built with the host's own GNU `cpio`,
so `cpio -itv` is a faithful oracle of the members
[`cpio.fth`](../../dsl/cpio.fth) must walk after the swap. It is ≤ the UKI's
`.initrd` raw capacity (512 bytes) so it swaps **in place**; a larger one is the
`TOO-BIG` control.

It emits **two** files: the cpio, and a **generated Forth source** (`rescue-cpio
( -- adr len )`) that compiles those exact bytes into the dictionary. That second
file is why the swap works on every arch without a second load buffer: `$setenv
load-base` + a second `load` is a **unix-door-only** trick (and x86 relocates its
addresses), so the replacement bytes ride in the **dictionary** — ordinary Forth
memory everywhere. The Forth is generated from the *same* cpio (so it cannot
drift), and the builder **verifies the emitted byte count** equals the cpio's —
`od` without `-v` would collapse the cpio's NUL padding to `*` and silently drop
bytes, so the count is asserted, not assumed.

**The `initrd-swap` track ([`smoke-openbios.sh initrd-swap`](../../smoke-openbios.sh))
swaps a UKI's whole `.initrd` for this rescue archive**, in place at the `0 >`
prompt, on **unix, x86, amd64 and ppc**: `cpio.fth` walks `.initrd` **before** (the
UKI's own members) and **after** (the rescue's), proving the swap by the *reader*,
not the editor's claim. The editor is `initrd-set` — Spike 6's `pe-section-set`
pointed at `.initrd`, so it inherits the OOB / capacity / NUL-pad guards. On unix
the swapped image is written back and `objcopy` + `cpio -itv` read the rescue
members off the PE (foreign oracle).

**Control (unix):** a replacement larger than the section → `edit| TOO-BIG`, and
`.initrd` is **unchanged** after (still the rescue members) — a refused swap writes
nothing.

Rebuild by hand:

```sh
./build-rescue-initrd.sh /tmp/rescue.cpio /tmp/rescue.fth
cpio -itv < /tmp/rescue.cpio        # the members the swap must produce
head -5 /tmp/rescue.fth             # the dictionary-data Forth
```

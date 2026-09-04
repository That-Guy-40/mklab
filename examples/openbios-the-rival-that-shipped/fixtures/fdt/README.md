# `fixtures/fdt/` — a device tree **dtc authored**, for the firmware to ingest

| file | what |
|---|---|
| [`import.dts`](import.dts) | a small tree with every value shape a DTB carries: a string, a string list, u32 cells, raw bytes, an empty property, nested nodes, `#address-cells`/`#size-cells`. No `@unit` addresses on purpose (see below). |

The `fdt-import` track **compiles it at run time** — `dtc -I dts -O dtb` — and
never caches the blob: the fixture is the source, the oracle builds the subject.
It then delivers the blob over the CD, `dsl/fdt-read.fth` materializes it under
`/imported`, `dsl/fdt.fth` flattens that node again, and `dtc` decompiles the
round trip. **Both decompiles are made from binary**, so dtc's rendering
guesses cancel — from a `.dts` it prints `[de ad be ef]`, from a blob it prints
`<0xdeadbeef>`, for the same four bytes — and only the *tree* can differ.

**Why no unit addresses.** OpenBIOS derives a node's `@unit` from its `reg`
through the parent's `encode-unit`, so the reader stores the base name and lets
the tree regenerate the unit. Under `/imported` there is no bus binding to say
how a unit is spelled, so a `reg`-bearing node would round-trip its *name*
through a formatting rule the fixture does not control. The firmware's **own**
tree — full of `@unit`s — is the track's second subject, graded on counts
rather than a byte-level round trip.

This is not a vendored external source; it is authored here and the only
copyright is this repo's.

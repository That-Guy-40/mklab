# The module conformance contract — `contract v1`

This is the small, uniform vocabulary each format module in `dsl/` **opts into** so a
capstone can consume any of them the same way — **without the modules being fused**. It is
a *convention*, not a framework and not a merge: one file per format, each removable,
addable, and composable on its own (`FIRMWARE_FAMILY_ROADMAP.md` §2, the owner's locked
"federation, not a fusion" intent — prunable for real hardware, liftable into its own repo).

The shared substrate stays exactly what it was — `dsl/struct.fth` (the cursor/TLV and typed
field engine) plus `dsl/sha256.fth`. This contract adds **no new dependency**: the reason
seam lives in `struct.fth`, and the registry + manifest/field helpers live in
`dsl/contract.fth`. A module conforms by defining a handful of words; nothing about its
internals changes.

## Load order

```
dsl/struct.fth        \ the substrate (always)
dsl/sha256.fth        \ substrate, iff a module needs it (eventlog's replay)
dsl/contract.fth      \ this contract's registry + helpers
dsl/<format>.fth      \ any subset of the format modules, in any combination
```

A *slim profile* is any subset of the format modules over that substrate. It must build and
pass with each **absent** module **named** absent (`MODULE <name>: not loaded`), never
silently mis-reported as present — that is what makes prunability checkable rather than
claimed (§6, and `tests/test-contract-conformance.sh`).

## The required core

For a module whose prefix is `NAME` (e.g. `elf`, `cbfs`, `fdt`, `evlog`):

| word | stack | contract |
|---|---|---|
| `NAME-open` | `( addr len -- handle )` | Bind to a buffer. **Refuse a bad magic BY NAME** (print `REFUSED: <reason>` and return `0`); otherwise return an opaque handle. |
| `NAME-fields` | `( handle -- )` | Enumerate the format's fields — **name, offset, width** — one `fld\| name=… off=… w=…` line each, for the grader and any UI. Offsets/widths are read from the field's own `struct.fth` type-id metadata (`t-off`/`t-width`), never restated. |
| `NAME-validate` | `( handle -- c-addr u )` | The format's invariants. `u=0` ⟺ **valid**; otherwise `( c-addr u )` is a **named reason** — the plans' `reason\|0`, realized in a Forth that has no `c"` as a counted-length string with `u=0` for "valid". |
| `NAME-manifest` | `( -- )` | Self-description: what it reads, what it deliberately does **not**, and the two honesty axes below. Called by the registry's `.modules`. |

### The reason seam — one shape for "bad input"

Before this contract the four modules refused four different ways: `elf.fth` aborted through
`struct.fth`'s `chk` (printing `want=/got=`), `fdt-read.fth` printed `BAD-MAGIC` and returned
`false`, `eventlog.fth` set an `ev-err` flag, and **`cbfs.fth` stopped silently** — a corrupt
first entry printed `CBFS-END` and looked like an empty archive. `contract v1` collapses the
quartet to one shape at the seam they already share:

- `chk` / `chk<` / `chk?` (in `struct.fth`) keep aborting with `want=/got=` — the right shape
  for a width nobody implemented or an authoring-time impossibility, and the shape
  `smoke-openbios.sh elf-methods` asserts. **Unchanged.**
- A new mode flag `chk-catch` makes those same predicates, when a `validate` turns it on,
  **capture the reason and `throw`** instead of aborting. `validate ( xt -- c-addr u )` runs a
  `chk`-using check word under `catch` and hands back the first failing reason, or `0 0`. So a
  module writes its invariants **once** (they may still be its `chk`-based checker) and gets a
  returned, named reason for free. Nothing on the abort path changes, because the flag is off
  unless `validate` set it, and `validate` turns it off again however `catch` returns.
- `.refusal ( c-addr u -- )` prints a returned reason as `REFUSED: <text>` — the uniform form
  every module, `NAME-open`, and the conformance checker key on.

## The two honesty axes the manifest must carry (§5)

1. **Arch scope** — the family's sharpest edge is the four-arch (`unix`/`amd64`/`x86`/`ppc`)
   endianness×width matrix a hosted tool structurally cannot have. Every manifest states its
   scope with an `ARCH:` token:
   - `ARCH:4/4` — reads correctly on all four arches (the byte-order-honest modules: `elf`,
     `cbfs`, `fdt`, `evlog`, `struct`, `sha256`).
   - `ARCH:x86-only` — inherently single-arch (`pe`, the UEFI/UKI work). Declared honestly,
     never by pretending.
2. **Liveness**, *where it applies* — `HOST-ONLY` when a host oracle grades it or a step is
   hosted-only (e.g. `write-file` authoring), `LIVE` vs `SNAPSHOT` for a seam-backed view
   (pacme), so a corpse is never mistaken for a running subject. Omitted where it does not
   apply (a pure in-memory reader).

The checker requires an `ARCH:` token on **every** manifest, and — where a module declares a
liveness stance — requires it to be one of `HOST-ONLY`/`LIVE`/`SNAPSHOT`.

## Optional extensions (taken "in part")

- `NAME-write ( handle …edit-args -- ok? )` — an **in-place edit**: a *delta*, not a whole
  re-author. It **refuses BY NAME before any byte moves** and writes **nothing** on refusal
  (never a partial), returning `true` only when the edit landed. This is the "refuse before the
  irreversible step" half of roadmap Tier 2. The edit args are per-format (a PE section by name,
  a cpio member by name, the kernel command line), stated in the module's header; the *shape* is
  the contract. The refusal keeps the module's own by-name prefix (`edit|`, `cpio|`, `bp|`) — a
  bool-returning verb that names its reason, the readers' voice one mutation further.
- `NAME-emit ( …compose-args -- adr len )` — **author** a whole artifact's bytes into a buffer
  (`elf-write`'s `author-exit-elf`, `evlog-author`, `cbfs-write`'s `cbfs-author`). The writer's
  other flavour: composing, rather than editing in place.
- `NAME-live` — a seam-backed handle, for the pacme live inspector.

A module implements only what it has; the contract does not require the writer half of a
reader. The registry names what is absent rather than treating it as an error.

**The writer half is graded on a DELTA, not a whole artifact** (roadmap Tier 2, and this repo's
"assert the outcome, not the mechanism"): `tests/test-contract-conformance.sh` reads an artifact,
calls `NAME-write`, re-reads, and asserts the edited field became the new value **and a neighbour
did not** — the edit, and *only* the edit. Its **refuse-before-write control** feeds an
oversized/invalid edit and asserts it is refused by name **and the bytes are unchanged** (a
partial write, or a write that ran despite a refusal, fails it). A writer graded only on a
whole authored artifact cannot see either property.

## The registry (`dsl/contract.fth`)

Loading a module ends with `register-module ( name-addr name-len manifest-xt -- )`. Then:

- `.modules` — list every registered module and call each manifest.
- `module? ( name-addr name-len -- flag )` — is a module present?
- `need-module ( name-addr name-len -- )` — print `MODULE <name>: not loaded` when absent,
  nothing when present. This generalises what `elf.fth`'s `hook` does for `elf32.fth` today
  (`… dsl/elf32.fth is not loaded`).

## Conformance is checked, and the checker proves itself first

`tests/test-contract-conformance.sh` drives the headless `openbios-unix` firmware and asserts,
per registered module: the required core exists; `NAME-validate` **refuses that module's
corrupt fixture BY NAME** (and accepts a valid one); `NAME-manifest` carries an `ARCH:` token
and, where present, a valid liveness label; and — the **separability guarantee** — a slim
profile loading only a subset still passes, with each absent module **named** absent.

Per this repo's "the control is where the bugs are," the checker exercises **must-catch /
must-not-catch fixtures before it is aimed at a real module**: a module missing `NAME-validate`
→ caught; a manifest with no arch scope → caught; a slim build that lies about a dropped module
→ caught; a fully-conformant fixture → not caught. The **CBFS negative control is load-bearing**:
before the `cbfs-list` fix a corrupt first entry read as an empty archive, so that control must
be seen to **fail** on the pre-fix code and **pass** after — the failing-then-passing pair that
proves the defect was real.

## Consumers pin the version

Each capstone that consumes a module gains a one-line pin — *"consumes {elf, cpio, bootparams}
at contract v1"* — in its README/plan when it is built, so drift closes at the moment of
building (roadmap §2). The contract is versioned; a breaking change is `contract v2`.

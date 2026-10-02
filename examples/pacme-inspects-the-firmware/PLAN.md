# pacme-inspects-the-firmware — build plan (this lab)

The canonical design, the feasibility measurements, and the full spike ladder (Spikes 0–5) live
in **[`../../DESIGN-NOTES-pacme-a-live-firmware-inspector.md`](../../DESIGN-NOTES-pacme-a-live-firmware-inspector.md)**
(TODO §32). This file records what *this operationalization* covers and defers.

## What PR1 delivers (DONE, verified live 2026-10-02)

**The bridge foundation — Spike 0 + Spike 1**, the two spikes that make every later one runnable:

1. **Spike 0 — the bridge DECISION ([`bridge.sh`](bridge.sh)).** Of the three surfaces (FILE
   snapshot / NBD live-block / gdbstub-IOD live-RAM), the chosen bridge is **NBD** over QEMU's QMP
   `block-export-add` of the firmware's live IDE NVRAM node — `LIVE: block-only`, with FILE as the
   `SNAPSHOT` fallback and the IOD named for Spike 5. **The writable-export hazard is measured:**
   QEMU **refuses** a writable export of the in-use node (permission conflict with `ide1-hd1`), so
   Spike 4's "edit live" shape is settled by data — pause the guest or edit through the guest, never
   a silent writable export.
2. **Spike 1 — the seam is faithful ([`smoke-pacme-seam.sh`](smoke-pacme-seam.sh)).** poke's bytes
   over the bridge == `od` of the live store, with a one-byte-corruption control that bites.

The shared bringup/QMP/teardown logic is in [`lib-bridge.sh`](lib-bridge.sh); [`deps.sh`](deps.sh)
names and checks the external deps (GNU poke required now; pacme = Spike 3).

## What PR2 delivers (DONE, verified live) — Spike 2 + the contract's `NAME-live`

Three pickle-vs-Forth-vs-foreign subjects, each a one-verdict track, all verified on `openbios-unix`
+ GNU poke 4.0:
- **FDT (LIVE)** — `fdt.pk` == `dsl/fdt.fth` == `fdtdump` on OpenBIOS's live flattened device tree;
  and **`fdt-live`** (the contract's **`NAME-live`**, added to
  `../openbios-the-rival-that-shipped/dsl/fdt-conform.fth`) re-flattens the live `/dt` each call — a
  tree change grows the live re-read while an independent snapshot does not. `dsl/CONTRACT.md` now
  specifies `NAME-live` concretely; `tests/test-contract-conformance.sh` implements the previously
  spec-only **liveness-label grade** + the behavioral live-vs-snapshot grade (its control bites: a
  static `-live` is caught). `NAME-live` landed with its consumer, not as a stub.
- **PE (HOST-ONLY)** — poke's shipped `pe.pk` == `dsl/pe.fth` == `objdump` on a UKI's COFF header.
- **CBFS (HOST-ONLY)** — our `cbfs.pk` == `dsl/cbfs.fth` == `cbfstool` on the ROM's first entry.
- Each control watched to bite (pickle magic/signature refusals; the three-reader grade fails on a
  deliberately misread field; the static-`fdt-live` live grade). poke CLI only — the pacme UI is
  Spike 3. **Honest liveness:** only FDT is live (the one firmware structure with a dsl reader);
  pe/cbfs are static files, so no `NAME-live` — their live forms are the Spike-5 gdbstub IOD.

## What this lab defers (with the crux, so each is a spike and not a bare TODO)

- **Spike 3 — the acme UI.** `poked` + the tmux pokelets; a click on a struct field jumps the byte
  view to its span. **Crux:** wiring the pokelets over `poked`'s socket and grading the highlighted
  span (== the field's `offset..size`) headless. The **pacme source build** (deps.sh has the recipe:
  `git clone https://sourceware.org/git/pacme.git`, autotools into a lab-local prefix) lands here —
  PR1/PR2 do not build pacme because the bridge/seam/pickle spikes use the `poke` CLI alone.
- **Spike 4 — edit live — DONE, verified live** ([`smoke-pacme-edit.sh`](smoke-pacme-edit.sh)).
  Resolved Spike 0's write-path question: attaching the IDE NVRAM node with **`share-rw=on`** makes
  the writable NBD export accepted, so poke edits `boot-file=A`→`B` in the LIVE store and a fresh
  boot reads exactly `B` (nothing zapped — a same-length value edit keeps the OFW partition valid).
  Controls bite: unshared node → writable export refused (the Spike-0 hazard, re-measured); an
  out-of-bounds poke write refused before it lands. The firmware observes the edit at its next boot
  (NVRAM's access model), stated.
- **Spike 5 — live RAM.** The one bespoke C `pk_register_iod` device onto QEMU's gdbstub (the API
  supports exactly one foreign IOD); until it exists, RAM views are `SNAPSHOT`, labelled.

## Grading discipline (the repo's rules, applied here)

- Every pacme view is graded against a **foreign** reader — `od`/`xxd` for the raw seam (Spike 1),
  the Forth `dsl/` toolkit for structure (Spike 2). The firmware's own read is never its own oracle.
- Each track carries a **negative control watched to bite** (the seam-faithful assertion fails on an
  off-by-one read; the Spike-0 hazard measures QEMU's real refusal, not an empty-node false one).
- The liveness label is honest: `LIVE: block-only` for the NBD seam, `SNAPSHOT` for any FILE-backed
  RAM view — a snapshot is never dressed as live.

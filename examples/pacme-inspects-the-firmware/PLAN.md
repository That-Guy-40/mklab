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

## What this lab defers (with the crux, so each is a spike and not a bare TODO)

- **Spike 2 + the contract's `NAME-live` — PR2.** Point `pe.pk` / an fdt / a cbfs pickle at the
  live buffer; each field pacme decodes == the Forth toolkit's read of the same bytes; a
  one-byte-off or truncated pickle is refused by name. **This is where `NAME-live` is built** — the
  dsl module gains `NAME-live ( -- handle )` (the seam-backed, re-reading live view, vs. a snapshot
  copy) + a `LIVE`/`SNAPSHOT` manifest label, and the conformance checker grades pacme's read
  against it. `NAME-live` lands here, with its consumer, not as a speculative stub.
  **Crux:** what `NAME-live` concretely binds to on a QEMU-backed firmware (the live NBD/IOS view
  vs. a captured snapshot), and how the checker drives a live-vs-snapshot distinction headless.
- **Spike 3 — the acme UI.** `poked` + the tmux pokelets; a click on a struct field jumps the byte
  view to its span. **Crux:** wiring the pokelets over `poked`'s socket and grading the highlighted
  span (== the field's `offset..size`) headless. The **pacme source build** (deps.sh has the recipe:
  `git clone https://sourceware.org/git/pacme.git`, autotools into a lab-local prefix) lands here —
  PR1 does not build pacme because the bridge/seam spikes use the `poke` CLI alone.
- **Spike 4 — edit live.** Gated on Spike 0's measured hazard: pause the guest / route through the
  guest's store words; refuse a malformed edit **before** the write.
- **Spike 5 — live RAM.** The one bespoke C `pk_register_iod` device onto QEMU's gdbstub (the API
  supports exactly one foreign IOD); until it exists, RAM views are `SNAPSHOT`, labelled.

## Grading discipline (the repo's rules, applied here)

- Every pacme view is graded against a **foreign** reader — `od`/`xxd` for the raw seam (Spike 1),
  the Forth `dsl/` toolkit for structure (Spike 2). The firmware's own read is never its own oracle.
- Each track carries a **negative control watched to bite** (the seam-faithful assertion fails on an
  off-by-one read; the Spike-0 hazard measures QEMU's real refusal, not an empty-node false one).
- The liveness label is honest: `LIVE: block-only` for the NBD seam, `SNAPSHOT` for any FILE-backed
  RAM view — a snapshot is never dressed as live.

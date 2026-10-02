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

- **Spike 3-lite — the field-span GRADE — DONE** ([`smoke-pacme-span.sh`](smoke-pacme-span.sh)).
  Investigation result (poke 4.0): a mapped value's byte span IS exposed via `'offset`/`'size` on
  composite (struct/array) values (not scalar field-copies) — `/#B` gives plain bytes. poke's magic
  field span and FDT_Header extent match `dsl/fdt.fth`'s `fdt-fields` offset table, the span lands on
  the real magic, and the span one field over does not (control). So poke + the toolkit agree on
  *where* fields live — the headless core of the acme UI's field-to-byte navigation.
- **Spike 3-full — the interactive acme UI — deferred.** The tmux pokelets over `poked`'s socket;
  the **pacme source build** (deps.sh has the recipe: `git clone https://sourceware.org/git/pacme.git`,
  autotools into a lab-local prefix) lands here. **Crux:** driving + grading a live TUI headlessly;
  all spikes so far use the `poke` CLI alone (no pacme UI, no sudo).
- **Spike 4 — edit live — DONE, verified live** ([`smoke-pacme-edit.sh`](smoke-pacme-edit.sh)).
  Resolved Spike 0's write-path question: attaching the IDE NVRAM node with **`share-rw=on`** makes
  the writable NBD export accepted, so poke edits `boot-file=A`→`B` in the LIVE store and a fresh
  boot reads exactly `B` (nothing zapped — a same-length value edit keeps the OFW partition valid).
  Controls bite: unshared node → writable export refused (the Spike-0 hazard, re-measured); an
  out-of-bounds poke write refused before it lands. The firmware observes the edit at its next boot
  (NVRAM's access model), stated.
- **Spike 5 — live RAM — DONE, verified live** ([`smoke-pacme-live-ram.sh`](smoke-pacme-live-ram.sh),
  [`gdb-iod.c`](gdb-iod.c) → `pokegdb`). A bespoke C `pk_register_iod` device (the API supports
  exactly one foreign IOD) whose `pread`/`pwrite` are gdb RSP `m`/`M` packets to QEMU's gdbstub, so
  poke reads AND edits the LIVE guest. The firmware writes a nonce; we **locate it in physical RAM
  by scanning a `pmemsave` dump** (Forth addr ≠ physical on x86 — ofmem offset is real, so never
  assumed); poke-over-gdbstub, QMP `xp`, and the firmware agree. The firmware overwrites the cell →
  the same poke reader sees N2 via the gdbstub IOD (LIVE) while a snapshot *file* stays at N1
  (SNAPSHOT); poke then writes N3 and QMP + the firmware both read it back. **Crux resolved by
  measurement:** QEMU's gdbstub answers `m`/`M` while the guest *runs* (no halt needed) but HALTS
  the vCPU on attach and leaves it halted on a bare disconnect, so the IOD sends a `D` (detach) on
  close to leave the guest running — and `D` is rejected (`E22`) if `qSupported` negotiated
  `multiprocess+`, so the handshake stays plain. **Honest boundary:** OpenBIOS x86 runs CR0.PG=0
  (no paging) so a gdb linear address *is* the guest-physical one (== QMP `xp`); the IOD makes no
  translation claim; the gdbstub is a QEMU `-gdb` debug transport (a lab instrument); x86 only;
  libpoke GPLv3, host-side. So RAM is no longer `SNAPSHOT`-only — the live handle is the gdbstub IOD.

## Grading discipline (the repo's rules, applied here)

- Every pacme view is graded against a **foreign** reader — `od`/`xxd` for the raw seam (Spike 1),
  the Forth `dsl/` toolkit for structure (Spike 2). The firmware's own read is never its own oracle.
- Each track carries a **negative control watched to bite** (the seam-faithful assertion fails on an
  off-by-one read; the Spike-0 hazard measures QEMU's real refusal, not an empty-node false one).
- The liveness label is honest: `LIVE: block-only` for the NBD seam, `SNAPSHOT` for any FILE-backed
  RAM view — a snapshot is never dressed as live.

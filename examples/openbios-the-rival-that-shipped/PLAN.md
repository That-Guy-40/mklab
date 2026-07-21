# PLAN — openbios-the-rival-that-shipped

**Status: COMPLETE — all five spikes PASSED and the lab is assembled.**
Follow-on to `../open-firmware-forth-to-boot/` (PR #24). Same house style, same
spike→POC→assemble lifecycle; the new subject is the *other* IEEE 1275
implementation, `github.com/openbios/openbios`.

## Thesis

Two independent answers to the same standard, two survival strategies. OFW
(the sister lab) self-hosted in Forth and froze in Dec 2015 — era-gaps get
fixed *live at the prompt*. OpenBIOS reimplemented IEEE 1275 in C + a Forth
kernel, rode QEMU, and still ships (it's QEMU's default ppc/sparc firmware;
commits last month). Its era-gaps are *fixable C bugs* — which the Linux-boot
spike proves by fixing eight of them.

## Spikes (all out-of-tree in `~/openbios-lab/`, all agent-verified on KVM)

| # | De-risks | Outcome | POC |
|---|---|---|---|
| 1 | 2026 toolchain builds the tree | PASS first try (upstream CI-green); `toke` from source; five image shapes incl. `openbios-unix` | [1](POC-1-BUILD-BOX.md) |
| 2 | multiboot entry + console + prompt driving | PASS after 2 fixes (multiboot header, dict-module loading); x86 serial input works over a socket | [2](POC-2-OK-PROMPT.md) |
| 3 | payload-era mismatch | PASS first boot (i440fx, isolated `DOTCONFIG`/`obj`) | [3](POC-3-COREBOOT-PAYLOAD.md) |
| 4 | 2003 loader vs 6.3 bzImage | PASS both x86 tracks after a 6-bug chain (+1 self-inflicted, reverted) | [4](POC-4-BOOT-LINUX.md) |
| 5 | prove the swap-in | PASS — our `openbios-ppc` boots via `-bios`, banner date ≠ distro blob | [5](POC-5-PPC-SWAP-IN.md) |

## Decisions (user-confirmed)

- Name `openbios-the-rival-that-shipped`; ppc track = swap-in + prompt only
  (no ppc kernel sub-project); routed in `boot-and-crash` between the OFW lab
  and the linuxboot capstone.

## Deliverables

- `patches/01-x86-revival.patch` — eight x86-path fixes + `auto-boot?`=false,
  one reviewable diff, applied idempotently by `build-openbios.sh`.
- Scripts: `build-openbios.sh`, `build-coreboot-openbios.sh` (guards both
  sibling labs' coreboot artifacts), `run-openbios-qemu.sh`,
  `smoke-openbios.sh` (3 tracks), `showcase-rival-boots-linux.sh` (2 tracks).
- Reusable tool extracted: `tools/drive-pty-repl.py` (pty sibling of
  `drive-serial-repl.py`; ppc console input needs a real terminal).
- Docs: README, RUNBOOK, MANUAL_TESTING, this PLAN, POC-1..5.
- Provenance: cite-don't-mirror (upstream vendors its own wiki in-tree;
  README pins the clone commit).

## Justified deviations from the sister lab

- **No `upstream-tutorial/` archive** — upstream carries the whole
  openfirmware.info wiki in `Documentation/website/`; we pin the clone commit
  instead (house "follows upstream code" tier). Joins `close-to-the-metal`,
  NOT `provenance-vendored`.
- **New state dir** `~/openbios-lab/`; **new pty tool** (the socket driver
  can't type to ppc); **a source patch** (the frozen rival forbade one — this
  one invites it).

## Verification

Both catalogs green (`paths.py --check`, `link_check.py`); all five verdicts
reproduced in MANUAL_TESTING; the coreboot guard confirms linuxboot's and the
OFW lab's kept ROMs are untouched. Committed only when asked (trailer
`Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`).

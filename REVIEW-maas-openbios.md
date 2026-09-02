# Review — health of `metal-as-a-service/` and the OpenBIOS lab

**Date:** 2026-09-02
**Scope:** [`examples/metal-as-a-service/`](examples/metal-as-a-service/) (driver, drivers,
tests, chaos matrix, README · PLAN · DEFERRED) and
[`examples/openbios-the-rival-that-shipped/`](examples/openbios-the-rival-that-shipped/)
(the 54-patch series, `smoke-openbios.sh`'s 33 tracks, the `dsl/` type layer, the B.3
preboot-structure spikes, and the two workflows that gate them), plus the repo-wide state
both sit in.
**Method:** every suite and every repo gate was **run**, not read — here, and in the latest
CI logs on `main` where this container could not (no QEMU, no podman, no KVM). Each finding
below was then re-checked against the source line it names before it was written down. Two
deep reads were delegated and their claims verified independently; anything not re-verified
is marked as such. **The clone is shallow** (history begins 2026-08-27), so "recent" for a lab
that has not changed since then is dated from the documents' own stamps, not from git.

> **Verdict:** healthy and honest, with the risk concentrated in **stale prose** rather than
> broken code. `main` is green on every CI run inspected, the repo-wide gates pass, there are
> no open PRs or issues, and both suites ran with **0 failed**. Nearly every defect below is
> the class [`CLAUDE.md`](CLAUDE.md) names first — *a record that outlived its subject* — plus
> two instruments that cannot see what they were pointed at.

---

## 1. What was measured

| suite | here (no QEMU, root) | latest CI on `main` (#839, 2026-09-02) |
|---|---|---|
| `metal-as-a-service/tests/run-all.sh` | 39/39 ran — 31 passed, 8 skipped, 0 failed | 39/39 ran — 35 passed, 4 skipped, 0 failed |
| `openbios-the-rival-that-shipped/tests/run-all.sh` (Tier A) | 40/40 ran — 6 passed, 34 skipped | same, by design (no tree, no QEMU in `ci.yml`) |
| `openbios-tier-b.yml` boot tracks | not runnable here | **13 of 33** tracks booted on x86/amd64/ppc, all PASS, 8m36s |
| `tools/tests/run-all.sh` (meta-checkers) | 19 passed, 1 skipped, **1 failed** | all pass |
| `tools/link_check.py` | 4607 links, 626 anchors, 0 broken, 0 orphans | green |
| `tools/paths.py --check` | every unit routed, generated docs fresh | green |

The MAAS skips here are the expected precondition gates (QEMU ×3, dnsmasq ×2, OVMF, swtpm,
cpio); in CI four remain (`test-verifying-rom`, `test-measured-image`, `test-probe-nic`,
`test-fleet-preflight`), each named in the summary.

**The one local red is the instrument, not the repo.**
[`tools/tests/test-doc-verbs.sh`](tools/tests/test-doc-verbs.sh) fails its own §0 control
(*"a fenced command naming a verb the phase-2 driver does not have did NOT fail the run"*) when run as root. Cause:
[`tools/lib/verb-probe.sh`](tools/lib/verb-probe.sh) refuses to invoke any verb as root
(correctly — some verbs build host networking) and **returns 0, "present", for every verb**,
so the planted missing verb can never register as a problem. CI runs unprivileged and passes.
The guard is right; its *report* is wrong — under root the checker should `skip` and say
UNKNOWN, not print `CONTROL FAILED`, which reads as a broken checker to anyone who runs it
locally. **R0** below.

---

## 2. `metal-as-a-service/` — finished, quiet, and its prose has drifted

### 2.1 State

Every increment, fast-follow and live run is recorded done; DEFERRED's four numbered gaps
are struck; the only hardware-blocked item (TODO C.1) was re-verified 2026-08-23. The lab has
not changed since late August. CI runs the full suite **including the chaos matrix**
(`chaos-run.sh` is driven by
[`tests/test-chaos-matrix.sh`](examples/metal-as-a-service/tests/test-chaos-matrix.sh), which
ran and passed in CI). The code held up under inspection: the EXIT net in
[`tests/lib.sh`](examples/metal-as-a-service/tests/lib.sh) is correct and no test overrides
it (checked mid-line and multi-line), cached records are identity-bound (`disk.raw.sha256`
re-derived; `pcrs.expected` stamped with its image digest), kills are by PID, there is no
`set -e`, no `pkill -f`.

### 2.2 Findings

**M1 — Ledger defect #11 was fixed in one driver of three.** The scoped console read
(`console_mark`, [`drivers/image.sh:89`](examples/metal-as-a-service/drivers/image.sh)) that
stopped a *second* deploy passing on the *first* boot's banner exists only in the image
driver. [`drivers/ramdisk.sh:273`](examples/metal-as-a-service/drivers/ramdisk.sh) and
[`drivers/install.sh:274`](examples/metal-as-a-service/drivers/install.sh) still
`grep -qE "$marker" "$console"` over the whole append-only log. Their tests cannot catch it
because they still **pre-write** the login line before `deploy`
([`tests/test-install-driver.sh`](examples/metal-as-a-service/tests/test-install-driver.sh),
[`tests/test-ramdisk-driver.sh`](examples/metal-as-a-service/tests/test-ramdisk-driver.sh),
[`tests/test-region-and-scheduler.sh`](examples/metal-as-a-service/tests/test-region-and-scheduler.sh))
— the mechanism-not-outcome fixture that `MOCK_BMC_BOOT_SAYS` in
[`tests/mock-bmc.sh`](examples/metal-as-a-service/tests/mock-bmc.sh) was built to retire.
Only the image driver's test uses it.

**M2 — The defect ledger has three sizes.** `README.md:36` says *thirteen*; `PLAN.md:32`
says *fifteen* and `PLAN.md:38` says *thirteen*; `DEFERRED.md:50` says *fifteen* and its
own heading at `DEFERRED.md:85` says **16**. A count written in prose, four times, drifting
exactly as [`CLAUDE.md`](CLAUDE.md)'s run-all rule predicts.

**M3 — `DEFERRED.md` contradicts itself on `describe`.** The item is struck through as
DONE (2026-08-06) at `DEFERRED.md:55` and `:420`; the file's **last bullet**
(`DEFERRED.md:789-790`) still reads, un-struck: *"`image` and `image+measured` still accept
any image name."*

**M4 — README says the chaos matrix covers "all five layers"** (`README.md:305`).
[`chaos-run.sh`](examples/metal-as-a-service/chaos-run.sh) declares **nine** (driver · oob ·
artifact · registry · process · metadata · console · reconcile · ui).

**M5 — `rescue` is a stub nobody has recorded.** `maas-lab.sh:669` prints *"recovery ramdisk
(root-password-reset idioms) boots here — fast-follow"* and moves the state. The lab plan
still lists `rescue-init.sh` and `RUNBOOK.md` as ⬜; DEFERRED.md does not mention it. An
open item that is in no open-items file is the quiet-abandonment shape DEFERRED's own
header warns about.

**M6 — `chaos-run.sh --help` runs the entire chaos matrix.** Its argument parser
(`chaos-run.sh:60`) knows `--json` and `--layers`; anything else falls through to a full
run. The sandbox is throwaway, so nothing is harmed — but it is the same shape
`build-coreboot-openbios.sh` had before Tier A caught it ("exited 0 having STARTED A
COREBOOT BUILD"). Found *by* that class of checker: pointing
[`tools/check-usage-is-data.sh`](tools/check-usage-is-data.sh) at the script produced a
chaos-matrix PASS line in the middle of its output.

**M7 — MAAS has no `tests/test-usage-is-data.sh`,** and nothing enforces that a suite ships
one (nine suites do; this one, the largest, does not). Running the checker by hand also
exposed **two false positives in the checker itself** that would block enrolling MAAS:

- `create-fleet.sh:649-650` — the usage heredoc contains **backslash-escaped** backticks
  (`` \`up\` ``), which do *not* substitute; the scanner has no notion of an escaped
  backtick and reports "command substitution … it will RUN." The rendered help shows plain
  backticks and runs nothing.
- `maas-lab.sh` and `create-fleet.sh` write help to **stderr by design** (`cat >&2 <<EOF`);
  the checker's §2 heuristic treats any stderr on `--help` as "something executed."

Per *the control is where the bugs are*: both are checker blind spots that need a
must-not-catch fixture, not lab changes. The four drivers additionally exit 2 on `--help`
(UNKNOWN to the checker), the same state the OpenBIOS scripts were in before 2026-08-25.

**M8 — smaller.** `cleanup_sandboxes` in `tests/lib.sh` runs unconditionally and no test
reads `$_EXIT_RC`, so a CI failure keeps only the verdict line and destroys the sandbox that
would explain it. `drivers/image.sh:109` gates a health loop on `tail … | grep -qE`, which
under `pipefail` can invert a match into a miss on a large console (TODO §0.4's fifth
recorded instance was this exact shape). Several tests SKIP *mid-file* after sections that
already passed (`test-fleet-preflight.sh` §6, `test-signing-cert-profile.sh`,
`test-image-measured-driver.sh`, `test-chaos-matrix.sh`), hiding proven work behind one
missing tool.

### 2.3 Recommendations, ranked

1. **Port `console_mark` into `ramdisk.sh` and `install.sh`**, and flip their tests from
   pre-written consoles to `MOCK_BMC_BOOT_SAYS` — that is the negative control that makes
   the port provable. (M1)
2. **Reconcile the ledger to one number** and strike or delete `DEFERRED.md:789-790`; fix
   `PLAN.md:38` and `README.md:305` in the same pass. (M2, M3, M4)
3. **Record the rescue stub** in DEFERRED.md or drop the roadmap rows in the lab plan. (M5)
4. **Give `chaos-run.sh` a real `--help`** that runs nothing, then add
   `tests/test-usage-is-data.sh` — *after* teaching the checker about escaped backticks and
   stderr-by-design help (see R1). (M6, M7)
5. Gate `cleanup_sandboxes` on `$_EXIT_RC`; capture-then-test the gate at
   `drivers/image.sh:109`. (M8)

---

## 3. `openbios-the-rival-that-shipped/` — all the momentum, and a coverage gap under it

### 3.1 State

Thirty-five commits in the week to 2026-09-02: patches 36–54 (long-mode coreboot payload,
the memory map, `/memory available`, reproducible builds, five `openbios-unix` fixes,
`write-file`), the `dsl/` type layer through arrays and device fields, and the **B.3**
preboot structure toolkit — Spike −1 green, Spike 0 complete on four arches (#375), Spike 2's
*read* direction landed (#376). The discipline is unusually good: the patch catalog, the
tested-tree identity and the build pin all agree (`e5ac46d`, `Arch-tested: x86 amd64 ppc
unix`); `test-track-list.sh` proves 33 dispatch arms = 33 wrappers = 33 entries in
`run-all.sh`; every recent track carries labelled negative controls and an observer outside
the firmware. Tier B builds all four targets, **fails** (never skips) when an artifact is
missing, and refuses an empty track list — both regressions guarded in `tools/tests/`.

What remains open, per [`TODO.md`](TODO.md) B.3 and
[`REVIEW-preboot-structure-toolkit-plan.md`](REVIEW-preboot-structure-toolkit-plan.md):
Spike 2's write/surgery direction and the other three ROMs; Spike 1 (TCG event log, needs a
swtpm subject); Spike 3 (a live flash window). Review item F10 (the four-arch matrix in CI)
is half done: `unix` is *built* in Tier B and not *booted*.

### 3.2 Findings

**O1 — 20 of 33 tracks never run in CI.** `DEFAULT_TRACKS` in
[`.github/workflows/openbios-tier-b.yml`](.github/workflows/openbios-tier-b.yml) lists 13.
Left out: `cbfs` (the newest work — #376 did not touch the workflow), `unix` and
`file-writer` (Tier B already builds the binary they need), `memory-available`,
`client-forth`, the three writer tracks (`pmem-writer`, `mmio-writer`, `flash-writer`), the
five `persist*`/`nvram`/`floppy` tracks, `amd64-ctx`/`-fault`/`-pmem`/`-linux`, and both
`coreboot*` tracks. The workflow's own comment says *"an unrun test rots."* Several of the
excluded tracks gate on nothing more than `qemu-system-x86_64` and the artifacts the gate
already requires; the coreboot-dependent ones (`cbfs`, `coreboot*`) are a legitimate cost
question, but the answer should be written down rather than implied by omission.

**O2 — A post-build SKIP is only a warning.** In the *Boot the tracks* step, a track that
exits 77 after a successful build produces `::warning::` and the job stays green. Combined
with O1, a default list whose tracks all skipped would pass the Tier B gate. The artifact
gate above it is the right shape; this step should hold the same line for tracks whose
preconditions the job itself installs.

**O3 — The track driver can be killed silently.** All 33 `tests/test-smoke-*.sh` `exec`
[`smoke-openbios.sh`](examples/openbios-the-rival-that-shipped/smoke-openbios.sh), whose
own EXIT trap (`smoke-openbios.sh:134`) has **no TERM/INT/HUP naming** — the exact §7
defect [`tools/check-harness-net.sh`](tools/check-harness-net.sh) guards against, invisible
to it because the trap lives outside `tests/`. A CI deadline or Ctrl-C on a 140-second
`struct-device` boot ends in a log that simply stops. The lab's own
[`tests/lib.sh`](examples/openbios-the-rival-that-shipped/tests/lib.sh) already has the
naming; the driver does not use it.

**O4 — A broken link the link checker cannot see.** `TODO.md:5118-5119` links
`patches/48-todo-17-5-cause-2-bootstrap-baked-host-pointers.patch`; the file is
[`patches/48-scrub-host-arena-pointers.patch`](examples/openbios-the-rival-that-shipped/patches/48-scrub-host-arena-pointers.patch).
`link_check.py` reports 0 broken because the link's `[Patch\n48](…)` text **wraps across
two lines** and the scanner works per line — a line-anchored instrument standing in for a
question about a *link*, the shape [`CLAUDE.md`](CLAUDE.md) records three times already.

**O5 — `cbfs` claims to grade the type column and does not.** The usage text, the PASS line
and TODO all say offset/**type**/size/name match `cbfstool`; the grading loop at
`smoke-openbios.sh:3343-3354` compares offset, name and length. Type is printed, never
asserted. Also: the reader covers **one** of the four ROMs and takes the COREBOOT region
offset from the host's `cbfstool layout` rather than parsing the `'ORBC'` master header, so
"walks the ROM" is currently "walks a region the host located." Stated here so the write
direction is not built on a read direction narrower than its own description.

**O6 — The lab's `PLAN.md` is a fossil with no banner.** `PLAN.md:3` says *"COMPLETE — all
five spikes PASSED"*; `PLAN.md:39` says `smoke-openbios.sh` has *3 tracks*, `patches/` has
*one* patch, and there is *no* `upstream-tutorial/`. Reality: 54 patches, 33 tracks, a
vendored Phrack 53:9. Same family, smaller: the Tier B log prints *"all five artifacts
present"* while checking **seven**; `README.md:359` and
[`tools/openbios-pin-check.sh`](tools/openbios-pin-check.sh) say *three* arches where the
tested tree says four; `MANUAL_TESTING.md` §11 carries `36/36 … 29/29` where disk is
43/33; [`MANUAL-TYPE-LAYER.md`](examples/openbios-the-rival-that-shipped/MANUAL-TYPE-LAYER.md)
§11 and §13 predate #375/#376 (no cursor vocabulary, no `elf32.fth`/`elf-write.fth`/`cbfs.fth`).
Also, *not re-verified here:* the weekly pin-check Routine's prompt reportedly still says
"30 patches … x86, amd64 and ppc."

**O7 — `TODO.md` §0.6 headlines "two named steps left"** while every box beneath it is
ticked, and the live B.3 work sits under §0.5 *"deliberately deferred."* A reader following
the file's own "start here" lands in the wrong section.

### 3.3 Recommendations, ranked

1. **Add `cbfs`, `unix` and `file-writer` to `DEFAULT_TRACKS`** and make a post-build 77
   fail for any track whose preconditions the job installs; write the exclusion reason next
   to each track that stays out. (O1, O2)
2. **Give `smoke-openbios.sh:134` the TERM/INT/HUP naming** `tests/lib.sh` already has, or
   route the wrappers through `lib.sh`, so a killed track cannot end silently. (O3)
3. **Fix the patch-48 link in `TODO.md`** and teach `link_check.py` to see a link whose text
   wraps a line, with a wrapped-link fixture in its negative control. (O4)
4. **Put a status banner on the lab's `PLAN.md`** (or bring `:3`, `:39` current), fix the
   "five artifacts" string and the "three arches" prose. (O6, O7)
5. **Make `cbfs` compare the type column** — or stop claiming it — then extend the track to
   all four ROMs *before* starting the write direction. (O5)

---

## 4. Repo-wide, and the two instruments

**R0 — `verb-probe.sh` under root:** turn the root guard's `return 0` into a named UNKNOWN
that the §0 control recognises, so `test-doc-verbs.sh` says *"SKIP: run unprivileged"*
instead of *"CONTROL FAILED"* on a developer's root shell. (§1)

**R1 — `check-usage-is-data.sh`:** add must-not-catch fixtures for a backslash-escaped
backtick and for help written to stderr, then enrol MAAS. (M7)

**R2 — `link_check.py`:** wrapped link text (O4). Both O4 and R0 are the same lesson as
2026-08-08 and 2026-08-15: *a scan that matches nothing and a scan that is broken print the
same green ✓.*

**Sizes worth knowing.** `smoke-openbios.sh` is 4,766 lines in one `case`, the largest arm
(`property-abi`) 512 lines; `TODO.md` is 5,515 lines; root-level plan and review documents
total ~17k lines. None of that is wrong, but it is why the stale-prose class dominates this
review — the prose has outgrown what a reader re-verifies by hand, and the checkers are what
keep it honest. Three of them have a blind spot each, listed above.

---

## 5. What this review did NOT verify

- Any boot behaviour locally — all track results are from CI run #73 of `openbios-tier-b.yml`
  and run #839 of `ci.yml`, both green.
- The Routine's prompt text and last exit code (O6, last paragraph).
- Whether the excluded OpenBIOS tracks that gate only on QEMU + artifacts would in fact pass
  on the Tier B runner (O1) — the gates were read, not run.
- `check-patch-hygiene.sh` A3b against the live upstream blob.

Nothing in the two labs was changed by this review.

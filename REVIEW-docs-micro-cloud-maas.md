# Review — the docs of `micro-cloud/` and `metal-as-a-service/`

**Date:** 2026-08-21
**Scope:** every Markdown file of the two composed labs and their root design
documents — [`examples/micro-cloud/`](examples/micro-cloud/) (README · MANUAL_TESTING ·
four RUNBOOKs · LEDGER · DEFERRED, ~4.2k lines) plus
[`MICRO_CLOUD_LAB_PLAN.md`](MICRO_CLOUD_LAB_PLAN.md) (5.4k lines), and
[`examples/metal-as-a-service/`](examples/metal-as-a-service/) (README · MANUAL_TESTING ·
PLAN · DEFERRED, ~5.0k lines) plus
[`METAL_AS_A_SERVICE_LAB_PLAN.md`](METAL_AS_A_SERVICE_LAB_PLAN.md). Roughly 15k lines of
prose.
**Method:** the repo's two doc gates were run first and both are **green**, so nothing
below is something a checker already asks. Every finding was then **reproduced by running
the thing the document describes** — the tool's own dispatch table, the suite's own
summary line, `git log -S` for "has this ever worked" — and no finding is recorded on the
strength of reading alone. Where a claim held, it is listed in §2 with the measurement,
because an audit that reports only failures is indistinguishable from one that checked
only the parts it suspected.

> **Status 2026-08-21: all nine are FIXED**, in the same pass that found them. D1 carries a
> regression test with its own control — [`test-inspect-facts-from-a-stream.sh`](examples/metal-as-a-service/tests/test-inspect-facts-from-a-stream.sh),
> which drives the **README's literal form** (here-string and all) and re-injects the
> original `-f` gate into a copy of the tool to watch the assertion bite. The fix was
> additionally verified by reverting it in the real driver and confirming the test failed
> (`rc=1`, naming the quickstart form) before restoring it. The eight doc fixes each keep the
> wrong sentence visible as a struck-through correction rather than quietly overwriting it,
> because in a repo whose bug class #1 is *a record that outlives its subject*, the record of
> what a document used to claim is worth more than a tidy diff. Re-verified after the fixes:
> §2's table, plus `metal-as-a-service` **39/39 listed tests ran — 39 passed, 0 skipped, 0
> failed** (the new test is the 39th). **Two further items** — a status header extended by
> appending, and a shellcheck directive that had never suppressed anything — were spotted
> outside the nine and fixed the same day; they are [§3b](#3b-two-more-spotted-in-passing-and-fixed-the-same-day).

---

## 1. Verdict

**Nine defects, and every one of them is in a sentence written in the present tense.**

Both labs keep two kinds of prose, and the split is almost perfectly clean:

- **Dated records** — `PLAN.md`'s increment outcomes, `MANUAL_TESTING.md`'s transcripts,
  `LEDGER.md`, both `DEFERRED.md` files. Sampled repeatedly during this pass; **accurate
  throughout**, including places where accuracy was inconvenient. micro-cloud's
  `DEFERRED.md` strikes a line through rather than deleting it and explains why, and MAAS's
  `DEFERRED.md` opens by explaining that its runner prints a **ratio** so that "no integer
  has to be maintained by hand here."
- **Current-state prose** — the two READMEs and the design sections of
  `MICRO_CLOUD_LAB_PLAN.md`. **All nine defects are here.**

That is this repo's own bug class #1 one level up. A claim bound to a date stays honest
forever, because the date is part of the claim. The *same* claim written in the present
tense is a **cache entry** — and the entry that best proves it is §8.2 of the plan, which
asserts a wizard count, and then asserts its own freshness with the words **"Not stale."**
Both halves are now false.

The severities below are about what a reader *does* with the sentence, not about how wrong
it is. D1 is first because it is the one that makes a person's terminal print an error in
the first five minutes.

| | finding | file | fix |
|---|---|---|---|
| **D1** | a quickstart command that has never worked at any commit | MAAS README | one character in `maas-lab.sh` |
| **D2** | three different, all-wrong test counts in one file | MAAS README | delete the integers |
| **D3** | the status header and the body disagree about what is built | micro-cloud README | edit |
| **D4** | a lab that shipped two weeks ago is still listed as "Queued" | micro-cloud README | edit |
| **D5** | 5 of 13 lines of a "CLI surface" name verbs the tool refuses | plan §5.1, §5.8 | edit |
| **D6** | a count that asserts its own currency, wrong twice over | plan §8.2, §15 | edit |
| **D7** | a spec the built code correctly ignored | plan §8.1 | edit |
| **D8** | a documented precondition that fails on the authoring host | micro-cloud MANUAL_TESTING | edit |
| **D9** | "verified live" bound to a date the file has since moved past | MAAS README | edit |

---

## 2. What held — measured, not assumed

An all-defect report is as uninformative as an all-PASS one. These were checked and are
sound:

| check | result |
|---|---|
| [`tools/link_check.py`](tools/link_check.py) | 4084 local links, **566 anchors verified**, **0 broken**; no orphaned file under `examples/` |
| [`tools/paths.py --check`](tools/paths.py) | every ref resolves · every lab unit routed · generated docs not stale |
| `examples/micro-cloud/tests/run-all.sh` | **23/23 listed tests ran** (matching 23 files on disk) — 17 passed, **6 skipped and named**, 0 failed |
| `examples/metal-as-a-service/tests/run-all.sh` | **38/38 listed tests ran** — 38 passed, 0 skipped, 0 failed |
| MAAS README's headless quickstart | every line runs **except D1's**, including `watch` (rendered all four `probe` milestones to 100%) |
| micro-cloud path checkpoint · step 4 | `lab-fc.sh mac api1` → `06:00:ac:47:f1:f7`, and `fabric.sh mac api1` derives the **same** value — the marker `06:00:ac:47` matches |
| micro-cloud path checkpoint · step 10 | `micro-cloud.sh plan` → 45 lines, `bash -n` clean, contains `fabric.sh tap api1` |
| filenames referenced in prose **and inside code fences** | every one resolves in both labs — the tree-diagram blind spot micro-cloud's README names is currently clean |
| MAAS README's "Files" table | names every `*.sh`, `*.toml`, `lib/*.py` and `drivers/*.sh` on disk |
| micro-cloud MANUAL_TESTING's seven success-signature rows | all ✅ and each carries the observation, not just a verdict |
| **after the fixes** — `link_check.py` · `paths.py --check` · `bash -n` · `shellcheck -x --severity=warning` | all green |
| **after the fixes** — both suites | micro-cloud **23/23, 17 passed / 6 skipped / 0 failed** (unchanged); MAAS **39/39, 39 passed / 0 skipped / 0 failed** |

**Not re-run, and named as such:** the `zero-touch-provisioning` path's step-8 checkpoint
is `metal-as-a-service/tests/run-all.sh && echo MAAS-SPINE-OK`. The suite was measured at
`38/38 … 0 failed`, rc=0, so the marker follows from that exit status — but the one-liner
itself was not executed a second time. Derived, not observed.

---

## 3. The nine

### D1 — the MAAS quickstart's third command has never worked at any commit

[`examples/metal-as-a-service/README.md`](examples/metal-as-a-service/README.md), the
headless "Try it" block:

```bash
./maas-lab.sh inspect node1 --facts /dev/stdin <<<'{"cpus":4,"mem_kb":8192000,"mac":"52:54:00:aa:bb:01"}'
```

```
maas: inspect: --facts file not found: /dev/stdin
rc=1
```

`maas-lab.sh` gated the injection with `[[ -f "$facts" ]]`. Under bash 5.2 a **here-string
is a pipe**, so `/dev/stdin` resolves through `/proc/self/fd/0` to a pipe: `-r` is true and
**`-f` is false**. `cp -- /dev/stdin` would have worked fine; the guard asked the wrong
question about the file.

Three things make this worth putting first:

1. **It never worked.** The guard arrived in `49ee863` (increment 1, the tool's first
   commit) and the README line in `23520df` (increment 2). The guard has not been touched
   since. There is no commit at which this line ran.
2. **The failure is contagious in the document.** The very next line —
   `./maas-lab.sh show node1  # note the schedulable summary (cpus=4 mem_mb=8000 …)` —
   then prints `schedulable -`. The reader's second command *also* contradicts the doc,
   for the same one reason.
3. **A green suite could not see it.** All 38 tests pass, and the only `--facts` caller
   among them ([`test-state-machine.sh:46`](examples/metal-as-a-service/tests/test-state-machine.sh))
   passes a **real file**. The suite exercises the mechanism through a seam no reader uses.
   That is the second of this repo's two invisible bug classes, in the tests of the lab
   that first wrote them down.

**Fixed:** the gate now asks whether the source is **readable and not a directory**, so a
pipe, a process substitution and a plain file all work and a directory is still refused by
name — plus a regression test that drives the **README's own form** (`--facts /dev/stdin`
from a here-string) rather than a file, with the pre-fix `-f` shape re-injected and watched
to fail.

### D2 — three different test counts, in one file, all wrong

Measured: `38/38 listed tests ran — 38 passed, 0 skipped, 0 failed`.

| line | claim |
|---|---|
| 24 | ``tests/run-all.sh`` → **15 passed** |
| 71 | `bash tests/run-all.sh   # 6 one-verdict smokes, all headless` |
| 291 | `tests/` — **27 headless smokes** |

CLAUDE.md's rule is *"Don't write the test count in prose"*, and the reason given there is
that one integer got hand-copied into five documents and drifted in one. Here it drifted
**three ways inside a single document**. The sharper part is that the lab's own
[`DEFERRED.md`](examples/metal-as-a-service/DEFERRED.md) already states the correct
practice — *"The runner states a ratio rather than a count … so no integer has to be
maintained by hand here. The one that used to be had already drifted."* The rule is written
in the lab and broken three times in the lab's front door.

The **dated** counts in `PLAN.md` (`3 passed` on 2026-07-25 … `26 passed` on 2026-07-28)
and `MANUAL_TESTING.md` are **not** this defect. They are log entries, and a log entry
bound to a date cannot go stale.

**Fixed:** all three replaced with the ratio the runner prints, and the sentences no longer
carry an integer that has to be maintained.

### D3 — the micro-cloud README's header and its body disagree

Line 3: `**Status (2026-08-19):** **all ten build slices have landed.**`
Line 42: `**Slices 9–10 remain.**`

Forty lines apart, in the file a reader opens to find out where the lab is.
[§14 of the plan](MICRO_CLOUD_LAB_PLAN.md) has all ten rows ✅, so the header is the
correct half. The date stamp is also a day early: slice 10 is recorded `DONE 2026-08-20`.

This survived the sweep in `0b6a382` (*"Seven stale status lines"*), which is the useful
part of the finding — a sweep that fixes seven instances of a class is not the same as
closing the class.

**Fixed:** the stale sentence replaced with what the body is actually there to say, and
the stamp moved to the date the claim became true.

### D4 — `nested-calico-sandbox/` shipped two weeks ago and is still "Queued"

The micro-cloud README carries a 📋 callout headed **"Queued as its own lab unit"**,
linking to `DEFERRED.md`'s *queue* anchor. Meanwhile
[`examples/nested-calico-sandbox/`](examples/nested-calico-sandbox/) exists, with its own
README, MANUAL_TESTING, `tests/`, two `.toml` specs and six scripts; it is routed (so
`paths.py --check` is green about it); and micro-cloud's **own** `DEFERRED.md` says at line
11: *"✅ **Items 1, 2 and 3 are DONE.** … is packaged."*

The queue that owns the item is right. The README that advertises it is wrong — which is
the worse direction, because the README is where someone looks to find out whether the
thing exists.

**Fixed:** the callout now points at the built lab and records what it settled, keeping the
"derived from one host at one Calico version" caveat that was the reason for the debt.

### D5 — §5.1 "CLI surface": 5 of 13 lines name verbs the tool refuses

[`MICRO_CLOUD_LAB_PLAN.md`](MICRO_CLOUD_LAB_PLAN.md) §5.1 prints a thirteen-line block
under the heading **CLI surface**. Run against the shipped
[`lab-fc.sh`](phase7-firecracker/lab-fc.sh):

```
console    -> rc=1 | lab-fc.sh: unknown verb: console (try --help)
ssh        -> rc=1 | lab-fc.sh: unknown verb: ssh (try --help)
restore    -> rc=1 | lab-fc.sh: unknown verb: restore (try --help)
preserve   -> rc=1 | lab-fc.sh: unknown verb: preserve (try --help)
mmds       -> rc=1 | lab-fc.sh: unknown verb: mmds (try --help)
snapshot api1 --tag warm -> rc=1 | lab-fc.sh: unknown flag: --tag
```

The real snapshot shape is `snapshot {create|list|restore|delete} <name> [snap]`, and the
real clone verb is `clone <src> <snapshot> <new>` — so §5.8's fleet loop
(`for n in 1 2 3 4 5; do lab-fc.sh restore "w$n" --from api1:warm; done`) is the same
defect a second time.

What makes this more than an ordinary design/implementation gap is that **§5.1 has been
amended in place once already** — the ⚠️ note correcting `destroy`'s tap behaviour, dated
2026-08-02, sits directly beneath the block. A section that visibly receives corrections
reads as maintained, so the six un-amended lines read as current rather than as a wish
list.

**Fixed:** the block now marks each line as SHIPPED or NOT BUILT with the real shape beside
it, and §5.8's loop uses the verb that exists.

### D6 — a count that asserts its own currency, wrong twice over

§8.2, verbatim:

> P1 measured it: **five wizards** (`wizards/base.py` + `phase1.py`…`phase5.py`,
> `wizard_select.py`) with **28 tests passing**. Not stale.

Measured: `lab_tui/screens/wizards/` holds `phase1.py` … `phase5.py` **and `phase7.py`** —
six — and `pytest tests/test_wizards.py` reports **36 passed**. The sixth arrived in
`4cf6283`, whose subject line is literally *"the guided-path guard, **the sixth wizard**,
and a probe that was wrong in the dangerous direction"*, and whose landing is recorded in
**§14 of the same document**, in the slice-9 row. The plan contradicts itself across two
sections.

§15's roadmap row repeats "**28 tests green**".

Both numbers are attributed to P1, which would be fine on its own — a cited measurement
carries its own date. **"Not stale."** is what converts a citation into a currency claim,
and it is the two words that make this a defect rather than a footnote.

**Fixed:** both sites now name the six wizards, cite the suite rather than an integer, and
the currency claim is gone.

### D7 — a spec the built code correctly ignored

§8.1 specifies the `fc` backend and includes:

> `console_command → lab-fc.sh console <name>`

The backend has since been written.
[`phase6-tui/lab_tui/backends/fc.py:114`](phase6-tui/lab_tui/backends/fc.py) sets
`console_command=[]`, and [`tests/test_backends_fc.py:98`](phase6-tui/tests/test_backends_fc.py)
asserts it stays empty — correctly, because `lab-fc.sh console` does not exist (D5). The
implementation is right and the specification is wrong, in the direction that would break
the tool if the next person followed it.

§8.1 is also still framed as future work (*"A sixth is a known shape:"*) for a component
that is built and green.

**Fixed:** §8.1 records what was built and why the console line was not.

### D8 — a documented precondition that fails on the host the lab was built on

[`examples/micro-cloud/MANUAL_TESTING.md`](examples/micro-cloud/MANUAL_TESTING.md), under
*"Preconditions, checked before anything privileged"*:

```
$ phase7-firecracker/lab-fc.sh preflight --config examples/micro-cloud/micro-cloud.toml
  FAIL     firecracker not on PATH
FAIL: 2 gate(s) refused, 0 UNKNOWN — nothing was created
```

`lab-fc.sh` resolves the binary with `command -v firecracker` in three places
(`:417`, `:1059`, `:1388`) and honours no override, while **every test in the lab**
resolves it from the workdir (`MC_FIRECRACKER`, defaulting to
`~/.local/state/lab-create/micro-cloud-s3/firecracker` — where the pinned v1.16.1 copy
actually is). Three RUNBOOKs give the `export PATH=…` line that makes this work. The
precondition block that *needs* it does not, and it is the block a reader runs first.

The tool is not wrong to read `PATH`; the doc is wrong to send someone to it without the
line. Fixing the doc is the honest fix — the alternative (teaching `lab-fc.sh` an env
override) is a driver change this audit has no mandate for, and is recorded in §5 instead.

**Fixed:** the precondition block now carries the `export PATH` line, with a pointer to the
RUNBOOK that explains where the binary came from.

### D9 — "verified live" bound to a date the file has since moved past

The MAAS README's Files table says of
[`drivers/image.sh`](examples/metal-as-a-service/drivers/image.sh): *"**destructive**;
verified live 2026-07-28"*. That file last changed on **2026-08-06** in `ff4b22f` — *"the
ownership gate could not refuse, the attestation gate could not fail — and five records
that outlived their subjects"* — which added **46 lines**.

The claim is not false about the past: the live run happened. But nothing binds it to the
bytes that ship today, and the commit that moved past it is *itself* about records that
outlived their subjects. This is the mildest of the nine and it is included because
"a version string is not an identity; compare hashes" is a rule this repo wrote down, and
a date beside a filename is weaker than a version string.

**Fixed:** the claim now names the commit the live run covered, so a later reader can see
exactly what has changed underneath it.

---

## 3b. Two more, spotted in passing and fixed the same day

Neither was in the nine — one is a shape problem rather than a false statement, and the
other is not prose at all — but both are the same lesson and both were cheap.

### D10 — a status header extended by appending, so the headline froze

The MAAS README opened **"Build status — increments 1–3 of the roadmap (§9 steps 1–3)."**
Increments 4, 4a, 5, 6, 7 and three fast-follows have landed since. The paragraph *did* say
so — but only by accretion: it kept its 2026-07-25 headline, narrated the later work in the
**future tense** (*"Step 4 adds…"*, *"Step 6 adds…"*), never mentioned increment 5 at all,
and delivered the correction as a clause at the very end (*"All 7 increments are done"*).

Nothing here is false, which is exactly why it stayed: **a status line a reader has to
finish the paragraph to distrust** passes every review that asks "is this accurate?" and
fails the only question that matters, which is what someone believes after reading the
first sentence. Appending is how a status block rots without any single edit being wrong.

**Fixed:** the true status leads, the ladder is a table in the past tense with increment 5
restored, and `DEFERRED.md`'s "all-✅ is not finished" caveat is carried up into it.

### D11 — a `# shellcheck disable` that had never suppressed anything

`tests/test-e2e-reaps-sink.sh` carried:

```bash
# shellcheck disable=SC1090
MD_PID=""; source "$FN" || fail "the extracted reap() does not parse"
```

A directive attaches to the next **command**, not the next **line**. The next command here
is `MD_PID=""`; the `source` two statements along never received it, so shellcheck reported
SC1090 anyway. Measured rather than reasoned: **deleting the directive entirely changed
shellcheck's output not at all** — which is the definition of an inert suppression, and the
control that proves it. Splitting the compound line so `source` stands alone takes the
finding to zero.

This is [`tools/check-harness-net.sh`](tools/check-harness-net.sh) §1's defect in miniature,
and CLAUDE.md's rule pointed at a linter instead of a test: **a thing aimed at a line is not
a thing aimed at a command.** Not a CI gate — CI shellchecks the phase drivers and the
micro-cloud instruments, not this file — so nothing would ever have said so.

*Postscript, because it cost a round and is the same joke: the comment written to explain
all this began a line with `# shellcheck`, which shellcheck parses as a directive
**wherever it appears**. The prose broke the file it was documenting (SC1073). Reworded.*

---

## 4. The pattern, stated once

A dated line is a **measurement**. A present-tense line is a **cache**, and it obeys every
rule this repo already has about caches: it keeps being served after its subject changes,
nothing errors because the record is merely false, and the failure surfaces downstream
wearing someone else's clothes — as a reader's `unknown verb: console`, or as a `rc=1` in
the third command of a quickstart.

Both labs already know this. The fix that generalises is not "sweep the stale lines" — that
was `0b6a382`, and D3 survived it. It is **derive the fact instead of writing it down**:
the test counts (D2) should never have been integers, because the runner already prints a
ratio; the verb lists (D5, D7) are `--help` output; the wizard count (D6) is `ls`. Every
one of the nine is a value that a command could have answered.

Two of the nine are now *checkable* as a side effect of their fix (D1 has a regression test
driving the README's own form; D2's ratio is printed by the runner). **The other seven are
not.** A checker that asks *"does every verb a doc types exist in the tool that receives
it?"* would have caught D5 and D7 mechanically, and is the obvious next tool in the
`check-guided-path-is-a-view.sh` family — recorded in §5, not built here.

---

## 5. What this audit did NOT check — UNKNOWN, not PASS

- **The privileged half of micro-cloud.** Six root-gated tests SKIPped, by name. Every
  claim in MANUAL_TESTING's success-signature table rests on author-run evidence this pass
  did not reproduce.
- **The author-run half of MAAS.** `run-e2e*.sh`, the real `install`/`image` drivers,
  `create-fleet.sh up` — all need rootful libvirt and a fleet. Their PLAN.md transcripts
  were read, not re-run.
- **Prose accuracy about mechanism.** This pass asked "does the command exist and run"; it
  did not verify that every *explanation* in 15k lines of prose is technically correct.
- **The two big plans' appendices** were sampled where a finding led into them, not read
  end to end.
- **A doc-verb checker does not exist.** D5 and D7 were found by hand. Until something asks
  the question on every run, the class is open regardless of these fixes.
- **D8's driver-side question is open**: should `lab-fc.sh` honour an env override for the
  Firecracker binary, as its own tests do? Deliberately not decided here.

> **Addendum 2026-08-21, after the merge — the fix for D1 was not being run.** Reading the
> CI log for the merge commit rather than its green tick: `examples/metal-as-a-service/tests/run-all.sh`
> **was in no CI job at all**. The largest suite in the repo — 39 tests, headless by
> construction — was the only one nobody gated, so D1's regression guard, whose entire
> purpose is to stop a documented command from silently ceasing to work, would never have
> run anywhere but a human's terminal. Closed by adding it to
> [`.github/workflows/ci.yml`](.github/workflows/ci.yml).
>
> Two things came out of doing that, and both are the same lesson as the nine:
>
> - **A green tick does not say which rows ran.** micro-cloud reported `11 passed, 12
>   SKIPPED, 0 failed` on the runner against `17 passed, 6 skipped` here. Both green. Every
>   runner already names its skipped files — inside a collapsed `::group::` that nobody
>   opens on a passing job. The step now re-surfaces them as one annotation.
> - **The loop's own skip-tolerance was dead code.** `bash "$t"; r=$?` under GitHub's
>   default `bash -e` never reaches the assignment: a suite exiting **77** killed the step
>   with the raw status, before the `[ "$r" -eq 77 ]` test written to permit it — and every
>   suite after it in the loop was silently not run. Never observed, because none had yet
>   skipped wholesale. Measured, then re-measured as a control: the old shape aborts at the
>   77 and never prints its own `::endgroup::`.

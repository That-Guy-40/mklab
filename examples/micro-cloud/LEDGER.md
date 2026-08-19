# LEDGER — micro-cloud

> [`MICRO_CLOUD_LAB_PLAN.md`](../../MICRO_CLOUD_LAB_PLAN.md) §0.1 rule 3: every slice's
> break pass writes here, and §15's first exit criterion is that this file **is not empty
> and every entry names something OBSERVED rather than predicted**. *A micro cloud that
> came up first try taught nobody anything.*

Entries are `L<slice>-<n>`. Each says what was **measured**, on what date, and — the part
that makes a ledger worth keeping — **what the wrong belief would have cost**. A finding
with no consequence attached is a note; a finding with one is a lesson.

The slices before 10 wrote their findings into the plan's appendices as they went (A–N,
plus [`DEFERRED.md`](DEFERRED.md)); those are not copied here, because a copy is the
stale-record bug this lab has a whole section about. This file starts where the plan's
dated record stops and is the running ledger from here on.

---

## L10-1 — Calico's node IP is on an interface that is DOWN, and `db` is the instance that could move it

**Observed 2026-08-19**, unprivileged, with `fabric.sh status` and `/sys/class/net`:

```text
calico tunnel : local 10.216.67.1 dev lxdbr0
candidate set : 2 enx00051b8eb138 192.168.1.106/24 CANDIDATE     # lxdbr0 is NOT in it

lxdbr0    operstate=down   carrier=0  members=(none)
incusbr0  operstate=down   carrier=0  members=(none)
```

Calico's VXLAN tunnel endpoint is `10.216.67.1` on **`lxdbr0`** — a bridge that is `down`
and memberless, and therefore **not a candidate by Calico's own first-found rules**. The
cluster is bound to an interface its own autodetection would no longer choose.

**What the plan said, and why it was wrong.** §9.2 records, from 2026-08-04, that *"both
daemons are inactive and both bridges are gone"*, and reasons from that: starting either
engine *"manufactures a fresh autodetection candidate under a live cluster."* Neither half
holds now. Both daemons are active (`incus`, `snap.lxd.daemon`), both bridges exist, and
the hazard has **inverted**: the candidate was not manufactured by a lab, and the
dangerous direction is no longer creating an interface but *changing one Calico already
depends on*.

This is the plan's own rule pointed at the plan: **a fact asserted three sessions ago is a
cache entry.** The parenthetical was true when written and is now a confident falsehood
sitting inside an argument about safety.

**What it would have cost.** `db` is the LXD instance. Left to its defaults the driver
attaches an instance to the engine's managed bridge — `lxdbr0`. Bringing `db` up would put
a member on it and take the bridge UP; `micro-cloud.sh down` would take the last member off
and put it back down. Autodetection re-runs **every 60 seconds** (plan Appendix I, from
`monitor-addresses/autodetection_methods.go:103`), so the lab would be flipping the
candidacy of the interface carrying a live cluster's tunnel endpoint, twice per demo.
That is [F.6](../../MICRO_CLOUD_LAB_PLAN.md#f6-additive-was-not-safe--the-tap-captured-a-live-clusters-tunnel) with the roles reversed.

**The fix is in the spec, not in a warning.** `micro-cloud.toml`'s `db` block carries an
explicit `nic` device parented to `br-mc0`, so LXD's own bridge is never brought up or down
by this lab — and `br-mc0` is structurally invisible to Calico by rule 1 of the fabric's
four constraints. The isolation matrix names `db` UNKNOWN and points here, because a row
that needs a privileged run should say what the privileged run is walking into.

---

## L10-2 — `up` orders invocations, and readiness is a different question

**Observed 2026-08-19** while rendering the first plan. `lab_tui.topology`'s `_UP_ORDER` is
`chroot, vm, fc, docker, podman, lxd`, so the plan starts `edge` (a QEMU VM) **before**
`api1` — and `edge`'s cloud-init `runcmd` pings `api1` by name and writes
`EDGE-PING-BY-NAME OK|FAIL` to its console. On a cold `up` that probe can only report FAIL.

The tempting fix is to move `fc` ahead of `vm` in the tuple, and it is the wrong fix in an
instructive way: **it would not make the probe deterministic.** `edge` takes ~30 s to reach
cloud-init and a microVM boots in ~0.5 s, so reordering merely changes which side usually
wins a race that is still a race. The property wanted is *"api1 answers before edge's
first-boot script runs"*, and no ordering of **invocations** can assert a fact about
**states**. The control plane has no readiness wait, and inventing one inside
`micro-cloud.sh` would put a fifth answer beside four drivers that each already have their
own.

So it is documented rather than papered over: `micro-cloud.sh up` says in its own output
that every step returning 0 *"is not the same as every guest being ready"*, `status` is
where you find out, and [`RUNBOOK-micro-cloud.md`](RUNBOOK-micro-cloud.md) re-runs the peer
check by hand once everything is up. That re-run is the real capstone evidence; the
first-boot line is a nice-to-have that happens to be racy.

---

## L10-3 — the plan generator could not run without a file-watching library

**Observed 2026-08-19.** `python3 -m lab_tui.topology up micro-cloud.toml` died with
`ModuleNotFoundError: No module named 'watchfiles'`.

`plan_up`/`plan_down` are pure: TOML in, argv out, nothing executed and no engine consulted.
But `topology.py` imported `phase_script` from `backends/base.py`, which imports pydantic and
`lab_tui.state`, which imports `watchfiles`. So the module that tells you **which commands to
type** could not be reached without installing the entire Textual stack.

That is a §0.2 violation with a very quiet presentation. *"Delete the guided path and nothing
is lost"* is not true of a plan you can only obtain by installing the guided path's
dependencies — and nothing would ever have reported it, because the only caller was the TUI,
which naturally had them.

Fixed by moving `phase_script` into a dependency-free [`lab_tui/paths.py`](../../phase6-tui/lab_tui/paths.py)
and re-exporting it from `backends/base.py`, so there is still exactly one definition of
where a phase script lives. `micro-cloud.sh` now asks that module for the order instead of
re-deriving it.

---

## L10-4 — three defects the slice's own tests found on their first run

Grouped because they are one shape: **a check that passed while measuring the wrong thing.**

| # | the defect | how it presented | what caught it |
|---|---|---|---|
| a | `micro-cloud.sh` pasted an **absolute** `MC_SPEC` onto the repo root (`"$REPO//tmp/x.toml"`) | the topology half of the plan was perfect — that path is passed through untouched — while `tap_instances` read a file that does not exist and contributed **no fabric taps at all**. A plan with every tap missing still parses and still orders correctly | the tap assertion in `test-micro-cloud-plan.sh`, first real run |
| b | the plan's printer emitted a **trailing space** on every line (`printf '%q '`) | `grep 'fabric.sh up$'` matched nothing, so the ordering check compared two empty positions — and its negative control "bit" because **both** were empty, not because the order was wrong. A control passing for the wrong reason | noticed when the real plan failed a check its own control had just "proved" |
| c | the isolation matrix read `dmesg` through a **pipe** (`dmesg \| tail -1 && echo readable`) | both rows reported `readable` on a host with `kernel.dmesg_restrict=1`, where neither is: a pipeline's status is the **last** element's, and `tail` succeeds over empty input | the host row's answer being implausible |

(c) is this repo's own standing rule — *never pipe a command whose exit status is the gate*
— appearing **inside the test written to catch checks that measure the mechanism instead of
the outcome**. (b) is the more useful one to remember: a negative control is itself code,
and a control that fires for the wrong reason is worse than no control, because it certifies
the assertion it was supposed to interrogate.

A fourth, caught before it shipped: the matrix's UNKNOWN rows were recorded **conditionally**
— the Firecracker row was listed only if KVM or the binary were missing, and on this host
both were present, so the row was neither measured nor reported. It simply vanished from a
summary that said "2 rows measured". Rows are now unmeasured **by default** and would have to
be actively probed to leave the list.

---

## L10-5 — the intermittent was two things, and one of them was me

**Reported first, corrected here.** This entry originally said `test-clone-entropy.sh` fails
intermittently inside `run-all.sh`, and then — once a failure was captured — that it *"has a
path that exits 1 while booting the VMGenID-active source, and gives no reason for it."*
That diagnosis was wrong, and how it was wrong is the useful part.

### What the evidence actually showed

The captured failure was three lines:

```text
  - booting the VMGenID-active source…
Terminated
FAIL: test exited early (rc=1) — no verdict was printed by the test itself
```

`Terminated` is bash reporting a **SIGTERM**, not anything the test did. And the log that
contained it was **truncated**: 94 lines, no `=== summary ===`, and the log for the *next*
iteration of that loop never created at all. Its siblings were 239 lines with a summary.

That is the signature of the run being killed from outside — and the outside was this
session's own tool, which times a foreground command out at two minutes and SIGTERMs the
process group. Reproduced deliberately: re-running the identical three-iteration command
produced the identical pattern — **run 1 complete (239 lines), run 2 truncated with no
summary, run 3 never started** — and a SIGTERM aimed at a suite's process group mid-boot
reproduces the bare `Terminated` line exactly.

So of the two failures this entry was opened for:

| | verdict |
|---|---|
| the failure inside the timed-out loop | **not a defect.** The run was killed; nothing in the test went wrong, and no `fail` message could ever have named it |
| the first failure, which completed with a full `14 passed, 6 skipped, 1 failed` summary | **still unexplained.** Its message was never captured. 1 occurrence in ~20 suite runs since |

### What was ruled out on the way, by measurement rather than by argument

- **Stale-PID kills** — `/proc/sys/kernel/pid_max` is 4194304 here, so PID reuse inside one
  suite run is not a mechanism.
- **A delayed killer left by an earlier test** — the chaos harness `wait`s on the child it
  kills; nothing in the suite backgrounds a watchdog that outlives it.
- **`run-all.sh`** — a plain `bash "$t"; r=$?`. No pipe, no background, no timeout.
- **The predecessor** — the suite pair (`test-fleet-clones.sh` then `test-clone-entropy.sh`)
  ran 8 consecutive times without a failure.

### The defect this actually found

Not in the test. **In the net, in all thirteen `tests/lib.sh` files.**

Bash runs no EXIT trap for an untrapped fatal signal, so a run stopped from outside — a CI
deadline, an agent harness timeout, Ctrl-C — ended in a log that simply stops. No verdict, no
reason. A reader then does what this ledger did: attributes the silence to whichever test was
unlucky enough to be running, and goes hunting for a bug that is not there.

`lib.sh` now traps `TERM`/`INT`/`HUP`, records which one, and re-exits `128+N` so the EXIT
trap still runs. The output becomes:

```text
FAIL: test was TERMINATED FROM OUTSIDE by SIGTERM — the run was cut short, so nothing above
is a result about the code under test
```

`tools/check-harness-net.sh` §7 proves it in every suite, against a copy of the lib with the
traps stripped out — **and that control immediately disproved a claim written into all
thirteen files on the way**: the first version of the comment said the traps also rescued the
teardown. They do not. A killed shell already ran its cleanup; measured against the
pre-change lib, which printed its cleanup line and no verdict at all. The claim was corrected
everywhere it had been propagated, and cleanup is now asserted in §7 only as an ordinary
regression guard — adding traps must not *cost* the teardown.

### And the smaller thing that was worth doing anyway

`boot_and_snap` made four tool calls and waited up to 60 seconds while printing **nothing**.
Every `fail` in it already named its own defect, but a death that produces no verdict at all
— a signal, an OOM, a host reboot — left the reader unable to tell `create` from `start` from
a guest that never counted. It now announces each stage, so the last line printed names the
command. That would not have prevented this misdiagnosis, but it shortens the next one.

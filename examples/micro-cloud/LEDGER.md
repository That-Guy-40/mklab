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

## L10-5 — one intermittent failure in `test-clone-entropy.sh`, and the evidence was not kept

**Observed 2026-08-19.** The first full `tests/run-all.sh` of the slice reported
`15 listed, 14 passed, 6 skipped, 1 failed` with `test-clone-entropy.sh` in the failed list.
An immediate re-run of the whole suite passed, and four consecutive standalone runs of that
test passed. So: **1 failure in 6 observations, and no message.**

**Caught in the act.** The first write-up of this entry said *"no message"* and set the next
step: keep the full log, not the summary. Six more suite runs did, and the seventh reproduced
it. The whole of what the test printed:

```text
  - booting the VMGenID-active source…
FAIL: test exited early (rc=1) — no verdict was printed by the test itself
```

That second line is **`lib.sh`'s EXIT net**, not the test. So the finding is not about
entropy at all:

> `test-clone-entropy.sh` has a path that exits 1 while **booting or cloning the
> VMGenID-active source**, before any assertion runs, and gives no reason for it.

Which is this repo's own rule broken from the inside — *a bare non-zero exit with no message
is a test bug, not a result* — and the reason the safety net exists. Without the net there
would have been a blank terminal and an `rc=1`. With it there is a location.

What is now known, and what is still not:

- **KNOWN**: it dies in the first of the 2×2's two boot phases, not in a comparison. Every
  run that got past that line finished and passed, including the four that reported the
  window as UNKNOWN — so the grading logic is not implicated.
- **KNOWN**: it is not a false PASS. The net turns it into a loud failure, which is the
  cheap half of *fix the liar first* already paid for.
- **UNKNOWN**: which command. The candidates are all in the boot/clone sequence — a VMM that
  did not come up in time, an API socket not yet accepting, a `snapshot create` racing a
  pause — and `set -e` makes them indistinguishable from the outside.
- **UNKNOWN**: whether suite context is causal. 2 failures in 8 suite runs, 0 in 4
  standalone. That is consistent with contention (this is the first slice in which a podman
  container runs alongside it) and equally consistent with a timeout that is simply tight.

**Not attributable to slice 10** — nothing here touches Firecracker, snapshots or the clone
path — but *"probably unrelated"* is a belief, so it stays open. The fix is a named
follow-up: give every step of that boot sequence its own `fail` message, so the next
occurrence names the command instead of the phase. An intermittent nobody has localised is a
test whose verdict means less than it appears to, in both directions.

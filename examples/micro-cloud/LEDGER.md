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

---

## L10-6 — the first privileged run: the fabric was right, the orchestrator was wrong

**Run 2026-08-19**, `sudo`, reduced spec (two microVMs), on the live-Calico host.

**The safety property held, measured independently of the fabric's own assertion.** Calico's
tunnel binding (`10.216.67.1 dev lxdbr0`), its `cali*` veth count (2) and `ip_forward` (1)
were identical before, during and after; teardown asserted the absence of our bridge, taps,
nft table, route and dnsmasq, and the script re-checked all of it from outside. `plan` ran
nothing. `down` returned 0. `up` returned 1 — and that is the finding.

### What blocked it

```text
FAIL  tap mc-api1 is owned by uid 1000, not 0 — Firecracker would get EPERM from TUNSETIFF
```

`fabric.sh` gives each tap to the **invoking user** on purpose: that is slice 2's finding,
and slice 5a's test drops both VMMs to uid 1000 *precisely so the ownership assertion means
something*. But `micro-cloud.sh up` ran the whole plan as root, because the fabric needs
root — so the two halves disagreed by construction.

**The preflight was right and the orchestrator was wrong**, and the wrongness is not a
permissions nuisance: a root `up` runs Firecracker as uid 0 against a tap built for an
unprivileged VMM. Had the gate not refused, the lab would have kept working while quietly no
longer demonstrating the thing it exists to demonstrate. The same collision sits one step
further along — `lab-podman.sh` refuses to run as root at all, because `metrics` is a
**rootless** sidecar and that is §9.3's exhibit.

Fixed by making the privilege boundary follow the resource rather than the command: the
network is root's, the instances are the user's. `micro-cloud.sh` now prefixes every
phase-tool step with `runuser -u $SUDO_USER --`, taken from **the same `MC_OWNER`/`SUDO_USER`
variable `fabric.sh` uses to decide who owns a tap** — two independent answers to *"who is
this lab for"* being exactly how the halves came to disagree. The prefix is prepended **into
the plan**, so `plan` still prints the command that actually runs.

It also fixes a wrinkle the run surfaced on the way: `runuser` sets `HOME` to the target
user's, so the drivers use *your* state directory. A root `up` had been creating instances in
`/root/.local/state` that a later unprivileged `status` could not see.

### Two smaller things, both caught by something reporting honestly

- **`UNKNOWN`, not a pass, on a dirty image.** `api1.ext4` — copied out of a workdir where a
  guest had been running — was marked dirty, `debugfs` refused to open it, and preflight
  said *"/sbin/init NOT verified"* rather than passing it. Its twin `api2.ext4` passed. An
  `e2fsck -fy` cleared it. The gate behaved exactly as the UNKNOWN rule requires: a check
  that could not run did not report the thing it checks as fine.
- **`status` printed nothing under "addresses".** The lease file existed and was empty,
  which is what the fabric leaves when it is up and no guest has DHCPed yet — but an empty
  section reads like a section that failed to run. It now says so, and distinguishes that
  from an unreadable file. (The path itself had already been fixed before this run: it was
  guessing dnsmasq's distro default rather than the `--dhcp-leasefile` the fabric passes, and
  is now bound to `fabric.sh`'s own `STATE=` by a test.)

---

## L10-7 — the second privileged run: green, and three defects only a green run could show

**Run 2026-08-19**, `sudo`, reduced spec. **`up` rc=0, `down` rc=0.** Two microVMs created and
started (pids confirmed *running*, not merely forked; `kernel_check = "match"`,
`rootfs_source_check = "match"`), and the cluster's binding, veth count and `ip_forward`
identical before, during and after.

The privilege fix from [L10-6](#l10-6--the-first-privileged-run-the-fabric-was-right-the-orchestrator-was-wrong)
worked, and it is visible in the plan rather than hidden in the run:

```text
runuser -u sqs -- …/phase7-firecracker/lab-fc.sh start api1
```

`preflight` then reported **`tap mc-api1 is owned by uid 1000 — openable unprivileged`**,
which is the sentence the whole design exists to produce.

**And the guests really joined the fabric.** From `api1`'s own console:

```text
dhcp rc=0
addr   : 10.71.0.101/24
route  : default via 10.71.0.1 dev eth0
resolv : search mc.lab nameserver 10.71.0.1
```

That is the reserved address, taken against the MAC the two tools derive independently — the
claim §9.2 makes, observed rather than asserted.

### The three defects, all of them inside a run that returned 0

| # | what it did | why a green run was the only way to see it |
|---|---|---|
| 1 | `status` reported **`UNKNOWN (driver could not be asked)`** for both microVMs | they were RUNNING, and `inspect` said so three lines further down the same log. `status` called `inspect <name> --json`; phase 7 **has no `--json`** (phases 2 and 5 do — it was written by analogy) and does not reject it either: it prints its ordinary TOML and exits 0, so `jq` failed and the fallback fired. **A false UNKNOWN is not the safe direction** — once UNKNOWN can also mean *I looked wrongly*, it stops carrying information in either direction |
| 2 | the preflight's tap-owner gate refuses a root VMM claiming **EPERM**, and that is false | measured with `tun-open.py`: root opened a tap owned by uid 1000 and TUNSETIFF **succeeded**. The kernel's rule is `owner == euid OR CAP_NET_ADMIN`. The gate was right to be unhappy and wrong about why — now it passes for root with a warning that a root VMM discards the property the tap was made for, and fails (truthfully) only for an unprivileged mismatch |
| 3 | `status`'s address section was **empty** while both guests already held their leases | the readiness gap of [L10-2](#l10-2--up-orders-invocations-and-readiness-is-a-different-question), seen from a new side: `up` returns when the VMMs are *running*, and a guest still has to boot and complete a DHCP exchange after that. Not a fault; but "empty" read as "broken", so the message now says which it is and points at the guest console |

### The guard for #1 took three attempts, and each was caught by its own control

The check is *"every flag micro-cloud.sh hands a driver is one that driver advertises **for
that verb**"*. Getting there:

1. a `grep | sed` pipeline that **matched nothing** — it reported "no flags found" and
   passed, which is indistinguishable from having checked everything. Its control re-injected
   the bug and the check stayed green.
2. rewritten in python, fed by a heredoc — but `python3 -` reads its **program** from stdin,
   so the piped data never arrived and it again examined nothing.
3. working, but keyed on (tool, flag) — which **passed the re-injected bug**, because
   `--json` *is* advertised by `lab-fc.sh`… on its `list` line. A flag that exists for a
   different verb is not a flag this verb takes, and borrowing one verb's flag for another
   was the entire defect.

Now keyed on (tool, **verb**, flag), and it catches the real bug and passes when it is fixed.
A usage line that elides its options (`lab-fc.sh create    ... [--dry-run]`) is reported
**UNKNOWN**, not as a refusal: `create --config` is genuinely valid, and an oracle that
cannot answer must not be read as saying no.

**The oracle here is help text, which is normally the wrong kind** — and that is stated in
the test rather than hidden, because phase 7 *silently ignores* an unknown flag. Running the
tool with the flag and without it produces the same successful output, so there is no
behavioural signal to probe. When a tool cannot be made to tell you, its documentation is the
only oracle left.

---

## L10-8 — the full spec: the chroot and the VM both built, and the capstone probe could never have worked

**Run 2026-08-19**, `sudo -E`, the whole `micro-cloud.toml`. `up` rc=1 at t+22 s, `down` rc=0,
elapsed 276 s. Calico's binding, veth count, `ip_forward` **and** both engine bridges'
membership identical before and after.

### What got built

* **the chroot** — `debootstrap` completed, `/var/chroots/micro-cloud-base` populated. §2's
  spine, created by the one step that legitimately keeps root.
* **`edge`** — provisioned from a cached Debian cloud image and started (pid 625835), on a
  real fabric tap: `br-mc0`'s members were `mc-api1 mc-api2 mc-edge`.
* **the halt** — `lab-fc.sh create` refused: *"instance 'api1' already exists"*, left over
  from the previous run, because `down` stops microVMs and never destroys them. Both halves
  are deliberate and together they make a second full run impossible without a reset. That is
  the halt-don't-converge contract working; it is now documented with the four destroy
  commands rather than left to be rediscovered.

`db` and `metrics` were never reached, because `up` halts rather than carrying on.

### The finding: a documented command that could not have worked at any commit

The runbook's capstone probe was `lab-vm.sh ssh edge -- ping api1`. It waited **240 seconds**
and got nothing, and the reason is structural rather than transient:

> `lab-vm.sh ssh` connects to `127.0.0.1:$ssh_port`. That port is a **slirp host port
> forward**. `edge` is `network_mode = "tap"` — there is no forward, and there never was.

Meanwhile `lab-vm.sh list` went on printing `SSHPORT 2222` beside it: a number describing
nothing. This is the repo's own recorded bug class arriving in a doc I wrote — *the CLI verbs
a doc cites all exist, while its first command had never worked at any commit* — and it is why
"the verb exists" is not the same question as "the verb applies here".
`tools/check-guided-path-is-a-view.sh` verifies the former and cannot see the latter.

Fixed in the driver rather than only in the doc: `ssh` now **refuses tap and bridge VMs by
name**, before the *is it running* check — because whether a VM can be reached is a fact about
its configuration, not its run state, and answering "it is not running" first sends the reader
to `start` and then straight into the hang. The refusal names the console and the fabric
address. Guarded by
[`phase2-qemu-vm/tests/test-ssh-refuses-without-a-hostfwd.sh`](../../phase2-qemu-vm/tests/test-ssh-refuses-without-a-hostfwd.sh),
whose control is that **user-mode networking must still get through** — an `ssh` that refused
everything would satisfy every other assertion and be worse than the hang it replaced.

### And the evidence was unobservable, which is why the first finding survived

`edge.toml`'s `runcmd` writes `EDGE-BEGIN` and `EDGE-PING-BY-NAME OK|FAIL` to `/dev/console` —
the lab's success signature. After the run, `qemu.log` was **empty** and the console was a
unix socket with nothing attached, so every one of those lines was written into a socket with
no reader and lost. There was no way to find out what `edge` had done.

QEMU's chardev takes a `logfile=` alongside the socket, so `lab-vm.sh` now passes one: the
socket stays exactly as interactive as it was, and the bytes also land in
`<vm-dir>/console.log`. A lab whose claim is a console marker needs the console to survive
past the moment nobody was watching.

### One more, reported rather than fixed

`down` returned 0 and `edge` was **still running** — on a tap the fabric had just deleted. VMs
persisting across a teardown is deliberate (the disk is expensive state), but a machine left
with its network yanked and nobody told is the **STRANDED** rung on this repo's own ladder,
and the difference between stranded and merely stopped is entirely whether the operator was
told. `micro-cloud.sh down` now names any still-running VM before the fabric step, and prints
the `stop` command for each. It does not stop them: that is the operator's call, and a
teardown that starts reaping VMs is one you run once and then stop trusting.

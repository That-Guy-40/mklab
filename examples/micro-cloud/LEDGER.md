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

---

## L10-9 — the clean run: the capstone claim, observed

**Run 2026-08-19**, `sudo -E`, full spec after a reset. **57 s**, `down` rc=0, cluster and
both engine bridges unchanged.

### §15's third exit criterion, met

From `edge` — a full QEMU VM with systemd and 73 processes — to `api1`, a Firecracker
microVM booting a 128 MB ext4:

```text
$ hostname            -> edge
$ ip -4 addr          -> 10.71.0.103/24
$ getent hosts api1   -> 10.71.0.101     api1
$ ping -c2 api1       -> 2 packets transmitted, 2 received, 0% packet loss
```

Resolution and reachability asked **separately**, because `ping` answering proves both at
once and tells you nothing about which broke when it fails. Three leases, each against the
MAC derived from the instance's own name, `br-mc0` carrying `mc-api1 mc-api2 mc-edge`, and
`api1`'s own console agreeing from the inside: `dhcp rc=0`, `gw ping: OK`,
`resolv: search mc.lab nameserver 10.71.0.1`.

**Four of five instances up** — `api1`, `api2`, `edge`, `metrics` (rootless podman, as
`$SUDO_USER`, via the per-slot privilege drop).

### The fifth, and it was my spec that was wrong

```text
[error] instance 'db': unknown key 'lab' — 'up' would silently ignore it.
  known [[instance]] keys: name engine type image from_chroot from_tarball from_qcow2 …
```

`[[microvm]]`, `[[vm]]` and `[[service]]` all take a `lab` key. Phase 5's `[[instance]]` does
not — the lab name comes from `[lab]` — and I wrote one by analogy, exactly as `--json` was
written by analogy in [L10-7](#l10-7--the-second-privileged-run-green-and-three-defects-only-a-green-run-could-show).
**`lab-lxd.sh` was right and loud**, refusing the whole config rather than ignoring a key it
did not understand. It just refuses at the *end* of a bring-up, after four instances are
already running.

Guarded now, and with a stronger oracle than the flag check next door: phases 5 and 7 each
declare the key list they **validate against** as a shell constant, so
`test-spec-is-one-description.sh` compares the spec against the very string the driver uses.
Re-injecting `lab` into `[[instance]]` makes it fail by name. Scope is stated rather than
implied: phases 1, 2 and 4 declare no such constant — phase 4 accepted the same key without
complaint — so their blocks are not covered.

### Two defects in the matrix's own reporting

- **It measured three rows and said two.** The `2` was a literal in the verdict line, so a
  run that filled a live `edge` row printed it in the table and then under-reported the
  count. Now derived from the matrix, and it names the rows it measured.
- **A namespace id is only comparable within one kernel.** `edge` reported netns
  `4026531840` — identical to the host's — and that is *not* sharing: it is the initial-netns
  inode in **every** Linux kernel, and `edge` has its own. The table invited precisely the
  wrong conclusion. Rows with their own kernel are now marked, **derived** from boot_id
  differing rather than from a list, with the reason printed under the table.

### Still UNKNOWN, and it is structural

`api1`/`api2` cannot be probed from outside: a microVM's boundary is a hypervisor, so the
probe must execute *inside*, and the slice-1/3 rootfs has no exec channel at all — no ssh, no
agent, a console that only speaks outward. Closing that row means booting them on slice 5c's
vsock-agent rootfs and probing over vsock: a different **image**, not a different privilege.
That is now what the UNKNOWN line says.

---

## L10-10 — `db` finally spoke, and what it said was that the spine was decorative

**Run 2026-08-19** (the second clean run, with the `lab` key fixed). Same 58 s, same green
teardown, same four instances — and a *different* error from phase 5:

```text
[error] instance 'db': specify exactly one of image | from_chroot | from_tarball | from_qcow2 (got 0)
```

The first refusal had hidden the second. Fixing the unknown key let the driver get one gate
further, and the next gate asked the question that mattered: **where does `db`'s filesystem
come from?** The spec had no answer, and following that through turned up something larger.

### The chroot was built by every run and consumed by nothing

§2's thesis is that *a chroot is the universal userspace every compute type imports*. In this
spec it was a `[[chroot]]` block that got debootstrapped on every bring-up and then ignored:
the microVMs booted pre-staged images, `edge` came from a cloud image, `metrics` from a
registry, and `db` from nothing at all. The spine was **decorative**, and nothing said so
because a decorative step still exits 0.

Giving `db` the chroot exposed why the block could not stay:

* a chroot is a **build input**, not a running instance. What instances consume are its
  *exports* — `export-rootfs` for the microVMs, `export-tarball` for `db` — and the control
  plane has no slot that emits an export step.
* so a bring-up needed those exports to exist **before** the instance steps, while the block
  was created by the *first* of those same steps. Circular, and `db` sat on the circle.
* and it is not incidental plumbing: phase 5 **refuses** a root-built chroot read directly,
  because `sudo lab-chroot create` leaves mode-600 files (`/etc/shadow`) an unprivileged run
  cannot read — and it names `export-tarball` as the route. Another driver being right and
  loud about a thing the spec had glossed.

Worse, [`RUNBOOK-micro-cloud.md`](RUNBOOK-micro-cloud.md) step 0 *also* created the chroot, so
two documented paths built the same tree and `up` would have refused the second one. That
only stayed invisible because every run so far had destroyed the chroot first.

### The fix, and it is the better lab

`micro-cloud.toml` now declares the five things that **run**. Step 0 builds the spine and
**both** exports, and `db` imports the tarball.

**And here the claim has to be trimmed to what is true.** The sentence this entry first
carried was *"one debootstrapped tree becomes the microVMs' root filesystem AND the LXD
container's image, so two compute types demonstrably share one userspace."* Checked before
believing it: `examples/micro-cloud/images/api1.ext4` is a minimal BusyBox tree from slices
1/3 — it still has `mc-probe.sh` in it from the clone-entropy work — **not** the Debian
chroot. So the shared-userspace claim is:

| route | status |
|---|---|
| chroot → `export-tarball` → `db` | **real as of this change**, and the reason `db` can come up at all |
| chroot → `export-rootfs` → `api1`/`api2` | **documented in step 0, not exercised here.** The images in place predate it, and swapping them is not free: a Debian minbase boots systemd and prints none of the `SLICE3-*` console markers the microVM half is currently proved by |

So §2 is *half* demonstrated, and saying "two compute types share one userspace" would have
been asserting the interesting half from the easy one.

§9.1's layout line said *"ONE spec: chroot + microvms + vm + containers"*. It is corrected in
the plan, with the reason: **a `[[chroot]]` block was the tidier document and the weaker
demonstration.**

### What this run does not yet show

`db` has still never come up — the tarball did not exist when it ran. The next run is the
first that can produce all five, and it is also the first where the chroot is load-bearing:
if step 0's export is missing, `db` fails and says so, which is the honest coupling.

---

## L10-11 — the spine imported perfectly and could not run: `minbase` has no init

**Run 2026-08-19.** Step 0 worked exactly as designed — chroot built in 24 s, `export-tarball`
wrote an 89 MB archive owned by the invoking user — and phase 5 got two gates further than
last time. The image **imported**. Then:

```text
[info] extracting Phase 1 tarball into staging rootfs/
[info] rebundling → unified tarball
[info] imported: lab-micro-cloud-db-img
[info] launching container 'db' as lab-micro-cloud-db
[error] Failed to run: incusd forklxc lab-micro-cloud-db … : exit status 1
```

The whole export route — the thing the previous entry built — is **correct**. The tree it
delivered is the wrong tree:

```console
$ ls -l /var/chroots/micro-cloud-base/sbin/init
ls: cannot access …: No such file or directory
$ ls /var/chroots/micro-cloud-base/lib/systemd/systemd
ls: cannot access …: No such file or directory
```

Debian `--variant minbase` has **no init system at all**, and LXC's job is to exec
`/sbin/init`.

### This is where §2's "universal" has an edge, and the edge is instructive

| consumer | needs | `minbase` |
|---|---|---|
| Firecracker microVM | *some* `/sbin/init`; slice 1 uses a shell script | ✅ fine |
| OCI image (podman) | a command, not an init | ✅ fine |
| **LXD/Incus system container** | a **real init**, exec'd by LXC | ❌ **fatal** |

And it lands precisely on the instance whose lesson it is: [§9.2](../../MICRO_CLOUD_LAB_PLAN.md#92-the-instances)
calls `db` *"the system-container case: a stateful pet **with its own init**"*. The spec had
been asking one tree to serve three consumers while building the one variant that cannot
serve the third.

**The import succeeding is what makes this worth recording.** Every mechanism in the chain
worked — tar as root, chown to the user, extract, rebundle, import — and a check on any of
them would have reported success. The outcome, *can this thing be a system container*, is a
different question, and only launching it asked.

Fixed with `--include systemd-sysv` in step 0, and it is a real cost rather than a free win:
a microVM rootfs exported from this tree now carries systemd, which boots slower and wants
more than the 256 MB the spec gives `api1`. **A universal userspace is not free of its
consumers' requirements** — that sentence is the finding, and it took a launch failure to
earn it.

### Everything else in the run repeated cleanly

`edge` at `10.71.0.103` with ssh, the capstone probes green, `down` rc=0, and the cluster plus
both engine bridges unchanged — 65 s end to end.

---

## L10-12 — the harness lived in /tmp for five runs, and a reboot took it

**2026-08-19.** The script that performs the privileged run — reset, step 0, `up`, the
readiness waits, the capstone probes, the isolation matrix, `down`, and the before/after
comparison of the host CNI's state — existed only in a session scratch directory. The machine
rebooted between runs and it was gone. The artifacts it had produced survived
(`/var/chroots/micro-cloud-base`, the images, the tarball); the procedure that produced them
did not.

**This is the second time this lab has lost a privileged harness to a temp directory.**
`fabric.sh` was written and exercised in a `/tmp` scratchpad on 2026-08-02, and PR #129 landed
the 307-line appendix *about* it without landing **it** — §14 said the slice was done, §9.1
listed the file, and both catalog gates were green, *because neither checker has an opinion
about a tool that does not exist*. It was recovered on 2026-08-04 by replaying one Write and
eleven Edits out of a session transcript. Its header still opens with **"THIS FILE WAS ALMOST
LOST, WHICH IS THE FIRST THING TO KNOW ABOUT IT."**

The lesson was written down and then not applied to the next thing of the same kind. What
made it easy to miss is that the second one never felt like an artifact: it was "the command I
run to test the lab", regenerated a little each time, and it accumulated — five runs' worth of
ordering constraints, every one of them bought by a failed run:

* the privilege boundary follows the resource, so the phase steps drop to `$SUDO_USER`
  ([L10-6](#l10-6--the-first-privileged-run-the-fabric-was-right-the-orchestrator-was-wrong));
* readiness is not what `up` returns on, so everything that reads state waits first
  ([L10-2](#l10-2--up-orders-invocations-and-readiness-is-a-different-question));
* the capstone is asked from `edge` at its **leased** address, never through `lab-vm.sh ssh`
  ([L10-8](#l10-8--the-full-spec-the-chroot-and-the-vm-both-built-and-the-capstone-probe-could-never-have-worked));
* step 0 builds the spine and its exports because the runtime spec cannot
  ([L10-10](#l10-10--db-finally-spoke-and-what-it-said-was-that-the-spine-was-decorative));
* and the chroot needs `--include systemd-sysv` or `db` cannot launch
  ([L10-11](#l10-11--the-spine-imported-perfectly-and-could-not-run-minbase-has-no-init)).

Every one of those is a thing a reader would otherwise have to rediscover by failing the same
way. Losing the file loses the *reasons*, which are worth more than the commands.

It is now [`run-privileged-demo.sh`](run-privileged-demo.sh), in the repo, linked from
[`MANUAL_TESTING.md`](MANUAL_TESTING.md) and [`RUNBOOK-micro-cloud.md`](RUNBOOK-micro-cloud.md)
so `link_check.py` will not let it become an orphan, and shellcheck'd in CI. Two behavioural
changes came with the move, both because a repo file has different obligations than a scratch
one:

- **destroying is opt-in.** `--reset` is a flag now, not the first phase. A script anyone can
  run should not delete a chroot because it was invoked.
- **it refuses to mislead about the chroot it finds.** If `/var/chroots/micro-cloud-base`
  exists without `/sbin/init` — the tree every run before L10-11 built — it says so and names
  `--reset`, rather than proceeding to a `forklxc` failure whose cause is three files away.

---

## L10-13 — all five up, and two defects inside the green run

**Run 2026-08-19**, `--reset`, from the harness now in the repo. **`up` rc=0** — the first
clean full bring-up — `down` rc=0, 73 s, cluster and both engine bridges unchanged.

```text
api1     "running"          api2     "running"
edge     running            (10.71.0.103, ssh answered)
db       lab-micro-cloud-db  default  container  Running     <-- first time
metrics  Up 8 seconds        alpine:latest
br-mc0 members: mc-api1 mc-api2 mc-edge veth756ac590         <-- db's veth, on the fabric
```

The capstone held again: from `edge`, `getent hosts api1` → `10.71.0.101`, `getent hosts
api2` → `10.71.0.102`, `ping api1` → **0% loss**.

### 1. `db` is on the L2 and invisible on the network

`getent db` returned nothing and `ping db` said *"Name or service not known"* — while `db`
was Running with a veth on `br-mc0`. It never appears in the lease file.

`systemd-networkd` ships **with** systemd but is **not enabled**, and a minbase tree has no
`dhclient`, no `ifupdown`, no `udhcpc`. So `db` came up, got its interface, and **nothing
ever asked for an address.**

This is [L10-11](#l10-11--the-spine-imported-perfectly-and-could-not-run-minbase-has-no-init)
happening one layer up, and the pair of them is the real shape of §2's cost:

| consumer | init | network config |
|---|---|---|
| Firecracker microVM | supplies its own | its init DHCPs itself |
| OCI container | not needed | podman supplies the namespace |
| **LXD system container** | **needs one** | **needs one** |

Two rounds, same lesson: **the shared userspace is missing whatever the newest consumer
assumes.** The microVM and the container each brought their own answer; the system container
expects the image to have brought it. Fixed with three `--post-command` lines that enable
`systemd-networkd` and write a `DHCP=ipv4` unit.

### 2. A false UNKNOWN, and it was mine — for the third time

The matrix reported

> `db (lxd)` — no running LXD instance named 'db' in lab micro-cloud

while `lab-lxd.sh list` showed it **`Running`** three lines earlier **in the same log**. The
probe was `grep -qE '\bdb\b.*(RUNNING|running)'`. Incus prints `Running` — a third
capitalisation the alternation did not enumerate.

Third time in this lab, same shape every time: **a format guessed at rather than asked
about.** `inspect --json` (phase 7 has no such flag), `lab =` in `[[instance]]` (phase 5 has
no such key), and now a status string spelled two of three ways. Each looked obviously right
because a sibling did it that way.

The fix is `grep -qi`, and the distinction matters more than the character: *enumerating
spellings is the bug*. Adding `Running` to the list would have fixed this run and left the
class. Case-folding removes the class. Verified against all three spellings plus `Stopped`
as the negative control.

### What is left

`api1`/`api2` remain structurally unmeasurable by the matrix — their rootfs has no exec
channel, and closing that means slice 5c's vsock-agent image rather than more privilege.
That is the only row of §9.3 whose absence is not a to-do.

---

## L10-14 — two errors in the fix for L10-13, found by checking instead of running

The fix committed for [L10-13](#l10-13--all-five-up-and-two-defects-inside-the-green-run) was
three `--post-command` lines. Before spending a run on it, each was checked against the thing
it depends on. **Two of the three were wrong**, and neither would have announced itself as a
mistake — `db` would simply have had no address again, for a different reason.

### 1. `systemctl enable` inside a chroot is not a reliable way to enable anything

There is no running systemd for it to talk to, and behaviour varies by version — some refuse
with *"Running in chroot, ignoring request"*. The command might have worked, and if it had
not, the failure would have been silent: a post-command that prints a notice and exits 0.

Replaced with the symlink `enable` would have created. It is identical on every version, and
— the part that matters — **its effect is checkable with `ls`**, which is why the run script
can now warn about a tree that lacks it before `up` rather than after `db` fails.

### 2. `db` would have registered in DNS under the wrong name

dnsmasq does serve DNS for names it learns from DHCP — `--domain --expand-hosts` are in the
fabric's argv. But **LXD sets a container's hostname to the instance name**, which here is
`lab-micro-cloud-db`. So `db` would have got an address, registered as
`lab-micro-cloud-db.mc.lab`, and `getent db` from `edge` would have failed exactly as before
— with the DHCP fix working perfectly.

Nor is there a fallback: `fabric.sh tap` reserves a lease against a MAC for instances that
take a **tap**, and `db` takes an LXD veth, so it has no reservation and no name from that
path either. The name has to travel in the request, which is `[DHCPv4] Hostname=db`.

### Why this entry exists at all

The three defects before it were each *"a format guessed at rather than asked about"*, and
each cost a privileged run to discover. These two were the same shape — an assumption about
someone else's behaviour, written because it looked obviously right — and they cost a few
minutes of reading instead, because this time the question was asked before the run rather
than after it.

That is the only difference. **The mistake rate did not change; the point at which it was
caught did.**

---

## L10-15 — the matrix reaches 4 of 5, and `db`'s missing address stops being guessed at

**Run 2026-08-19**, `--reset`, with the L10-14 corrections. `up` rc=0, `down` rc=0, 74 s,
cluster and both engine bridges unchanged. The chroot was verified to carry both fixes before
the run rather than after: `post_command[4]` shows the `Hostname=db` unit being written, and
the tree has the `systemd-networkd` symlink and the `.network` file with the right content.

### §9.3's matrix is now 4 of 5

```text
  ROW                            PIDS PID1       BOOT_ID   NETNS
  host                            979 systemd    07ff095c  4026531840
  metrics (podman, rootless)        4 sleep      07ff095c  4026534179
  db (lxd system container)         7 systemd    d6eaf799  4026535033*
  edge (qemu vm, full stack)       74 systemd    34c39bca  4026531840*
```

`db` measured for the first time, and the row earns its place immediately: **7 processes with
`systemd` as PID 1** is the system-container case stated in one line — a container that boots
an init, beside a rootless container whose PID 1 is `sleep`, beside a VM with its own kernel.
The case-folding fix from [L10-13](#l10-13--all-five-up-and-two-defects-inside-the-green-run)
is what let it be seen at all.

Only `api1`/`api2` remain, and their absence is structural rather than a to-do.

### And `db` STILL has no address — which is now the interesting part

`getent db` empty, `ping db` unresolvable, no lease. But this run establishes what the last
two could not:

* the image is right — the symlink and the `.network` unit are present and correct, checked
  on disk after the run;
* `systemd` **is** PID 1 inside the container, so the init half works;
* `lab-lxd.sh exec` **works**, because the matrix probed through it.

Every fact needed to explain this is one command away *inside* a container that was running
while the script had a shell into it. Two rounds were spent diagnosing this by inference —
first *"it has no init"*, then *"it has no DHCP client"* — and each guess cost a privileged
run to test.

So the harness now asks: `run-privileged-demo.sh` gained a step that queries `db` directly
for its interfaces, addresses, hostname, whether `systemd-networkd` is active and enabled,
what `networkctl` sees, the contents of `/etc/systemd/network/`, and the unit's journal.

It prints those **whether or not `db` has an address**, deliberately. A block that appears
only on failure is one nobody can read, because nobody has seen what healthy looks like.

**The lesson is not about DHCP.** It is that a running instance with a working exec channel
is the cheapest oracle in the lab, and it went unasked for two rounds while its behaviour was
inferred from the image instead.

### Addendum 2 — CAUGHT, THEN EXPLAINED, THEN FIXED (2026-08-19)

Redirecting instead of piping worked on its first use. The intermittent is
**`test-clone-entropy.sh`**:

```text
FAIL: clone b2 of bsrc has a different boot_id from b1 — VMGenID reseeds the CRNG and
nothing else, so if boot_id has started changing, something re-personalises the guest now
and every document here saying otherwise is wrong
```

**§5.8 is not wrong. The test was mis-reading a truncated line**, and the mechanism is one
this repo has a section about: *a regex standing in for a question.*

The record extractor ended `[0-9a-f-]*`, which is **unanchored**, so a console line cut
part-way through the boot_id still matched and `-o` handed back the truncated prefix as
though it were the value. Measured directly, no VM required:

```console
$ complete   → 3dd1b6c8-fe90-4ced-a0e8-dded4c31a5b2
$ truncated  → 3dd1b6c8-fe90-4ced-a0e8-dded          # matches; a strict PREFIX of the above
```

A resumed clone's first console output **is** such a fragment — the remainder of a line the
guest was mid-`echo` through when the snapshot froze it. That is exactly the case the
extractor's own comment claimed to step over (*"half a line is not a read"*), and it did step
over it **for the index and nothing else**: `$2` is a complete field early in the line, so a
record truncated inside the boot_id still yields a perfectly good index. Which is why
`resume_index` passed and the comparison two assertions later failed — the detail that made
the obvious explanation (a clone booting instead of resuming) impossible, and left the thing
unexplained for four days.

Everything else follows: rare, because the pause has to land inside the last field
specifically; only under a full suite, because load shifts where it lands; and phrased as an
accusation against §5.8, because the assertion was written to be loud about the thing it
would mean *if the input were trustworthy*.

**Fixed** by anchoring the last field to a full UUID — `8-4-4-4-12` — so a partial one is not
a match and `-m1` steps to the next record that really is complete. All four extractors share
one pattern now.

**And the control that would have caught it** runs before anything boots: a two-line fixture
whose first record is truncated inside the boot_id, and the extractors must skip it and read
the second. Re-injecting the old pattern makes it fail by name (*"returned index '800',
expected 801"*). Verified both directions.

> The strong evidence here is the control reproducing the exact failure mode, not the absence
> of the failure afterwards. At ~2 occurrences in 10 suite runs, "it did not recur" would need
> a great many runs to mean anything, and would still be the weaker claim.

### Addendum — the suite flaked again, and I lost the message again### Addendum — the suite flaked again, and I lost the message again

While preparing this entry, one `run-all.sh` reported `14 passed, 6 skipped, 1 failed`; three
captured runs immediately after were clean. **The failing test's name was not recorded**,
because the run was piped into `grep '=== summary'` and the `FAIL:` line went with it.

[L10-5](#l10-5--the-intermittent-was-two-things-and-one-of-them-was-me) ends with the
instruction *"next occurrence, keep the full log, not the summary"*, written after exactly
this. I read that entry while writing this one and still piped the run.

The instruction was not the fix. Filtering at the point of running is what loses the
evidence, so the runs after it were written to files first and grepped second — which is what
the instruction should have said, and now does here: **redirect, then read; never pipe a run
whose failure you might need to explain.**

---

## L10-16 — asked the container, got the mechanism: networkd waits for udev, and there is no udev

**Run 2026-08-19.** `up` rc=0, `down` rc=0, 76 s. The diagnostic added in
[L10-15](#l10-15--the-matrix-reaches-4-of-5-and-dbs-missing-address-stops-being-guessed-at)
did its job on its first run: two rounds of inference replaced by seven lines of fact.

```text
    hostname:          badass-box-qmhu
    networkd active:   active
                       enabled
    .network files:    -rw-r--r-- 1 1000 1000 65 10-fabric.network
    networkd log:
      systemd-networkd[51]: lo: Link UP
      systemd-networkd[51]: lo: Gained carrier
      systemd-networkd[51]: Enumeration completed
      systemd-networkd[51]: vethce0469d8: Interface name change detected, renamed to eth0.
```

**The fix from L10-14 worked, and was not enough.** `systemd-networkd` was active, enabled,
and reading the right file. It handled `lo`, finished enumerating, watched `eth0` appear —
and stopped. Confirmed on disk afterwards: the tree has **no `systemd-udevd`**. Debian ships
udev as its own package; `systemd-sysv` does not pull it in.

> **systemd-networkd waits for udev to mark a link initialized before configuring it.**
> `lo` is exempt, which is exactly why the one interface it configured was the one that
> proves nothing.

Two more facts arrived in the same output, each of which would have caused the *next* failure:

* **`hostname: badass-box-qmhu`** — not `db`, and not the LXD instance name either.
  `lab-chroot.sh` bakes a **random** hostname into every tree it builds. `dhclient` sends
  `/etc/hostname` by default and dnsmasq registers what it is told, so `db` would have come up
  with an address and resolved under a name nobody could guess. `send host-name "db";` puts
  the name in the request instead.
* **`ip: not found`** — no iproute2, so two of the probes returned nothing. A diagnostic gap
  found by the diagnostic, which is the cheapest possible place to find one.

### The fix chosen, and why it is not the obvious one

`ifupdown` + `isc-dhcp-client`, not networkd. networkd costs no packages and is the modern
answer, and it is the wrong answer *here* for a reason that is a property of the environment
rather than of the tool: a container has no udev. `ifupdown` is a boot-time script with no
such dependency, which is why it remains the conventional path inside one.

That is also the rule this whole sequence keeps producing, now in its fourth form: **the
shared userspace is missing whatever the newest consumer assumes**, and what the system
container assumes is an entire boot-time network stack — an init (L10-11), a configuration
(L10-13), a client that does not need udev (here), and a name to send (here).

### What this run changes about how the lab is debugged

Nothing about the previous two rounds was unknowable. `db` was running, `lab-lxd.sh exec`
worked, and every one of those seven lines was one command away the whole time. The
difference is that the harness now asks by default and prints the answers whether or not
anything is wrong — so the next person does not have to think of the question while a lab is
still up.

---

## L10-17 — ifupdown is installed, configured, enabled — and `eth0` still has no address

**Run 2026-08-19.** `up` rc=0, `down` rc=0, 77 s, cluster unchanged. `db` Running. Still no
lease, still `getent db` empty.

What the container reported this time is different from last time, and narrower:

```text
    interfaces:        lo
                       eth0@if114          <-- the interface EXISTS
    addresses:         lo 127.0.0.1/8      <-- and only lo has one
    networkd active:   inactive / disabled <-- correct: we migrated off it
    .network files:    (none)              <-- correct
```

Verified on disk afterwards: `ifupdown` and `isc-dhcp-client` installed, `/etc/network/interfaces`
correct, `send host-name "db";` in `dhclient.conf`, and `networking.service` symlinked into
`multi-user.target.wants`. Every ingredient is present and `eth0` is unconfigured.

### Two of my own checks were wrong, in the same way, in one session

* **`-e` on a symlink into the container's root.** Checking the enable symlink from the host,
  `[[ -e …/multi-user.target.wants/networking.service ]]` said ABSENT. It is not: `-e`
  **follows** the link, and an absolute symlink to `/lib/systemd/system/networking.service`
  dangles when resolved against the *host's* filesystem. `ls` showed it immediately. The run
  script's own pre-flight uses `-L` and was right all along; the ad-hoc check I typed was not.
* **The diagnostic was still aimed at systemd-networkd** after the lab migrated to ifupdown.
  So a run whose entire question was *"did ifupdown bring eth0 up"* answered *"networkd is
  inactive"* — true, and beside the point. **A diagnostic aimed at the previous design
  confirms the previous design is gone**, which reads like information and is not.

Both are the same shape as the defects they were meant to catch: asking a question whose
answer cannot distinguish the cases you care about.

### What the next run asks instead

`networking.service` active/enabled, the interfaces file as the container sees it, whether
`dhclient` is on PATH there, `/var/lib/dhcp/` leases, `journalctl -u networking`, and — the
decisive one — **`ifup eth0` run by hand with its output and the resulting address**. That
last one collapses the remaining space: either it works, and the unit did not run; or it
fails, and says why.

`systemd-networkd` is still probed, expecting `inactive`, because a half-migration with both
managers present would look exactly like this too.

## L10-18 — `networking.service` won the race to `eth0` and lost: an ordering bug, not a config bug

**Run 2026-08-19 (second).** `up` rc=0, `down` rc=0, 81 s, cluster unchanged, all five Running.
The re-aimed diagnostic (L10-17) asked the right question and the journal answered it outright:

```text
    networking.service:  failed / enabled
    networking log:
      ifup[74]: Failed to get interface index: No such device
      ifup[55]: ifup: failed to bring up eth0
      systemd[1]: networking.service: Failed with result 'exit-code'
    ifup by hand:
      DHCPACK of 10.71.0.104 from 10.71.0.1
      eth0 inet 10.71.0.104/24 ... rc=0
```

The unit ran. It ran **before `eth0` existed in the container's netns**, failed on a device that
was not there yet, and — being `Type=oneshot` — never looked again. Seconds later the same
command, by hand, got a lease on the first DISCOVER.

**This is why five runs of checking ingredients found nothing.** Every ingredient *was* present.
The defect was never in the set of facts, it was in their **order**, and no amount of asking
"is X installed / configured / enabled" can see an ordering bug. Three rounds of this lab's
`db` problem were diagnosed by inspecting state; the one that solved it read a **log**, which
is the only artifact that carries time.

### The tree pays for having no udev twice, in opposite directions

| manager | what it does when the link is not there yet | outcome here |
|---|---|---|
| **systemd-networkd** (L10-16) | waits for udev to mark the link initialized | waits **forever** — there is no udev to send the event |
| **ifupdown** (L10-17) | does not wait at all; runs at boot and exits | fails **immediately** — `No such device` |

Neither is wrong; both are correct designs for a machine that *has* udev. `minbase` has none
(Debian ships `udev` as its own package and `systemd-sysv` does not pull it), so the wait has to
be supplied by hand. The fix is a drop-in:

```ini
[Service]
TimeoutStartSec=30
ExecStartPre=/usr/local/sbin/wait-for-eth0
```

```sh
until [ -e /sys/class/net/eth0 ]; do sleep 0.2; done
```

`TimeoutStartSec` is what bounds it — systemd kills the `ExecStartPre` at 30 s, so a device that
genuinely never appears still fails loudly instead of hanging the boot. No variables and no
quotes in either file, which is deliberate: the content travels through `--post-command` → the
outer shell → `sh -c` inside the chroot, and each layer is one more chance to eat a `$` or a
`'`. Both files were rendered through that exact pipeline and diffed before being trusted.

**Controls, run rather than reasoned** — device present → returns 0 immediately; device absent →
still blocking at the timeout (rc 124, so it really does wait); device created **late** inside an
`unshare -rmn` netns → blocked exactly 2 s and returned 0. The third needs `mount -t sysfs sys
/sys` inside the namespace, or `/sys/class/net` keeps showing the *host's* devices and the
control silently proves nothing.

### The diagnostic healed the subject it was measuring

The `ifup by hand` probe that produced the answer above also **brought `eth0` up**. Step 5 ran
two seconds later and reported the capstone in full — `getent db → 10.71.0.104`, `ping db` 0%
loss. That capstone row is not a result. It is the diagnostic's own side effect, read back.

Nothing was wrong with running `ifup` — it was the decisive test and it decided. The mistake was
running it **upstream of an observation**, in a script whose next step observes. So 4b is now
read-only, and the thing that made the confusion possible is gone from the report: `DB_SELFCONF`
is sampled *before* any probe runs and printed on its own summary line, so **"db reached the
fabric" and "db reached the fabric by itself" can no longer be read off the same line.**

A probe that repairs its subject is a special case of the liar in the root `CLAUDE.md`: not a
false success, but a **manufactured** one — and it is worse in one respect, because everything it
prints is true.

> **Superseded in part by L10-18a:** the drop-in below was the right shape and the wrong
> **view**. The read-only 4b and the `DB_SELFCONF` line stand.

## L10-18a — the wait was satisfied and `ifup` still could not find the device: two views, one name

**Run 2026-08-20, `reset=1`.** `up` rc=0, `down` rc=0, 78 s, cluster unchanged. The new summary
line did its job on its first outing:

```text
db self-configured=no   <- 'no' means db's capstone row, if any, was not earned
```

The drop-in was verifiably in place — the diagnostic `cat`s it out of the *running* container —
and the failure was byte-identical to L10-18's. The delivery chain was then checked end to end
from the exported image, with no privileged run needed:

```console
$ tar tzvf images/micro-cloud-base.tar.gz | grep wait-for-eth0
-rwxr-xr-x 0/0  213  ./usr/local/sbin/wait-for-eth0
-rw-r--r-- 0/0   72  ./etc/systemd/system/networking.service.d/wait-for-eth0.conf
```

Both present, the helper executable, the drop-in exactly 72 bytes — the length of its intended
content. Nothing was lost between `--post-command`, the chroot, the tarball and the image.

### The unit's own status names the contradiction

`networking.service: Main process exited, code=exited, status=1/FAILURE` — **the main process**,
i.e. `ifup`. systemd does not run `ExecStart` if an `ExecStartPre` fails. So `ExecStartPre`
**returned 0**: the wait was *satisfied*, and the next command could not find the device.

Both are true at once because they are **not the same view**:

| view | whose netns it answers for |
|---|---|
| `/sys/class/net/…` | the netns of the **sysfs mount**, fixed when `/sys` was mounted |
| `ip link` / `if_nametoindex` (netlink) | the **caller's own** netns |

Shown locally in a fresh netns whose `/sys` is still the host's — no container, no privilege:

```console
    ip link show docker0   -> not present     # netlink: this netns has no docker0
    /sys/class/net/docker0 -> VISIBLE         # sysfs: still answering for the host
    OLD helper (sysfs)   rc=0    <- returned at once: FOOLED
    NEW helper (netlink) rc=124  <- still waiting: agrees with ifup
```

**This is the root `CLAUDE.md`'s opening table with my own name on it.** The cheap check is not
a weaker version of the real one; it is a *different question that happens to be easier to ask*,
and it can be true while the thing it stands for is false. "A `/sys/class/net` entry exists" was
a stand-in for "the name resolves in the namespace `ifup` will ask about", and the stand-in was
satisfied by a namespace nobody was in. Three of L10-18's controls passed — the helper really
does block, really does return, really does wait exactly as long as needed. **They measured the
helper against the wrong seam, so they proved everything except the thing that mattered.**

The fix: wait on `ip link show eth0`, the same lookup the consumer makes. This lab already has
the rule in another shape — the delivery test that used `curl --data-binary` and proved the sink
rather than the node, whose `busybox wget` truncates DER. *Drive the client the machine actually
has.*

### And it added a witness, because "never loaded" and "loaded and satisfied" looked identical

The helper now echoes two lines that land in the unit's journal. Without them the run above
could not distinguish *the drop-in was never read* from *it ran and was satisfied* — the
`systemctl show ExecStartPre` probe added alongside answers the first directly. A silent
success and a silent absence present the same way from outside; **`UNKNOWN` was the honest
verdict for that run, and it took two probes to retire it.**

### The no-quotes rule earned itself in the same edit

The rewritten helper's comment first contained a quoted phrase — inside a `printf "…"` that
crosses `--post-command`, the outer shell and an in-chroot `sh -c`. It would have terminated the
format string and truncated the file mid-sentence. It was caught by **rendering the
post-command through the real pipeline and reading the result**, not by inspecting it: the
truncation is invisible in the source line and obvious in the output.

> **Corrected by L10-19:** the *divergence* above is real and reproducible, but this entry
> asserted it was the **cause** of L10-18's failure. It is not established. See L10-19.

## L10-19 — the capstone, earned: five instances, one L2, `db` self-configured — and two corrections

**Run 2026-08-20T02:38Z, `reset=1`.** `up` rc=0, `down` rc=0, 79 s, cluster unchanged.

```text
    getent api1  -> 10.71.0.101     api1
    getent api2  -> 10.71.0.102     api2
    getent db    -> 10.71.0.104     db
    ping api1    -> 2 received, 0% packet loss
    ping db      -> 2 received, 0% packet loss
```

`db`'s journal shows the whole sequence for the first time — the witness, then DHCP:

```text
wait-for-eth0[55]: wait-for-eth0: waiting for eth0 on netlink
systemd[1]:        Starting networking.service - Raise network interfaces...
wait-for-eth0[55]: wait-for-eth0: eth0 is visible on netlink
dhclient[85]:      DHCPDISCOVER on eth0 ... interval 4
dhclient[85]:      DHCPOFFER of 10.71.0.104 from 10.71.0.1
dhclient[85]:      DHCPACK   of 10.71.0.104 from 10.71.0.1
dhclient[85]:      bound to 10.71.0.104 -- renewal in 19190 seconds
systemd[1]:        Finished networking.service - Raise network interfaces.
```

**§9.3's capstone is now met by all five instances**, and it is met with a **read-only** 4b —
nothing in the run touched `db`'s network before `edge` resolved it. That distinction is the
whole reason L10-18 exists.

### Correction 1 — the guard against a manufactured success manufactured a failure

The summary line said **`db self-configured=no`**. It is wrong, and the journal above says why:
`DB_SELFCONF` sampled once at **t+46 s**, while the DHCPDISCOVER was still in flight
(`interval 4`); the DHCPACK landed **four seconds later**. The `systemctl is-active` probe in
the same block printed `activating`, which was the tell, and I read past it.

**The same root cause as the bug it was built to prevent: sampling at the wrong moment relative
to the event.** L10-18's probe ran *after* an effect it caused, and reported it as observation;
this one ran *before* an effect it was waiting for, and reported its absence as fact. A
single-shot sample of an asynchronous thing is a coin toss either way. It now polls to a bound
and **prints how long it took** — `db` needing 4 s and `db` needing 40 s are not the same lab,
and a duration is the one number a boolean cannot carry.

### Correction 2 — L10-18a's diagnosis is NOT established, and this run is the evidence against it

L10-18a claimed the sysfs helper was satisfied by a *different namespace's* view. Two facts here
undercut it:

* **`systemctl show` reports `start_time` and `stop_time` in the same second.** The wait did not
  visibly block, so this run **did not exercise it**. A helper that never had to wait cannot be
  credited with the outcome.
* **This container's two views AGREE.** The new side-by-side probe prints
  `netlink sees: lo eth0@if186` and `sysfs sees: eth0 lo` — the *container's* devices, not the
  host's (`docker0`, `cali…`, `vxlan.calico`). So sysfs **is** namespaced here, and the
  divergence I demonstrated locally, while entirely real, is not shown to be what happened.

What is actually in hand: the sysfs helper, one failing run; the netlink helper, one passing
run. **n = 1 each, against a defect that is timing-dependent by construction.** The netlink
version is still the right one to keep — it asks the question the consumer asks, and that stands
on its own — but *"the netlink change fixed it"* is a claim I have not earned.

So the witness now logs **one line per poll**. The journal timestamps then say how long the wait
blocked, and **no poll lines at all means eth0 was already there** — which is exactly the
difference between a fix and a race that happened to fall the right way. Controlled both
directions locally: a device created late produced five `not visible yet` lines; a device already
present produced none.

**The pattern across L10-18, L10-18a and L10-19 is one pattern.** Every wrong answer came from
measuring at a moment that was not the moment in question — a probe upstream of its own
observation, a sample taken before the event, a control aimed at a seam the consumer does not
use. The subject was never mysterious. The clock was.

## L10-20 — the microVM row was never structural; it was waiting for a channel that already existed

**2026-08-20.** §9.3's matrix has said the same thing for weeks: `api1`/`api2` are
**structurally** unmeasurable, because a microVM's boundary is a hypervisor, the probe has to
run *inside*, and slice 3's rootfs has no exec channel at all. Every clause of that was true,
and the conclusion was still wrong — **slice 5c had built the channel on 2026-08-07.** vsock
needs no bridge, no lease and no root. What it lacked was not access but a *verb*.

```text
  ROW                                PIDS PID1       BOOT_ID   NETNS       DMESG    /dev/kvm UID
  host                                921 systemd    07ff095c  4026531840  refused  open    1000
  metrics (podman, rootless)            4 sleep      07ff095c  4026538850  refused  closed  0
  api (firecracker microvm, vsock)     59 init       7ff31aa1  4026531840* readable closed  0
```

Measured **unprivileged, with no fabric and no root**.

### Why the agent runs commands instead of answering seven questions

The obvious design was to teach the agent the matrix's seven probes and have it reply with
values. It is the wrong one, and the reason is the matrix's entire basis: **one implementation
of the probes, run in every context — the runner changes, the question does not.** Answering in
C would have made this the only row computed by different code, so a row that differed from the
container's could no longer distinguish *the boundary differs* from *that C is wrong*. That is
the confusion §9.3 exists to remove, so the agent gained `EXEC <cmd>` and the guest runs the
same shell commands every other row runs.

This **reverses** a decision `vsock-agent.c` stated in its own header — *"deliberately not a
shell"* — so the header now records the reversal and what it costs: the image carries a remote
shell reachable over vsock. Not an escalation (vsock is host-to-guest, unrouted, and the host
already owns the guest's memory, disk and CPU), but a surface, and it lives only in the image
built to *be* probed. `PING` keeps its structured reply, so slice 5c's own tests are untouched —
verified by running them.

### What the row actually shows, which is not what the container row shows

`metrics` reads the **host's** `boot_id` through a namespaced `/proc`: its isolation is a *view*
of one machine. The microVM reads a **different** one, because it *is* a different machine — and
that is now an assertion, not an observation for the reader. If this row ever reported the
host's `boot_id`, it would mean the answers came from the host: **the seam answering for the
wrong instance**, a class that has bitten this repo before. Controlled by pointing the runner at
the host and watching it fire, and the control-of-the-control by inverting it.

`dmesg` is the cell worth staring at. Host `refused`, container `refused`, microVM **`readable`**
— and that is not a leak. `kernel.dmesg_restrict` belongs to *this* kernel, and the guest is not
running it. It is reading **its own** ring buffer. The container, which shares the kernel, cannot.

### The row is booted by the test, exactly as the container row is

`metrics`'s row has never been the lab's running container either — it is a fresh one with the
same image and command. The microVM row follows that precedent, with two honest differences
recorded in the file: its image carries the agent, and it has **no tap**, because a hypervisor
boundary does not become a different boundary for having a NIC. The consequence is that the row
is measured on *ordinary* runs rather than only on the privileged one.

### A fourth instance of the same mistake, in the same session

`test-clone-entropy.sh` failed in the suite (`read #806 is absent from b3`) while passing twice
standalone. The comparison index was the highest FIRST index across the clones, demanded of all
three immediately. Two different things make it absent, and they need different answers:

| cause | evidence | answer |
|---|---|---|
| not yet written | low record count | **wait** for it |
| never written — garbled on the shared console | ~59 000 records and still absent | take the **next** index |

The counts settled it: with 59k records each, #806 was not "not yet". So the fix is a bounded
wait **and** a two-index forward search, and the failure now prints each clone's record count,
because *absent* cannot tell *not yet* from *never*.

**The forward search is deliberately narrow.** Scanning far ahead for any common index would
find the clones already diverged and report *no hazard* — turning the thing this file exists to
reproduce into a false negative. The control earned that reasoning rather than assuming it:
excluding `hi` entirely, the test takes `hi+1`, says so, and **still passes**, which is direct
evidence that ±2 stays inside §5.8's window.

That is now **four** in one session — L10-18's probe running before its own observation, L10-19's
`DB_SELFCONF` sampling before the DHCPACK, L10-19's helper measured against the wrong seam, and
this. Every one was a measurement taken at a moment, or through a view, that was not the one in
question.

## L10-21 — the driver could not configure the channel the lab is built on

**2026-08-20.** L10-20 closed §9.3's microVM row by booting a guest *the test* configured.
The row was honest about that, and it left an odd asymmetry standing: the lab **documents**
vsock, **tests** vsock, and **depends** on vsock — and `lab-fc.sh` could not emit the device.
Slice 5c's own test hand-writes a `config.json` and launches Firecracker directly, which is
why nobody noticed. **A channel the driver cannot configure is one every consumer
re-implements**, and each of them gets to rediscover the 108-byte `sockaddr_un` cap alone.

So `vsock` and `vsock_cid` are now first-class `[[microvm]]` keys, with `--vsock` /
`--vsock-cid`, and `micro-cloud.toml` declares them for `api1` and `api2`.

### The CID is derived, and it is not the identity

`vsock_cid_for_name` hashes the name exactly as `mac_for_name` does — a number written into
a file can outlive its subject; one computed from the name cannot — and `lab-fc.sh vsock-cid
<name>` prints it without booting, the read-only counterpart of `mac`. `0`, `1` and `2` are
refused as the kernel's own.

But the number is **advisory under Firecracker**, and the driver says so where it matters.
The host end is a userspace unix socket, so *which guest?* is answered by **which path you
opened**. Slice 5c already measured the consequence — three guests believing they were CID
43 at once, while QEMU refused the second at device creation. So `inspect` prints
`vsock_uds`, and prints its state in **three** outcomes: present; *missing while running*,
which is a fault; and *absent while stopped*, which is not. Collapsing those two would report
a healthy stopped instance as broken.

### Three defects, each found by running it rather than reading it

1. **A device with nothing behind it is worse than no device.** Declaring `vsock = true` for
   `api1` makes the socket exist while the slice-3 image has no agent — so `vsock_uds_state =
   "present"` and every probe times out, which reads as a *broken channel* rather than an
   *empty guest*. The privileged demo now injects the agent into the api images in place,
   with `debugfs`, idempotently.
2. **A stale socket blocked the next start.** `stop` left `vsock.sock` behind and the next
   `start` died on `Error binding to the host-side Unix socket: Address in use (os error 98)`
   — **the second time in this driver that a stale path has masqueraded as a vsock fault**
   (the first was the 108-byte cap). The API socket has had `rm -f` with that exact comment
   for months; I simply did not give the new socket the same treatment. Now unlinked at
   `start` *and* `stop`, and controlled by stopping and starting a guest that previously
   failed — it now boots and reports a **new** `boot_id`, which is what distinguishes a fresh
   boot from a stale connection to the old one.
3. **`inspect` died on an instance with no `config.json`.** The uds path was read with
   `sed … | head -1`; under this file's `set -e -o pipefail` a missing file makes `sed` exit
   1, `pipefail` hands the pipeline *sed's* status rather than `head's`, and the assignment
   inherits it. `inspect` printed two lines and stopped. **This repo's own standing rule —
   never pipe a command whose exit status is the gate — arriving from the other direction: I
   did not want a gate and the pipe created one.** Caught by an existing control that exists
   for exactly this shape (*"'inspect' refused a LEGAL instance name"*).

### And the parity test called a real flag missing

`test-cli-vs-config-parity.sh` builds each key's flag as `--$k`, which was correct only
because every key had been one word. `vsock_cid` was the first that was not, so the test
reported *"key with no CLI flag: vsock_cid"* while `--vsock-cid` sat in the parser. TOML keys
are snake_case and flags are kebab-case; encoding that convention beats special-casing the
key, since the next underscored key would fail identically and read as a real regression.

It gained the control it never had: an invented flag must be refused **with the message the
loop greps for**. Without it, a `flag_for()` returning garbage would report nothing missing —
the loop would simply never match — and the section would pass by looking for the wrong
string, which is precisely the bug it had just been fixed for.

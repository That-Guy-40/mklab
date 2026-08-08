# nested-calico-sandbox — a Calico we are allowed to break

A throwaway single-node **microk8s + Calico** inside a Phase-2 VM, so that beliefs about
the CNI can be tested by **experiment** instead of derived and hoped for.

Everything here is **unprivileged**: no root, no host networking, no nested KVM.

## The question it exists to make askable

[`examples/micro-cloud/fabric.sh`](../micro-cloud/fabric.sh) is safe to run beside a live
cluster because of two rules:

| | the rule | where it came from |
|---|---|---|
| **1** | first-found autodetection **excludes** interfaces matching `^br-.*` — hence the fabric's bridge is `br-mc0` | **read out of a v3.28.1 binary.** Never tested by naming a bridge the other way |
| **2** | an interface **with an IPv4 address** becomes a first-found candidate — hence the fabric's taps are addressless | **observed once, as an outage:** a lab's tap captured a live cluster's VXLAN tunnel endpoint ([plan F.6](../../MICRO_CLOUD_LAB_PLAN.md#f6-additive-was-not-safe--the-tap-captured-a-live-clusters-tunnel)) |

On the machine this repo lives on, falsifying either means breaking the Kubernetes the
machine is using. A cluster we may destroy removes that objection, and that is the entire
premise of this lab.

## What it measured

```
NCS-CALICO-VERSION=v3.29.3        NCS-AUTODETECTION-METHOD=first-found
NCS-BINDING-BEFORE=enp0s3
NCS-DECOYS-UP br-decoy(idx 8) mc-decoy(idx 9)
NCS-BINDING-AFTER-DECOYS=mc-decoy   after=15s     ← rule 2
NCS-CONTROL-DELETED=mc-decoy
NCS-BINDING-AFTER-CONTROL=enp0s3    after=15s     ← rule 1
NCS-EXCLUDED-DECOY-STILL-PRESENT=10.99.1.1/24
```

**Rule 2 is measured.** Two dummy interfaces, both addressed and up, differing *only in
name*. Calico migrated to one of them **on its own poll, with nothing restarted** — F.6's
mechanism reproduced on purpose rather than suffered once.

**Rule 1 is measured, and only because of the control.** "Calico took `mc-decoy`" is
explained equally well by *the exclusion is real* and by *the highest index won*. So the
winner is deleted — and Calico falls back to the **incumbent at index 2**, skipping
`br-decoy` at index **8**, still up and still addressed. Index ordering cannot explain that.
The only difference left is the name.

> **The control is the lab.** Without it this is a story about one interface being chosen.
> With it, it is a measurement of *why*.

## A finding is bound to its subject

[`findings.env`](findings.env) records the result **together with the Calico version, the
microk8s version and the autodetection method that produced it**, and
[`tests/test-selection-rules.sh`](tests/test-selection-rules.sh) **refuses to compare** a
live run against it across a mismatch, printing both values.

This is the same discipline as metal-as-a-service's `capture-policy`, which stamps
`# image-sha256:` into `pcrs.expected` so a policy captured from a different build is
refused by name. **A version string is a weaker identity than a hash** — two builds of one
version can differ — and that limitation is stated here rather than pretended away. It is
still enormously better than an unstamped claim, and it is what the CNI exposes.

**It answers about *a* Calico, not *the* Calico.** The measurement is **v3.29.3**; the host
this was developed on runs **v3.28.1**. The result transfers as a statement about the
selection algorithm at a named version. It is **not** a prediction about any particular
machine, and nothing here should be quoted as one.

### The record that nearly outlived its subject, in this lab, on day one

The first `findings.env` recorded the migration as **180 seconds**, from a hand-run that saw
the incumbent still bound at ~100 s. The **first packaged reproduction**, hours later on the
same image and the same Calico, converged in **15 s**.

Same subject, an order of magnitude apart. A single number would have been false on its
first re-run — this repo's bug class #1, committed *inside the file written to prevent it*.
It is now a **range**, and the tests report convergence time rather than asserting a bound.

## Using it

```bash
# ~15 min: create, grow the overlay, boot, and wait for the cluster's own marker
examples/nested-calico-sandbox/sandbox.sh up

# run the experiment and print the NCS-* record
examples/nested-calico-sandbox/sandbox.sh experiment

# where is the guest's tunnel? (and the host's, which must never move)
examples/nested-calico-sandbox/sandbox.sh status

examples/nested-calico-sandbox/sandbox.sh down
```

`tests/run-all.sh` runs the headless half anywhere and **SKIPs** the live half with a reason
when no sandbox is up — an unmet precondition is an UNKNOWN, never a pass.

> ⚠️ **This suite is a LOCAL gate, not a continuous one, and a green CI does not cover it.**
> Three of its six tests need a VM that takes ~15 minutes to build and ~45 minutes to
> exercise, so CI sees them SKIP. That is the correct result — an unmet precondition is an
> unknown — but it means the selection rules, G.9 and the CNI matrix are only measured when
> a human runs them here. Stated plainly so a green badge is not read as coverage it does
> not have.
>
> What CI *does* cover of the matrix is [`tests/test-cni-chaos-grader.sh`](tests/test-cni-chaos-grader.sh):
> the grader's assertions are a set of claims about what it would do if the CNI misbehaved,
> and the only cluster it has ever graded behaved well, so every one of those branches had
> run zero times. It hands the grader **hand-injected records** — a refused pod reporting
> `Running`, an allocator that returns nothing, a run that left the IP pools disabled, an
> injector that landed no fault — and requires each to be refused **by its own message**.
> Two seconds, no cluster, no root.
>
> Full local run: `4 measured tests, ~45 minutes`. Last green **with a sandbox up**,
> 2026-08-07: `5/5 listed tests ran — 5 passed, 0 skipped, 0 failed`. The grader test was
> added on 2026-08-08 and has only been run **headless** since
> (`6/6 listed tests ran — 3 passed, 3 skipped, 0 failed`, the three skips being the live
> half) — said this way round because "6 passed" is a number nobody has measured, and a
> count that outruns its run is this repo's bug class #1 written into a README.

## Three traps this lab hit, so you do not have to

- **`ping` is not connectivity here.** slirp drops ICMP for an unprivileged user, so a ping
  from inside the guest fails while TCP works perfectly. The first spike read that as "no
  network" and nearly abandoned the lab.
- **`/snap/bin` is not on `sudo`'s `secure_path`.** A bare `microk8s` under sudo is
  *command not found* — which the first spike reported as a cluster failure while the
  cluster was running. Every call here uses the absolute path.
- **The guest console is a unix socket, not a file.** `lab-vm.sh` exposes it for
  `lab-vm.sh console` to attach; nothing writes a log. `sandbox.sh` captures it with
  `socat` — and while that capture runs, `lab-vm.sh console` sees nothing, because **one
  client at a time** on that socket.

## It cannot touch the host

The guest is `network_mode = "user"` (slirp): **no tap, no bridge, no fabric on the host
side.** `sandbox.sh` prints the host's Calico binding before and after, and
`tests/test-selection-rules.sh` **fails** if it moved during a run — because if this lab can
move the host's tunnel then it is not a sandbox and the guarantee above is false.

## The CNI's break pass

A passing cluster only proves the happy path. `CLAUDE.md`'s ladder asks for an injection
point at **every layer that can fail on its own**, and the CNI had none — because breaking
one meant breaking the cluster this machine uses. That is exactly the objection this lab
removes, so [`cni-chaos.sh`](cni-chaos.sh) injects at seven of them and
[`tests/test-cni-chaos.sh`](tests/test-cni-chaos.sh) grades the outcome:

| layer | fault |
|---|---|
| *(control)* | none — the dataplane must work before anything is broken |
| the CNI **process** | delete `calico-node`'s pod |
| felix's **programming** | flush Calico's netfilter rules |
| one pod's **veth** | delete it underneath a running pod |
| the **overlay device** | delete `vxlan.calico` |
| the **chosen address** | let Calico bind a decoy, then delete the decoy out from under it |
| the **address allocator** | disable the cluster's pools, offer a /29, and fill it with real pods |
| the **datastore beneath it** | stop `k8s-dqlite` — the layer *below* the CNI, and the one that breaks the API this harness talks through |

**Graded against a real dataplane**, not a readiness field: every row's headline observable
is `pod-a → pod-b`. Four more are collected alongside it (`ready`, `nodeip`, `tunnel`,
`rules`) because when the dataplane *does* break they say which layer broke.

### What one node cannot see, said out loud

There are no peers here, so **the VXLAN tunnel carries no traffic**. A fault whose only real
consequence is cross-node cannot move the dataplane observable — and grading it ABSORBED
would mean *"the fault never mattered"*, not *"the CNI absorbed it"*. The `vxlan-deleted`
row is therefore graded **only** on whether Calico rebuilds the device, and says so by name.

Every fault is **scoped**: nothing touches `enp0s3`, which carries ssh. A fault that kills
the guest's own management path would send every remaining row to the same rung and the
harness would report a uniform, uninformative failure while looking like it worked.

### One fault, two subjects: the allocator row

Exhausting the address allocator is the analogue of micro-cloud's DHCP-pool row, one layer
up — and like that row, **the point is not that it runs out. It is *how*.** Running out of
addresses is arithmetic. The interesting part is what the CNI does at the moment it has
none left, and the answer differs for two subjects the same fault hits at once:

| subject | question | measured |
|---|---|---|
| pods that **already hold** an address | do they notice the allocator is dry? | **ABSORBED** — `pod-a → pod-b` never broke |
| a pod admitted **at that instant** | is it refused honestly, and recoverably? | **HALTED** — refused by name; freeing one address let exactly one waiter through in **7 s** |

The cluster's pool is a `/16`, which nobody is filling with pods, so the pools in use are
disabled and a deliberately tiny `/29` is offered in their place — then filled with real
pods making real CNI `ADD` calls. Seven of its eight addresses were taken and five pods were
refused, with this against them:

> `plugin type="calico" failed (add): failed to request IPv4 addresses: Assigned 0 out of 1`
> `requested IPv4 addresses; No IPs available in pools: [10.99.9.0/29]`

That is about as honest as a refusal gets — it names the operation, the count and the pool
that ran dry. The test asserts the message contains **the CIDR this harness chose**, which
is not a guess about upstream's wording; [see below](#two-defects-the-first-run-found-in-its-own-harness)
for what happened when it was.

Two further questions the rung cannot answer are asked separately. First, whether the
allocator **gives addresses back** — bug class #1, aimed at the allocator. It does, at *two
speeds*: six of the seven return the instant their pod leaves the API, and exactly one
lingers for a tail that has outrun every deadline picked for it. So the test asserts the
prompt path (which has a real failure mode: if *nothing* comes back, every pod that ever ran
permanently consumes an address) and merely **reports** the tail. Second, whether the run
**put the cluster back** — this is the only row that edits a cluster-wide API object, and
leaving a pool disabled would poison every later run with a fault nobody injected.

```bash
examples/nested-calico-sandbox/sandbox.sh cni-chaos     # ~20 min
```

### Two defects the first run found in its own harness

Both were in the assertions written to judge Calico, and **both would have failed a cluster
that was behaving correctly** — the expensive direction, because nothing is broken and the
suite insists otherwise.

- **A guessed error string.** The check for "did the refusal name itself" grepped for
  `assign an IP`, `no IP addresses available` and `IPAM`. All three were invented at the
  desk, and all three missed the real message quoted above (`Assigned`, not `assign an IP`;
  `No IPs`, not `no IP addresses`; no `IPAM` anywhere). An exemplary refusal would have been
  graded dishonest by an assertion that was itself asserting a made-up mechanism. It now
  matches on the pool CIDR **this harness chose**.
- **A leak check that was a deadline in disguise — three times.** It read the allocator's
  records ten seconds after the last pod left and reported one address still held. Raised to
  180 s: same answer, and an independent poll found the address free ~80 s later. Raised to
  600 s: same answer again, free on the next look. Three false leak reports against a healthy
  cluster, each one *"I stopped watching"* printed as *"it never happened"*.

The second is worth stating in both directions. A detector that cries leak on a healthy
cluster is not being "cautious": it fails CI for a defect that is not there, and the first
thing a reader learns is to stop believing it.

The fix was not a bigger number — that is the same mistake with more patience. **"Did it
leak" means "is it never reclaimed", and no test establishes never.** So the question
changed: assert the prompt path, which is answerable and has a real failure mode, and report
the tail as an observation. The grader's branches were then each made to bite against
hand-written records — the whole matrix can be re-graded without a cluster via
`CNI_CHAOS_RECORD=<file>`, which is also how a failed run's kept record is re-read without
spending another 20 minutes.

## What it does not yet do

- **G.9's remaining scenario** — give a real **`fabric.sh` tap** an address and watch it
  become a candidate. A dummy interface in a guest is *not* a tap on `br-mc0`; see
  [`tests/test-fabric-tap-becomes-candidate.sh`](tests/test-fabric-tap-becomes-candidate.sh).
- **Cross-node consequences.** One node cannot observe them; a second would be a different
  lab.
- **The datastore beneath Calico** (`k8s-dqlite`) — a layer below this one, and breaking it
  breaks the API the harness talks to.

## See also

- [`MICRO_CLOUD_LAB_PLAN.md` Appendix O](../../MICRO_CLOUD_LAB_PLAN.md#appendix-o--the-nested-calico-experiment-run-two-derived-rules-become-measurements-2026-08-07) — the experiment as first run, by hand
- [`MANUAL_TESTING.md`](MANUAL_TESTING.md) — what to expect, step by step
- [`examples/micro-cloud/DEFERRED.md`](../micro-cloud/DEFERRED.md) — the brief and its five constraints

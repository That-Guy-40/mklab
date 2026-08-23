# The clone ledger

[Plan §4.1](../../MICRO_CLOUD_LAB_PLAN.md#41-decision-16--the-reuse-ladder-hardline) sets a
four-rung reuse ladder and requires this file so the rule cannot decay into a comment nobody
checks:

| rung | meaning |
|---|---|
| **1 — Invoke** | call the existing tool unchanged. The default. |
| **2 — Wrap** | a thin adapter translating our vocabulary to theirs, **and nothing else**. |
| **3 — Extend upstream** | add a verb or backend to the original so **both** labs benefit. |
| **4 — Clone** | only when the original's constraint is **load-bearing AND wrong for us** — and then the constraint gets named here. |

## The ledger

**There are no rung-4 clones in this lab.** That is the entry, and it is a measurement
rather than an aspiration: as of **2026-08-23**, `git grep -niE 'forked from|clone of|copied
from|adapted from|derived from'` over `examples/micro-cloud/` returns **no file declaring a
fork**. The four hits it does return are about *values* being derived — a MAC from a name, a
tap list from the spec — not about code taken from somewhere else.

| what | rung | evidence |
|---|---|---|
| Firecracker itself | **1 — invoke** | `lab-fc.sh` shells out to the upstream binary; the lab pins a version and now takes `$LAB_FC_BIN` to say *which* one. Nothing is reimplemented. |
| The phase drivers (`lab-chroot.sh`, `lab-fc.sh`, `lab-docker.sh`, `lab-lxd.sh`, `lab-vm.sh`) | **1 — invoke** | `micro-cloud.sh` orders them; it does not contain their logic. Deleting the guided layer loses nothing, which is [§0.2](../../MICRO_CLOUD_LAB_PLAN.md)'s invariant. |
| `fabric.sh` | **new code, not a clone** | there is no original: bridge + tap + NAT + dnsmasq wiring for *this* lab's addressing. A clone needs something to clone. |
| `preserve.sh` | **new code, not a clone** | same. Its two tiers are this lab's own model. |
| MAAS's deploy drivers | **1 — invoke** | recorded in the plan as rung 1 at the point the decision was made. |

## What is NOT yet enforced, and why that matters

§4.1 asks for more than this file: *"a test that **fails** when a file declares a fork in its
header and is not listed, or is listed without naming a constraint."* **That test does not
exist**, so the ledger above is currently maintained by a human reading `git grep` output —
which is exactly the shape §4.1 predicts decays.

Written down rather than implied, because an unenforced ledger and an enforced one look
identical on the day they are both correct. Tracked as [`TODO.md`](../../TODO.md) **A.5**.

A neighbour of that check now exists and is worth reading first:
[`tools/check-tree-diagrams.sh`](../../tools/check-tree-diagrams.sh) turns "the docs promise
a file that does not exist" into a gate, which is the same shape — a claim in prose,
compared against the tree.

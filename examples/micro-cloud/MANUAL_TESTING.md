# MANUAL_TESTING — micro-cloud

> [`MICRO_CLOUD_LAB_PLAN.md`](../../MICRO_CLOUD_LAB_PLAN.md) §10 asks the question this file
> exists to answer, and it is deliberately not "which claims are untested?":
>
> > **Which claims were tested by observation, and which only by reading a config?**
>
> Everything below is one or the other, said out loud. A row marked ⬜ is an **UNKNOWN**, and
> UNKNOWN is a verdict distinct from PASS — it means nobody has looked, not that it is fine.

## What runs with no privileges, on every CI run

```bash
examples/micro-cloud/tests/run-all.sh
```

| test | observes | ⚠️ does NOT prove |
|---|---|---|
| `test-micro-cloud-plan.sh` | the plan is complete against the spec, ordered (fabric before/after the instances), parses as shell, and **ran nothing** — with two negative controls that bite first | that any step would succeed |
| `test-spec-is-one-description.sh` | `micro-cloud.toml`'s `edge` block is key-for-key identical to `edge.toml`'s, and every declared MAC still matches what `fabric.sh` and `lab-fc.sh` derive — each with a control | that the MAC formula is *right*, only that the three places agree |
| `test-isolation-matrix.sh` | §9.3, for the **host** and **rootless container** rows: process-table size, PID/network namespace ids, `/proc` identity, `/dev/kvm`, `dmesg` | the three machine rows — they are printed as UNKNOWN, by name, with the reason |
| `test-guided-path-is-a-view.sh` | (execs `tools/check-guided-path-is-a-view.sh`) every verb in the rendered plan and in `install-catalog.toml` is one the tool actually dispatches — **asked** by running it | that a walkthrough succeeds |
| the slice 0–9 suite | as documented in [`README.md`](README.md) | — |

Green here means the lab is **described** correctly. It does not mean it came up.

## The privileged run — this is the part that needs you

Everything below needs root (the fabric creates a bridge, taps and nft rules) and a host with
KVM. It is separated because of what the fabric sits beside: **read
[`LEDGER.md` L10-1](LEDGER.md#l10-1--calicos-node-ip-is-on-an-interface-that-is-down-and-db-is-the-instance-that-could-move-it)
before the first `sudo`.** On the machine this was built on, a live Calico cluster's tunnel
endpoint is on a bridge that is down and memberless, and the `db` instance is the one whose
default behaviour would have moved it.

### Preconditions, checked before anything privileged

```bash
examples/micro-cloud/fabric.sh status          # read the THEIRS block. Write it down.
phase7-firecracker/lab-fc.sh preflight --config examples/micro-cloud/micro-cloud.toml
```

### The run

**There is a script that does all of this and records the evidence**, and it is the one to
use — [`run-privileged-demo.sh`](run-privileged-demo.sh):

```bash
sudo -E examples/micro-cloud/run-privileged-demo.sh --reset
```

It brackets the whole run with an *independent* recording of the CNI's state, waits for
readiness (which `up` does not), asks the capstone question from `edge` at its leased
address, runs the matrix, tears down, and diffs the before/after. `--reset` destroys what
earlier runs left — each object through the tool that made it, by name — which a repeat run
needs, because `down` does not destroy and `create` refuses an instance that exists.

It lived in a scratch directory for five runs and a reboot took it. That is the second
privileged harness this lab has lost to `/tmp`; it is in the repo now.

The steps it performs, if you would rather type them:

```bash
sudo examples/micro-cloud/micro-cloud.sh up
     examples/micro-cloud/micro-cloud.sh status
     edge_ip=$(awk '$4 == "edge" { print $3 }' /run/mklab-mc/leases)
     ssh lab@"$edge_ip" -- getent hosts api1     # NOT `lab-vm.sh ssh`: see below
     ssh lab@"$edge_ip" -- ping -c2 api1
     examples/micro-cloud/tests/test-isolation-matrix.sh
sudo examples/micro-cloud/micro-cloud.sh down
     examples/micro-cloud/fabric.sh status      # THEIRS must match what you wrote down
```

### The success signature

| # | claim | how you know | status |
|---|---|---|---|
| 1 | the fabric came up and Calico did not move | `fabric.sh up` records the binding and the whole candidate set; `down` compares and reports a migration by name | ✅ **2026-08-19** — binding, veth count, `ip_forward` and both engine bridges' membership identical before/during/after, checked independently of the fabric's own comparison, across four runs |
| 2 | five instances of four kinds are up | `micro-cloud.sh status` shows `api1`, `api2` running, `edge` running, `db` and `metrics` listed by their own drivers | ✅ **2026-08-19** — `up` rc=0, all five: `api1`/`api2` running, `edge` running, **`db` Running** with its veth on `br-mc0`, `metrics` up. First clean full bring-up |
| 3 | they are on one L2 and resolve each other **by name** | `getent hosts api1` from `edge` returns an address in `10.71.0.0/24`; `ping -c2 api1` is 0% loss. **Not via `lab-vm.sh ssh`** — that verb connects to a slirp hostfwd `edge` does not have (`network_mode = "tap"`), and phase 2 now refuses it by name. ssh to the leased address instead, or read `console.log` | ✅ **2026-08-19** — from `edge`: `getent hosts api1` → `10.71.0.101`, `ping -c2 api1` → **0% loss** |
| 4 | each microVM has its **own identity from one image** | `lab-fc.sh inspect api1` and `api2` show different MACs and addresses from the same rootfs lineage; MMDS answers `instance-id` inside each guest | ✅ **fully observed 2026-08-20** — both booted from copies of one source image and took *different* MACs and *different* reserved leases (`.101`/`.102`), each derived from its own name. The **MMDS half is now closed too**, and unprivileged: `tests/test-mmds-answers-inside-the-guest.sh` makes a tap inside a user netns (MMDS packets never leave the VMM, so no fabric and no root), and the guest completes the **v2 PUT-for-a-token handshake over `nc`** — `wget` cannot PUT — reading `instance-id` **matching its own name**, while the same GET *without* a token is refused **401** |
| 5 | §9.3's matrix has five rows, not two | `test-isolation-matrix.sh` prints no UNKNOWN rows | ✅ **5 of 5 measured, 0 UNKNOWN — 2026-08-20** — host, `metrics`, `db`, `edge`, and **`api1` as the lab's own running instance**, not a stand-in: the spec declares `vsock = true`, the demo injects the agent into the api images, and the matrix asks the real guest (`58` processes, PID 1 `init`, **its own boot_id** `8a8c1b4b`, `dmesg` **readable** because it is its own kernel and the host's `dmesg_restrict` does not reach it). Every row runs the *same* probe commands through a different boundary |
| 6 | teardown left **nothing of ours** | `ip -o link show` has no `br-mc0` and no `mc-*`; `fabric.sh down` asserted absence itself and did not have to be trusted about it | ✅ **2026-08-19** — `down` rc=0, and `br-mc0`/`mc-*` absence re-checked from outside |
| 7 | teardown left **everything of Calico's** | `fabric.sh status`'s THEIRS block — tunnel binding, `cali*` veth count, `ip_forward` — matches what step 0 recorded | ✅ **2026-08-19** — THEIRS block identical to what pre-flight recorded |

**Do not mark a row ✅ from a command that merely exited 0.** Row 3 is the one this most
applies to: `up` orders invocations and not readiness
([L10-2](LEDGER.md#l10-2--up-orders-invocations-and-readiness-is-a-different-question)), so
`edge`'s own first-boot `EDGE-PING-BY-NAME` line is expected to say FAIL on a cold bring-up
and says nothing either way about row 3. The hand-run `getent`/`ping` above is the evidence.

### What is expected to be awkward

- **A second `up` halts at the chroot.** `lab-chroot.sh create` refuses a target that
  exists, and `lab-fc.sh create` refuses an existing instance. Both refusals are correct —
  they protect a tree several instances are running on, and a per-instance rootfs copy. The
  converging verb is `phase6-tui/lab_tui/apply.py`, which is a different contract.
- **`db` needs `br-mc0` to already exist**, because its `nic` device names it as a parent.
  It is ordered last, so this holds; if you run the LXD step alone, run the fabric first.
- **`metrics` will not appear on the fabric at all**, and that is the §9.3 exhibit rather
  than a fault. A rootless container cannot be given a tap.

### If something goes wrong

`micro-cloud.sh` halts on the first non-zero step and prints the step's description, its exit
status, and the exact command — so the next thing to do is run that command by hand and read
its own diagnostics, which are better than anything this wrapper could relay. Nothing is
retried automatically and nothing is cleaned up on failure: a half-built lab you can inspect
is worth more than a tidy one you cannot.

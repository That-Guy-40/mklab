# DEFERRED — what a green run still does not prove

**Status as of 2026-07-28:** `run-e2e.sh` **PASSES** end to end on real libvirt domains
(ten phases; see [`PLAN.md`](PLAN.md), "PASS — the whole path"). `tests/run-all.sh` is
**23 passed / 0 failed** and `chaos-run.sh` reports **0 criticals**.

This file exists because *that sentence is not the same as "the lab is finished,"* and the
difference is easy to lose. Everything below is a gap that a passing run **cannot** reveal,
each one already reached and understood — none of this is speculative future work, and
none of it is blocked. They are in priority order, and the first one is worth more than
the other two together.

When you pick one up: the PLAN.md section named with each item is the evidence trail (the
live run that exposed the gap, and what it printed). Update this file when an item lands —
an item that is quietly done is as misleading as one quietly abandoned.

---

## 1. The on-node half of F2 has never run  ⭐ highest value

**What is unproven.** F2 (payload signing) has two halves, and only one of them has ever
executed on this fleet:

| half | where | status |
|---|---|---|
| host-side | `verify` — OpenSSL CMS against the CA, before the node is touched | **exercised every run** |
| on-node | `imgverify` in the iPXE script — the firmware re-checks as it fetches | **never executed** |

Every passing run set `E2E_NO_IMGVERIFY=1`, because QEMU's stock iPXE ROM (what a libvirt
NIC boots by default) is built without `IMAGE_TRUST_CMD`: an `imgverify` line is an unknown
command, the script aborts, and nothing boots — with **zero bytes** on the console, because
that ROM also has no serial console. So the run refuses up front rather than booting into a
silence.

**Why it matters more than it looks.** The supply-chain claim this lab makes is a *chain*:
the host verifies before it hands the payload over, and the machine verifies again before it
executes. Half a chain is a different (and much weaker) claim, and the current arrangement
is one flag away from reading as the strong one. The refusal keeps it honest today; a
verifying ROM would make it *true*.

**It also closes a second, unrelated hole.** The same ROM gives iPXE a **serial console**.
Right now the boot chain's own `echo` lines never reach the console log, so every
iPXE-level failure is invisible to precisely the instrument built to see it — that is what
made the third live run's failure a 120-second silence rather than a message.

**The concrete first step.** The builder already exists and is proven in the RAM-infra lab:

```bash
../../netboot/build-ipxe.sh --imgverify --certfile ~/.cache/lab-create/maas/images/trust/ca.crt
```

⚠️ `--certfile` is the killer gotcha recorded in the RAM-infra work — without it the ROM
verifies against nothing. Then attach it per NIC (`<rom file='…/ipxe.rom'/>` inside each
domain's `<interface>`, so `create-fleet.sh` grows a `give_verifying_rom()` beside
`give_console()`), record the capability per node in the registry, and run with
`MAAS_IPXE_TRUSTS_CA=1` — which `run-e2e.sh` already understands.

**Done when:** a run with neither `E2E_NO_IMGVERIFY` nor `--no-verify` reaches `active`,
**and** a deliberately tampered payload is refused *by the firmware* with a message on the
node's console log. The negative control is the point — a ROM that verifies nothing also
lets a good payload through.

**Evidence trail:** [`PLAN.md`](PLAN.md) — "The third live run", "The seventh run", and
`### Named, not yet built`. Headless coverage of the seam itself:
[`tests/test-imgverify-halves.sh`](tests/test-imgverify-halves.sh).

---

## 2. Only the `ramdisk` driver has touched a real node

**What is unproven.** `run-e2e.sh` deploys `ramdisk` and nothing else. The `install`,
`image`, and `image+measured` drivers have real headless tests that drive the real driver
scripts — [`tests/test-install-driver.sh`](tests/test-install-driver.sh),
[`tests/test-image-driver.sh`](tests/test-image-driver.sh),
[`tests/test-image-measured-driver.sh`](tests/test-image-measured-driver.sh) — and that is
genuinely more than a mock. It is still not a machine.

**Why it matters.** This lab's own record argues the case: of the thirteen defects the live
path found, **not one** was visible to the green headless suite. They lived in the plumbing
the mocks stand in for — a baked `boot.ipxe`, a colliding BMC port, a self-symlinked
busybox, a disk write lock, a kernel with no NIC driver, a wrongly-cut escape hatch. There
is no reason to think the other three drivers are the exception, and one live finding
already points at them: `install.sh` claimed *every* image as its own until a rollback
handed it a RAM payload (see item 3's sibling in `PLAN.md`, "the eighth run").

**The concrete first step.** `install` is the higher-value of the two and the more
expensive: it is the ~30-minute Anaconda path, already proven single-node by
`../virtualbmc-ipmi-lab/run-finale.sh`. Rather than lengthen `run-e2e.sh`, add a **separate**
`run-e2e-install.sh` (or an `E2E_DRIVER=install` mode) so the fast reconcile-loop run stays
fast. `image` is cheaper — it needs a golden whole-disk raw staged, and its deployer-ramdisk
path has never met real hardware at all.

**Careful:** `fleet.toml` deliberately declares one payload for all three nodes now
(see the comment in it). Do **not** re-introduce a heterogeneous spec without building the
artifacts first — that made phase 9's convergence invariant unreachable and cost two live
runs.

**Done when:** a live run reaches `active` through `install` on a real domain, with the
installed OS's own `login:` on the console — not the ramdisk's.

---

## 3. A chaos scenario for a BMC that answers for a *different machine*

**What is unproven.** `chaos-run.sh`'s `oob` layer covers a BMC that **stops** answering
(`bmc-drop`). It does not cover a BMC that answers **wrongly but plausibly** — the failure
the second live run hit by accident, when `alpine-node` and `node1` both defaulted to port
6230 and the winner served IPMI for both.

**Why it is the highest-value scenario outstanding.** It is the only failure this lab has
seen that **passed every gate on the way to failing**. Four IPMI commands succeeded and
returned true answers — about the wrong machine. Nothing was down, nothing errored, and the
control plane's record and reality diverged silently: the **LIED** rung, reached without a
single thing appearing broken. Compare `bmc-drop`, which announces itself immediately.

**The concrete first step.** Teach the mock BMC to actuate *another* node's power state on
request — an env like `MOCK_BMC_ACTUATES=<other-node>` — then add a scenario that points
node A's BMC at node B and grades what the control plane does. The interesting question is
whether anything **notices**: a deploy that powers on the wrong machine, health-gates the
wrong console, and records success is STRANDED-or-worse, and the honest grade may well be
critical on the first attempt. That is a finding, not a failure of the exercise.

**A defence already exists and is not the same thing.**
[`lib/vbmc_check.py`](lib/vbmc_check.py) catches the *collision* before enroll (and refuses
an empty `vbmc list`, so a dead vbmcd cannot read as "no problems"). That prevents the
specific accident. It does not answer "what does the control plane do when the seam lies
to it," which is what the chaos matrix is for.

**Done when:** `chaos-run.sh` has an `oob` scenario injecting a mis-bound BMC, its rung is
graded after attempting the recovery the system offers, and
[`tests/test-chaos-matrix.sh`](tests/test-chaos-matrix.sh) fails if the scenario is removed.

**Evidence trail:** [`PLAN.md`](PLAN.md) — "What the SECOND live run found: the seam
answered for the wrong machine", and `### Named, not yet covered`.

---

## Smaller, still open

- **`install.sh`'s ownership test is narrow on purpose.** `describe <image>` refuses a
  payload staged as kernel+initrd+cmdline (the triple only `ramdisk.sh stage` writes),
  which catches the rollback case that actually happened. It does **not** catch an image no
  driver has staged, or a third driver's. A per-driver catalog — the shape
  `ramdisk-catalog.toml` already establishes — would close it properly.
- **`describe` is asked of every driver by `gate`, but only `ramdisk` and `install`
  answer meaningfully.** `image` and `image+measured` still accept any image name.

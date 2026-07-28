# DEFERRED — what a green run still does not prove

**Status as of 2026-07-28:** `run-e2e.sh` **PASSES** end to end on real libvirt domains
(ten phases; see [`PLAN.md`](PLAN.md), "PASS — the whole path"). `tests/run-all.sh` is
**23 passed / 0 failed** and `chaos-run.sh` reports **0 criticals**.

This file exists because *that sentence is not the same as "the lab is finished,"* and the
difference is easy to lose. Everything below is a gap that a passing run **cannot** reveal,
each one already reached and understood — none of this is speculative future work, and
none of it is blocked. They are in priority order, and the first one is worth more than
the other two together.

> **Item 1 has since been picked up, and it paid immediately.** The first time real
> verifying firmware was pointed at this lab's payloads it refused them all, because the
> signing certificate was missing `keyUsage=digitalSignature` — a defect no host-side check
> could ever have seen. That is the case for this file in one sentence: the gaps a green
> run cannot reveal are where the defects were.

When you pick one up: the PLAN.md section named with each item is the evidence trail (the
live run that exposed the gap, and what it printed). Update this file when an item lands —
an item that is quietly done is as misleading as one quietly abandoned.

---

## Where to start next (as of 2026-07-28, after PR #97)

**1. The live run — the only thing item 1 still lacks, and everything for it is staged.**

```bash
./build-verifying-rom.sh install       # ← the one step outstanding; needs sudo
FLEET_NIC_ROM=1 ./create-fleet.sh      # brings the fleet up WITH the verifying ROM attached
MAAS_IPXE_TRUSTS_CA=1 ./run-e2e.sh     # no E2E_NO_IMGVERIFY
```

Already done and verified, so do **not** redo them: the trust root is re-minted with the
firmware-acceptable profile (`check-keys` passes), `micro-linux-x86_64` is re-signed under
it (the host-side gate passes), and the ROM is rebuilt against that CA
(`tests/test-verifying-rom.sh` boots it and passes). The fleet itself is **down** — no
libvirt domains, no `vbmcd` — so `create-fleet.sh` has to run first regardless.

`build-verifying-rom.sh install` is the single remaining prerequisite: qemu runs as another
user and cannot read `$HOME`, so the ROM must be copied under `/var/lib/libvirt`. Without
it `give_verifying_rom()` refuses rather than half-applying — a fleet where some nodes
verify and some do not proves less than one where none do.

**2. Items 2–4 below** — the `install` driver on real hardware, the mis-bound-BMC chaos
scenario, and whether `apply` should self-heal a node its own guard demoted.

**3. Move the signing key out of `~/.cache`** (in "Smaller, still open"). A one-line default
change plus a migration note. It moved up the list on 2026-07-28 for a concrete reason: the
trust dir was deleted mid-session and the whole fleet's signing material went with it. It
was recoverable in minutes — but only because the recovery path had just been written down.

---

## 1. The on-node half of F2 — ✅ RUNS, and found a real defect; ⬜ not yet on the live fleet

**Status changed 2026-07-28.** The firmware half now executes, headlessly, on every run of
[`tests/test-verifying-rom.sh`](tests/test-verifying-rom.sh):

| half | where | status |
|---|---|---|
| host-side | `verify` — OpenSSL CMS against the CA, before the node is touched | exercised every run |
| on-node | `imgverify` in the iPXE script — the firmware re-checks as it fetches | **runs under QEMU** ✅ |
| on-node, live | the same, on a libvirt fleet node | **still never run** ⬜ |

**What it cost to find out, and why it was worth it.** The very first time real verifying
firmware was pointed at this lab's own signed payloads, it refused them — *all* of them,
including good ones:

```
http://…/good.img... ok
http://…/good.img.sig... ok
Could not verify: Permission denied (https://ipxe.org/022ae13c)   ← "Not a signing certificate"
```

`drivers/verify-lib.sh` minted its code-signing leaf with `extendedKeyUsage=codeSigning`
and nothing else. `openssl cms -verify` does not look at key usage, so every host-side
gate, every driver test and the whole green suite accepted it — and iPXE requires
**`keyUsage=digitalSignature`** as well. **This fleet had been signing payloads that no
verifying firmware would ever accept**, and by construction nothing on the host could see
it. Fixed in `verify-lib.sh` (the profile now matches `netboot/sign-payload.sh`, the signer
the RAM-infra lab proved against real iPXE), guarded by `verify-lib.sh check-keys`, and
pinned against re-divergence by
[`tests/test-signing-cert-profile.sh`](tests/test-signing-cert-profile.sh) §4.

**The second hole is confirmed and closed too.** Measured on this fleet's own `node1.log`:
it begins at `Linux version …` with **zero** SeaBIOS or iPXE lines. Side by side in
libvirt's own QEMU invocation (`-display none`, *not* `-nographic`): **stock ROM 0 bytes on
the serial console, the new ROM 617**. ⚠️ Do not test a `CONSOLE_SERIAL` build under
`-nographic`: QEMU sets `FW_CFG_NOGRAPHIC`, SeaBIOS puts *its* console on COM1 too, and the
two writers interleave byte-by-byte (`iiPPXXEE`) — under that invocation the stock ROM looks
instrumented and this one looks broken, which is exactly backwards.

**How to build it** (the earlier note here named `--certfile`, which is not a flag
`build-ipxe.sh` has — that was OpenSSL's `-certfile`, from `verify-lib.sh`):

```bash
./build-verifying-rom.sh build      # docker, ~10 min: iPXE + IMAGE_TRUST_CMD + TRUST=<fleet CA>
./build-verifying-rom.sh install    # sudo: /var/lib/libvirt, because qemu cannot read $HOME
```

**What remains — the live run.** Everything needed is now in place and untested only
*together*:

```bash
FLEET_NIC_ROM=1 ./create-fleet.sh      # give_verifying_rom() attaches it per NIC
MAAS_IPXE_TRUSTS_CA=1 ./run-e2e.sh     # no E2E_NO_IMGVERIFY
```

⚠️ The live trust dir (`~/.cache/lab-create/maas/images/trust`) still holds a **legacy
leaf**: `verify-lib.sh gen-keys` never overwrites an existing keydir. Re-mint it, re-sign
every image, and rebuild the ROM (it bakes the CA) before that run — `run-e2e.sh`'s preflight
now refuses rather than letting it fail on the node.

**Done when:** a live run with neither `E2E_NO_IMGVERIFY` nor `--no-verify` reaches
`active`, **and** a deliberately tampered payload is refused by the firmware with the
refusal visible in that node's console log.

**Evidence trail:** [`PLAN.md`](PLAN.md) — "The verifying ROM". Headless coverage:
[`tests/test-verifying-rom.sh`](tests/test-verifying-rom.sh) (the firmware itself),
[`tests/test-signing-cert-profile.sh`](tests/test-signing-cert-profile.sh) (the certificate
profile), [`tests/test-rom-xml.sh`](tests/test-rom-xml.sh) (the domain rewrite),
[`tests/test-imgverify-halves.sh`](tests/test-imgverify-halves.sh) (the seam).

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

## 4. Should `apply` self-heal a node its own guard demoted?

**The tension.** `apply`'s pre-flight re-checks every node claiming `active` and demotes
one that is no longer healthy to `error` — the anti-STALE guard, and it works. `apply` then
**holds** `error` nodes for the operator, by design. The consequence: the reconcile loop
cannot recover a node it demoted *itself*. Every stale node needs a manual `retry`, and a
fleet drifts toward held-and-ignored one node at a time.

**Why it is not obviously a bug.** An `error` state that wants a human is Ironic-faithful,
and "the loop quietly redeployed the thing that just died" is its own failure mode — the
second-order version of a crash loop.

**Why it still deserves an answer.** The two paths into `error` are not the same thing. A
node that **failed a deploy** has an unproven image and a human should look. A node
**demoted by the pre-flight** was healthy at activation and stopped afterwards — which is
often exactly what a reconcile loop exists to repair. Distinguishing them (a
`demoted_by_recheck` marker, say, and a bounded number of self-heal attempts before it
becomes a true hold) is the shape of the fix.

**Careful:** whatever this becomes must not be able to mask a node that fails immediately
and repeatedly. Bound it, record each attempt in the history, and make the bound visible in
the `apply` table.

**Evidence trail:** [`PLAN.md`](PLAN.md) — "The eleventh run", where a passing run reported
a fixed point over a fleet that was two-thirds held for exactly this reason.

---

## Smaller, still open

- **The fleet's signing key lives in a cache directory.** `run-e2e.sh:42` puts
  `MAAS_IMAGES_DIR` under `~/.cache/lab-create/maas/images`, so `trust/ca.key` — the thing
  every payload signature chains to — sits in a directory whose entire contract is *safe to
  delete*. The registry, by contrast, is under `$XDG_STATE_HOME/lab-create/`, which is where
  this belongs. Losing it is recoverable (re-mint → re-sign every image → rebuild the ROM,
  which bakes the CA) but silent until a deploy fails. Moving it is a one-line default
  change plus a migration note for anyone with an existing fleet.
- **`tests/test-e2e-fails-fast.sh` runs the real `run-e2e.sh`.** `MAAS_STATE` is now
  sandboxed on that line, but the test is still only safe because the preflight refuses
  before phase 1 — a test whose hermeticity depends on the order of checks *inside the
  script under test*. Measured harmless today (the registry's history is byte-identical
  across a run); worth making structural.

- **`install.sh`'s ownership test is narrow on purpose.** `describe <image>` refuses a
  payload staged as kernel+initrd+cmdline (the triple only `ramdisk.sh stage` writes),
  which catches the rollback case that actually happened. It does **not** catch an image no
  driver has staged, or a third driver's. A per-driver catalog — the shape
  `ramdisk-catalog.toml` already establishes — would close it properly.
- **`describe` is asked of every driver by `gate`, but only `ramdisk` and `install`
  answer meaningfully.** `image` and `image+measured` still accept any image name.

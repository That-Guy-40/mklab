# TODO — mklab

Project-level backlog, in the order raised (roughly: readiness, not priority).
For per-lab status see the phase `SHOWCASE.md`s and
[`examples/00-INDEX.md`](examples/00-INDEX.md); for the staged design see
[`PLAN.md`](PLAN.md). Large items should graduate to their own `*_LAB_PLAN.md`
(cf. [`NETBOOT_LAB_PLAN.md`](NETBOOT_LAB_PLAN.md),
[`MICRO_LINUX_LAB_PLAN.md`](MICRO_LINUX_LAB_PLAN.md)).

---

## 0. Next up — the three things nearest the front of the queue

*Added 2026-08-07.* The list below is otherwise **in the order raised, not priority**, so
this section exists to say what is actually next. All three are micro-cloud debts, all
three are small-to-medium, and each is **blocked on packaging or on a host, never on a
question nobody has answered**.

They are deliberately stated as what is **NOT** done, because two of them are the shape
this repo keeps getting caught by: *the experiment is finished, so the item feels finished.*
It is not — an experiment nobody can re-run is a story.

| # | what | state |
|---|---|---|
| **0.1** | **`examples/nested-calico-sandbox/` — the lab unit** | ⚠️ **the experiment is DONE; the packaging is not.** [Appendix O](MICRO_CLOUD_LAB_PLAN.md#appendix-o--the-nested-calico-experiment-run-two-derived-rules-become-measurements-2026-08-07) has the whole recipe and it reproduces **unprivileged in ~15 minutes**. What is missing is the cohesive-lab shape: a phase-2 `.toml`, `README.md`, `MANUAL_TESTING.md`, a `tests/` harness **carrying the delete-the-winner control**, a 00-INDEX row and a `learning-paths.toml` route. Detail in [§9](#9-nested-calico-sandbox--a-disposable-cluster-so-the-cni-beliefs-can-be-tested) |
| **0.2** | **G.9's remaining break-pass scenario** | **partly answered, not closed.** DHCP exhaustion is green; `retap` is green. What remains is *give a **`fabric.sh` tap** an address on purpose and watch it become a candidate* — [G.9](MICRO_CLOUD_LAB_PLAN.md#g9-not-run--recorded-as-unknown-not-as-pass). Appendix O measured the **property** with a dummy interface in a guest at Calico v3.29.3; **a dummy in a guest and a tap on `br-mc0` are not the same subject**, and this host runs v3.28.1. Needs 0.1 |
| **0.3** | **the fabric's own teardown code, under a live agent** | **named as not covered** by [`test-vsock-chaos.sh`](examples/micro-cloud/tests/test-vsock-chaos.sh). Its network row severs the guest's link with `set_link down`, which is a *superset* of losing the bridge — so the **property** is measured — but `fabric.sh down`'s teardown path is never exercised with a guest attached. **A stronger fault does not imply the weaker one ran**; that is why the matrix says so instead of letting it pass quietly. Root-gated |

- [x] **0.1** ✅ **DONE 2026-08-07** — [`examples/nested-calico-sandbox/`](examples/nested-calico-sandbox/):
      spec, driver, guest experiment, stamped `findings.env`, four tests, 00-INDEX row,
      `learning-paths` route. The harness refuses to compare across a Calico mismatch,
      naming both versions. [Appendix Q](MICRO_CLOUD_LAB_PLAN.md#appendix-q--the-sandbox-packaged-g9-closed-on-the-real-artifact-2026-08-07)
- [x] **0.2** ✅ **DONE 2026-08-07** — G.9 closed **on the real artifact**: a genuine
      `fabric.sh` tap, given an address on purpose, captured the guest cluster's tunnel.
      F.6 reproduced deliberately, at Calico v3.29.3.
- [x] **0.3** ✅ **DONE 2026-08-07** — the vsock chaos matrix has a `fabric.sh down beneath a
      live agent` row. Root-gated; a skip reports **UNCOVERED** rather than folding into the pass.

**0.4 — the flaky-CI shape, partly fixed** *(added 2026-08-07, after main went red twice)*.
`producer | grep -q PATTERN || fail` is wrong in two independent ways when the thing being
asserted is a **container's** state: the state is *eventual* (a tool returning is not the
container having done the thing), and `grep -q` exits on first match, closes the pipe, and
the producer can die on SIGPIPE — which under `pipefail` reports the **pipeline** as failed
though the match was found. That inversion is now on its **fifth** recorded instance here.

`await_line` / `await_match` in `phase3-docker/tests/lib.sh` and
`phase4-podman/tests/lib.sh` capture first and test second, with a deadline, and were
watched to fail on a needle that never arrives.

- [x] **0.4** ✅ **DONE 2026-08-07.** All 13 sites classified rather than swept, and the
      classification changed the plan: three of them were `&& fail` — **eventual absence** —
      where the inversion fails in the *dangerous* direction. A SIGPIPE'd producer makes the
      pipeline non-zero, `&& fail` never runs, and *"container still present after destroy"*
      reports a **pass**. Demonstrated, not argued: `producer | grep -qx name` over 200k
      lines returns **141** and the assertion silently skips.
      That also corrects this entry's own rule. *"A negative assertion must not gain a
      retry"* is true of an **invariant** ("must never appear") and false of **eventual
      absence** ("must be gone after this action") — which all three were. They now use
      `await_absent`.
      Converted by class: 3 eventual-absence → `await_absent`; 2 eventual-presence →
      `await_line`; 4 immediate → `has_line`/`has_match` (capture-then-test, no pointless
      retry); 4 `yq --version` precondition guards and 1 file-grep left alone.
      [`tools/tests/test-no-pipe-gates.sh`](tools/tests/test-no-pipe-gates.sh) now gates the
      **silent** variant repo-wide and inventories the 8 remaining noisy `|| fail` sites
      without gating them — the first draft flagged all 30 hits including its own
      documentation, which would have bred exemptions until it meant nothing.

## 0.6 The OpenBIOS toolkit's front of the queue (2026-08-27)

*Placed above §0.5 on purpose, and scoped narrowly on purpose.* §0.5 still has two open
boxes and is not superseded; this section covers only the thread that ran from §13 through
§16, because that thread now has a **stated end goal** and two named steps left, and a
reader should not have to walk 3,000 lines to find them.

**The end goal is [`REVIEW-preboot-forth-binary-structures.md`](REVIEW-preboot-forth-binary-structures.md)** —
poke's model in the environment poke is locked out of. Its **F2** was the only structural
blocker: `encode-*` chose its own destination, so it could never be aimed at storage the
firmware does not own. **F2 is now closed in fact** (§16): the writers take a destination,
the cursor composes at one, and `smoke-openbios.sh pmem-writer` finds the bytes in the
host's NVDIMM image after QEMU has exited.

The review's *Revised next steps* are 3½ of 4 done — §1 (config flips), §3 (the storage
question), §4 (`decode-bytes`), and three of §2's four assertions. **What is left is two
items, and neither is blocked on anything.**

- [x] **0.6a — the review's last unticked assertion. DONE 2026-08-27.** Measured in
      `property-abi` on both arches: `/chosen`'s `stdin` round-trips
      (amd64 `h-live=h-prop=14c08`), a **different** ihandle from the same node is
      distinguishable (`stdout`, `14ae8`) so the match is a statement about the round trip
      and not about the comparison, and **`h-hi=0`** — the top 32 bits, derived per boot.
      **So the review's own UNKNOWN is answered: an amd64 instance does NOT land above
      4 GiB today**, which is why the truncation hazard is latent rather than live. The
      assertion is written so the day that changes it fails by name, and §13.2(b)'s refusal
      means the firmware would abort honestly rather than truncate. *Original text:* §2's fourth: *"assert `/chosen`'s
      `stdin` survives a round trip at whatever address instances actually land on in long
      mode."* Cheap — no firmware change, one amd64 boot, arithmetic on values the prompt
      already prints. It also settles the review's own named UNKNOWN, from *What this review
      did NOT prove*: **whether an amd64 instance can land above 4 GiB at all.** That is the
      gate on the whole hazard: §13.2(b)'s refusal turned a silent truncation into an honest
      abort, but nobody has put an instance up there and watched one round-trip.

- [x] **0.6b — the third seam. DONE 2026-08-27**, `smoke-openbios.sh mmio-writer`, and it
      gave the third distinct answer as predicted — but **not at a PCI BAR**, because there
      isn't one to aim at. See 0.6c/0.6d, both found by trying. *Original text:* The NVDIMM answered *"memory the firmware
      does not own"* and CFI flash answered *"command-sequenced device"* — a BAR is neither.
      The `vga` track already reaches `QEMU,VGA@2`'s `assigned-addresses`, so the address is
      available without new plumbing. **Expect a third distinct answer**, not a repeat of
      either: a framebuffer accepts stores like RAM but is observed by a device rather than
      by a file, so the assertion has to come from outside the firmware some other way
      (QEMU's `screendump` is the obvious candidate, and it has not been tried).

- [x] **0.6c — FIXED 2026-08-27**, [patch 33](examples/openbios-the-rival-that-shipped/patches/33-first-memory-bar-got-address-zero.patch).
      **Not a window-size problem, and not an amd64 one** — both framings above were wrong.
      `drivers/pci.c:2125` seeds its allocator with `mem_base = arch->pci_mem_base`, and
      x86's and amd64's `default_pci_host` **omitted the field**, so it was 0 and the FIRST
      memory BAR was programmed with address 0. Every later BAR looked fine because
      `mem_base` had advanced past it — which is why it survived. ppc and sparc64 both set
      it already, with the comment *"avoid VGA at 0xa0000"*. Now `.pci_mem_base = 0x40000000`
      on both, and `BAR0: 32 bit prefetchable memory at 0x40000000 [0x40ffffff]`.
      **Bit 31 deliberately clear**: `0xC0000000` would put it into every BAR address and
      trip §13.2(a)'s `a-signbit-boot` guard — the guard would be working, and forcing that
      decision as a side effect of a BAR fix is what would be wrong. Verified after:
      `a-signbit-boot=0` still.
- [x] **0.6d — FIXED 2026-08-27**, [patch 34](examples/openbios-the-rival-that-shipped/patches/34-pci-bus-cell-counts.patch).
      Independent of 0.6c, as the measurement showed. **A PCI bus never declared its cell
      counts.** `#address-cells`/`#size-cells` are written from `pci_dev->acells`/`->scells`
      and **nothing in `pci_database.c` assigns either field, on any entry**;
      `host_config_cb` is never reached here at all, because QEMU's i440FX is not in the
      database (*"Cannot manage 'PCI host bridge' … 8086 1237"* in every boot log) and the
      generic subclass row has a `NULL` callback. So `my-#acells` fell back to its
      no-property default of **2** for every child of a PCI bus.

      **The C side always encoded three cells** (`pci_encode_phys_addr` writes
      phys.hi/mid/lo), so `reg` and `assigned-addresses` were right on disk the whole time.
      The **Forth decode side read two where three were written** — a silent stack shift, not
      an error: `pci-bar>pci-addr` is commented `( reg prop prop-len phys.lo phys.mid
      phys.hi )`, receives one fewer, and its `6 pick` reaches past the operand it wants.

      After, on both arches: `my-#acells` 3, `pci-bar>pci-addr` leaves exactly 5,
      `" screen" open-dev` returns an ihandle, `frame-buffer-adr` = `40000000`, **0
      exceptions**. The `vga` track now asserts cause and effect separately — it had only
      ever checked that the alias *resolved*, which is not the same as being able to use it.

- [x] **0.6e — the type layer. DONE 2026-08-29**, `smoke-openbios.sh struct-layer` +
      [`dsl/struct.fth`](examples/openbios-the-rival-that-shipped/dsl/struct.fth). This is
      [`REVIEW-preboot-forth-as-a-poke-engine.md`](REVIEW-preboot-forth-as-a-poke-engine.md)'s
      **G2**, the item that review put at the top of its own list once §16 closed F2.
      **And the review was wrong about where it starts**, which measuring first is what
      found: it recommends building a definer with `create ... does>`, and OpenBIOS
      **already ships one** — `forth/bootstrap/bootstrap.fs:1570` has
      `: field create over , + does> @ + ;`, working at the untouched prompt (`size`=7,
      offsets 0/4/6, measured on amd64 before a line was written). The section had been
      written from a `git grep` of *this repo*, which is a question about the lab standing
      in for a question about the firmware — the same substitution `check-harness-net.sh`
      made twice. What was actually missing is **width and byte order**: `field` carries an
      offset and nothing else, so every read restates the type by hand. Both of G2's
      checkpoints are met on both arches, the layer parses a real ELF64 header against host
      ground truth, and **seven injections were run and all seven bit** — the fourth
      exposing a defect in the assertions themselves (three rows asserted a refusal
      *printed its name*, which is the mechanism; the outcome is that the operation did not
      complete).

- [x] **0.6f — arrays, and a layout over a live device. DONE 2026-08-30**,
      `smoke-openbios.sh struct-array` + `struct-device`, closing the two items
      [`REVIEW-preboot-forth-as-a-poke-engine.md`](REVIEW-preboot-forth-as-a-poke-engine.md)
      still listed under *What this review did NOT prove* after 0.6e. **Arrays**
      walk the ELF64 program-header table of a real image on both arches, checked
      against the SUBJECT (`/elf64-ehdr` == the file's own `e_ehsize`) rather than
      constants, and graded by a sum the firmware derives. **The device half
      produced [patch 49](examples/openbios-the-rival-that-shipped/patches/49-device-register-words-were-empty.patch):**
      IEEE 1275 §5.3.7.2's six device-register words had bodies containing **no
      words at all** — `b8000 rb@` returned `b8000`, `42 b8002 rb!` left depth 2
      having stored nothing — and `forth/device/table.fs:390-395` binds FCode
      tokens `0x230`-`0x235` to them, so it presents as a **stack shift inside a
      driver**, the same shape as patches 25 and 34.
      **And the two arches disagree, which is the finding worth keeping:** on
      amd64 the typed device write reaches physical `0xb8000` and the screen; on
      x86 the identical code reads back `1f41` through Forth and never reaches the
      device, because `arch/x86` rebases the GDT. That row is asserted
      **positively** rather than skipped — the cheap check caught lying, in the
      same run as the arch where it tells the truth (§13.3(A) from a third
      direction). Five injections, five bites; reverting **all six** words does
      not reach the named row at all — it overflows the Forth stack, which is the
      write half's real failure mode.

**What NOT to re-derive**, because each cost a run and is written up in §16:

| | |
|---|---|
| a Forth address is **not** a physical one on x86 | the GDT rebase; `ffbe0000` stores land in RAM and read back convincingly. §13.3(A)'s fact from the other side |
| the prompt prints the **stack depth** | `--expect "0 > "` hangs forever whenever a cursor is deliberately left on the stack. Caught three times in one night |
| the console **echoes the command** | `r0=" fw @ …` precedes `r0=ff ff ff`, so a value extraction that allows a space after the `=` matches the echo |
| a fault in a **shared** word is not scoped | breaking `int!` breaks every property in the device tree, and the generic gate fires instead of the named one. Inject into a word with no in-tree callers, or scope the fault to a value the tree never uses |
| the console **paints the VGA screen too** | it scrolls, so a small write at row 0 is gone by the next prompt, and a raw image diff is swamped by echo. Fill the whole buffer, and assert on a **colour the console never produces** |

---

## 0.5 The queue after §0 drained — what is actually next (2026-08-08)

§0.1–0.4 are all closed, so this section replaces them as the front of the queue. It is
grouped by **what each item is blocked on**, because that is the only thing that decides
which can be picked up tonight and which cannot be picked up at all here.

### Not blocked — buildable now

- [x] **A.3** ✅ **DONE 2026-08-17** — **phases 3, 4 and 5 now have a per-service
      `start`**, symmetrical with phase 2's and phase 7's, and their `up` stays what
      it always was: create-if-absent.
      *The gap:* against a **stopped** container `lab-podman.sh up` logs
      `[warn] service 'web' container exists (…); leaving as-is` and returns **0**,
      and none of the three had any other verb that could run one — so a stopped
      container was a state **no phase-6 verb could repair**. Found by
      [`phase6-tui/tests/test_apply_live.py`](phase6-tui/tests/test_apply_live.py)
      driving rootless podman for real; invisible to every earlier assertion about
      `apply`, because those ran against injected backends and a fake converges
      when the fixture says so.
      *The fix went where the gap was* — into the drivers, not into `apply`.
      Phase 6 reaching around a driver to `podman start` would have put a **second
      owner on one lifecycle**, which is the stale-record shape this repo keeps
      finding; `held_for_want_of_a_verb` stays as the general rule for a slot that
      still has nothing (only `chroot`, which has no run state).
      *Each `start` asserts the OUTCOME*, not the engine's exit status: it reads the
      state back afterwards, so a container whose entrypoint exits immediately is a
      **FAIL**, not a `PASS` — REVIEW-phase7.md P7-4's lesson (`PASS: started` over a
      VM that never booted) carried across before it could recur. Watched to bite in
      `phase3-docker/tests/test-start-verb.sh` and `phase4-podman/tests/test-start-verb.sh`.
      *Not verified live for LXD* — ✅ **now verified, 2026-08-20.** The half behind
      `LAB_LXD_LIVE=1` was an **UNKNOWN** because launching an instance on this host
      manufactures the Appendix F.6 bridge-capture hazard. **The blocker was the
      cluster's configuration, not the test**: `IP_AUTODETECTION_METHOD` was
      `first-found`, so any addressed bridge at a higher ifindex could take the tunnel.
      Pinned to `interface=enx00051b8eb138`, then run:
      [`test-start-verb.sh`](phase5-lxd/tests/test-start-verb.sh) and
      [`test-export-tarball.sh`](phase5-lxd/tests/test-export-tarball.sh) both **PASS**,
      and a 2-second witness over the whole run — 135 samples, 4m28s, spanning four
      60 s autodetection intervals — recorded **one** binding.
      The control is that the hazard was **neutralised rather than removed**: `incusbr0`
      (idx 86) and `lxdbr0` (idx 92) were still up with their addresses throughout, so
      the pin is what ignored them, not an absence of candidates.
      *Which makes this the second entry in this file to have carried a blocker that was
      not what it said* — see C.2. The stated blocker was "launching an instance"; the
      real one was one unpinned environment variable.

- [x] **A.4** ✅ **DONE 2026-08-20 — and the entry was wrong about two of its three
      phases.** Closed as *"a restore hands back a running container"*: phases 3 and 4's
      `inspect` report `command`, `entrypoint`, `entrypoint_source`, `env` and `workdir`
      at **`schema_version: 2`**;
      [`preserve.sh`](examples/micro-cloud/preserve.sh) writes the argv into
      `derivation.toml`; and `restore` prints the command that starts it, filled in from
      what was recorded. Measured end to end against live rootless podman: the image
      alone still dies at `no command or entrypoint provided`, and the line `restore`
      now prints comes back `Up 1 second  /bin/sleep 600`.

      **The premise was re-derived before anything was written, and it did not survive.**
      This entry said *"no driver reports a container's argv (`inspect` renders labels,
      state, userns and network, and no command)"*. Phases 3 and 4 had reported
      `container.command` all along — **wrongly, in two different ways, neither visible to
      a green suite**:
      - **docker** read only `Config.Cmd`, so an `ENTRYPOINT`-only container was reported
        as having **no argv at all**. Its own SHOWCASE published that empty array as the
        sample output for an *nginx* container, for months. An empty field where the
        answer is unknown reads as *"there is nothing here"* — the quiet half of the liar
        case, and the reason `entrypoint` had to be a separate field rather than a better
        `command`: only then is `command: []` a **true** statement.
      - **podman** read `Cmd // Entrypoint // []`. jq's `//` rejects only `null` and
        `false`, so the fallback could never fire for a `Cmd` of `[]` — and when `Cmd`
        *was* null it supplied podman's **joined string**, making `container.command` a
        string for one image and an array for the next, inside a document whose header
        calls it *"a stable schema_version=1 surface that the Phase 6 TUI can rely on"*.

      **Phase 5 is not in scope, and that is a finding rather than a narrowing.** An LXD
      instance runs the image's own init — `lab-lxd.sh` already refuses a `command` key
      **by name** with that explanation — and its `from-tarball` backend synthesises
      `metadata.yaml`, so a restored LXD image *launches*. Phase 5 has neither the field
      nor the defect; a `command` row there would report `[]` forever, which is the shape
      this item exists to remove. So `docker`/`podman` moved to 2 and `lxd` stayed at 1,
      as did podman's **pod** document — a bump on a document that did not change is a
      false statement about it, and `kind` is the discriminator that lets each version on
      its own evidence.

      **The engines disagree about the shape, and the fix is a provenance row rather than
      a split.** Measured: docker 29.7.1 gives `["/bin/sleep","600"]`; podman 4.9.3 gives
      `"/bin/sleep 600"`. A joined string cannot be re-split without guessing —
      `["/bin/sh","-c","sleep 900"]` and `["/bin/sh","-c","sleep","900"]` flatten
      identically and are different programs — so the array is recovered from the
      **image**, and accepted only when re-joining it reproduces the container's string.
      `entrypoint_source` (`engine-array` · `image-verified` · `joined-string` · `none`)
      travels with the value because it decides whether the value may be replayed. Both
      controls were run: a container started with `--entrypoint` is **not** described
      using its image's argv, and an unsplittable entrypoint comes back as the one string
      it is known to be.

      **A control caught the test rather than the code.** The first version of
      `test-preserve-round-trip.sh`'s new section compared the revived container's argv
      against the argv it had just read out of the **manifest** — the record against
      itself. Sabotaging `preserve.sh` to record `["sleep","999"]` for a container running
      `sleep 600` produced a wrong manifest, a faithful replay of the wrong value, and a
      green **PASS**. The property is *"the record matches what was preserved"*, so the
      test now captures the original's argv from the engine before anything is destroyed
      and compares against **that**. Three controls fire, each on its own assertion: no
      record, wrong record, record ignored.

- [x] **A.1** ✅ **DONE 2026-08-15** — the cross-node CHAOS ROWS for
      [`examples/nested-calico-sandbox/`](examples/nested-calico-sandbox/README.md#the-cross-node-rows--f6-with-a-witness):
      `cross-node-chaos.sh` + `guest-xprobe.sh`, graded by `tests/test-cross-node-chaos.sh`,
      with `tests/test-cross-node-grader.sh` making all 18 of its branches bite against a real
      record in ~2 s with no cluster. Both rows measured **DEGRADED**, and the witness saw
      three things one node could not: the overlay **falls through to the default route** when
      its device is deleted; the F.6 row's outage (**17–55 s** across seven runs — Calico
      re-detects on a timer, so the duration is a spread and is recorded as one) was spent
      **essentially entirely with the cluster reporting both nodes `Ready`**; and the cluster
      keeps **two** records of a node's address, of which only Calico's tracked — kubelet's
      `InternalIP`, the one `kubectl get nodes -o wide` prints, kept naming an address that no
      longer existed.
      The rung is decided by **packets lost** rather than by a post-injection sample: that
      sample races the CNI's recovery (a 1 s rebuild against a 3–4 s probe) and losing the race
      would have scored ABSORBED. The 1-per-second witness caught an outage the sampler missed
      entirely — `LIEWINDOW=0` beside `LOSS=4/90` in one run.
      The row had to be designed twice: **`cidr=` does not prefer a higher ifindex the way
      `first-found` does**, so the decoy injector that works in the one-node matrix never
      lands here (205 s, and a full `calico-node` restart, with the decoy ignored).
- [x] **A.2 — the k8s-dqlite row** — ✅ **DONE 2026-08-08**, *the same day this section was
      written*, and this entry named the fix as its own precondition: *"buildable only if the
      dataplane observable stops being `kubectl exec`"* is exactly what was done.

      It is **row 7 of 9** in [`cni-chaos.sh`](examples/nested-calico-sandbox/cni-chaos.sh)
      (`ROW=datastore-stopped`). The blocker was specific rather than fundamental: a CNI does
      not need the API to *forward a packet* — once a pod is running its connectivity is
      felix's netfilter rules, Calico's per-pod host route and the pod's veth, all kernel
      state — so the row is graded on the pod's address pinged **from the node**, captured
      while the API was still up, and no API is consulted after the fault.

      **Measured ABSORBED:** with `snap.microk8s.daemon-k8s-dqlite` stopped and `/readyz`
      refusing, the pod stayed reachable; restarting the unit brought the API back in **21 s**.
      *A datastore outage costs you every API call and not every workload* — a property
      operators assume and rarely verify.

      Guarded without a cluster: `tests/test-cni-chaos-grader.sh` carries the row's own
      negative controls (mutating `MID_NOAPI`/`AFTER_NOAPI` must be caught), so its grading is
      checked on every run in ~2 s rather than on the day someone spends 20 minutes on a live
      matrix.

      **Weaker, not missing, and stamped as such:** the observable crosses **one** veth
      (node → pod) rather than two (pod → pod), recorded in
      [`findings.env`](examples/nested-calico-sandbox/findings.env) as
      `NCS_DATASTORE_OBSERVABLE_IS_NODE_TO_POD=one-veth-not-two` rather than presented as the
      same measurement as the other rows.

> ~~**§0.5's "buildable now" list is now empty**~~ — **that sentence was false for two days
> and nothing noticed.** Written when A.1 landed (2026-08-15), it asserted a property of the
> *list*; **A.4 was then filed into the list directly above it on 2026-08-18** and the
> sentence went on saying the section was empty. A summary line claiming a section is empty
> is precisely the thing that stops a reader opening it — so an item nobody was blocked on
> sat unread behind a line that said there was nothing there.
>
> That is C.2's mistake pointed the other way, in the same file that names it: C.2 attached a
> **blocker that was not real** to finished work; this attached an **emptiness that was not
> real** to unfinished work. Both stop the next reader for the same reason — a status line is
> read *instead of* the section, not alongside it.
>
> **The fix is not a better sentence, it is no sentence.** A restated count is a cached fact
> about a list that is sitting right there; whatever number is written here will be wrong the
> next time an item is filed, and the person filing it has no reason to look up. **Count the
> unticked boxes.** What can be said without rotting is the history, so that is all that is
> said now: A.1 landed 2026-08-15, A.2 on 2026-08-08, A.3 on 2026-08-17, A.4 on 2026-08-20.
>
> A.2 was the **fifth** entry found that week whose subject had closed underneath it (see the
> four in §4, §8, §0.5 C.2 and micro-cloud's `DEFERRED.md`), and it shares their shape
> exactly: written the same day the work landed, describing the solution, never ticked.

- [x] **A.5** — **four files the micro-cloud docs promised and did not have.** ✅ **DONE
      2026-08-23** — all four resolved: two written, one built and booted, one deliberately
      NOT built. Found 2026-08-20 while fixing two of them, and the interesting part is
      *why nobody noticed*.
      `RUNBOOK-first-microvm.md` was cited by [`learning-paths.toml`](examples/learning-paths.toml)
      as **step 1's checkpoint** — the entry point of the whole journey — and had never
      existed; it is now written and every command in it was run before it was written.
      `RUNBOOK-build-images.md` was cited by
      [`micro-cloud.toml`](examples/micro-cloud/micro-cloud.toml) and should **not** be
      built: its content is
      [`RUNBOOK-micro-cloud.md` step 0](examples/micro-cloud/RUNBOOK-micro-cloud.md), and a
      second copy is the duplicate-doc defect. Both citations are re-pointed.
      **Two of the three landed 2026-08-23.**
      [`CLONES.md`](examples/micro-cloud/CLONES.md) — the §4.1 reuse ledger, and its entry is
      a **measurement**: `git grep -niE 'forked from|clone of|copied from|adapted from'` over
      the lab returns no file declaring a fork, so there are no rung-4 clones, and the four
      hits it does return are about *values* being derived (a MAC from a name) rather than
      code. It also records what §4.1 asks for and **does not yet exist** — the test that
      fails when a file declares a fork and is not listed — because an unenforced ledger and
      an enforced one look identical on the day they are both correct.
      [`UPSTREAM.md`](examples/micro-cloud/UPSTREAM.md) — cite-don't-mirror provenance, with
      every URL **fetched and 200 before it was written down** (this repo has enshrined an
      error page's sha256 as "the tutorial" once) and the staged binary's sha256 computed
      from its bytes, labelled as *what these transcripts ran against* rather than as a claim
      about what upstream publishes, since the release's own `.sha256` was not compared.

      **`hand-walk/` landed 2026-08-23, built AND booted** — the repo's rule, and the reason
      it was not knocked out alongside two markdown files.
      [`examples/micro-cloud/hand-walk/`](examples/micro-cloud/hand-walk/RUNBOOK.md): a
      Debian box driven through **phase 4** (`build =` context + a `devices` key for
      `/dev/kvm`) — no one-off `podman run`, which is the repo's rule and needed no exception
      here. Verified by running it: `curl` the REST API over a unix socket, two PUTs and an
      `InstanceStart`, and the guest reached an **Alpine login prompt at `uptime=0.04s`
      inside a rootless container**. That transcript is what the RUNBOOK quotes.

      Two things the image deliberately does **not** contain, and both are decisions rather
      than omissions: the `firecracker` binary (a `RUN curl … && chmod +x` would be
      fetch+exec of a prebuilt toolchain one layer down, so the pinned v1.16.1 is
      bind-mounted — the box runs the binary the lab measured, not whatever is newest on
      rebuild day) and the kernel + rootfs (lab **output**; an image carrying them starts
      going stale against the thing that produces them).

      **Networking stays author-run**, named rather than quietly skipped: a tap needs
      `CAP_NET_ADMIN`, which this box does not have and should not be given — the host runs a
      live Calico cluster whose tunnel endpoint a stray tap has captured before. Same
      partition `phase1-chroot/hand-walk/` documents for `binfmt`.

      Routing caught one thing worth recording: `paths.py --check` passed **before** the
      hand-walk was added to the `tutorial-hand-walks` collection, because micro-cloud itself
      is already routed. A green coverage gate therefore did *not* mean the new unit was in
      the by-journey view built for it — it is now.

      **What is left of this entry is a wish, not a task, and that is why the box is ticked.**
      §4.1 also asks for a test that fails when a file declares a fork and is not listed in
      `CLONES.md`. No such file exists today (the ledger's entry is a `git grep` result), so
      there is nothing to gate and no way to know the gate works. It is recorded where the
      person who would need it looks — [`CLONES.md`](examples/micro-cloud/CLONES.md)'s *"what
      is NOT yet enforced"* section — rather than held here as an open box.

      **An unticked box should mean schedulable work.** Leaving this one open made the list
      read as five items when two were real, which is §0.5's own complaint about a status
      line being read *instead of* the section it heads.
      *Why the checkers were green the whole time:* all four were cited as **bare filenames
      in prose and in ASCII tree diagrams inside code fences**.
      [`link_check.py`](tools/link_check.py) validates markdown *links*; a filename in a tree
      diagram is not a link, exactly as a filename in a sentence is not.

      **The checkable version now exists**:
      [`tools/check-tree-diagrams.sh`](tools/check-tree-diagrams.sh), gated in the `docs` job
      — §16 q6's *"what else in this document describes something that does not exist?"* made
      mechanical. Measured: **58 entries across the 5 documents whose trees describe this
      repo**, all present; **34 further tree blocks declined and named**, because a tree
      rooted at `/srv/tftp/` or at a flowchart label describes something that is not this
      repo.

      Four false-positive classes had to be measured away first, and each was found by
      running it rather than by thinking about it: **box-drawing diagrams** share the `└──`
      corner glyph (the first run reported 100+ fragments of ASCII art as missing files);
      **one fence can hold several trees** separated by a blank line, and without resetting
      the root, PLAN-PXEBOOT.md's second tree was checked against the first tree's directory;
      **the root may be the document's own directory** (`tools/README.md` roots at `tools/`,
      which resolved to the repo's top-level `tools/` and reported six files missing from a
      directory nobody claimed them to be in); and — the one worth remembering — **an entry
      already marked `⚠ NOT BUILT` is not a broken promise, it is the fix**, so the first run
      reported all four A.5 files, every one already carrying the marker. A checker that
      punishes the remedy it recommends is worse than no checker.

### Blocked on hardware — recorded so it stops being re-raised as if it were schedulable

- **C.1 — metal-as-a-service `image` / `image+measured` drivers on REAL hardware.**
      Detail in [`examples/metal-as-a-service/DEFERRED.md`](examples/metal-as-a-service/DEFERRED.md).
      Everything that can be proven under emulation has been; what remains needs a machine
      with a real BMC, and no amount of local work advances it.
      **NOT A CHECKBOX, deliberately.** This is not undone work; it is work this host cannot
      do, and an empty box invites someone to pick it up, re-scope it and defer it again —
      the churn this section exists to prevent. It carries a date instead.

      **Blocker re-verified 2026-08-23** — this section's own rule is that a blocker is
      checked before it is restated, since C.2 sat behind a wrong one for eight days. Still
      held: `DEFERRED.md` names the requirement as real hardware with a BMC, and this host
      has none. Nothing in the emulated path has become the missing evidence.
- [x] **C.2 — the rollback-pair corruption case** — ✅ **DONE 2026-07-28 (night)**, and it
      was **never blocked on hardware**: it is a registry-write ordering defect, fixed
      headlessly and regression-locked headlessly. The `(driver, image)` pair is now only
      ever written **when a gate passes**, so a failed deploy leaves the last verified pair
      untouched and there is no pre-gate write for a future failure branch to forget to
      undo; the in-flight driver lives in a transient `deploying_driver`. Guarded by
      [`tests/test-rollback-driver-pair.sh`](examples/metal-as-a-service/tests/test-rollback-driver-pair.sh)
      §4+§7, written red-first — §7 **replays the live incident** (both slots bad, then a
      successful redeploy) and asserts the recorded previous pair is the real one.

      **This entry was stale the day it was filed.** §0.5 is dated 2026-08-08; the fix
      landed eleven days earlier and
      [`examples/metal-as-a-service/DEFERRED.md`](examples/metal-as-a-service/DEFERRED.md)
      had struck it through. Worse than merely stale: *"same blocker"* attached a hardware
      excuse to work that needed none, which is the one framing guaranteed to stop anyone
      looking. Only **C.1** is hardware-blocked.

**Why C.1 is listed as blocked rather than left in the general list.** A hardware item
sitting in a queue of software items reads as "not done yet" and gets re-picked,
re-scoped, and re-deferred. It is not undone work; it is work this host cannot do. Naming
the blocker is the difference between a queue that drains and one that accumulates.

**And the converse, which C.2 just demonstrated:** naming a blocker that is not real is
worse than naming none. A wrong blocker does not merely fail to help — it *actively*
stops the next reader from looking, because "blocked on hardware" is a reason to skip an
entry without opening it. C.2 sat behind that excuse for eight days having been finished
for eleven. Check that a blocker still holds before restating it, exactly as this repo
requires of any other cached fact.

### Not blocked, but deliberately deferred

- [ ] **B.1 — build [`RESILIENT_REGION_LAB_PLAN.md`](RESILIENT_REGION_LAB_PLAN.md)** — v1.1
      **BUILD-READY** as of 2026-08-08, all four §9 decisions resolved. First increment:
      `region.sh` + the two host-safe chaos drills.
- [ ] **B.2 — build [`SECURITY_RANGE_LAB_PLAN.md`](SECURITY_RANGE_LAB_PLAN.md)** — v1.1
      **BUILD-READY** as of 2026-08-08, all four §9 decisions resolved including the
      charter boundary and the directory name (`examples/security-range/`). First
      increment: the spine + S2.
- [ ] **B.3 — build [`PREBOOT_STRUCTURE_TOOLKIT_LAB_PLAN.md`](PREBOOT_STRUCTURE_TOOLKIT_LAB_PLAN.md)** —
      v1 (2026-09-01), feasibility checked before writing (CBFS is BE `'ORBC'`; the two
      `struct.fth` primitives are genuinely absent; a real `coreboot.rom` exists to
      dissect). A preboot TLV toolkit over the four OpenBIOS arches as an
      endianness×width control. **Spike 0 is the gate** (`vfield:`/`alignto` + the
      static-offset-vs-cursor decision); then the TCG event log (attestation without a
      TPM, stopping honestly at the quote) and coreboot CBFS. Extends
      `examples/openbios-the-rival-that-shipped/`; enabled by §20's `write-file`, mapped
      by §21's gleanings.

## 1. Crack the FLOPPINUX login hash (educational security exercise)

Demonstrate, **on our own throwaway lab artifact**, how weak a classic `$1$`
(MD5-crypt) password is. The 2.88 MB FLOPPINUX QoL + login build (`LOGIN=1`)
ships this account in `/etc/passwd`:

```
root:$1$floppinx$2WKWnHcP/VZpbTpD57PW30:0:0:root:/home:/bin/sh
```

The plaintext is already known (`lab`) — the point isn't to *learn* it, it's to
show the recovery and explain the *why*.

- [x] Recover `lab` from the hash with `john` and/or `hashcat` + a small wordlist
      (e.g. rockyou); time it and record the exact command + wall-clock.
- [x] Write up the WHY: `$1$` = MD5-crypt (1000 iterations, 8-char salt
      `floppinx`); why it's trivially crackable on a modern GPU/CPU versus `$6$`
      (SHA-512-crypt) or bcrypt/argon2; what the salt does (kills rainbow
      tables / shared-hash detection) and does **not** do (slow a targeted
      guess).
- [x] Lab-hygiene takeaway: a published throwaway credential is fine for an
      air-gapped floppy in QEMU — and is exactly why you never ship `LOGIN=1` on
      a real network.
- [x] Land it as a short doc under the lab (e.g.
      `examples/tiny-linux-experiments/floppinux/HASH_CRACKING.md`), linked from
      that README and `00-INDEX`.

Scope: our own hash, our own lab, educational — not targeting any third party.

**✅ Done 2026-07-23.** [`HASH_CRACKING.md`](examples/tiny-linux-experiments/floppinux/HASH_CRACKING.md)
+ a self-contained [`crack.py`](examples/tiny-linux-experiments/floppinux/crack.py)
(pure-Python md5crypt — works on 3.13+ where `crypt` is gone; no install/network).
Recovers `lab`: recompute-verify (`openssl passwd -1` byte-matches), dictionary
(15-word list, **3.2 ms**), exhaustive `[a-z]³` (7438/17576, **~2.1 s** single-thread
pure-python; a compiled `crypt(3)` ~4× faster, john/hashcat millions/s). WHY
written up (MD5-crypt = 1000 MD5 rounds = fast; salt kills rainbow tables + shared-
hash detection but does NOT slow a *targeted* guess; `$6$`/bcrypt/Argon2 table).
Linked from the lab README (Files + ⚠️ Security) and 00-INDEX; `john`/`hashcat`
commands documented (author-run — not installed here). link_check green.

## 2. Vendor an `upstream-tutorial/` copy for every tutorial-based lab

Promote the FLOPPINUX pattern to a **repo-wide convention**: any lab that
operationalizes an external write-up keeps a byte-exact, attributed archive of
that source *alongside* the operationalization — so the lab is reproducible
offline and its provenance is explicit.

Exemplar to copy:
[`examples/tiny-linux-experiments/floppinux/upstream-tutorial/`](examples/tiny-linux-experiments/floppinux/upstream-tutorial/)
— vendored HTML/CSS, a provenance table (title / author / canonical URL /
retrieved date), per-file `sha256`s, and a copyright/attribution note.

- [x] Audit `examples/` for labs derived from a *specific* external tutorial or
      blog post (candidates to confirm: the PXE / netboot labs, the
      kickstart / preseed galleries, the `kali-*` builders).
- [x] For each, add an `upstream-tutorial/` dir with the vendored source + a
      README matching the floppinux exemplar (provenance, `sha256`s, attribution).
- [x] Where a lab follows *official docs* rather than one page, capture the exact
      URLs + retrieval date + a note instead of mirroring whole doc sites.
- [x] Record the convention in [`CLAUDE.md`](CLAUDE.md) so future labs follow it.
- [x] Keep `tools/link_check.py` green (0 broken links) after every add.

**✅ Done 2026-06-07.** Six single-write-up labs vendored byte-exact under their
own `upstream-tutorial/` (HTML + CSS + `sha256`s + attribution, parent README
linked): five under `examples/` — `debian-http-boot/` & `almalinux-pxe-lab/` &
`rocky-pxe-lab/` (Kenneth Finnegan / CIQ write-ups), `kali-llm-lab/` &
`kali-llm-desktop-lab/` (the Kali Ollama+5ire blog, byte-identical copy in each
per self-containment) — plus `micro-linux/` (Uros Popovic's post; see the
*Closed* note below). Seven official-docs / upstream-wrapper labs got a dated
provenance note (URL + as-of date, not mirrored): `kali-pxe-lab/`,
`kali-preseed-gallery/`, `rocky-kickstart-gallery/`,
`ansible/almalinux-infra-ansible/`, `kali-nonroot-chroot/`, `offsec-awae-vm/`,
`kali-vm-builder/`. Convention recorded in `CLAUDE.md` › *Provenance*.
`link_check.py`: 0 broken.

**Closed 2026-06-07 (the two out-of-`examples/` items, once the user supplied
the URLs):**
- **`micro-linux/`** — full-vendored: Uros Popovic's *"Making a micro Linux
  distro"* (<https://popovicu.com/posts/making-a-micro-linux-distro/>, published
  2023-09-21) archived byte-exact under `micro-linux/upstream-tutorial/` (HTML +
  3 CSS + provenance + `sha256`s); linked from `micro-linux/README.md` and the
  plan's status line — which finally gives the plan's ~20 "the source post"
  references a resolvable canonical URL. The archive README notes the deliberate
  "adaptation in the spirit of" divergence (plan §1.1 / §11).
- **`phase1-chroot --rootless`** — full-vendored (a phase feature, but archived
  for parity at the user's request): Alex Bradbury's *"Rootless cross-architecture
  debootstrap"*
  (<https://muxup.com/2024q4/rootless-cross-architecture-debootstrap>, published
  2024-12-03) archived byte-exact under `phase1-chroot/upstream-tutorial/` (a
  single self-contained HTML — inline CSS + inline `data:` SVG — + provenance +
  `sha256`). Linked from `phase1-chroot/README.md`; the exact URL is also in the
  two PLAN.md mentions.

## 3. Container lab to hand-implement each upstream tutorial

Stand up a disposable container (Docker / Podman / Incus / LXD — chosen per
tutorial) that gives a clean, repeatable environment to **walk each upstream
tutorial by hand, step-by-step** — distinct from the automated `build-*.sh`
operationalization. Value: a sandbox to learn the recipe manually, and a way to
catch upstream drift against our scripts.

- [x] Pick the runtime per tutorial (rootless Phase-4 podman for all seven;
      `--cap-add SYS_ADMIN` where `binfmt`/chroot needs it; the author's distro
      as base where the tutorial is distro-specific).
- [x] Reuse the existing phases instead of one-off containers: each `hand-walk/`
      ships a `Containerfile` driven via `lab-podman.sh build`/`up` (`build =`).
- [x] Per tutorial: a `Containerfile` + a `RUNBOOK.md` pointing at the
      `upstream-tutorial/` copy from item 2, + a 00-INDEX entry + parent inbound link.
- [x] ~~Start with FLOPPINUX~~ → **started with micro-linux instead** (fully
      unblocked: apt cross-toolchain, pure TCG, no devices, no fetch gate — the one
      lab the agent can build *and* boot to verify end-to-end). FLOPPINUX turned out
      to be the *worst* first pick: it hits **both** the `musl.cc` fetch gate **and**
      loop-mount/`mknod` (blocked in-sandbox even `--privileged`) — both are
      author-only. (The TODO's "container sidesteps the gate" claim is **half-true**:
      the layer is a clean artifact, but an *agent-triggered* `podman build` of a
      musl.cc fetch is still gated — the classifier reads the Containerfile; the
      *user* runs that build.)
- [x] Catalog the container labs in [`examples/00-INDEX.md`](examples/00-INDEX.md)
      (§ *🚶 Hand-walk the tutorials*).

**✅ Done 2026-06-08.** Seven `hand-walk/` sandboxes, each = Containerfile (the
author's environment as code) + RUNBOOK (the post by hand, with the *why*) +
00-INDEX entry + parent inbound link; `link_check.py` green. Split by what the
build sandbox can run:
- **Agent built + boot/run-verified end-to-end:** `micro-linux/` (kernel→`init.c`→
  u-root boots), `phase1-chroot/` (muxup rootless foreign debootstrap, `uname -m
  → riscv64`), `examples/debian-http-boot/` (fakeroot debootstrap + initrd + iPXE),
  `examples/almalinux-pxe-lab/` (iPXE EFI build + dnsmasq config).
- **Agent built env + verified the tractable parts; one step author-only:**
  `examples/rocky-pxe-lab/` (box + `lorax`/`dnsmasq`/`tftp` present; the **Lorax
  run** needs loop → host), `examples/tiny-linux-experiments/floppinux/` (Arch env
  verified; **musl.cc fetch + `mknod`/loop floppy** → host).
- **Authored, you-build:** `examples/kali-llm-lab/` (multi-GB Kali + model; Ollama
  is a fetch-and-exec you authorize — RUNBOOK §1 sha512-verifies it).

Convention recorded in `CLAUDE.md` › *Hand-walk sandboxes*. Three real prereq
gotchas the "reproduce the env" exercise surfaced + fixed: `libc6-dev-riscv64-cross`
(hosted-C cross), `build-essential` not bare `gcc` (iPXE host helper needs
`<stdint.h>`), `fakeroot`+`systempaths=unconfined` (rootless debootstrap `mknod` +
`unshare --mount-proc`).

## 4. Net-booted, RAM-resident infrastructure images (immutable infra; reboot = newest build)

Explore **stateless infrastructure nodes** that PXE/iPXE-boot a kernel + initramfs
**entirely into RAM** (the initramfs *is* the root fs — no OS on local disk), so a
**reboot re-pulls the latest image**: update centrally, reboot the fleet, done.
Where a role needs persistent data, the **OS stays ephemeral** and only the *state*
is mounted from elsewhere — local disk (a ZFS pool) or network storage
(iSCSI/NFS) — attached by `/init` or an early systemd unit, never baked into the
image. Boot transport is HTTP **and HTTPS**, so nodes can boot over a LAN *or* the
open internet.

This is the immutable-infrastructure / "golden image" pattern, and the repo
already has the load-bearing mechanic: [`examples/debian-http-boot/`](examples/debian-http-boot/)
boots a whole systemd Debian from a single gzipped-cpio initramfs over HTTP
(Kenneth Finnegan's hand-rolled `/init`). The work here is to grow that one trick
into *role-specific* infra images and the serving/state plumbing around them.

**Candidate roles (each a lab):**
- **AnyCast DNS node** — RAM OS + an authoritative DNS server; the **zone/record
  database is the state** (mounted from local disk or fetched at boot). Announce
  the anycast prefix (BGP via `bird`/ExaBGP) **only while healthy**, withdraw on
  failure — the point of anycast. Models Gandi's design (ref below).
- **CDN edge** — RAM OS + a local **ZFS pool** holding the cache/content
  (persists across reboots though the OS doesn't); cache/webserver (nginx/varnish)
  runs from RAM.
- **Lightweight package mirror** — RAM OS, the mirror tree mounted over **iSCSI**,
  webserver served from RAM. Rebuild the image whenever; a reboot picks it up.

**GRADUATED to [`RAM_INFRA_LAB_PLAN.md`](RAM_INFRA_LAB_PLAN.md) (2026-07-23).**
Flagship role **`examples/anycast-dns-ram/`** landed; two of the four new
mechanics are built + verified. Remaining roles/mechanics tracked in the plan.

**Sketch / sub-tasks:**
- [x] Boot path: iPXE chainloading kernel + initramfs over **HTTP and HTTPS** —
      already provided by the mature netboot pipeline (`netboot/`,
      `pxe-boot-mechanics/`); the RAM-infra labs reuse it.
- [x] **Image integrity (non-negotiable) — DONE & verified.** Payload signing +
      iPXE **`imgverify`** + A/B rollback: [`netboot/sign-payload.sh`](netboot/sign-payload.sh)
      + `build-ipxe.sh --imgverify --payload-trust`; proven 3/3 headless (signed
      boots, tampered rolls back, both-tampered refuses) in
      [`netboot/MANUAL_TESTING.md`](netboot/MANUAL_TESTING.md) §13. Closes **F2**.
- [x] Health-gated service announce (anycast) — **DONE & verified.** ExaBGP
      health-gate + bird2 collector in [`examples/anycast-dns-ram/`](examples/anycast-dns-ram/)
      (`demo-anycast.sh` → PASS: announce while healthy, withdraw on failure,
      re-announce on recovery).
- [x] Versioned / A-B images so a bad build rolls back by booting the prior one —
      **DONE** (the iPXE `imgverify` boot script's `current`→`previous` rollback).
- [x] Stateless-OS + externalized-state split (`/init` mounts ZFS/iSCSI/NFS) —
      **DONE.** **ZFS (cdn-edge)** verified ([`examples/cdn-edge-ram/`](examples/cdn-edge-ram/) —
      `demo-cdn-state.sh` PASS: a fresh OS imports a ZFS cache pool + serves the
      survivor content over HTTP). **network NFS/iSCSI (package-mirror)** —
      [`examples/package-mirror-ram/`](examples/package-mirror-ram/): the
      `||`-guarded `state-mount.sh` verified docker-free
      (`test-state-mount-guard.sh` PASS); the live mount is author-run (touches
      host-global kernel state; ready-to-run ganesha/tgt recipes shipped).
- [x] Build on existing foundations — flagship image spec
      [`anycast-dns-chroot.toml`](examples/anycast-dns-ram/anycast-dns-chroot.toml)
      debootstraps the stack; `micro-linux --baked` used as the verify spike payload.
- [x] Vendor the Gandi post + [`examples/00-INDEX.md`](examples/00-INDEX.md) entry —
      done for the flagship. (Hand-walk N/A: the Gandi post is a design overview,
      not a step recipe → cite+vendor, and `demo-anycast.sh`'s container already
      reproduces the environment.)

~~**Still open (follow-on passes):** the **cdn-edge-ram** (ZFS state) and
**package-mirror-ram** (iSCSI/NFS state) roles~~ — ✅ **BOTH DONE 2026-07-23**, per
[`RAM_INFRA_LAB_PLAN.md`](RAM_INFRA_LAB_PLAN.md) §4b/§4c: `cdn-edge-ram` **DONE &
verified** (`demo-cdn-state.sh` PASS — a fresh OS imports a ZFS pool a prior boot left
behind and serves the survivor content), `package-mirror-ram` **DONE** with
`state-mount.sh` verified docker-free by `tests/test-state-mount-guard.sh`.

*This line was already contradicted by its own section* — the two sub-bullets a dozen
lines above record both roles as done, and the plan it points at says so in bold. What
genuinely remains is **narrower and different**: the **live** NFS/iSCSI mount is
author-run, because a real network mount touches host-global kernel state on a dev box
that is itself serving NFS. That is a run, not a role.

**References:**
- Gandi, *Booting an anycast DNS network* (2019) —
  <https://news.gandi.net/en/2019/03/booting-an-anycast-dns-network/> (the
  10,000-ft view; **vendor when the lab is built**).
- Kenneth Finnegan, *Booting Linux over HTTP* (2020) —
  <https://blog.thelifeofkenneth.com/2020/03/booting-linux-over-http.html> —
  **already vendored** at [`examples/debian-http-boot/upstream-tutorial/`](examples/debian-http-boot/upstream-tutorial/);
  the RAM-root-over-HTTP building block.

## 5. AlmaLinux: demo + automated run (RHEL-family `rd.break`, mirror Rocky)

The AlmaLinux sibling of the Rocky root-password-reset work
([`setup-rocky-target.sh`](examples/root-password-reset/setup-rocky-target.sh) +
[`reset-demo-rocky.sh`](examples/root-password-reset/reset-demo-rocky.sh)) — a
hand-walk on-ramp + a hands-off serial-driven **`rd.break`** proof on a real
AlmaLinux 9. AlmaLinux is RHEL-family, so the method is identical to Rocky's
(dracut initramfs → `chroot /sysroot` → `passwd` → `touch /.autorelabel` → SELinux
relabel) and the scripts should port nearly verbatim — including the grub2 serial
char-drop fix (`serial-drive.py --char-delay 0.08`) and the **editor-append** for
`rd.break`.

**Primary / first subproject — port the kickstart gallery to AlmaLinux:**
- [x] `examples/almalinux-kickstart-gallery/` ported from
      [`examples/rocky-kickstart-gallery/`](examples/rocky-kickstart-gallery/):
      `fetch-kickstarts.sh` + `select-kickstart.sh` + the unified P4+P2 TOML +
      README + MANUAL_TESTING. Point it at AlmaLinux's upstream kickstart catalog
      (find the AlmaLinux equivalent of `rocky-linux/kickstarts`) and reuse
      [`examples/almalinux-pxe-lab/`](examples/almalinux-pxe-lab/)'s installer fetch
      (`vmlinuz`/`initrd.img`/`install.img`) the way the Rocky gallery reuses
      `rocky-pxe-lab/fetch-rocky-installer.sh`.
- [x] Same gallery patches as Rocky where needed (`shutdown`→`reboot`, unlock root
      via `--root-pw`, `/dev/vda` pinning if any kickstart hardcodes a disk).
      Provenance: a dated note (official upstream catalog → cite, don't mirror).
      *(AlmaLinux's were Packer kickstarts hardcoding `/dev/sda` → the `/dev/vda`
      rewrite is REQUIRED here, not the no-op it is for Rocky; gencloud install
      boot-verified end-to-end on KVM, root/lab, AlmaLinux 9.8.)*

**Then the reset pair (mirror the Rocky scripts):**
- [x] `examples/root-password-reset/setup-almalinux-target.sh` +
      `reset-demo-almalinux.sh` — build via the new gallery (`gencloud`),
      pre-stage (widen GRUB `--timeout` via `grub2-mkconfig`), then serial-drive the
      `rd.break` reset + verify *old-rejected / new-`uid=0`* with the relabel applied.
      *(VERIFIED end-to-end on KVM 2026-06-11, first attempt: Ctrl-n×3 to the BLS
      `linux` line carries over from Rocky; one AlmaLinux difference — gencloud bakes
      `bootloader --timeout=0`, a hidden menu, so the pre-stage also sets
      `GRUB_TIMEOUT_STYLE=menu`.)*
- [x] `almalinux.toml` in the reset lab, delegating to the gallery (mirrors
      `rocky.toml` / `kali.toml`); update `RUNBOOK-rd-break.md` (note AlmaLinux),
      the README matrix, MANUAL_TESTING; add a 00-INDEX entry; keep `link_check.py`
      green.

Exemplars: the just-built Rocky pair +
[`examples/rocky-kickstart-gallery/`](examples/rocky-kickstart-gallery/);
[`examples/kali-preseed-gallery/`](examples/kali-preseed-gallery/) (the gallery shape).

## 6. UEFI variant of each root-password-reset method

The lab already argues the reset is **firmware-agnostic** with a Debian
**BIOS + UEFI pair** ([`debian-bios.toml`](examples/root-password-reset/debian-bios.toml)
verified; [`debian-uefi.toml`](examples/root-password-reset/debian-uefi.toml) on
OVMF, author-run). Round that out: a **UEFI variant of every method/distro**, using
`debian-uefi.toml` as the exemplar — once you reach the GRUB editor the steps are
identical; only *getting to the menu* differs (OVMF shows its own phase first; on
EFI the loader may be systemd-boot, also `e`).

- [x] Verify the existing [`debian-uefi.toml`](examples/root-password-reset/debian-uefi.toml)
      end-to-end (currently author-run) — reach GRUB over serial under OVMF, run the
      `init=/bin/bash` reset — to lock in the exemplar.
- [x] **Kali UEFI** — a UEFI build of the preseed-gallery target (drop `firmware`,
      set `pxe_bootfile = "ipxe.efi"` per the gallery README) + the `init=/bin/bash`
      reset under OVMF. *(Authored as an author-run recipe in RUNBOOK-init-shell.md —
      firmware-agnostic once at the GRUB menu, which the verified Debian/UEFI run
      proves; the heavy gallery-under-OVMF install is the author-run part.)*
- [x] **Rocky / AlmaLinux UEFI** — a UEFI build of the kickstart-gallery target +
      the `rd.break` reset under OVMF. *(Authored, author-run, in RUNBOOK-rd-break.md
      with the EFI specifics: `grub.cfg` under `/boot/efi/EFI/<distro>/` → the
      `grub2-mkconfig` target changes; Secure Boot's shim→grubx64 chain + the
      GRUB-password interaction; OVMF secboot vs non-secboot variant.)*
- [x] **systemd debug shell** — note the UEFI path if it differs. *(RUNBOOK-systemd-
      debug-shell.md: firmware-agnostic — same `e`/cmdline edit; only the GRUB-
      password/Secure-Boot caveat.)*
- [x] Extend the README firmware matrix to each method × BIOS/UEFI; add 00-INDEX
      coverage; keep `link_check.py` green.

**✅ Done 2026-07-23.** The headline item — **`debian-uefi.toml` verified end-to-end
under OVMF/KVM** (`BdsDxe`/`EDK II` boot-manager phase → `Welcome to GRUB!` over
serial → the full `init=/bin/bash` reset → old pw `Login incorrect`, new pw
`uid=0(root)`; every step EXPECT-confirmed live, rc=0). Evidence in
[`MANUAL_TESTING.md`](examples/root-password-reset/MANUAL_TESTING.md) → *Debian
UEFI/OVMF — verified end-to-end*; `debian-uefi.toml` STATUS flipped to ✅ verified;
README firmware-axis note + matrix updated (init-shell now **BIOS + UEFI**). The
other distros' UEFI variants (Kali/Rocky/AlmaLinux) + the systemd debug shell are
**authored as author-run recipes** in the RUNBOOKs — each is `firmware = "uefi"`
gallery build + the *identical* in-menu reset, and the verified Debian/UEFI run is
the load-bearing "firmware-agnostic" proof. `link_check` green.

Exemplar: [`debian-uefi.toml`](examples/root-password-reset/debian-uefi.toml) + the
firmware-axis note in
[`examples/root-password-reset/README.md`](examples/root-password-reset/README.md)
(`lab-vm.sh` `firmware = "uefi"` = OVMF/edk2).

## 7. Vendor the official **Packer** image-builder repos (Kali first, then AlmaLinux) — whole + automated

Both Kali and AlmaLinux publish a **Packer-based image-builder repo** that produces
their official cloud/VM images. AlmaLinux's is
[`AlmaLinux/cloud-images`](https://github.com/AlmaLinux/cloud-images) — the *same*
repo the [`almalinux-kickstart-gallery`](examples/almalinux-kickstart-gallery/)
already pulls its `http/*.ks` kickstarts from, but here we want the **whole Packer
builder**, not just the kickstarts. Kali has an equivalent (URL **to be supplied by
the user** — see the prerequisite). Each lab has **two halves**: (a) the upstream
repo **vendored in full**, runnable **per its own instructions** (offline,
byte-faithful), and (b) an **mklab automation wrapper** that drives the Packer build
through the existing phases.

> **Vendoring note (deliberate exception).** CLAUDE.md's default for "follows
> upstream *code*" is *cite, don't mirror* — but the explicit requirement here is to
> have each builder **available in whole to run per the repo's own instructions**,
> so this is a **full vendor**: pin the exact upstream **commit** + a **Retrieved**
> date, keep the upstream **LICENSE**, and add a provenance `README.md` (a
> `git rm`-to-remove note). Decide submodule-pin vs. flattened copy when starting;
> a flattened copy is more self-contained (matches the repo's offline ethos).

**Prerequisite — do this FIRST, before any work:**
- [x] **Ask the user for the Kali Packer image-builder repo URL.** Supplied
      2026-08-06: <https://gitlab.com/kalilinux/build-scripts/kali-packer>.

> ⚠️ **And the answer reframed the Kali half: most of it already existed.**
> [`examples/kali-packer-vagrant/`](examples/kali-packer-vagrant/) has operationalized
> **that exact repository** since 2026-07-03 — same URL, and
> [`UPSTREAM.md`](examples/kali-packer-vagrant/UPSTREAM.md) already pinned the same
> commit `b8c9b34e…`, which a fresh clone on 2026-08-06 confirmed is *still* HEAD.
> The lab has a driver (`build-kali-box.sh`), a pinned fetcher, a README, a
> MANUAL_TESTING, a 00-INDEX row, and it was **built and booted end-to-end** with two
> documented bitrot fixes. Writing this item's "vendor it under its own `examples/`
> subdir" as specified would have produced a **second lab for the same upstream** —
> the duplication this repo's own blast-radius rule exists to prevent. What was
> genuinely missing was narrower: the **bytes**, and the hand-walk.

**Kali first:**
- [x] Vendor the Kali Packer builder **in full** (pinned commit + provenance +
      LICENSE), runnable per upstream's README. **Done 2026-08-06** —
      [`examples/kali-packer-vagrant/upstream-repo/`](examples/kali-packer-vagrant/upstream-repo/):
      all **17** tracked files byte-exact (verified against the source checkout,
      0 mismatches), a per-file `sha256` table, a `SHA256SUMS` for
      `sha256sum -c`, upstream's `LICENSE` preserved, and the posture change
      recorded in `UPSTREAM.md`. The retirement is what makes it worth doing: a
      pinned URL is a poor custodian of a repository nobody maintains.
      *(One trap worth naming: upstream ships a `.gitignore`, and vendoring it
      verbatim silently applies those rules to our subtree. Checked rather than
      assumed — `git status --ignored` shows nothing hidden, and all 17 stage.)*
- [x] ~~mklab automation wrapper — a build script~~ **already existed**:
      [`build-kali-box.sh`](examples/kali-packer-vagrant/build-kali-box.sh) +
      [`fetch-kali-packer.sh`](examples/kali-packer-vagrant/fetch-kali-packer.sh).
- [x] **Point the driver at the vendored copy** so the lab builds **offline** by
      default, with a flag to clone upstream live instead. **Done 2026-08-06.**
      `fetch-kali-packer.sh` stages the archive after verifying it against
      `SHA256SUMS` (**refuses** a mismatch, naming the file — a vendored tree is a
      cached copy, and one nobody re-checks is bug class #1); `--upstream` restores
      the clone. *It nearly stayed decorative:* `build-kali-box.sh` passed
      `--ref "$REF"` **unconditionally** with `REF=main`, and `--ref` implies
      `--upstream`, so every build would still have cloned and the offline path
      would have existed and never run — one defaulted flag. Guarded by
      [`tests/test-offline-archive.sh`](examples/kali-packer-vagrant/tests/test-offline-archive.sh),
      which asserts the property against **`build-kali-box.sh`** and not only the
      fetcher, because that is where the defect was.
- [x] **Hand-walk `Containerfile`** (Packer + QEMU baked in, per the *Hand-walk
      sandboxes* convention); partition what the agent can run vs. an explicit
      "you run this" marker (Packer needs KVM/`/dev/kvm`; flag if blocked here).
      **Done 2026-08-06** — [`examples/kali-packer-vagrant/hand-walk/`](examples/kali-packer-vagrant/hand-walk/)
      (`Containerfile` + `RUNBOOK.md`); see the follow-up entry below, which
      records what building it surfaced. *This box stayed unticked while the very
      next subsection said the work was done and the section ended on "Item 7 is
      COMPLETE" — the same stale-record shape the audit findings had.*

**AlmaLinux second:**
- [x] Vendor [`AlmaLinux/cloud-images`](https://github.com/AlmaLinux/cloud-images)
      **in full** (same provenance discipline), and cross-link it with the
      kickstart gallery (which already consumes a slice of this repo).
      **Done 2026-08-06** — [`examples/almalinux-packer-images/`](examples/almalinux-packer-images/):
      563 files byte-exact at pinned `6d808bf7`, `SHA256SUMS`, upstream `LICENSE`
      preserved, cross-linked both ways with the gallery.
      ⚠️ **The argument is INVERTED versus Kali and the lab says so:** that upstream
      is *retired*, this one is *actively maintained*, so the archive is a **dated
      snapshot, not a mirror** — its pin records *which* factory the lab documents,
      and `--upstream` shows what moved.
      **The `.gitignore` trap fired here.** Upstream's `.gitignore` lists
      `*.pkrvars.hcl` *and* upstream tracks `tests/test-values.pkrvars.hcl`, so a
      plain `git add` silently dropped it. Force-added, and the test asserts
      **on disk == in SHA256SUMS == tracked by git** so a future re-vendor cannot
      lose a file quietly. *(Checked for Kali too, where it did not fire.)*
- [x] Same automation wrapper + hand-walk `Containerfile` shape as the Kali half.
      **Done** — `fetch-cloud-images.sh` (offline by default, verifies 563 files,
      **refuses** a tamper by name; `--upstream` to clone live) +
      [`hand-walk/`](examples/almalinux-packer-images/hand-walk/RUNBOOK.md) (RHEL-9
      box with QEMU/KVM, Packer from HashiCorp's RPM repo, `ansible-core`).
      ⛔ **Deliberately NO `build-alma-image.sh`.** Unlike the Kali lab, no image has
      been built here — a wrapper would imply a path somebody walked. The build is
      **author-run and marked as such** (`/dev/kvm`, a ~1 GB ISO, tens of minutes);
      what is CI-gated is the archive, the offline staging and the tamper refusal.

- [x] **Kali hand-walk `Containerfile`** — **done 2026-08-06**, and it surfaced a live
      doc defect: the HashiCorp apt line this lab's own README gives,
      `$(lsb_release -cs)`, expands to `kali-rolling` on Kali and **404s** (HashiCorp
      publishes no such suite). Pinned to `bookworm`, with the 404 recorded next to it.
- [x] **A real `packer` run against BOTH vendored archives** — `init` + `validate`,
      **verified 2026-08-06**:
      - Kali: `build-kali-box.sh --validate-only` inside the sandbox → **`The
        configuration is valid.`** — archive verified offline, both compat patches
        applied, 5 plugins installed, live ISO resolved, every schema checked.
      - AlmaLinux: `packer validate -only='qemu.almalinux-9-gencloud-x86_64'` on the
        vendored 563 files → **`The configuration is valid.`**

      This is the first proof either vendored archive is a *valid Packer config* rather
      than merely a byte-exact pile of files. ⚠️ **And the AlmaLinux run found a false
      success:** on RHEL-family, `cracklib-dicts` ships `/usr/sbin/packer`, which
      **shadows** HashiCorp's `/usr/bin/packer`; a bare `packer version` prints `0 0` and
      **exits 0**, so `validate` "passed" twice while checking nothing. Fixed with a PATH
      order *and* a build-time assertion — a PATH tweak is a mechanism, the assertion is
      the outcome.

- [x] **A full `packer build` producing an actual image** — **DONE 2026-08-06, author-run.**
      `build-kali-box.sh --install-packer` on the host: **`packer_kalirolling_libvirt_amd64.box`,
      5.7 GB, built in 11 min 12 s** on QEMU 8.2.2 + KVM with the pinned packer 1.13.1 —
      **from the VENDORED archive, offline** (`archive verified: 17 files match`), both compat
      patches applied, the 4.47 GB ISO checksum-verified by packer.
      **The whole chain is now proven end to end**: vendored bytes → verified → staged →
      patched → `packer init` → live ISO resolution → unattended d-i install → Ansible-free
      shell provisioning → `vagrant` post-processor → a bootable box.

      ⚠️ **The first attempt failed and it was NOT a defect.** It died at
      `Error running boot command: … use of closed network connection` — the VNC socket
      closing mid-type. I predicted "bitrot #3" and was **wrong**: an identical re-run, same
      host, no changes, succeeded. That is the §17.5 control (*same commit, re-run*)
      distinguishing flaky from real, and the honest label is **flaky**, recorded in the
      README beside the two genuine bitrots rather than promoted to one.

- [x] **AlmaLinux image built, for symmetry** — **DONE 2026-08-06**:
      `AlmaLinux-9-GenericCloud-9.8-20260806.x86_64.qcow2`, 567 MB, **5 min 55 s**, from the
      vendored archive in the hand-walk container (Ansible `ok=36 changed=23 failed=0`),
      then **booted to `localhost login:`**. Two host-specific findings, both of which look
      like a broken build: upstream's `qemu_binary` default is `null` so packer seeks
      `qemu-system-x86_64` — **a name RHEL-family does not ship**, so *upstream's own default
      fails on upstream's own distro* (their CI runs Debian-family runners); and booting
      needs `-cpu host` because AlmaLinux 9 requires **x86-64-v2** while QEMU's default
      `qemu64` panics init with `Fatal glibc error: CPU does not support x86-64-v2`.

**Item 7 is COMPLETE.** Both builders vendored in full, both runnable offline against
verified archives, both hand-walks built, both configs `packer validate`-clean, and **both
built into real, booted images**.

Per-lab, both halves: a `README.md` + `MANUAL_TESTING.md`, a 00-INDEX entry, and
`tools/link_check.py` green (0 broken, no orphans).

Exemplars: the *Provenance* + *Hand-walk sandboxes* conventions in
[`CLAUDE.md`](CLAUDE.md); existing vendored sources under
`examples/*/upstream-tutorial/` and hand-walk `Containerfile`s
([`micro-linux/hand-walk/`](micro-linux/hand-walk/)); the distros' existing labs
([`examples/kali-preseed-gallery/`](examples/kali-preseed-gallery/),
[`examples/almalinux-kickstart-gallery/`](examples/almalinux-kickstart-gallery/))
as the d-i/kickstart counterparts to these Packer builders.

## 8. Repo health review (2026-08-03): one real defect + deferred follow-ups

A full health pass run on a **minimal container (root, no
podman/qemu/incus/debootstrap, no docker daemon)** — deliberately hostile
conditions, and a good stress test of the "no silent exits, honest SKIPs"
discipline. The record, so the next reviewer knows what was already checked:

- **Green:** `tools/link_check.py` (368 docs, 0 broken, 0 orphans);
  `tools/paths.py --check`; `bash -n` over all 363 tracked scripts; all
  `tools/tests/` suites; phases 1, 2, 3, 5, 7 + micro-linux (runnable tests
  pass, the rest SKIP with named reasons); phase6-tui + phase6b-web pytest
  (154 passed, 1 skipped); `netboot/tests/test-sign-payload.sh`; the
  [`examples/metal-as-a-service/`](examples/metal-as-a-service/) chaos suite
  (28 passed, 7 skipped, 0 failed — zero criticals, all 9 layers covered).
- **Provenance verified beyond what CI checks:** all **204** recorded `sha256`s
  across the 32 `upstream-tutorial/` archives re-hashed against the archived
  bytes — 204 match, 0 mismatches. The one archive-less dir
  ([`examples/linuxboot-uefi-kexec/upstream-tutorial/`](examples/linuxboot-uefi-kexec/upstream-tutorial/))
  is the *cite, don't mirror* tier correctly applied.

**The defect: phase4's `export` path gates before it validates — and its two
tests FAIL where they should SKIP.**
[`test-validation.sh`](phase4-podman/tests/test-validation.sh)'s
"export bogus format" assertion and
[`test-compose-export.sh`](phase4-podman/tests/test-compose-export.sh) both
**FAIL** on a host without podman (and fail *differently* as root: the
rootless-first refusal fires instead). Two distinct problems:

1. [`lab-podman.sh`](phase4-podman/lab-podman.sh)'s export path runs the
   root-gate / podman-presence check **before argument validation**, unlike
   every other subcommand — 13 sibling usage-validation checks pass fine in
   the same podman-less run. Usage errors should not require a working podman
   to be diagnosable.
2. The two tests carry no skip guard, violating the contract
   [`ci.yml`](.github/workflows/ci.yml) itself states ("daemon/root tests
   self-skip"). CI masks both (GitHub runners are non-root and ship podman) —
   this only bites on a minimal or root box, exactly the case the SKIP
   discipline exists for. Credit where due:
   [`run-all.sh`](phase4-podman/tests/run-all.sh) honestly exited 1.

- [x] Reorder `lab-podman.sh` `export` to validate its arguments (unknown
      format, missing lab) *before* the rootless gate and podman-presence
      check, matching the other subcommands.
- [x] ~~Give the "export bogus format" assertion and `test-compose-export.sh`
      a skip guard~~ — **this was the wrong fix, and doing it would have
      cemented the defect.** See below.
- [x] Negative control per house rules: after the fix, rerun both tests on a
      podman-less box and watch them PASS; re-inject the defect and watch all
      three assertions bite.

**✅ Done 2026-08-06.** The gates moved *inside* the `case` arms rather than
above it, so each format consults exactly what it uses. But investigating first
found the diagnosis above was **half the defect**: `--format compose` **never
calls podman at all** — it reads the stored `spec.toml` and prints YAML — so it
was a pure text transformation gated on a container engine *and* on being
non-root. `test-compose-export.sh` has carried "no live podman needed" in its
header since the day it was written; the code disagreed, and nothing noticed
because CI's runners ship podman.

**That is why sub-task 2 was the wrong fix.** A skip guard would have made a
podman-less host report `SKIP` for a test that needs no podman — retiring the
question while it was still open, which is exactly what the *UNKNOWN is not
PASS* rule forbids in the other direction. Neither test needs a guard now:
both pass on a podman-less `PATH`, as does `export bogus format`.

**The regression guard is new, because the existing assertion is inert where CI
runs it.** `expect_error "export bogus format"` only distinguishes fixed from
broken on a host with **no** podman, so it passed identically before and after
and would never catch this coming back.
[`tests/test-export-needs-no-podman.sh`](phase4-podman/tests/test-export-needs-no-podman.sh)
makes podman-presence *observable* instead of environmental: it runs a copy of
the tool with both gate functions replaced by tripwires that exit 9 by name, so
"did this path consult podman?" has a recorded answer on every host. Two
controls, because a one-sided test would also pass if the fix simply deleted the
gates: `logs` **must** trip the tripwire (proving it is wired), and
`--format kube` **must** trip it (proving the path that really does run
`podman kube generate` kept its gate).

Verified: full phase4 suite with real podman **11 passed · 1 skipped · 0
failed**; all three tests green on a `PATH` mirroring the host minus podman; and
with the defect re-injected all three fail — the new guard *with podman
installed*, which the other two cannot do. The root half of the original report
("fails differently as root — the rootless-first refusal fires") is fixed
structurally: neither surviving path reaches `require_rootless` at all, which is
what the `kube`-must-trip control measures.

**Known-open items re-confirmed, not new** (tracked elsewhere, listed for
completeness): ~~the Alpine `--allow-untrusted` gap — the residue of
[`AUDIT.md`](AUDIT.md) F2~~ — ✅ **CLOSED 2026-08-06**, three days after this section
was written: [`AUDIT.md`](AUDIT.md) F2 is **RESOLVED**, and it closed the Alpine half by
name — `alpine_apk_add` passes `--keys-dir "$root/etc/apk/keys"` and **no**
`--allow-untrusted`, so package RSA signatures are checked against Alpine's own bundled
keys. (The function's header comment still claimed the opposite and was corrected with
that row — the same defect as this line, one layer down.) ~~plus backlog items #4/#5
follow-on passes~~ — **#4's roles are done** (see §4, where that claim was stale too) and
**#5 is complete**, all four boxes ticked including the AlmaLinux `rd.break` reset
verified end-to-end on KVM. ~~and #7 (Packer vendoring, blocked on its prerequisite
question)~~ — **#7's prerequisite was answered 2026-08-06 and the item is COMPLETE**: both
builders vendored in full, both `packer validate`-clean, both built into real booted
images.

**Nothing on this line is still open.** It is kept struck through rather than deleted
because it is the record of what was believed on 2026-08-03 — but it *read as current
status*, which is how a closed question gets re-asked.

## 9. `nested-calico-sandbox/` — a disposable cluster, so the CNI beliefs can be tested

This host runs **microk8s with Calico on the metal**, and that single fact has shaped
several labs and cost one real outage
([`MICRO_CLOUD_LAB_PLAN.md`](MICRO_CLOUD_LAB_PLAN.md) F.6: a lab's tap captured the live
cluster's VXLAN tunnel endpoint). The mitigations that came out of it —
[`examples/micro-cloud/fabric.sh`](examples/micro-cloud/fabric.sh)'s bridge-naming rule and
its addressless-tap rule — are **derived from one host at one Calico version and have never
been falsified**, because falsifying them means breaking the cluster the machine is using.

A **throwaway microk8s inside a phase-2 VM** removes that constraint. It is listed here as
well as in the micro-cloud queue because its value is not confined to that lab: it is the
repo's only way to ask "what does the CNI actually do when I provoke it?" without the answer
costing an outage, and the same box is a safe host for the **whole** slice-3 break pass —
including `retap`, which no test has ever called.

> ⚠️ **Read the boxes carefully: the EXPERIMENT is done and the LAB is not.** On
> 2026-08-07 a disposable microk8s (v1.35.6, Calico **v3.29.3**) was stood up by hand in a
> `lab-vm.sh` guest and both rules were measured —
> [Appendix O](MICRO_CLOUD_LAB_PLAN.md#appendix-o--the-nested-calico-experiment-run-two-derived-rules-become-measurements-2026-08-07).
> That closes the *questions*. It does not close this item: a measurement nobody can re-run
> is a story, and the recipe currently lives only in an appendix. This is
> [§0.1](#0-next-up--the-three-things-nearest-the-front-of-the-queue).

- [x] `examples/nested-calico-sandbox/`: the cohesive-lab shape — ✅ **BUILT 2026-08-07**:
      spec, `sandbox.sh`, `guest-experiment.sh`, stamped `findings.env`, four tests,
      00-INDEX row, `learning-paths` route. Reproduces unprivileged in ~15 min.
      [Appendix Q](MICRO_CLOUD_LAB_PLAN.md#appendix-q--the-sandbox-packaged-g9-closed-on-the-real-artifact-2026-08-07)
- [x] Re-run **F.6** on purpose: give an interface an address and watch the node IP
      migrate. ✅ **measured 2026-08-07** — Calico migrated to the decoy **on its own
      60-second poll**, nothing restarted. (One interval was not enough: still on the
      incumbent at ~100 s, moved by ~3 min.) **Caveat kept:** this was a *dummy interface
      in a guest*, not a **`fabric.sh` tap** beside a cluster whose loss would matter —
      [§0.2](#0-next-up--the-three-things-nearest-the-front-of-the-queue) is that gap.
- [x] Verify **rule 1** by naming a bridge both ways and watching only one get picked.
      ✅ **measured 2026-08-07, and only because of the control**: deleting the winner made
      Calico fall back to the incumbent at index **2**, *skipping* an addressed `br-decoy`
      at index **8**. Index ordering cannot explain that, so the `^br-.*` exclusion is real
      — it had until then only ever been *read out of a binary*. Bound to **v3.29.3**; this
      host runs **v3.28.1**, and the finding is about the algorithm at a named version, not
      about this machine.
- [x] Exercise `retap` against a deliberately root-owned tap. ✅ **GREEN 2026-08-07** — `TUNSETIFF-FAILED errno=1` on a tap with owner uid 0 → `retap` → `TUNSETIFF-OK`, reservation byte-identical and still single, tap addressless on `br-mc0`, both verbs refusing the other's case, Calico unmoved. **Three privileged runs, two harness defects, zero defects in `fabric.sh`** — the test caught itself twice (an owner-**less** tap is attachable by anyone; and §5 asserted a *message* where the tool was right). [Appendix P](MICRO_CLOUD_LAB_PLAN.md#appendix-p--retaps-first-privileged-run-the-test-failed-and-that-is-the-finding-2026-08-07)
      ([`test-retap-recovers-a-root-owned-tap.sh`](examples/micro-cloud/tests/test-retap-recovers-a-root-owned-tap.sh));
      it stages the real defect and asserts the **`TUNSETIFF` outcome**, not the owner
      file. Root-gated, so it SKIPs unprivileged. **The privileged run is in** — it took
      three of them and two harness defects, both of which the test caught itself
      ([Appendix P](MICRO_CLOUD_LAB_PLAN.md#appendix-p--retaps-first-privileged-run-the-test-failed-and-that-is-the-finding-2026-08-07)).
- [x] A **CNI-layer chaos scenario** — ✅ **DONE 2026-08-07.** Five layers injected inside a
      Calico we may destroy: the CNI process, felix's netfilter programming, one pod's veth,
      the overlay device, and the chosen node address. **2 absorbed, 3 not, 0 critical.**
      *(Left as the record of that day. It has since grown to **8 rows over 7 layers —
      4 absorbed, 4 not, 0 critical** — the address allocator on 2026-08-08 and the
      k8s-dqlite datastore the same day. Current state lives in the lab's README, not here:
      a count in prose is a cached fact, and this one is now three revisions old.)*
      Two findings worth more than the rungs: Calico **never self-heals a deleted pod veth**
      (244 s with the dataplane down, recovered only by recreating the pod), and moving the
      node's advertised IP **heals the control plane while abandoning the workload** — F.6's
      consequence, watched for the first time. A third came free: `^cni.*` is ALSO in the
      first-found exclusion list, discovered by naming a decoy into it.
      [Appendix R](MICRO_CLOUD_LAB_PLAN.md#appendix-r--the-cnis-break-pass-the-last-layer-gets-an-injection-point-2026-08-07)

**Two constraints that must be honoured or the results are worthless**, both instances of
this repo's bug class #1: the sandbox must enumerate **its own** candidate set (ordering
depends on which interfaces exist, and the guest has neither `lxdbr0` nor `incusbr0`), and
it must **record the Calico version it observed** and refuse to generalise across a
mismatch — microk8s bundles whatever its channel ships, while every fact we hold is
**v3.28.1**. The finding transfers as a statement about a named version's selection
algorithm, **not** as a prediction about this host.

Full brief, with the five derived constraints and what "done" looks like:
[`examples/micro-cloud/DEFERRED.md`](examples/micro-cloud/DEFERRED.md#queued--nested-calico-sandbox-a-disposable-cluster-to-break-on-purpose).
Needs ~4 GiB RAM and ~10 GiB disk; **nested KVM is not required**.

---

## 10. ~~Extend the EXIT-trap safety net to phases 1–5 and micro-linux~~ — **DONE 2026-08-06**

Closed the same day it was filed. The scope grew once the shared checker existed: every
`tests/` directory in the repo now has the same shape, so the rule needs no exemption
list.

| tests dir | before | now |
|---|---|---|
| `phase1-chroot/` | 17 of 21 tests with **no net** | lib owns the trap; 22 traps → `on_exit` |
| `phase2-qemu-vm/` | 13 of 17 with no net | 7 traps → `on_exit` |
| `phase3-docker/` | 15 of 16 with no net | 8 traps → `on_exit` |
| `phase4-podman/` | 11 of 13 with no net | 6 traps → `on_exit` |
| `phase5-lxd/` | 10 of 10 with no net | 7 traps → `on_exit` |
| `micro-linux/` | 10 of 10 with no net | 1 trap → `on_exit` |
| `phase7-firecracker/` | net fine, no `on_exit` | gained the registry |
| `examples/micro-cloud/` | net per test (6 copies) | lib owns it; 6 traps → `on_exit` |
| `examples/bmc-toolkit/`, `examples/zfsbootmenu-boot-environments/`, `examples/metal-as-a-service/` | fixed earlier the same day | now on the shared checker too |

- [x] `_VERDICT` + `on_exit` + `_on_exit` in every `lib.sh`, with the trap installed there.
- [x] Every test that installed its own EXIT trap converted (~50 sites).
- [x] **One** implementation of the check — [`tools/check-harness-net.sh`](tools/check-harness-net.sh)
      — with a five-line `tests/test-harness-net.sh` per directory so it runs inside that
      suite's `run-all.sh`, and therefore CI. The bespoke copy written for
      metal-as-a-service hours earlier was replaced by a wrapper.
- [x] All eleven suites run, and the six converted ones diffed **per-test verdict against
      a baseline captured before the change**: all 87 identical. A green summary would
      not have shown a test flipping PASS→SKIP.

**What the work added beyond the brief:** registered cleanup can read the exit status as
`$_EXIT_RC`. Without it, a teardown that branches on failure — micro-cloud's
DHCP-exhaustion test keeps its log directory when the run fails — has no choice but to
write its own `trap … EXIT`, which is the very defect being removed. A rule people cannot
follow is a rule that gets broken.

---

## 11. CI coverage: what a green tick still does not run (2026-08-21)

Raised while gating the metal-as-a-service suite ([#267](https://github.com/That-Guy-40/mklab/pull/267)),
which was the largest suite in the repo and the only one nobody ran. **CI is green and
correct for what it covers.** This section is what it does *not* cover, written down so
`0 failed` stops being read as *everything ran* — which is this repo's oldest rule
(**UNKNOWN is a verdict, distinct from PASS**) pointed at its own pipeline.

Everything below is **measured from the job log of `1c756a6`**, not estimated.

### 11.1 The one honest debt from #267: the dead-code fix is unproven in production

#267 repaired a branch that could never execute. The example-lab loop had:

```bash
bash "$t"; r=$?
[ "$r" -eq 0 ] || [ "$r" -eq 77 ] || rc=1
```

Under GitHub's default `bash -e {0}`, `cmd; r=$?` never reaches the assignment — the step
dies with the raw status. So a suite exiting **77**, the skip that line exists to permit,
failed the job *and silently stopped every suite after it in the loop*.

**It is still unproven where it matters.** No suite has yet exited 77 wholesale on a
runner, so the repaired branch has not run in CI. What exists is a **local** six-case
harness driving the *shipped* `run_suite` (sed'd out of `ci.yml`, not re-implemented),
with the control showing the old shape dying at the 77 without printing its own
`::endgroup::`. Real, measured — measured *here*, which
[is not the same thing](CLAUDE.md).

- [x] **11.1** — **closed 2026-08-22** by the durable form, not the throwaway:
      [`tools/tests/test-ci-tolerates-a-skipped-suite.sh`](tools/tests/test-ci-tolerates-a-skipped-suite.sh)
      seds the **shipped** `run_suite` out of `ci.yml` (a re-implementation would drift and
      then prove something about the copy) and drives it under both `bash -e` and
      `bash -eo pipefail` against synthetic suites exiting 0/77/1. It asserts the loop
      **reaches the suite after the 77** — a sentinel, not the exit code, because the
      truncation was the expensive half — that `::group::` closes across it, that a suite
      exiting 1 still fails the step *and* still does not truncate the loop, and that the
      annotation names every skipped test on one line while staying silent when nothing
      skipped. Two controls: the pre-#267 `; r=$?` shape must fail the same assertions, and
      an absent annotation block must produce no annotation.

      **It ran on a runner** in the `shellcheck + bash -n` job of PR #269 and printed both
      the verdict and `control: the pre-#267 '; r=$?' shape dies at the 77 (rc=77) and the
      later suite never runs`. So the tolerant branch is now taken on every push, on
      GitHub's own shell — which is what "measured *there*" was asking for.

      Four mutants of `ci.yml` were run and watched to bite before it shipped. One of them
      retired a check inside the checker: a `grep -q 77` extraction-sanity line fired first
      on the deleted-tolerance mutant and blamed *the extraction* for a defect that was
      nothing of the sort. Behaviourally the same mutant now reports "the tolerance is too
      wide and CI gates nothing", which is true. And the control caught a bug in itself on
      its first execution: in `${v/pat/repl}` an unescaped `&` in the **replacement**
      expands to the matched text, so a replacement containing `2>&1` spliced the match
      back into itself and built a line that never ran.

### 11.2 Fifty-eight rows skip on every CI run — 21 of them closable

The new annotation names them; nothing had before. **The count cross-checks:** the
annotation's per-suite totals sum to **58**, and so does the sum of every runner's own
`N skipped`, which is a nice accident — the parser is not dropping any.

| suite | rows skipped |
|---|---|
| `phase2-qemu-vm` | 12 |
| `examples/micro-cloud/` | 12 |
| `phase1-chroot` | 11 |
| `phase5-lxd` | 10 |
| `examples/metal-as-a-service/` | 7 |
| `examples/nested-calico-sandbox/` | 4 |
| `phase3-docker` · `phase7-firecracker` | 1 each |

Grouped by **what each is blocked on**, which is the only thing that says which are
schedulable:

**(a) Closable by installing a package on the runner — 21 rows:**

| install | rows it unblocks |
|---|---|
| `qemu-system-x86` | **12** — most of phase 2's argv tests plus MAAS's `measured-image`, `probe-nic`, `verifying-rom` |
| `musl-tools` | 2 — micro-cloud's two vsock tests |
| `dnsmasq` | 2 — MAAS's DHCP-reservation and UEFI-netboot rows |
| `swtpm` · `ovmf` · `libguestfs-tools` · `xorriso` | 1 each |
| binfmt `qemu-aarch64` | 1 — phase 3's buildx multiarch row |

- [x] **11.2a** — **done 2026-08-22, and the figure above was wrong.** `qemu-system-x86`
      + `qemu-system-arm` + `xorriso` (~120 MB, ~1 min per run of the job) took the total
      from **58 skipped rows to 48**, measured from the annotation on both sides:

      | suite | before | after | what moved |
      |---|---|---|---|
      | `phase2-qemu-vm` | 12 | **3** | the eight argv rows, plus `test-seed-and-sha256.sh` on `xorriso`; `test-debian-x86_64-boot.sh` still needs `/dev/kvm`, socat and curl |
      | `examples/metal-as-a-service/` | 7 | **6** | `test-tpm-xml.sh` |

      *(That table read `4` and `49` for one draft — written from the FIRST green run,
      before `xorriso` was in the install. The figures here are from the run that shipped.
      A number copied out of a previous run is a cache entry, in a section about exactly
      that; the annotation is the source, so read it after the last change, not before.)*

      **Two corrections to 11.2's table, both from reading only the FIRST missing command
      in each skip line.** It over-counted: `qemu-system-x86` was credited with twelve rows
      and bought nine, because `test-debian-x86_64-boot.sh` needs four more things and the
      three MAAS rows named `qemu-system-x86_64` first while each needs a whole chain
      behind it (`ukify`+`swtpm`+`mtools`+OVMF; a ROM built with docker; a staged netboot
      kernel). It also **under**-counted, in the other direction: nothing predicted
      `test-tpm-xml.sh`, which the same install bought anyway. A tally derived from one
      line of a skip message is a cache entry, and it was wrong in both directions at once.

      **And the eighth row failed the moment it ran** — the whole point of moving a row
      from UNKNOWN to measured. `test-mac-cli.sh` calls `create`, which seeds a NoCloud ISO
      by **default**, so on a host with no `genisoimage`/`xorriso`/`mkisofs` it failed and
      announced `REGRESSION: 'create --mac' failed — the flag must exist`. The flag was
      fine. A test that names the wrong cause is worse than one that skips, so it now
      passes `--no-cloud-init` (its subject is MAC → spec → manifest → argv; seed ISOs are
      machinery it has no opinion about) and its failure message defers to `create`'s own
      output. Proven both ways locally against a PATH built without the three ISO makers:
      the pre-fix test reproduces the runner's failure exactly, the fixed one passes with
      and without them.

      The remaining 11.2(a) installs are unchanged and still open: `musl-tools` (2),
      `dnsmasq` (2), `swtpm`·`ovmf`·`libguestfs-tools` (1 each), binfmt `qemu-aarch64` (1).
      Each should be weighed against runner minutes in its step comment, as this one is.

**(b) Not closable on a hosted runner — 37 rows, and they must stay UNKNOWN:**
17 need **root** (phase 1's mount/debootstrap guards, micro-cloud's fabric), 10 need a
reachable **LXD/Incus daemon**, 4 need a live **nested Calico sandbox**, and 6 need the
**pinned `firecracker` binary** — which is *deliberately* not fetched: the repo's
toolchain-fetch gate forbids fetch+exec of prebuilt toolchains, so this one is **closed
by decision, not open**. Recorded here so it stops being re-raised as if it were
schedulable.

### 11.3 `shellcheck` gates 60 of 516 tracked scripts

**As measured 2026-08-21:** `bash -n` covers **all 515**. `shellcheck` runs against a
**hand-maintained list of 60** —
the phase drivers plus the micro-cloud instruments — so a list, again, is doing a job a
question should do. Measured: of the **455** un-gated tracked scripts, **415 already pass**
at CI's own severity and **40 would fail** (1 of them vendored upstream, so 39 are ours).
*(That count was 454/414 for one draft of this entry: the file feeding the loop had no
trailing newline, so `wc -l` under-reported by one and `while read` never handed over the
last line — `tools/wizard-walkthrough.sh`, which passes. A tally that silently drops its
final element, in a section about checks that silently cover less than they look.)*
`examples/metal-as-a-service/maas-lab.sh` — 73K, the largest driver in the repo — is
un-gated and *passes today*; four of its siblings (`create-fleet.sh`, `deployer-init.sh`,
`lib/e2e-common.sh`, `measure-init.sh`) are among the 40.

**Re-derived 2026-08-22** (the paragraph above is from 2026-08-21, and a figure in prose
is a cache entry): **516** tracked scripts, **60** gated at `--severity=warning`, **456**
un-gated, of which **416 already pass** and **40 would fail**, carrying **59 findings**.
The drift is one file — this section's own sibling, `test-ci-tolerates-a-skipped-suite.sh`,
added the same day. Every classification below is from that sweep; re-run it before acting
on it rather than trusting these numbers.

**The wiring is ten lines. The work is the 40 files** — so 11.3 is two tasks, in this
order, and the order is the point: **flip the gate second**, or the inversion ships red and
a gate that starts red is a gate someone disables.

#### 11.3a — fix what is real (do this first)

The 59 findings triage into three tiers. An earlier note in this session put "roughly ten"
in the top tier; reading each one puts **three** there, and being wrong in that direction
is worth recording — a code that *can* indicate a defect is not a defect, and the tally was
made from severity codes rather than from the lines they point at.

**Tier 1 — real defects (3 files, 4 findings). Each is a one-line fix, and each is a shape
this repo already has a rule about:**

| where | code | what is actually wrong | fix |
|---|---|---|---|
| `examples/FREEBSD-simple-templating-serving-RHEL-kickstart-files/templating/kickstart.sh:72` | SC2320 | `if [ ${?} -eq 0 ]` sits after two `echo`s, so it tests the **echo's** status. The script announces *"ISO image generated"* whether or not `mkisofs` succeeded — a **false success**, the one that outranks an honest failure | capture `mkisofs`'s status into a variable **on its own line**, before the echoes, and test that |
| `examples/metal-as-a-service/create-fleet.sh:106` | SC2318 | `local name="$1" log="$CONSOLE_DIR/$name.log"` — `local` is a *command*, so its arguments are expanded **before** it runs and `$name` is the **caller's**, not `$1`. Correct today only by accident: the call site is `for name in $(fleet_names)` with `name` left global and holding the same value. Measured: same-value caller → `/dir/node1.log`; a caller whose `name` differs → **that** node's path; **no** caller global (i.e. if that loop variable were ever made `local`) → `/dir/.log`, one shared append-only console for the whole fleet, written into the domain XML and recorded in the registry. Node B's boot output would then satisfy node A's health gate — the record-outlives-its-subject class this lab's own [`DEFERRED.md`](examples/metal-as-a-service/DEFERRED.md) is about. Needs sudo + libvirt to execute, so the green suite cannot see it | split into two `local` statements |
| `phase5-lxd/tests/test-inspect-json.sh:337` | SC2221 + SC2222 | `*"no instance"*\|*"no instance, profile"*` — the second pattern is subsumed by the first and can never match. The assertion accepts one message while reading as though it accepts two | drop the dead pattern, or make the first specific enough that both are reachable |

**Tier 2 — real, low-grade, mechanical (15 findings).** `cd` with no guard (SC2164, 11×) —
six of them the opening `cd -- "$(dirname -- "${BASH_SOURCE[0]}")"` in a `run-all.sh`, where
a failed `cd` leaves the runner globbing `test-*.sh` in an unrelated directory and reporting
a clean `0/0`. Append `|| exit 1`. Plus `ls | grep` / `ls | xargs` (SC2010 3×, SC2011 1×) —
replace with a glob or `find -exec`.

**Tier 3 — labels, not bugs (40 findings).** These are the exclusion list, and each gets an
**in-file** `# shellcheck disable=<code>  # <reason>` rather than a central entry, so the
excuse lives beside the code and dies with it:

- **SC2154 (20×)** — deferred or indirect assignment shellcheck cannot see: `rc=$?` inside a
  single-quoted `trap` body, and `_shellmath_getReturnValue _sm` assigning by name. One of
  the 20 reads `did you mean 'r_sm'?`, which is the only typo-shaped one and is **not** a
  typo — check it, don't assume it.
- **SC2054 (6×)** — `QEMU+=(-nic user,model=virtio-net-pci)`: those commas are QEMU option
  syntax inside one word, not array separators. Quote the word; behaviour is unchanged.
- **SC1112 (3×)** — typographic apostrophes inside single-quoted **prose** (`the container's`).
  Retype as ASCII.
- **SC2187 (2×)** — `deployer-init.sh` / `measure-init.sh` are `#!/bin/busybox sh`. Add
  `# shellcheck shell=dash`, then **re-run**: dash-checking will surface findings the
  bash-assumed pass never reported.
- **SC2148 / SC1090 / SC1007 / SC2217 / SC1008 / SC1113 / SC2096 / SC3045 (1× each)** —
  a sourced lib with no shebang (`shell=bash`), a non-constant `source`, a deliberate
  `VAR= cmd` prefix, a deliberate `sleep 30 </etc/hostname &` holding an fd open *because
  that is the article's subject*, a `/etc/profile.d/` snippet whose first comment line
  shellcheck reads as a shebang, and `ulimit -n` under `#!/bin/sh`.
- **SC2076 (1×)** — the only genuinely **vendored** file
  (`examples/almalinux-packer-images/upstream-repo/…/99-img-check.sh`), and therefore the
  only one that belongs in a central exclusion: it is not ours to edit.

- [x] **11.3a** — **done 2026-08-22.** The ungated set went from **40 files / 59 findings**
      to **1 file / 1 finding** (the vendored upstream script, which 11.3b's exclusion owns).
      Each Tier-1 fix was watched to bite, not just re-run green:

      | fix | the control that was RUN |
      |---|---|
      | `kickstart.sh` | with a stub `mkisofs` forced to fail: **before**, `rc=0` and *"ISO image generated"*; **after**, `rc=1` and the ERROR branch. Then the happy path with a real `mkisofs` |
      | `create-fleet.sh` | the real `give_console`, extracted from both versions and driven three ways. Before: a caller whose `name` differs writes **that** node's path, and no caller global writes `/console/.log`. After: `/console/node1.log` in all three |
      | `test-inspect-json.sh` | both messages fed to the `case` and accepted, a drifted one refused — **and the real test run against a live incus**, which is what proves the patterns match what `lab-lxd.sh` actually emits |

      **Two more real defects turned up while fixing those three**, which is the argument for
      doing 11.3a before 11.3b rather than the reverse:

      1. **A safety net that always reported `rc=1`.**
         `examples/UNIX-floating-point-arithmetic-in-bash/demo.sh` captured `rc=$?` *inside*
         the `||` block of its EXIT trap, so `$?` was the status of the `[ -n … ]` test that
         preceded it, not the script's. Measured: an early `exit 77` printed
         `FAIL: exited early (rc=1)`. Capturing first fixes it — the rule `lib.sh`'s
         `_on_exit` already follows, in a file that had reimplemented the net by hand.
      2. **`tools/tests/test-no-pipe-gates.sh` was a liar, in this repo's signature way.**
         Its scan was a `grep` over a **physical line**, so a gate written as
         `producer | grep -q X \` + `|| fail` was invisible. That is the **third** time here
         that a regex over a line has stood in for a question about a *command*
         (`check-harness-net.sh` §1 was wrong the same way **twice**). Worse, its fixture had
         **already planted** the continuation shape — behind a `>= 1` assertion the same-line
         plant satisfied on its own, so the plant sat there for months proving nothing.

         Fixed by joining backslash-continuations before matching (a bounded normalisation,
         not a shell parser — the remaining blind spot, a `grep -q` inside a quoted string or
         heredoc, is named in the file), by requiring each planted shape to be caught
         **individually**, and by `[^|]` on both patterns so the second bar of `||` stops
         reading as a pipe — six false positives appeared the moment lines were joined.

         **It then found 15 live pipe-gated verdicts across 9 files**, every one invisible
         before. Fourteen are the noisy `|| fail` form; **one is the SILENT `&& fail`**
         variant in `examples/micro-cloud/tests/test-preserve-round-trip.sh` — a leftover-
         container guard that, when SIGPIPE'd, reports the leftover as absent, which is the
         single outcome it exists to prevent. All 15 converted to capture-then-test, and the
         widened scanner was watched biting on a re-injected continuation in a real file.

      Tier 2 (11 unguarded `cd`, `ls | grep`, `ls | xargs`) and Tier 3 (the labels, each an
      in-file `# shellcheck disable=<code>  # <reason>`) landed with it. Two placement
      mistakes are worth remembering: a directive above a *blank line or a comment* attaches
      to the wrong command — it must sit immediately above the command it excuses — and
      retyping a typographic apostrophe as ASCII inside a **single-quoted** string closes the
      string, which is why those three are labelled rather than "fixed".

      Verified after: `bash -n` over all 516 tracked scripts; the four `tools/tests` gates;
      phase 5's suite 20/20 (17 passed, 3 skipped) against a live incus; the four affected
      MAAS/micro-cloud tests individually green; phase 1's two export tests green.

      **The last three were closed the next day, 2026-08-23, by running them as root.**
      `test-nspawn-integration.sh`, `test-schroot-integration.sh` and `test-rootful-up.sh`
      skip without root *both here and on the CI runner*, so their rewritten assertions were
      the only ones in that change never watched executing anywhere — fixtures in both
      directions were a reduction of that UNKNOWN, not a closure of it. All three now
      **PASS** under real root, each through its full round-trip (nspawn registers and
      destroys a `machinectl` image; schroot writes and removes its `chroot.d` conf; the
      rootful test binds privileged port 1013 and confirms a non-root user warns for the
      same port). A root run is not something CI can do, so this is the form the closure
      takes: [`tools/verify-root-gated-tests.sh`](tools/verify-root-gated-tests.sh) exists to be re-run
      by hand when those three change again.

#### 11.3b — flip the gate (only once 11.3a is green)

```yaml
- name: shellcheck EVERY tracked shell script
  run: |
    mapfile -t files < <(git ls-files '*.sh' | grep -vxF -f .shellcheck-exclude)
    echo "linting ${#files[@]} of $(git ls-files '*.sh' | wc -l) tracked scripts"
    shellcheck -x --severity=warning -e SC2064,SC2155,SC2034 -f gcc "${files[@]}"
```

replacing **both** hand-maintained lists (the phase drivers and the micro-cloud
instruments). Keep the existing error-severity sweep of `*/tests/*.sh`: it is a subset, and
deleting it is a change nobody needs to make on the same day.

Four things that make it a gate rather than a decoration:

1. **`.shellcheck-exclude` is a file of exact paths with a `# why` above each**, and it
   should end up holding **one** entry (the vendored upstream script). An exclusion list of
   39 is the same construct as an inclusion list of 60 — a list doing a question's job.
2. **Print the ratio it linted** (`N of M tracked`), for the same reason `run-all.sh` prints
   `ran/listed`: a step that silently lints nothing and a step that lints everything both
   exit 0.
3. **Fail when an excluded path no longer exists.** A stale exclusion is a cache entry: it
   keeps excusing a file that was renamed, and the *new* name is silently gated by nobody.
4. **Run the negative control before believing it.** Plant a file with a known-bad line
   (`cd /tmp` with no guard is enough), confirm the step **fails**, and confirm the count in
   (2) went up by one. An all-PASS sweep is indistinguishable from one that matched no
   files — which is exactly how a `git ls-files` glob typo would present.

- [x] **11.3b** — **done 2026-08-23.** Two inclusion lists (60 files) replaced by one sweep
      of `git ls-files '*.sh'` minus [`.shellcheck-exclude`](.shellcheck-exclude), which holds
      **one** entry: a vendored upstream script that is not ours to edit. Measured: the gate
      lints **515 of 516** tracked scripts and the repo is at zero findings, because 11.3a
      went first.

      All four properties shipped, and (4) is a *permanent* control rather than a pre-flight:
      [`tools/tests/test-shellcheck-gate.sh`](tools/tests/test-shellcheck-gate.sh) seds the
      **shipped** step out of `ci.yml` and runs it against planted fixtures on every push —
      a script with an unguarded `cd` must fail it **and raise the linted count by one** (a
      gate that fails for some other reason is not evidence it saw the file), excluding that
      file must silence it, and an exclusion naming a path that no longer exists must fail
      **by name**. The step itself also refuses a selection that collapsed to fewer than
      `total - 10` files, because a glob typo presents exactly as a clean pass over almost
      nothing.

      Writing the control caught the usual thing: its first extraction pulled in the
      *following* step's `- name:` line, so it reported "the extracted step does not parse as
      bash" — true, and about YAML rather than about the step.

### 11.4 Nothing asks whether a verb a doc types actually exists

Two of the nine findings in
[`REVIEW-docs-micro-cloud-maas.md`](REVIEW-docs-micro-cloud-maas.md) (**D5**, **D7**) were
documents naming verbs the tool refuses, and both were found **by hand**. `link_check.py`
verifies that a link resolves and has no opinion on the sentence around it;
`tools/check-guided-path-is-a-view.sh` asks this question already, but only of the
*rendered plan* and `install-catalog.toml`.

- [x] **11.4** — **done 2026-08-23.** [`tools/check-doc-verbs.sh`](tools/check-doc-verbs.sh),
      gated in the `docs` job. Measured on the whole corpus: **191** distinct `<tool>.sh
      <verb>` commands across **440** documents, **0** hard failures.

      It does **not** grep the dispatch table. `verb_present` — which asks the tool, since a
      driver answers a verb it lacks exactly as it answers a verb nobody has — was lifted out
      of `check-guided-path-is-a-view.sh` into [`tools/lib/verb-probe.sh`](tools/lib/verb-probe.sh)
      and is now **shared**, because a copy drifts from its subject and then proves something
      about the copy.

      **The false positives were the whole job, exactly as this entry predicted**, and every
      rule that separates them was measured rather than guessed:

      | what looked like a broken command | what it actually was | how it is told apart |
      |---|---|---|
      | `tools/pxe-fetch.sh probe` ×4 | a real tool, addressed from the **lab root** — the README lives inside `examples/pxe-boot-mechanics/tools/` | resolve repo-root, then the doc's directory, then each ancestor |
      | `phase{N}-*/lab-*.sh` | metasyntax describing a *shape* | a token containing `{}*<>$` is never a path |
      | `` `lab-chroot.sh up` `` in `phase6-tui/SHOWCASE.md` | the doc **explaining that no such verb has ever existed** | an inline span is a mention, not an instruction |
      | `$ phase1-chroot/lab-chroot.sh up --config mc.toml` | a **transcript** of what a planner once emitted | a `$ ` prompt marks a recording |

      That last rule is the one worth keeping: it is measured, not assumed. Counted across
      every tracked document, **1234** command lines sit in ` ```bash ` fences with **no**
      prompt, while **all 74** in untagged fences carry `$ `, as do the 26 in ` ```console `.
      The convention is unambiguous, so the prompt decides — and an early draft *stripped the
      prompt before classifying*, erasing the one signal that answers the question.

      **A fourth was caught by CI, on the checker's first production run, and it is the best
      one:** the `docs` job failed on **`TODO.md` — this entry**, whose table above quotes
      `tools/pxe-fetch.sh probe` inline as an *example of a false positive*. The missing-tool
      branch fired before the class was consulted, so a path quoted in a sentence was graded
      as a broken instruction. The checker was right that no such path resolves from the repo
      root and wrong that anyone was being told to run it. A tool whose own documentation
      trips it is a tidy demonstration that prose and commands are not separable by shape.

      **Three more were caught by its own controls**, each on the run that introduced it: an indented code block was invisible (Markdown code without a fence);
      `grep -vE '\t…'` matched a literal **`t`**, silently dropping every line ending in that
      letter — including its own fixtures `… lab-lxd.sh list`; and the arguments to
      `check_doc_command` were passed in the wrong order, so `class` held the document path
      and every hard mismatch quietly degraded to a warning. A checker grading its own
      findings down to advisory is the failure mode it exists to prevent.

      **Two verdicts short of PASS, both named rather than counted as passes:** 14 bare-name
      mentions reported for a human (prose and a command are structurally identical there —
      *"`preserve.sh` two tiers"* parses exactly like *"`lab-fc.sh clone`"*, and a checker
      that cannot tell them apart must not fail a build on the guess), and **79 commands left
      UNPROBED by a safety boundary**. That boundary is a list, one week after 11.3b deleted
      one — the difference being the direction it fails in: a coverage list silently
      under-covers, while this one names every row it declined. It exists because this checker
      **invokes** verbs, and the first repo-wide run reached `smoke-nvram.sh all`,
      `mlbuild.sh` and `build-verifying-rom.sh`. Nothing was harmed — no taps, no VMs, no
      stray files, and each call is bounded to 30s — but *"it happened not to break
      anything"* is not a safety argument.

**11.4a's first finding was against the checker itself, and it did damage.** Recorded here
because a tool that harms what it inspects is the one thing this repo's probe-safety note
says must never happen — and it happened, to the tool written by the note's own reasoning.

On **2026-08-23** `check-doc-verbs.sh` probed **`vbmc-lab.sh destroy`**, and the verb did its
job: it removed the `vbmcd-lab` container, undefined the `alpine-node` domain, and removed
the `vbmcd:lab` image. (The lab's own design leaves the disk image and the `state/vbmc/*`
BMC configs, so it was a recoverable teardown rather than data loss — but that is the lab's
mercy, not the checker's.) It had been doing this on **every run, locally and in CI**, along
with `lab-chroot.sh destroy`, `lab-vm.sh destroy`, `lab-docker.sh down` and `lab-lxd.sh down`
— all of which happened to refuse only because no instance of that name existed.

**The allowlist asked the wrong question.** *"Is this tool a driver?"* is not a safety
question: a driver is exactly the kind of tool whose destructive verbs **work**. The verb has
to be asked about too, so `verb_is_destructive` now beats the allowlist and turns those rows
into named UNPROBED entries instead of invocations. It matches **prefixes**: an exact-match
first draft sailed past `sandbox.sh down2`, whose own usage line reads *"destroy the two-node
pair"* — the same defect wearing a digit. Measured after: **0** safety warnings (there is
nothing left that acts), 89 probed, 17 rows declined as destructive.

**11.4a, partly closed 2026-08-23.** Two new oracles, both measured and both labelled as
weaker than tier A:

**Tier B — ask the tool, never run one of its verbs.** A *nonce* verb is the safest possible
call (no tool has it, so a dispatching tool can only refuse), and `--help` is no more
dangerous than the nonce. Read the pair and compare the document's verb against what the tool
says it accepts. It is layered, because "only the nonce" still invokes something: a script
with no dispatch is filtered out **statically** and never invoked at all. The grep is a
**pre-filter for safety**, not the oracle. And a **thin answer is not evidence of absence** —
if the tool did not print something verb-list-shaped, the row stays UNKNOWN rather than
becoming a finding. Without that rule, sourced driver libraries (`verify-lib.sh`,
`install.sh`) produced "does not list" warnings for interface verbs they implement fine.

**Subverbs**, the third category the earlier triage named: `lab-fc.sh restore` is shorthand
for `snapshot restore`. **The pattern was wrong four times, each looking right**, and every
one was caught by measuring rather than reading:

| the pattern | what it actually matched |
|---|---|
| `(…\|\$)` as an end-anchor | `\$` in a double-quoted string is a **literal dollar**, so it demanded a `$` character |
| `[[:space:],}\)\]]` | a backslash inside a **bracket expression** is not an escape in POSIX ERE — the class closed early and left a stray `]` to match |
| `[^a-z]*restore` | the prose *"create needs it RUNNING; restore needs it STOPPED"* |
| `[a-z0-9\|,-]*up` | the **suffix** inside `--groups group,group` — which excused `lab-chroot.sh up`, the very verb two documents quote as never having existed |
| `([a-z0-9,-]+[\|,])*boot` | repeats **zero** times, collapsing to `<word> <verb>`: *"install at first boot"* |

The fix asks the real question instead of approximating it: the character immediately before
the verb must be a group separator, because a usage block writes `<parent> {a|b|verb|c}` and
prose never puts `|` `,` `{` `(` against the word. **The control fixture is what exposed it**
— a clean usage block failed while the live run reported three "subverbs", all prose.

Measured after: **106 probed** (was 89), 15 by tier B, 1 genuine subverb, 11 warnings, **78
unprobed** (was 93), 0 hard failures.

- [x] **11.4a** — the warning tail is **CLOSED 2026-08-30**; the unprobed set is a **named
      boundary**, not a backlog. The entry called for *"the document to say which it meant —
      a convention, not a regex"*, and that is what shipped.

      **0 undecided warnings**, from 11. Two of them were never ambiguous at all: `#` was
      being read as a **root prompt**, so `# gen-almalinux-ks.sh stays in netboot/` and
      `# lab-vm.sh also needs jq` had the English words *stays* and *also* parsed as verbs.
      Measured across the corpus: all **25** `# <repo-tool>` lines inside fences are
      comments; this repo writes privilege as `sudo`, never as a `#` prompt. A comment is
      prose by definition, so it is now skipped — which also means ~25 commented-out
      commands are no longer read at all. They were warning-only before, so nothing that
      could *fail* was lost, and that trade is deliberate rather than accidental.

      The other nine are declared in [`.doc-verb-mentions`](.doc-verb-mentions), each with
      its reason: six are rows in the micro-cloud plan's table *whose whole subject is which
      verbs `lab-fc.sh` does not have*, two are TODO entries quoting this checker's own
      false positives, one is a SHOWCASE quoting a planner's broken output. **A declaration
      cannot reach a fenced command** — only inline/table rows consult the file — or the
      mechanism would be a way to bless an instruction someone will copy. Entries are
      refused when the document is gone, and when they silence nothing (which covers *"the
      tool has since gained the verb"* without a second probe).

      **Why it matters that the list is now empty:** eleven permanent warnings is a list
      everybody learns to scroll past, and a new one would have arrived looking exactly like
      the noise. The same argument this checker already made about UNKNOWN rows, turned on
      its own output.

      **Two of its own controls found defects in the change**, both the same shape — a
      rehearsal mutating production state:

      | | |
      |---|---|
      | §0's fixtures append to the same `WARNINGS` array the report reads | the run printed *"1 warning(s) — see the ! lines above"* with **no `!` line anywhere above it** |
      | §0.2b drives the declaration machinery by assigning `MENTIONS` directly, and left it **empty** | the real run then reported 9 undecided warnings and 0 declared — the controls had disabled the feature they had just proved |

      **And the first draft of the staleness check crossed the probe-safety boundary**: it
      called `verb_present()` directly to ask whether a tool had *since gained* a declared
      verb, invoked `pxe-fetch.sh probe`, and reported that the call *"does not look like a
      refusal"* — i.e. it may have done work. The vbmc-destroy lesson, committed by the
      guard against stale exemptions. The run already answers that question (a tool with the
      verb never reaches the declaration), so the probe was deleted rather than fixed.

      **What remains UNPROBED is 77 rows in four named groups, and it is a boundary rather
      than a tail:** 17 destructive-by-verb (never invoked, by policy — correct forever), 25
      with no verb dispatch, 25 whose tool did not answer a nonce with a usage block, 10
      whose answer was too thin to list verbs. Each is printed by name on every run. A tool
      with no dispatch has no self-description to read, and inventing one would be the guess
      this checker exists not to make.

### 11.5 Open question left by D8: should `lab-fc.sh` take an env override for the VMM?

`lab-fc.sh` resolves Firecracker with `command -v firecracker` in three places and honours
no override, while **every test in micro-cloud** resolves it from the workdir via
`MC_FIRECRACKER`. Two answers to *"where is the VMM"*, and only one is reachable from the
tool. D8 fixed the **doc** (the precondition block now carries the `export PATH`), which
was the honest fix for an audit with no mandate to change a driver.

- [x] **11.5** — **decided 2026-08-23: yes.** `lab-fc.sh` honours **`$LAB_FC_BIN`**, and
      falls back to `command -v firecracker` when it is unset. That default is load-bearing
      rather than polite: phase 7 stands in a VMM by PATH-shimming a fake `firecracker`, so
      anything that stopped consulting `PATH` would take seven tests with it. It does not
      relax the toolchain-fetch gate — somebody still has to stage the binary; the driver
      merely stops insisting it be on `PATH`.

      **Mapping the blast radius first found the reason to be careful, and it was not the
      five call sites.** `_running_pid` identified the VMM by grepping `/proc/<pid>/cmdline`
      for the **literal string `firecracker`** — so an override pointing at `fc-v1.16.1`
      would answer NOT RUNNING for a VMM that *is* running, and `stop` would then report
      nothing to stop and leave the guest behind. The override created that hazard; the fix
      greps the resolved binary's basename. Measured: against the row-4 fixture the old
      literal misses the process entirely, the basename matches it.

      Six rows in [`tests/test-vmm-override.sh`](phase7-firecracker/tests/test-vmm-override.sh),
      all green, 20/20 for the suite: the override selects the VMM; an override naming no
      file and one naming something non-executable are each refused **by name** (a silent
      fallback would run a *different* VMM and report success to the one person — the
      operator with a typo — who would believe it); `preflight` reports the binary **and its
      source**; the liveness check follows the override; and with `$LAB_FC_BIN` unset `PATH`
      still decides. The row-4 control asserts the fixture's argv does **not** contain
      `firecracker`, so the row cannot pass against the pre-fix driver.

      D8's doc workaround is retired: `examples/micro-cloud/MANUAL_TESTING.md` now exports
      `LAB_FC_BIN` instead of prepending to `PATH`.

      **It does not by itself close 11.2(b)'s six firecracker-gated rows.** Those need a
      binary present, which CI still has no sanctioned way to obtain; what changes is that
      staging one anywhere is now enough.

      **Finished properly on a re-audit the same day**, after "is 11.5 thoroughly done?" was
      asked and the answer turned out to be no. The driver change was complete; three things
      around it were not, and the third is the one that mattered:

      1. **`--help` never mentioned the knob.** A tool that honours an environment variable
         and does not document it is the doc-drift class this repo keeps finding. `--help`
         now has an `environment:` section naming `LAB_FC_BIN`, `LAB_STATE_DIR` and
         `FC_PINNED_VERSION` — and it is comment-extracted rather than a heredoc, so the
         usage-is-data hazard does not apply.
      2. **Three RUNBOOKs still told the reader to use `PATH`**, and one of them asserted
         *"`firecracker` must be on `PATH`"* — a present-tense claim that the driver change
         had just made **false**. Two were instructions and are updated; the third is a
         **dated transcript**, so the note goes *beside* it rather than over it. A transcript
         records what happened, and editing one to match today is falsifying a record.
      3. **Four micro-cloud files resolve the binary themselves AND shell out to
         `lab-fc.sh`** — which is the D8 seam itself, not a side-effect of it. Adding an
         override without wiring those would have made two answers into **three**. Each now
         `export`s `LAB_FC_BIN="$FC_BIN"` beside its own resolution, so both halves run the
         same binary rather than the same version by luck. Re-run after: the override test,
         `test-isolation-matrix.sh` and `test-mmds-answers-inside-the-guest.sh` pass;
         `test-edge-on-the-fabric.sh` skips for root, as it did before.

---


---

## 12. Spike 3 — boot Linux from the **64-bit** firmware ✅ **DONE 2026-08-25**

*Added 2026-08-24, after Spikes 0–2 and P0–P3 landed (#280–#288); **done
2026-08-25**.* The last rung of the port.

**`./showcase-rival-boots-linux.sh amd64` → `PASS`.** The checkpoint below was
met unchanged. What the plan below got right: the loader port's size and shape,
and that `load-base` would not need x86's C-side workaround. What it got wrong
is recorded as corrections **13 and 14** in
[`X86-64-FEASIBILITY.md`](examples/openbios-the-rival-that-shipped/X86-64-FEASIBILITY.md#what-the-audit-corrected),
and the five *silent* failures it did not anticipate are in
[§ Spike 3, run](examples/openbios-the-rival-that-shipped/X86-64-FEASIBILITY.md#spike-3-run-the-64-bit-firmware-boots-linux--measured-2026-08-25).
The short version, because it generalises: **`arch/amd64` does not relocate, so
the firmware sits at the 1 MiB a bzImage runs at**, and three of the five
defects are `arch/x86/linux_load.c` assuming otherwise — including an initrd
placement that underflowed to `0xff501000` and a kernel read that overwrote the
running firmware mid-read with no fault to report.

**The one to remember:** `unsigned long type` in `struct e820entry` is 4 bytes
on i386 and 8 on LP64, so the zero page's 20-byte entries became 24. The kernel
saw one memory range instead of two, decided it had 640 KiB, and panicked in
`init_mem_mapping` **before `console_init`** — so the panic went to the printk
ring buffer and never to a console. A correctly-running kernel, completely
silent, for an hour. It is now a **build** error (`LINUX_ABI_ASSERT`), because
the runtime symptom is nothing at all.

*The original plan follows, unedited, since being wrong in an interesting way is
the point of keeping it.* Everything below the loader worked in long mode; this
item was about the loader.

**Checkpoint** (unchanged from
[`X86-64-FEASIBILITY.md`](examples/openbios-the-rival-that-shipped/X86-64-FEASIBILITY.md)):
*the existing [`showcase-rival-boots-linux.sh`](examples/openbios-the-rival-that-shipped/showcase-rival-boots-linux.sh)
success signature — `Welcome to u-root!` — unchanged, from the 64-bit firmware.*

### Start here: three blockers, measured at the 64-bit prompt on 2026-08-24

Driven through `./run-openbios-qemu.sh amd64` with the showcase ISO attached.
**None of these was known before typing at the prompt**, and the first is
cheaper than anyone had assumed:

```console
0 > dev /ide@1 ls
14be28 cdrom@0                         \ IDE enumerates in long mode — fine
 ok
0 > dir /ide@1/cdrom@0:\
Probing for ext2fs
Probing for reiserfs
Unknown filesystem type                 \ <-- BLOCKER 1
Unable to locate device /ide@1/cdrom@0:\ ok
0 > boot /ide@1/cdrom@0:\vmlinuz console=ttyS0
[amd64] Booting file '/ide@1/cdrom@0:\vmlinuz' with parameters 'console=ttyS0'
[amd64] linux_load is STUBBED in this build (Spike 1).   \ <-- BLOCKER 2
Unsupported image format
Trying disk...
load-base: undefined word.              \ <-- BLOCKER 3
```

1. **The ISO9660 driver is not compiled in.** `config/examples/amd64_config.xml`
   has `CONFIG_FSYS_ISO9660 = false`; the x86 config has it `true`. (`FSYS_FAT`
   and `FSYS_UFS` differ the same way.) **A one-line config flip, not code** —
   do this first, because it is testable on its own: `dir /ide@1/cdrom@0:\` must
   list `vmlinuz` and `uroot.img`. Until it does, nothing about the loader can
   be measured, since the loader never gets a file.
2. `arch/amd64/linux_load.c` is the loud Spike-1 stub. See the port below.
3. **`load-base` is undefined on amd64** — the *same* defect
   [`patches/01-x86-revival.patch`](examples/openbios-the-rival-that-shipped/patches/01-x86-revival.patch)
   fixed for x86, in two places, neither of which has an amd64 arm:
   `forth/admin/nvram.fs` (`s" 4000000" s" load-base" int-config`, under
   `[IFDEF] CONFIG_X86`) and the `feval("%lx constant load-base")` at the end of
   `arch/x86/openbios.c`'s `arch_init`. **Check whether amd64 needs the second
   one at all**: x86 needs it because relocation rebases the GDT so every Forth
   address is segment-relative, and long mode ignores segment bases — so
   `virt_offset` is 0 here and the plain `int-config` may be enough. Do not
   transcribe x86's workaround without asking whether its cause exists.

### The port itself is smaller than the record implied

`arch/amd64/linux_load.c` was described as *"the real file is 647 lines"*.
Measured: **the upstream amd64 original and the live x86 twin differ by 76
insertions and 15 deletions** — 91 lines out of 647. It is a mechanical
substitution of one file API for another:

| dead `loadfs.h` (amd64 original) | live `libc/diskio.h` (x86 twin) |
|---|---|
| `file_open(f)` | `fd = open_io(f)` — an explicit `fd` is threaded through |
| `lfile_read(buf, n)` | `read_io(fd, buf, n)` |
| `file_seek(off)` | `seek_io(fd, off)` |
| `file_size()` | a local static helper: `tell` → `seek_io(fd,-1)` → `tell` → restore |
| — | `close_io(fd)` |

Also dropped in the x86 twin: `uint64_t forced_memsize`. **Take the x86 file as
the base and re-apply the amd64 delta**, not the other way round — the x86 one
already carries revival-patch fixes #5 (grubfs `seek`/`tell`, without which
`file_size()` reports ~4 GB for every file) and #7 (copying the whole setup
header into the zero page).

### Then the 64-bit entry, which is where the thinking is

The `+0x200` entry does **not** dispense with the zero page —
`boot_params` is still built and handed over, and the modern header fields are
still read. What it buys is avoiding the **64→32 mode drop**.

The handoff differs from x86's in a way that will not survive transcription:

```c
/* arch/x86/linux_load.c */          /* arch/amd64: struct context has NO esp/rsp */
ctx->esp = virt_to_phys(ESP_LOC(ctx));   /* <-- no counterpart */
ctx->eip = kern_addr;                    /* ctx->rip = kern_addr + 0x200 */
                                         /* ctx->rsi = <zero page>  <-- already a field */
```

`arch/amd64/context.h`'s comment says it outright: *the frame IS the stack*, so
`switch_to` takes `rsp` from the frame pointer itself and there is no field to
set. And the frame already carries **`rsi`**, which is exactly the register the
64-bit boot protocol wants `boot_params` in. That is a happy accident of
Spike 2's design, not something it was built for — verify it, do not assume it.

**Verify against `Documentation/x86/boot.rst`, do not recall:** the alignment
the 64-bit entry requires, what the loader must have identity-mapped (the
trampoline maps 0–5 GiB with 2 MiB pages — probably enough, but *probably* is
not a measurement), and the interrupt/flag state expected at entry.

### Harness work that comes with it

- **`showcase-rival-boots-linux.sh` needs an `amd64` flavor** — it currently
  takes `multiboot|coreboot` only. Mirror what
  [`run-openbios-qemu.sh`](examples/openbios-the-rival-that-shipped/run-openbios-qemu.sh)
  gained in #288.
- **A `smoke-openbios.sh` track** asserting the *outcome* (u-root reached), with
  a control — the obvious one being the ISO9660 flag back off, which must fail
  at `dir`, not at `boot`.
- The `boot` line is **≤ ~80 chars** — the firmware input buffer drops the tail
  silently. The showcase line is **75** characters (two docs said 78 until
  2026-08-24; a copied integer nobody re-counted).

### Known-good ground to build on

Long mode, the trampoline, SSE, the 64-bit IDT with **recovering** fault
handling, the context switch, `/nvram` on an NVDIMM above 4 GiB, and
`arch/amd64/boot.c` (already re-ported off the deleted `elfload.h`). 14 smoke
tracks, 13 passing. Rebuild with `./build-openbios.sh amd64`; ~5 s warm.

**One thing NOT proven and worth stating:** the fs layer has never read a byte
in long mode. Blocker 1 has been masking it, so *"grubfs works on amd64"* is
currently an **UNKNOWN**, not a pass — the pointer-width bugs that the census
found elsewhere in the tree are exactly the shape that would show up there
first.

## 13. The 1275 encode/decode wordset at a 64-bit cell

*Added 2026-08-24, from [`REVIEW-preboot-forth-binary-structures.md`](REVIEW-preboot-forth-binary-structures.md)
— a review of [`DESIGN-NOTES-preboot-forth-binary-structures.md`](DESIGN-NOTES-preboot-forth-binary-structures.md),
which proposed generalizing the property-encoding wordset into a GNU-poke-like
structure builder. The design question is the notes' to settle; what belongs here is
the four defects the review found in the shipped wordset, all of which bite the amd64
track regardless of whether that toolkit is ever built.*

### 13.1 Two more config flips — **BOTH CLOSED: `LOADER_FORTH` 2026-08-25, `DRIVER_VGA` 2026-08-26**

*Original text kept below the rule, because being wrong in a specific way is the useful
part.* `CONFIG_LOADER_FORTH` **is now `true` on amd64** (parity with x86, builds clean,
`amd64` and `amd64-linux` both still PASS). `CONFIG_DRIVER_VGA` **is now `true` too**, and
getting there cost two patches and turned up a defect on **x86**, where the flag had been
`true` all along — see [§13.1a](#131a-driver_vga-closed--and-the-x86-half-was-broken-too)
below the original text. What the two checkpoints turned into:

**Neither is a one-line config flip, and they are blocked by two unrelated defects
neither of which was recorded anywhere.**

#### The `LOADER_FORTH` checkpoint — **MET**, by a one-call-site amd64 fix

> **Correction.** The version of this entry merged in #294 said this checkpoint
> *"CANNOT be reached"*. That was true of the code as it stood and is **false now**;
> it was reached the same evening. The paragraph below is kept because the reasoning
> that followed from it is still how the cause was found.

```console
0 > load /ide@1/cdrom@0:\marker.fth      \ clean, ok, empty stack
0 > load-base load-size evaluate
SPIKE-FORTH-LOADED
```

**The cause: every `bind_func` before `device_end()` is invisible to `$find`.**
`bind_func` is `is-cfunc` (`libopenbios/clib.fs:17`) is `$create`, and `$create`
defines into the *current* vocabulary — so while a device context is open, the words
land in that node instead of the dictionary. Markers planted through `arch_init` and
probed at the prompt:

| bound | result |
|---|---|
| arch_init's first statement | **MISSING** |
| straight after `openbios_init()` | **MISSING** |
| after `modules_init()` | **MISSING** |
| `platform-boot`, after `device_end()` | **FOUND** |

`$find` works (`dup`, `is-cfunc`, `(does>)` all found — `(does>)` also kills the
"parenthesised names are unfindable" idea). The only thing between the missing and the
found is `device_end()`. **Fix:** move `openbios_init()` after it —
[`patches/14-…`](examples/openbios-the-rival-that-shipped/patches/14-amd64-openbios-init-after-device-end.patch),
one call site, `arch/amd64` only. Control: put it back and both words vanish and
`load` prints `Unable to locate (init-program)!` again.

**Not** fixed by calling `device_end()` *earlier*: that faults
(`set_property: NULL phandle`, GPF at `08:0000000000102ba3`) — the tree is not built
yet at the top of `arch_init`.

#### The arch-neutral pair — **fixed as a LOCAL DIVERGENCE, 2026-08-25**

Two defects, not three: **the fourth does not exist.** This entry recorded *"with 2
and 3 fixed locally, the `go` trampoline still evaluates nothing — UNKNOWN"*. It
was an artifact of a measurement taken before the `eval2` change was in the running
image. With both fixed in a clean tree, `go` works. Named here rather than quietly
dropped, because a retired UNKNOWN that nobody announces is how a phantom defect
gets designed around.

| # | defect | evidence |
|---|---|---|
| 2 | `load-state >ls.file-size` is never set on the `$load` path — `!load-size` writes a *separate* `variable file-size` (`client.fs:37-41`). Two records of one fact | after `load`, `load-base` held `\ marker.." SPIK` — the file, intact — while `>ls.file-size` printed **0** and `load-size` printed `23` (hex; 35 bytes) |
| 3 | **`eval2` does not exist.** The `fword("eval2")` in `initprogram.c` was the only occurrence of that name in the tree; nothing defines it, and `fword()` on a missing word is silent | `load-base load-size eval2` → `eval2: undefined word.`; the same line with `evaluate` prints the marker |

Together they mean **OpenBIOS's Forth-source loader has never evaluated a byte, on
any arch**, for as long as those lines have existed.

**Carried as a divergence, not sent upstream** —
[`patches/15-forth-loader-divergence.patch`](examples/openbios-the-rival-that-shipped/patches/15-forth-loader-divergence.patch).
The reason is a difference in *goals*, not a judgement about the code: upstream
maintains a firmware that boots operating systems under QEMU, and nothing it ships
needs `load` of a `.fth` to work. This lab is a teaching artifact and needs exactly
that path, because loading Forth off media is what makes multi-line test Forth
possible against an ~80-char serial truncation. Handing a maintainer a fix for a
road they do not drive on is a cost to them, not a gift.

Developed in a **separate tree** (`~/openbios-lab-archneutral/`, a full copy that
builds independently via `OPENBIOS_WORKDIR`) because these are the first
arch-neutral lines this lab has touched — `initprogram.c` is shared with x86, ppc
and sparc, and three targets this lab does not exercise should not change on the
strength of an amd64 measurement.

With patches 14 and 15 both applied, `go` works and not just the `evaluate` recipe:

```console
0 > load /ide@1/cdrom@0:\marker.fth
0 > go
switching to new context:
Evaluating Forth...
SPIKE-FORTH-LOADED
```

#### The x86 arm — **done**, and it corrected a claim made here

The binding defect is per-arch, so patch 15 alone was necessary but not sufficient:
x86 built with it and *without* an x86 equivalent of patch 14 still ended `load` in
`Unable to locate (init-program)!`.
[`patches/16-…`](examples/openbios-the-rival-that-shipped/patches/16-x86-openbios-init-after-device-end.patch)
is the identical one-call-site move.

| word | before | after |
|---|---|---|
| `(init-program)` | MISSING | **FOUND** |
| `(go)` | MISSING | **FOUND** |
| `platform-boot` | FOUND | FOUND |

so `CONFIG_LOADER_FORTH` — `true` on x86 all along, over a dead path — finally means
something. x86 regression: `multiboot`, `dict-identity`, `nvram`, `persist`, `floppy`
and the **showcase** all PASS.

**The correction.** This lab briefly recorded `cif-claim`/`cif-release` as a second
instance of the same bug, because they too are invisible to a global `$find`. They are
**not a defect**: they are bound inside `find-device /openprom/client-services … device_end()`
*on purpose*, which installs them as **node methods** — exactly what ppc and sparc do
for those two names via `NODE_METHODS`. The probe answers *"is this word global"*; it
cannot answer *"should it be"*. Only the source does, and it was read before anything
was moved.

**New UNKNOWN:** x86's `go` prints `Evaluating Forth...` and then **hangs**, where
amd64's completes. The `load` + `evaluate` recipe works on both. x86 rebases the GDT
and carries two definitions of `load-base`; either could matter and neither has been
measured.

#### The rule is now a check, not a habit

The ppc run above was nearly missed — `initprogram.c` is built unconditionally for
every arch, and the PR was opened before that track was run. It passed, so nothing
broke; the point is that **nothing would have said so**, and it was caught by a person
thinking to ask.
[`tools/check-patch-scope.sh`](tools/check-patch-scope.sh) now requires any patch
touching a path outside `arch/{x86,amd64}/` to carry `Arch-tested:` naming all three
arches this lab can drive, and the lab's
[`tests/test-patch-scope.sh`](examples/openbios-the-rival-that-shipped/tests/test-patch-scope.sh)
runs it in CI. It proves itself on 8 fixtures first, grandfathers pre-rule patches
**by name with reasons** (a date cutoff grows silently), and states on every run that
**sparc is reachable from these shared files and untestable here** — so "all three
named" can never be read as "all arches covered".

**Working convention that goes with it:** `~/openbios-lab-archneutral/` is a
**scratchpad, not a parallel branch**. Resync it *from* the lab tree when starting a
change that leaves `arch/{x86,amd64}/` — `libopenbios/`, `forth/`, `drivers/`,
`kernel/` — and do arch-confined work directly in the lab tree, where the file path
is itself the blast-radius proof.

*The original diagnosis, kept because it is how the cause was found:* the checkpoint
could not be reached, and **x86 failed identically**, so it was not port work.

`boot <file>` never consults the Forth loader on **either** arch: `arch/{x86,amd64}/boot.c`
call `linux_load()` and nothing else. The generic loader chain in `libopenbios/load.c`,
which is what `CONFIG_LOADER_FORTH` gates, is reached through `load` → `$load`
(`forth/debugging/client.fs:189,135`). Driving that:

```console
0 > load /ide@1/cdrom@0:\marker.fth
Mounted iso9660
Path=/marker.fth
Unable to locate (init-program)!
 ok
2 >
```

`$load` ends with `r> close-dev` then `init-program`, and `init-program` is
`s" (init-program)" $find if execute else ." Unable to locate…" then`. Probed directly at
the prompt, on a build of each arch:

| word | amd64 | x86 | bound by |
|---|---|---|---|
| `dup` | found | — | the dictionary |
| `is-cfunc` | found | — | `libopenbios/clib.fs` |
| `(does>)` | **found** | — | `forth/bootstrap/bootstrap.fs` |
| `platform-boot` | **found** | — | `bind_func` in `arch_init`, **after** `device_end()` |
| `(init-program)` | **MISSING** | **MISSING** | `bind_func` in `openbios_init()` |
| `(go)` | **MISSING** | — | `bind_func` in `openbios_init()` |

So `$find` works, `bind_func` works, and the two words bound inside `openbios_init()` are
the ones that are gone. **Two hypotheses were tested and both are refuted:**

- *"parenthesised names are not findable"* — `(does>)` is found. Refuted.
- *"`is-cfunc` uses `$create`, which defines into the current vocabulary, so an active
  device context at `openbios_init()` time swallows them"* — adding `device_end()` before
  `openbios_init()` in `arch/amd64/openbios.c` produced `set_property: NULL phandle` and a
  **general protection fault at `08:0000000000102ba3`**, named by Spike 2's handler.
  Reverted. That disproves the *fix*, and leaves the ordering idea unproven either way.

**Cause: UNKNOWN.** The symptom is reproducible on both arches and the instrument has been
checked against known-present words of the same shape. Next probe: whether `openbios_init()`
runs at all at that point (`bind_func` a throwaway marker as its first statement and look
for it), which separates *"never called"* from *"called, words land somewhere unreachable"*.

**Consequence for the flip:** `CONFIG_LOADER_FORTH=true` is a genuine prerequisite —
`forth_load.c` is only compiled under it, and `is_forth()` dispatch in
`libopenbios/initprogram.c` only exists under it — but it is **inert today**, and the entry
says so rather than letting a landed config change imply a working feature.

#### The `DRIVER_VGA` checkpoint needs code, not a flag

`drivers/pci.c:1045`'s `feval("['] vga-driver-fcode 2 cells + 1 byte-load")` lives in
`vga_config_cb`, which runs only while enumerating a VGA-class PCI device. **amd64 never
enumerates PCI at all**: `arch/x86/openbios.c:438` calls `ob_pci_init()` and then
`ob_ide_init("/pci/isa", …)`; `arch/amd64/openbios.c` calls **only**
`ob_ide_init("/pci/pci-ata", …)`, against a hardcoded path, with no `ob_pci_init()`
anywhere. The amd64 boot log shows it — none of the `Cannot manage 'PCI host bridge'`
lines x86 prints appear.

So flipping `CONFIG_DRIVER_VGA` would compile `vga_load_regs.c`, `vga_set_mode.c` and the
`QEMU,VGA.bin` FCode blob into a build where **nothing ever calls them**. Note also that
`vga_config_cb`'s `feval` is *not* guarded by `CONFIG_DRIVER_VGA`, so on any arch that does
enumerate PCI with VGA off it would execute an undefined word — masked here only by the
missing enumeration. **Real scope:** wire `ob_pci_init()` into amd64's `arch_init` and move
IDE onto the probed path. That is Spike-sized, not a flip, and it should be its own item.

> **Half of that last sentence is wrong, and §13.1a says how.** There is no probed path to
> move IDE onto: `drivers/ide.c:1519` names its `const char *path` argument and never reads
> it again. And the `feval` being unguarded turned out to matter far more than "masked here
> by the missing enumeration" — it has been failing on **x86**, every boot, for years.

#### And the header was wrong

It said *"Three more config flips"* and the body listed **two**. Measured 2026-08-25 after
§12 closed: `ISO9660` now agrees, **six** shared options still differ
(`DEBUG_FS`, `DRIVER_VGA`, `FSYS_FAT`, `FSYS_UFS`, `HFSP`, `LOADER_FORTH`), so the
"six-row diff" the original text described was **seven** at the time it was written. Two
further options — `CONFIG_DEBUG_FLOPPY` and `CONFIG_DRIVER_FLOPPY` — exist in the x86
config and **not at all** in amd64's, a third category the original missed.

---

*Original text, 2026-08-24:*

> ### 13.1 Three more config flips, found the same way blocker 1 was
>
> §12's blocker 1 (`CONFIG_FSYS_ISO9660`) is one row of a six-row diff between
> `config/examples/x86_config.xml` and `config/examples/amd64_config.xml`. Two more are
> in-scope work, not cosmetics:
>
> - **`CONFIG_LOADER_FORTH`** — `true` on x86, `false` on amd64. Until it is on, every
>   line of test Forth has to be typed at the serial prompt, through the ~80-char
>   truncation §12 already records. **Checkpoint:** a `.fth` loaded off media prints its
>   own marker.
> - **`CONFIG_DRIVER_VGA`** — `true` on x86, `false` on amd64. `drivers/pci.c:1045`
>   (`feval("['] vga-driver-fcode 2 cells + 1 byte-load")`) is the **only in-tree FCode
>   execution on the x86 side**, so with VGA off, amd64 has never evaluated a byte of
>   FCode. **Checkpoint:** `byte-load` reached at all — which would also be the first
>   FCode ever evaluated at a 64-bit cell in this tree.

### 13.1a `DRIVER_VGA` CLOSED — and the x86 half was broken too

**2026-08-26, patches 17 and 18, `./smoke-openbios.sh vga`.** The flag is now `true` on
amd64. The Spike had two halves, and only the first was the one §13.1 predicted.

#### Half one: amd64 had no PCI bus (patch 17)

`CONFIG_DRIVER_PCI` was already `true`, so `drivers/pci.c` was compiled and linked — and
`arch/amd64/arch_init()` never called `ob_pci_init()`. Copying x86's five-line preamble
(`arch = &default_pci_host`, `find-device /`, `open-dev to my-self`, the call, `0 to
my-self`) gives amd64 the bus it never had:

| at the amd64 prompt | before | after |
|---|---|---|
| `dev /pci8086,1237@0` | *no such device* | 5 children |
| `openbios-video-width` | `0` | `320` (hex; 800) |
| `Cannot manage 'ISA bridge' …` in the boot log | absent | present, as on x86 |

Two things §13.1 got wrong, both found by measuring rather than reading:

- **"Move IDE onto the probed path" cannot be done, because there is no such path.**
  `drivers/ide.c:1519` takes `const char *path` and **never reads it again** —
  `ob_ide_init()` calls `new-device` in whatever device context is current. So
  `"/pci/pci-ata"` and x86's `"/pci/isa"` are both inert strings, `dev / ls` shows
  `ide@0..ide@3` at the **top level on x86 too**, and there is **no `/pci` node on either
  arch**. Left as-is with a comment.
- **`include/arch/amd64/io.h` was missing `#include "asm/types.h"`**, which x86's copy has
  always had. `DRIVER_VGA` pulls in `drivers/vga_load_regs.c`, whose include chain reaches
  `include/drivers/vga.h` — and *that* header declares `extern volatile uint32_t *dac;`
  **without including a types header at all**. It has been building on x86 by accident.
  Fixing the shared header would be the more correct repair and needs the ppc/sparc arms;
  the arch's own include dir is where the divergence is.

#### Half two: the FCode blob was defined into the ROOT NODE, on both arches (patch 18)

With PCI wired and `DRIVER_VGA` on, `vga_config_cb` still did not work — and the reason
turned out to be **the same defect as patches 14 and 16, a third time, in Forth**.

`arch/{x86,amd64}/init.fs` line 9 runs `" /" find-device` and nothing closes it. Eighty
lines later, `-1 value vga-driver-fcode` — and `value` is `$create`, which defines into the
**current vocabulary**. Measured on x86 *before* the fix, with the flag `true`:

```
0 > " vga-driver-fcode" $find .        0        \ not found
0 > vga-driver-fcode u.                vga-driver-fcode: undefined word.
0 > dev / " vga-driver-fcode" $find .  -1       \ found — inside root
0 > dev / words                        vga-driver-fcode preopen make-openable …
```

`drivers/pci.c:1045` runs its `feval` with the **PCI device node** current, not root, so
the lookup failed on every boot. **The VGA FCode driver had never been evaluated on x86
either** — on the arch where the flag has been `true` for years.

**Why nobody noticed, and it is the sharpest part.**
`forth/bootstrap/interpreter.fs:64` reports an unresolvable token with `type 3a emit` — the
word, then a colon — then throws `-13`. `feval`'s caller prints no status. So the entire
failure is the string

```
vga-driver-fcode:
```

with **no newline**, no *"undefined word"*, and the next `printk` landing on the same line.
It reads as a progress marker. This lab had already written that exact string into
`drivers/floppy.c` as a **boot landmark** (*"hung … right after `vga-driver-fcode:`"*).
A cheap check for the string's *presence* would therefore have asserted the **defect**;
the `vga` track asserts its **absence**, scoped to the boot output before the first prompt
so the probe's own command echo cannot answer for it.

**Why it survived upstream:** `arch/ppc/ppc.fs` carries the same block and **never calls
`find-device`**, so on ppc the word is global and the driver has always loaded. Verified
unchanged by this work — ppc answers `-1` before and after. It is broken only on the two
arches nobody boots.

#### The fix, and what it measures

One word — `device-end`, before the block — on both arches:

| | x86 | amd64 |
|---|---|---|
| `" vga-driver-fcode" $find .` | `-1` (was `0`) | `-1` (was `0`) |
| `vga-driver-fcode:` in the boot log | gone | gone |
| `openbios-video-width` | `320` | `320` (was `0`) |
| `QEMU,VGA@0` under the host bridge | present | present (new) |

The two patches are **independent**, and that was measured rather than assumed: rebuilding
amd64 with patch 18 re-injected still shows `W=320` and `QEMU,VGA@0` while `F` drops back
to `0` — enumeration and reachability are separate failures.

**Negative control, run not reasoned.** The `device-end` was deleted from
`arch/amd64/init.fs`, amd64 rebuilt, and the track fired:

```
FAIL: REGRESSION: amd64 printed 'vga-driver-fcode:' during boot — that is
interpreter.fs:64 reporting an unresolvable token, not progress …
```

The same broken image also prints `F=0`, so the second assertion would have fired had the
first not exited. All eleven other smoke tracks pass on x86, amd64 and ppc.

#### The second unbalanced site: amd64's prompt was never clean (patch 19)

Asked afterwards whether any of this is a defect in the **Forth definition machinery**.
It is not — and asking produced a fourth instance of the same shape.

`active-package!` (`forth/device/package.fs`) is faithful IEEE 1275:

```forth
: active-package! ( phandle -- )
  ?dup if
    forth-wordlist over >dn.methods @ 2 set-order
    >dn.methods @ set-current          \ definitions land in the NODE
  else
    forth-wordlist dup 1 set-order set-current
  then ;
```

Defining into the active package is not a bug, it is *how* `: open ... ;` inside
`new-device`/`finish-device` becomes a node method. Nothing to fix in `$create`, `value`
or `variable`.

**But the measurement that settled it found a second unbalanced `find-device`.** Asked
what was actually active at the prompt:

| | `active-package` | `pwd` | `get-order` |
|---|---|---|---|
| **x86** | `0` | *no active device* | `1` |
| **amd64** | `0x13d708` | **`/chosen`** | `2` |

`arch/x86/init.fs:52` ends `preopen` with `device-end`; **amd64's copy never did**, so the
last `preopen` of the `SYSTEM-initializer` left `/chosen` active for the rest of the boot.
Every definition made at the amd64 prompt was silently a method of `/chosen`:

```
0 > variable la  5 la !  la @ .    5  ok
0 > device-end  la @ .             la: undefined word.
```

Defined, usable, then gone — `device-end` sets the order back to `[forth-wordlist]` alone
and the word was never in it. **This has nothing to do with `evaluate`**, which is how it
was first (wrongly) explained: the two lines above were typed straight at the prompt. It
surfaced inside a multi-line probe only because a probe is the kind of thing that walks the
tree between defining a word and using it.

| arch | line-9 `find-device` closed | `preopen` closes | prompt |
|---|---|---|---|
| x86 | no → patch 18 | **yes** (`:52`) | clean |
| amd64 | no → patch 18 | **no** → patch 19 | `/chosen` active |
| sparc64 | yes (`device-end :51`) | no | **UNVERIFIED** |
| sparc32 | yes (`device-end :38`) | no | **UNVERIFIED** |
| ppc | never opens one | n/a | **UNVERIFIED** |

Each arch got a different subset of the two sites right, which is why **one** defect kept
presenting as **four** unrelated symptoms: `(init-program)` missing, `(go)` missing, the
VGA blob unreachable, and a variable that evaporates.

After patch 19 amd64 gives x86's answer exactly: `active-package 0`, *no active device*,
order `1`. The `amd64` track asserts the **outcome** — a variable defined at the prompt
survives `device-end` — not `active-package u.`, which is the mechanism. The same probe
went into the **`multiboot`** track as its control: x86 has always passed it, which is what
separates *"the fix works"* from *"the probe cannot fail"*.

**Deliberately not fixed:** `arch/sparc64/init.fs` and `arch/sparc32/init.fs` have the
identical omission. This lab cannot boot sparc, so they stay an UNKNOWN rather than a blind
patch — [`tools/check-patch-scope.sh`](tools/check-patch-scope.sh) would demand an
`Arch-tested:` line naming three arches, and no honest one can be written for a sparc file.

#### Still open, and named rather than folded into the pass

- **`" screen" find-dev` returns `0` on both arches.** The FCode installs the node and its
  properties; nothing creates a `screen` devalias, so nothing points at the display. The
  `vga` track prints this as an `UNKNOWN` note on every run.
- **The `QEMU,VGA@0` node cannot be reached by path.** `ls` under the host bridge lists it,
  but `dev /pci8086,1237@0/QEMU,VGA@0` — and the relative form — both answer *no such
  device*, on x86 as well. `pnodename` and `pathres` disagree about that node's unit
  address. Unmeasured beyond that.
- ~~**`arch/amd64/init.fs`'s `preopen` has no `device-end`**~~ — investigated the same day
  and fixed by **patch 19**, above. It was the second unbalanced site, not a curiosity.
- ~~**The `feval` that reports nothing.**~~ — **CLOSED 2026-08-26, patch 20.** See
  [§13.1b](#131b-the-silence-all-four-defects-hid-behind--closed-2026-08-26) below.

### 13.1b The silence all four defects hid behind — **CLOSED 2026-08-26**

**Patch 20, arch-neutral, `Arch-tested: x86 amd64 ppc`.** `./smoke-openbios.sh diagnostics`.

`feval()` has **always** returned the throw code — `eword()` wraps the call in `catch` and
hands the result back. Counted in this tree at `e5ac46d`:

| binding | call sites | that look at the return |
|---|---|---|
| `feval()` | **146** | **1** |
| `fword()` | **969** | **0** |

The one is `packages/cmdline.c:257`, the interactive command line, which pushes the code
straight into `print-status`. Everywhere else a Forth fragment that threw — or a word that
was not in the dictionary at all — executed nothing, said nothing, and the C caller carried
on as though it had worked. **Every defect in §13.1 and §13.1a hid behind that**, and they
are all one failure: *the word is not where the caller is looking.*

**Why the old output was worse than nothing.** For an undefined word the interpreter *does*
print something — `interpreter.fs:64` does `type 3a emit`, the word then a colon — and then
throws into a caller that prints no status. So the entire failure is `vga-driver-fcode:`
with no newline, and the next `printk` lands on the same line. It reads as progress. The
new line **completes** that half-message instead of competing with it.

#### Three things the patch got wrong first, each caught by measuring

1. **`%.96s` printed a mangled half-line — and that is a real bug in `libc/vsprintf.c`.**
   Its `%s` case has the correct `strnlen(s, precision)` under an `#if 0`, and the live
   branch is `len = mstrlen(s); if( precision > len ) len = precision;` — **precision is a
   MINIMUM, not a maximum.** `%.96s` on a 13-byte string prints 96 bytes, 83 past the
   terminator. Clipped in C instead, and the printf bug **fixed separately in
   [§13.1c](#131c-s-precision-was-a-minimum--closed-2026-08-26)** — a message written to
   end a silence, silenced by the printf it was written with.
2. **Reporting on the interactive path is noise.** First draft: `pwd` at the prompt printed
   `no active devicefeval: pwd -- threw -2 (...)` then ` Aborted.` — the same failure said
   twice, once by a layer with no business saying it. A channel that fires on ordinary typos
   is one people learn to ignore, which **recreates the silence being fixed**.
   `feval_quiet()` exists for the one caller that renders the status itself.
3. **The code is `-19`, not `-13`, and both are right.** OpenBIOS's Forth runs in **base
   16**, so `-13 throw` in `interpreter.fs` is hex — decimal `-19`, which is why
   `kernel/bootstrap.c` says `case -19:` for *"undefined word."* while the Forth table says
   `-13`. The message prints both. The first draft of the smoke assertion looked for `-13`
   and went **red against a working reporter**. No C copy of the code→name table was made —
   this file's history says copies drift — so the message names where the table lives.

#### The track is two-sided in a single boot

| | assertion |
|---|---|
| **silent when healthy** | a clean boot prints **zero** `feval:`/`fword:`/`eword:` lines on x86, amd64 and ppc |
| **loud when it should be** | `test-feval-report` prints **exactly one**, naming a word that cannot exist, with its code in both bases |

Neither half is worth having alone: the first reads identically whether the reporter works
or was compiled out, and the second would pass a reporter that fires on everything.
`test-feval-report` is bound in `libopenbios/init.c` — one definition for all three arches,
and the reporter's own **must-catch fixture** rather than a real failure someone has to
remember to keep broken.

**Negative control, run not reasoned.** Patch 18's defect re-injected (the `device-end`
removed from `arch/amd64/init.fs`) alongside a bogus `fword("no-such-word-control")`. Both
branches printed and the silence assertion bit — **and the control immediately found a flaw
in the assertion itself**: it matched `^(feval|fword|eword):` and reported **1** failure
where there were **2**, because the undefined-word case *continues* `interpreter.fs`'s line
and never starts one. A line-anchored regex standing in for a question about a message —
the mistake [`tools/check-harness-net.sh`](tools/check-harness-net.sh) made twice.
Unanchored, it reports both.

**Not watched to fire:** `_eword()`'s *"word not in the dictionary"* branch. It is reachable
only if `evaluate` itself is missing, which cannot happen in a firmware that has reached the
prompt. Named rather than counted as covered.

### 13.1c `%s` precision was a MINIMUM — **CLOSED 2026-08-26**

**Patch 21, arch-neutral, `Arch-tested: x86 amd64 ppc`.** Found by §13.1b's own diagnostic.

`libc/vsprintf.c`'s `%s` case:

```c
#if 0
    len = strnlen(s, precision);
#else
    len = mstrlen(s);
    if( precision > len )
        len = precision;
#endif
```

C99 7.19.6.1 says precision on `%s` is the **maximum** number of bytes to write, and the
argument need not be NUL-terminated within them. The live branch made it a **floor**:

| format | argument | printed |
|---|---|---|
| `%.3s` | `"abcdef"` | all six characters |
| `%.10s` | `"abc"` | **ten bytes**, seven past the terminator |
| `%.0s` | `"abc"` | `"abc"` |
| `%8.3s` | `"abcdef"` | precision confused with field width |

**The correct call was one line above, under an `#if 0`**, and `libc/string.c:214`'s
`strnlen()` is and always was correct. A live line somebody disabled, not a missing
implementation.

**In-tree victims:** `fs/hfsplus/hfsp_record.c` prints a FourCC that is *not*
NUL-terminated with `%4.4s`, twice. Measured with the defect in place, a 4-byte field
followed by `XYZ!` printed **`ABCDXYZ!`** — eight characters where four were asked for,
from a debug path walking off the end of a struct field.

#### The fixtures run in the firmware, and the control found a hole in them

`test-printf-precision` is bound in `libopenbios/init.c` — one definition for all three
arches — because `kernel/bootstrap.c` `#define`s `printk` to the **host** printf under
`BOOTSTRAP`, so a host harness would exercise glibc and report on OpenBIOS. Six of its
seven cases were wrong before the patch; the seventh, bare `%s`, is the **must-NOT-break**
control (a "fix" routing the no-precision path through `strnlen(s, -1)` would still pass
the other six).

**And this is the part worth keeping.** The first fixture compared with `strcmp()` alone —
and **`strcmp` stops at the first NUL**. `%.10s` on `"abc"` wrote `"abc\0"` plus six bytes
of whatever followed, and `strcmp(got, "abc")` said **equal**. The case that most directly
demonstrates an over-read was the one case the fixture could not see; the control reported
`2/7` and called `no-extend` a pass. `vsnprintf()` returns `str-buf` — what it actually
produced — so the length is now checked beside the bytes:

```
printf-precision: no-extend want[abc](3) got[abc](10) BAD
```

and the control reports `1/7`. **An assertion that can only see up to a NUL is not an
assertion about a function whose bug is writing past one.**

#### The two gaps this section named — **both now measured, 2026-08-26**

`test-printf-edges`, a sibling fixture bound the same way. Eleven cases; the sequence was
**measure, then decide what to assert** — what C99 says and what this firmware does are two
questions, and the second is the one a caller here depends on.

| path | result |
|---|---|
| `number()` precision — a **minimum** digit count, the opposite sense to `%s`, on a different code path | correct in every case except one |
| `vsnprintf` at the buffer edge | **correct in full** — truncates, NUL-terminates, returns the *untruncated* length, and leaves the buffer untouched at `size 0` |

The `size 0` case is checked with a **canary byte**, because a correct return value says
nothing about whether it wrote. And the two `%8.8lx` cases are not decoration: they are the
shape [`arch/ppc/qemu/main.c:58-59`](https://github.com/openbios/openbios) actually prints
four of in its boot path, and a repo-wide grep finds them to be the **only** integer
conversions with a precision anywhere outside the fixture. Test the shipped shape.

#### The one divergence, asserted as itself

`%.0d` of `0` prints `"0"`. C99 7.19.6.1 says *"if the value and the precision are both 0,
no characters are produced"* — `number()` does `if (num == 0) tmp[i++] = '0';`
unconditionally.

**Deliberately not fixed**, and the reasons matter more than the line would:

- **Zero in-tree callers.** The only integer conversions with a precision are ppc's two
  `%8.8lx`, and both are asserted correct.
- **It is harmless** — one extra character, no access past a bound. Unlike patch 21's bug,
  which over-*read*.
- **The one real caller is a boot path on the control arch.** Editing `number()` to serve
  no caller, in front of that, is churn with a nonzero downside.

So the **measured** behaviour is asserted and the C99 answer printed beside it:

```
printf-edges: d-zero C99[](0) here[0](1) DIVERGES-AS-RECORDED
printf-edges: 10/10 ok, 1/1 recorded divergence
```

If someone fixes `number()`, the fixture prints `DIVERGENCE-CLOSED` and the track goes red
on purpose. **A divergence that stops being true has to be visible, or the record quietly
becomes false** — which is this file's cached-fact rule pointed at its own notes.

#### And the same case found a second, ppc-only anomaly

The first version of the assertion folded the **return value** into the pass condition. ppc
went red — and the reason was not the divergence:

| arch | `%.0d` of `0` writes | returns |
|---|---|---|
| x86 | `"0"` | `1` |
| amd64 | `"0"` | `1` |
| **ppc** | `"0"` | **`0`** |

**On ppc, `snprintf` writes a byte and reports having written none.** That is a different
defect from the C99 divergence, and a worse-shaped one: a caller advancing a cursor by the
return value would overwrite the character. All three arches agree on what is *written*;
only the *return* moves.

Which is why the ratio keys on the written bytes and the line prints `wrote=` and `ret=`
separately, with the exact line pinned **per arch** by the track. **A single number cannot
say which half moved** — folding them together made one arch's ratio differ for a second,
unrelated reason and hid both.

**The ppc mechanism is UNKNOWN and is recorded as one.** `number()` takes the `num == 0`
branch, emits one character, and `vsnprintf` returns `str-buf`; why that is `0` there and
`1` elsewhere has not been traced, and **no guess is written down in place of tracing it**.
It has no in-tree caller — the only integer conversions carrying a precision anywhere are
ppc's own two `%8.8lx`, which the fixture asserts correct — so it is named, not fixed, and
the track fails if it ever spreads to another arch.

### 13.1d x86's `go` hung on an uninitialised `load-state` — **CLOSED 2026-08-26**

**Patch 23, arch-neutral, `Arch-tested: x86 amd64 ppc`.** §13.1 carried *"x86's `go` hangs
where amd64's completes"* as an UNKNOWN. It is neither a context-switch bug nor arch code.

```forth
constant load-state.size
create load-state load-state.size allot     \ allot does NOT zero
```

Nothing else initialises it. The six C loaders in `libopenbios/*_load.c` each fill in
`>ls.file-size` for their own format; **the `$load` path fills in none of it.** And
`init_forth_context()` reads that field treating **0 as "nobody wrote this"**.

Measured — same firmware, same 31-byte `.fth`, **both arches loading it correctly**
(`load-size` `0x1f`, first byte `0x5c` on both):

| | `load-state >ls.file-size @` | what `evaluate` got |
|---|---|---|
| amd64 | `0` | fallback fired → **31 bytes** → worked |
| x86 | `0x30000000` | fallback did **not** fire → **768 MB** to interpret as Forth |

That is the hang. **amd64 had been passing by luck**, on the contents of memory.

#### Three lines and a printk

1. **`erase` `load-state` at creation**, so `0` finally means *"nothing was loaded"* rather
   than *"nobody wrote it down"*. Covers `>ls.entry` and `>ls.file-type` too — same
   exposure, and no reader had any way to know.
2. **`!load-size` writes both records of the one fact.** `variable file-size` and
   `load-state >ls.file-size` hold the same number and only the first was set on the
   `$load` path — the "two records" defect [§13.1](#131-two-more-config-flips--both-closed-loader_forth-2026-08-25-driver_vga-2026-08-26)'s
   patch 15 *named and worked around rather than fixed*. Ordering is safe: `$load` calls
   `!load-size` **before** `init-program`, so a C loader still wins with its own value.
3. **A zero size is a refusal with a reason.** `evaluate` of 0 bytes succeeds and prints
   nothing, so an unwritten size looked exactly like a payload with nothing to say — the
   same silence this lab has now chased four times.

#### And it surfaced a second x86 defect, now honest instead of hanging

```
0 > go
switching to new context:
Evaluating Forth...
init-program: nothing to evaluate -- ls.file-size=0 load-size=0 load-base=4000000
```

Comparing the two words the context reads — **by xt and by value**, at the prompt and from
inside:

| word | xt @prompt | xt @context | value @prompt | value @context |
|---|---|---|---|---|
| `load-base` | `13756c` | **`12ebb8`** | `e066fdd0` | `4000000` |
| `load-size` | `12afc8` | `12afc8` | `1f` | **`0`** |

**Those are two different mechanisms wearing one symptom:**

- **`load-base` resolves to a different word** (different xt). `13756c` is the C shadow
  `arch/x86/openbios.c` defines late as `phys_to_virt(LOAD_BASE_PHYS)`; `12ebb8` is the
  earlier constant in `forth/admin/nvram.fs`.
- **`load-size` resolves to the same word** (identical xt) and yields a **different
  number**. That is not a lookup failure at all — the fetch of `variable file-size` returns
  something else.

> **Retraction.** The first write-up of this said the constant *"rules out address
> translation, because a constant would carry the same number through any segment change."*
> **That was wrong.** A Forth constant's value lives in its dictionary body and is *fetched
> at execution time*, through whatever data segment is in effect — a segment change moves it
> like anything else. Reasoning was standing in for a measurement; the table above replaced
> it, and no single-mechanism story explains both rows.

**Beyond that the mechanism is not established, and no guess is recorded in its place.**
amd64 is unaffected — it defines no shadow, because it does not relocate — and runs the
payload.

`go` on x86 therefore goes from a **silent 768 MB walk to a named refusal**, which is the
whole of what patch 23 claims. **Running the payload there is the next item**, and it is
now a debuggable failure rather than a hang.

### 13.3 Measured, named — and (A), (C), (D) and most of (E) since fixed

Everything here was **observed**, not deduced. Where a mechanism is unknown it says so, and
no guess stands in its place. **(A) is CLOSED (2026-08-26)** and **(D) is CLOSED (2026-08-27)** — between them they
account for both entries that had an in-tree caller actually broken. Tracing (A) turned "two
mechanisms, one symptom" into one; tracing (D) turned "pnodename and pathres disagree" into
four bytes in the wrong order. B, C and E have no broken caller today, which is why each
stays recorded rather than repaired.

#### A. x86's client context read a STALE COPY of the firmware — **CLOSED 2026-08-26**

*The original entry is kept below the rule, because the way it was wrong is the useful
part: it recorded two mechanisms where there is one, and said so in as many words.*

`arch/x86/context.c`'s `arch_init_program()` entered the **fcode/forth trampolines** in the
CLIENT program's **flat** segments. Those trampolines are not client programs — their entry
is a firmware function (`init_forth_context()` / `init_fcode_context()` in
`libopenbios/initprogram.c`) which then drives the Forth interpreter. x86 relocates OpenBIOS by **rebasing the GDT**, so
every Forth address is segment-relative; entered flat, the trampoline read each address at
its link-time value — where the **original, un-relocated copy of the image** still sits,
byte-exact, frozen at the instant of relocation. Nothing faults. The copy is valid. It is
merely stale.

Measured at the prompt, reading both windows (`400000 load-base -` recovers `virt_offset`
= `1fd8fe50` from the running firmware, so the stale window is `<addr> 400000 load-base - -`):

| | live | stale |
|---|---|---|
| `forth-wordlist @` | `137808` | `132b08` |
| `file-size @` | `16` | `0` |

That is both rows of the table below, from one cause:

- **The "lookup difference" is not one.** `#order`, `context[0]` and `current` are
  *identical* in the two windows — checked. The stale chain head simply predates the
  `constant load-base` that `arch/x86/openbios.c` defines at the end of `arch_init`, so the
  same `$find` walks past the shadow to `nvram.fs`'s config word.
- **The "fetch difference" is the same address in the other window.** `load-size` is
  `file-size @`; same xt, same address, different memory.

**And amd64 was never affected because it does not relocate** — `virt_offset` is 0, flat
*is* reloc. The arch that could not show the bug is the one that looked healthy. Fourth
time in this lab.

Fixed by [patch 24](examples/openbios-the-rival-that-shipped/patches/24-forth-trampoline-runs-in-firmware-segments.patch):
the trampolines get the firmware's own relocated segments (and no client-entry arguments,
being C functions that take none), and `{forth,fcode}_init_program()` **stamp
`ls.file-type`** — only the C loader path wrote it, so a payload loaded with `load` reached
`arch_init_program()` claiming to be an *elf-boot image*. Same two-records-of-one-fact shape
as [§13.1d](#131d-x86s-go-hung-on-an-uninitialised-load-state--closed-2026-08-26), one
field over.

**Watched to bite.** `./smoke-openbios.sh client-forth`: x86 and amd64 each `load` a Forth
payload off a CD and `go` it, and must print the payload's own marker. Re-injecting the flat
segments fails it **by name on x86 while amd64 still passes** — the asymmetry is the point.
The obvious re-injection does not compile (`-Werror=unused-but-set-variable`), so the
control uses an unsatisfiable condition. The track also asserts x86's two windows still
**differ** before its pass is allowed to count — on an arch where they are the same memory
the bug is undetectable — and carries a same-probe tautology (a cell compared with itself
must report `-1`) so a `=` answering `0` for everything cannot satisfy it. Negative control:
a second boot with the same program minus `is_forth()`'s `\ ` magic, which must be refused
by name rather than evaluated (and that one was watched to fire too, by giving the control
payload the magic).

---

*Original entry, 2026-08-26:*

From [§13.1d](#131d-x86s-go-hung-on-an-uninitialised-load-state--closed-2026-08-26). Once
the 768 MB walk was fixed, `go` refuses honestly and prints why. Comparing **by xt and by
value**:

| word | xt @prompt | xt @context | value @prompt | value @context |
|---|---|---|---|---|
| `load-base` | `13756c` | **`12ebb8`** | `e066fdd0` | `4000000` |
| `load-size` | `12afc8` | `12afc8` | `1f` | **`0`** |

**Two mechanisms, one symptom**, and this is the part to start from:

- **`load-base` resolves to a different word.** `13756c` is the C shadow
  `arch/x86/openbios.c` defines late as `phys_to_virt(LOAD_BASE_PHYS)`; `12ebb8` is the
  earlier constant in `forth/admin/nvram.fs`. A **lookup** difference.
- **`load-size` resolves to the same word** — identical xt — and yields a different number.
  A **fetch** difference. Not a lookup problem at all.

No single-mechanism story explains both rows. amd64 is unaffected: it defines no shadow,
because it does not relocate. **The next session starts from this table**, which the
firmware now prints itself.

#### B. `number()` diverges from C99 in two measured ways — **CLOSED 2026-08-29 (patch 46)**

Both from `libc/vsprintf.c`, both asserted **as themselves** by `test-printf-edges` so that
closing either one goes red on purpose.

| case | C99 | here | why |
|---|---|---|---|
| `%.0d` of `0` | *(nothing)* | `"0"` | `if (num == 0) tmp[i++] = '0';` runs unconditionally |
| `%08.3d` of `42` | `"     042"` | `"00000042"` | the `0` flag is **not** ignored when a precision is given |

The second is **independently corroborated by GCC**, which refuses the literal:
`-Werror=format=` → *"'0' flag ignored with precision and '%d'"*. The compiler is right
about the rule; this printf does not follow it.

**Both are now fixed, and so is the `LLONG_MIN` negation below** — see §17.4 for
why the parked reasoning was re-derived and then overruled by §13.3(C), and for
the control that came back BLIND. What follows is the record as it stood while
they were carried.

~~**Not fixed**~~ — no in-tree caller combines a zero flag with a precision. The only integer
conversions carrying a precision anywhere are `arch/ppc/qemu/main.c:58-59`'s two `%8.8lx`,
which carry no `0` flag and are asserted correct. Both divergences mis-*format*; neither
over-*reads*, which is what separated them from
[§13.1c](#131c-s-precision-was-a-minimum--closed-2026-08-26)'s `%s` bug.

**And one suspicion deliberately NOT tested:** `number()` does `num = -num` on a
`long long` with no guard, so `LLONG_MIN` is undefined behaviour. It is left unexercised
**because testing it would mean shipping the UB in a fixture** — read from the source,
named here, not measured.

#### C. ppc32 was the only arch built without `-fno-builtin` — **CLOSED 2026-08-27**

*It was never `number()`, and it was never ppc's libc.* Every arch in this tree passes
`-fno-builtin` — amd64, x86, sparc32, sparc64, ppc64, and even ppc-`unix` — except one:

```sh
ppc)  CFLAGS="-m32 -mcpu=604 -msoft-float -fno-builtin-bcopy -fno-builtin-log2 ..."
```

Two named exclusions where every sibling disables the lot. With `snprintf` left as a **GCC
builtin**, a call with a constant format and a constant argument lets the compiler compute
the **return value** itself — per C99, where `%.0d` of `0` produces no characters — while
leaving the call in place for its side effect. `libc/vsprintf.c` then performed that side
effect and wrote `"0"`, because it diverges from C99 exactly there ([§13.3(B)](#b-number-diverges-from-c99-in-two-measured-ways--closed-2026-08-29-patch-46)).

**The buffer came from our implementation and the return came from GCC's.** Two different
printfs answering one call, and the arch that disagreed was the one that let a second printf
into the room.

Measured, changing that one line and nothing else:

| | |
|---|---|
| before | `d-zero … wrote=1 ret=0 DIVERGES-AS-RECORDED RET-DISAGREES` |
| after | `d-zero … wrote=1 ret=1 DIVERGES-AS-RECORDED` |

which is what x86 and amd64 have always printed.
[Patch 29](examples/openbios-the-rival-that-shipped/patches/29-ppc32-had-no-fno-builtin.patch).

**Watched to bite.** The `diagnostics` track pinned the d-zero line *per arch* and went red
on the fix — the good-news failure again. It now expects one line for all three and applies
its `RET-DISAGREES` guard to every arch instead of excusing ppc; taking `-fno-builtin` away
fails it by name. **And the fixture is deliberately left foldable**: passing the format
through a `volatile` pointer would stop a compiler answering for our libc, and would also
hide the day a build flag lets one in again — which is exactly what that guard is for.

#### D. `pci.c` wrote its property cells in HOST byte order — **CLOSED 2026-08-27**

*Both original bullets are kept below the rule. One of them was false, and the other was
true about the wrong node.*

**No child of the PCI host bridge could be reached by path** — not the VGA node
specifically. `ls` listed five children and gave every one of them the same unit address
(`@0`) while their `reg` phys.hi cells were all distinct. The first child's four bytes:

| | |
|---|---|
| bytes | `00 08 00 00` |
| read **little**-endian | `0x00000800` — bus 0, device 1, function 0: the correct 1275 phys.hi |
| read **big**-endian (what `decode-int` does, via `l@-be`) | `0x00080000` — device field `(hi>>11)&0x1F` = **0** |

So `ob_pci_encode_unit()` faithfully rendered `"0"` for all five, and
`ob_pci_decode_unit("0")` produced a phys.hi of 0 that matched none of their `reg` cells.
**`pnodename` and `pathres` never disagreed** — they agreed perfectly about a value that had
been byte-swapped underneath them.

The rest of the tree already knows: `set_int_property()` writes `__cpu_to_be32(val)`,
`get_int_property()` reads `__be32_to_cpu(*p)`, every Forth reader goes through `l@-be`. Only
`drivers/pci.c`'s builders handed `set_property()` raw host-order `u32` arrays. **On a
big-endian host that is the same thing** — and OpenBIOS's PCI support is exercised almost
entirely on ppc and sparc64. x86 and amd64 are the only little-endian targets, so this is a
defect that existed only where nobody was looking.

[Patch 28](examples/openbios-the-rival-that-shipped/patches/28-pci-property-cells-are-big-endian.patch)
wraps the cell stores in `__cpu_to_be32`, which is the **identity** under
`CONFIG_BIG_ENDIAN` — provably inert on ppc and sparc, changing only the arches that were
broken. Two sites are deliberately left alone and named: `pci_set_AAPL_address()`'s
`cell`-typed props (a `__cpu_to_be32` would truncate a 64-bit cell, and it is Apple/ppc-only),
and the literal props blocks under `CONFIG_SPARC64`/`CONFIG_PPC` (big-endian-only, already
correct, untestable here).

After, on both arches:

```console
14f470 pci8086,7000@1
14fb60 pci8086,7010@1,1
150028 pci8086,7113@1,3
150788 QEMU,VGA@2
151e58 e1000@3
" screen" find-dev   ->  150788
```

— QEMU's actual i440FX topology, function numbers and all. **Both bullets close on one fix**,
because the second was never a missing alias: `/aliases` had carried `screen` all along,
pointing at a path that could not resolve.

**Watched to bite.** The `vga` track asserted `QEMU,VGA@0` — the defect — so it went red on
the fix, which is the good-news failure a characterization test exists to produce. It now
asserts `@2` and names both candidate causes; its `screen` line was an UNKNOWN printed on
every run and is now an assertion. Re-injecting the host-order phys.hi fails it by name. One
control bug of my own, caught the same way: `find-dev` returns `( phandle true | false )`, so
the probe's bare `.` printed the **flag**, and `S=-1` read as "no phandle" — the probe now
says `FOUND`/`NONE` outright.

---

*Original entry, 2026-08-26:*

- **`QEMU,VGA@0` cannot be reached by path.** `ls` under the host bridge lists it, but
  `dev /pci8086,1237@0/QEMU,VGA@0` — and the relative form — both answer *no such device*,
  **on x86 as well**. `pnodename` and `pathres` disagree about that node's unit address.
- **No `screen` devalias** on either arch. The FCode installs the node and its properties;
  nothing points at it, so `" screen" find-dev` returns `0`. The `vga` track prints this as
  an UNKNOWN on every run.

#### E. Unverified by construction — **two of three rows CLOSED 2026-08-27**

Re-read, two of them were *verified-by-nobody* rather than unverifiable.
[Patch 30](examples/openbios-the-rival-that-shipped/patches/30-eword-and-printf-surface-fixtures.patch).

- **`_eword()`'s "word not in the dictionary" branch — CLOSED.** The entry said it is
  *"reachable only if `evaluate` itself is missing"*. True of the **callers** and false of
  the branch: `eword()` takes the word to run as an **argument**, so any name that does not
  exist reaches it. `test-eword-report` asks for one, and the `diagnostics` track requires
  **exactly one** `eword:` line naming it. Worth a fixture because the two failures are not
  the same failure — a `-1` throw means the word ran and aborted, this means **nothing ran**
  — and before the reporter existed both left `ret == -1` and printed the same nothing.
- **The untested printf surface — CLOSED.** `%n` and the `L` qualifier (which `ll` also maps
  to) are both *implemented* and neither had ever been run; an implemented-but-unrun
  conversion is an UNKNOWN, not a pass. Two cases join `test-printf-edges`, taking it from
  12/12 to **14/14**: `"ab%ncd"` → `abcd`, `rc 4`, `n 2`; and `%llx` of `0x123456789abcdef`
  → `123456789abcdef`, `rc 15`. **`%n` *is* the return value**, written through a pointer at
  the point it appears — so it asserts the same quantity the `trunc` cases assert about `rc`,
  at a different *moment*: mid-format rather than at the end. And the `llx` case needs 60
  bits, so on x86 it prints a number the Forth stack under it cannot hold.
- **sparc32/sparc64 carry amd64's `preopen` omission** (no `device-end`) — **still open, and
  re-derived rather than re-quoted**: measured 2026-08-27, `device-end` appears **0** times
  in each of `arch/sparc32/init.fs` and `arch/sparc64/init.fs`, against **1** in x86 and
  **3** in amd64. This lab still cannot boot sparc, so it stays UNVERIFIED rather than
  patched blind — [`check-patch-scope.sh`](tools/check-patch-scope.sh) prints
  `NOT COVERED: sparc` on every run so a green three-arch line cannot read as "all arches
  covered".

#### Resolved while writing this list

**x86's `load` prints no probe/mount trace where amd64 prints five lines.** Noticed during
§13.1d and briefly filed as unexplained; it is not a defect. `CONFIG_DEBUG_FS` is `true` on
amd64 and `false` on x86 — one of the six shared config options §13.1 already recorded as
differing. Named here so the next person who sees the asymmetry does not re-open it.

### 13.2 Four defects in `forth/device/property.fs` — **(b)(d) FIXED 2026-08-26, (c) FIXED 2026-08-27, (a) decided and instrumented**

Read at `openbios` `e5ac46d`. **The work was to watch them bite; three then turned out to be
fixable and were fixed.** What is left characterized is (a) alone, and that is a decision with
a measurement behind it rather than an omission — see its entry below.

*(This heading and this sentence were themselves stale for four hours on 2026-08-27: they
still said "(a)(c) characterized" after (c) had been fixed and merged. Recorded rather than
quietly corrected, because it is the same shape as the seven claims this section's own work
disproved — a present-tense summary outliving its subject.)*

`./smoke-openbios.sh property-abi` runs a multi-line Forth probe **loaded off media**
on both arches (only possible since patches 14/15/16; before them every line had to be
typed through the ~80-char truncation). Measured:

| | amd64 (64-bit cell) | x86 (32-bit cell) |
|---|---|---|
| **(a)** `-1 encode-int decode-int` | `ffffffff` — **not a round trip** | `-1` — round-trips |
| **(b)** a value ≥ 2³² | ~~silently truncated to 0~~ → **REFUSED BY NAME** (patch 26) | **UNREPRESENTABLE** — an UNKNOWN, not a pass |
| **(c)** `encode+` with an `allot` between fragments | ~~lies about the length~~ → **FIXED** (patch 27); the length was right, the **bytes** were not | same — it never was a 64-bit issue |

**(c) bites on BOTH arches**, so it is not a 64-bit issue at all — this entry called it
*"correct today"*, and it is correct only while nothing moves `here` between two
fragments. Forcing one `allot` breaks it immediately.

**And `encode-phys` is not fixed-width — asserted, because that is the misreading
this entry warned about.** It encodes `my-#acells` ints, and `my-#acells` reads the
**parent's** `#address-cells` (clamped 1–4, default 2 when there is no parent).
Measured on amd64:

| context | `my-#acells` | `encode-phys` length |
|---|---|---|
| `dev /` | 2 — the **default**, root has no parent | **8 bytes** |
| `dev /ide@1` | 1 — from root's own `#address-cells` | **4 bytes** |

Root is the trap: its own property says `1` while `encode-phys` *under* it uses `2`.

The track is a **characterization** test: if it fails saying *"appears FIXED"* that is
good news, and the expectations here and there get updated together.

**Two false passes were caught in the probe itself, both by the x86 control:**
- the first version printed `b-WIDE-OK` on x86, because the literal `100000000`
  truncates to 0 *on entry* on a 4-byte cell — so it compared `0 = 0` and reported a
  pass for a case the stack cannot express. It now checks the literal survived first.
- the (c) assertion used `grep -q '…ENCODE\+-WOULD…'`, and in a **basic** regex `\+` is
  a *quantifier*, not a literal plus — so it matched nothing and reported (c) FIXED
  while both logs plainly contained the string. Now `grep -F`.

**(b) `l!-be` — FIXED 2026-08-26.** A 1275 property-encoded integer is **four bytes**
(§5.3.5.1). On a 32-bit cell that is the whole cell; on a 64-bit cell it is half of one, and
`l!-be` wrote the low four bytes and dropped the rest with no error and no flag. The tree
encodes **pointers** through this path (`forth/admin/iocontrol.fs:42,76`;
`forth/device/display.fs:362`), so an ihandle above 4 GiB went into `/chosen`'s `stdin` as
its bottom 32 bits and read back as a different object — the **LIED** rung, which outranks
HALTED for exactly that reason. It now refuses *before* the write, which is the only place a
refusal is a gate rather than a post-mortem:

```console
encode-int: value does not fit in the 4 bytes 1275 encodes an integer into  Aborted.
```

**Both halves of the 32-bit range still encode**, and they are the must-not-catch pair in the
same run: `ffffffff` (an unsigned address or phandle) and `-1` (a sign-extended negative
filling a cell with ones). Nothing in the tree trips the gate — `amd64-pmem`, whose store
sits at `0x100000000`, passes unchanged.

**(a) `l@-be` — NOT fixed, and 2026-08-26 is when that became a decision rather than an
omission.** Sign-extending is the one-line fix and it is **not safe here**: it turns every
decoded value with bit 31 set into a negative cell, and `assigned-addresses` carries PCI
physical addresses — QEMU's 32-bit PCI window sits just under 4 GiB, and
`drivers/vga.fs:148` hands exactly such an entry to `pci-bar>pci-addr`. A framebuffer at
`fd000000` would become `fffffffffd000000` and be used as an address. The real fix is signed
decode **plus** an `ffffffff and` in every consumer wanting an unsigned 32-bit address, which
reaches `drivers/sbus.fs` and the sparc trees this lab cannot boot.

So (a) is tolerated on a **premise** — *"nothing here decodes a value with bit 31 set"* — and
a claim about a corpus is a cache. Two counters in `l@-be` derive it on every boot, read
**before** the probe decodes anything of its own:

| | amd64 | x86 |
|---|---|---|
| `a-decodes-boot` | `2b` | `2b` |
| `a-signbit-boot` | **`0`** | **`0`** |

with the probe's own deliberate `ffffffff` as the counter's must-catch control in the same
run (`a-signbit-end=1`). Without that second reading, a counter wired to nothing reports the
same reassuring `0` as a firmware that never saw one — not hypothetical: the first draft read
the counters at the **end**, caught the probe's own `ffffffff`, and that is how the scoping
error was found. **The day `a-signbit-boot` goes non-zero, (a) has its first real consumer
and the decision is forced.**

**(c) `encode+` — FIXED 2026-08-26/27, and the entry's own description of it was wrong.**
`nip +` keeps the first address and adds the two lengths: adjacency-by-assumption, right only
while nothing moves `here` between the two `alloc-tree` calls. This section called that
*"lies about the length"* — and re-injecting the defect disproved it on the first run.
`nip +` returns `l1+l2`, which is **exactly right**. What it returns is the wrong **array**:
`a1` followed by whatever sits at `a1+l1`. Measured on both arches, one `allot` forced
between `1 encode-int` and `2 encode-int`:

| | |
|---|---|
| `encode+` length | `8` — correct |
| first `decode-int` | `1` — correct |
| second `decode-int` | **`30302f63`** — the allot'd gap, read as an integer |

A plausible length over the wrong bytes is the **LIED** rung, and worse than (b): nothing
throws, the array decodes, and every field before the gap is right. The claim had never been
measured — the old probe tested **adjacency** and inferred the rest, which is the same shape
as the two claims below.

The fix keeps the classic fast path byte for byte and concatenates into a third array when
the fragments are not adjacent. **Both branches run in the probe**, and it says which it got
(`c-fast-ADJACENT` / `c-slow-NOT`) before asserting the result — a fix whose slow path is
never taken is indistinguishable from no fix. Re-injecting `nip +` fails it on the slow
path's **second decode**, not on its length, which is why the assertion had to be the decode.

#### Two claims this track made, both corrected by measurement 2026-08-27

Neither was a firmware defect. Both were shipped as present-tense comments and both were
re-derived rather than re-quoted, which is the only reason they were caught.

**1. *"a tick in evaluated text parses an empty name."*** `' encode-int catch` failed inside
the (b) probe with a nameless `: undefined word.`, and that was written up as a limitation of
`evaluate`. It is not:

| | amd64 | x86 |
|---|---|---|
| `'` at the top level of evaluated text | works | works |
| `'` inside an interpreted `if … else … then` | **fails** | **fails** |
| `[']` in the same place | works | works |

The mechanism is [`forth/bootstrap/bootstrap.fs:201`](examples/openbios-the-rival-that-shipped/patches/26-encode-int-refuses-what-four-bytes-cannot-hold.patch):
`if` calls `setup-tmp-comp`, which switches to **compile** state and builds the body as a
temporary definition that `then` executes afterwards. A non-immediate word like `'` is
therefore *compiled*, and runs when `>in` is already past the whole construct, so its
`parse-word` returns nothing. `[']` is immediate, parses at compile time, and works.
**Standard Forth: an interpreted `if` here IS a definition.** The probe uses `[']` and is back
to one file and one `evaluate`, which also deleted the stack-dirty hazard the (b) control
found.

*(`state @` inside the branch reads `0`, and that is the instrument answering the wrong
question — it is compiled too, so it runs after `then` has restored the state.)*

**2. *"`variable` does not stick inside the evaluated text."*** Measured:

```console
variable qw  7 qw !  qw @ .     →  7    (and still 7 at the prompt afterwards)
dev /  variable la  9 la !      →  la @ is 9 while the context is open
device-end  la @                →  la: undefined word.
```

So it was never about `evaluate`. The probe defined `la` after a `dev /`, and `$create`
defines into the **active package's** method list, which `device-end` drops from the search
order — correct IEEE 1275, and this lab's own documented rule, misfiled as a limitation of
evaluated text.

**(d) `decode-bytes` — FIXED 2026-08-26, and it was one transposed character.** Two
predictions in this entry were wrong, in opposite directions, and both are kept below.

The word's own stack annotations were right all along, and they are IEEE 1275-1994
§5.3.5.2 exactly: `( prop-addr1 prop-len1 #bytes -- prop-addr2 prop-len2 data-addr
data-len )`. The `( R: len2 )` note beside the offending line is only *true* if that line
is a `>r` — which is what it should have been. With `>r`, len2 is parked, `addr2 = addr1 +
#bytes` is computed, len2 comes back, and `2swap` puts the remainder under the decoded
array. So the fix **is** balancing the `r>`s, contrary to the paragraph two below.

**Fixed rather than deleted**, and the choice is not close: one character produces the
standard's word, while deleting it would leave `encode-bytes` — five callers plus an
FCode-table entry — with no inverse. And its absence from `forth/device/table.fs` is **not
a gap to fill**: `decode-bytes` has no FCode number in 1275, and that table is positional.

[Patch 25](examples/openbios-the-rival-that-shipped/patches/25-decode-bytes-robbed-the-return-stack.patch).
`property-abi` now ends on a (d) section — after (a)–(c), so a robbed stack cannot
invalidate them — asserting `d-depth-pre=0`, `d-depth=4`, `d-data=ab`, `d-len2=0`,
`d-depth-post=0` on both arches. **The depth is the assertion**: a round trip that prints
`ab` proves the bytes were found and says nothing about the two cells taken from underneath
the caller. Re-injecting the bare `r>` fails it by name (`left 6 items on the stack, not
4`) — and that control found **two defects in the harness**, which is where they keep
turning up: the generic "probe did not complete" gate fired first and blamed patches
14/15/16 for a defect the probe had already printed, and its message carried an
**unescaped `` `load` `` in backticks** that bash *ran*, splicing the empty result into the
text so the failure read *"if  no longer reaches"* — CLAUDE.md's usage-heredoc rule,
pointed at a `fail` string, visible only on a run that was already failing.

*Original entry, 2026-08-25 — the crash prediction, and the measurement that disproved it:*

**Run in isolation 2026-08-25, and it does NOT crash.** That
prediction ("calling it corrupts the return stack and would take the machine down") was
this entry's, and it is wrong. Measured on amd64:

```console
D-DEPTH-BEFORE=0
D-ENCODED-DEPTH=2      \ after `" ab" encode-bytes`
D-CALLING-NOW          \ `1 decode-bytes`, so 3 items in
D-RETURNED             \ it came back
D-DEPTH-AFTER=6        \ documented effect is 4 out — TWO EXTRA
```

The two extra cells are exactly the two bare `r>`: it pulls them off the **return**
stack and leaves them on the data stack. It survived because `evaluate`'s return stack
was deep enough to be robbed without the closing `;` landing anywhere fatal.

**That is worse than a crash, not better.** A word that corrupts the return stack and
then returns *cleanly* hands its caller a silently wrong stack and an intact-looking
machine. It stayed out of the `property-abi` probe for the right reason — it perturbs
state mid-run and would invalidate (a)–(c) — but not for the stated one.

Its damage today is still zero, re-derived: called by **nothing** anywhere in the tree,
and `forth/device/table.fs` carries `encode-bytes` with **no `decode-bytes`**, so the
round trip does not exist. **Fix or delete it** before anything claims otherwise — and
the fix is not merely balancing the `r>`s, since the stack comment describes an effect
(`addr len2 addr1 #bytes`) that no caller has ever depended on.

*(That last sentence is the second wrong prediction. The stack comment describes the 1275
effect, and balancing the `r>`s produces it.)*

| # | defect | why it matters on amd64 |
|---|---|---|
| a | `l@-be` (`:24`) accumulates 4 bytes into a **cell**, zero-extending | `-1 encode-int decode-int` is `-1` on x86 and `4294967295` on amd64 — **same bytes, different value**. `forth/admin/devices.fs:434` compares a decoded int against a phandle |
| b | `l!-be` (`:16`) masks to 4 bytes with **no overflow check**, and the tree encodes pointers as ints (`forth/admin/iocontrol.fs:42,76`; `forth/device/display.fs:362`) | an ihandle above 4 GiB is silently truncated into `/chosen`'s `stdin`. Masked today only because the firmware runs at 1 MiB — and the port's headline gain is memory above 4 GiB |
| c | `encode+` is `nip +` (`:233`), i.e. **adjacency-by-`alloc-tree`**, not concatenation | correct today; silently produces a lying length if anything touches `HERE` between two fragments |
| d | `decode-bytes` (`:195`) has two bare `r>` with no matching `>r`, and is **called by nothing** and absent from the FCode table | the `encode-bytes` round trip does not exist; fix or delete before anything claims it does |

**Write the assertions on the 64-bit build, not as a cross-build byte diff.** A diff of
encoded bytes cannot state any of the above: `encode-int` is `/l`-sized by construction
(`/l` is `sizeof(u32)`, `kernel/bootstrap.c:849`), so the bytes match on both builds
even when everything above them is wrong — and the input that triggers (b) is
unrepresentable on a 4-byte-cell stack. Also assert `encode-phys` (`:237`) changes
length with the parent's `#address-cells`, so nobody re-reads it as fixed-width.

## 14. A real test suite for `examples/openbios-the-rival-that-shipped/`

*Added 2026-08-25, immediately after Spike 3 (#291) and the `--help` fix (#292).*

The lab has **15 smoke tracks, a three-flavor showcase, and exactly one thing CI
runs** — [`tests/test-usage-is-data.sh`](examples/openbios-the-rival-that-shipped/tests/test-usage-is-data.sh),
added by #292, which checks help text and nothing else. Every assertion that the
*firmware works* runs only when a human types it. That is the gap: a lab whose
whole subject is *"a green suite cannot see this"* has almost no suite.

### Measured first, so the plan is not a guess

Each of these was checked on 2026-08-25 rather than assumed, and two of them
changed the shape of this item:

- **Every track skips without a built firmware.** Checked arm by arm: all 12
  `case` arms (15 names — some arms carry several) guard on a built artifact
  first, whether that is `no image at $MB — run ./build-openbios.sh x86 first`
  or coreboot's `no ROM at $ROM`. So a suite wired naively
  into CI would report **15 SKIPs and a green tick** — which is the exact shape
  this repo keeps re-finding: *an all-PASS result is indistinguishable from one
  that checks nothing.* Tiering is therefore not a nicety, it is the whole
  design problem.
- **[`tools/check-doc-verbs.sh`](tools/check-doc-verbs.sh) is blind here, by its
  own design.** Pointed at the lab's README + MANUAL_TESTING it reports
  *"0 distinct commands across 2 documents"*, because this lab writes its
  examples as `$ `-prefixed console transcripts and that tool deliberately
  passes over transcripts. **Do not wire it in and call it coverage** — it would
  be a green tick over nothing. A lab-specific A5 below does the real job.
- The `case` arms, the usage string and MANUAL_TESTING **agreed** when this was
  written, and still agreed when A2/A5 were finally built on 2026-08-27 — 31
  dispatch names across four scripts, 19 of them `smoke-openbios.sh`'s. So the
  guards are **preventive, not corrective**: neither found live drift. Said
  plainly because "we added a checker" reads as "we found something", and here
  that would be false. What the checker's own §0 controls *did* find is in
  [`tools/check-track-list.sh`](tools/check-track-list.sh): the first backward
  scan stopped at a **nested** `case` inside an arm and read 2 arms out of 19 —
  and the fixture written to catch exactly that shape **passed anyway**, because
  it put the nested `case` on the arm's own line where there is no bare `case`
  line to stop at. A fixture that does not reproduce the real shape proves
  nothing. Fifth time in two days.
- All eleven `TESTED_TREE_MARKERS` in
  [`build-openbios.sh`](examples/openbios-the-rival-that-shipped/build-openbios.sh)
  name files that `patches/TESTED-TREE.patch` touches. Also coherent today —
  and also a **cached description of a patch**, which is bug class #1. (They
  described `patches/01` alone until 2026-08-27; see §14 Tier B below for why
  that was the wrong subject to describe.)
- ~~**The clone is unpinned**~~ — **PINNED 2026-08-27.** `build-openbios.sh` now
  checks out `openbios` at `e5ac46d` and `fcode-utils` at `6e563ee`, detached,
  fetching the exact object when the clone lacks it. A **tag would not do**: a
  version string is not an identity and a tag can be moved, so these are SHAs.
  A clone already at the pin is left completely alone, so the uncommitted
  divergence this lab develops in is never touched; a clone that is *not* at the
  pin and *is* dirty makes the build refuse by name rather than move HEAD under
  that work. [`tools/openbios-pin-check.sh`](tools/openbios-pin-check.sh) reads
  the SHAs **out of** `build-openbios.sh` — a second copy would be a cache of the
  first, stale in exactly the case it exists to detect — and reports when
  upstream has moved past them. It never bumps anything: moving the pin means
  re-reading every patch in `patches/` and re-running every track on three
  arches, and that is a decision someone makes rather than a surprise mid-build.

  **A pin nobody looks at ages silently, so a routine looks at it weekly** —
  Mondays 09:00 America/New_York (`0 13 * * 1` UTC), routine
  `trig_01BxvYWNk9j4H2sitWXYfkp4`. It runs `openbios-pin-check.sh` in a cloud
  session against this repository and reports; when a pin has moved it also
  counts the commits and lists their subjects from a blobless clone. It is
  granted **Bash, Read and Grep only** — no `Write`, no `Edit` — so "it never
  bumps anything" is enforced by the harness rather than promised by the prompt.
  Its instructions say in as many words that a `77` is an UNKNOWN and not a pass.
- **podman may be absent on the runner** — `ci.yml` already carries a
  `::warning::` for exactly that in the phase6 job. Tier B cannot be assumed.

### Tier A — headless: no clone, no container engine, no QEMU

The tier that must run on every PR, and the one that must not be empty.

| | guard | its control |
|---|---|---|
| **A1** | usage text is data — **done**, #292 | ✅ both run: a removed `--help`, and an unquoted delimiter with `` `date` `` in the prose |
| **A2** | ✅ **done 2026-08-27** — every `case` arm appears in the usage string and vice versa, **and in the `usage()` heredoc**, across all four dispatching scripts | ✅ both run against the REAL corpus: renaming one name in the usage line fails with *both* halves named (`'client-forth' is a case arm but is NOT in its own usage list` / `'client-forthh' is offered by the usage list but has NO case arm`) |
| **A3** | ✅ **done 2026-08-27** — every `REVIVAL_MARKERS` entry names a file `patches/01` touches **and** a string it actually adds. The match is a **substring** match, deliberately, because that is what the build's own `grep -qF` does: the checker asks the question the build asks | ✅ both halves, against the REAL corpus: a marker file the patch does not touch → *the marker array has drifted from the patch it describes*; a marker string it does not add → *the build will read a correctly patched tree as unpatched* |
| **A4** | ✅ **done 2026-08-27** — each `patches/NN-*.patch` parses under **`git apply --numstat`** (git's own diff reader, never a private parser), its `Subject: [PATCH NN/..]` matches its filename, and the series is `01..30` with no gaps or duplicates. Patches **01–10 predate the Subject convention** (it began at 11) and are exempt **by name, with a reason, and printed on every run** — the same argument `check-patch-scope.sh` makes about its own five | ✅ renumbering `28`'s subject to `27/28` → *the filename and the subject disagree about which patch this is*. And both directions of the exemption are fixtures: an exempt number with no subject passes, a non-exempt one fails |
| **A5** | ✅ **done 2026-08-27** — every `<script> <name>` typed in the lab's ten documents names a real arm of that script. **This is the job `check-doc-verbs.sh` cannot do here** | ✅ appending `` `./smoke-openbios.sh vgaa` `` to MANUAL_TESTING fails with *the docs type 'smoke-openbios.sh vgaa', which is not one of its arms* |

### Tier B — needs the pinned clone + podman + QEMU (TCG, no KVM)

**Landed 2026-08-27 as `workflow_dispatch` ONLY**
([`.github/workflows/openbios-tier-b.yml`](.github/workflows/openbios-tier-b.yml)), because
the decision it informs is a **cost** decision and nobody had the number. Wiring it to
`pull_request` before measuring a cold run would be guessing with someone else's minutes.
The "~10 min" below was an estimate, never a measurement.

**The gate matters more than the minutes.** Every track guards on a built artifact and SKIPs
without one, so a Tier B job that cannot build produces a full sweep of SKIPs and a green
tick — the shape this section already measured. So the job **fails** if the five artifacts
are absent, and a `77` *after* a successful build is reported as a warning rather than
counted green.

**What it cannot do, stated rather than discovered later:** `ubuntu-latest` has no KVM, so
every boot is TCG and the timings are an **upper bound**.

**It earned its place before it ever produced a timing.** On the first run that got as far as
building, `build-openbios.sh` reported **rc=0 in zero seconds having built nothing**, and the
gate caught it. Cause: `REVIVAL_MARKERS` carried `s" load-base"`, a string that is in the
**pristine** `forth/admin/nvram.fs` three times already (the ppc, sparc32 and sparc64 arms).
A marker means *present ⇒ applied*, so a cold clone matched 1 of 8 and the build refused
every target with *"the revival patch is HALF applied"*. **Every working copy in this lab has
been patched since the day it was made**, so no cold checkout had ever happened — the bug was
invisible to every green run for the lab's whole life.

`check-patch-hygiene.sh`'s A3 passed it, and was right to: patch 01 *does* add that line. **A3
was asking a true thing that was not the question.** A3b now asks the question — fetch the
file at the pinned commit and require the marker to be **absent** — and SKIPs rather than
passes when the network is unavailable, because an unchecked marker is an UNKNOWN and this
whole checker exists because an unchecked marker was read as a checked one.

### OpenBIOS in long mode as a coreboot payload — patches 36-38

**Done 2026-08-28.** `arch/amd64` could not be a coreboot payload at all: coreboot
cannot hand a payload a separate dictionary module the way QEMU's
`-kernel`/`-initrd` can, so a coreboot image must be the **embedded** one
(`IMAGE_ELF_EMBEDDED`, dictionary compiled in), and amd64 built no such image.
Three defects, each of which hid the next — which is why this looked like one
question and was three:

| # | patch | the defect | how it presented |
|---|---|---|---|
| 36 | [`build.xml`](examples/openbios-the-rival-that-shipped/patches/36-amd64-embedded-image-set.patch) | `arch/amd64/build.xml` declared **one** executable; x86 declares four | `switch-arch builtin-amd64` set `CONFIG_IMAGE_ELF_EMBEDDED` and built **nothing**, rc=0 — a silent no-op |
| 37 | [`builtin.c`](examples/openbios-the-rival-that-shipped/patches/37-amd64-builtin-never-declared-its-array.patch) | the file says *"wrap an array around the hex'ed dictionary file"* and never wraps it | `error: 'forth_dictionary' undeclared` — it could not compile, and had not since **2003** |
| 38 | [`openbios.c`](examples/openbios-the-rival-that-shipped/patches/38-amd64-embedded-dictionary-branch.patch) | only the **multiboot** dictionary path existed | reached long mode, printed `forth started`, then `panic: no dictionary entry point` |

**Patch 38 is the interesting one.** x86 branches on `sys_info.dict_last`: a builtin
image is already relocated and ready to run, so it is used **in place** with `last`
taken from the image; a multiboot module is a dictionary **file** and gets parsed
into `intdict`. amd64 had only the second arm, so it parsed a ready-to-run
dictionary as though it were a file and never set `last` — `findword()` then found
nothing. The tell was in x86's own comment on that arm: *"as arch/amd64 does."*
**The code already recorded that this was the only path there.**

And the failure arrives **after** long mode and after Forth starts, which is what
made it read as a dictionary bug rather than a missing branch.

**Result, driven through the shipped path:** `./build-coreboot-openbios.sh amd64`
→ `./smoke-openbios.sh coreboot-amd64` → the `0 > ` prompt, `3 4 + .` → `7`, and
**`-1 u.` → `ffffffffffffffff`**. The 64-bit assertion is the point of the track: a
prompt alone would be satisfied by the x86 ROM in the tree next door, so the track
also fails by name if `panic: no dictionary entry point` ever returns.

`build-coreboot-openbios.sh` now takes `[x86|amd64]`, with a separate `DOTCONFIG`,
`obj=` dir, guard file and provenance stamp per arch — and each arch's guard list
now includes **the other arch's ROM**, since that is the same clobbering question
one arch wider.

**A note on reproducibility, measured rather than assumed (§17.5):** the cold tree
builds these images, but its binaries are **not** byte-identical to the dev tree's —
and neither is a rebuild of the *same* tree, so the non-determinism is pre-existing
(something dated is baked into the dictionary) and not introduced here. It is also
the vindication of
[`openbios-archive-tree.sh`](tools/openbios-archive-tree.sh) digesting **source**
and excluding `obj-*`: a digest over the binaries would identify nothing.

~~**Still open:** … `RAM 0 MB` …~~ — **FIXED, patch 39 below. And the diagnosis
written here first was wrong**: it named the `unsigned long`-in-an-ABI-struct trap
and the wrong file. The mechanism is `uint64_t` **alignment**, in
`libopenbios/linuxbios.h`. A guess recorded in the same sentence as a measurement
reads like a measurement, which is why it is struck through rather than edited
away.

### The coreboot memory table is a wire format — patch 39

**Done 2026-08-28.** `libopenbios/linuxbios.h` described coreboot's table with a
plain `uint64_t`. That is not portable **in a wire format**, and the reason is
alignment rather than width:

| | `_Alignof(uint64_t)` | `sizeof(struct lb_memory_range)` |
|---|---|---|
| i386 | 4 | **20** |
| x86-64 | 8 | **24** — four bytes of tail padding |

coreboot emits **20**-byte entries. So the amd64 firmware computed `size / 24` for
the entry count and strode `map[i]` by **24** over 20-byte records: the first entry
read correctly and every one after it was garbage.

```
before:  0x09f00000000000 0x00000100000000 655360     after:  0x00000000001000 0x0000000009f000 1
         0x00000000056000 0x0f600000000002 0                  0x000000000a0000 0x00000000056000 2
         RAM 0 MB                                             RAM 510 MB
```

**coreboot had already solved this on its own side, and says why** — which is what
settled the choice of fix rather than a preference:

```c
/* lb_uint64_t will keep 64bit coreboot table values aligned to 32bit
 * to ensure compatibility. */
typedef __aligned(LB_ENTRY_ALIGN) uint64_t lb_uint64_t;    /* LB_ENTRY_ALIGN 4 */
```

The patch mirrors that typedef rather than reaching for `__attribute__((packed))`.
Packing gives the same 20 bytes here **only by coincidence of this struct's shape**;
the `aligned(4)` typedef *is* the ABI and stays right for any other record that
later gains a 64-bit field. Measured: natural 24 / packed 20 / this 20 on x86-64,
and 20 / 20 / 20 on i386 — so **arch/x86 is unaffected either way**, which is why
this was invisible until amd64 could be a coreboot payload at all.

**The track asserts the VALUE, not that something printed.** `coreboot-amd64` now
extracts `RAM <n> MB` and fails when it is under 256 of the 512 given to QEMU. A
guard checking merely that the word `RAM` appeared would have passed throughout the
bug. Control: the typedef was removed, the firmware and ROM rebuilt, and the track
failed with *"found only 0 MB of the 512 MB QEMU was given"*.

~~**NOT fixed…** `/memory` still carries no `reg`…~~ — **FIXED, patch 40 below.**
The comparison against arch/x86 is what scoped it correctly: it was never a
coreboot-path gap, it was that *nobody published the map at all.*

### amd64 saw 3 GB of a 5 GB machine — patch 41

**Done 2026-08-28**, and it was **half of an earlier fix**. Spike 1 changed
`struct multiboot_info`'s own fields from `unsigned long` to `uint32_t` and left a
comment saying these are wire-format structures with every field fixed at 32 bits
— but the two structs inside the **union immediately before
`mmap_length`/`mmap_addr`** kept `unsigned long`.

| | union size | `offsetof(mmap_length)` |
|---|---|---|
| x86-64, `unsigned long` | 32 | **64** — spec says 44 |
| x86-64, `uint32_t` | 16 | 44 ✓ |
| i386, either | 16 | 44 ✓ |

So arch/x86 never saw it — the same shape as patch 39, and the same reason it hid.

**The symptom was a plausible number.** The firmware read garbage for
`mmap_length`/`mmap_addr`, computed an entry count of **zero**, printed *"Multiboot
mmap is broken"*, and fell back to `mem_lower`/`mem_upper` — which cannot express
anything above 4 GiB. With `-m 5G` it answered **3071 MB**. Nothing crashed and
nothing printed an absurd value.

```
before:  Multiboot mmap is broken / RAM 3071 MB   (2 ranges, both below 4 GiB)
after:   9 mmap entries parsed    / RAM 5119 MB   (3 ranges, incl. 0x100000000)
```

**A partial fix reads as a complete one when the comment beside it describes the
whole problem.** That is the durable lesson here: the comment was accurate about
the bug class and the code below it only carried half the remedy.

The `amd64` track now boots a **second** time with `-m 5G` and asserts the total,
because the `-m 512` boot above it cannot distinguish these cases at all — 3071 and
5119 both look like answers at 512 MB. Control: the `unsigned long` was restored
and the track failed naming the struct.

**Now live, and NOT a bug in this file:** with all three ranges collected,
`/memory` publishes two and says *"1 of 3 range(s) NOT published … the root
declares `#address-cells 1`"*. Seeing the memory and being able to **encode** it are
different questions. Whether the root should declare `#address-cells 2` is a
device-tree design decision with a wide blast radius — every node's address
encoding, and this session already had to give PCI its own `#address-cells 3 /
#size-cells 2`. **Was carried as §17.1, and is now DECIDED and DONE** (2026-08-29,
patches 42-43): two address cells on the amd64 root, x86 left at one because one
cell is accurate there. All three ranges publish. See §17.1 for the blast-radius
map and what the change cost.

### Nothing published the memory map — patch 40

**Done 2026-08-28.** `/memory` had a `name` and nothing else, on **both** x86
arches and on **every** path. On ppc and sparc the `reg` is a by-product of ofmem,
which those arches lean on (20 references in `arch/ppc`, 6 in `arch/sparc32`);
`arch/x86` states in its own `openbios.c` that it has none, and `arch/amd64`
mentions ofmem nowhere. So nobody ever wrote the map into the tree.

**The scoping came from a comparison, not from the first thing that looked wrong.**
It surfaced on the amd64 coreboot path, which made "the coreboot path is missing
it" the obvious diagnosis — so x86 multiboot was checked before anything was
written, and it had no `reg` either. Those are different bugs and only the second
was real.

`publish_memory_ranges()` sits in `libopenbios/init.c` so both arches call **one**
implementation, from `arch_init()` **after** `openbios_init()` — the tree does not
exist at the top of `arch_init`, where `find_dev()` faults rather than returning 0,
which the file already records from an earlier session.

Two decisions worth keeping:

- **The cell counts are read from the root, not assumed.** A `reg` means nothing
  without the `#address-cells`/`#size-cells` that decode it, and this root declares
  **`#address-cells 1`** and **no `#size-cells`** — so a hardcoded 2/2 would have
  produced a property every consumer misreads. Absent counts fall back to the 1275
  defaults.
- **A range that does not fit is dropped and said out loud, never truncated.** One
  address cell is 32 bits, and this lab routinely puts an NVDIMM at
  `0x100000000`; silently writing the low half is a property that looks valid and
  points somewhere else.

| path | published |
|---|---|
| x86 / amd64 multiboot (QEMU e820) | `00000000 0009fc00` + `00100000 1fee0000` — **511 MB** |
| amd64 coreboot (the coreboot table) | `00001000 0009f000` + `00100000 1fd71000` — **510 MB** |

`assert_memory_reg` in the driver sums the **size column** rather than stopping at
"a reg exists", because an empty or zero-filled property is exactly what a broken
encoder emits and it would satisfy a presence check. Control: the call was removed
from `arch/x86`, the firmware rebuilt, and the track failed with *"/memory carries
no 'reg' property"*.

**Publishing a `reg` RENAMES the node, and the suite caught it the expensive way.**
A 1275 node carrying a `reg` has a unit address, so `dev / ls` went from `memory`
to **`memory@0`** — and `dict-identity`, which anchors on `^<phandle> <name>$` so
that a word in prose cannot pass for a node, failed while **nothing was broken**.
That is the second direction of the mechanism-not-outcome trap: an assertion that
fails when the mechanism is replaced by a *better* one. The pattern now allows an
optional `@unit`, still anchored. `dev /memory` resolves either way, which is why
every probe during development kept working and only the strict test noticed.

(The `147a70 memory` line in
[`X86-64-FEASIBILITY.md`](examples/openbios-the-rival-that-shipped/X86-64-FEASIBILITY.md)
is left alone on purpose: it is a **dated transcript** of what the firmware printed
then, and editing it to match today's output would turn a true record into a false
one.)

**And a defect of my own, found by this work:** the cross-arch entry added to
`build-coreboot-openbios.sh`'s sha-guard a day earlier was wrong. That guard file
is written **once and cached**, and it listed this lab's *own* other-arch ROM —
which the lab rebuilds on demand. So rebuilding x86 left amd64's guard describing a
ROM that had legitimately changed, and the next amd64 build failed its own guard.
**A cached expectation about a thing that is supposed to change — bug class #1,
committed while fixing bug class #1.** The guard now covers only the *sibling
labs'* artifacts, which this lab never writes, and self-heals a guard file written
by the broken version rather than requiring someone to delete it by hand. The two
arches never needed the guard for isolation: separate `DOTCONFIG` and `obj=` dirs
are what keep them apart.

### Archiving the tested tree — a snapshot that can prove what it is

**Done 2026-08-27.** [`tools/openbios-archive-tree.sh`](tools/openbios-archive-tree.sh)
takes a dated, compressed snapshot of the patched OpenBIOS tree — 5.7 MB of source
to an **884 KB** `.tar.zst` — and `build-openbios.sh` will take one after a
successful build when `OPENBIOS_ARCHIVE=1`.

**The archive is not the source of truth, and the design says so.** The tree is
reproducible: pin + `TESTED-TREE.patch` regenerates it exactly. This is insurance
against upstream vanishing or a rewritten history, not a second definition of the
firmware. Which is precisely why it must carry an identity — a directory of
tarballs named only by date is bug class #1 waiting to happen, because the day two
of them disagree nothing says which was the tree that was tested.

So every archive is stamped with the **pin**, the **sha256 of the patch** that
produced it, the **mklab commit**, and a **tree digest** over file contents
(sorted under `LC_ALL=C`, since a digest that depends on the asker's locale is not
an identity). **The date is a record; the digest is the identity.** Both are in
the filename, so `ls` answers *when* and *is this the same tree* without opening
anything.

Three properties fall out, and the third is the one that ties this back to §14:

- **Dedup is by content.** Re-running on an unchanged tree writes nothing, which
  is what makes it safe to leave switched on in the build.
- **`obj-*` and `config-host.mak` are excluded**, so the digest identifies *the
  source*, not *what was last built*.
- **Which makes the archive comparable to a cold reproduction** — and they agree.
  The live tree, the archive, and a tree rebuilt from the pin and the patch on a
  fresh clone all carry `fee928e882ef096e88553a635213c64d98116d93eb9717da16f11f945f93dc6f`.
  The snapshot, the running firmware, and the reproducible path are the same bytes,
  measured rather than asserted.

[`tools/tests/test-openbios-archive-identity.sh`](tools/tests/test-openbios-archive-identity.sh)
(in `ci.yml`, synthetic tree, no clone or network needed) carries 16 assertions,
and the load-bearing ones are the two where verification must **FAIL**: a tampered
archive and one with no manifest. Both were re-injected into the tool and watched
to bite.

**Two defects in the test, both in the control, both found the same way.** The
first draft read `$?` inside its assertion helper — whose own first statement is
`n=$((n+1))`, an arithmetic assignment that **sets `$?`** — so every status row was
reading the increment. It reported both controls as failures while the tool was
fine, and would equally have reported a broken verify as a pass. The second: the
dedup row counted files, but dedup produces the same date and the same digest and
therefore the **same filename**, so a re-archive overwrites in place and the count
is identical either way. The row now asserts the bytes were not rewritten.

And a third, in the *injection* rather than the test: the control that was meant to
prove the dedup gap used the wrong indentation, so it never applied and reported
"does not bite". *When the control reports something surprising, suspect the
control.* Re-run correctly it bites on the new row while the file-count row still
passes — which is the evidence the strengthening needed.

### Tier B's second finding: the lab was not reproducible, and had never been

The marker fix got the build running. It then went green on all three arches — `build:x86`
**37s**, `build:amd64` **9s**, `build:ppc` **12s**, 58 seconds for the lot from nothing on a
cold `ubuntu-latest` with no KVM — and the artifact gate **still failed**, on
`obj-amd64/openbios.multiboot`.

The gate was right again. `build-openbios.sh` applied **one of thirty-four patches**. Patch
02 is what adds `<executable name="openbios.multiboot" …>` to `arch/amd64/build.xml`, so a
clean checkout built the x86 revival and **no amd64 port at all**, while
`smoke-openbios.sh` asserted amd64 behaviour in **21 tracks**. The firmware every one of
those tracks had ever booted existed only in a hand-maintained working copy.

**"Apply them in order" was the obvious fix and it does not work.** Measured before writing
anything: applying `01..34` to a pristine pin lands **19 of 34**, and `git apply -3` lands
the *same* 19 — a merge strategy cannot recover context that was never written. The cause is
structural and predates this session: **every patch was extracted as a diff against a tree
that already had the others applied**, so its context lines describe the finished tree rather
than the tree as it stood at that step. Reverse-walking from the finished tree does better
(**23 of 34**) and then stops on the early ones. The intermediate trees that would make the
series linear do not exist anywhere any more.

So the record and the applied artifact were split, deliberately and with a checker between
them:

- **`patches/TESTED-TREE.patch`** is applied — the cumulative divergence from the pin,
  generated by [`tools/openbios-regen-tested-tree.sh`](tools/openbios-regen-tested-tree.sh)
  rather than written. Verified by *reproducing the tree*: **722 of 722 source files
  identical by sha256**, the only difference being `config-host.mak`, which `switch-arch`
  generates. That is a stronger claim than "34 patches applied without error."
- **`patches/NN-*.patch`** stay the record, one annotated change each, and are not applied.
- **A6** in [`check-patch-hygiene.sh`](tools/check-patch-hygiene.sh) binds them: the two must
  name the **same files**, in both directions. Built-but-unrecorded ships a change with no
  account of why; recorded-but-unbuilt is a document describing firmware nobody runs.

**A6 found one on the day it was written.** `arch/amd64/boot.h` was in the built divergence
and in **no** numbered patch, while `arch/amd64/boot.c` had been `#include`-ing it since
Spike 1 — the port had been compiling against a file the record did not mention. Now
[patch 35](examples/openbios-the-rival-that-shipped/patches/35-record-amd64-boot-h.patch).

Two smaller things fell out of the same sitting, both the same shape as the bug being fixed:

- The `Arch-tested:` line on a **generated** patch is a claim about a tree that just changed,
  so the regenerator takes it as a **required argument**. Stamping it automatically would
  have made it a cached fact; omitting it fails `check-patch-scope.sh` loudly until someone
  runs the tracks.
- **A3b treated a 404 as a skip.** Now that the markers span the amd64 port — several of
  whose files the patch *creates* — `curl -f` turned every one of those into a SKIP. A 404
  at the pin is an **answer** ("absent, trivially"), not an unknown, and a SKIP that is
  really a pass teaches the reader to ignore the SKIP that is really an unknown.

**Proof, cold, from a pristine pin:** all four targets build (`x86` 9s, `amd64` 6s, `ppc` 7s,
`unix` 6s), and ten tracks pass on the result — `multiboot`, `amd64`, `dict-identity`,
`property-abi`, `vga`, `diagnostics`, `client-forth`, `pmem-writer`, `flash-writer`,
`mmio-writer`. The last seven depend on patches 20–34, which a cold tree had never had.

**What this says about Tier B.** Its value was never the timings. Three green CI runs, 34
patches and a pin all said nothing about the cold path, because **every working copy here had
been patched by hand since the day it was made** — the one thing nobody had ever done was
start from scratch. That is the same lesson as the marker bug one level up, and it is why the
per-PR question below should be answered "yes".

The remaining decision, once the number exists: `pull_request` on every PR, nightly, or
**path-filtered per-PR** (only when the PR touches this lab or `tools/drive-*`) — which the
original text did not consider and which buys per-PR signal at roughly nightly cost. Tonight
argues for per-PR signal: three tracks went **red on a fix**, which is exactly what you want
from the person who caused it, and eight firmware patches in one night would make a nightly
failure a bisect.

Original estimate below, kept because being wrong about it in a specific way is the useful
part.

- **B1** build `x86`, then `smoke-openbios.sh multiboot` under `accel=tcg` — the
  firmware reaches its own prompt and answers.
- **B2** `dict-identity` — the guard that the x86 tracks load
  `openbios-x86.dict` (the superset) and not the arch-less base. Worth more than
  its size: that confusion made a broken NVRAM round-trip look like a working
  one for months.
- **B3** patch round-trip for `08`–`12`: each applies to its reconstructed base
  and reproduces the built tree **byte-exactly**. Done by hand for `12` on
  2026-08-25; a version string is not an identity, so compare bytes.

### Tier C — local only, and it must be legible as UNKNOWN

Needs host artifacts CI will never have: the linuxboot lab's cached
`payload-bzImage` + `uroot.cpio` (showcase, `amd64-linux`, `floppy`), a cached
coreboot tree (`coreboot`), a SeaBIOS image and CFI flash (`persist*`), and KVM
for anything that would otherwise take minutes under TCG.

**These must be named in the summary, not counted.** An unmet precondition is an
UNKNOWN, and the runner has to say *which* guard did not run — the 2026-08-15
incident (two mount guards silently skipping behind a healthy-looking
`13 passed, 13 skipped`) is the reason that rule exists.

### The structural piece — **DONE 2026-08-27**

`tests/lib.sh` and `tests/run-all.sh` exist. **The net is copied verbatim from
[`phase7-firecracker/tests/lib.sh`](phase7-firecracker/tests/lib.sh)** — the exemplar
CLAUDE.md names — rather than rewritten, because a second implementation of a safety net is
a second thing to get wrong; `tests/test-harness-net.sh` then holds the copy to the same
seven sections instead of trusting it for being a copy. All five tests are **headless by
construction**: they read files and run `--help`, so the suite cannot become the *"15 SKIPs
and a green tick"* this section measured. `ci.yml` now carries **one** entry instead of five.

That closes **§15.1** and **§15.3** for this lab (four and three rows left respectively).

*One thing worth knowing before writing another runner:* the ratio checker harvests fixture
names by grepping the runner's source for `test-*.sh` — **comments included**. Naming
another suite's test file in prose makes it build a fixture by that name, which the runner's
own disk-vs-list check then rejects; the checker says it could not drive the runner rather
than quietly weakening its assertion. Refer to it by directory.

### What building this opts the lab into

Worth knowing **before** starting, because both are hard gates that drive the
real files rather than grepping them:

- creating `tests/lib.sh` enrolls the lab in `ci.yml`'s
  `git ls-files '*/tests/lib.sh'` loop → [`tools/check-harness-net.sh`](tools/check-harness-net.sh)
  §1–§7: `lib.sh` owns the single EXIT trap, tests register teardown with
  `on_exit`, cleanup can read `$_EXIT_RC`, `TERM`/`INT`/`HUP` are named and
  re-exited `128+N`, and **no test may install its own `trap … EXIT`**.
- creating `tests/run-all.sh` enrolls it in
  [`tools/tests/test-run-all-reports-a-ratio.sh`](tools/tests/test-run-all-reports-a-ratio.sh),
  which drives the runner with synthetic pass/fail/skip fixtures and asserts
  what it **prints**: a `ran/listed` ratio, the skipped file named, the failed
  file named, and exit 1 when a test fails.
- ship the five-line `tests/test-harness-net.sh`, and add the runner to
  `ci.yml`'s example-lab loop next to the entry #292 already added.

### Decisions to make first

1. **Pin the clone** — recommended, and A3/B3 are only meaningful once it is.
2. **Tier B in CI, or local + nightly?** ~~~10 min per PR~~ — **MEASURED
   2026-08-27**, run `33115835118`, cold `ubuntu-latest`, podman present, **no
   KVM** so every boot is TCG: **3m11s wall**, 3m06s in the job.

   | phase | | |
   |---|---|---|
   | `build:x86` **37s** | `build:amd64` **8s** | `build:ppc` **11s** |
   | `track:multiboot` **5s** | `track:dict-identity` **6s** | `track:amd64` **6s** |
   | `track:property-abi` **10s** | `track:diagnostics` **15s** | `track:ppc` **21s** |
   | `track:vga` **29s** | | |

   56s to build all three firmwares from nothing (the container image, which
   compiles `toke` from source, is inside the x86 number); 92s to boot seven
   tracks under TCG. The guess was 3× high, and the x86 build dominates only
   because it pays for the image.

   **LANDED 2026-08-27: path-filtered per-PR, weekly backstop, always-reporting gate.** Three minutes is not a nightly-only
   cost, and the argument for per-PR is no longer about minutes — this lab's
   firmware is built from a patch that nothing else exercises, and Tier B has now
   found **two** defects invisible to every green run: a marker matching a
   pristine file, and a build applying 1 of 34 patches. Both were only visible
   from a cold checkout, and a nightly would have found them a day later against
   a merged main rather than in the PR that caused them. Filter on
   `examples/openbios-the-rival-that-shipped/**` and `tools/openbios-*` so the
   other ~120 labs do not pay for it.

   The shape, and why it is not `on.pull_request.paths`: a workflow-level path
   filter stops the run happening **at all** on a non-matching PR, so a
   **required** status check never reports and the PR blocks forever on
   something that will never arrive. Instead the workflow always triggers, a
   ~15s `changes` job asks
   [`tools/openbios-tier-b-relevant.sh`](tools/openbios-tier-b-relevant.sh),
   `tier-b` is skipped when the answer is `false`, and
   [`tools/openbios-tier-b-gate.sh`](tools/openbios-tier-b-gate.sh) reports on
   behalf of all of it — that is the one that WOULD be marked required.

   **DECIDED 2026-08-27: `main` stays unprotected, deliberately.** Required
   status checks were proposed (`Tier B gate` and the four `ci.yml` jobs,
   `strict: false`, `enforce_admins: false`) and declined, because this repo
   sometimes needs to **land red work and come back to it** — a lab left
   mid-investigation is a normal state here, and a gate that argues about it
   costs more than it catches on a single-maintainer repo.

   Two things this does NOT change, worth stating so the decision is not
   re-litigated from a false premise:

   - **Every check still runs and still reports on every PR.** Protection governs
     only whether a red one can be *merged*; it has no effect on what is measured.
     Nothing in §14 or §15 depends on it.
   - **It would not have been a wall anyway.** With `enforce_admins: false` the
     maintainer keeps an admin override, so red work could still be merged — the
     rule would have added a confirmation step, not a barrier. Which is precisely
     why it was not worth the friction.

   If it is ever revisited, the contexts must be copied **verbatim** from the
   check-runs API on a real head commit, not typed from the workflow file: a
   required context whose name does not match is a check that never reports, and
   that blocks every PR with nothing on the page explaining why.

   Both halves fail **silently**, so both are driven by
   [`tools/tests/test-openbios-tier-b-relevance.sh`](tools/tests/test-openbios-tier-b-relevance.sh)
   (in `ci.yml`): the filter on **9 must-match and 7 must-not-match** real
   paths; the gate on its whole truth table — **2 rows pass, 8 refuse**,
   including a relevance job that never finished, and the silent one, *a
   relevant change that did not run Tier B*, which is the gating logic having
   broken and otherwise looks identical to a PR that needed nothing. The gate is
   **default-deny** for that reason: a gate whose default is "pass" opens when
   its own machinery breaks, which is exactly when it should be shut.

   §1 of that test **re-derives** the filter's `tools/` half from the workflow's
   own entry points, so a lab that starts using a new repo tool fails there
   rather than falling quietly outside the filter — the list is a cached fact,
   so something has to re-derive it. Its first draft derived from the whole lab
   and reported four checkers as uncovered; those are run by the lab's `tests/`,
   which Tier B does not invoke and `ci.yml` already gates. It was answering a
   true thing that was not the question.

   **And the empty-`TRACKS` hole, found while wiring this up:** `inputs` exists
   only on `workflow_dispatch`, so on a `pull_request` or the weekly run
   `TRACKS` arrived **empty** — and an empty `for` list runs zero tracks, prints
   no failure, and exits 0. The oldest shape in this file, inside the very job
   built to catch it. Fixed with a fallback to a single `DEFAULT_TRACKS` (the
   input's own `default:` was removed, so the list is defined once) **and** a
   refusal to finish having run zero tracks.

   **Both were reasoned about and neither had been watched**, which is the same
   gap one level up: the fallback has since fired in production (Tier B ran
   seven tracks on a `pull_request`), but the refusal had **never executed at
   all**. So
   [`tools/tests/test-tier-b-refuses-an-empty-track-list.sh`](tools/tests/test-tier-b-refuses-an-empty-track-list.sh)
   (in `ci.yml`) `sed`s the **shipped** `Boot the tracks` body out of the
   workflow and runs it — **18 assertions**, only `smoke-openbios.sh` stubbed,
   since the question is about the loop and not about whether firmware boots. It
   carries a control (the pre-fix shape must exit 0 silently), and all three
   defects were **re-injected into the real workflow** and watched to bite.

   **The measurement corrected the claim that wrote it.** "Either alone is a
   half measure" implied two copies of one guard; breaking each showed they are
   **orthogonal**. Remove the fallback and the count check fires — the job is
   *safe but useless*, every PR failing loudly. Remove the count check and the
   job works normally and goes *silently green* the day something empties the
   list. One provides **function**, the other **safety**, and only the second is
   the bug class this repo keeps re-finding.

   One weaker result worth naming rather than leaving implicit: deleting the
   fallback line was first caught by the test's **extraction sanity check** (*the
   extracted body does not reference `DEFAULT_TRACKS`*) rather than by a
   behavioural row. That is a guard doing its job, but it is a string check
   standing where a behaviour check should be, so the injection was sharpened —
   neuter the fallback while keeping the identifier present — and **4 of 18
   behavioural assertions** then failed by name. The instrument was confirmed to
   out-reach the defect only after being made to.

   **Blast radius, measured rather than assumed:** `${{ inputs.… }}` is consumed
   in exactly **one** place in the whole repo (this step), and exactly one
   `workflow_dispatch` input is declared anywhere. Nothing else needed the same
   fix.
3. ~~**Keep `smoke-openbios.sh` as the single driver**…~~ — **DONE 2026-08-27:
   wrapped.** The driver stays the single implementation and `tests/` carries one
   `test-smoke-<track>.sh` per track, each a five-line `exec` — so the verdict,
   the SKIP and the exit code are all the driver's, and there is still one place
   to type a track by hand.

   **The objection in the old runner header was right, and had to be answered
   rather than overruled.** It read *"all five are headless by construction"* and
   kept the tracks out because every one guards on a built artifact and SKIPs
   without it — so a suite that merely included them printed a green tick on a
   machine that cannot build. §14 had measured exactly that. Including them is
   only safe once an all-SKIP sweep stops reading as a pass, so `run-all.sh` now
   reports the two groups **separately** (`of which boot tracks: n/22`), prints
   an explicit **UNKNOWN** when none executed and **PARTIAL** when some did not,
   and `OPENBIOS_REQUIRE_TRACKS=1` turns any skip into a failure.

   **Strict mode fails on ANY skip, not only on all of them, and that distinction
   was earned by measurement.** Driven against an empty `OPENBIOS_WORKDIR`, the
   sweep came back **21 skipped, 1 passed** — because the `coreboot` track reads
   its ROM from the *linuxboot* lab (`COREBOOT_DIR`, default
   `~/linuxboot-lab/coreboot`) and is therefore independent of the tree under
   test. A guard that only fires when *every* track skips is silenced by exactly
   that: one unrelated pass hiding twenty-one unknowns.

   **Which surfaced a finding worth its own line — now CLOSED, and it was the bad
   case.** `test-smoke-coreboot.sh` could **PASS while the firmware under test was
   never built**. Measured 2026-08-27: the track boots
   `$COREBOOT_DIR/build-openbios/coreboot.rom` — the *linuxboot* lab's tree —
   while the `multiboot` arm beside it boots straight out of `$OPENBIOS_WORKDIR`,
   and **nothing related the ROM to the payload inside it**. Two consequences,
   both observed rather than reasoned:

   - Against an empty workdir it passed, reporting *"OpenBIOS (coreboot) answered
     7 at the 0 > prompt"* for a tree that had never been built.
   - The ROM on this machine was dated **Aug 25 00:48**, the payload ELF **Aug 27
     14:02**. Every run for two days reported on firmware predating an entire
     session of fixes, while presenting the result as a test of them.

   Nothing errored: the ROM is readable and it does answer 7. It was a record
   outliving its subject — the reason a green suite could not see it. The 00-INDEX
   claim that it *"sha-guards both sibling labs' ROMs"* is **accurate and about a
   different question**: that guard stops the siblings' ROMs being clobbered, and
   was the only sha check in the builder.

   **The fix is the exemplar CLAUDE.md names for exactly this.** Deriving was the
   first choice and is not available — coreboot *transforms* an ELF on the way in
   (1,162,128 bytes became a 75,851-byte `simple elf` CBFS file) and this tree's
   `cbfstool` cannot `extract` a payload at all. So
   [`tools/openbios-rom-provenance.sh`](tools/openbios-rom-provenance.sh) records
   the **pairing** at build time and re-derives **both** digests at check time:
   only the pairing is stored, because only the pairing cannot be recovered
   afterwards.

   The two failure modes are graded by the ladder, not lumped together:

   | outcome | grade | why |
   |---|---|---|
   | ROM built from a different payload | **77 UNKNOWN** | nothing is broken; a rebuild restores the answer |
   | sidecar describes a different ROM | **1 FAIL** | the record and reality disagree — the LIED rung |
   | no sidecar / no payload / no ROM | **77 UNKNOWN** | stated, never passed |

   Proved end to end on the real track, in **both** directions — a truthfully
   stamped ROM passes and prints the payload digest it carries; an empty workdir
   is refused by name. That second run matters as much as the first: *a track that
   can never pass is as broken as one that can never fail.* The ROM was rebuilt in
   the process, so `coreboot` now tests this session's firmware for the first time.
   13 assertions in
   [`tools/tests/test-openbios-rom-provenance.sh`](tools/tests/test-openbios-rom-provenance.sh)
   (in `ci.yml`, synthetic, no coreboot needed), including two controls proving the
   comparison can distinguish at all — every row compares a digest to a digest, so
   the file would pass entirely if the comparison always succeeded.

   [`tests/test-every-track-has-a-wrapper.sh`](examples/openbios-the-rival-that-shipped/tests/test-every-track-has-a-wrapper.sh)
   holds the set together in **both** directions — a track with no wrapper is a
   track nobody runs, a wrapper naming a dead track is drift — and also asserts
   each wrapper actually `exec`s the driver rather than reimplementing it, and
   that every one is listed in `run-all.sh` so the ratio is measured against the
   full 22. It borrows `arms_of()` out of `check-track-list.sh` rather than
   growing a second parser for the same dispatch.

   **It caught a naming collision on its first run:** the wrappers were originally
   `test-track-<name>.sh`, which the existing headless `test-track-list.sh`
   matches — so "list" was read as a track. Hence the `test-smoke-` prefix.

**The acceptance test for this item is not "the suite is green".** It is: break
one thing in each tier and watch the named guard bite, and confirm the summary
names every Tier-C row it did not run.

---

## 15. Corpus survey (2026-08-26) — synergies not wired, families with a hole

Full write-up: [`SURVEY-examples-synergy.md`](SURVEY-examples-synergy.md). A desk survey of
`examples/` against the two catalogues, the seven drivers and `ci.yml`. The routing is
complete and the backlog is drained, so this looks only for what nobody has written down.
The boxes below are the actionable half; §C2, §D and §E of the survey are design calls, not
work items, and are deliberately not checkboxes here.

- [x] **15.1 — the EXIT-trap CI loop is keyed on the defect.** ✅ **DONE 2026-08-30.** The
      loop now enumerates `tests/` **directories** containing a `*.sh`, so a suite with no
      shared net is a *failing row* instead of no row. Three of the four invisible
      directories were enrolled the same day (a verbatim `lib.sh`, a runner, a
      `test-harness-net.sh`) and all three pass all seven sections; the fourth,
      `tools/tests`, is a **named** exemption in [`.harness-net-exempt`](.harness-net-exempt)
      with its reason. The step prints `checked 17 of 18` and names what it did not check.
      **The exemption file is refused two ways**, because a blanket excuse is how the
      original four stayed invisible: an entry naming a directory that no longer exists,
      and — the subtler rot — one naming a directory that has since *gained* a `lib.sh`
      and could therefore be enrolled.
      [`tools/tests/test-harness-net-loop.sh`](tools/tests/test-harness-net-loop.sh) drives
      the step **sed'd out of `ci.yml`**, not a copy, against fixtures for all five ways it
      can go quietly wrong, and re-derives the shipped exemptions against the real tree.
      *Original text:* `ci.yml`'s loop enumerates
      `git ls-files '*/tests/lib.sh'`, but `check-harness-net.sh`'s **first** check is
      *whether a `lib.sh` exists at all*. So a `tests/` directory with no shared net is not a
      failure — it is not a row. **Measured:** the checker aimed by hand at all 21 `tests/`
      dirs returned **13 × rc 0** (every enrolled suite) and **5 × rc 1** — `almalinux-packer-images/`,
      `kali-packer-vagrant/`, ~~`openbios-the-rival-that-shipped/`~~, `package-mirror-ram/`, and
      **`tools/tests` itself**, the directory holding the meta-checkers. **openbios's row
      closed 2026-08-27**: it now has a `lib.sh` (the net copied verbatim from
      `phase7-firecracker`, not rewritten) and passes all seven sections, so the enumeration
      picks it up. **Four rows left.** Enumerate `tests/`
      **directories** containing `*.sh` instead; the five rows go red, which is the point.
      This is `CLAUDE.md`'s *"a scan that matches nothing and a scan that is broken print the
      same green ✓"* moved up one level — a broken **population** rather than a broken pattern.
      **RE-DERIVED 2026-08-29** (the measurement above was dated 2026-08-26, and a
      fact three sessions old is a cache entry): aiming the checker at every `tests/`
      directory containing a `*.sh` gives **18 directories, 14 rc 0, 4 rc 1** — the
      same four this box names. The record was accurate. What it did not say is that
      **all four fail on the FIRST check**, *"no lib.sh — there is no shared net to
      check"*, so the scanner never reaches their tests: the state of those suites is
      an **UNKNOWN**, not a known-bad.
- [x] **15.2 — three private copies of the net, one already drifted weaker.** ✅ **DONE
      2026-08-30**, and the reading was right: `package-mirror-ram/tests/test-state-mount-guard.sh`
      installed its own `trap` with **no `_VERDICT` flag** and whitelisted `rc == 1`, so a
      `die` (which *is* `exit 1`) ended the run with **no `FAIL:` line** — the exact silent
      exit the net exists to prevent. The two `test-offline-archive.sh` files carried
      near-identical hand-rolled copies. All three now source a `lib.sh` **copied verbatim**
      from an exemplar rather than written afresh (a fourth hand-written net is a fourth
      thing to drift), register teardown with `on_exit`, and install no EXIT trap of their
      own — which `check-harness-net.sh` §1 now verifies, because 15.1 made it able to see
      them at all.
- [x] **15.3 — ~~four~~ ~~THREE~~ ZERO `tests/` dirs have no `run-all.sh`** ✅ **DONE
      2026-08-30** (openbios's landed 2026-08-27; the last three the same day as 15.1/15.2).
      `test-run-all-reports-a-ratio.sh` now drives **14** runners, up from 11, and each
      prints `ran/discovered` plus the names of anything skipped. Two of the three were
      named in `ci.yml` as individual **test files** and the third — `package-mirror-ram` —
      was named nowhere, so **CI had never run its state-mount guard at all**: the
      *"a test file in no list"* shape, exactly as this box described it.
      **`tools/tests` is deliberately not enrolled** (see 15.1's exemption), and a new gap
      opened up while looking: **7 of the 18 files in `tools/tests/` are named in no CI step**
      — `test-actions.sh`, `test-control-pane.sh`, `test-doc-verbs.sh`, `test-echo-gate.sh`,
      `test-list.sh`, `test-serial-source.sh`, `test-tree-diagrams.sh`. That is the same
      shape one level up, and it is **15.8**.
- [x] **15.4 — `netboot/` mints a snakeoil CA next door to `lab-ca/`.** ✅ **DONE
      2026-08-30, and verified by a boot rather than by `openssl verify`.**
      `netboot/sign-payload.sh --lab-ca <name>` signs with a leaf issued by the shared root;
      the DER trust root baked into iPXE **is** that anchor, compared by digest against the
      tracked `lab-ca.fingerprint` rather than by path. Measured on KVM
      ([`netboot/MANUAL_TESTING.md` §13.3](netboot/MANUAL_TESTING.md)):
      `iPXE: slot current VERIFIED -- booting`, then the kernel; and the control — one byte
      flipped in `current/initrd.gz`, `.sig` left stale — `imgverify FAILED for slot
      current` → `rolling back current -> previous` → `slot previous VERIFIED`.

      **Three things were found by doing it, and none of them was the wiring:**

      | | |
      |---|---|
      | **the blocker was inside `sign-payload.sh`** | it required `ca.key` on *every* run, so the documented *"point `--keydir` at real (offline/HSM) material"* seam could not be used as documented — the ROOT PRIVATE KEY had to sit beside the signer, which is the one thing an offline root exists to avoid. Signing needs `ca.crt` + the leaf's key; the root key is now required only by `--gen-keys` |
      | **the two consumers want CONTRADICTORY leaves** | stboot's `descriptor.Verify()` leaves `KeyUsages` unset, so Go requires `serverAuth` and rejects a `codeSigning` leaf; iPXE *requires* `codeSigning`. So `issue-signing-cert.sh` (Ed25519, **no EKU**) could not be reused, and `issue-codesign-cert.sh` (ECDSA P-256, `codeSigning` + `digitalSignature`) is a **second leaf profile under one root** — the correct PKI shape, and a thing somebody will try to unify. Both directions are now asserted |
      | **it works only because the pin is v2.0.0** | the shared root is ECDSA, and `crypto/ecdsa.c` + `p256.c` + `p384.c` arrive in iPXE's first release since 2020. On v1.21.1 this root would be unparseable — so the pin bump `versions.env` already carried is load-bearing for a reason nobody had written down |

      `examples/lab-ca/` also gained its **first tests** — the anchor matches its tracked
      fingerprint, no private key is tracked, and the two profiles stay incompatible — plus
      a CI row. `netboot/tests/test-sign-payload-lab-ca.sh` drives a **throwaway** root via
      `LAB_CA_DIR`/`LAB_CA_KEYDIR`, because a guard that can only run on the one machine
      holding the real key is an UNKNOWN everywhere else.

      **The control found a defect in the test rather than in the subject, as usual.** The
      key-hygiene assertion's message contained `` `git add -A` `` inside a **double-quoted**
      string — command substitution — so firing it would have **staged the whole repo**.
      It is `CLAUDE.md`'s opening rule aimed at an error message: text that merely *names* a
      command must not sit where a shell will run it.
- [x] **15.5 — a package mirror nobody installs from.**
      ✅ **DONE 2026-08-30** — [`examples/air-gapped-install/`](examples/air-gapped-install/README.md):
      `airgap.sh mirror` builds a **signed** partial Debian mirror (the 79-package `minbase`
      closure, *derived from* `debootstrap --print-debs` rather than written down, every
      `.deb` traced to a `gpgv`-verified upstream `InRelease`) in exactly the layout
      [`package-mirror-ram`](examples/package-mirror-ram/README.md)'s nginx `root
      /srv/mirror;` serves — then installs from it inside `unshare -rn`, a namespace whose
      only interface is loopback. That lab now has its first consumer, and its README says
      which half is which: the NFS/iSCSI **transport** stays author-run, the tree being
      **installable rather than merely servable** is verified.

      **The controls are the deliverable, and one of them was a liar for a whole draft.**
      "The config names a local mirror" is not the same claim as "this install had no other
      source." The first draft proved isolation the tempting way — point `debootstrap` at
      `deb.debian.org` and watch it fail. Run *outside* the namespace as a control, that row
      still printed **`failed as required`**, because a non-root `debootstrap` refuses before
      it ever opens a socket (`E: debootstrap can only run as root`). It was reporting the
      wrong refusal in exactly the scenario it existed to catch. C0 now asks `curl`, whose
      network-class exit codes (6/7/28/35) *are* the answer, and the run **stops** rather
      than grading anything against an unknown; C1/C2/C3 each assert their **own** reason —
      the network, the signature, the hash — not merely that they failed.
      [`tests/test-the-air-gap-is-real.sh`](examples/air-gapped-install/tests/test-the-air-gap-is-real.sh)
      removes the namespace and requires the same rows to refuse a verdict.

      **`gpgv`'s exit status is the wrong question — the one place in this repo where
      parsing output beats reading `rc`.** A Debian `InRelease` carries several signatures;
      `gpgv` exits non-zero unless it can check *every* one. This host's
      `debian-archive-keyring` stops at bookworm, so trixie's `InRelease` yields one
      `GOODSIG` and two `NO_PUBKEY` and `gpgv` exits **2** on a perfectly trustworthy file.
      `debootstrap` says so in its own source (`read_gpg_status`,
      `/usr/share/debootstrap/functions`): *"Don't worry about the exit status from gpgv."*
      `--status-fd` is gpg's machine-readable interface, and the rule used is debootstrap's,
      so the builder accepts exactly what the installer will.

      **Two more defects, both in the instrument rather than the subject.** A *successful*
      install reported `rc=1`: the server-reaping `trap` named a `local` variable, which is
      out of scope by the time an EXIT trap runs, so under `set -u` the trap died on
      `srv: unbound variable` — leaving the server running **and** overwriting a clean exit
      with the teardown's. And `"$DRIVER" status | grep -q …` **skipped the most important
      test in the lab** while the mirror sat on disk: `grep -q` exits at the first match,
      SIGPIPEs the still-printing `status`, and `pipefail` reports 141. A skip is the quiet
      direction of that bug.

      **Also adds `lab-chroot.sh --keyring PATH`** (+ a `keyring =` TOML field), because a
      local mirror is signed by a **local** key and no driver here could say so — the
      keyring was chosen from the distro name alone, so `--mirror http://my-mirror/` could
      only ever be a re-host of the same archive signed by the same people.
      [`phase1-chroot/tests/test-keyring-override.sh`](phase1-chroot/tests/test-keyring-override.sh)
      asserts the **argv debootstrap actually receives** (from both the flag and the TOML
      field — two separate jq expressions, and the config one is the one that gets missed),
      that an unreadable path is refused by name, and that `--no-check-gpg` is neither
      passed nor accepted. That last check was first written as `grep -q -- --no-check-gpg
      lab-chroot.sh` and failed **on the driver's own comment saying the flag is
      deliberately not offered** — a regex over a line is not a question about a command,
      for the fourth time in this repo.

      Still author-run: the rooted second stage (`dpkg --configure`, which does **no**
      network I/O — named in the README rather than glossed), and the full **d-i** install
      via [`preseed-local-mirror.cfg`](examples/air-gapped-install/preseed-local-mirror.cfg),
      whose diff against the gallery base *is* the lesson — `apt-setup/services-select`
      emptied is what stops the installed machine being pointed back at
      `security.debian.org` hours later.

      **AND THE FIRST CI RUN CAUGHT THE LAST ONE, which is the repo's own rule arriving on
      schedule: measured HERE is not measured THERE.** All seven checks went green, and the
      suite had proved **nothing** — `SKIP: missing required command: debootstrap` (the
      runner has no debootstrap), and then the air-gap meta-control skipped in cascade
      because there was no mirror for it to take the namespace away from.
      `2 passed, 2 skipped, 0 failed`, and the two that skipped are the only two that make
      a claim. The `skipped —` names were in the log, inside a collapsed `::group::` that
      nobody opens on a passing job.

      Two fixes, because installing the package would only have closed *this* instance:
      CI now `apt-get`s `debootstrap` (~300 KB) and reports **both** preconditions by name
      (the binary, and the `/etc/subuid` range `unshare --map-auto` needs) rather than
      assuming the install settled it; and `run_suite` in `ci.yml` gained a third
      **`strict`** argument for a suite whose preconditions the job installs *itself* —
      there, a skip is a CI defect, not an UNKNOWN, and it goes **red with an `::error::`
      naming the file**. Proved against the shipped function by
      [`tools/tests/test-ci-tolerates-a-skipped-suite.sh`](tools/tests/test-ci-tolerates-a-skipped-suite.sh),
      which `sed`s `run_suite` out of `ci.yml` rather than copying it: the sneaky fixture
      **exits 0 while naming a skipped test** (the exact shape that went green), a third
      control deletes the strict branch and requires the gate to stop firing, and the
      **non-regression** asserts every *non*-strict suite still tolerates the identical
      input — twelve suites here legitimately skip on that runner, and a leak would turn
      them all red at once.

      **The strict gate earned itself on its very next run, catching the same class one
      layer down.** With `debootstrap` installed, CI went green-having-checked-nothing
      *again* — `missing /usr/share/keyrings/debian-archive-keyring.gpg`. On Ubuntu,
      `debootstrap` depends on `ubuntu-keyring`, **not** the Debian one, so the runner had
      the tool and could not verify the upstream index. The gate turned that red instead of
      leaving it in an annotation. The defect, though, was mine and structural: the CI step
      **hand-wrote two precondition checks and reported both satisfied — there were three.**
      A precondition list kept beside the caller is a re-implementation of a requirement the
      *driver* owns, and it drifts the moment the driver grows a fourth. So `airgap.sh`
      gained a **`preflight`** verb that names every unmet precondition at once (including
      two nobody had listed: a `debootstrap` that does not know the suite, and a subuid
      range that exists while `unshare -rn --map-auto` is still refused), and **both** CI
      and the suite's own gate now call it instead of keeping copies. `require_cmd` stopped
      at the first missing command, so a short machine learned about one per run.
- [x] **15.6 — `push` exists only in phase 3, and there is no registry to push to.**
      ✅ **DONE 2026-08-30** — [`examples/local-registry/`](examples/local-registry/README.md):
      a rootless `registry:2` under phase 4, its TLS leaf issued by the **shared** root
      ([`lab-ca/`](examples/lab-ca/README.md)'s third consumer, after the HTTPS tier and
      15.4's netboot signer). `registry-lab.sh demo` pushes an image, pulls it back, and
      compares **manifest digests** — a tag is a mutable pointer, so *"the tag came back"*
      is equally true of a registry that handed back something else.

      **The control is the deliverable, not the push.** *"`podman push` succeeded"* proves
      nothing about TLS: the ordinary way to run a lab registry is `--tls-verify=false`, and
      from outside that is indistinguishable from a working chain until the day it matters.
      So `demo` pushes **twice**, control first — with no CA it must fail, and it does:
      `x509: certificate signed by unknown authority`. The test asserts that line rather
      than the exit status, because a demo that silently stopped running the control would
      still exit 0.

      Deliberately **loopback-only, unauthenticated, delete disabled** — and the loopback
      bind is asserted by a test, because it is the only thing that makes "no auth"
      defensible and it would otherwise be one edit from gone. The client's trust goes in
      via `--cert-dir`, never `~/.config/containers/certs.d`: installing the CA globally
      would make every later run pass for a reason that has nothing to do with this lab.

      **15.7's lesson was applied, got it half right, and CI supplied the other half within
      the hour.** `volumes` needs absolute host paths — the cached-machine-fact that let a
      sibling spec carry `/home/user/…` unnoticed. The first draft hard-coded this
      checkout's path and added a checker to derive the correct value and refuse a
      mismatch. That is a real improvement, and it was still wrong:

      ```
      FAIL: REGRESSION: local-registry.toml does not contain the volume line this checkout needs:
            want: /home/runner/work/mklab/mklab/examples/local-registry/state/certs:/certs:ro,Z
      ```

      **A value that is false everywhere except one machine is not rescued by checking it.**
      The check fired correctly on a design that could never have passed anywhere but here.
      So the tracked spec carries `@LAB_DIR@`, `registry-lab.sh render` substitutes wherever
      the lab actually is, and podman reads a gitignored copy. `tests/test-spec-paths.sh`
      asserts the tracked file stays **portable** and that rendering produces what the
      driver asks for — verified the way the failure was found, by running it from a copy at
      a completely different path.

- [x] **15.10 — ~~five~~ FORTY-TWO specs hard-coded one machine's filesystem.** ✅ **DONE
      2026-08-30.** The entry's own count was a hand-derived guess again: derived, it is
      **42 specs / 60 paths**, and they are not one problem but three —

      | class | what it names | verdict |
      |---|---|---|
      | 19 specs | `/media/sqs/COLD_STORAGE/LAB_CREATE_V2/…` — **this checkout** | false on every other machine |
      | 29 specs | `/home/sqs/netboot…` — **this user's** netboot workdir | false for every other user |
      | 5 specs | `/var/lib/lab-create/…` | **correct** — the same everywhere, and left alone |

      `lab-vm.sh` now expands three placeholders when it parses a spec — **`@LAB_DIR@`**
      (the config file's own directory), **`@REPO@`** (the repo root, derived from the
      driver's location) and **`@NETBOOT@`** (`$LAB_NETBOOT_DIR`, else `~/netboot`, so the
      spec stops carrying a second copy of where that lives). All 60 phase-2 paths are
      converted; a real one was driven end to end (`create` → `start`, running, →
      `destroy`) rather than only parsed.

      **The fix is expansion, NOT a checker, and that distinction is the whole entry.** The
      sibling lab built the same day tried the other way — hard-code the path, derive the
      right one, refuse a mismatch — and CI failed it within the hour on
      `/home/runner/work/mklab/mklab`. *A value that is false everywhere except one machine
      is not rescued by checking it.* [`tools/check-spec-paths.sh`](tools/check-spec-paths.sh)
      exists to keep the placeholders in place, not to validate a hard-coded path.

      **Its own control rewrote the checker.** The first pattern *enumerated* the
      machine-specific prefixes — `/home/…`, `/root`, `/Users/…`, and a guess at a checkout
      under `/media` — and the fixtures caught it missing `/media/sqs/COLD_STORAGE/LAB_CREATE_V2/`
      because that directory has a **digit** in it and the pattern said `[A-Z_]+`. Not a
      typo to patch: enumerating machine-specific prefixes means **encoding this machine
      into the checker that exists to stop specs encoding this machine.** It is inverted
      now — match any absolute path, subtract a closed allowlist of system roots — so a new
      kind of home, a checkout under `/srv`, or an NFS mount is caught without teaching it
      anything, and a wrong allowlist fails loud instead of silent. 13 fixtures, 6
      must-catch and 7 must-not, before it looks at a real file.

      **15.7 is corrected rather than left standing.** Its test asserted the path equalled
      *this* checkout's — so it would have failed anywhere else, and passed only because
      that suite is not in CI. It now asserts the tracked file stays **portable**, which is
      true on every machine including ones it has never run on.

      And 14 specs carried the instruction *"Update /home/sqs to your `$HOME` if different
      (no shell expansion in TOML)"*. That sentence was true when written and is now false;
      it is replaced by the placeholder note, because a doc that tells you to do the thing
      the driver now does for you is worse than one that says nothing.

- [x] **15.11 — `volumes` named a machine in 20 files (24 paths).** ✅ **DONE 2026-08-30**,
      and the open question in it — share one implementation, or duplicate a fourth time —
      is answered by the repo's own stated architecture rather than by taste:

      > `phase4-podman/lab-podman.sh:23` — *"Self-contained per the per-phase rule: helpers
      > are duplicated inline."* And `CLAUDE.md` opens with *"each a self-contained driver"*.

      **No phase driver sources any shell file** — measured, not assumed — so a shared
      library would have made the first driver in this repo unable to be copied out on its
      own. That is a bigger change than the one being made, and it belongs to whoever
      decides to make it deliberately.

      **So: duplicate, and BIND.** `_expand_spec_paths` is byte-identical in all four
      drivers that read path-bearing specs, and
      [`tools/check-driver-helper-parity.sh`](tools/check-driver-helper-parity.sh) fails if
      the copies ever drift. The argument is this repo's own history: three near-identical
      `toml_to_json` bodies already existed, and nobody could have told you which two were
      the same (podman and lxd) without hashing them. The parsers around the helper are
      deliberately **not** compared — phase 3 carries a `python3`/`tomllib` branch the
      others lack, and a checker that punishes a real difference teaches people to delete it.

      A fourth placeholder joined the set: **`@HOME@`**, for the per-user directories a lab
      genuinely needs (`~/.config/lab-netboot/…`, `~/.local/state/lab-create/…`). The
      vocabulary is closed at four on purpose — something a reader can hold in their head,
      not an expression language.

      **PARITY IS NOT WIRING, and that distinction is measured rather than argued.** Each of
      phases 3/4/5 gained its own `tests/test-spec-placeholders.sh`, because the parity
      check proves the four copies are the same function and says nothing about whether a
      given driver *calls* it. Control: with `lab-podman.sh`'s call removed but the helper
      left in place, **parity still passes** while the wiring test fails with
      *"a placeholder survived into the parsed spec"*.

      `check-spec-paths.sh` §2 flipped from **counted** to **gated** — the exception went
      when its reason did — and `examples/local-registry/` lost the private `render` step it
      only had because phase 4 could not expand. Two mechanisms for one problem is the thing
      this repo argues against everywhere else.

      **Removing that step also removed a check, and the lab's own control caught it inside
      a minute:** `spec-check` had compared the *resolved* volume lines against what the
      driver needs, and dropping `render` dropped the comparison. It is back, asking the
      phase-4 parser — and its "could not parse" branch now **refuses** instead of warning
      and returning 0, because an unchecked thing must not read as a checked one.

- [ ] **15.9 — should `push` become a verb in phases 4 and 5?** *(split out of 15.6 on
      2026-08-30, once there was something to push to.)* 15.6 said a registry would
      "justify it in phases 4/5"; the registry now exists, and the honest answer is that
      nothing has yet needed the verb. `examples/local-registry/` pushes with `podman push`
      directly, which is what a reader would type. Adding a verb to two drivers is a real
      blast radius — usage text, tests, the guided path, `check-doc-verbs`' probe boundary —
      and this repo's own rule is that a verb added speculatively is a verb nobody has
      watched work, which is precisely the defect 15.6 existed to fix. **So it is a decision
      to make on evidence, not a leftover:** wire it when a lab wants to push as part of a
      flow, and it arrives with a caller.
- [x] **15.7 — one spec hard-codes ~~this machine's~~ NOBODY'S home.** ✅ **DONE
      2026-08-30**, and the framing was wrong in a way worth keeping: `/home/user/mklab/…`
      is not this machine's home, it is **no machine's**. The five sibling specs that carry
      an absolute qcow2 path all name this checkout; that one named a placeholder, and it
      had done so since the file was written.

      **Nothing noticed because the only question ever asked of it was whether it began
      with a slash.** The lab's own test asserted `img.startswith("/")` — which
      `/home/user/…` satisfies perfectly. It now derives the expected value from the lab's
      own location (`<lab>/out/root-on-zfs.qcow2`, the artifact `install-zfs-root.sh`
      writes) and was watched to reject the old value by name.

      **And `lab-vm.sh` moved its own check.** `create_one` did ask whether the backing
      file was readable — but only after `state_init`, the 0700 VM directory and the
      manifest, so a bad path printed *"creating VM"*, an error, and *"cleaning up partial
      VM dir"*. It is in `validate_spec` now, where `kernel`/`initrd` have always been, and
      there is one copy rather than two. The test asserts the **ordering**, not the message:
      asserting the message alone passed identically against both versions, which is an
      assertion attached to nothing.

- [x] **15.8 — ~~7 of the 18~~ 8 of the 19 files in `tools/tests/` were run by nobody.**
      ✅ **DONE 2026-08-30.** `ci.yml` named the meta-checkers one `run:` step at a time —
      a hand-maintained **inclusion list**, the thing §11.3b inverted everywhere else,
      sitting in the job whose entire subject is checks that quietly cover nothing. The ten
      steps are now one: `bash tools/tests/run-all.sh`, discovery-based, so a checker added
      tomorrow runs without anyone remembering to say so. **19/19 pass, 0 skipped**, in
      about a minute.

      **This entry's own count was wrong when it was filed**, which is the joke it
      deserves: *"7 of the 18"* was typed by hand into an item about hand-maintained lists.
      Derived, it is **8 of 19** — the omission was `test-watch.sh`, and the 18 was already
      19 by the time the sentence was written.

      **And the eight are not one group, which matters more than the number.** Two of them
      — `test-doc-verbs.sh` and `test-tree-diagrams.sh` — are the **self-controls for tools
      CI runs every day**: `check-doc-verbs.sh` and `check-tree-diagrams.sh` have their own
      steps in the `docs` job. So those two checkers ran on every push while nothing had
      ever confirmed they could still *catch* anything — *"a scan that matches nothing and
      a scan that is broken print the same green ✓"*, arriving from the one direction this
      repo had not yet looked. The other six (`test-actions.sh`, `test-control-pane.sh`,
      `test-list.sh`, `test-watch.sh` — all four covering `tools/control-pane`, which no CI
      step mentions at all — plus `test-echo-gate.sh` and `test-serial-source.sh`) test
      tools CI does not run.

      **No exemption list, deliberately**, unlike `.harness-net-exempt`. That file exists
      because the *checker* cannot run on those subjects; here every file is a test that
      can decide for itself and print `SKIP:` with its reason, which puts the "why not"
      next to the code instead of in a file that goes stale. None of the nineteen needed
      it. `tools/tests` keeps its harness-net exemption — a runner and a shared `lib.sh`
      are different questions, and the loop's staleness check asks about the second.

      **The ten step comments were not lost, they were the second copy.** Each of these
      checkers opens with a long header naming the incident it exists for; the YAML
      comments were a condensed duplicate sitting next to the runner rather than next to
      the code. One record now, in the file.

**Deliberately not a box:** the survey's §D — the repo has grown a **second, undocumented**
answer to "hand-walk a tutorial" (`RUNBOOK.md` + `setup-workshop.sh` + a
`<lab>-debian.toml`/`<lab>-alpine.toml` pair, in **13** labs, used as a genuine cross-libc
parity oracle) alongside the **10** documented `hand-walk/` subdirs. It is an upgrade nobody
wrote down, not a defect; but nothing asserts the two halves of a pair stay in step, so the
parity claims in those READMEs are unguarded.

---

---

*Created 2026-06-06; #5–#6 added 2026-06-11; #7 added 2026-06-11; #8 added
2026-08-03; #9 added 2026-08-06; #10 added 2026-08-06; #11 added 2026-08-21;
#11.1 and #11.2a closed 2026-08-22; #12 and #13 added 2026-08-24; #12 **closed
2026-08-25**; #14 added 2026-08-25; #15 added 2026-08-26.*

---

## 16. The storage question, decided (2026-08-27)

[`REVIEW-preboot-forth-binary-structures.md`](REVIEW-preboot-forth-binary-structures.md)'s
**F2** is the ultimate goal's only structural blocker, and its *Revised next steps* §3 says
to settle it **before** writing any convenience layer, *"because it is a design fork rather
than sugar"*. This is that decision, written down.

The rest of that step list is now done: §1's three config flips (13.1), §4's `decode-bytes`
(13.2(d)), and three of §2's four assertions — `encode-int` **refuses** a value ≥ 2³²
(13.2(b)), `decode-int`'s zero-extension is **pinned as deliberate** with the reason
measured (13.2(a)), and `encode-phys`'s length is asserted to change with `#address-cells`.
§2's fourth — *"assert `/chosen`'s `stdin` survives a round trip at whatever address
instances actually land on in long mode"* — was open when this section was written and
**closed later the same day by [§0.6a](#06-the-openbios-toolkits-front-of-the-queue-2026-08-27)**:
`property-abi` measures the round trip on both arches (amd64 `h-live=h-prop=14c08`, a
different ihandle from the same node distinguishable at `14ae8`) and reports **`h-hi=0`**,
which also answers the review's own unmeasured question — an amd64 instance does **not**
land above 4 GiB today, so the truncation hazard is latent rather than live. *Corrected
2026-08-30: this paragraph said "still open" for three days after it was not.*

### The fork, and why "pluggable `alloc-tree`" is the wrong half of it

The choice was between generalizing **underneath** the 1275 words (make `alloc-tree`'s
destination pluggable) and a **parallel `encode-at` vocabulary beside** them. Underneath was
chosen — *"with the destination as an explicit parameter rather than a mode flag"*.

**Those two halves turn out to contradict each other, and finding that is the useful part.**
`alloc-tree` is called *inside* `encode-int`, where the caller cannot reach it. Making it
pluggable therefore means the destination lives in a **variable** that `encode-int` reads —
which is a mode flag wearing a parameter's clothes, and *"a cached fact about which arena you
are in"* is the bug class this repo has now found eleven times. It also leaves the
device-tree path and the toolkit path sharing one mutable global, which was the risk the
option was chosen *despite*.

### What is chosen instead: split allocate-and-write, and keep one implementation

Each encode word is already **size → allocate → write at the allocated address**, and *the
write already takes an explicit destination*:

```forth
: encode-int    ( n -- prop-addr prop-len )     /l alloc-tree tuck l!-be /l ;
: encode-string ( str len -- prop-addr prop-len ) tuck char+ alloc-tree tuck 3 pick move swap 1+ ;
: encode-bytes  ( data-addr data-len -- prop-addr prop-len ) tuck alloc-tree tuck 3 pick move swap ;
```

So the writer is `l!-be` and `move` — both already parameterized by address. The refactor
**exposes the writer and the sizer, and redefines the 1275 word in terms of them**:

| new | shape |
|---|---|
| `/int` `/string` `/bytes` | sizers — how many bytes this value needs |
| `int!` `string!` `bytes!` | writers — **destination is a stack parameter** |
| `encode-int` … | unchanged signature: sizer → `alloc-tree` → writer |

That satisfies both halves of the decision at once, and it satisfies a rule the "pluggable"
version could not: **extract the shipped thing, never re-implement it.** There is one
encoder per type, used by the device tree and by the toolkit alike. The two paths share
**no mutable state at all** — not a global, not a mode — so the risk named when the option
was chosen is removed rather than accepted.

Composition for the mapped case is a **cursor passed explicitly** (`( dest -- dest' )`), not
a current-arena variable. [Patch 27](examples/openbios-the-rival-that-shipped/patches/27-encode-plus-concatenates.patch)
already removed the obstacle the review named here: `encode+` no longer requires arena
adjacency, so composing fragments no longer depends on where they were allocated.

### The surface is four call sites, not eight

Re-derived rather than quoted — the earlier figure counted the whole file:

| `property.fs` | what it allocates | in scope? |
|---|---|---|
| `encode-int` `encode-string` `encode-bytes` | **encoded arrays** | ✅ the toolkit surface |
| `encode+`'s non-adjacent path | a combined encoded array | ✅ |
| `(property)`'s `prop-node.size` and its name copy | **device-tree nodes**, not encoded arrays | ❌ deliberately different — redirecting these would put tree structure in a flash region |

### First deliverable, and its observable checkpoint

Per the house rule, an outcome and not a mechanism: **the same `encode-int` bytes appear at
an address the caller chose, with `here` unchanged across the call.** Concretely, at the
amd64 prompt — `here` before and after must be equal, and the four bytes at a caller-supplied
buffer must equal what `encode-int` produces into the arena for the same value.

`here` being unchanged is the assertion that matters: it is what distinguishes *writing where
you were told* from *writing into the arena and copying*, and only the first of those can
ever be aimed at MMIO or flash.

### First deliverable — **DONE 2026-08-27**, [patch 31](examples/openbios-the-rival-that-shipped/patches/31-encode-writers-take-a-destination.patch)

`/int` `/string` `/bytes` and `int!` `string!` `bytes!` exist; the three `encode-*` words
are redefined in terms of them with their signatures unchanged. `string!` writes the
terminator itself — `alloc-tree` zero-fills and the old `encode-string` inherited that, but
a caller's buffer is not pre-zeroed. And `int!` **inherits §13.2(b)'s
refusal for free**, because it *is* `l!-be`: a value that cannot survive four bytes is
refused wherever it is aimed.

`property-abi` asserts both halves of the checkpoint, on both arches:

```
s-int-HERE-UNCHANGED   s-int-BYTES-MATCH
s-str-HERE-UNCHANGED   s-str-len=3   s-str-nul=0   s-str-txt=ab
```

**The first two controls were bad ones, and the way they were bad is the point.** Making
`int!` allocate-and-write-elsewhere, or do nothing at all, broke **every property in the
device tree** — the probe never ran, and the generic *"probe did not complete"* gate fired
instead of the named assertion. That is this repo's own rule, from the chaos-harness
section: *scope the fault to the subject under test*, because a fault that breaks everything
sends every scenario to the same rung.

The narrowed pair isolates one assertion each **with the other still passing**, which is
what proves they are jointly necessary rather than one being decorative:

| injected | `here` | bytes |
|---|---|---|
| `int!` also bumps `here` | **MOVED** ✗ | MATCH ✓ |
| `int!` writes one byte late, **only for the probe's value** | UNCHANGED ✓ | **DIFFER** ✗ |

The second is scoped to a value the device tree never encodes, so the firmware stays up and
only the subject fails. `string!` losing its terminator fails by name too, against a buffer
poisoned with `ff` first so an inherited zero cannot pass for a written one.

### Second deliverable, the cursor — **DONE 2026-08-27**, [patch 32](examples/openbios-the-rival-that-shipped/patches/32-the-cursor.patch)

`int!+ ( n dest -- dest' )`, `string!+`, `bytes!+`. **The cursor is the value on the stack,
not a current-destination variable** — two structures can be under construction at once, in
different memory, with nothing to save and restore. A variable would be the mode flag this
section rejected, one layer up.

What it demonstrates is the toolkit's **minimum viable shape**: three fields written at a
caller-chosen address, then read back with the **stock 1275 decoder**. The read half was
always general — that is F2's other half — and only the write half was arena-bound. Now
both halves meet at an address the caller picked:

```
tgt  11111111 swap int!+  22222222 swap int!+  33333333 swap int!+
w-advanced=c   w-HERE-UNCHANGED
tgt c decode-int  ->  11111111, 22222222, 33333333
```

**The controls are scoped by construction** this time: the new words have no device-tree
callers, so a fault in them cannot take the firmware down before the probe runs — which is
exactly what went wrong controlling patch 31's writers.

| injected | what fired |
|---|---|
| stride wrong (`/int 1+`) | `w-advanced=f`, and **field one is still correct**: `w-i1=11111111`, `w-i2=ff222222`, `w-i3=22ff3333` — the buffer's poison bleeding through the gaps |
| the cursor touches the arena | `w-HERE-MOVED`, with all three fields still decoding correctly |

The first of those is why the assertions cover fields **two and three**: a cursor that
advances wrongly writes the first field perfectly, so field one proves nothing. The second
isolates the arena property from the correctness property, the same pairing patch 31 needed.

### Third deliverable, real storage — **DONE 2026-08-27**, `smoke-openbios.sh pmem-writer`

The first two were proven against a dictionary buffer, which is still the firmware's own
memory: `here` unchanged was the *only* thing separating them from the arena words they
replaced. This aims them at an **NVDIMM at `0x100000000`** — above 4 GiB, reachable only in
long mode, and backed by a file on the host.

```
before: offset 4194304 reads [00 00 00 00 00 00 00 00 00 00 00 00]
after:  offset 4194304 reads [c0 ff ee 01 c0 ff ee 02 c0 ff ee 03]
```

Three ints written by `int!+` at `0x100400000` (4 MiB into the region, clear of `/nvram`'s
own partition at the base), read back through the stock `decode-int` with `here` unchanged —
and then found **byte-for-byte in the host's file by `od`, after QEMU exited**. If the bytes
are in that file, they left the firmware. **F2 is closed in fact, not only in principle.**

**The host file is the assertion and the prompt is not**, and the control proves why. Aiming
the identical probe at ordinary RAM (`0x4000000` instead of `0x100400000`):

| | |
|---|---|
| `padv`, `pi1`–`pi3`, `here` | **all pass** — `int!+` and `decode-int` agree with each other |
| the host file | **unchanged**, and the track fails on it |

That agreement between two firmware words is exactly what this check exists to distrust:
only a reader that is *not* the firmware can say where the bytes went. Same reason the
`amd64-pmem` track greps the image rather than trusting `printenv`.

*(One self-inflicted delay worth recording: the first driver expected `"0 > "` between the
writes. The prompt prints the **stack depth**, and the cursor is deliberately on the stack —
so it waited forever. Third time tonight the depth-in-the-prompt has caught me.)*

### Flash — measured 2026-08-27, and the answer is **no**, `smoke-openbios.sh flash-writer`

**A CFI part is not a store-to seam**, and knowing that is worth more than assuming the
NVDIMM result generalizes. `arch/x86/openbios.c`'s `lab_flash_write()` does the Intel
sequence — `0x20` setup, poll status, `0x40` program per byte, `0xff` back to read-array — so
a bare store into that window is a **command**, not data.

| | |
|---|---|
| the corrected window, erased part | `r0=ff ff ff` — and the no-flash control reads `0 0 0`, so `ff` is a measurement |
| after three `int!+` stores | `r1=ff ff ff` — the array is untouched |
| the host image at offset 0 | `ff ff ff` — untouched |

**So the split's conclusion holds and its scope is narrower than `pmem-writer` suggests: the
writer produces bytes at an address; getting those bytes into flash is the flash driver's
job, above it.** That is the correct layering rather than a gap — it is how every real
firmware programs a part.

**And the trap is worth the track on its own.** Storing at the *uncorrected* `ffbe0000` reads
back as `c0 ff ee` — convincingly, and nowhere near the chip. x86 rebases the GDT, so a Forth
address is not a physical one; the store went to RAM. That is
[§13.3(A)](#a-x86s-client-context-read-a-stale-copy-of-the-firmware--closed-2026-08-26)'s
segment fact met from the other side, and it cost this track two runs before the erased-flash
read caught it. The track pins all three facts, so nobody re-derives the wrong one.

*(Two instrument bugs found on the way, both by the controls: the first attempt sized the
pflash images wrong and the firmware's own CFI probe reported no chip at all; and every value
extraction matched the console's command **echo** — `r0=" fw @ …` comes before `r0=ff ff ff`
in the log — and printed an empty value into otherwise-correct messages.)*

### Third seam, MMIO — **DONE 2026-08-27**, `smoke-openbios.sh mmio-writer`

1000 `int!` stores into the legacy VGA aperture at `0xb8000` put **167,685 blue pixels** on
the display, where the pre-write dump and the no-write control each hold **0**, with `here`
unchanged. Read by QEMU's **`screendump`** — an observer the firmware cannot fake, and the
point of the exercise: `decode-int` agreeing with `int!` says nothing about what the hardware
did.

| seam | stores | observer |
|---|---|---|
| NVDIMM (`pmem-writer`) | **land** | a **file**, read after QEMU exits |
| CFI flash (`flash-writer`) | are **commands**; the array is untouched | the array, and the host image |
| VGA aperture (`mmio-writer`) | **land** | a **device**, read by `screendump` |

Three seams, three answers. The writer can be aimed at all three; what differs is whether a
store is data and who can see it.

*Two implementation notes, both from failed first attempts. The console paints this same
screen, so it **scrolls** — a four-character write at row 0 was gone before the next prompt
was drawn, and the probe duly reported no change; filling all 80×25 cells is scroll-proof.
And the assertion counts pixels of VGA **blue** (attribute `1f`), a colour the console never
produces, rather than diffing the images — a raw diff is swamped by console echo.*

**Upgraded 2026-08-27, once 0.6c and 0.6d were fixed:** `mmio-writer` now also aims at the
**live PCI BAR**, which is the test this section originally wanted.

```
BAR0 at 0x40000000:  [00 00 00 00 00 00 00 00] → [c0 ff ee 01 c0 ff ee 01]
```

read by QEMU's monitor (`xp`, a guest-physical read) rather than by `screendump`. **The
display cannot answer that one**: the VGA sits in 640×480 compat mode scanning the
**legacy** aperture, not the linear framebuffer, so a real store into BAR0 is invisible on
screen — and `screendump` could not tell it from a store that never happened. Two outside
observers, chosen for what each can actually see.

### It WAS not a PCI BAR, and that was two defects — both now fixed

Trying to aim at the real framebuffer BAR is what found them.

- **The VGA BAR0 is never assigned on amd64.** QEMU's own `info pci` reports
  `Bus 0, device 2: BAR0: 32 bit prefetchable memory at 0xffffffffffffffff` — unassigned.
  The firmware places BAR2 and BAR6 inside a ~1 MiB window and never finds room for the
  16 MiB BAR0, so the device tree's `assigned-addresses` carries **`phys.lo = 0`** for it.
- **`" screen" open-dev` faults**, downstream of that same zero: a general protection fault
  with **`dstackcnt=-3`** — a data-stack underflow — as `map-fb` hands `pci-bar>pci-addr` an
  entry whose address is 0. **This became reachable only with
  [§13.3(D)](#d-pcic-wrote-its-property-cells-in-host-byte-order--closed-2026-08-27)**: before
  that fix the `screen` alias resolved to nothing, so nobody could open it. Fixing one layer
  exposed the next, which is the ordinary shape of this work.

Both are now fixed — [patch 33](examples/openbios-the-rival-that-shipped/patches/33-first-memory-bar-got-address-zero.patch)
and [patch 34](examples/openbios-the-rival-that-shipped/patches/34-pci-bus-cell-counts.patch),
§0.6c and §0.6d — and neither was what its first framing said. The BAR was not too big for a
window; the allocator's base was never seeded. And the open did not fault because of that
zero; a PCI bus had never declared `#address-cells`, so every Forth decode read one cell
short. **They were independent**, which the measurement settled after the TODO had guessed
they were one.

Review §2's fourth assertion is **closed** (§0.6a): `/chosen`'s `stdin` round-trips at the
address instances actually land on, and the review's own UNKNOWN — whether an amd64 instance
can land above 4 GiB — is answered per boot rather than assumed. It cannot, today.
- **Review §2's fourth assertion** — `/chosen`'s `stdin` surviving a round trip at whatever
  address instances land on in long mode — and the review's own unmeasured question of
  whether an amd64 instance can land above 4 GiB at all.

---

## 17. OpenBIOS: open decisions and dangling issues (as of 2026-08-28)

Everything still open for `examples/openbios-the-rival-that-shipped/`, in one place,
so it stops being scattered across §13–§16 and the PR history. **Both of the
decisions are now taken**: §17.2 on 2026-08-28 (nothing goes upstream) and §17.1
on 2026-08-29 (two address cells, amd64 only). What is left below is dangling
issues, named so they are not rediscovered as new.

**All of 17.1–17.7 are closed. §17.8 is what was left when they were** — not
items, but sentences inside the closed sections: a claim nothing had derived and
a page of counts nothing was reading. Audit the closed section's *prose*, not
just its checkboxes.

### 17.1 — ~~DECISION: should the root declare `#address-cells 2`?~~ — DONE 2026-08-29 (patches 42-43)

**Decided: yes, on amd64 only.** `arch/amd64/init.fs` now declares
`#address-cells 2 / #size-cells 2` on the root, and `/memory` describes the whole
machine. At `-m 5G`:

```
reg    00000000 00000000   00000000 0009fc00
       00000000 00100000   00000000 bfee0000
       00000001 00000000   00000000 80000000
```

The coreboot path was measured separately rather than assumed, because
§17.1 claimed *both* paths and only one of them had ever been booted at 5 GB.
`-bios build-openbios-amd64/coreboot.rom -m 5G` reports `RAM 5118 MB` and:

```
reg    00000000 00001000   00000000 0009f000
       00000000 00100000   00000000 bfd71000
       00000001 00000000   00000000 80000000
```

Different first range — coreboot's map starts at `0x1000`, so the node is
`memory@1000` there and `memory@0` on multiboot — and the same third range. The
`1 of 3 range(s) NOT published` line is gone from both.

**x86 stays at one cell, and that is the point rather than a compromise.** A
32-bit firmware cannot form an address above 4 GiB either way, so one cell there
is *accurate*; two would be a wider hole to say the same nothing in. The blast
radius is per-arch because the capability is.

**What the blast-radius map found before the first edit**, by asking the running
firmware rather than reading C: root has fourteen children on amd64 and exactly
**three** carry a `reg` — `memory@0`, `pci8086,1237@0` and `ide@0..3`. The first
two already *derive* their cell counts from the root (`libopenbios/init.c`,
`drivers/pci.c`). The third did not: `drivers/ide.c` wrote a fixed three cells,
which decoded correctly by luck at one address cell and would have read
`[channel][0]` as `channel << 32` at two — `/ide@1` resolving to nothing while
`/ide@100000000` resolved instead, taking the boot aliases, the showcase's boot
line and every `load` off the CD with it. That is patch 42, landed and measured
*before* the root moved so the two are separable.

**The unit words had to move with the count**, and this is the part that would
have failed quietly. `forth/device/tree.fs`'s shared root decodes a unit address
with `parse-hex` and encodes it with `tohexstr` — one cell each way — while
`forth/device/pathres.fs`'s `(exact-match)` compares exactly as many leading
cells of a child's `reg` as `decode-unit` returned values.
[`arch/sparc64/tree.fs`](https://github.com/openbios/openbios) overrides the same
two methods on the same shared root, which is the in-tree precedent that
overriding works at all. Every node kept its name: `memory@0`, `ide@1`,
`pci8086,1237@0`.

**`#size-cells` is now declared rather than defaulted, which closed a
disagreement.** Absent, this tree had two answers for it: `my-#scells` falls back
to 1 (`forth/device/property.fs:234`) while `drivers/pci.c` asked
`get_int_property()` and got **0** — which is why the PCI host bridge's `reg` was
a lone address cell with no size beside it.

**The instrument came first, as §17.1 predicted it could.**
`smoke-openbios.sh property-abi` gained a `ranges` case — the *parent* half of a
`ranges` entry, taken at the PCI bus where one lives, since a ranges entry's
child halves use the bus's own 3/2 (patch 34) and its parent half uses the root's
cells. It was landed and passing at **one** cell before the root moved, and every
expectation in it is derived from the root's own declaration read back off the
running firmware, so it now reports 2 cells on amd64 and 1 on x86 from the same
assertions.

**And it caught the thing it was aimed at.** The track's old `encode-phys is not
fixed-width` assertion compared `/` (no parent → the 1275 default of 2) against
`/ide@1` (root's declared 1). At two cells those become **equal** on amd64 — an
assertion failing on a change rather than on a defect, which is the
mechanism-not-outcome trap in its expensive direction. It now measures three
contexts per arch, the third being a PCI child whose bus declares 3, which no
root change can move.

Green after: `property-abi`, `dict-identity`, `vga`, `client-forth`,
`diagnostics`, `amd64`, `amd64-pmem`, `amd64-linux`, `multiboot`, `persist`,
`coreboot`, `coreboot-amd64` — and **`ppc` rebuilt and re-smoked as the control**
for the shared-file edit in `drivers/ide.c`.

### 17.2 — ~~DECISION: upstream the patches that are upstream's bugs~~ — DECIDED 2026-08-28: none of them

**Settled: nothing goes upstream.** All 41 patches are carried as deliberate
local divergence, indefinitely. The reason is review burden on a small volunteer
project, not a judgement about the code:

> "We won't be upstreaming anything… I don't want to bother the maintainers of
> this project. This repo is very low activity. It seems to be in maintenance
> mode."

**The blocking unknown was answered before deciding, and it answered the other
way.** [`open-firmware-native-habitats/`](examples/open-firmware-native-habitats/README.md)
recorded that whether upstream accepts PRs was **unverified** and that the check
comes first. Measured 2026-08-28: `openbios/openbios` has commits dated
**2026-06-29**, including a `.github/workflows` update — a maintained repository
with CI, moving slowly. So this is a decision about our posture, **not** a claim
that upstream is dead, and the catalog says so in those words. Writing down the
comfortable version would have been a record that outlives its subject, which is
the failure this lab exists to keep finding.

**The sort was done, and it is now a checked artifact.**
[`patches/00-CATALOG.md`](examples/openbios-the-rival-that-shipped/patches/00-CATALOG.md)
classifies all 41 by why each exists — `UPSTREAM-BUG` 20, `PORT` 10, `FEATURE` 7,
`FIXTURE` 2, `DIVERGENCE` 1, `RECORD` 1 — with a `scope` column separating the
**22 shared-path** patches (where a pin bump will actually conflict) from the 19
that touch only `arch/`, `include/arch/` or their own `*_config.xml`.

**Only one patch is a divergence in the sense of wanting different behaviour**
(patch 15's Forth-source loader). The other 40 are things upstream would
arguably want and is not going to be asked for — which is the honest shape of
"all 41 are ours".

`check-patch-hygiene.sh` **A7** binds the catalog to the series: one row per
patch both ways, kinds drawn from the vocabulary the document itself defines,
and the scope and count columns **recomputed** from the patches on every run
rather than read off the page. The counts earned that within an hour of being
typed — the hand-tallied summary said 22 `UPSTREAM-BUG` and 9 `PORT` where the
rows say 20 and 10. Eight scanner self-controls run first, and all four
injections into the real catalog (a deleted row, a flipped scope, a decremented
count, a kind renamed in one place only) were watched to bite.

**What would reverse it.** The 20 `UPSTREAM-BUG` rows are the candidate set,
already one-per-defect with PR-shaped `Subject:` lines and `Arch-tested:` lines
from patch 20 onward. Carrying them locally forecloses nothing.

### 17.3 — ~~`/memory` has a `reg` but no `available`~~ — DONE 2026-08-29 (patches 44-45)

Both PC arches now publish `available` beside `reg`, and **it is republished on
every claim and every release rather than snapshotted at boot** —
`libopenbios/ofmem_common.c` does the same for the arches that have ofmem; x86
and amd64 have none, so their bump allocators call it themselves. A property
that describes a *cursor* and is written once is a record that outlives its
subject the first time a client allocates.

```
available  00800000 1f7e0000        (amd64, -m 512)
claim 1000 -> 00801000 1f7df000
release    -> 00800000 1f7e0000
```

**17.3 turned out to contain a second, unrecorded defect, and it was the bigger
one.** `arch/amd64` bound **no `cif-claim` or `cif-release` at all** — no
`/openprom/client-services` block — so the 1275 claim service fell through
`forth/system/ciface.fs`'s `else 3drop -1` and *every* client allocation on the
64-bit firmware returned `-1`. Measured before writing anything, with the
positive control in the same run: `" cif-claim" find-method` found it on x86 and
did not on amd64. Publishing `available` there first would have advertised memory
nothing could take. That is **patch 44**, kept as its own diff.

**x86's window formula could not be copied**, which is the interesting part.
x86 sizes its window as 8 MiB up to `virt_to_phys(0)` — the bottom of the
client's address window, below the **relocated** firmware — and both ends move
with `virt_offset`. amd64 does not relocate at all, so `virt_to_phys(0)` is 0 and
the same expression yields an **empty** window: an allocator that refuses
everything. amd64's limit is derived from `sys_info`'s memory map instead.

**`available` is deliberately narrower than "all unallocated RAM".** Both arches
allocate from one window, so RAM outside it — everything above 4 GiB included —
is in `reg` and will be **refused** by `claim`. Under-reporting costs a client an
option it never had; over-reporting is a lie. An empty window publishes a
**zero-length** property rather than none, because *"nothing is free"* and
*"nobody has said"* are different answers.

**New track: `memory-available`**, on both arches, and it asserts that the
property **moves** rather than that it exists — claim a page, the free base rises
by exactly `0x1000` *and* the size falls by exactly `0x1000`; a LIFO release puts
both back. The control that makes those mean anything is a claim of `0xffffff000`
bytes: it must return `-1` and leave the property **untouched**, or "it moves"
would be satisfied by a value wired to anything that changes.

**All four assertions were watched to bite, and two of the four controls were
themselves wrong first** — this repo's own rule about where the bugs are:

| injected | result |
|---|---|
| publish once at boot, never after | *"available is not tracking the allocator"* — but only after the control was fixed: the first attempt removed the **boot** publish too, so the property was absent and an earlier assertion fired |
| amd64 binds no `cif-claim` | the missing-method failure — but only after the control was fixed: **deleting** the bind left the function unused, `-Werror` stopped the build, and the track SKIPped having tested nothing |
| a refused claim republishes anyway | *"a REFUSED claim still moved 'available'"* |
| hard-code the cells to 1/1 | *"not encoded with the counts that decode it"* |

**~~Not asserted~~ — CLOSED 2026-08-29:** that `available` is a subset of `reg`
was a claim from *reading* (*"true by construction, the window comes from the
same `sys_info`"*), which is the shape of every stale record this lab has found.
The track now reads `reg`'s cells off the running firmware, regroups them with
the root's counts, and asserts containment. Control: publishing a window
`0x10000` past the range end fails with *"the free window 800000..1fff0000 is NOT
inside any range of /memory's reg"*.

### 17.4 — ~~§13.3(B): `number()`'s two C99 divergences~~ — DONE 2026-08-29 (patch 46)

Both closed, plus the undefined behaviour §13.3(B) named and declined to test.

| case | C99 | before | after |
|---|---|---|---|
| `%.0d` of `0` | *(nothing)* | `"0"` | *(nothing)* |
| `%08.3d` of `42` | `"     042"` | `"00000042"` | `"     042"` |

**The parked reasoning was re-derived, not trusted, and it still held.** A
repo-wide grep for an integer conversion carrying a precision finds ppc's four
`%8.8lx` in the boot path — no `0` flag, asserted correct — and for `%08.3d`,
nothing but the fixture asserting the divergence itself. So there was still no
in-tree caller.

**What the parked note did not weigh is §13.3(C), which happened in this same
tree.** A printf that disagrees with C99 is a latent *"two printfs answering one
call"*: GCC may constant-fold `snprintf`'s **return** per C99 while our code
writes different bytes. That is precisely the ppc32 bug that cost a day and
presented as a firmware defect. `-fno-builtin` now prevents it on every arch
(patch 29) — but that is a mitigation one build-flag edit away from being lost,
and the divergence is the thing it mitigates. Closing it removes the hazard
rather than the symptom. **That argument, not the formatting, is why this stopped
being the lowest-value item on the list.**

**The third fix is what made the fixture shippable.** `number()` did
`num = -num` on a `long long` with no guard, so `LLONG_MIN` was undefined
behaviour; §13.3(B) named it from the source and declined to test it *"because
testing it would mean shipping the UB in a fixture"*, which was correct. The
digits now come from an unsigned accumulator, where the negation is defined for
every input.

**The `llmin` fixture is an UNKNOWN, not a proof** — re-injecting the old signed
`-num` leaves it **green**, because on x86-64 GCC the undefined negation happens
to produce the two's-complement bit pattern. That was reported as BLIND rather
than hidden.

**CLOSED 2026-08-29 with an instrument that out-reaches the defect.** A firmware
fixture compares *bytes*, and the bug produces the right bytes; no arrangement of
byte comparisons can see it. A **sanitiser** observes the *operation*.
[`tools/openbios-check-vsprintf-ub.sh`](tools/openbios-check-vsprintf-ub.sh)
compiles the **shipped** `libc/vsprintf.c` on the host under
`-fsanitize=undefined` and runs the same case: silent on the shipped file,
and with `-num` re-injected it reports *"negation of -9223372036854775808 cannot
be represented in type 'long long int'"*. Its §0 runs that control **first**, so
the instrument proves itself before it is aimed at anything.

**And the reach depends on `-O0`, which is the finding.** At `-O1` or `-O2` GCC
legally rewrites the signed negation into an unsigned one and the undefined
operation stops existing in the object code — measured on gcc 13.3. That is also
the deeper reason no *runtime* test could ever have seen this: the firmware is
not built at `-O0`, so at its own optimisation level the UB has already been
optimised away. Undefined behaviour is a property of the **source**; `-O0` is
what keeps enough of the source in the binary for a sanitiser to point at it.
`tests/test-vsprintf-ub.sh` runs it in the suite — it costs a compile, not a boot.

**The fixtures inverted rather than disappeared** — they were built for this day
(*"if someone fixes `number()`, this line fails and says so"*) — and moved from
the divergence counter into the ordinary one: **17/17 ok, 0/0 recorded
divergence**. The `0/0` half stays in the summary on purpose: it is a positive
statement that somebody looked, and dropping the phrase would make a tree
carrying a *new* divergence print exactly what a conformant one prints.

Controls: `%.0d` re-injected → `d-zero want[](0) got[0](1) BAD`; the `0` flag
re-injected → `zeropad-prec got[00000042] BAD`; the signed negation re-injected →
**BLIND**, reported above.

### 17.5 — ~~Builds are not byte-reproducible~~ — DONE 2026-08-29 (patches 47-48); both causes closed

§17.5 said *"something dated is baked in during bootstrap"* and left it. Chased,
and it is **two causes**, not one. Both are now closed and both arches rebuild
byte-identically on request.

**Cause 1 — the build date, both arches, and it is exactly two bytes.**
`Makefile.target` generates `obj-<arch>/forth/version.fs` from
`date +'%b %e %Y %H:%M'` and compiles it into the dictionary. Two x86 builds a
minute apart differ by the minute digits and nothing else. (The old note in
`MANUAL_TESTING.md` blamed `__DATE__`/`__TIME__`; it is make, not the compiler.)

**The date is not noise, which is why it was not deleted.** `smoke-openbios.sh`'s
ppc track proves the running firmware is **ours** rather than the distro's
`-bios` blob by comparing exactly that banner, and boots the distro blob
alongside to show the two differ. Stamping a constant would make that comparison
pass on two identical blobs. So the build honours **`SOURCE_DATE_EPOCH`** — the
reproducible-builds standard — and is bit-for-bit unchanged when it is unset.

Measured both ways: with the epoch pinned, x86's dictionary,
`openbios-builtin.elf` and `openbios.multiboot` are **byte-identical** across two
builds, and the dictionary is stamped `Nov 14 2023 22:13`, which is the control
proving the build honoured the variable rather than two builds merely landing in
the same minute.

**Cause 2 — amd64 only, was NOT in the record, and is now FIXED (patch 48).**
With the date pinned the amd64 dictionary *still* differed, by ~79 bytes. The
cell holding `end-mem` read

```
build A   0000 7322 4a7d e018
build B   0000 70d9 f729 c018
```

— canonical Linux userspace addresses. `init_memory()` hands `initialize-forth`
the bounds of the **host's** 1 MiB Forth arena, and the bootstrap then stores
pointers into that arena in ordinary dictionary cells: `start-mem`, `end-mem`,
`free-list`, the pockets, `prep-dict`, `prep-here`, `/options`' string values.
**Fourteen of them.** They are not relocatable — the relocation table covers
pointers into the *dictionary*, and these point into a different allocation — so
they were written out raw and moved with ASLR.

**x86 never showed it for a reason, not by luck.** When the target cell is
narrower than a host pointer, `cross.h`'s `pointer2cell` **subtracts**
`base_address`, so what lands in the image is a small stable offset. At equal
widths the raw address is stored.

**Zeroing them is safe because they are dead data**: every one is written again
before it is read, by `initialize-forth` → `init-mem` / `init-pockets` /
`init-tmp-comp`. The image's copies have never been the values the firmware runs
on.

**Two things about the fix were found rather than foreseen, and both by controls:**

| | |
|---|---|
| the first draft was **unscoped** | on narrower-target builds `arena_lo` comes out as **0**, the window becomes `[0, 1 MiB)`, and every small integer matches — building x86 scrubbed **4530** cells and the bootstrap segfaulted. The comment claiming the range *"cannot collide with a real value"* was simply wrong |
| scrubbing **one** writer was not enough | `openbios-builtin.elf32` still differed by 30 bytes: `write_dictionary_hex()` emits the C array compiled into the builtin ELF and reads the live dictionary separately. The rule now lives in one `scrub_host_arena_ptr()` that both writers call |

**Measured after: both arches rebuild byte-identically** with the epoch pinned —
dictionaries, multiboot images and the builtin ELF alike.

**The checker has no known-gap row left, so it grew a real negative control.**
[`tools/openbios-check-reproducible.sh`](tools/openbios-check-reproducible.sh)
now also builds once with `SOURCE_DATE_EPOCH` **unset** and requires that build
to differ. Without it, *"identical"* would be equally consistent with a
comparison that never looked.

**Consequences that still hold:**
- [`openbios-archive-tree.sh`](tools/openbios-archive-tree.sh) digests **source**
  and excludes `obj-*`, which is what makes an archive comparable to a cold
  reproduction. A digest over the binaries would still identify nothing on amd64.
- *"The cold tree and the dev tree build identical bytes"* — **MEASURED
  2026-08-30, and it holds.** It was written here as a claim this lab *"**can**
  make"*, which is not the same as one anybody had made: nothing had ever built
  the cold tree and compared. [`tools/openbios-check-cold-tree.sh`](tools/openbios-check-cold-tree.sh)
  does it — clone at the pin, apply `TESTED-TREE.patch`, build both arches with
  `SOURCE_DATE_EPOCH` pinned — and reports **722/722 source files
  sha256-identical** and **6/6 artifacts** byte-for-byte equal (both
  dictionaries, both multiboot images, `openbios-builtin.elf` and
  `.elf32`). So the tree this lab measures **is** the tree its record defines,
  and that is now a derivation rather than a sentence. Not in `run-all.sh`: a
  cold clone plus four container builds; `MANUAL_TESTING.md`'s *Reproducer
  notes* carry the invocation and the transcript.

### 17.6 — ~~The provenance/rebuild ordering trips easily~~ — CLOSED 2026-08-29

The guard was never wrong: `smoke-openbios.sh`'s coreboot tracks SKIP with *"this
ROM was built from a DIFFERENT payload"* whenever the firmware is rebuilt without
rerunning `./build-coreboot-openbios.sh <arch>`, and it once caught a ROM that
had spent **two days** reporting on a payload predating every fix in the tree
beside it.

**What was wrong is WHERE it spoke.** It fired minutes later, from a different
command, and it fired three times in one day here before anyone wrote down that
it is a *sequencing* trap rather than a bug. A record that says *"recognise this
SKIP instantly rather than debugging it"* is documentation standing in for a
fix.

`build-openbios.sh` now says it **at the moment the staleness is caused**:

```
==> NOTE: build-openbios/coreboot.rom no longer carries this firmware.
    ./smoke-openbios.sh coreboot will SKIP until you run:
        ./build-coreboot-openbios.sh x86
```

It names the track that will skip and the exact command that fixes it. It is a
**note, not a failure** — rebuilding firmware without rebuilding a ROM is an
ordinary thing to do, and only matters if you then expect those tracks to run.
And it asks [`openbios-rom-provenance.sh`](tools/openbios-rom-provenance.sh)
rather than comparing dates or paths itself: one implementation of *"does this
ROM carry this payload"*, shared by the gate and by the notice.

Both directions were watched: rebuilding x86 firmware produces the x86 notice,
and after rebuilding the x86 ROM, building **amd64** produces the amd64 notice
and **no x86 notice** — so it is tracking the payload rather than firing on every
build.

### 17.7 — ~~Repo-wide, not OpenBIOS-specific~~ — CLOSED 2026-08-29 as double-tracking

This was never an item, it was a **pointer** — and a backlog recorded in two
places drifts in one of them. §15 is the home; §17 is for OpenBIOS. The openbios
rows in §15.1 and §15.3 closed on 2026-08-27, which is what this entry existed to
say, and it has now been said in §15 itself.

**Re-derived before deleting it**, because the counts were dated 2026-08-26 and
this lab's own rule is that a fact asserted three sessions ago is a cache entry.
Measured 2026-08-29 by aiming `check-harness-net.sh` at every `tests/` directory
containing a `*.sh`: **18 directories, 14 pass, 4 fail** —
`examples/almalinux-packer-images/`, `examples/kali-packer-vagrant/`,
`examples/package-mirror-ram/` and `tools/tests` — the same four §15.1 names, and
the same three (plus `tools/tests`, which §15.3 excludes on purpose) with no
`run-all.sh`. **The record was accurate**, which is worth knowing rather than
assuming.

**One thing the record did not say, and it changes what §15.2 means:** all four
fail on the *first* check, *"no lib.sh — there is no shared net to check"*. The
scanner never reaches their tests. So the state of those suites is **UNKNOWN**,
not bad: §15.2's *"three private copies of the net, one already drifted weaker"*
is what somebody found by reading, and nothing has yet been able to measure the
rest.

### 17.8 — the residue inside §17 itself — CLOSED 2026-08-30

Every subsection above was struck through, so "what is left in §17" was not a
list of items but a handful of **sentences inside the closed ones**: a claim
nothing had derived, and a page of counts nothing was reading. Both are the
failure mode this section exists to document, committed by the section that
documents it.

**(a) *"can make"* is not *"measured"*.** §17.5 closed byte-reproducibility and
then wrote that *"the cold tree and the dev tree build identical bytes"* is a
claim this lab **can** make. Nobody had built the cold tree. Now
[`tools/openbios-check-cold-tree.sh`](tools/openbios-check-cold-tree.sh) does:
**722/722 source files sha256-identical**, **6/6 artifacts byte-identical** on
both arches. The claim holds — which is the good outcome, and was never the
point. An underived claim is an UNKNOWN wearing a PASS's clothes whether or not
it happens to be true.

**Its control found three defects in the checker, none visible in the green
run** — the repo's own rule about where the bugs are, on the first try:

| the defect | how it presented |
|---|---|
| the artifact message asserted *"the sources are identical, so a third source of non-determinism has appeared"* — **in a run where the source half had just reported them different** | four confident lines sending a reader to hunt determinism, when the cause was the edit named two lines above |
| `cmp -l` writes `EOF on <file>` to **stderr** when the lengths differ | two lines of noise above the verdict, in the report of a tool whose subject is reading bytes carefully |
| one edited file was counted as **2 differing entries** | `diff` emits a `<` and a `>` for the same path; the list printed it twice |

**And the reach was measured rather than assumed.** Of the six artifacts, the
two `openbios.multiboot` loaders do **not** embed the dictionary: the control
tree — one extra Forth word — built a byte-identical multiboot on both arches
while both `.dict`s and both `openbios-builtin.elf`s changed and contained the
new word. So `6/6` is not six independent witnesses, and the tool now says which
file answers which question instead of letting the ratio imply it.

**(b) A7 guarded the tables; every stale number was in the prose above them.**
[`patches/00-CATALOG.md`](examples/openbios-the-rival-that-shipped/patches/00-CATALOG.md)
opened *"all 41 are ours"*, said a pin bump *"re-applies all 41"*, split them
*"22 of 41"* against *"The 19 `arch-local` rows"*, and closed on *"the other
48"* and *"behind 23 bug fixes"* — while its own summary tables, four inches
lower and recomputed on every CI run since the day they drifted, added up to
**53**. Five stale numbers on the page whose subject is numbers that go stale.

**And its first sentence named the wrong tree.** *"one annotated diff per change
against the pinned commit `6e563ee`"* — that is **fcode-utils'** pin. The
patches are against `e5ac46d`. One wrong identity, in the single document whose
job is to say what these diffs apply to, in the one place in the repo that got
it wrong.

`check-patch-hygiene.sh` gains **A8**, and it is deliberately an **absence**
rule rather than a second checked copy of the counts: the prose carries none of
them, the tables are the single place they live, and the base commit is read out
of `build-openbios.sh` rather than kept anywhere. A rule that forbids a shape
cannot silently stop matching the way a scan for a reworded sentence can. Ten
new self-controls, all watched — and the widening was not foreseen but
**forced**: the first draft scanned only the narrative *above* the series table
and missed *"the other 48"*; the second was line-anchored and missed *"behind 23
bug\nfixes"*, because markdown wraps. That is the **fourth** time in this repo a
line-anchored pattern has stood in for a question about a sentence, and this one
was caught only because the document it was aimed at happened to contain the
wrapped case.

**(c) The same count, stale in three more places**, all present-tense: *"moving
the pin means re-reading 30 patches"* in the lab README, in
[`tools/openbios-pin-check.sh`](tools/openbios-pin-check.sh)'s header, and in
§0.6's own text here. All three now say *"every patch in `patches/`"* — the
number was never doing any work. `MANUAL_TESTING.md` also billed
`openbios-check-reproducible.sh` as *"four container builds"*; it is five, the
fifth being the negative control that was added after the sentence was written.

**(d) What was deliberately left alone**, so it is not rediscovered as a defect:
[`REVIEW-preboot-forth-as-a-poke-engine.md`](REVIEW-preboot-forth-as-a-poke-engine.md)
says *"this repo's 48 patches"* in a **Repo state** table stamped `fc02a0b`. That
is a record bound to a commit, and it was true at that commit. A dated record
that names its subject is exactly what a cache is not. §17.7's UNKNOWN belongs
to §15, which is its home.


---

## 18. `openbios-unix`: FIXED (2026-08-30)

Found by verifying [`MANUAL_TESTING.md`](examples/openbios-the-rival-that-shipped/MANUAL_TESTING.md)
§5 rather than reading it. The documented invocation does not work:

```console
$ printf '3 4 + .\nbye\n' | obj-amd64/openbios-unix obj-amd64/openbios-unix.dict
encode-int: value does not fit in the 4 bytes 1275 encodes an integer into
$ echo $?
0
```

**Two separate things, and only the second is a defect.**

### (a) The refusal is CORRECT. Do not weaken it.

It looks at first like patch 26 mis-scoped its gate into `l!-be`, a general
4-byte big-endian store whose callers now include `dsl/struct.fth`. Measured
instead: **all five trips come through `int!`** — the 1275 property encoder —
and never through a raw `l!-be`. What is being encoded is an ihandle
(`forth/admin/iocontrol.fs:42,76` write `/chosen`'s `stdin`/`stdout`), and on
this target an ihandle is a **raw 64-bit host pointer** — `0x76fb51003650` in
one run — because `include/kernel/stack.h:35` defines `pointer2cell` as a plain
cast when the target cell is as wide as the host's. [Patch
48](examples/openbios-the-rival-that-shipped/patches/48-todo-17-5-cause-2-bootstrap-baked-host-pointers.patch)
records the same asymmetry from the other side: at *narrower* widths `cross.h`
subtracts `base_address`, which is why `arch/x86` never showed it.

A host pointer cannot survive four bytes. Before patch 26 this target "worked"
by silently truncating them to their low 32 bits — the LIED rung — which is the
era §5's old transcript came from. Patch 26 turned that into an honest halt.

### (b) CLOSED 2026-08-30 — the exit status is a report now, not a constant

`arch/unix/unix.c` returned 0 unconditionally after `enterforth()`, so a
bootstrap that aborted and one that ran to completion were indistinguishable to
the shell. A false success outranks an honest failure, which is why this was the
part worth fixing.

**Three obvious signals were measured and all three fail to discriminate** —
kept, because they are why the fix is not a one-liner:

| signal | abort case | clean case |
|---|---|---|
| `enterforth()`'s return (`rstackcnt != tmp`) | `0` | `0` — `throw` with no catch frame unwinds to depth 0, so the return stack balances |
| `interruptforth & FORTH_INTSTAT_STOP` | `0` | `0` — it marks input EOF, not how the session ended |
| `exception()` (`kernel/bootstrap.c:605`) | never called | never called — it serves the dictionary-BUILD path, not a prebuilt dict at runtime |

**The reason all three fail is one fact**, and `start.fs`'s own comment names it:
`initialize-of` *"is never left unless something goes really wrong or the user
decides to leave the engine"*. Both exits unwind **identically** — `bye` ends in
`0 rdepth!`, and an uncaught `throw` ends in `catchframe @ rdepth!` where
`catchframe` is `0`. The same store. So there is nothing to detect *about the
abort*; the discriminator has to be on the path that is DELIBERATE.

[Patch 51](examples/openbios-the-rival-that-shipped/patches/51-unix-exit-status-reports-the-forth.patch)
does exactly that: `bye` sets `of-left-cleanly`, and `arch/unix` reads it through
**`feval()`** — the shipped C-to-Forth call — rather than reaching into the
dictionary at a guessed offset. Measured both ways:

    clean session ending in bye ....... exit 0, no diagnostic
    init aborts (arena above 4 GiB) ... exit 1, "the Forth engine was left
                                        WITHOUT `bye` -- initialisation did
                                        not complete. See TODO 18(b)."

**And a missing flag is UNKNOWN, not a failure.** If `of-left-cleanly` is not in
the dictionary the C side says so by name and keeps the old status, because "I
could not check" must render as neither a pass nor a fail.

`smoke-openbios.sh unix` asserts all three states: exit 0 on the healthy run, the
absence of the abort diagnostic on it, and the absence of the UNKNOWN line.

*(Measuring this is its own trap, recorded because it nearly produced a wrong
verdict: `printf … | openbios-unix | tail` is a THREE-element pipeline, so
`PIPESTATUS[0]` is `printf`'s status and reads 0 whatever the firmware did.
Redirect to a file and read `$?`.)*

### (c) FIXED — but not the way this section first proposed

The fix written here was *"give the Unix target a base-relative `pointer2cell` at
equal widths"*. **That would have been wrong**, and the reason is worth keeping:
`Makefile.target` defines `NATIVE_BITWIDTH_EQUALS_HOST_BITWIDTH` for **every**
target, so `include/kernel/stack.h`'s plain cast is not a Unix special case — it
is what every arch uses at run time, and changing it would have altered what an
ihandle *is* on three currently-green targets to fix one.

[Patch 50](examples/openbios-the-rival-that-shipped/patches/50-unix-arena-below-4g.patch)
does the arch-local thing instead: `arch/unix/unix.c` maps the Forth arena and
the dictionary **below 4 GiB**, so this target's pointers fit in four bytes the
way every other target's always have (the QEMU firmwares live at `0x400000` and
`0x4000000`). It does not make 1275 able to hold a 64-bit pointer; it stops this
one target being the only place that asks it to. A hint is only a hint, so the
result is verified and a mapping that still lands high panics **by name** and
exits non-zero.

    0 > stdin @ u. 20004ba8  ok        \ was above 4 GiB, and refused
    0 > start-mem @ u. 20000000  ok

Covered by `smoke-openbios.sh unix`, which asserts the **property** rather than
the boot. Its control is the revert: put the arena back on the heap and the track
fails by name.

### (d) CLOSED 2026-08-30 — it was never a firmware bug; it was `free()` on an mmap'd pointer

Filed as a pre-existing out-of-bounds read in the firmware. **It is not.** It was
introduced by (c) itself and is entirely explained by one mistake: `main()` ended
with `free(memory)` / `free(dict)`, and those two allocations had just become
`mmap` regions. **glibc's `free()` reads its chunk header BELOW the pointer**, at
`p-8` — which is the whole of it.

| build | symptom | what it was |
|---|---|---|
| no slack, `free()` | `panic: segmentation violation at 1ffffff8` | the header read hits an unmapped page |
| slack, `free()` | `free(): invalid pointer` | same read, now succeeds; glibc inspects the garbage it finds |
| slack, `munmap` | clean | fixed |
| **no slack, `munmap`** | **clean** | **the control: the guard page was never needed** |

Two things I had recorded as separate bugs — the SIGSEGV and the `free(): invalid
pointer` abort — were one bug in two costumes, one page apart. The guard slack
has been removed; `free_below_4g()` is the fix and carries the explanation.

**WHAT SUSTAINED THE WRONG STORY, which is the part worth keeping.** The panic
dump prints `pc=0x3000a0a0(dict+0xa0a0)`, and I resolved that offline to a point
inside `bye` and built a narrative on it — *"the faulting PC is in `bye`, which
matches the output order"*. **That field is the firmware's Forth PC GLOBAL, not
the faulting instruction.** `bye` was merely the last Forth word to run before
`main()` returned and called `free()`. `dstackcnt=-1` is stale for the same
reason. A cached record read as though it described the present moment — the trap
this file opens with, met from the inside, and the "narrowing" it produced was
careful archaeology on a field that had nothing to do with the fault.

**The measurement that broke it open** was a gdb hardware access-watchpoint on
`memory-8` and `memory-16` in the *shipped* configuration: across a whole session
it **never fires**, and the process exits normally. A genuine pre-existing read
would still have been there. Watchpoints beat guard pages here because they
perturb nothing — the earlier `PROT_NONE` attempt changed the subject and then
hung, which is why it produced no answer.

*(For anyone probing this target in future: `openbios-unix -s` / `--segfault`
disables the firmware's own SIGSEGV handler — `arch/unix/unix.c:606` installs it
only `if (!segfault)` — so a real fault reaches gdb or a core file instead of
being printed and `exit(1)`ed. It was already shipped; I did not need to build a
probe.)*


---

## 19. `openbios-unix`: four defects from one user session (2026-08-30) — CLOSED

A user ran the firmware as a plain process, mistyped the command once, and tried
to leave with Ctrl-D. The typo was theirs; all four of these are ours, and none
had any coverage because this target had no track at all until §18.

### (a) A missing dictionary was neither named nor fatal — FIXED (patch 52)

```console
$ openbios-unix ./no-such.dict
fword: 'is-noname-cfunc' is not in the dictionary -- nothing was executed
fword: 'PREPOST-initializer' is not in the dictionary -- nothing was executed
not supported.
$ echo $?
0
```

`read_dictionary()` returns 0 when `stat()` fails and **the caller ignored the
return**, so the engine ran on with an empty dictionary and complained about
words it had never loaded — then reported success. The unreadable file was never
named. Now: `panic: cannot read the dictionary '…' -- no such file, or not
readable.`, exit 1.

### (b) End of input spun a core at 100% forever — FIXED (patch 52)

`kernel/forth.c`'s `key()` was `while (!availchar());` — a busy-wait **nothing
could interrupt**. `availchar()` answering *"no key yet"* is indistinguishable
from *"there will never be another key"*. Measured: state `R`, no wchan, 100%
CPU, indefinitely.

**It needed both halves.** The console knows end-of-input happened, so it sets
`FORTH_INTSTAT_STOP` (the flag `kernel/bootstrap.c` already used for the
dictionary path) — and the waiter has to *listen*, which is the one shared line.
Fixing the console alone changed nothing.

### (c) Every clean exit printed a failure — FIXED (patch 52)

`feval: 0 to terminate? -- threw -4`, on every healthy run. `packages/cmdline.c`
resets the stacks before that `feval` and its comment says *"Reset stack"* — but
it reset only the **return** stack, so the call ran at a negative data-stack
depth and `interpreter.fs`'s `depth 0< if -4 throw` fired. The phrase is fine;
typed at the prompt it answers ` ok`. One line does what the comment claimed.

### (d) Ctrl-D did nothing on a real terminal — FIXED (patch 53)

**And (b)'s fix was inert for the case a person actually hits.**
`init_terminal()` clears `ICANON`, so the tty never converts `^D` into
end-of-file — it arrives as the literal byte `0x04`, which the line editor
silently swallowed. Pressing Ctrl-D did *nothing*, repeatedly, which reads to a
user as input that is queued and not flushing. That is what was reported.

**A terminal and a pipe end differently, and three attempts conflated them:**

| attempt | worked for | broken for |
|---|---|---|
| set `STOP` in the console | nothing — `key()` never read the flag | everything |
| `key()` honours `STOP`, return `'\r'` at EOF | pipes | a tty: `^D` is never EOF, so wholly inert |
| treat `0x04` as EOF, `'\r'` then exit on the 2nd | pipes | a tty: stdio does not latch EOF there, so the next read BLOCKS |

The distinction, stated so it stops being re-derived: **Ctrl-D is one keystroke
and means "leave now"** — there is no second one coming. **Pipe EOF latches**, so
there the first can finish a trailing line with no newline and the second leaves.

### Why a green suite could not see any of it

Every test written for §18 drives a **pipe**, and would pass with Ctrl-D
completely inert — which is exactly what shipped in #360. `smoke-openbios.sh
unix` now drives a **real pty** (`tests/pty-ctrl-d.py`) and asserts the process
exits. Watched to bite: with the `0x04` branch removed — the state that merged —
it reports `ALIVE` and fails by name.

**The rule this cost:** *drive the client the machine actually has.* This lab
already carries `tools/drive-pty-repl.py` for precisely this reason — a socket is
not a terminal — and it did not occur to me to reach for it until a user hit the
gap.


## 20. `openbios-unix`: the firmware AUTHORS a file the host runs — CLOSED (2026-09-01)

The design notes ([`DESIGN-NOTES-preboot-forth-binary-structures.md`](DESIGN-NOTES-preboot-forth-binary-structures.md))
and their review ([`REVIEW-preboot-forth-as-a-poke-engine.md`](REVIEW-preboot-forth-as-a-poke-engine.md))
proposed a poke-like binary-structure toolkit on the preboot Forth. §G6 recorded
the honest state of it: **"the reader is still ahead of the writer."** `dsl/elf.fth`
reads and inspects an ELF; nothing could persist one. This closes that, on the
one target where a persisted file has somewhere to go — the hosted process.

### The gap was real, and measured before it was filled

`openbios-unix` could **read** a host file and **write nothing that outlives the
process**. All three seams were off:

| seam | state |
|---|---|
| `write_dictionary()` (`arch/unix/unix.c`) | `#if 0` — the read side (`read_dictionary`) is live, the write side compiled out |
| `-f` disk emulation | `open(…, O_RDONLY)`; the `blk` package has `read-blocks` and **no** `write-blocks` |
| NVRAM | `arch/unix` has **no** `arch_nvram_get/put` — only the QEMU-bootable arches do |

No `write-file`/`save-file` word existed anywhere in `forth/`, `libopenbios/`, or
the lab's `dsl/`. The QEMU targets persist NVRAM via `pmem` (an NVDIMM QEMU maps
to a host file); the hosted process has no QEMU, so nowhere to write. So a
structure `dsl/struct.fth`/`dsl/elf.fth` built in the arena evaporated at exit.

### The fix ([patch 54](examples/openbios-the-rival-that-shipped/patches/54-unix-write-file-authors-a-host-file.patch))

`bind_func("write-file", forth_write_file)` in `arch/unix`'s `arch_init()` —
**hosted-only on purpose**, not in the common `libopenbios/init.c` beside
`le-l!`, because only a hosted firmware has a host filesystem to write to.

    write-file ( data-adr data-len fname-adr fname-len -- actual-len )

It returns the bytes actually written (−1 if it never opened the file) and
**names every failure** with the path and the operation — a firmware word that
writes nothing and reports success is the silent liar this repo hunts. It cannot
carry `strerror(errno)`: `config.h` `#define`s `errno` to the firmware's own
`errno_int` (declared only `#if __APPLE__`), which host `open()`/`write()` never
touch — so it names the path instead. (Cousin of the repo's `type <cmd>`
lesson — a name resolving to something other than the binary you expect; here a
macro shadows the name.)

### The demo, and why the grader is un-fakeable

[`dsl/elf-write.fth`](examples/openbios-the-rival-that-shipped/dsl/elf-write.fth)
hand-authors a 132-byte static x86-64 ELF (exit(code)) with `le8`/`le16`/`le32`/
`le64` — the **ELFkickers teensy-ELF model**, made operational — and
`save-exit-elf` persists it. `smoke-openbios.sh file-writer` grades on a ladder
whose top rung the firmware cannot fake:

1. **the primitive** — 4 authored bytes round-trip to disk, return value == 4;
2. **execution** — the host `chmod +x`'s the file and **the kernel runs it**; the
   exit status must equal the code authored into `mov edi, imm32`. Proven for two
   distinct codes (0x7→7, 0x2a→42), so a harness that hardcoded one would fail the
   other. Watched to bite: authoring the wrong code → "exited 0, not 7"; a
   corrupt magic → the kernel refuses, "exited 126, not 7";
3. **independent decoders** — `file`, `readelf`, and **ELFkickers `elfls`** (a
   decoder that is not this repo's `dsl/elf.fth`) all read it as a valid x86-64
   ELF64 entering at the authored `0x400078`;
4. **the negative control** — an unopenable path returns −1, names itself, and
   creates nothing.

ELFkickers is vendored as the differential oracle: a minimal byte-exact subset
(`oracle/elfkickers/{elfrw,elfls,COPYING}` + provenance README, GPL-2+, commit
`0aa73da`), the rest of the kit cited not mirrored. `elfls` is a bonus row that
SKIPs cleanly with no `cc`; **execution is the load-bearing grader**.

### What it cost, worth keeping

- **The unix target reads stdin through an 80-column line editor** — a piped
  source line truncates past ~82 (measured: 81 survive, 83 cut). That is why the
  133-col `dsl/elf.fth` cannot be piped to the unix target (the QEMU tracks stage
  it via ISO + `load`), and why every line of `dsl/elf-write.fth` is ≤80.

### Natural sequel (not done)

A symmetric **`read-file`/`load-file`** host word. The unix target still cannot
read a host file back *in-firmware* — the in-firmware read-back cross-check
(author with the writer, validate with `dsl/elf.fth`'s reader in one session) is
blocked both by that and by the stdin limit above, so the read-back here is
external (elfls/readelf). A `read-file` word would also let `elftoc`-style
round-tripping happen at the prompt. Parked until a lab needs it.


## 21. Prospecting the poke-elf pickles — a claim map (2026-09-01)

Duplicated by request from `examples/openbios-the-rival-that-shipped/dsl/POKE-ELF-GLEANINGS.md`
(the canonical copy, beside the DSL it is about); if you edit one, edit both.

A second pass over **all sixteen** GNU poke ELF pickles
(<https://jemarch.net/poke-elf-1.0-manual/html_node/Pickles-Overview.html>),
read at the same commit `dsl/elf.fth` transliterates from — `ae45538`
(2024-10-15). The first pass (`REVIEW-preboot-forth-as-a-poke-engine.md` §E)
mined `elf-common.pk`/`elf-64.pk` for the type layer and the address methods.
This pass walked the rest — the config registry, the OS and machine pickles, the
whole-file types, the notes — and grades every seam for **this** project: an
OpenBIOS Forth that inspects boot images, builds device trees, hands structures
to the next stage, and (as of TODO §20) **authors** ELF files.

**The honest frame first.** Most of poke-elf is a *linker's* view of ELF —
relocation types, symbol tables, dynamic sections, section groups, and per-arch
registries of hundreds of reloc kinds (`elf-mach-aarch64.pk` is 681 lines,
`mips` 648, almost all reloc tables). A firmware that authors an `exit(N)` binary
and reads a bzImage never relocates, so that ore is real but **not ours**. The
gold is the *format-agnostic machinery* and the *boot-relevant records*. Graded
by how much digging each is worth:

## Loose gold — on the surface, cheap to pocket

- **The program-header ORDERING check.** `elf64_check_phdr` (wired as a
  whole-table field constraint: `phdr : elf64_check_phdr(phdr)`) encodes a real
  ELF invariant — `PT_INTERP` and `PT_PHDR` must appear **before** any `PT_LOAD`
  and only once. Our `?phdrs64` checks the *complementary* thing (no `PT_LOAD`
  runs past EOF) and nothing about ordering. A firmware that is about to **run**
  an image should refuse a malformed one; adding the ordering rule to `?phdrs64`
  is a handful of lines and the two checks together are the honest gate.
- **`elf_hash`** (`elf-common.pk`) — the SysV symbol-hash function, a pure ~10-line
  loop over a string. Trivially transliterated to Forth, and a clean self-contained
  primitive the moment anything touches a `.hash` section or wants a small content
  digest at the prompt. Not needed today; free to keep in the pan.

## Gems — worth breaking out the pickaxe

- **`Elf_Note` is the reusable extensible-record archetype, and we have nothing
  like it.** The type (`elf-common.pk`, deliberately class-agnostic) is a TLV:
  `namesz, descsz, type, name[namesz], pad-to-4, desc[descsz], pad-to-4`. That is
  **structurally identical** to a TPM measured-boot event-log entry, to an FDT
  `/chosen` note, and to the boot-handoff blobs `DESIGN-NOTES-...` §8 names —
  *"the same type description that builds an event-log entry also parses one
  back."* `.note.gnu.build-id` is itself an **image content hash**, which is the
  repo's own "bind the fact to its subject's identity" law wearing an ELF hat
  (cf. metal-as-a-service's `pcrs.expected`/build-id lesson). `dsl/elf.fth` only
  *names* `NOTE` as a `p_type` string; it parses no note. A Forth `note:`/`tlv:`
  layout word is the single richest vein here — it turns the type layer from an
  ELF reader into a describer of the extensible records the fleet actually hands
  around at boot.
- **The two `struct.fth` primitives the notes expose as missing.** `Elf_Note`
  needs (a) a **length-prefixed array** — `uint<8>[namesz] name`, an array whose
  count is a *prior field*, where our `array:` takes a fixed stride only — and
  (b) **`alignto(OFFSET, 4#B)`** — padding computed from the *running offset*, not
  a constant. Both are exactly the cell-width/offset hazards `DESIGN-NOTES` §3
  warns about, met head-on. They are also what it would take to describe the
  device tree's own structure block (FDT is length-prefixed, `nul`-padded,
  4-byte-aligned). Adding `vfield:`/`alignto` to `struct.fth` is the enabling
  work under the note gem.

## Panning downriver — derivative value, further from the source

- **The config registry** (`elf-config.pk`), re-assayed. Its real payoff is not
  pretty-printing but **field validity keyed by context**: `ei_class`,
  `ei_data`, and a note's `_type` are all constrained through
  `elf_config.check_enum(class, machine, value)`, so a field *refuses* a value not
  registered for the current machine. For us the machine is the wrong key — but
  the **shape** (a `{class, context, value, name}` store with `check`/`format`/
  `apropos`, decoupled from layout) maps precisely onto our one genuine
  context-parameterized decode: IEEE-1275 `#address-cells`, which is `2` on the
  amd64 root, `1` on its children and on x86 (`arch/{amd64,x86}/init.fs`; the
  amd64-port notes flag that the root's `decode-unit`/`encode-unit` **must** move
  with the count). Today we handle enum naming with hardcoded nested-`if` tables
  (`.p-type`/`.sh-type`) and the DT decode with inline per-node assumptions; a
  small context-keyed registry is the honest generalization of both.
- **The field-reconfigures-the-reader pattern.** `Elf_Ident.ei_data` doesn't just
  validate — it **sets the reader's endianness for every subsequent field**
  (`ei_data == 2LSB ? set_endian(LITTLE) : set_endian(BIG)`). We deliberately
  declined this (REVIEW §E2: per-field byte order plus an honest refusal of a
  big-endian ELF64). But the *pattern* — a field that reconfigures how its
  siblings decode — is the archetype for a DT `#address-cells` property changing
  how the cells after it are read. Borrow the pattern; don't port the ELF use.
- **`get_load_base` aligns down by `p_align`.** poke returns `min(p_vaddr &
  ~(p_align-1))` over `PT_LOAD`; our `elf64-load-base` returns the raw minimum
  `p_vaddr`. For our `vaddr>off` these agree on a normally-aligned image and
  differ on the page base. A one-line refinement to consider only if page-base
  semantics are ever wanted — noted so the divergence is deliberate, not drift.

## Left in the ground — assayed, barren for us

Symbol tables, section groups (COMDAT), the dynamic section, relocation entries,
and the per-arch reloc registries (`elf-mach-*`) are a linker/loader's concern.
This firmware authors and inspects; it does not link or relocate. `elf.fth`
already lifted the pieces that *are* ours — REVIEW §E1's constraints-that-refuse
(`?elf64`) and §E4's address methods (`vaddr>off`, `elf-load-base`), the latter
with a hard-won unsigned-comparison fix the narrow cell exposed — so those are
not re-counted here.

## What this map is for

Nothing above is scheduled. It is a **claim map**: when a future item touches
measured-boot/attestation records, FDT construction, or FCode/property naming —
all TLV- or context-keyed — the vein to work is the `Elf_Note` archetype plus the
two `struct.fth` primitives (the pickaxe), then the context-keyed registry (the
pan), not the reloc tables (the barren rock). It is the concrete form of
`DESIGN-NOTES-preboot-forth-binary-structures.md` §5's thesis — *generalize the
encode/decode wordset outward from device-tree properties to arbitrary binary
structures* — with poke-elf pointing at exactly which structures pay.

---


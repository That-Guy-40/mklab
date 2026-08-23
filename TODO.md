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

- [ ] **A.5** — **four files the micro-cloud docs promise and do not have.** Found
      2026-08-20 while fixing two of them, and the interesting part is *why nobody noticed*.
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

- [ ] **C.1 — metal-as-a-service `image` / `image+measured` drivers on REAL hardware.**
      Detail in [`examples/metal-as-a-service/DEFERRED.md`](examples/metal-as-a-service/DEFERRED.md).
      Everything that can be proven under emulation has been; what remains needs a machine
      with a real BMC, and no amount of local work advances it.
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

- [ ] **11.4a** — the 79 unprobed rows and the 14 bare-name warnings are the remaining tail.
      Neither is closable by tightening a regex: the first needs a safe way to ask a
      build/smoke script what verbs it has without running one, and the second needs the
      document to say which it meant.

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

*Created 2026-06-06; #5–#6 added 2026-06-11; #7 added 2026-06-11; #8 added
2026-08-03; #9 added 2026-08-06; #10 added 2026-08-06; #11 added 2026-08-21;
#11.1 and #11.2a closed 2026-08-22.*

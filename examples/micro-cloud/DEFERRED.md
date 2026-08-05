# Micro-Cloud Lab — deferred work

> Moved here from [`MICRO_CLOUD_LAB_PLAN.md`](../../MICRO_CLOUD_LAB_PLAN.md)
> §17 on 2026-08-03 — exactly as that section's own note said it would, once
> this directory existed. The **§17.x numbering is preserved** because the
> plan's appendices cite it (§17.3, §17.4); all other bare §n references below
> point into the plan. The original §17 was written 2026-07-29 at the end of
> the planning session that produced v2 and v3; the DONE markers were added as
> the slices landed.

## NEXT — slice 5a: a second engine on one fabric

*Added 2026-08-05, when §18.6 items 1–5 landed and this became the front of the
queue. Numbered outside the §17.x sequence on purpose: that numbering is cited by
the plan's appendices (§17.3, §17.4) and must not shift.*

**The question.** Plan [decision E](../../MICRO_CLOUD_LAB_PLAN.md#83-the-unsolved-half--one-seam-or-four):
is the control-plane seam one vocabulary or four? It is answered with two engines
actually running, not with two imagined ones — and the evidence table is
[§18.4](../../MICRO_CLOUD_LAB_PLAN.md#184-what-slice-5-must-answer).

**The shape.** QEMU `-M microvm` boots **the same `vmlinux` and the same `.ext4`**
Firecracker boots, on a `fabric.sh`-made tap, so the only variable is the VMM
([§18.3](../../MICRO_CLOUD_LAB_PLAN.md#183-two-corrections-to-14s-one-line-brief)).

### Everything it consumes exists and is verified

| input | where | state |
|---|---|---|
| `fabric.sh` (`up`/`tap`/`status`/`down`) | [`fabric.sh`](fabric.sh) | committed; round trip re-verified 2026-08-04 ([I.7](../../MICRO_CLOUD_LAB_PLAN.md#i7-the-recovered-fabric-re-verified-against-the-moved-binding--pass)) |
| `lab-fc.sh` + preflight | [`phase7-firecracker/`](../../phase7-firecracker/lab-fc.sh) | slice 4; baseline **0.564930 s** |
| `-M microvm`, virtio-mmio, qboot | [`phase2-qemu-vm/`](../../phase2-qemu-vm/lab-vm.sh) | pre-existing; `test-microvm-argv.sh` |
| `--network-mode tap` | same | takes a **pre-made tap by name** — what `fabric.sh tap` produces and how FC consumes one. Unprivileged in both |
| `--disk-format raw` | same | PR #137; attaches a **per-instance copy**, not a CoW overlay, so the storage stack matches FC's |
| `vmlinux`, `api1.ext4` | `~/.local/state/lab-create/micro-cloud-s3/` | survived the /tmp reap |

**De-risked 2026-08-05, and it was the assumption most likely to sink the slice:**
QEMU's `-kernel` normally wants a bzImage, while Firecracker is ELF-only. Measured —
`-M microvm` **does** load the same ELF `vmlinux`, reaching `VFS: Cannot open root
device` at **0.048 s** and rebooting, which is `panic=1` behaving exactly as
[E.3](../../MICRO_CLOUD_LAB_PLAN.md#e3-the-panic1-hole-closed-by-watching-it)
measured for FC. The kernel half of "the same kernel" is therefore real, not hoped
for. What remains unverified is the guest finding its root disk on the **mmio** bus.

### Split by privilege — the headline half needs nothing from the operator

**(a) Unprivileged: the number nobody has.** No fabric, no tap, no network — boot
QEMU `-M microvm` on the same kernel and a per-instance copy of the same rootfs and
time it against FC's 0.564930 s. `/dev/kvm` is already r+w for uid 1000 (P1). This
is the measurement the plan's density argument has been *one sample wide* on since
slice 1.

**(b) Author-run: the fabric half.** `fabric.sh up`, one tap per engine, both VMMs
on `br-mc0` at once, name resolution across engines, then `down` with its Calico
comparison. Needs `CAP_NET_ADMIN`, so it ships as a one-shot script the way
[I.7](../../MICRO_CLOUD_LAB_PLAN.md#i7-the-recovered-fabric-re-verified-against-the-moved-binding--pass)'s
re-run did.

### Confounds to control, or the comparison proves nothing

- **`root=` is not symmetric.** [E.4](../../MICRO_CLOUD_LAB_PLAN.md#e4-two-findings-the-plan-did-not-anticipate)
  found Firecracker *appends* `root=/dev/vda rw` after the user's `boot_args`; QEMU
  appends nothing, so slice 5a must **supply** it. The same spec cannot serve both
  verbatim — and that asymmetry is itself decision-E evidence, not an annoyance.
- **Same bytes, not "a similar Alpine."** Both engines get a per-instance copy of
  one `.ext4`; that is why `--disk-format raw` copies rather than overlays.
- **Same accel.** KVM on both, or the comparison measures TCG.
- **Report the spread, not one run.** Slice 1 established FC's 0.55 s with *zero
  variance over four runs*; a single QEMU sample is not comparable to that.
- **State what is NOT held constant** — device model, firmware (qboot vs none),
  and the VMM's own startup are all inside "the VMM", which is the point, but the
  number means nothing if the reader thinks it isolates one of them.

### Break pass

Kill one engine's process and see what the other reports; delete the bridge under
both (slice 3 graded this **HALTED (honest)** with one VMM —
[G.8](../../MICRO_CLOUD_LAB_PLAN.md#g8-deleting-the-bridge-under-a-running-microvm--halted-honest-and-one-surprise));
and the §7.2 teardown comparison, which now matters more than it did: the tunnel
sits on the **physical uplink** and autodetection re-runs every **60 seconds**
([I.3](../../MICRO_CLOUD_LAB_PLAN.md#i3-the-hazard-did-not-go-away--it-got-worse),
[I.4](../../MICRO_CLOUD_LAB_PLAN.md#i4-the-finding-that-outlives-the-migration--autodetection-is-a-60-second-poll)),
so a two-VMM run is exposed for its whole duration.

### Done looks like

A boot-time number with its spread beside FC's 0.564930 s; both engines on
`br-mc0` resolving each other by name; `down` reporting Calico unchanged; the
§18.4 seam table filled in from what the two lifecycles actually needed; and a
dated appendix. **`retap`, and the slice-3 exercise itself, are still unre-run** —
5a is where that debt is paid.

---

## 17.0 First thing now: commit the slice artifacts — `fabric.sh` above all

*Added 2026-08-03, when this file was created.*

> ✅ **Item 1 DONE 2026-08-04 — and this section's own premise was wrong.**
> `fabric.sh` was **not** in `micro-cloud-s3/`. That workdir holds `api1.ext4`,
> `api2.ext4`, `vmlinux`, `firecracker`, the boot logs and the `config-*.json`
> variants — **and no `.sh` files at all**. The scripts lived in a `/tmp`
> session scratchpad that had already been reaped, so the "operator action"
> below could never have succeeded as written: it named a location nobody
> re-checked between writing the instruction and following it.
>
> The only surviving copy was the session transcript. Recovered from it by
> replaying one `Write` and eleven `Edit`s, each operation's `tool_result`
> checked for `is_error` and each `old_string` asserted unique before replacing
> — 420 lines, shellcheck-clean, now committed as [`fabric.sh`](fabric.sh).
> Full account: [plan §18.1](../../MICRO_CLOUD_LAB_PLAN.md#181-the-precursor-nobody-recorded--fabricsh-is-not-in-the-repo).
>
> ✅ **Re-verified 2026-08-04 23:39 — the privileged round trip PASSES.**
> `up` → `tap api1` → `tap api2` → `status` → `down`, author-run. Teardown's
> Calico comparison matched the **new** binding, which pre-flight had recorded
> by deriving it — a copy with `incusbr0` written in would have failed on a
> host where nothing was wrong. See
> [I.7](../../MICRO_CLOUD_LAB_PLAN.md#i7-the-recovered-fabric-re-verified-against-the-moved-binding--pass).
>
> **Still not proven, and named rather than left implicit:** `retap` was never
> called, **no microVM booted** (dnsmasq started and re-read its files but
> served nobody), and the comparison's negative direction was not re-run. The
> fabric is re-verified; **the slice-3 exercise is not.** Slice 5a re-runs it
> with a second engine attached.
>
> **Item 2 (the slice 1/2 artifacts) stands** — those files really are in the
> workdirs, verified 2026-08-04.

Slice 3's deliverable — `fabric.sh` (`up` / `tap` / `retap` / `status` /
`down`) — and the slice 1/2 workdir artifacts (configs, boot logs, inittab
markers) exist **only** under `~/.local/state/lab-create/micro-cloud-s{1,2,3}/`
on the mklab host. Nothing in any clone of this repository contains them.

That is the plan's own bug class #1, committed by the plan:
[Appendix G](../../MICRO_CLOUD_LAB_PLAN.md#appendix-g--slice-3-the-fabric-2026-08-02)
is a committed **record** whose **subject** is an unversioned file in a state
directory — one that `tools/lab-sweep.sh` has already cleaned once
([G.6](../../MICRO_CLOUD_LAB_PLAN.md#g6-a-hazard-our-own-cleanup-armed): the
sweep that emptied `incusbr0` ran the same morning as slice 3). Appendix E's
"every number can be re-derived" holds only while those files survive.

**Operator action** — the files are on the host, so no agent clone can do it:

1. Commit `micro-cloud-s3/fabric.sh` here as `fabric.sh` (the measured file,
   byte-exact — see the README's warning against reimplementing it from the
   appendix).
2. Commit whatever of `micro-cloud-s1/` and `micro-cloud-s2/` makes Appendices
   E and F re-derivable — the Firecracker `config.json` variants, the boot-log
   excerpts, the probe scripts. Not the images (`.gitignore`'d under `images/`
   per the §9.1 layout).
3. Then slice 5 ("a second engine on **one fabric**") has a fabric that exists
   somewhere durable.

### 17.1 First thing: spike P2 — the privileged half (AUTHOR-RUN) — **DONE 2026-07-30**

> **Result: [Appendix B](../../MICRO_CLOUD_LAB_PLAN.md#appendix-b--p2-assumption-preflight-2026-07-30).**
> 11 PASS · 0 FAIL · 1 XFAIL · 0 UNKNOWN, rc=0 — all four checks green, all
> three of P1's `UNKNOWN` rows resolved, and both missing inputs now on disk
> (`mc-p2-trixie`, 215 MB; `firecracker v1.16.1` + `jailer`). It also
> **falsified §7.1 consequence 2** and produced one honest new `UNKNOWN` —
> where Calico's dataplane actually lives. **Slice 1 is unblocked.** The rest
> of this subsection is the original brief, kept as written.

P1 (Appendix A) checked everything reachable without privilege. **P2 resolves
its three `UNKNOWN` rows and flips its two "expected gap" rows that are merely
missing inputs.** It is sudo-gated and involves a fetch, so it is a hand-off,
not an agent task — the agent's runner gates fetch-then-execute of prebuilt
binaries.

Four checks, in dependency order:

| # | check | why it must be P2 | what it unblocks |
|---|---|---|---|
| 1 | **`nft list tables`** — who owns the firewall next to Calico | needs root | §7's "additive, separately named table" plan is currently an *intention*; this makes it a design against a known ruleset |
| 2 | **`debootstrap` one small chroot** | needs root | P1's negative control (*no chroot exists*) is slice 1's missing input. Nothing in §2's matrix can be exercised without a tree |
| 3 | **create + delete one tap on a throwaway bridge** | needs `CAP_NET_ADMIN` | proves the fabric's primitive **without building the fabric** — the cheapest possible de-risk of §7 |
| 4 | **fetch `firecracker-v1.16.1-x86_64.tgz`, verify against upstream's `.sha256.txt`** | fetch+exec gate | slice 1 cannot start without the binary. P1 confirmed the asset **and** the published hash exist |

Then, on the same run: **`firecracker --version`, and one no-op boot attempt**,
because Firecracker's own testing skews Intel and this host is **AMD-V
(`svm`)**. "It runs on this CPU" is an outcome nobody has observed yet.

Deliverable: P1's table re-printed with 0 `UNKNOWN`, plus a one-line note per
row that changed. The write-up belongs in Appendix A as a second dated column,
**not** as an edit to the first — the point of a dated measurement is that it
stays a record of what was true then.

### 17.2 Then slice 1 — one microVM, by hand — **DONE 2026-08-01**

Per §14. What makes it the right next build step is not that it is first on a
list, but that it **converts three arguments into observations**:

- **Decision B** (§6.3c): does `extract-vmlinux` on a Debian `bzImage` actually
  boot under FC? P1 could not even find the script — it ships inside the
  kernel source tree.
- **Decision F**: Alpine vs Debian. Build both; the size and boot-time delta
  *is* the answer, and it decides whether "spawn twelve" is real.
- **§5.4's first hole**: drop `panic=1` and **watch the VM hang forever**.
  Until somebody sees that, the config assertion guards a string rather than a
  behaviour.

> **All three converted, and the slice paid for itself twice over — see
> [Appendix E](../../MICRO_CLOUD_LAB_PLAN.md#appendix-e--slice-1-one-microvm-by-hand-2026-08-01).**
>
> - **B = yes.** The host's own kernel, extracted, boots FC in 0.62 s against
>   the purpose-built CI kernel's 0.55 s. Micro-cloud need not ship or fetch a
>   kernel.
> - **F = the question was mis-framed.** 26× the size, *identical* boot time
>   (0.55 s, zero variance, 4 runs each). Alpine-vs-Debian is a **footprint**
>   decision, not a speed one.
> - **§5.4 hole 1 = observed.** 1.63 s clean exit with `panic=1`; hung until
>   killed without.
>
> And **two holes nobody had named** (§5.4 holes 3–4): Firecracker appends its
> own boot args so a user `root=` is silently ignored, and a stray `ip=` costs
> 12.3 s in total silence. The first was found *because* the `panic=1`
> experiment showed no difference and the fault was checked rather than the
> result believed.

### 17.3 The one test I cannot run from this side — **HALF DONE 2026-08-01**

**§16 question 5.** A real beginner walking one `START_HERE_*_WIZARD.md` end to
end.

I verified that all 18 verbs cited across phases 1/2/5 still exist in their
tools. That is **verb existence, not walkthrough success** — the same
mechanism-vs-outcome gap this plan is organised around, and I cannot close it
by reading more carefully. It needs somebody who does not already know the
answer.

It is worth doing **before** slice 1 rather than at slice 9, for a reason that
is easy to get backwards: the novice path is the part most likely to be quietly
broken, because nobody who can fix it has needed it in a long time. Cost: a
friend, an afternoon, and a willingness to hear that the docs lie.

> **The machine-checkable half is now done, and the prediction was right.**
> [`tools/wizard-walkthrough.sh`](../../tools/wizard-walkthrough.sh) executes
> every instruction the five wizards give instead of reading them. First run:
> **8 PASS · 4 FAIL · 1 XFAIL · 1 UNKNOWN**, two of the failures blocking a
> beginner outright — including a launch command that **had never worked in
> the entire history of the repository**. Full table and fixes in
> [Appendix C](../../MICRO_CLOUD_LAB_PLAN.md#appendix-c--the-novice-on-ramp-walked-by-machine-2026-08-01).
>
> **This does not close §17.3, and the harness says so on every run.** It
> carries a standing `UNKNOWN` row — *"a beginner who does not know the answer
> got through it"* — that is structurally incapable of becoming `PASS`. A
> script can prove a command exits non-zero. It cannot notice that step 3
> assumes knowledge the reader does not have, that the prose says "the wizard
> writes a TOML" without saying where, or that a novice who hits `EADDRINUSE`
> has no idea what to do next. **Do not let a green run retire this item.**
> The friend and the afternoon are still owed.

### 17.4 Open questions

Carried from §16, unchanged:

1. **Where to stop.** Slices 2, 4, 6, or 7 are all honest stopping points.
2. **Decision E — the seam** (§8.3). Recommendation: defer to slice 5; slice 4
   carries the tripwire.
3. **Decision G — MAAS registry reuse** (§8.4). Recommendation: invoke for
   deploy drivers, separate registry initially, revisit at slice 6.
4. **Decision B — `extract-vmlinux`** (§6.3c). An experiment for slice 1.
5. **The beginner walkthrough** — §17.3.

New, surfaced while writing v3 and not yet decided:

6. **Where does the P1 spike finally live?** It is now kept at
   [`tools/micro-cloud-preflight.sh`](../../tools/micro-cloud-preflight.sh) — a
   **provisional** home, chosen so the instrument that produced Appendix A
   survives the session that wrote it. *A measurement whose harness is gone
   cannot be re-run, and an un-re-runnable measurement quietly becomes a belief
   again.* Re-run it any time with `tools/micro-cloud-preflight.sh` (exit 0 =
   no unexpected slice-1 blockers; exit 1 = a blocker **or** no `XFAIL`
   fired). Still to decide: (a) leave it in `tools/`; (b) move it to
   `examples/micro-cloud/tests/test-assumptions.sh` so drift is caught by the
   suite; (c) let it seed `lab-fc.sh preflight` (§5.9), whose host-capability
   gates are mostly these checks. **(c) is probably right, but only at slice
   4** — before then there is no tool for it to be part of. Until then it is a
   spike that was kept, not shipped tooling, and its header says so.

   > **DUE NOW — slice 4 is done, and the count has grown to four.** `tools/`
   > holds `micro-cloud-preflight.sh` (P1), `-p2.sh` (P2) and
   > `-fabric-probe.sh` (slice 3), and `lab-fc.sh preflight` is a fourth
   > implementation of overlapping host-capability gates. **Four instruments
   > that can disagree about the same host is this plan's own bug class**, and
   > the disagreement would surface as a slice refusing for a reason another
   > tool says is fine. Answer **(c)**, scheduled at
   > [plan §18.6](../../MICRO_CLOUD_LAB_PLAN.md#186-order-of-work) item 4: one
   > gate implementation, the others reduced to callers, asserted structurally
   > the way `phase7-firecracker/tests/test-preflight-is-one-function.sh`
   > already does for `create` vs `preflight`. The **dated spikes stay
   > runnable** — a measurement whose harness is gone becomes a belief again,
   > which is this entry's own original argument.
   >
   > ✅ **CLOSED 2026-08-05 — and the fold was the wrong fix.** The premise was
   > measured before acting on it: run side by side, the instruments **agree**
   > about `/dev/kvm`, about firecracker's pinned version, and about ext4
   > read-back (lab-fc's `UNKNOWN` on a dirty image is H.4's fix working, not a
   > disagreement). Exactly one disagreement was real and it was a **cached
   > string**, not a divergent implementation: P1 printed `vxlan.calico over
   > lxdbr0` — a literal beside a derived process count, wrong since 2026-08-01
   > and doubly wrong since Appendix I. The fabric probe had the same defect in
   > a hard-coded bridge list that was reporting *"0 nft rules"* for two
   > interfaces that no longer existed. Both now derive. The rule — *the
   > appendix is the record and is immutable; the instrument is code and must be
   > true when it runs* — is enforced by
   > [`tools/tests/test-no-cached-host-facts.sh`](../../tools/tests/test-no-cached-host-facts.sh),
   > which carries its own negative control and is gated in CI. Full account:
   > [plan §18.7](../../MICRO_CLOUD_LAB_PLAN.md#187-item-4s-premise-tested-the-four-instruments-agree--and-one-of-them-was-lying).
7. **How does the fabric *record* what it changed?** §7.1 says teardown must
   revert only what `up` set (because `ip_forward` was already `1` and a live
   Kubernetes depends on it). That needs a mechanism — a statefile in the
   fabric's state dir naming each global it touched and the prior value.
   Small, but it is load-bearing and currently unspecified.

   > **CLOSED 2026-08-04.** It was answered in code on 2026-08-02 and the
   > document did not know, because the code was not in the repository —
   > §17.0's subject exactly. [`fabric.sh`](fabric.sh) writes
   > `/run/mklab-mc/preflight`: the recorded `ip_forward` (and whether *we* set
   > it), the uplink, Calico's binding, the pod veth count, the whole
   > autodetection candidate set, and the pre-change FORWARD surface from
   > **both** netfilter backends. `down` reverts only what that file says we
   > created and compares the rest. See
   > [G.7](../../MICRO_CLOUD_LAB_PLAN.md#g7-the-teardown-assertion-proven-in-both-directions).
8. ~~**`incus` or `lxc`?**~~ — **SETTLED 2026-08-01: `lxc` (LXD), pinned
   explicitly.** See
   [D.1](../../MICRO_CLOUD_LAB_PLAN.md#d1-the-correction--the-vxlan-underlay-is-incusbr0-and-the-empty-daemon-is-the-load-bearing-one).
   They are genuinely separate installs (snap LXD 5.21.5 vs deb Incus 7.2),
   and the premise in the original question — that LXD hosts the Kubernetes —
   was **false**. The decisive fact is the opposite one: **Calico's VXLAN
   tunnel endpoint lives on `incusbr0`** (`local 10.45.178.1 dev incusbr0`),
   while `lxdbr0` carries nothing but this repo's own leftover test container.
   **Pin it**, do not let `probe_engine` choose: `lab-lxd.sh` prefers Incus
   whenever its daemon answers, so the default is the engine we least want to
   disturb.

   > ⚠️ **REVERSED 2026-08-01, later the same day —
   > [F.8](../../MICRO_CLOUD_LAB_PLAN.md#f8-lxdbr0-is-a-candidate-and-it-outranks-the-one-calico-chose).**
   > This answer was reasoned from *what rides on each bridge*, which was right
   > as far as it went and was not the deciding factor. **`lxdbr0` is an
   > autodetection candidate at index 9; `incusbr0` is one at index 17.**
   > `^lxcbr.*` does not match `lxdbr0`. So bringing `lxdbr0` **up** — which is
   > exactly what targeting LXD does — inserts a *lower-index* candidate ahead
   > of the interface Calico currently uses, and the next `calico-node`
   > restart can migrate the cluster's node IP to `10.216.67.1`.
   >
   > **Revised answer: target `incus`, pinned.** Not because Incus is better,
   > but because `incusbr0` is *already* the chosen interface, so using it
   > changes nothing. The rule generalises past this host: **prefer the engine
   > whose bridge the CNI has already selected, because that is the one choice
   > guaranteed not to move it.**
9. ~~**Does `db` on LXD still make sense (§9.2)?**~~ — **DISSOLVED
   2026-08-01.** The question existed only because LXD was believed to be
   "running someone else's cluster." It is not. `db` on LXD is the *safe*
   placement, and it is now pinned in §9.2. The coexistence lesson the
   question was reaching for is still real — it just lives somewhere else:
   **microk8s on the host**, whose Calico dataplane is 140 rules in legacy
   xtables ([B.2](../../MICRO_CLOUD_LAB_PLAN.md#b2-the-second-firewall--and-the-bug-p2-committed-while-hunting-it))
   and whose tunnel endpoint is on a container-engine bridge nobody put it on
   deliberately.
10. **How do the web wizards share code with the TUI's?** (§8.2's gap.) If the
    web port reimplements `generate_toml()`, there are **two spec generators
    that can disagree** — this repo's signature bug, in a place a novice would
    meet it first. The port should share the generator and re-implement only
    the *view*. Needs confirming against `wizards/base.py`'s actual split
    before any work starts.
11. **Which Ubuntu release, and does autoinstall need a different netboot
    path?** (§11.1's first gap.) `debian-pxe-lab`'s preseed chain may or may
    not carry over to subiquity's `autoinstall.yaml` + cloud-init datasource
    model.
12. **Clonezilla-style capture: `partclone`, `ddrescue`, or plain `dd`?**
    (§11.1's second gap.) And where does it sit relative to §9.5's tier 1 — is
    whole-disk capture a third preserve tier, or tier 1 for machines rather
    than instances?
13. **`preserve` for a chroot itself.** A chroot is already a tree, so tier 2
    is presumably "tarball + `derivation.toml`" and tier 1 does not exist for
    it. Probably trivial; worth one line so it is not an accidental gap.

### 17.5 One loose thread that is not this plan's

The **CI shell-suite failure** seen on `2018985` (2026-07-30). Proven
environmental by the correct control — *same commit, no changes, re-run
passed* (fail at 59s, pass at 2m13s) — but the cause is **unidentified**,
because `gh run view --log` returned empty for the failed job and the output
was never captured. It is the first such failure *after* #113's `crun` SKIP
guard landed, where the three before it were the `crun` era.

**Action if it recurs: capture the log while it is still retrievable**, before
re-running. One data point is not a trend, and a re-run destroys the evidence
that would make it one.

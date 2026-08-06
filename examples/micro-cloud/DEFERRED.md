# Micro-Cloud Lab — deferred work

> Moved here from [`MICRO_CLOUD_LAB_PLAN.md`](../../MICRO_CLOUD_LAB_PLAN.md)
> §17 on 2026-08-03 — exactly as that section's own note said it would, once
> this directory existed. The **§17.x numbering is preserved** because the
> plan's appendices cite it (§17.3, §17.4); all other bare §n references below
> point into the plan. The original §17 was written 2026-07-29 at the end of
> the planning session that produced v2 and v3; the DONE markers were added as
> the slices landed.

## DONE — slice 5a, both halves

> ✅ **(b) landed 2026-08-05, the same day as (a)** — [Appendix K](../../MICRO_CLOUD_LAB_PLAN.md#appendix-k--slice-5a-b-two-engines-on-one-fabric-and-decision-e-answered-from-what-the-lifecycles-actually-needed-2026-08-05).
> `sudo bash tests/run-all.sh` → **3 passed · 0 skipped · 0 failed**. Firecracker and
> QEMU `-M microvm` on two `fabric.sh` taps, **both dropped to uid 1000**, distinct
> DHCP leases from one dnsmasq (`10.71.0.101` / `10.71.0.102`), and **each engine's
> guest resolved the other's by name**. Calico's binding, pod veth count and
> `ip_forward` unchanged throughout.
>
> **Decision E is answered: §8.3 shape (b)** ([K.2](../../MICRO_CLOUD_LAB_PLAN.md#k2-decision-e-answered--184s-table-filled-in-from-what-the-two-lifecycles-needed)). The intersection is
> `create`/`start`/`stop`/`status`/`destroy`; every difference is in the **channel or
> the artifact**, with one exception — Firecracker owns `root=` and QEMU does not.
>
> **Still open** ([K.5](../../MICRO_CLOUD_LAB_PLAN.md#k5-what-slice-5a-leaves-closed-and-what-it-does-not)): `retap` is *still* never called (it needs a
> deliberately root-owned tap to recover from), G.9's two break-pass scenarios are unrun,
> and **slice 5b** — the fidelity case — has not started.
>
> ⚠️ **Correction 2026-08-06** — this line said G.9's scenarios "want a host without a
> live cluster". That was **already wrong when it was written**: G.9's own addendum
> (2026-08-03) says a **nested QEMU guest running a disposable microk8s is** such a host.
> And the two scenarios never shared a blocker — **DHCP exhaustion needs no cluster at
> all**, only a shrinkable range, and could run on this host today behind a two-line
> change to `fabric.sh`. Full account:
> [M.7](../../MICRO_CLOUD_LAB_PLAN.md#m7-a-correction-this-appendix-inherited-the-g9-blocker-was-lifted-three-days-before-it-was-restated).
>
> ---
>
> ✅ **(a), earlier the same day** — the unprivileged boot comparison, four arms,
> [Appendix J](../../MICRO_CLOUD_LAB_PLAN.md#appendix-j--slice-5a-a-the-second-engine-the-number-nobody-had-and-the-number-everybody-had-was-wrong-2026-08-05).
> It answered §18.3's *"nobody has the other number"* and **corrected the number
> everybody did have**: 0.512 s of Firecracker's 0.567 s is a kernel **i8042 probe**
> ([J.3](../../MICRO_CLOUD_LAB_PLAN.md#j3-the-headline-that-was-false)), so the honest tuned figure is **0.055 s** — and Firecracker, not
> QEMU, is the faster of the two once both are on equal footing
> ([J.5](../../MICRO_CLOUD_LAB_PLAN.md#j5-the-answer-once-both-engines-are-on-equal-footing)). (b) re-derived it from the guests' own clocks
> ([K.3](../../MICRO_CLOUD_LAB_PLAN.md#k3-the-seams-are-not-independent-of-the-performance-story)).

## DONE — slice 5b: the fidelity case

> ✅ **2026-08-06 — the whole micro-cloud suite is green at root: 5 passed, 0 skipped,
> 0 failed** ([Appendix M](../../MICRO_CLOUD_LAB_PLAN.md#appendix-m--slice-5b-the-fidelity-case-joins-the-fabric-2026-08-06)). A stock Debian 12 cloud image on `-M q35` booted on a
> `fabric.sh` tap beside a Firecracker microVM, took its **RESERVED** lease
> `10.71.0.102` — the MAC from a static spec file reached the guest — and reached
> `api1` **by name** across the fidelity gap. Calico's binding, pod veth count and
> `ip_forward` unchanged throughout.
>
> **Seven defects on the way, every one in the harness or a phase tool, none in the
> lab.** Two were real tool bugs a green suite could never have seen: `lab-vm.sh
> inspect` exited 1 with **no output at all** for every running VM (a running QEMU
> locks its own disk), and a `: ` in a `runcmd` made cloud-init parse a **mapping**
> instead of a command, so a perfectly-booted VM silently ignored every instruction it
> was given.

## DONE — the DHCP-exhaustion half of G.9's break pass

> ✅ **2026-08-06** — [M.8](../../MICRO_CLOUD_LAB_PLAN.md#m8-the-cheaper-half-of-g9-built--and-the-defect-the-knob-uncovered-2026-08-06).
> The pool is `MC_DHCP_LO`/`MC_DHCP_HI`, and
> [`tests/test-dhcp-exhaustion.sh`](tests/run-all.sh) fills a five-address one in seconds.
> ✅ **GREEN at root 2026-08-06, on the second run. Slice 3's break coverage is now 4 of 5.**
> The first run passed 8 of 9, and the 9th failure was **the fabric being right about the
> harness**: `down` refused to call teardown clean while three of this test's own veths were
> still on the bridge. Chasing that found the worse bug — `dhcp_ask` was called in a command
> substitution, so its `CLIENTS+=` bookkeeping went to a subshell and the EXIT trap reaped
> nothing. Both fixed, and the re-run passed every assertion including the new
> `clients reaped before teardown` guard that the failure paid for.
>
> **The knob uncovered a latent defect**, which is the part worth keeping: reservations
> were computed as `10.71.0.$((100 + IDX))` with the base hard-coded, so any pool not
> starting at `.100` would have marched them **outside the range** — addresses dnsmasq is
> never told to serve — while `tap` created the tap anyway. Harmless while one constant
> matched another; armed the moment anyone used the new knob. It now derives from
> `DHCP_LO`, and overflow is refused **by name, before the tap exists**.
>
> The load-bearing assertion is the **inverse of slice 5b's**: with the dynamic pool empty,
> a **reserved** instance must still get **its own** address (ABSORBED), while an
> unreserved client at the same instant gets nothing (HALTED). The second is the first's
> negative control, from the same exhausted state — without it, "the reserved client got an
> address" cannot be told apart from "the pool was never full."
>
> Fake guests are veth pairs whose far end lives in its own netns, so the leased IPv4 never
> appears on a host interface and Calico's 60-second autodetection poll cannot see it —
> F.7.1 rule 2 satisfied *by construction*, and asserted afterwards rather than assumed.

## The original brief — slice 5b: the fidelity case

*The §9.2 `edge`: a full cloud image on `-M q35` with cloud-init, on the same fabric,
reaching `api1` by name — the counterpart to 5a's density case.*

> ⚠️ **Its first finding landed before any of it was built** — [Appendix L](../../MICRO_CLOUD_LAB_PLAN.md#appendix-l--slice-5bs-first-finding-before-a-line-of-it-was-built-the-two-tools-could-never-agree-2026-08-05).
> Deriving what 5b's spec needs showed that `fabric.sh` reserved DHCP leases against a
> MAC derived from **creation order** while `lab-fc.sh` derived one from the **name**:
> the two committed tools could never agree, and the failure is silent (a dynamic lease
> while dnsmasq keeps answering the name with the reserved address). Fixed; both tools
> now answer `mac <name>` and a test drives both.
>
> **Consumed and verified for 5b so far:** `lab-vm.sh --network-mode tap --tap <name>`
> takes a pre-made tap and creates nothing (same contract as Firecracker); a TOML spec
> carrying `mac = "..."` reaches the manifest and the argv; `cloud-localds` is present;
> a Debian bookworm cloud image is cached.
>
> **Known gap:** `lab-vm.sh` has **no `--mac` CLI flag** — `mac` is absent from the CLI
> spec builder's jq object, so only a `--config` TOML can set it. 5b uses a TOML spec
> anyway (§9.1 wants one), so this is recorded rather than fixed.
>
> **Built 2026-08-05:** [`edge.toml`](edge.toml) + [`tests/test-edge-on-the-fabric.sh`](tests/run-all.sh).
> The spec's MAC is a **cached value with a gate**: the harness asks `fabric.sh mac edge`
> and refuses to boot on a mismatch. The load-bearing assertion is that each guest holds
> the address the fabric **RESERVED** — a guest that misses its reservation still gets a
> `10.71.0.x`, so a subnet regex would pass while the point failed. `api1` boots **through
> `lab-fc.sh`**, which no earlier slice did.
>
> **First root run refused, correctly:** `FAIL firecracker not on PATH`. `lab-fc.sh` finds
> the binary with `command -v` and offers no flag and no env override — deliberately,
> because its gate is *"the pinned version is installed"* and a path you can point anywhere
> is not that gate. The lab's pinned v1.16.1 lives in slice 3's state dir, so the harness
> now prepends that dir rather than working around the refusal. Re-verified unprivileged:
> `ok firecracker v1.16.1 at …/micro-cloud-s3/firecracker (pinned)`.
>
> ✅ **The edge BOOTS** (2026-08-06): Debian 12, cloud-init 22.4.2 finished in
> **3.48 s**, `edge login:` on the serial console — on a `fabric.sh` tap, beside a
> Firecracker microVM, with both VMMs at uid 1000. Getting there cost four defects,
> every one of them in the harness or the phase tool rather than the lab: a missing
> `PATH` for the pinned firecracker; an EXIT trap that reaped the fabric and the edge
> but not `api1` (leaking a live microVM, which the next run then refused); a console
> file the unprivileged reader could not create; and **`lab-vm.sh inspect` exiting 1
> with no output for every running VM** (a locked qcow2 — fixed in #149).
>
> **Two cloud-config defects, both in `lab-vm.sh`, both silent from the caller's side:**
> `runcmd` entries were emitted as BARE YAML scalars, so any command containing `: `
> parsed as a **mapping**; `cc_runcmd` then failed and **none** of the runcmd ran, on a
> VM that booted perfectly. And `chpasswd: {list: |}` is deprecated since cloud-init
> 22.3 and makes the whole document schema-invalid. Both fixed, both guarded by
> `phase2-qemu-vm/tests/test-cloud-init-yaml.sh`, which parses the generated user-data
> and asserts the TYPES cloud-init will see — a grep would have passed on the broken
> output, because the bytes looked perfect and only the parse was wrong.
>
> **Still not done:** the edge has not yet run its `runcmd`, so nothing has confirmed
> the reserved lease or cross-fidelity name resolution. Nothing has verified that a cloud
> image takes a lease from the fabric's dnsmasq, that cloud-init runs without slirp, or
> that the edge resolves `api1`. The harness's root path has never reached past its own
> preflight.

## QUEUED — slice 5c: vsock, the first channel that is not the fabric

*Scoped 2026-08-05, at the user's request, after 5b's spec and harness landed. Sits AFTER
5b because 5b's harness is written and unrun; 5c does not depend on it.*

**The question.** Every row of §18.4's seam table so far is network-attached, and the
fabric is the common seam that made shape **(b)** defensible. vsock is the first channel
that is **not the fabric**: a host↔guest pipe with no bridge, no lease, no name, no DNS.
Does the seam story survive a channel where the **guest** contract is byte-identical and
the **host** API differs in kind?

The plan has wanted this since v1 — decision **C** (*"the vsock agent is the cleanest
counter-example to MAAS's console-only habit"*) and §246: MAAS reads a serial log **because
a rack machine offers nothing else**; a microVM you own can be *asked*. Keeping the console
habit would cargo-cult a constraint that no longer applies.

### Measured 2026-08-05, before scoping — not assumed

| | state |
|---|---|
| `/dev/vhost-vsock` | present, `root:kvm 0660`, and uid 1000 is in `kvm` → **usable unprivileged**, like `/dev/kvm` |
| host modules | `vhost_vsock`, `vsock`, `vmw_vsock_virtio_transport_common` all loaded |
| QEMU | has **`vhost-vsock-device`** on the *virtio-bus* — so it works on `-M microvm`, not only q35 — plus `vhost-vsock-pci` |
| **the lab's kernel** | **`CONFIG_VSOCKETS=y` and `CONFIG_VIRTIO_VSOCK=y`** — `__initcall__kmod_vsock…` / `…kmod_vmw_vsock_virtio_transport…` symbols are present in `vmlinux`, and an initcall symbol only exists for **built-in** code. This is the assumption most likely to have sunk 5c, and it is retired: Firecracker boots with **no initramfs**, so a modular driver is a driver that would never load ([E.2](../../MICRO_CLOUD_LAB_PLAN.md#e2-decision-b--yes-with-one-condition-worth-stating)'s condition, applied to a different subsystem) |
| host `socat` | built `WITH_VSOCK 1` — so the host end needs no new tool |
| **the guest rootfs** | ⛔ **zero vsock-capable userspace.** `strings api1.ext4 \| grep -ci vsock` = **0**; it is busybox+musl, and busybox `nc` has no `AF_VSOCK`. **The kernel can, and nothing in the image can ask it to.** |
| Firecracker's own support | **NOT measured.** v1.16.1 documents a `vsock` block (`guest_cid` + `uds_path`); this repo has never exercised it |

### So the real work is a guest agent, not plumbing

The gap is **userspace**, which is the opposite of what "is vsock available?" suggests. 5c
therefore needs a tiny static agent in the image — and that is a **`export-rootfs` +
Phase-1 chroot** job, i.e. it consumes the [§18.6 item 3](../../MICRO_CLOUD_LAB_PLAN.md#186-order-of-work)
work already landed rather than inventing a new path.

### The asymmetry to measure, stated as a hypothesis so it can be wrong

| | Firecracker | QEMU |
|---|---|---|
| guest | `AF_VSOCK`, CID + port | `AF_VSOCK`, CID + port — **expected identical** |
| host | a **unix socket** carrying a text handshake (`CONNECT <port>\n`), `uds_path` in the config | **real `AF_VSOCK`** sockets on the host |

**This is documentation, not measurement.** If it holds, vsock is a *sharper* row than
`stop`: there the intent matched and the channel differed; here the guest-side contract is
byte-identical while the host-side API differs in kind — a harder case for shape (b) than
anything 5a or 5b produced. If it does not hold, that is the finding.

### Break pass, and the reason 5c is worth more than a seam row

vsock is a layer that **fails independently of the fabric**, which is exactly what
`CLAUDE.md`'s chaos ladder wants and what this lab does not yet have: tear down `br-mc0`
with the agent connected (network gone, is the guest still *reachable*?); kill the host
listener under a live guest; exhaust CIDs; and — the interesting one — **give two guests the
same `guest_cid`** and find out whether the second is refused or silently answers for the
first ([the seam-answers-for-the-wrong-instance](../../MICRO_CLOUD_LAB_PLAN.md#appendix-d--where-the-kubernetes-actually-is-2026-08-01)
class, which has bitten this repo before with a vbmc port collision).

### Done looks like

An agent in the image answering over vsock from **both** engines; a §18.4 row filled in from
what the two host APIs actually needed; the console demoted from *sole witness* to *one
witness*; and a chaos scenario for a layer that can fail on its own. **Explicitly out of
scope:** replacing SSH (decision C says start with SSH), and MMDS.

## QUEUED — `nested-calico-sandbox/`: a disposable cluster to break on purpose

*Scoped 2026-08-06. Unblocked and independent of the slice queue — nothing in slices 5c+
depends on it, and it depends on nothing later than slice 3.*

**The question it exists to make askable.** Three pieces of this lab's most expensive
knowledge are **unfalsifiable on this host**, because testing them means breaking a live
cluster:

| the belief | where it came from | why it is untested |
|---|---|---|
| the `^br-.*` exclusion makes `br-mc0` invisible to Calico (rule 1) | [F.7.1](../../MICRO_CLOUD_LAB_PLAN.md#f7-the-selection-rule-derived--and-7-already-satisfied-it), read out of the v3.28.1 binary | never verified by *naming a bridge the other way* and watching it get picked |
| an addressed interface becomes a first-found candidate (rule 2) | [F.6](../../MICRO_CLOUD_LAB_PLAN.md#f6-additive-was-not-safe--the-tap-captured-a-live-clusters-tunnel), observed **once**, as an outage | re-running it means causing a second outage |
| the ordering that decided F.6 | **nothing** — [G.3](../../MICRO_CLOUD_LAB_PLAN.md#g3-f7s-ordering-rule-does-not-explain-f6--the-correction) retracted the explanation | we cannot even *predict* the outcome, so the experiment is the only way |

`fabric.sh`'s whole safety design rests on the first two, and constraint 3 exists precisely
because they are *"derived from ONE host at ONE Calico version"*. A guest we are allowed to
destroy turns all three from beliefs into measurements.

**Why a lab unit and not a one-off script.** It is not only the F.6 re-run. A disposable
cluster is a **safe host for the entire slice-3 break pass**, which is the largest unpaid
debt in this queue:

- **`retap` is still never called** — it needs a deliberately root-owned tap to recover
  from, and deliberately breaking tap ownership on the machine running the fabric is
  exactly the kind of thing you do somewhere disposable.
- [G.9](../../MICRO_CLOUD_LAB_PLAN.md#g9-not-run--recorded-as-unknown-not-as-pass)'s
  tap-address scenario, the last unrun row of §14's break pass now that DHCP exhaustion
  is covered.
- **A chaos scenario for the CNI layer**, which micro-cloud does not have at all —
  `CLAUDE.md`'s ladder wants an injection point per independently-failing layer, and the
  CNI is one nobody has watched fall over here.

**What it must be, per the conventions.** A cohesive own-subdir lab:
`examples/nested-calico-sandbox/` with a phase-2 `.toml` (a cloud image + cloud-init that
installs microk8s), `README.md` + `MANUAL_TESTING.md`, a 00-INDEX row, a
`learning-paths.toml` route, and its harness under `tests/`.

### The five constraints, derived rather than discovered later

1. **It must enumerate its OWN candidate set.** Candidate ordering depends on which
   interfaces exist, and the guest has neither `lxdbr0` (index 9) nor `incusbr0` (index 17)
   — the two that decided [F.8](../../MICRO_CLOUD_LAB_PLAN.md#f8-lxdbr0-is-a-candidate-and-it-outranks-the-one-calico-chose).
   Reusing the host's list would be the cached-fact bug one layer down.
2. **It must record the Calico version it observed, and refuse to generalise across a
   mismatch.** microk8s bundles whatever its channel ships; the `^br-.*` exclusion and the
   index ordering are **v3.28.1** facts. Bind the finding to its subject's identity and
   name a mismatch, exactly as `capture-policy` does for PCRs.
3. **Wait, do not merely restart.** Autodetection re-runs on a **60-second poll**
   ([I.4](../../MICRO_CLOUD_LAB_PLAN.md#i4-the-finding-that-outlives-the-migration--autodetection-is-a-60-second-poll)),
   so an experiment that restarts `calico-node` and reads immediately is measuring the
   startup path only — half the mechanism, and the half that is already understood.
4. **It answers about *a* Calico, not *the* Calico.** The result transfers as a statement
   about the selection algorithm at a named version. It is **not** a prediction about this
   host, and the write-up must say so or it becomes one.
5. **No nested KVM required.** Neither scenario needs a microVM inside the guest — dummy
   interfaces and the guest's own DHCP clients suffice (G.9), so this does not wait on
   `kvm_amd nested=1`.

**Cost, measured where it can be:** microk8s + Calico wants roughly **4 GiB RAM and ~10 GiB
disk**. The harness shape already exists — [`edge.toml`](edge.toml) plus
[`tests/test-edge-on-the-fabric.sh`](tests/run-all.sh) is a cloud image driven by cloud-init
on a `fabric.sh` tap, which is precisely what this needs.

**Done looks like:** rules 1 and 2 promoted from *derived* to *measured*, with the Calico
version stamped on the result; G.3's ordering either explained or explicitly recorded as
still unexplained after a real experiment; `retap` called for the first time; and a CNI-layer
row in a micro-cloud chaos matrix. **Explicitly out of scope:** touching the host's cluster
in any way, and pinning `IP_AUTODETECTION_METHOD` here — [§7.1](../../MICRO_CLOUD_LAB_PLAN.md#71-this-host-is-not-empty--and-one-v2-line-was-a-real-defect)
is clear that changing someone else's config is the operator's decision, not the fabric's.

## The original brief — slice 5a: a second engine on one fabric

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
| `fabric.sh` (`up`/`tap`/`status`/`down`) | [`fabric.sh`](fabric.sh) | committed; round trip re-verified 2026-08-04 ([I.7](../../MICRO_CLOUD_LAB_PLAN.md#i7-the-recovered-fabric-re-verified-against-the-moved-binding--pass)), now a **repeatable test** — [`tests/test-fabric-round-trip.sh`](tests/run-all.sh) — whose privileged path was **executed 2026-08-05 and passed with 0 skips** ([I.9](../../MICRO_CLOUD_LAB_PLAN.md#i9-the-one-shot-became-a-test-and-the-tests-root-path-ran--pass)) |
| `lab-fc.sh` + preflight | [`phase7-firecracker/`](../../phase7-firecracker/lab-fc.sh) | slice 4; baseline **0.564930 s** — reproduced as 0.567145 on 2026-08-05, and then explained: **90.3% of it is an i8042 probe** ([J.3](../../MICRO_CLOUD_LAB_PLAN.md#j3-the-headline-that-was-false)) |
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
> ✅ **And re-run 2026-08-05 from the committed test, not the one-shot** —
> `sudo bash tests/run-all.sh` → `1 passed, 0 skipped, 0 failed`. The zero
> matters as much as the one: the test has three SKIP guards, so an all-skip
> run would look green while asserting nothing
> ([I.9](../../MICRO_CLOUD_LAB_PLAN.md#i9-the-one-shot-became-a-test-and-the-tests-root-path-ran--pass)).
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

> ✅ **IT RECURRED, TWICE, ON 2026-08-06 — and the reason the 2026-07-30 log was
> "never captured" is now known and fixable.**
>
> **`gh run view --log` returns ZERO lines for a failed job**, silently (rc=0,
> empty output). So does `--log-failed`, and so does `gh run view --job <id>
> --log`. That is not "the output was never captured" — it is the tool answering
> emptily. **The API endpoint works:**
>
> ```sh
> gh api "repos/<owner>/<repo>/actions/jobs/<job_id>/logs" > job.log   # ~850 lines
> ```
>
> `<job_id>` comes from the URL in `gh pr checks` output
> (`…/actions/runs/<run_id>/job/<job_id>`). **Capture before re-running.**
>
> With the log in hand, the two 2026-08-06 failures split cleanly — which is the
> whole point of the control, and why "flaky" must never be the *default*
> diagnosis:
>
> | PR | failing test | verdict |
> |---|---|---|
> | #155 | `test-inspect-json.sh` — `jq: … Cannot index array with string "Labels"` | **a real bug.** The runner image moved to **podman 5**, where `podman pod inspect` returns an ARRAY, not an object. `lab-podman.sh` had `.[0] as $c` for containers and `. as $p` for pods. Fixed in #156 |
> | #157 | `test-pod-lifecycle.sh` — *container not running* | **flaky.** Passed on a re-run of the same commit |
>
> **Red on a machine nobody changed, green on the machine that runs the tests** is
> the signature of an environment-shaped bug. Check the runner's tool versions
> before reading the diff.
>
> ⚠️ **A second, unrelated Actions failure mode, same day:** GitHub silently
> created **no run at all** for two PRs (#163, #164) — `statusCheckRollup: []`,
> nothing in `gh run list` for the branch — and a manually dispatched run
> (`gh workflow run CI --ref <branch>`) then sat **queued for 25+ minutes**. That
> is an Actions-side outage, not a repo problem, and it matters because *"no
> checks reported"* is easy to misread as *"checks passed"*. **Never merge on an
> absent run**: for a docs-only diff the honest substitute is running CI's jobs
> locally and saying so.

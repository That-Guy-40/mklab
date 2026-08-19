# RUNBOOK — the fleet: five warm clones from one memory image

> Plan reference: [§5.8 — Snapshot / restore, and the deepest lesson in the plan](../../MICRO_CLOUD_LAB_PLAN.md#58-snapshot--restore--and-the-deepest-lesson-in-the-plan).
> Tool: [`phase7-firecracker/lab-fc.sh`](../../phase7-firecracker/lab-fc.sh) (`snapshot`, `clone`).
> Tests: [`tests/test-fleet-clones.sh`](tests/test-fleet-clones.sh),
> [`tests/test-clone-entropy.sh`](tests/test-clone-entropy.sh),
> [`phase7-firecracker/tests/test-clone-refusals.sh`](../../phase7-firecracker/tests/test-clone-refusals.sh).

§5.8 promises one sentence:

> *Five warm instances from one memory image, in about the time one would take to boot. That
> is literally how Lambda serves a cold start.*

It is true, it is about forty lines of shell, and **the interesting part is what comes back
with them.**

---

## 1. The two verbs, and the difference between them

```console
$ lab-fc.sh snapshot create api1 warm     # memory + devices + the disk, from one pause
$ lab-fc.sh snapshot restore api1 warm    # put that back into api1
$ lab-fc.sh clone       api1 warm w1      # make a DIFFERENT machine out of it
```

`restore` puts a snapshot back into the instance it came from. `clone` makes another machine.
They differ in exactly two places, and both are load-bearing:

| | the disk | the memory image |
|---|---|---|
| `restore` | copied back over the instance's own rootfs | loaded |
| `clone` | **copied per clone** — never shared | **shared** by every clone |

**The disk is copied because it must be.** A snapshot's rootfs is one instant of one
filesystem. Two guests writing to one copy of it is corruption on the first write, and
nothing errors while it happens.

**The memory is shared because it can be.** Firecracker maps a `File` memory backend
`MAP_PRIVATE`, so N clones read one file and each one's writes stay private to it. That is
not a claim taken from the documentation — `test-fleet-clones.sh` sha256s the memory file
before and after five clones have been running and writing, and asserts it is unchanged. One
257 MB image serves the fleet; copying it per clone would cost five times the RAM for
nothing.

---

## 2. Walkthrough

### Boot something and let it get somewhere

The guest here prints a monotonic counter to its console once a second, because a **file**
marker could not tell a resume from a reboot — the rootfs is inside the snapshot, so a
rebooted guest would find the same file and "pass". Memory continuity is the only thing that
separates the two, so the proof is made of memory.

```console
$ lab-fc.sh create --name api1 --kernel vmlinux --rootfs base.ext4 --memory 256M
$ lab-fc.sh start api1
$ tail -1 ~/.local/state/lab-create/fc/api1/fc.log
MC-TICK 4 SECRET 6620d700645585da BOOTID ce38cd40-b164-4371-89b4-a8d86de4beac
```

### Snapshot it while it runs

```console
$ lab-fc.sh snapshot create api1 warm
PASS: snapshot api1/warm — 286M, VM resumed and still running (pid 187606)
      memory, device state AND the disk, all from the same pause
```

### Clone it five times

```console
$ lab-fc.sh stop api1
$ for n in 1 2 3 4 5; do lab-fc.sh clone api1 warm "w$n"; done
PASS: cloned api1/warm -> w1 (pid 188893) — API reports state=Running
      its own disk: …/fc/w1/rootfs.ext4
      SHARED memory image (read-only to it, mapped MAP_PRIVATE): …/fc/api1/snapshots/warm/mem
…
```

**Measured on this host: 2.1 s for all five**, against ~0.5 s to boot one. Note what that
number is made of — the memory sharing is free, and essentially all of the 2.1 s is the five
per-clone **disk copies**. A fleet on a smaller rootfs is proportionally faster.

### And every one of them resumed rather than booted

```console
$ for n in 1 2 3 4 5; do head -1 ~/.local/state/lab-create/fc/w$n/fc.log; done
MC-TICK 5 SECRET 6620d700645585da BOOTID ce38cd40-b164-4371-89b4-a8d86de4beac
MC-TICK 5 SECRET 6620d700645585da BOOTID ce38cd40-b164-4371-89b4-a8d86de4beac
MC-TICK 5 SECRET 6620d700645585da BOOTID ce38cd40-b164-4371-89b4-a8d86de4beac
MC-TICK 5 SECRET 6620d700645585da BOOTID ce38cd40-b164-4371-89b4-a8d86de4beac
MC-TICK 5 SECRET 6620d700645585da BOOTID ce38cd40-b164-4371-89b4-a8d86de4beac
```

The snapshot was taken at tick 4. Five machines picked the counter up at 5. A fresh boot
restarts at 1, and would have reprinted the kernel banner — asserted too.

**Now read the other two columns.**

---

## 3. The lesson: identity is not a property of an image

Every clone above has the same `SECRET` — eight bytes the guest read from `/dev/urandom`
*before* the snapshot — and the same `BOOTID`, which is
`/proc/sys/kernel/random/boot_id`, the kernel session identity that systemd and journald key
off. Five machines, one identity.

> **Identity is not a property of an image. It is a property of a running thing — and copying
> memory copies identity.**

On the plan's own ladder this is **LIED**, not HALTED, and that is why it outranks a crash.
Nothing errored. Five machines came up healthy and each of them is confidently wrong about
who it is.

### What `clone` does about it: says so, every time

```text
NOT RE-PERSONALISED — this clone resumed as a copy of a RUNNING machine, so it
currently believes it is api1. Identical to every other clone of this snapshot:
  - /proc/sys/kernel/random/boot_id  (the kernel session id systemd and journald key off)
  - anything already derived from /dev/urandom and held in memory: session keys,
    ssh host keys read at boot, a seeded PRNG in a long-running process
  - the clock, the hostname, and (had it a NIC) the guest MAC and its ip= address
```

### And why there is no `clone --tap`

`PATCH /network-interfaces` moves the **host** tap. It cannot touch the guest's MAC or its
`ip=` — both are in the memory image being copied — so five clones would all claim one MAC
and one address on one L2. A flag that produced that silently would be this tool telling its
own tripwire a lie, so `clone` does not offer one. Re-personalisation is a **guest-side**
step, which is exactly why real fleets treat restore as requiring explicit
re-personalisation rather than as a free `fork()`.

---

## 4. The entropy question, and why §5.8's demonstration does not reproduce

§5.8 says: *demonstrate the hazard (`head -c8 /dev/urandom | xxd` matching across clones),
then fix it by re-seeding on resume.*

**Run precisely that and it does not reproduce.** Five clones print five different values.
Two independent things are being conflated there, and
[`tests/test-clone-entropy.sh`](tests/test-clone-entropy.sh) separates them.

### The fix is already in the guest kernel

```console
$ grep 'crng reseeded' ~/.local/state/lab-create/fc/w1/fc.log
[    4.015494] random: crng reseeded due to virtual machine fork
```

Firecracker exposes a **VMGenID** device. Linux's `drivers/virt/vmgenid.c` sees the
generation counter change on `snapshot/load` and calls `add_vmfork_randomness()`. §5.8's
prescribed fix ships in the guest, one layer below where the plan looked for it.

### But the demonstration would fail even with it off — because the window is a few reads wide

Turn VMGenID off and probe with a `sleep 1` between reads, and the clones *still* diverge.
The hazard is real; the instrument was too slow to see it. Measured, on this host:

| | first read is ~ms after resume | first read is ~1 s after resume |
|---|---|---|
| **VMGenID active** | usually different — **but it is a race** | different |
| **VMGenID disabled** | **IDENTICAL — the hazard** | different |

The bottom-left cell is the one that matters and the bottom-right is the liar. One second of
independent execution is more than enough interrupt jitter to reseed the pool, so a sleeping
probe reports "no hazard here" in the row where the hazard is real. **Measured across runs
on this host the window has been 1, 3 and 20 reads — every one of them a small fraction of a
second.** The test reports the number and never asserts it: how much ambient entropy a host
mixes in is a fact about that host on that run, and pinning it would be caching a value whose
subject moves. That is this repo's oldest rule pointed at a measurement
rather than at an assertion: the cheap check is not a weaker version of the real one, it is a
different question that happens to be easier to ask, and it can be true while the thing it
stands for is false.

> **Turning VMGenID off, and the typo that cost a run.** The control is
> `initcall_blacklist=<initcall>`. The obvious symbol, `vmgenid_driver_init`, is silently
> ignored — the kernel's actual initcall is **`vmgenid_plaform_driver_init`**, because
> upstream's variable name is misspelled. Blacklisting a name the kernel does not have is a
> no-op that prints nothing, so the first control appeared to prove the *opposite* of the
> truth. The test now prints the symbol out of the kernel binary with `strings` before it
> trusts the control, and refuses to run if it is absent — and it asserts the reseed line
> **disappeared** rather than assuming the flag worked.

### VMGenID narrows the window; it does not close it

`add_vmfork_randomness()` runs from the ACPI notify path, not from the resume itself, so
whether it lands before the guest's first read is scheduling. Observed both ways here — on
one run three clones with VMGenID demonstrably firing produced an **identical** first read.
So the test asserts *that the reseed fired*, never *that it won the race*, and reports which
way each run went. Asserting the race would be asserting a flake.

### The half no reseed fixes

In **every** cell of that table, the pre-snapshot secret and `boot_id` are byte-identical
across all clones. VMGenID reseeds the CRNG; it does not re-personalise the machine.

> **Reseeding on resume fixes the randomness you have not asked for yet. It cannot fix the
> session keys you already minted from it.**

That is the version of §5.8's lesson that survives contact with a kernel which already
implements §5.8's fix — and it is the sharper one, because it is the half that no hypervisor
feature can take care of for you.

---

## 5. The gates, and one that is not obvious

`clone` refuses before it copies anything, because on a real fleet the copy is the expensive
irreversible step:

| refused | why |
|---|---|
| a traversing name — in **any** of the three positions | all three are path components |
| an unknown instance or snapshot | named, not guessed at |
| `clone api1 warm api1` | that is `snapshot restore`, and the refusal says so |
| a name already in use | `clone` does not overwrite |
| a snapshot whose bytes have changed | **by name, with both digests** — the same function `restore` uses, not a second copy of it |
| a snapshot with no manifest | **UNKNOWN**, said out loud; not a match and not a mismatch |

And the one that is easy to miss:

```console
$ lab-fc.sh destroy api1
lab-fc.sh: 5 clone(s) read their memory image out of …/fc/api1:
  - w1 (RUNNING)
  - w2 (RUNNING)
  …
lab-fc.sh: refusing to destroy 'api1' — destroy those first, or pass --force to remove the
memory image they were made from
```

Because `clone` **shares** the memory file, the source instance's state directory is a live
dependency of every clone made from it. A running clone survives the delete — the mapping
outlives the unlink — but nothing can be cloned from that snapshot again and no clone's
provenance can ever be re-derived. That is the "record outlives its subject" shape with the
subject deleted on purpose, so it is refused by name. The dependants are found by **reading
the sibling manifests**, never from a list written at clone time: a cached list of dependants
goes stale the moment one is destroyed.

---

## 6. What a clone is not

A clone has **no `config.json`**, and never will — the machine configuration is inside the
memory image. So:

```console
$ lab-fc.sh stop w1 && lab-fc.sh start w1
lab-fc.sh: 'w1' is a CLONE of api1/warm and has no config.json — a snapshot carries the
machine configuration, so there is nothing here to boot.  Once stopped, a clone is gone:
make another with `lab-fc.sh clone api1 warm <new-name>`
```

**Stopping a clone ends it.** That is not a limitation to be worked around; it is what a warm
clone *is*. The durable thing is the snapshot, and clones are cheap because they are
disposable. `inspect` reflects the same fact — no kernel row (there is no kernel of its own),
and instead a `clone_mem_check` that re-derives the digest of the shared memory image it is
reading right now.

---

## 6a. The other tier: the same microVM, jailed

§5.6's isolation tier is the sibling of everything above — `clone` gives you *many* machines
from one; `--jailer` puts *one* machine inside a chroot with its own uid.

```console
$ sudo LAB_FC_JAIL_UID=30000 LAB_FC_JAIL_GID=30000 lab-fc.sh start api1 --jailer
PASS: started api1 JAILED (pid 1336963) — process confirmed running, not merely forked
      chroot: …/fc/api1/jail/firecracker/api1/root
```

**Every path in `config.json` is relative to the new chroot**, so `--jailer` stages the
kernel and rootfs inside the jail and writes a second, in-chroot config. The rootfs is
hard-linked — one guest disk, not two mutable images — which means a jailed start takes
ownership of the instance's disk, and a later plain `start` says so and gives you the way
back rather than failing with a bare `Permission denied`.

### What actually distinguishes a jailed VMM — and what does not

§5.6 says to diff `/proc/<pid>/root`, `/proc/<pid>/ns/net` and the `Seccomp` line. Measured,
**none of those three answers the question**:

| field | plain | jailed | |
|---|---|---|---|
| `ns/mnt` | `mnt:[4026531841]` | `mnt:[4026535173]` | **asserted** — the unshare happened |
| the guest disk, as each has it open | `…/fc/jplain/rootfs.ext4` | **`/rootfs.ext4`** | **asserted** — the chroot, visible |
| `Uid` | 0 | **30000** | **asserted** — the privilege drop |
| `/proc/<pid>/root` | `/` | `/` | *reported* — identical, see below |
| `ns/net` | `net:[4026531840]` | `net:[4026531840]` | *reported* — jailer **joins** a netns, never creates one |
| `Seccomp` | 2 | 2 | *reported* — Firecracker filters itself in either tier |

**`/proc/<pid>/root` renders as `/` for a jailed VMM exactly as for a plain one**, because the
jail is built inside a private mount namespace and its path is not reachable from the reader's
namespace. The field is present, correct, and useless for telling the tiers apart — a
mechanism standing in for a property, in the plan's own instructions.

The row to show someone is the second one: **the same guest disk, opened by two VMMs, and the
jailed one calls it `/rootfs.ext4`.** That is the chroot in a single line of output.

---

## 7. Running it yourself

```console
$ examples/micro-cloud/tests/test-fleet-clones.sh     # needs KVM + the slice-1/3 images
$ examples/micro-cloud/tests/test-clone-entropy.sh    # ditto; boots two sources, clones six
$ phase7-firecracker/tests/test-clone-refusals.sh     # no KVM, no VMM — runs anywhere
$ phase7-firecracker/tests/test-jailer-staging.sh    # ditto — the jail tier's file-and-text half
$ sudo -E env PATH="$HOME/.local/state/lab-create/micro-cloud-s3:$PATH" \
      examples/micro-cloud/tests/test-jailer-isolation.sh   # needs CAP_SYS_ADMIN
```

The first two SKIP by name where there is no KVM or no images. The third is the half that
must never rot, so it is built to need neither: its source instance is a directory and its
snapshot is four files, both fabricated in the test, because `clone`'s gates are questions
about paths and digests and neither knows nor cares which process wrote the bytes.

Every assertion in all three was watched to fail on the defect it names before it was
believed — including the two that were wrong on the first attempt: a fleet test whose guests
never wrote to disk (so "each clone has its own disk" was measuring nothing), and an entropy
probe that slept a second before looking (so it reported the hazard did not exist).

# RUNBOOK — the whole micro cloud, instance by instance

> The other runbooks in this directory each take one mechanism apart:
> [`RUNBOOK-fleet.md`](RUNBOOK-fleet.md) is snapshot/restore and the clone hazards,
> [`RUNBOOK-preserve.md`](RUNBOOK-preserve.md) is backing a lab up and restoring it
> elsewhere. **This one is the demo** — five instances of four kinds on one L2, and the
> question [§9.3](../../MICRO_CLOUD_LAB_PLAN.md#93-the-capstone-question--isolation-not-ping)
> says is the actual payload: *what can each of these things see of the others, and what did
> each boundary cost?*

## Before anything: read the plan, then look at your host

```bash
examples/micro-cloud/micro-cloud.sh plan
```

That runs **nothing**. It prints the whole lab as commands, in order, with the `cd` that
makes the spec's relative paths resolve — so you can read it, paste any line of it, or pipe
it to `bash -n` and satisfy yourself it is a script and not a story. It is also what
`tests/test-micro-cloud-plan.sh` asserts against, and what
`tools/check-guided-path-is-a-view.sh` §3 runs each verb of.

Then look at what the fabric is about to sit beside:

```bash
examples/micro-cloud/fabric.sh status
```

**Read the `THEIRS` block before you run anything privileged.** On the machine this lab was
built on it says the CNI's tunnel endpoint lives on `lxdbr0` — a bridge that is *down and
memberless*, and therefore not a candidate by Calico's own rules. That is
[`LEDGER.md` L10-1](LEDGER.md#l10-1--calicos-node-ip-is-on-an-interface-that-is-down-and-db-is-the-instance-that-could-move-it),
and it is the reason `db` is pinned to `br-mc0` by an explicit `nic` device rather than left
to LXD's default bridge. Your host will say something different; the point is that you look,
because the fabric records this at `up` and compares it at `down`.

## Step 0 — the images (root, once)

The two microVMs boot an ext4 built from the `[[chroot]]` block in `micro-cloud.toml`. That
is [`RUNBOOK-build-images.md`](../../MICRO_CLOUD_LAB_PLAN.md#6-new-component-b--lab-chrootsh-export-rootfs)'s
job in the plan; the short version is that `lab-chroot.sh create` needs root (debootstrap
does) and `export-rootfs` turns the tree into the image without a loop mount:

```bash
sudo phase1-chroot/lab-chroot.sh create --config examples/micro-cloud/micro-cloud.toml
sudo phase1-chroot/lab-chroot.sh export-rootfs micro-cloud-base \
     --output examples/micro-cloud/images/api1.ext4 --size 512M
cp examples/micro-cloud/images/api1.ext4 examples/micro-cloud/images/api2.ext4
```

The kernel is an **uncompressed ELF `vmlinux`**, not a `vmlinuz` — Firecracker's loader is
ELF-only and answers a bzImage with `Elf(InvalidElfMagicNumber)`. `lab-fc.sh preflight`
checks this before anything is copied, and tells you to run `extract-vmlinux` if you handed
it the wrong one.

Once both exist:

```bash
phase7-firecracker/lab-fc.sh preflight --config examples/micro-cloud/micro-cloud.toml
```

Every gate, before any state is created. This is the step that catches a missing image, a
wrong kernel format, a tap that does not exist, and a name the driver cannot address —
while it is still free to be wrong.

## Step 1 — bring it up

```bash
sudo examples/micro-cloud/micro-cloud.sh up
```

The fabric first (bridge, nft, dnsmasq, then one addressless tap per instance that declares
one), then the instances in the order `lab_tui.topology` computes. A step that returns
non-zero halts the run and is named, with its exit status and the exact command — a
tear-down or a bring-up that carries on past a failure reports success over a half-built lab.

**`up` orders invocations, not readiness.** Nothing waits for a guest to answer. That is
[L10-2](LEDGER.md#l10-2--up-orders-invocations-and-readiness-is-a-different-question), and
its visible consequence is that `edge`'s first-boot `ping api1` runs before `api1` is
started and reports `EDGE-PING-BY-NAME FAIL`. It is not a fault in the lab and reordering
the slots would not fix it; the peer check below is the evidence that matters.

## Step 2 — what is actually up

```bash
examples/micro-cloud/micro-cloud.sh status
```

Unprivileged, and it derives everything: each driver is asked directly (`lab-fc.sh inspect`,
`lab-vm.sh list`, `lab-podman.sh status`, `lab-lxd.sh status`) and the addresses are read
back out of dnsmasq's lease file. There is no state file of instance addresses anywhere in
this lab — [§8.4a](../../MICRO_CLOUD_LAB_PLAN.md#84a-decision-g--settled-2026-08-16-derive-the-facts-record-only-the-intent)
settled that: *derive the facts, record only the intent.*

Note what the addresses are **not**: the plan's §15 transcript shows `api1 10.71.0.11`, and
the fabric does not promise that. Reservations are handed out by arrival order inside
`MC_DHCP_LO..MC_DHCP_HI`, and `fabric.sh`'s own comments say so — `api1` was `.101` only
because it was always created first. What is stable is each instance's **MAC**, derived from
its name by a formula `fabric.sh` and `lab-fc.sh` share, and the reservation is against that.

## Step 3 — the peer check, by hand

This is the part worth typing yourself, because it is the claim: **heterogeneous instances,
one L2, resolved by name.**

```bash
# from the fidelity VM, which has a full userspace
phase2-qemu-vm/lab-vm.sh ssh edge -- ping -c2 api1
phase2-qemu-vm/lab-vm.sh ssh edge -- getent hosts db

# and the microVM's own identity, from the metadata service rather than from a file
phase7-firecracker/lab-fc.sh inspect api1
```

`getent hosts` rather than `ping` for the name half: `ping` answering proves resolution *and*
reachability at once, and when it fails you cannot tell which broke. Ask the two questions
separately.

## Step 4 — the capstone

```bash
examples/micro-cloud/tests/test-isolation-matrix.sh
```

Unprivileged it measures two rows — the host and the rootless container — and names the
other three UNKNOWN with the reason each needs a privileged run. That is deliberate: *"I
could not check this" must never render as "this is fine."*

The two rows it does measure already carry the lesson §9.3 is after. `metrics` sees 4
processes where the host sees ~950, and its network namespace is its own — it is **not on
the fabric at all**, because a rootless container cannot be given a tap (that needs
`CAP_NET_ADMIN`, which is the entire point). But it reads the host's `boot_id` straight out
of `/proc`: procfs is namespaced for *processes*, not for the machine's identity. The
boundary that hides 946 processes does not hide what machine you are on.

## Step 5 — down, which is a test

```bash
sudo examples/micro-cloud/micro-cloud.sh down
```

The instances in reverse, then `fabric.sh down`, which is the interesting half.
[§7.2](../../MICRO_CLOUD_LAB_PLAN.md#72-teardown-is-a-test-not-a-cleanup): teardown
**asserts absence** afterwards and fails loudly otherwise, and it distinguishes *what we
created* from *what we found* — `net.ipv4.ip_forward` was already 1 on this host because a
live Kubernetes needs it, and a teardown that reverts someone else's global is not a cleanup,
it is an outage. It then compares Calico's binding and candidate set against what the
pre-flight recorded, and reports a migration rather than assuming one did not happen.

Then check by hand, because the assertion and the observation are two different things:

```bash
ip -o link show | grep -E 'br-mc0|mc-'      # expect nothing
examples/micro-cloud/fabric.sh status        # THEIRS should match what up recorded
```

Note what `down` deliberately does **not** do: it stops the microVMs but does not destroy
them (each keeps its own rootfs copy), and it leaves the chroot and the VM alone entirely.
Those are expensive, persistent artifacts, and a tear-down that reaps them is a tear-down you
run once and then stop trusting. The plan prints the `destroy` commands for each so you can
choose.

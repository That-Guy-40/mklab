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

## Step 0 — the spine, and the two things made from it (root, once)

**This is where §2 becomes checkable.** *A chroot is the universal userspace every compute
type imports* — so one tree is built here and both of the lab's own images are exported from
it: an ext4 for the microVMs and a tarball for the LXD system container.

**How far that is actually true right now, stated rather than implied.** The tarball route is
live: `db` imports it, and without it `db` does not come up. The ext4 route is the documented
path, but if you already have working microVM images from slices 1/3 they are a **BusyBox**
tree, not this Debian one, and swapping them is not free — a Debian minbase boots systemd and
prints none of the `SLICE3-*` console markers the microVM half is currently proved by. Export
it if you want the whole spine demonstrated end to end; keep the slice-3 images if you want
the existing microVM evidence to keep meaning what it meant.

```bash
# the spine itself (debootstrap needs root)
#
# `--include systemd-sysv` IS THE INTERESTING FLAG, and it was added because the lab failed
# without it. See "where universal stops" below.
sudo phase1-chroot/lab-chroot.sh create \
     --backend debootstrap --distro debian --suite bookworm --arch x86_64 \
     --variant minbase --manager none --include systemd-sysv \
     --post-command 'systemctl enable systemd-networkd' \
     --post-command 'mkdir -p /etc/systemd/network' \
     --post-command 'printf "[Match]\nName=eth0 en*\n\n[Network]\nDHCP=ipv4\n" > /etc/systemd/network/10-fabric.network' \
     --name micro-cloud-base --target /var/chroots/micro-cloud-base --lab micro-cloud

# export 1 — the microVMs' root filesystem, written WITHOUT a loop mount
sudo phase1-chroot/lab-chroot.sh export-rootfs micro-cloud-base \
     --output examples/micro-cloud/images/api1.ext4 --size 512M
cp examples/micro-cloud/images/api1.ext4 examples/micro-cloud/images/api2.ext4

# export 2 — db's image. NOT `from_chroot`: phase 5 refuses to read a root-built tree
# directly (mode-600 files like /etc/shadow are unreadable to an unprivileged run) and says
# so by name. export-tarball runs tar as root and chowns the result to you.
sudo phase1-chroot/lab-chroot.sh export-tarball micro-cloud-base \
     --output examples/micro-cloud/images/micro-cloud-base.tar.gz
sudo chown "$USER" examples/micro-cloud/images/micro-cloud-base.tar.gz
```

### Where "universal" stops, measured

§2 says a chroot is the userspace *every compute type imports*. Running it found the edge of
that: a Debian `--variant minbase` tree has **no init at all** — no `/sbin/init`, no systemd.
That is:

* **fine for a microVM.** Firecracker boots a kernel that execs whatever `/sbin/init` you put
  there; slice 1's images use a shell script.
* **fine as an OCI layer.** A container image needs a command, not an init.
* **fatal for a system container.** LXC execs `/sbin/init` and there wasn't one, so `db`
  failed at launch with `forklxc … exit status 1` *after* the image imported perfectly. The
  import succeeding is what makes this worth writing down: everything about the export route
  worked, and the tree was still the wrong tree.

And it lands on exactly the instance whose lesson it is — [§9.2](../../MICRO_CLOUD_LAB_PLAN.md#92-the-instances)
calls `db` *"the system-container case: a stateful pet **with its own init**"*.

**Then it happened again, one layer up.** With an init, `db` started — and had no address.
`systemd-networkd` ships with systemd but is **not enabled**, and a minbase tree has no
`dhclient`, no `ifupdown`, no `udhcpc`. So the container came up, got its veth on `br-mc0`,
and *nothing ever asked for one*: present on the L2, invisible on the network, with
`getent db` returning nothing from `edge`. Hence the three `--post-command` lines above.

So the tally of what "universal" costs, per consumer:

| | init | network config |
|---|---|---|
| Firecracker microVM | supplies its own | its init DHCPs itself |
| OCI container | not needed | podman supplies the namespace |
| **LXD system container** | **needs one** | **needs one** |

`--include systemd-sysv` and the `.network` unit are what make one tree serve all three, and
they are a real cost: a microVM rootfs exported from this tree now carries systemd, which
boots slower and wants more than 256 MB.

**Why the chroot is not a block in `micro-cloud.toml`.** It was, until running the lab showed
it could not be: the instances consume its *exports*, the control plane has no slot that emits
an export step, and so a bring-up needed the exports to exist before the very step that
created the tree they come from. `micro-cloud.toml` now declares the five things that **run**,
and this step builds what they run *on*. The spec carries the full reasoning.

**If you COPY an image rather than build one, fsck it.** An ext4 copied out of a directory
where it was last used by a running guest is marked dirty, and `debugfs` refuses to open it:

```bash
e2fsck -fy examples/micro-cloud/images/api1.ext4
```

Preflight reports that case as **UNKNOWN**, not as a pass and not as a failure — *"cannot
read … with debugfs (image is dirty or unsupported) — /sbin/init NOT verified"*. That
distinction is the point: the gate could not run, and a gate that cannot run must not report
that the thing it checks is fine. Observed on the first privileged run of this lab, on one of
two otherwise identical images.

Then check every gate before anything is created:

```bash
phase7-firecracker/lab-fc.sh preflight --config examples/micro-cloud/micro-cloud.toml
```

`firecracker` must be on `PATH`, and it usually is not — the pinned binary lives in the
slice-3 workdir. `sudo` will not carry your `PATH` either, so export it explicitly:

```bash
export PATH="$HOME/.local/state/lab-create/micro-cloud-s3:$PATH"
```

Every gate, before any state is created. This is the step that catches a missing image, a
wrong kernel format, a tap that does not exist, and a name the driver cannot address —
while it is still free to be wrong.

## Step 1 — bring it up

> **Or run the whole thing at once.**
> [`run-privileged-demo.sh`](run-privileged-demo.sh) performs every step below — step 0
> included — waits for readiness, asks the capstone question the way it has to be asked, and
> brackets the run with an independent recording of the host CNI's state:
>
> ```bash
> sudo -E examples/micro-cloud/run-privileged-demo.sh --reset
> ```
>
> The rest of this runbook is what it does, in the order it does it, so you can run any step
> by hand and know what it was for.


```bash
sudo examples/micro-cloud/micro-cloud.sh up
```

**`sudo` here does not mean the instances run as root, and that matters more than it looks.**
The fabric is root's; the instances are yours. `micro-cloud.sh` drops back to the invoking
user (`runuser -u $SUDO_USER --`) for every phase-tool step, and `plan` prints that prefix so
you can see it. The first privileged run of this lab did *not* do that, and it was refused —
correctly — at the first microVM:

```text
FAIL  tap mc-api1 is owned by uid 1000, not 0 — Firecracker would get EPERM from TUNSETIFF
```

`fabric.sh` hands each tap to the invoking user **on purpose**, so the VMM opens it with no
privilege at all. A root `up` would have run Firecracker as uid 0 against a tap built for uid
1000 — and had the gate not caught it, the lab would have quietly stopped demonstrating the
thing it exists to demonstrate. The same boundary is why `metrics` works at all:
`lab-podman.sh` refuses to run as root, because a rootless sidecar is §9.3's exhibit.

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

**`lab-vm.sh ssh edge` does not work here, and the reason is worth knowing.** That verb
connects to `127.0.0.1:<ssh_port>`, which is a **slirp host port forward** — it exists only in
user-mode networking. `edge` is `network_mode = "tap"`, so there is no forward and there never
was; the `SSHPORT 2222` that `lab-vm.sh list` prints beside it is a number describing nothing.
This runbook told you to run that command for a while, and it could not have worked at any
commit. Phase 2 now refuses it by name and points here instead.

Reach the guest at its address **on the fabric** — the host holds `10.71.0.1` on `br-mc0`, so
it can route to every instance:

```bash
# the address the fabric actually leased it (never a number from a doc)
edge_ip=$(awk '$4 == "edge" { print $3 }' /run/mklab-mc/leases)

ssh lab@"$edge_ip" -- getent hosts api1     # does the NAME resolve?
ssh lab@"$edge_ip" -- ping -c2 api1         # and is it REACHABLE?

# and the microVM's own identity, from the tool rather than from a file
phase7-firecracker/lab-fc.sh inspect api1
```

`getent hosts` and `ping` are asked separately on purpose: `ping` answering proves resolution
*and* reachability at once, and when it fails you cannot tell which broke.

**If the lease line is not there yet, the guest has not DHCPed yet** — see step 1's note about
readiness, and read what it is actually doing:

```bash
less ~/.local/state/lab-create/vms/edge/console.log
```

That file exists because the serial chardev now carries a `logfile=`. It did not, until a run
of this lab found that `edge`'s own cloud-init markers — `EDGE-BEGIN`, `EDGE-PING-BY-NAME` —
were being written to a socket with no reader, and lost. The lab's success signature was
unobservable through the documented path.

## Running it a second time — reset first

`down` stops microVMs and never destroys them, and `create` refuses an instance that already
exists. Both are correct, and together they mean a second `up` halts at the first microVM with
*"instance 'api1' already exists"*. That is the halt-don't-converge contract working, not a
fault. To run the whole thing again:

```bash
phase7-firecracker/lab-fc.sh destroy api1 --force
phase7-firecracker/lab-fc.sh destroy api2 --force
phase2-qemu-vm/lab-vm.sh     destroy edge  --force
sudo phase1-chroot/lab-chroot.sh destroy micro-cloud-base
```

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

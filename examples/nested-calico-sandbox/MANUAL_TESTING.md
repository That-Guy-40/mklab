# nested-calico-sandbox — Manual Testing Walkthrough

Top to bottom, with what to expect and how to recognise breakage. **No root, no host
networking, no nested KVM.** Budget ~20 minutes, most of it the snap download.

> **Working directory:** the repo root.

## 0. Preflight

```bash
ls -l /dev/kvm && groups | tr ' ' '\n' | grep -qx kvm && echo "kvm OK"
command -v qemu-img socat python3 >/dev/null && echo "tools OK"
ip -d link show vxlan.calico 2>/dev/null | grep -oE 'local [0-9.]+ dev [a-zA-Z0-9._-]+'
```

That last line is **the host's** Calico tunnel. Write it down. Nothing in this lab may move
it, and every step below prints it again so you can see that it did not.

> ⚠️ **Re-derive it, never quote it.** On the machine this lab was built on, that binding
> moved **four times in six days** with no lab involved — `incusbr0` → the physical uplink →
> `lxdbr0` → back to the uplink. Any doc naming a specific interface is a cache entry.

## 1. Bring the sandbox up (~15 min)

```bash
examples/nested-calico-sandbox/sandbox.sh up
```

**Expect:**

```
[info] host Calico binding BEFORE (recorded so teardown can prove we did not move it):
[info]   local 192.168.1.106 dev enx00051b8eb138
[info] creating overlay qcow2: .../calico-sandbox/disk.qcow2
[info] overlay virtual-size 3072M -> 16384M
[info] starting calico-sandbox (accel=kvm arch=x86_64 mem=4G cpus=2)
[info] waiting up to 900s for the cluster (first boot pulls ~200 MB of snap)
  NCS-BOOT
  NCS-MICROK8S-INSTALLED
  NCS-K8S-READY
  NCS-CALICO=docker.io/calico/node:v3.29.3
  NCS-READY-FOR-EXPERIMENT
[info] cluster ready after 90s
```

**How to recognise breakage:**

| symptom | what it means |
|---|---|
| `overlay virtual-size 3072M -> 3072M` and a refusal | the resize did not take. Nothing downstream would work: microk8s needs ~10 G and a 3 G image runs out mid-install, surfacing as a *snap* error with nothing pointing back here |
| `NCS-MICROK8S-FAILED` | the snap install failed; the next three console lines are its tail |
| `NCS-K8S-NOTREADY` | installed but never converged. **Check the version of this**: an early spike reported exactly this while the cluster was running perfectly, because `/snap/bin` is not on `sudo`'s `secure_path` |
| `NCS-CALICO=UNRESOLVED` | the cluster came up without a `calico-node` DaemonSet — a different CNI, and every rule below is about something else |
| times out at 900 s | read the captured console: `~/.local/state/lab-create/vms/calico-sandbox/ncs-console.log` |

> The console is a **unix socket**, not a file — `sandbox.sh` captures it with `socat`.
> While that capture is running, `lab-vm.sh console calico-sandbox` will show **nothing**:
> one client at a time on that socket. Read the log instead.

## 2. Verify the guest is real before trusting anything it says

```bash
phase2-qemu-vm/lab-vm.sh ssh calico-sandbox -- \
  'df -h / | tail -1; sudo /snap/bin/microk8s kubectl get ds -n kube-system calico-node'
```

**Expect** a 16 G root filesystem and `calico-node  1  1  1  1  1`.

If `df` still shows 3 G, cloud-init's `growpart` did not run — the resize reached the qcow2
but not the partition table.

## 3. Run the experiment

```bash
examples/nested-calico-sandbox/sandbox.sh experiment
```

**Expect:**

```
NCS-CALICO-VERSION=v3.29.3
NCS-AUTODETECTION-METHOD=first-found
NCS-CANDIDATE-SET=lo enp0s3 vxlan.calico cali… cali…
NCS-BINDING-BEFORE=enp0s3 addr=10.0.2.15
NCS-DECOYS-UP br-decoy(idx 8) mc-decoy(idx 9)
NCS-BINDING-AFTER-DECOYS=mc-decoy after=15s
NCS-CONTROL-DELETED=mc-decoy (br-decoy still up, addressed, higher index than the incumbent)
NCS-BINDING-AFTER-CONTROL=enp0s3 after=15s
NCS-EXCLUDED-DECOY-STILL-PRESENT=10.99.1.1/24
NCS-END
```

**Read it in this order, because the third line is the one that matters:**

1. `BINDING-AFTER-DECOYS=mc-decoy` — **rule 2**. An addressed interface became a candidate
   and Calico migrated *on its own poll*, nothing restarted.
2. `CONTROL-DELETED` — the winner is removed while `br-decoy` stays up and addressed.
3. `BINDING-AFTER-CONTROL=enp0s3` — **rule 1**. It fell back to the incumbent at index 2
   rather than to `br-decoy` at index 8. **Index ordering cannot explain that**; the only
   difference left is the name.

Without step 3, step 1 is equally explained by *"the highest index won"* and the `^br-.*`
exclusion is unproven. **If `BINDING-AFTER-CONTROL` is `br-decoy`, that is a real finding**
— the exclusion does not hold at that version, and `fabric.sh`'s bridge naming rests on it.

> `after=Ns` is **reported, never asserted**. Three runs on the same image and the same
> Calico converged in ~180 s, 15 s and 10 s. Anything that requires a particular figure is
> asserting a coincidence.

## 4. The suite

```bash
examples/nested-calico-sandbox/tests/run-all.sh
```

**With a sandbox up:** `3/3 listed tests ran … 3 passed, 0 skipped, 0 failed`.

**Without one:** `test-selection-rules.sh` **SKIPs** with a reason and tells you the command
to bring one up. That is the correct result, not a weak pass — an unmet precondition is an
UNKNOWN.

## 5. G.9's scenario — a real `fabric.sh` tap (needs root *in the guest only*)

```bash
examples/nested-calico-sandbox/tests/test-fabric-tap-becomes-candidate.sh
```

This copies the **real** `fabric.sh` into the guest, brings a fabric up *there*, and gives
one of its taps an address on purpose. It is the scenario [plan G.9](../../MICRO_CLOUD_LAB_PLAN.md#g9-not-run--recorded-as-unknown-not-as-pass)
deferred in 2026-08-02 as "an outage on a live cluster" — here it costs nothing.

The distinction it closes: §3 uses **dummy** interfaces, and a dummy in a guest is not a tap
on `br-mc0`. Same property, different subject.

## 6. Tear down, and check the host

```bash
examples/nested-calico-sandbox/sandbox.sh down
```

**Expect** the same host binding printed in step 0. If it differs, find out why **before**
assuming this lab caused it — on this host it has moved on its own four times.

## Success signature

- `NCS-BINDING-AFTER-DECOYS=mc-decoy` — rule 2 measured
- `NCS-BINDING-AFTER-CONTROL` is **not** `br-decoy` while `br-decoy` is still addressed —
  rule 1 measured, with the control that makes it mean something
- the host's Calico binding identical at step 0 and step 6
- `3/3 listed tests ran … 0 failed`

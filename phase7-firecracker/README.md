# Phase 7 — Firecracker microVMs (`lab-fc.sh`)

A config generator and a process babysitter for [Firecracker](https://firecracker-microvm.github.io/)
microVMs. It replaces the typing that [`examples/micro-cloud/`](../examples/micro-cloud/)'s
first three slices did by hand — and the most useful thing it does is **tell you what it
did**: every field of the generated `config.json` carries a provenance tag, so "the tool
quietly started doing this for you" cannot happen quietly.

```
lab-fc.sh create --dry-run --name api1 --kernel vmlinux --rootfs rootfs.ext4

  WHAT THIS TOOL DID THAT YOU DID NOT TYPE:
  WHERE FROM FIELD = VALUE                 WHY
  DEFAULT   mem_size_mib = 256             you did not say; Firecracker's own default is 128
  DEFAULT   boot_args: panic=1             MEASURED: with it Firecracker exits in 1.63s on panic;
                                           without it the VM hung until killed at 20s
  APPENDED  boot_args: root=/dev/vda rw    FIRECRACKER adds this after ours; the kernel honours
                                           the LAST root=, so this one wins
  REFUSED   boot_args: root=<yours>        not offered as a knob — it would be silently overridden
```

| tag | meaning |
|---|---|
| `YOURS` | you typed it |
| `DEFAULT` | the tool supplied it because you did not |
| `DERIVED` | the tool computed it from something you did type |
| `APPENDED` | Firecracker adds it **after** ours, and the kernel honours the last one |
| `REFUSED` | you asked for something the tool will not do, and why |

## Verbs

```
lab-fc.sh preflight --config <f.toml> | <spec flags>
lab-fc.sh create    ...  [--dry-run]     # --dry-run prints config + provenance, writes nothing
lab-fc.sh start     <name> [--force]     # --force: start despite a changed/missing kernel
lab-fc.sh stop      <name> [--force]     # --force: escalate to SIGKILL if SIGTERM is ignored
lab-fc.sh destroy   <name> [--force]     # --force: kill it first if it is running
lab-fc.sh list      [--json]
lab-fc.sh inspect   <name>
lab-fc.sh mac       <name>               # the guest MAC this tool would set — read-only
```

`--help` prints the same list, extracted from the script's own header.

## The spec

One `[[microvm]]` block per instance. Every key below is also a `--flag` of the same name
(`ip` is `--ip`, `mmds` is a bare `--mmds`), and
[`tests/test-cli-vs-config-parity.sh`](tests/test-cli-vs-config-parity.sh) proves the two
spellings generate a byte-identical config **and** a byte-identical provenance table.

```toml
[[microvm]]
name    = "api1"                    # lowercase alnum/dash, ≤31 chars — it is a directory name
kernel  = "/path/to/vmlinux"        # an uncompressed ELF, NOT a bzImage/vmlinuz
rootfs  = "/path/to/rootfs.ext4"    # copied per-instance at create
memory  = "256M"                    # 256, 256M or 1G — Phase 2's spelling
vcpus   = 1
tap     = "mc-api1"                 # must ALREADY exist; this tool never makes taps
mac     = "06:00:ac:47:f1:f7"       # optional; derived from the name if omitted
ip      = "10.71.0.101"             # only legal alongside a tap
gateway = "10.71.0.1"
netmask = "255.255.255.0"
mmds    = true                      # MMDS v2 (v1 answers any GET, unauthenticated)
append  = "mc_name=api1"            # extra boot args, verbatim. root= is REFUSED — see below
lab     = "micro-cloud"
```

Anything else is refused **by name**, and the run stops before a single gate executes — a
key that is silently dropped is a field that appears to work and does nothing.

## Things it deliberately will not do

- **It does not create or delete taps.** Tap lifecycle belongs to
  [`examples/micro-cloud/fabric.sh`](../examples/micro-cloud/fabric.sh) (`fabric.sh tap` /
  `retap`). Two owners for one resource is the stale-record bug this repo keeps finding:
  whichever deletes it first leaves the other's record describing something gone. The tap is
  an **input** here — validated (it exists, it is owned by *your* uid, it carries no IPv4),
  never manufactured.
- **It will not let you set `root=`.** Firecracker appends its own `root=/dev/vda` *after*
  ours and the kernel honours the last one, so yours would be silently ignored. Refusing
  loudly beats offering a knob that does nothing.
- **It will not accept `ip=` without a NIC.** Measured twice: 0.55 s → 12.84 s, spent in the
  kernel's IP autoconfiguration waiting for a device that never appears, with no `IP-Config`
  line and no error anywhere in `dmesg`. Silent, 23×.
- **It has no `explain` verb.** Provenance belongs to the thing that generates the config,
  so it is a flag on `create`, not a new noun.
- **It offers no way to point at a different `firecracker` binary.** The gate is "the
  *pinned* version is installed"; a path you can aim anywhere is not that gate. Prepend the
  directory to `PATH` instead.

## What it verifies, and when

`preflight` is **the same function `create` runs first** — not a second implementation that
predicts what `create` will do. Two implementations drift, and the one that drifts is always
the one that says "fine". [`tests/test-preflight-is-one-function.sh`](tests/test-preflight-is-one-function.sh)
asserts it structurally, by diffing the gate lines the two verbs print.

Each gate prints `ok`, `FAIL`, or **`UNKNOWN`** — and `UNKNOWN` is a verdict distinct from a
pass. A gate that cannot run says so and is counted separately in the summary. (This exists
because an earlier version, unable to *open* a dirty ext4 image, confidently reported "rootfs
has no /sbin/init" about an image that had booted minutes earlier. "I could not look" is not
"I looked and it is missing".)

`create` records a `sha256` of the kernel, and `start` **re-derives and compares it**,
refusing by name and printing both digests if the kernel has been rebuilt underneath the
instance — a version string is not an identity. `--force` is the documented way past it and
says so when used. `inspect` reports both the kernel and the rootfs source in three
outcomes: `match`, `CHANGED since create`, or `UNKNOWN` when the file is gone.

## Where it sits

| | |
|---|---|
| **rootfs from** | [`phase1-chroot`](../phase1-chroot/) — `lab-chroot.sh export-rootfs` produces exactly the ext4 image this consumes |
| **taps from** | [`examples/micro-cloud/fabric.sh`](../examples/micro-cloud/) |
| **compared with** | [`phase2-qemu-vm`](../phase2-qemu-vm/) — same lab, a full VM instead of a microVM |
| **exercised end-to-end by** | [`examples/micro-cloud/tests/test-edge-on-the-fabric.sh`](../examples/micro-cloud/tests/test-edge-on-the-fabric.sh) — boots `api1` through this tool, on a fabric tap, beside a QEMU cloud image |

## Testing

```sh
phase7-firecracker/tests/run-all.sh
```

Every test runs unprivileged and none of them boots a virtual machine — see
[`MANUAL_TESTING.md`](MANUAL_TESTING.md) for what that does and does not prove, and for a
by-hand reproduction of every defect the [2026-08-16 review](../REVIEW-phase7.md) found.

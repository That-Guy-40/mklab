# RUNBOOK — preserve a lab you liked, and restore it elsewhere

> Plan reference: [§9.5 — Preserve: two tiers, and a derivation](../../MICRO_CLOUD_LAB_PLAN.md#95-preserve--two-tiers-and-a-derivation).
> Tool: [`preserve.sh`](preserve.sh). Tests: [`tests/test-preserve-gate.sh`](tests/test-preserve-gate.sh),
> [`tests/test-preserve-round-trip.sh`](tests/test-preserve-round-trip.sh),
> [`tests/test-preserve-capability-table.sh`](tests/test-preserve-capability-table.sh).

The requirement this answers is one sentence from the user:

> *"I MAY also want to back up and preserve the labs, containers, VMs, or chroots I like."*

And the constraint the whole tool is shaped by is one sentence from §9.5:

> **A backup that cannot tell you what built it is a record that will outlive its subject.**

So a backup here is never just a tarball. It is a directory containing the artifacts **and
a `derivation.toml`** that binds each one to a `sha256`, the driver that produced it (by
digest, not by version string), the engine's version, the repo commit, and the date. A
restore re-checks all of it **before** it imports anything.

---

## The two tiers, and how to choose

| | **portable** (`--tier portable`, the default) | **fast** (`--tier fast`) |
|---|---|---|
| what it writes | the filesystem, back out to a tarball, + `derivation.toml` | an engine-native snapshot, in place |
| keeps | the bytes — reproducible, movable to another host | the engine's own notion of state |
| loses | running state **and the image's configuration** (see below) | portability: locked to this host, this engine, this version |
| phases | all six | **phases 2 and 7** — the other four refuse **by name** and say what is missing |

Pick **portable** unless you specifically want to roll a VM's disk back in place.

### The fast tier is thinner than §9.5's table suggests

> **Updated 2026-08-19.** This section read *"phase 2 only … `lab-fc.sh` has no snapshot
> verb; it is DEFERRED"* for a day after that stopped being true — `lab-fc.sh snapshot`
> landed in #236. Left visible rather than quietly rewritten, because it is the record-outlives-its-subject
> shape in this lab's own documentation: nothing errored, the paragraph was simply false. The
> **table** never was, because `capabilities` derives it by probing each driver and
> [`tests/test-preserve-capability-table.sh`](tests/test-preserve-capability-table.sh) fails
> when the two disagree **in either direction** — including this one, where a driver grows a
> verb and the tool goes on refusing the tier with a very convincing message. Derive the
> fact; don't cache it.

Only `lab-vm.sh` and `lab-fc.sh` have an engine-native snapshot verb. Ask for `--tier fast`
on a container phase and you get a refusal that names the mechanism §9.5 intends and the verb
that does not exist yet:

```console
$ ./preserve.sh save --tier fast --out /tmp/bk podman:mylab/web
[preserve.sh] REFUSED 1 — named, not skipped:
  - podman:mylab/web — no fast tier: `podman commit` — lab-podman.sh has no commit verb
[preserve.sh] nothing was preserved
```

That is an **UNKNOWN rendered as an UNKNOWN**. A tool that silently fell back to the
portable tier here would hand you a backup with no running state while you believed you had
one — which is the whole failure mode §9.5 exists to prevent, wearing a helpful face.

**And one correction to §9.5's own table:** it says the fast tier "preserves running state".
For Firecracker that is now literally true — `lab-fc.sh snapshot create` captures memory,
devices **and** the disk from one pause, and a restore resumes the guest at the captured
instant rather than rebooting it ([`RUNBOOK-fleet.md`](RUNBOOK-fleet.md)). For phase 2 it is
**not** — `lab-vm.sh snapshot create` is a `qemu-img` *internal* snapshot and the driver
refuses to take one against a running VM (it would corrupt a live disk), so what you get is
**disk state at a stopped moment**. Still useful, still non-portable, but you cannot resume
a live guest from it.

---

## Naming what to preserve

Units are `<phase>:<target>`:

| phase | target form | example |
|---|---|---|
| `chroot` | a chroot name, **or a path** | `chroot:mybase` · `chroot:/srv/trees/base` |
| `vm` | a VM name | `vm:edge` |
| `docker` `podman` `lxd` | `<lab>/<service>`, or a bare ad-hoc name | `podman:micro-cloud/metrics` |
| `fc` | a microVM name | `fc:api1` |

> **Why you list them instead of pointing at one spec.** §9.1's layout has a single
> `micro-cloud.toml` naming every instance, and `preserve.sh` would enumerate it — but that
> file does not exist yet, and writing a TOML parser against a file nobody has written, then
> testing it with fixtures of one's own invention, is a mechanism standing in for an
> outcome. Pass `--spec FILE` to record a spec's own `sha256` in the manifest; when
> `micro-cloud.toml` lands, enumeration becomes a loop over `lab_tui.topology`, which
> already parses this shape and is already tested.

---

## Walkthrough — back it up, destroy it, restore it, prove it is the same

This is §14 slice 7's exercise, and it is what
[`tests/test-preserve-round-trip.sh`](tests/test-preserve-round-trip.sh) runs unattended.

### 1. Have something worth keeping

```console
$ cat > /tmp/mylab.toml <<'EOF'
[lab]
name = "mylab"

[[service]]
name = "web"
engine = "podman"
image = "docker.io/library/busybox:latest"
manager = "plain"
command = "sleep 600"
EOF
$ phase4-podman/lab-podman.sh up --config /tmp/mylab.toml
$ podman exec lab-mylab-web sh -c 'echo I-WAS-HERE > /etc/marker'
```

The marker goes in **after** it starts, on purpose: it proves the export reads the
container's own filesystem rather than the image it was built from.

### 2. Save

```console
$ examples/micro-cloud/preserve.sh save --tier portable \
      --out ~/backups/mylab --spec /tmp/mylab.toml podman:mylab/web
[preserve.sh] portable: podman:mylab/web → podman-mylab-web.tar.gz
  - sha256 6d6726ef6df408e2…  (2227995 bytes)
[preserve.sh] manifest: /home/you/backups/mylab/derivation.toml
[preserve.sh] preserved 1/1 unit(s), tier=portable
```

`derivation.toml` now carries, for each artifact: `unit`, `phase`, `target`, `role`,
`driver` + `driver_sha256`, the `verb` used, `file`, `sha256`, `bytes`, and
`engine_version` — plus a `[derivation]` header with the date, the tool's own digest, and
the repo commit (and whether the tree was dirty when it ran).

### 3. Verify — three outcomes, never two

```console
$ examples/micro-cloud/preserve.sh verify ~/backups/mylab
  match    podman:mylab/web    filesystem    podman-mylab-web.tar.gz
1/1 match · 0 CHANGED · 0 UNKNOWN
OK: every artifact matches the derivation.
```

| verdict | exit | meaning |
|---|---|---|
| `match` | 0 | the bytes are the bytes the manifest describes |
| `CHANGED` | 1 | they are not — **both digests are printed** |
| `UNKNOWN` | 3 | the artifact could not be read. *Not* a pass, and *not* a corruption |

### 4. Destroy it

```console
$ phase4-podman/lab-podman.sh down --lab mylab
```

### 5. Restore

```console
$ examples/micro-cloud/preserve.sh restore ~/backups/mylab
… verify runs FIRST and must come back clean …
  issuing      …/lab-podman.sh build --tag mklab-restored-podman-mylab-web --backend from-tarball …
restored 1 · no import path 0 · failed 0
what came back, and what did NOT (tier 2 keeps the filesystem, not the image config):
  - podman:mylab/web → image 'mklab-restored-podman-mylab-web'.  Start it with a command,
    because the image has none: …/lab-podman.sh run --name <NEW-NAME> --image mklab-… -- <cmd>
```

### 6. Prove it is the same

```console
$ podman run --rm mklab-restored-podman-mylab-web cat /etc/marker
I-WAS-HERE
```

---

## What a restore gives you back — and what it does not

**A restore of a container phase gives you an IMAGE, not a running container.** That is a
measured property of tier 2, not a shortcut.

The drivers advertise `run --name <NEW-NAME> --tarball FILE` as the round trip, and that was tried
first. Against a real rootless podman it fails at the last inch:

```
Error: no command or entrypoint provided, and no CMD or ENTRYPOINT from image
```

`podman export` writes the **filesystem**. It does not write the OCI config, so the image
`podman import` builds back has no `CMD`, no `ENTRYPOINT`, no `ENV` and no `WORKDIR`. §9.5
says the portable tier "loses running state"; what it actually loses is running state **and
the image's configuration**. The filesystem survives the round trip; the *intent* does not.

The derivation is the right place for that intent, and **it carries it now** — TODO A.4,
closed 2026-08-20. Phases 3 and 4's `inspect` report `command`, `entrypoint`,
`entrypoint_source`, `env` and `workdir` at `schema_version: 2`; `preserve.sh save` writes
the argv into `derivation.toml`; and `restore` prints the command that starts it, filled
in from what was recorded rather than ending on a `<cmd>` placeholder you have to remember:

```
podman:api/keeper → image 'mklab-restored-podman-api-keeper'.
  Start it with the argv this backup recorded:
    phase4-podman/lab-podman.sh run --name <NEW-NAME> --image mklab-restored-podman-api-keeper -- 'sleep' '600'
  [entrypoint/command split is not restored: the image has neither, so the whole argv is
   passed as the command]
```

Three things about that, because each is a place this could have quietly lied:

* **The image still has no config.** That is a property of `export` and nothing here
  changes it. The argv is supplied at `run`, from the manifest.
* **Entrypoint and command are concatenated**, which is what the engine itself does
  (`run --entrypoint X img A B` execs `X A B`, and so does an image whose `ENTRYPOINT` is
  `X` run with command `A B`). The argv is reproduced exactly; the *split* between the two
  is not, and the line says so rather than leaving it to be discovered.
* **`env` is deliberately not recorded.** A container's environment carries values the
  engine injected for *that* container — `HOSTNAME=<its id>`, `HOME`, `container=podman`,
  all measured absent from the image — so replaying them would bake a dead container's
  identity into a new one. It is also where secrets live, and a manifest is the part of a
  backup people paste into an issue. `inspect --json` reports it live, from the container,
  for anyone who wants it.

**The original A.4 entry was wrong about two of its three phases, and the corrections are
the interesting part.** It read *"no driver reports a container's argv"* and prescribed *"a
row in phases 3/4/5's inspect"*:

* Phases 3 and 4 **did** already report `container.command` — and it was wrong in two ways
  a green suite could not see. Docker's renderer read only `Config.Cmd`, so an
  `ENTRYPOINT`-only container was reported as having **no argv at all**. Podman's read
  `Cmd // Entrypoint // []`, and since podman reports the entrypoint as a space-joined
  *string*, that field came back a **string for one image and an array for the next**.
* Phase 5 has **neither the field nor the defect**, and should not grow either. A Phase 5
  instance runs the image's own init — `lab-lxd.sh` refuses a `command` key by name for
  exactly that reason — and its `from-tarball` backend synthesises `metadata.yaml`, so a
  restored LXD image already launches. A `command` field there would report `[]` forever:
  an empty answer to a question that does not apply, which is the shape A.4 exists to
  remove rather than add.

So `docker` and `podman` moved to `schema_version: 2` and `lxd` stayed at `1`.

### The phases with no automatic import path, and why

| phase | status |
|---|---|
| `docker` `podman` `lxd` | ✅ restored to an image via the driver's `from-tarball` backend |
| `vm` | ✋ phase 2's `from-chroot` backend takes a **directory** and needs root (loop mounts, `mkfs`, `extlinux`). Extract the tarball as root, then `create --backend from-chroot --chroot <dir>` |
| `chroot` | ✋ `lab-chroot.sh` creates from debootstrap/pacstrap and has no import verb. Extract the tarball as root into a new tree |
| `fc` | ✋ `lab-fc.sh` has no import verb. The rootfs, kernel and config were all preserved; put them back and `create --config` |

Each of these is **named in the restore summary**, with the reason, rather than skipped.

---

## The gate, and why it is the point

```console
$ printf 'X' >> ~/backups/mylab/podman-mylab-web.tar.gz    # one byte
$ examples/micro-cloud/preserve.sh restore ~/backups/mylab
  CHANGED  podman:mylab/web    filesystem    podman-mylab-web.tar.gz
           expected sha256 6d6726ef6df408e2303ebd7174c3c2d3cee495a25202650b48af7f9e078271fb
           actual   sha256 4b49ebb3d9311648ad3481c08544369c66f34643eeda30032e3be9504c27f00a

restore REFUSED: the verify pass above did not come back clean (rc=1).
Nothing has been imported. Fix or re-take the backup — do not edit the digests.
```

Three things are load-bearing in that output and each cost somebody a day in
[`metal-as-a-service`](../metal-as-a-service/README.md):

1. **It names the artifact.** "Checksum failed" sends you looking; this has already told you
   which file.
2. **It prints both digests.** A version string is not an identity — that lab shipped a
   served `vmlinuz` whose `file -b` output was *identical* to the kernel rebuilt over it,
   and only the sha differed.
3. **It refuses before the import.** A gate that fires after the irreversible step is not a
   gate, it is a post-mortem.

The complementary case matters just as much: **an artifact nobody could read comes back
`UNKNOWN`, not `CHANGED` and not a pass.** "I could not look" is how an open question gets
quietly retired.

---

## Checking the tool's own claims

```console
$ examples/micro-cloud/preserve.sh capabilities
# phase	driver	portable	fast	engine
chroot	phase1-chroot/lab-chroot.sh	export-tarball	-	tar
vm	phase2-qemu-vm/lab-vm.sh	export-tarball	snapshot	qemu-img
…
```

That table is a **cached fact about six other scripts**, so it is gated rather than
trusted: [`tests/test-preserve-capability-table.sh`](tests/test-preserve-capability-table.sh)
probes each driver for the verb and fails by name when the two disagree **in either
direction** — including the quiet one, where a driver grows a verb and the tool goes on
refusing the tier with a very convincing message.

## Exit codes

| verb | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| `save` | all preserved | nothing preserved | some refused (each named) | — |
| `verify` | all match | something CHANGED | — | something UNKNOWN |
| `restore` | restored | refused by the gate, or an import failed | some units have no import path yet | — |

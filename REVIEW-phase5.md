# Review — Phase 5 (`phase5-lxd/lab-lxd.sh`)

**Date:** 2026-08-16
**Scope:** Phase 5 only — `lab-lxd.sh` (1881 LOC), its `tests/` (11 files), and
the shared harness-net checker as it applies to Phase 5. Audited for **safety**
(host damage), **soundness** (correctness/data-integrity), **security**
(isolation/injection), and **feature completeness** — the same axes and format as
[`REVIEW-phase1.md`](REVIEW-phase1.md), [`REVIEW-phase2.md`](REVIEW-phase2.md),
[`REVIEW-phase3.md`](REVIEW-phase3.md) and [`REVIEW-phase4.md`](REVIEW-phase4.md).
**Method:** the driver read end-to-end. Findings that live in the driver's own
logic (the exporter, the YAML helper, name validation) were reproduced by running
it; findings about **what the driver sends to the engine** were measured at the
argv seam with a recording shim rather than against the live daemon — see §3b for
why that boundary was drawn and exactly what it leaves unproven. Builds on
[`REVIEW-phases-1-5.md`](REVIEW-phases-1-5.md) (2026-07-08) and
[`AUDIT.md`](AUDIT.md).

---

## 1. Verdict

Phase 5 is the only phase whose suite runs **fully green with zero skips**
(**11/11 ran, 11 passed, 0 skipped, 0 failed**) — and they are not paper tests:
they launch real instances and a real VM against a live Incus and tear them down.
That is the strongest test story in the repo. The driver earns it in places: a
genuine dual-engine probe that tests whether `incus`/`lxc` actually *works for
this user, now* rather than trusting `command -v`, `--all-projects` threading so
instances outside the `default` project stay reachable (Review M5), a jq filter
that uses `startswith`/`ltrimstr` instead of building a regex from a user string
(M-4), `LAB_STATE_DIR` validated for absoluteness and `..` **before** anything can
`rm -rf` through it (L-3), `--no-absolute-names` on every tarball extraction
(H-3), `os-release` parsed with awk instead of sourced (H-1), and a deliberate
subshell+EXIT-trap shape in all four backends chosen precisely so a `die` still
reclaims the loop device *and* cannot clobber `cmd_up`'s rollback trap.

The residue is **five defects**, all reproduced. The largest is not an injection
at all — it is that Phase 5's two descriptions of a lab have almost nothing in
common:

- **P5-1 (MED)** — ✅ **FIXED 2026-08-16.** `export --format compose` and `up` describe **disjoint labs**.
  The exporter emits four instance fields `up` **silently ignores**, drops nine
  that decide what the instance actually is, and overlaps on three.
- **P5-2 (MED)** — ✅ **FIXED 2026-08-16** (the L1 half in #209, the exporter in this pass). `_yaml_str` here never received the **Review L1** fix that
  Phases 3 and 4 both carry, and the exporter hand-rolls `"%s"` instead of calling
  even its own helper. Measured: **0 of 8** config fields round-trip; 2 inject a
  resolved compose attribute, 6 produce a file compose refuses.
- **P5-3 (LOW/MED)** — ✅ **FIXED 2026-08-16.** `down` reports
  `── lab 'x' torn down ──` and exits **0** when the engine refused **every** stop and
  delete, and removes the cached spec anyway. It now re-queries `_instances_in_lab`
  after the loop, names each survivor with its project, **keeps the cached spec while
  an instance remains**, and exits non-zero. Regression:
  [`tests/test-down-reports-refusal.sh`](phase5-lxd/tests/test-down-reports-refusal.sh).
  See [§7](#7-resolution-of-p5-3-2026-08-16).
- **P5-4 (LOW/MED)** — ✅ **FIXED 2026-08-16.** `[[project]]` and `[[profile]]` names are never validated,
  while `[lab]` and `[[instance]]` names are; they reach the engine as **flags**.
- **P5-5 (LOW)** — ✅ **FIXED 2026-08-16.** The `image` positional has no `-`-leading guard (Review M1 is
  in Phase 3 only). It reaches the engine's flag parser; the reason it does not
  bite is an accident of argument order, not a guard.

Phase 5 addresses instances by validated name and label, never by path or PID, so
neither Phase 1's **P1-1** nor Phase 2's **P2-2** class exists here.

---

## 2. Findings

### P5-1 — MED — `export --format compose` and `up` describe disjoint labs — ✅ FIXED 2026-08-16

Phase 5's TOML is read by two consumers that were written against different
mental models of the schema, and nothing reconciles them. Enumerating the
`[[instance]]` fields each one actually reads — `spec_get "$inst" X` and `jq '.X'`
both counted, over `cmd_up`'s instance loop (lines 957–1098) and `cmd_export`'s
compose loop (lines 1683–1715):

| | fields |
|---|---|
| consumed by `up` | `config`, `devices`, `engine`, `from_chroot`, `from_qcow2`, `from_tarball`, `image`, `name`, `profiles`, `project`, `storage`, `type` |
| emitted by `export` | `command`, `environment`, `image`, `name`, `ports`, `type`, `volumes` |
| **emitted but never consumed** | **`command`, `environment`, `ports`, `volumes`** |
| **consumed but never emitted** | **`config`, `devices`, `engine`, `from_chroot`, `from_qcow2`, `from_tarball`, `profiles`, `project`, `storage`** |
| overlap | `image`, `name`, `type` |

Both halves are defects, in opposite directions:

- The four **invented** fields are accepted silently by `up` and do nothing.
  `.ports` appears exactly once in the whole driver — line 1698, inside the
  exporter. A user who writes `ports = ["8080:80"]` in a Phase-5 topology gets no
  port mapping, no proxy device, and **no warning** — and then an exported compose
  file asserting the mapping exists.
- The nine **dropped** fields are the ones that decide what the instance is.

**Reproduced end-to-end** with one TOML carrying both kinds of field:

```
# 1. what `up` actually sent to the engine
incus launch -c user.lab-create.tool=lab-lxd … -c limits={"memory":"512MiB"} \
       images:alpine/3.23 lab-p5both-web
incus config device add lab-p5both-web extra disk source=/srv path=/mnt
    → ports / volumes / environment appear 0 times

# 2. what `export --format compose` says the same lab is
  "web":
    image: images:alpine/3.23
    ports:
      - "8080:80"          ← never applied
    environment:
      GREETING: "hello"    ← never applied
    volumes:
      - "/srv:/data"       ← never applied
                           ← and no limits.memory, no `extra` disk device
```

The exporter's own header is honest but incomplete: *"LXD-specific fields
(profiles, project, storage) are not representable in compose YAML and are
omitted."* That names **three of the nine** dropped fields and **none of the four**
invented ones.

**Fix direction:** two independent changes. (a) `up` should **refuse or warn on
unknown instance keys** — a topology that sets `ports` is expressing an intent the
tool cannot honour, and silence is the wrong answer; LXD's equivalent is a `proxy`
device, so the useful version is a clear error naming it. (b) The exporter should
emit only what it can faithfully represent and **say what it dropped**, listing
the fields rather than a fixed three. Given the overlap is three fields, it is
worth asking whether a compose export belongs in Phase 5 at all — the `lxc-yaml`
format is the faithful one, and it is derived from the *engine*, not from a spec
file that may no longer describe reality.

### P5-2 — MED — `_yaml_str` never got Review L1, and the exporter mostly bypasses it — ✅ FIXED 2026-08-16

The repo's self-containment rule duplicates helpers into every phase. `_yaml_str`
exists three times, and the Review L1 fix — *escape backslash **first**, then the
double-quote, so a value ending in `\` cannot break out* — landed in two of them:

```sh
phase3-docker/lab-docker.sh:1317  _yaml_str() { local s="${1//\\/\\\\}"; printf '"%s"' "${s//\"/\\\"}"; }
phase4-podman/lab-podman.sh:1821  _yaml_str() { local s="${1//\\/\\\\}"; printf '"%s"' "${s//\"/\\\"}"; }
phase5-lxd/lab-lxd.sh:1649        _yaml_str() { printf '"%s"' "${1//\"/\\\"}"; }
```

Measured on the same input — and the difference is not cosmetic:

```
phase 3  _yaml_str(C:\path\)  →  "C:\\path\\"     YAML parses  → 'C:\path\'
phase 4  _yaml_str(C:\path\)  →  "C:\\path\\"     YAML parses  → 'C:\path\'
phase 5  _yaml_str(C:\path\)  →  "C:\path\"       YAML PARSE ERROR
```

Worse, the exporter mostly does not call it. Ports, volumes and environment
*values* are hand-quoted with a bare format string, which escapes nothing at all:

```sh
printf '      - "%s"\n'      "$p"     # 1697  ports
printf '      %s: "%s"\n'    "$kk" "$vv"   # 1704  env key RAW, value hand-quoted
printf '      - "%s"\n'      "$vol"  # 1711  volumes
printf '    image: %s\n'     "$simage"   # 1691  raw
printf '    command: %s\n'   "$cmdline"  # 1714  raw
```

So Phase 5 is the weakest of the three exporters. Same sweep as
[`REVIEW-phase3.md`](REVIEW-phase3.md) P3-2 and
[`REVIEW-phase4.md`](REVIEW-phase4.md) P4-5, asserting on the attribute
`docker compose config --format json` **resolves** rather than on the text:

| outcome | n | fields |
|---|---|---|
| injects an attribute the TOML never declared | 2 | `instance.image`, `instance.command` |
| corrupts — valid TOML in, compose refuses the output | 6 | `instance.name`, `ports[]`, `volumes[]`, env key, env value, `network.driver` |
| **round-trips unchanged** | **0** | — |

Phase 3 had 2 survivors of 14 and Phase 4 had escaped values; Phase 5 has none.

**Fix direction:** bring `_yaml_str` to parity with its two siblings (it is a
one-line change, already written twice), route **every** scalar through it, and
reject control characters. The deeper point is the duplication itself: one fix,
three copies, applied twice. Phase 4 owns the right primitive for the last part in
`sanitize_unit_value`; a shared `tools/` helper with one test would end this class,
at the cost of the self-containment rule — a trade worth stating explicitly rather
than rediscovering per phase.

### P5-3 — LOW/MED — `down` reports success when the engine refused every removal — ✅ FIXED 2026-08-16

`cmd_down` discards the outcome of both operations (lines 1131–1132) and then
announces success unconditionally:

```sh
"$LXC_CMD" stop   "${scope[@]}" "$iname" --force >/dev/null 2>&1 || true
"$LXC_CMD" delete "${scope[@]}" "$iname" --force >/dev/null 2>&1 || true
…
rm -rf -- "$_lab_dir"
log_info "── lab '$lab_name' torn down ──"
```

**Reproduced** with an engine stand-in that refuses **every** `stop` and `delete`
with a non-zero exit and an error on stderr — the strongest possible failure
signal:

```
$ lab-lxd.sh down --lab p5d
[info] ── tearing down lab 'p5d' ──
[info] stop+delete lab-p5d-web
[info] ── lab 'p5d' torn down ──          ← rc=0
spec.toml still there?  NO — deleted anyway
```

Nothing survived the report: the instance is still there (the engine said so, in
the exit status the code threw away), the operator is told the lab is gone, and
the cached `spec.toml` — which `export --format compose` requires — is removed, so
the lab can no longer be exported either. This is the third phase with this exact
shape (P3-3, P4-6), which makes it a house pattern rather than an oversight.

**Fix direction:** re-query `_instances_in_lab` after the loop and name what
survived; make the state-dir removal conditional on that list being empty. `down`
need not fail hard, but it must not call a refused teardown *torn down*.

### P5-4 — LOW/MED — `[[project]]` and `[[profile]]` names are never validated — ✅ FIXED 2026-08-16

`cmd_up` validates the lab name (line 900) and every instance name (line 962),
with the comment *"L-2: validate before using in instance names, labels, and
device specs."* Project and profile names get no such treatment — `ensure_project`
checks only non-emptiness, and `ensure_profile` only that a name exists (line 748)
— yet both are used identically: as positionals to engine subcommands that also
take flags.

**Measured at the argv seam**, with the engine replaced by a recorder:

```
incus project create -p--force -c features.profiles=false -c features.storage.volumes=false
incus project set    -p--force user.lab-create.tool lab-lxd
incus profile create -x
```

**Control** — the identical string in a field that *is* validated:

```
$ lab-lxd.sh up --config prof2.toml     # [lab] name = "-p--force"
[error] invalid lab name '-p--force': use only [a-zA-Z0-9._-], start with alphanumeric, max 63 chars
```

So the validation exists, is understood, and is simply not applied to two of the
four name kinds. What the engine then does with `-p--force` is its own flag
parsing — no privilege change was demonstrated (see §3b), and the honest
description is a validation asymmetry with an engine-level consequence, not a
proven exploit.

**Fix direction:** `validate_name "$pname" "profile name"` / `"project name"` in
the same up-front loop that already validates instance names, so all four name
kinds are checked in one place before any write.

### P5-5 — LOW — the `image` positional has no `-`-leading guard — ✅ FIXED 2026-08-16

Review M1 — *"the image is the first POSITIONAL, so an `image = "--privileged"` in
a TOML would inject flags"* — is implemented in Phase 3's `run` **and** `up`,
absent from Phase 4 (**P4-1**, where it produced a live privileged container), and
absent here too. Phase 5 has the idea: `cmd_inspect` explicitly refuses a target
starting with `-` (line 1363). The launch path does not.

**Measured:**

```
$ cat img.toml   # image = "--device=disk,source=/,path=/host"
$ lab-lxd.sh up --config img.toml
incus launch -c user.lab-create.tool=lab-lxd … --device=disk,source=/,path=/host lab-p5img-web
```

The value arrives in argv as a flag, and `incus launch` genuinely accepts
`-d, --device` (confirmed from `--help`). **But the impact stops there, for a
reason worth recording precisely:** `incus launch`'s usage is
`launch <image> [<name>]`, so the injected flag consumes the image slot,
`lab-p5img-web` is then read as the *image*, no such image exists, and the launch
fails. Unlike Phase 4 — where the `command` field supplied a second positional to
serve as the image — **Phase 5's `cmd_up` never reads a `command` field at all**
(confirmed by the field analysis in P5-1), so there is no second positional to
complete the injection.

That is a mitigation by argument order, not by design. It would evaporate the day
someone adds a `command` field to the schema, or if the instance name happened to
name a real local image alias.

**Fix direction:** port the M1 guard, and prefer `launch -- "$image" "$iname"`
where the CLI supports `--`, so the positional cannot be re-read as an option.

---

## 3. Minor / robustness (not standalone findings) — ✅ ALL FOUR FIXED 2026-08-16

- **`cmd_run` does not validate `--name`.** Phase 3 calls
  `validate_name "$name" "container name"`; Phases 4 and 5 call nothing.
  `cmd_run` builds `instance_name_for "${OPT_LAB:-adhoc}" "$name"` and three label
  values from it. Third instance of the same asymmetry across the container
  phases.

- **An unquoted dotted key in `[instance.config]` becomes a nested object.**
  Measured:
  ```
  [instance.config]        →  {"limits":{"memory":"512MiB"}}   → -c limits={"memory":"512MiB"}
  limits.memory = "512MiB"
  "limits.memory" = "512MiB"  →  {"limits.memory":"512MiB"}    → -c limits.memory=512MiB   ✓
  ```
  `to_entries` is flat, so the nested form yields a `-c` argument the engine will
  reject with a confusing message rather than the driver saying "config keys must
  be quoted". **Not a broken recommendation** — I checked, and *every* example and
  doc in the repo uses the quoted inline-table form
  (`config = { "limits.memory" = "256MiB" }`), which is correct
  ([`examples/lxd-examples/lxd-mixed-topology.toml`](examples/lxd-examples/lxd-mixed-topology.toml),
  [`SHOWCASE.md`](phase5-lxd/SHOWCASE.md),
  [`START_HERE_LXC_WIZARD.md`](phase5-lxd/START_HERE_LXC_WIZARD.md)). Recursively
  flattening `config` in jq, or detecting an object-valued entry and naming the
  fix, would close the gap between the documented spelling and the natural one.

- **A comment credits a guard that isn't in that function.** `cmd_inspect`'s line
  1368 reads *"M-1: validate_name above rejects targets starting with '-'"* —
  there is no `validate_name` call in `cmd_inspect`; the actual (correct) guard is
  the explicit `[[ "$target" != -* ]]` five lines earlier at 1363. The protection
  is real, the attribution is not, and a future edit that "removes the redundant
  check because validate_name handles it" would silently reopen M-1.

- **One pipe-gated verdict** at line 1081:
  `config device list … | grep -qx "$dname"` decides whether a device is added.
  Same latent class measured in Phase 3 §3 (fails open only past the 64 KiB pipe
  buffer). Far less reachable here than in Phases 3/4 — the producer is one
  instance's device list, not every container on the host — so this is inventory,
  not a live concern.

## 3b. Not verified by this pass — UNKNOWN, not PASS

**No live engine writes were performed by this audit.** That is a deliberate
boundary, and it bounds four of the five findings:

- The host runs a live Incus with a Calico-backed topology, and this reviewer
  cannot `sudo` — so a wedged daemon could not be recovered
  (`sudo systemctl restart incus`). Findings about **what the driver sends** were
  therefore measured at the **argv seam** with a recording shim. That is the right
  seam for a flag-injection question — the driver's job ends at argv — but it
  proves only what is *sent*, **not what the engine does with it**. Specifically
  unproven: whether `incus project create -p--force` (P5-4) does anything harmful,
  and whether the P5-5 launch fails exactly as the usage string implies.
- Worth stating against my own caution: **Phase 5's own suite does perform live
  writes** — it launches instances, creates profiles and projects, builds a VM, and
  tears them all down — and it passed 11/11 during this audit. So the engine is
  healthy and these paths are exercised by CI; they were simply not exercised *by
  me* with hostile inputs.
- **The VM backends were not exercised.** `backend_from_chroot_vm` and
  `backend_from_tarball_vm` require `EUID=0` (loop mounts, `mkfs`, `extlinux`), so
  the partitioning, the extlinux config, the MBR `dd`, and the raw→qcow2 conversion
  are all unmeasured here. The suite's `test-vm-lifecycle.sh` covers the *launch*
  of a VM, not these root-only image builds.
- **The `from-chroot` / `from-tarball` import paths** were read, not run: they
  need a Phase-1 chroot and perform an `image import` write.

## 4. Investigated and cleared (so it is not re-raised)

- **The subshell + EXIT trap in all four backends.** This looks like the
  EXIT-trap violation `tools/check-harness-net.sh` forbids, and is not: that rule
  governs *tests* clobbering `lib.sh`'s verdict net. Here the shape is deliberate
  and the comment explains it — a `RETURN` trap would not fire on `die` (which is
  `exit`), leaking a loop device and a 20 GB raw file, and a *function-scope* EXIT
  trap would clobber `cmd_up`'s partial-up rollback. A subshell-local EXIT trap
  fires on every exit and cannot escape. Correct as written.
- **`_resolve_distro_latest`'s jq filter (M-4).** Uses
  `startswith($d + "/")` / `ltrimstr` rather than interpolating the distro into
  `test()`. The comment's example is right: `alp.ne` would otherwise match
  `alpXne/3.21` through the regex wildcard. No injection.
- **`cmd_list`'s `grep -c . || true` (M-6).** Correct and necessary: `grep -c`
  exits 1 on a zero count, which under `set -e` would kill `list` on an empty
  result. The `|| true` preserves the printed `0` while neutralizing the status.
- **`LAB_STATE_DIR` handling (L-3).** Validated absolute and `..`-free at load
  time, and `cmd_down` additionally `realpath -m`s the lab dir and asserts the
  `$LAB_LXD_STATE_DIR/` prefix before `rm -rf`. Two independent guards on the one
  destructive path; neither is redundant.
- **My hypothesis that the documented config-key spelling was broken.** After
  finding `-c limits={"memory":"512MiB"}` in a live argv I suspected the repo's own
  examples were producing it. They are not — every example and wizard uses the
  quoted inline-table form, which flattens correctly. The defect is narrower than
  it first looked, and is recorded in §3 at that narrower size.

## 5. Feature completeness

Phase 5's surface is coherent and genuinely dual-engine: `incus` preferred with an
`lxc` fallback, chosen by probing which one *works* rather than which is
installed; four image sources (upstream with a `latest`→highest-stable-alias
resolver that LXD does not provide natively, from-chroot, from-tarball,
from-qcow2 as the documented Phase-2 bridge); containers **and** VMs; projects and
profiles as first-class TOML blocks; `--all-projects` threading throughout so
instances outside `default` remain reachable by `exec`/`logs`/`status`/`destroy`
(M5); `inspect --json` at `schema_version=1` for Phase 6; and two export formats.
Limitations are stated in-code with reasons (VM builds are x86_64/BIOS/extlinux
and root-only; `--follow` has no LXD equivalent for the log buffer). The
`compose` export format is the one piece whose value is questionable — see P5-1.

## 6. Calibration — good patterns preserved

The engine probe is the standout, and it is exactly the outcome-over-mechanism
discipline this repo preaches: `have incus` would answer "is the binary present",
so `probe_engine` instead runs `incus info` and `lxc info` and asks *which one
actually works for this user, now* — then, when both fail, prints **each** engine's
real error plus the specific `systemctl`/`usermod` fix rather than a generic
"daemon unreachable". `resolve_image` is honest about a real upstream gap (there
is no `latest` alias) and solves it by querying rather than guessing. The
`--all-projects` work (M5) fixed a whole class of "works in default, invisible
elsewhere" bugs at every verb at once. `tar` is deliberately **not** given `-h`,
with the reasoning recorded — dereferencing would bake host files into the image
through absolute symlinks *and* abort on a dangling `/etc/resolv.conf`. And the
suite is the repo's best: eleven tests, zero skips, real instances and a real VM
created and destroyed — which is why this review had to go looking with hostile
inputs and a shim to find anything at all.

---

## 7. Resolution of P5-3 (2026-08-16)

`cmd_down` now re-queries `_instances_in_lab` after the stop/delete loop. If anything
survived it names each instance (with its project, where that is not `default`), keeps
the cached `spec.toml`, and returns non-zero rather than announcing success.

This was the third phase with the identical shape (P3-3, P4-6, P5-3), and all three now
carry the same rule: **a record must not outlive its subject, and must not predecease it
either.** Deleting the cached spec while the instance is still running is the second
half of the bug — the lab becomes un-exportable, with an error blaming the operator for
not using `up --config`, which is exactly what they did.

### Why the test drives a stand-in engine, and why that is the right seam

The question is *"what does `down` do when the engine refuses?"*, and a real daemon
cannot be made to refuse on demand. A stand-in is not a weaker substitute here; it is
the only way to ask the question deterministically. It is a real implementation of the
real interface (`info`, `list --all-projects --format=json`, `stop`, `delete`), so the
driver runs its real code path through it — no special-casing inside `lab-lxd.sh` — and
`delete` removes a name from the stand-in's world only when it *succeeds*, so "what
survived" is a consequence of what the engine did rather than something the test asserts
into place.

It also keeps this test off the real daemon, which matters: **an untestable path is how
P5-3 stayed open in the first place.**

**Negative control.** Against the pre-fix driver the test reproduces the finding's
transcript exactly — `stop+delete lab-p5dwn-web`, then `── lab 'p5dwn' torn down ──`,
rc=0, spec deleted. The test also guards its own fixture: `down` exits 0 both when the
engine refuses (the bug) and when it simply found nothing to do (a stand-in that was
never consulted) — opposite facts with the same rc — so it asserts the driver actually
reached the instance before reading anything into the exit status. A final control runs
an *empty* lab and requires a clean teardown, so "reports a partial teardown" cannot be
true of every run.

### The live half of §3b is now closed too

This review's live coverage was previously limited on the audit host because
`test-profiles-projects.sh` performs incus **profile writes**, which are recorded as
wedging the daemon here with recovery needing a `sudo systemctl restart` the agent
cannot perform. Re-derived 2026-08-16: incus is reachable, with a `zfs` storage pool and
a `default` profile carrying root+eth0 — so the *rest* of the suite runs live. **12 of
13 tests now pass against the real daemon**, including `test-container-lifecycle.sh` and
`test-vm-lifecycle.sh`, which create and destroy a real container and a real VM.

That matters for this fix specifically: the re-query introduces a way to report a
**false partial teardown** if `incus delete --force` were asynchronous — the failure
mode a stand-in cannot detect. It is not: a real instance created and destroyed live
reports `torn down`, rc=0.

**Closed the same day — 13 of 13 now run live.** `test-profiles-projects.sh` was the
last holdout, deferred because incus **profile writes** are recorded in this agent's notes
as wedging the daemon, with recovery needing a `sudo systemctl restart` it cannot perform.
The user ran it unprivileged; it **passed**, and the daemon did not wedge — nor on a second
run afterwards. That cached fact is now doubtful and has been demoted to "not reproduced
on incus 7.3 for `project create` / `profile create` / `profile set`".

It also supplied the measurement this section had recorded as a *reading*: the fix's
project path. `down` deleted an instance living in a **non-default project**
(`stop+delete lab-…-m (project=ppp…)`) and then reported `torn down`, rc=0 — so the
re-query does not raise a **false partial teardown** for a successfully-removed
project-scoped instance, which is the one way this fix could have made things worse and
the one a stand-in cannot see.

### And the run surfaced a defect nothing in the suite could see

Passing is not the same as clean. The run printed, twice, into the operator's terminal:

```
Warning: the "<key> <value>" syntax is deprecated; please switch to the "<key>=<value>" syntax
```

`ensure_project` and `ensure_profile` used the positional `set <target> <key> <value>`
form, which incus' own help keeps only "for backward compatibility" — a path that works
today, warns today, and stops working on a future release. **No existing test could catch
it, and no better test of the usual kind would have:** every assertion here is about the
lab that got built, and the lab is byte-identical either way. The defect lives only in the
argv.

So the regression is asserted at the argv seam with a recording shim
([`tests/test-config-set-syntax.sh`](phase5-lxd/tests/test-config-set-syntax.sh)) — the
rare case where the mechanism *is* the property, because the two spellings differ in
nothing except which one is scheduled for removal. It needs no daemon, carries a control
that plants both deprecated shapes and requires the same parser to reject them **and**
accept two correct ones (so it cannot pass by over-firing), and covers a value containing
`=` (splitting is on the first `=`). Verified live: the same test that emitted two
warnings now emits **zero**.

### Found on the way: a flaky test, and a premise that was never measured

Running the live suite surfaced `test-from-chroot-symlink.sh` failing once in five runs
and passing on every re-run — the flake nobody can reproduce. It was not this change:
lines 71–72 read

```sh
tar tzvf "$captured" | grep -q 'rootfs/etc/hostlink ->' || fail "…"
```

which is the SIGPIPE inversion this repo has recorded five times, in the *noisy*
direction. `tools/tests/test-no-pipe-gates.sh` **saw** these sites and deliberately did
not gate them, on the stated grounds that the form "only bites with a producer big
enough to fill a pipe buffer."

**That premise is false, and it was reasoning rather than measurement.** The 64 KiB
threshold applies to a producer that writes once (real `docker ps` does — which is why
the Phase 3 driver gates were genuinely latent). A producer that *streams* is still
writing after `grep` exits, however little it produces in total. Measured on a **13 KB**
`tar tzvf` listing — one fifth of the pipe buffer:

| shape | spurious failures |
|---|---|
| `tar tzvf f.tgz \| grep -q 'x ->'` | **140 / 200** |
| `out="$(tar tzvf f.tgz)"; grep -q …` | 0 / 200 |

All **8** remaining sites repo-wide were converted to capture-then-test, and the checker
now **gates** the noisy form instead of counting it — and re-derives the premise on every
run against a streaming fixture, failing loudly if the inversion ever stops reproducing,
so the gate can never quietly become a defence against nothing.

---

## 8. Resolution of P5-1, P5-2, P5-4, P5-5 and §3 (2026-08-16)

With P5-3 closed earlier the same day, this completes REVIEW-phase5. Suite:
**16/16 ran, 16 passed, 0 skipped, 0 failed** — every test live against the real Incus,
including container and VM lifecycle.

### 8.1 What changed

| item | change | regression test |
|---|---|---|
| **P5-1a** | `validate_instance_keys` refuses any `[[instance]]` key `up` does not consume, naming LXD's real equivalent | `test-argv-injection-guards.sh` |
| **P5-1b** | the exporter emits only representable fields and prints a per-instance `# dropped:` line **derived from the spec** | `test-export-hardening.sh` |
| **P5-2** | every scalar through `_yaml_str`, which gained the control-character path its siblings have | `test-export-hardening.sh` |
| **P5-4** | `validate_name` on project and profile names, in the same up-front pass as lab and instance names | `test-argv-injection-guards.sh` |
| **P5-5** | `validate_image_ref` + `launch -- "$image" "$iname"` on both launch paths | `test-argv-injection-guards.sh` |
| **§3** `--name` | `cmd_run` validates its instance name (the third phase to need it) | — |
| **§3** dotted keys | `config` tables are flattened recursively, so the quoted and unquoted spellings agree | `test-argv-injection-guards.sh` |
| **§3** attribution | the comment crediting `validate_name` in `cmd_inspect` now credits the explicit check that actually guards it | — |
| **§3** pipe gate | the device-list verdict captures first, tests second | — |
| *(also)* | the engine gate moved into the `lxc-yaml` branch, so `--format compose` needs no daemon | `test-export-hardening.sh` |

### 8.2 P5-1 was a schema question, and the blast radius decided it

The review offered *"refuse or warn"*. Refusing is the stronger answer and it was safe to
choose, but only because that was **checked before editing**: every `[[instance]]` key in
all **40** shipped specs was enumerated first, and not one uses `ports`, `environment`,
`volumes` or `command`. Nothing in the repo changes behaviour; the four fields were
accepted-and-ignored by `up` and emitted-as-if-real by `export`, and nobody had ever
written one.

Keying the gate off a **known-good list** rather than a blacklist of those four is what
makes it worth having: a typo like `imagee` is now refused too, where before it was
silently dropped.

The exporter's counterpart is the honest half. It used to carry a fixed header naming
*"profiles, project, storage"* — three of the nine fields it actually dropped. It now
derives the list per instance:

```yaml
  "web":
    image: "images:alpine/3.21"
    container_name: "lab-demo-web"
    # dropped: config, profiles, project, storage  (no compose equivalent — see --format lxc-yaml)
```

The review asked whether a compose export belongs in Phase 5 at all. It is kept, because
removing a shipped feature is the user's call and not a reviewer's — but the file now
states plainly what it is not, and points at `--format lxc-yaml`, which is read from the
**engine** rather than from a spec file that may no longer describe reality.

### 8.3 Negative controls

Both new tests were watched failing against the pre-fix driver:

| test | verdict against the pre-fix driver |
|---|---|
| `test-argv-injection-guards.sh` | FAIL — `up` accepted a flag-shaped `[[project]]` name |
| `test-export-hardening.sh` | FAIL — a newline in `image` injected a resolved `privileged: true` |

**Three of this pass's own assertions were wrong before they were right**, and each was
caught by running rather than reading. They are recorded because the pattern is the point:

1. **The stand-in answered `info <instance>` with success**, so the driver believed the
   instance already existed, logged *"leaving as-is"*, and never reached the launch — the
   image assertion then failed while **blaming the driver for the fixture's defect**. The
   test now guards its own fixture: if that message appears, it says so instead of
   reporting a regression.
2. **The `# dropped:` control matched the file header.** The header explains what a
   `dropped:` line *is*, so an unanchored `grep 'dropped:'` matched every export — the
   control failed against a correct driver. Anchored to the emitted line.
3. **`device add` takes the device type POSITIONALLY** (`data disk source=…`), not as
   `type=disk`. The assertion was wrong; the driver was right.

Each is the same shape the reviews keep finding in the code — a check that reads as
evidence while measuring something adjacent — committed while writing checks for it.

### 8.3b The fix that CI caught, and my local check that could not have

Two of this pass's edits were written by a script that hit an assertion **before** its
`write_text` — so they silently never landed, while every later step reported success:

- `_yaml_str` never got the control-character path.
- The old top-level `require_lxd_or_incus` was never removed, so `--format compose` still
  demanded a daemon.

Both survived the local suite, for instructive reasons.

**The gate**: my "no engine on PATH" check ran with `PATH="$T/bin:/usr/bin:/bin"`, and
`/usr/bin` holds a working `incus`. The check could not have failed. CI — which has a
**broken `lxc` snap wrapper and no daemon** — is what found it. Re-verified afterwards
against a genuinely engine-free `PATH`.

**The escaping**: a raw newline inside a double-quoted YAML scalar does **not** inject a
sibling key — YAML *folds* it. So the real failure was not injection but silent
**corruption**: the value returned with its newlines and indentation flattened to single
spaces. The test asserted "no injection" and two substrings, both of which survive
folding, so it went green over an unescaped emitter. The assertion now demands the value
come back **byte-identical**, and was watched failing against the one-line `_yaml_str`
before being kept.

That is the same defect as §8.3's three, one layer up: a check that measured something
adjacent to the property and read as evidence for it.

### 8.4 Still UNKNOWN

§3b's boundaries mostly stand, and are narrower than they were:

- ~~**The VM image backends** (`backend_from_chroot_vm`, `backend_from_tarball_vm`) still
  require `EUID=0` for loop mounts, `mkfs` and `extlinux`, so the partitioning, the MBR
  `dd` and the raw→qcow2 conversion are unmeasured. `test-vm-lifecycle.sh` covers a VM's
  **launch**, not these builds.~~

  > ✅ **CLOSED 2026-08-16 — measured on hardware, and running the code found two real
  > defects the audit could not have read.**
  > [`tests/test-vm-image-build.sh`](phase5-lxd/tests/test-vm-image-build.sh) builds real
  > images and asserts the **artifact**, never the steps. It intercepts at
  > `backend_from_qcow2` — an existing function boundary, and the only step needing a live
  > engine — so everything this bullet named runs for real without a daemon. Root-gated;
  > self-skips otherwise, and CI's runner has passwordless sudo (phase 4's root tests run
  > there), so it runs in CI too.
  >
  > **The driver was correct on all four things this bullet listed.** The first 440 bytes
  > are byte-identical to `mbr.bin`; the label is msdos with exactly one bootable primary;
  > `qemu-img info` confirms a real qcow2; and the **UUID chain holds** — `/etc/fstab` and
  > `extlinux.conf`'s `root=UUID=` both name the filesystem that is actually on the image.
  > That last one had never been compared by anything, and its failure mode is a kernel
  > panic on someone else's machine.
  >
  > **What the run found instead was in the paths around it, and both were invisible to
  > reading:**
  >
  > 1. **`--no-absolute-names` is not a GNU tar option.** It is a bsdtar/libarchive
  >    spelling; GNU tar 1.35 answers `unrecognized option` and exits 64. It was on **both**
  >    tarball paths — the VM one and the **container** one — so `from_tarball` was broken
  >    on every GNU-tar host. Two reviews, this one included, had credited the flag as
  >    hardening (H-3) and neither had ever executed it. Removing it loses nothing:
  >    measured, GNU tar strips a leading `/` and **refuses** a `../` member by default. The
  >    property was already the default; the flag was only a way to break the command.
  > 2. **`( … ) || die` silently disables `set -e` inside the subshell** — bash suppresses
  >    errexit for the left operand of a `||` list and the suppression propagates in. So the
  >    failing `tar` did not stop the build: it continued and reported *"no `/boot/vmlinuz-*`
  >    found"* about a tarball that had one, blaming a step three later. Every remedy was
  >    **measured, and the obvious ones do not work** — re-issuing `set -e` inside, an `ERR`
  >    trap inside, and `if ! ( … )` all still leak past. Per-command `|| die` is the guard,
  >    which is what **Phase 2's equivalent subshell has always had**; Phase 5's VM path had
  >    none. Guarded now by §7b, with the fault injected at `extlinux --install` —
  >    deliberately *not* the last command, since the last one propagates anyway and a test
  >    that broke only that would pass against the defect.
  >
  > **Two of the test's own assertions were wrong first, both caught by running it.** A
  > leaked-workdir scan used `find "$tmp" -maxdepth 1`, which yields the start directory —
  > and `$tmp` is itself a `mktemp -d`, so it matched every time and could never pass; it
  > reported a leak against a driver that had cleaned up correctly. And a drafted
  > absolute-path-tar assertion **could not fail in either direction**, because GNU tar
  > strips the leading `/` by default; it was deleted rather than shipped as coverage, with
  > the reason recorded in the file.
- **What the engine does with a flag-shaped name** was never the question this driver
  owns, and remains untested by choice: the guards now refuse those values before argv,
  so the engine never sees them.
- No longer unknown: the live paths. All 16 tests run against the real daemon.

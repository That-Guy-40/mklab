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

- **P5-1 (MED)** — `export --format compose` and `up` describe **disjoint labs**.
  The exporter emits four instance fields `up` **silently ignores**, drops nine
  that decide what the instance actually is, and overlaps on three.
- **P5-2 (MED)** — `_yaml_str` here never received the **Review L1** fix that
  Phases 3 and 4 both carry, and the exporter hand-rolls `"%s"` instead of calling
  even its own helper. Measured: **0 of 8** config fields round-trip; 2 inject a
  resolved compose attribute, 6 produce a file compose refuses.
- **P5-3 (LOW/MED)** — `down` reports `── lab 'x' torn down ──` and exits **0**
  when the engine refused **every** stop and delete, and removes the cached spec
  anyway.
- **P5-4 (LOW/MED)** — `[[project]]` and `[[profile]]` names are never validated,
  while `[lab]` and `[[instance]]` names are; they reach the engine as **flags**.
- **P5-5 (LOW)** — the `image` positional has no `-`-leading guard (Review M1 is
  in Phase 3 only). It reaches the engine's flag parser; the reason it does not
  bite is an accident of argument order, not a guard.

Phase 5 addresses instances by validated name and label, never by path or PID, so
neither Phase 1's **P1-1** nor Phase 2's **P2-2** class exists here.

---

## 2. Findings

### P5-1 — MED — `export --format compose` and `up` describe disjoint labs

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

### P5-2 — MED — `_yaml_str` never got Review L1, and the exporter mostly bypasses it

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

### P5-3 — LOW/MED — `down` reports success when the engine refused every removal

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

### P5-4 — LOW/MED — `[[project]]` and `[[profile]]` names are never validated

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

### P5-5 — LOW — the `image` positional has no `-`-leading guard

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

## 3. Minor / robustness (not standalone findings)

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

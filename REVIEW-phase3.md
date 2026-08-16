# Review — Phase 3 (`phase3-docker/lab-docker.sh`)

**Date:** 2026-08-16
**Scope:** Phase 3 only — `lab-docker.sh` (1651 LOC), its `tests/` (17 files), and
the shared harness-net checker as it applies to Phase 3. Audited for **safety**
(host damage), **soundness** (correctness/data-integrity), **security**
(isolation/injection), and **feature completeness** — the same axes and format as
[`REVIEW-phase1.md`](REVIEW-phase1.md) and [`REVIEW-phase2.md`](REVIEW-phase2.md).
**Method:** the driver read end-to-end; every finding reproduced against a **live
Docker daemon** (this pass had one reachable, so the container paths were
exercised, not reasoned about) with a control before being recorded. Builds on
[`REVIEW-phases-1-5.md`](REVIEW-phases-1-5.md) (2026-07-08) and [`AUDIT.md`](AUDIT.md)
— the F4 loopback-publish item there was re-checked against today's code, and is
the subject of P3-1.

---

## 1. Verdict

Phase 3 is built to the same standard as Phases 1 and 2 on its **live** path:
`set -euo pipefail`, TOML→JSON→`jq` (no `eval`/`source`), a strict
`validate_name` gating every lab/service name before it reaches a label filter or
container name, `-`-leading guards on the image and network-driver fields,
create-then-inspect instead of check-then-create to close two TOCTOU races
(Findings 8, 9), a label-scoped `destroy` that refuses containers it does not own,
an H4 partial-`up` rollback that diffs against a pre-run snapshot so an
incremental re-`up` cannot tear down healthy siblings, and `trap '' PIPE` in
`cmd_list` for the SIGPIPE inversion this repo has been bitten by five times. The
suite is green (**17/17 ran, 16 passed, 1 skipped, 0 failed**).

The residue is **four real defects**, all reproduced. Two of them share one root
cause, and it is the finding that matters:

> **`export` is a second, unguarded implementation of the same topology.** Every
> protection `up` applies on the way to Docker — the F4 loopback default, name
> validation, YAML escaping — is **absent** on the way to the compose file, even
> though [`SHOWCASE.md`](phase3-docker/SHOWCASE.md) tells the reader to pipe that
> file straight into `docker compose up -d` (*"ships it"*). The artifact is not a
> report *about* the lab; it is a second way to *run* it, and it is the one with
> no guards. Phase 4 already solved exactly this for its generated quadlets —
> `sanitize_unit_value` refuses newlines *"to prevent systemd unit injection"* and
> its `PublishPort=` routes through `_pub_host` — so the fix shape is in-tree,
> one phase over.

> **Status 2026-08-16: all four findings are FIXED**, together with **every §3 item**
> and the §3b gap, each carrying a regression test whose assertion was **watched to
> fail against the pre-fix driver** before it was kept. The suite is now **23/23 ran,
> 23 passed, 0 skipped, 0 failed** — the skip is gone because `test-compose-interop.sh`
> no longer needs one specific vendor's `yq` (§3b). Two fixes turned out to be
> cross-phase and were applied in the sibling drivers too: **F4** in Phase 4's compose
> export, **Review L1** in Phase 5's `_yaml_str`. See [§7](#7-resolution-2026-08-16)
> for the inventory and the negative-control evidence.
>
> The headline above was right about the shape but understated it in one way worth
> recording: the guarded path and the unguarded one are not merely inconsistent —
> `export` was the path a reader is *told* to use, so the artifact with no guards was
> the recommended one. That is the sibling-docs drift pattern, in code.

- **P3-1 (MED)** — ✅ **FIXED 2026-08-16.** `export` drops the F4 loopback default:
  the same TOML that `up` binds to `127.0.0.1` binds `0.0.0.0` **and `[::]`** when
  run through the exported compose file. AUDIT.md records F4 as resolved with
  *"**every** publish site routes through it."* The port now routes through
  `_pub_host` at the emit site, and **Phase 4's compose export got the same fix** —
  it had the identical gap. Regression: `tests/test-export-hardening.sh`,
  `phase4-podman/tests/test-compose-export.sh`.
- **P3-2 (MED)** — ✅ **FIXED 2026-08-16.** `export` emits unescaped, unvalidated
  scalars. **3 of 14** config-reachable fields inject a *resolved* compose attribute
  (demonstrated: `privileged: true` plus a bind mount of `/`), **9 corrupt** the
  artifact, and only **2 round-trip** — the two that happen to be escaped. Ordinary
  values break it: 4 of 5 realistic `command` strings produce a file compose
  refuses. Fixed with all three layers from the fix direction below, and the
  escaper now handles control characters by **escaping** rather than refusing, so
  the value survives as well as the artifact.
- **P3-3 (LOW/MED)** — ✅ **FIXED 2026-08-16.** `down` reports
  `── lab 'x' torn down ──` and exits **0** while a network it failed to remove is
  still present. A false success, the class CLAUDE.md ranks above an honest failure.
  It now re-queries after removal, names each survivor, and exits non-zero.
- **P3-4 (LOW)** — ✅ **FIXED 2026-08-16.** The `depends_on` **"soft-check"** is
  fatal: a dependency not in the topology is warned about as tolerable (*"may be a
  cross-engine service"*), then queued as a service to start, and kills the whole
  `up`. An unknown name is now skipped, which is what the warning always claimed.

One suspicion — that the three `docker ps … | grep -qx` gates fail open under
SIGPIPE at realistic scale — was **investigated and largely cleared** (§4); the
threshold was measured rather than assumed, and my first reproduction of it was
an artifact of my own fixture.

Phase 3 addresses containers by validated name and label, never by path or PID,
so neither the Phase 1 **P1-1** basename-collision class nor the Phase 2
**P2-2** pidfile-identity class exists here.

---

## 2. Findings

### P3-1 — MED — `export` drops the F4 loopback default; the artifact binds `0.0.0.0` — ✅ FIXED 2026-08-16

`_pub_host` (line 93) is the Review-F4 fix: a bare `8080:80` binds every host
interface, so the driver prepends `127.0.0.1` unless the spec already names a
bind IP (the explicit opt-in) or `LAB_PUBLISH_HOST` overrides it. Phase 3 calls
it at **two** sites — `cmd_run` (line 617) and `cmd_up` (line 835). `cmd_export`
emits the port verbatim (line 1392):

```sh
printf '      - %s\n' "$(_yaml_str "$p")"      # escaped, but never _pub_host'd
```

**Reproduced end-to-end, on the outcome rather than the argv** — one TOML,
`ports = ["18099:8080"]`, both paths, asking the kernel what was bound:

```
# 1. up — the enforced path
$ lab-docker.sh up --config topo.toml
$ docker port lab-p3audit-web        →  8080/tcp -> 127.0.0.1:18099
$ ss -ltn | grep 18099               →  LISTEN 127.0.0.1:18099

# 2. export → docker compose up — the documented handoff
$ lab-docker.sh export --config topo.toml > out.yml && docker compose -f out.yml up -d
$ docker port lab-p3audit-web        →  8080/tcp -> 0.0.0.0:18099
                                        8080/tcp -> [::]:18099
$ ss -ltn | grep 18099               →  LISTEN 0.0.0.0:18099
                                        LISTEN [::]:18099
```

Same lab, same service, same container name — reachable from the lab LAN, and on
IPv6 too, which the original F4 finding did not have to consider.

**Control — the divergence is precisely the default, not all ports.** A spec that
already names a bind IP must round-trip identically, or the fix would be
overreaching:

| TOML `ports` entry | `up` passes to docker | `export` emits |
|---|---|---|
| `127.0.0.1:19001:80` | `127.0.0.1:19001:80` | `"127.0.0.1:19001:80"` ✓ same |
| `0.0.0.0:19002:80` | `0.0.0.0:19002:80` | `"0.0.0.0:19002:80"` ✓ same |
| `19003:80` | `127.0.0.1:19003:80` | `"19003:80"` ✗ **diverges** |

Only the bare form differs, which scopes this to a one-call fix.

**Fix direction:** `_pub_host` the port at line 1392, exactly as
[`phase4-podman/lab-podman.sh`](phase4-podman/lab-podman.sh) already does when it
generates `PublishPort=` into a quadlet (lines 574, 612) — the sibling phase
treats its generated artifact as a publish site, and this one does not. AUDIT.md's
F4 row should then be re-verified rather than assumed: its claim of *"every
publish site"* was true of the two live sites and missed the artifact.

### P3-2 — MED — `export` emits unescaped, unvalidated scalars → injected compose attributes, and routine corruption — ✅ FIXED 2026-08-16

`cmd_export` escapes **some** scalars with `_yaml_str` and emits others raw. The
split is not by risk; it is by which ones someone got to. Twelve raw
value-emitting sites, including:

```sh
printf '    container_name: lab-%s-%s\n' "$lab" "$sname"   # 1372
printf '    image: %s\n' "$simage"                          # 1374
printf '    hostname: %s\n' "$sname"                        # 1385
printf '      %s: %s\n' "$kk" "$(_yaml_str "$vv")"          # 1400  key raw, value escaped
printf '      - %s\n' "$svc_net"                            # 1421
printf '    command: %s\n' "$cmdline"                       # 1426
printf '      interval: %s\n' "$xhc_interval"               # 1479-1482
printf '  %s:\n    driver: %s\n' "$(_yaml_str "$net")" "$d" # 1497  key escaped, value raw
```

**Facet (a) — an injected privilege.** `command` is emitted raw, so a newline in
it ends the YAML scalar and the next line is parsed as a sibling key of the
service. The TOML declares neither `privileged` nor a host mount; the resolved
compose does:

```
$ lab-docker.sh export --config inj.toml > inj.yml
$ docker compose -f inj.yml config
services:
  web:
    privileged: true                 # ← from a `command = "…"` string
    volumes:
      - type: bind
        source: /
        target: /host
```

Asserted on `docker compose config --format json` reading the **resolved
`privileged` attribute**, not on the text — a text grep also matches the string
appearing *inside* a healthcheck value, and an earlier version of this sweep
reported two false positives for exactly that reason.

**The blast radius, measured field by field** (14 config-reachable string fields,
each given a valid base value so only the injected line is under test):

| outcome | n | fields |
|---|---|---|
| **injects** an attribute the TOML never declared | 3 | `service.image`, `service.command`, `healthcheck.interval` |
| **corrupts** — valid TOML in, compose refuses the output | 9 | `lab.name`, `service.name`, `ports[]`, `volumes[]`, `networks[]`, env key, env value, `network.driver`, `depends_on[]` |
| **round-trips** unchanged | 2 | `service.cmd[]`, `healthcheck.test` |

The two survivors are the two that are escaped — and they sit **next to** the two
that are not. `cmd = ["…"]` goes through `_yaml_str` (line 1434) and is safe;
`command = "…"`, the other branch of the same `if`, is raw and injects.
`healthcheck.test` is escaped by `jq` (line 1478) and is safe; `healthcheck.interval`,
four lines below in the same block, is raw and injects. Nothing about the risk
distinguishes them.

**Facet (b) — it breaks on ordinary input, no adversary required.** Of five
entirely realistic `command` values, four produce a compose file that will not
parse:

| TOML | emitted | compose |
|---|---|---|
| `"sh -c echo hi: there"` | `command: sh -c echo hi: there` | ✗ *mapping values are not allowed here* |
| `"true"` | `command: true` | ✗ YAML boolean, not a string |
| `"*.sh"` | `command: *.sh` | ✗ *unknown anchor '.sh'* |
| `"{ echo hi; }"` | `command: { echo hi; }` | ✗ parsed as a flow mapping |
| `"yes"` | `command: yes` | ✓ (quoted by compose on the way out) |

**Facet (c) — `export` performs no name validation at all**, while `up` refuses
the same file at its first line:

```
$ lab-docker.sh up     --config nm.toml
[error] invalid lab name '-not a valid name!': use only [a-zA-Z0-9._-], …
$ lab-docker.sh export --config nm.toml
  "also bad!!":
    container_name: lab--not a valid name!-also bad!!
```

**Fix direction:** three layers, and the last is the durable one.
1. `validate_name` the lab and service names in `cmd_export` as `cmd_up` already
   does — refuse before emitting, per the repo's refuse-before-the-expensive-step
   rule.
2. Reject control characters in any exported scalar, the shape
   `sanitize_unit_value` already has in Phase 4.
3. **Route every scalar through `_yaml_str`**, so the writer *cannot* emit a
   broken artifact. Layers 1–2 are rules about callers; layer 3 removes the need
   for one. This is the same conclusion P2-1 reached about `write_vm_manifest`,
   and for the same reason: the current split exists because the escaping was
   applied to the fields someone was looking at.

Note `_yaml_str` is sufficient for facet (a) but not (b): a newline inside a
double-quoted YAML scalar still yields a file compose rejects — loud rather than
dangerous. That is why layer 2 belongs in the fix and not just layer 3.

### P3-3 — LOW/MED — `down` reports success while leaving a network behind — ✅ FIXED 2026-08-16

`cmd_down` swallows the outcome of both removals (lines 956–958, 968):

```sh
docker rm -f "${ids[@]}" >/dev/null 2>&1 \
    || { docker stop "${ids[@]}" >/dev/null 2>&1 || true
         docker rm   "${ids[@]}" >/dev/null 2>&1 || true; }
…
docker network rm "${nids[@]}" >/dev/null 2>&1 || true
log_info "── lab '$lab_name' torn down ──"
```

Nothing between the `|| true` and the success banner asks whether anything was
actually removed. **Reproduced** with an unmanaged container attached to the
lab's network — the ordinary way this happens, since the network is a normal
Docker network a student can join:

```
$ docker run -d --name p3squatter --network lab-downaudit-net busybox sleep 600
$ lab-docker.sh down --lab downaudit
[info] stopping/removing 1 container(s)
[info] removing 1 network(s)
[info] ── lab 'downaudit' torn down ──          ← rc=0
$ docker network ls | grep downaudit
lab-downaudit-net                                ← still there
```

The operator is told the lab is gone. It is not, and each leaked network holds a
subnet from Docker's finite address pool, so repeated cycles fail in a place far
from the cause — the "record and reality disagree" rung, reported as success.

**Fix direction:** re-query after removal and report what survived by name, the
way Phase 1's `_safe_rm_rf` ground-truths `/proc/mounts` rather than trusting its
own bookkeeping. `down` need not fail hard — a network held by a foreign
container is a legitimate state — but it must not call it *torn down*.

### P3-4 — LOW — the `depends_on` "soft-check" is fatal — ✅ FIXED 2026-08-16

`_topo_visit` warns when a dependency is not in the topology, explicitly
anticipating a legitimate reason, then recurses into it anyway (lines 473–480):

```sh
# Soft-check: warn if dep not in list (may be a cross-engine service).
if ! jq -e … ; then
    log_warn "service '$name' depends_on '$dep' which is not in this topology"
fi
_topo_visit "$dep" "$svc_json"          # ← queues the phantom for startup
```

The phantom lands in `_TOPO_SORTED`, and because it is a *dependency* it sorts
**first**, so `cmd_up` reaches it before any real service:

```
$ lab-docker.sh up --config dep.toml          # web depends_on "cache"; no cache declared
[warn] service 'web' depends_on 'cache' which is not in this topology
[error] service 'cache': specify one of image | from_tarball | from_chroot | build
[info] partial 'up': rolled back 0 new container(s)
rc=1                                           # web never started
```

The error names a service the user never wrote, and the whole lab is dead.

**Control — the case the comment is actually about works correctly.** Declared
with `engine = "podman"`, the same dependency is honoured:

```
$ lab-docker.sh up --config dep2.toml
…lab 'depaudit' up (1 docker service(s), 1 skipped)      rc=0
lab-depaudit-web                                          ← running
```

So the cross-engine path the comment invokes is *not* this path; the warning
promises a tolerance the code does not implement.

**Fix direction:** append to `_TOPO_SORTED` only names that exist in `svc_json`.
The ordering contribution of an unknown dependency is vacuous anyway — it has no
edges — so nothing is lost.

---

## 3. Minor / robustness (not standalone findings) — ✅ ALL SIX FIXED 2026-08-16

- **`run --arch <unknown>` exits 1 with no message**, where `build` names the
  problem:
  ```
  $ lab-docker.sh build --arch bogus --tag x    → rc=1  "[error] unknown arch: bogus"
  $ lab-docker.sh run   --arch bogus --name a1 --image busybox
                                                → rc=1  (no output at all)
  ```
  `cmd_build` calls `is_known_arch`; `cmd_run` does not, and reaches
  `args+=(--platform "$(docker_platform "$OPT_ARCH")")` (line 610). `docker_platform`
  returns 1 for an unknown arch, the failed command substitution makes the array
  assignment non-zero, and as the **last command of an `&&` list** under `set -e`
  that kills the script before any diagnostic. Isolated:
  `set -e; f(){ return 1; }; a=(); [[ -n x ]] && a+=(--p "$(f)")` → rc=1, silent.
  Add the `is_known_arch` check `cmd_build` has.

- **The docker.sock warning matches one of two names for the same file.** Lines
  636 and 850 case-match the literal `/var/run/docker.sock`. On any systemd host
  `/var/run` is a symlink to `/run`, so the canonical path is `/run/docker.sock`
  — same device and inode, no warning:
  ```
  $ stat -c '%d:%i' /var/run/docker.sock /run/docker.sock   → 26:3525   26:3525
  $ … run --volumes /var/run/docker.sock:/var/run/docker.sock
      [warn] volume mount of docker.sock gives container full Docker daemon access
  $ … run --volumes /run/docker.sock:/var/run/docker.sock
      (no warning — identical socket mounted at the identical place)
  ```
  The guard is advisory, so this is not an access-control hole; it is an advisory
  that is silent for the spelling most hosts use. It asks *"is this string
  `/var/run/docker.sock`?"* when the question is *"is this the daemon socket?"* —
  resolve with `realpath` and compare, or match both spellings. The `/` case has
  the same shape (`//`, `/.`, and a symlink to `/` all evade it).

- **A literal env value of `"null"` is silently dropped.** Finding 32 preserves
  compose's inherit-from-host semantics by marking such entries JSON `null`, but
  the consumer tests the *rendered text* (line 841): `[[ -n "$kk" && "$vv" != "null" ]]`.
  `jq -r` prints a JSON null and the string `"null"` identically, so they are
  indistinguishable at that seam. Measured — `A = "null"`, `B = "keep"`:
  ```
  $ docker inspect lab-nl-w --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E '^(A|B)='
  B=keep                                    ← A was dropped
  ```
  Same shape as P2-1's jq `//` trap: a sentinel that collides with a legal value.
  Discriminate in `jq` (where the type is still known) rather than in bash.

- **Three `docker ps -a --format '{{.Names}}' | grep -qx` gates** (lines 599, 894,
  1123) put a verdict downstream of a pipe, the inversion this repo has recorded
  five times. Measured rather than assumed — see §4: they fail open only once the
  producer's output exceeds the 64 KiB pipe buffer (~4,000 containers), so this is
  latent, not live. `cmd_destroy` (line 1064) already uses the correct shape —
  capture to a variable, then `grep -Fxq` — and it is two lines of change to make
  the other three match. `tools/tests/test-no-pipe-gates.sh` does not cover them:
  it scans `*/tests/*.sh`, and these are driver code.

- **`healthcheck.test` is emitted as a pretty-printed jq array**, so the value
  spans four lines at column 2 inside a block indented to 6:
  ```yaml
      healthcheck:
        test: [
    "CMD-SHELL",
    "curl -f http://x || exit 1"
  ]
  ```
  Valid — YAML flow context ignores indentation — but only by luck, and it is what
  makes this field's failure mode differ from its neighbours'. `jq -c` (or
  `jq -nc`) emits it on one line.

- **The mikefarah/yq probe tests the banner, not the capability.**
  `yq --version 2>&1 | grep -qi 'mikefarah'` (lines 243, 222). yq 4.2.0 prints
  `yq version 4.2.0` — no URL, no vendor name — so it is rejected as "not
  mikefarah". Here that verdict is *right by accident*: 4.2.0 genuinely lacks
  `-p yaml -o json`, which arrived later. But the check cannot tell those two
  facts apart, and mikefarah builds between the two format changes support `-p`
  while failing the grep. Probe the capability (`yq -p yaml -o json` on a
  one-line fixture) instead of parsing a version banner — a version string is not
  an identity.

## 3b. Not verified by this pass — UNKNOWN, not PASS — ✅ CLOSED 2026-08-16

- **The Compose-YAML interop path (`compose_to_json`, ~80 lines of jq) was not
  exercised.** `tests/test-compose-interop.sh` **skipped** on this host for the
  reason directly above — yq 4.2.0 is too old — so the `--config *.yml` branch,
  its environment-map normalisation, its `depends_on` map/list handling and its
  `hc_test` translation are all unmeasured here. The suite line reads
  *16 passed, 1 skipped* and names the file; that skip is this gap. Its
  `CMD`-vs-`CMD-SHELL` translation looks worth a closer look when a newer yq is
  present — `hc_test` joins an exec-form `["CMD","a b","c"]` with spaces into a
  shell string, which re-splits an argument containing a space — but that is a
  reading, not a measurement, and is recorded here as such rather than as a
  finding.

  **Closed 2026-08-16.** The precondition was the defect, not the host: `compose_to_json`
  hard-required one vendor's binary for a job the standard library can do. It now falls
  back to `python3` + `PyYAML` (`yaml.safe_load`, never `load` — the full loader
  constructs arbitrary Python objects from `!!python/object` tags, which would make
  reading an untrusted compose file a code-execution seam), and `toml_to_json` likewise
  falls back to `tomllib`. The interop test **runs** on this host now, so the branch,
  its environment normalisation, its `depends_on` handling and its `hc_test` are
  measured rather than reasoned about.

  The `CMD`-vs-`CMD-SHELL` reading was **right, and is now a measurement**: `hc_test`
  joined an exec-form `["CMD","a b","c"]` into `a b c`, which the shell re-splits into
  three words — a two-argument check silently becoming a three-argument one. Fixed with
  `@sh`, which quotes each element, and asserted by *running the rendering through the
  shell's own word splitting* and counting the words, rather than by comparing strings.

  **The skip was also hiding a stale test.** `test-compose-interop.sh` still grepped for
  the **unquoted** `^  web:` that `export` stopped emitting when Finding 21 quoted YAML
  keys. It would have failed the moment it ran. An unrun test rots silently, which is the
  strongest argument here for closing a skip rather than annotating it — and it is why the
  three `yq --version | grep mikefarah` preconditions in the *tests* were replaced with
  capability probes too, not just the one in the driver.

## 4. Investigated and cleared (so it is not re-raised)

- **The three `| grep -qx` gates failing open at realistic scale.** My first
  reproduction said they fail with **five** containers, which would have made this
  a finding. That was **my fixture's defect, not the driver's**: the shim emitted
  names with one `printf` per line, so the producer was still writing when
  `grep -q` exited on the first match and took a SIGPIPE. Real `docker ps` writes
  its output in one `write(2)`, which completes before `grep` closes the pipe.
  Measured against a single-write producer on this kernel (pipe buffer 65536
  bytes):

  | producer output | names | pipeline rc |
  |---|---|---|
  | ~4 KiB | 170 | 0 |
  | ~64 KiB | 2730 | 0 |
  | ~128 KiB | 5461 | **141** (SIGPIPE) |

  So the gates are wrong in form and reachable only past ~4,000 containers.
  Recorded in §3 as latent with the number attached, rather than as a defect —
  and the correction is recorded here because "I reproduced it" was, for one
  round, false.

- **`cmd_up`'s `trap "_partial_up_cleanup '${lab_name}'" EXIT` (line 711).** The
  trap string is built by interpolation, which is the shape that usually carries
  an injection. It is safe here: `validate_name "$lab_name"` runs at line 674,
  **before** the trap is installed, and its regex `^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$`
  admits no quote, space or `$`. The trap is cleared on the success path
  (`trap - EXIT`, line 925), and `_partial_up_cleanup` reads `_PRE_C`/`_PRE_N`
  through dynamic scope from `cmd_up`, which the comment states. The rollback
  diffs against the pre-run snapshot, so a re-`up` that fails does not remove the
  containers it did not create — verified by the existing
  `tests/test-partial-up-rollback.sh`. No defect.

- **`cmd_list`'s `trap '' PIPE` (line 1026).** Not the EXIT-trap violation the
  harness-net checker forbids — different signal, driver code not test code, and
  the reason is documented and correct: a `printf` builtin takes SIGPIPE in the
  shell process itself, where `|| true` cannot help.

## 5. Feature completeness

Phase 3's declared surface is complete and coherent: four image sources (`image`
pull, `from-chroot` import with an unreadable-file preflight that redirects to the
rootless path, `from-tarball`, and `buildx` with a binfmt precondition it
*checks and explains* rather than silently running a privileged container), six
arches mapped to Docker platforms, multi-service topologies with declared
networks, `depends_on` with a real topological sort and health-gating, healthchecks,
compose-YAML input as well as TOML, twelve verbs including `inspect --json` for
Phase 6, and cross-engine `engine =` routing so one topology can span Phases 3
and 4. Stated limitations carry reasons in-code (object-form volumes unsupported;
`build:` contexts do not round-trip through export). No missing feature rises to a
finding — the export *fidelity* gaps are P3-1/P3-2, not absent features.

## 6. Calibration — good patterns preserved

The label-first design is the right call and is applied consistently: `down`,
`list`, `destroy` and the rollback all scope by `lab-create.tool`, so the tool
cannot reap a container it does not own (Review M2), and there is no state file to
go stale — the engine *is* the record, which sidesteps the entire "record outlives
its subject" class that produced Phase 2's P2-2. The two TOCTOU races are closed
by attempting the operation and handling the failure rather than pre-checking
(Findings 8, 9). `validate_name` gates every name before it reaches a label
filter, a container name, or the trap string. The `-`-leading guard is applied to
the image in **both** `run` and `up` (Review M1) and to the network driver
(Finding 16). `_resolve_container_name` rejects multi-slash targets instead of
silently dropping a component (Finding 29). `cmd_destroy` already uses the
capture-then-`grep -Fxq` shape that §3 recommends for the other three sites, and
`-F` there is deliberate so a `.` in a name is not a wildcard (Review L2). The
`from-chroot` readability preflight is a model of refusing before the expensive
step *and* telling the user the exact alternative command. And
`tests/test-status-export.sh` does validate the exported YAML with
`docker compose config --quiet` — the outcome, not the text — which is why P3-2
had to be found with hostile inputs rather than by reading: the assertion is
right, and every value in its fixture is a plain token.

---

## 7. Resolution (2026-08-16)

Everything above is now fixed — the four findings, all six §3 items, and the §3b
gap — plus the two cross-phase instances the findings implicated. Diagnosis and
repair are in the same document on purpose: the fix direction each finding proposed
is where the work started, and where it *diverged* is recorded below rather than
quietly rewritten.

### 7.1 What changed

| item | change | regression test |
|---|---|---|
| **P3-1** | `export` routes each port through `_pub_host` before emitting | `test-export-hardening.sh`, `test-compose-interop.sh` |
| **P3-1 (Phase 4)** | same fix at `lab-podman.sh:1897` — its compose export had the identical gap | `phase4-podman/tests/test-compose-export.sh` |
| **P3-2** | `validate_name` on lab + service names; **every** scalar through `_yaml_str`; `_yaml_str` grew a control-character path | `test-export-hardening.sh` |
| **P3-3** | `down` re-queries after removal, names each survivor, exits non-zero | `test-down-reports-survivors.sh` |
| **P3-4** | an unknown `depends_on` target is skipped, not queued | `test-depends-on-phantom.sh` |
| **§3** arch | `--arch` validated **once at the parser**, covering `run`/`build`/`push`/`up` | `test-arch-and-mount-guards.sh` |
| **§3** mounts | `_warn_sensitive_mount` resolves the path and compares device:inode | `test-arch-and-mount-guards.sh` |
| **§3** env `"null"` | the `select` moved into `jq`, where the type is still known | `test-env-literal-null.sh` |
| **§3** pipe gates | one `_name_exists` helper; all three call sites use it | `test-name-gate-at-scale.sh` |
| **§3** healthcheck | `jq -nc` | `test-export-hardening.sh` |
| **§3** yq probe | `_yq_can FORMAT` runs the tool on a one-line fixture | `test-compose-interop.sh` (it now runs) |
| **§3b** interop | `python3`/`PyYAML` + `tomllib` fallbacks; `hc_test` uses `@sh` for exec form | `test-compose-interop.sh` |
| **Review L1 (Phase 5)** | `_yaml_str` escapes backslash **before** double-quote, as Phases 3/4 already did | `phase5-lxd/tests/test-yaml-escaping.sh` |

### 7.2 Where the fix diverged from the fix direction

- **P3-2 proposed *rejecting* control characters** (layer 2, the `sanitize_unit_value`
  shape from Phase 4). The implementation **escapes** them instead: a newline becomes
  `\n` inside the quoted scalar, so the artifact stays valid *and* the value survives.
  Rejecting would have been correct-but-lossy, and "the export refuses a config `up`
  accepts" is its own kind of divergence between the two paths. The fast path is pure
  bash; only a value that actually contains a control character pays for `jq`.
- **`command:` was left a quoted string, not split into a list.** Making the export
  mirror `cmd_up`'s naive `read -ra` whitespace split would have been *more* faithful to
  `up` and *less* correct: compose's own shlex handles quoting properly, and `up`'s
  splitter is the weaker of the two. Mimicking the weaker one would be regressing toward
  the mechanism. The measured consequence is recorded honestly instead: compose's shlex
  legitimately drops `;` and `}` from a string command, so `test-export-hardening.sh`
  asserts the **YAML scalar** the parser reads back, not compose's resolved argv.

### 7.3 Two assertions that had to be corrected before they could be trusted

Both were caught by running the new tests against the **pre-fix** driver, which is the
only way either could have surfaced:

1. **`grep -c '^      test: '` returned `1` for the pretty-printed form too** — only the
   *first* line of a multi-line jq array carries the prefix. The check looked like it
   measured single-line-ness and could never fail. Replaced with an assertion that the
   emitted line *ends in `]`*, i.e. that the value is complete on it. This is the §3
   "cheap check standing in for the real one" pattern, committed by a test written to
   catch that very pattern.
2. **A `command` ending in a bare backslash** was in the ordinary-values list, and
   compose refused it. That refusal is **correct** — it is not a well-formed shell
   command line — so the case was moved to a field nothing shell-splits (an env value),
   where backslash fidelity is genuinely the exporter's problem. A fixture the code
   ought to reject cannot also be its happy path.

### 7.4 Negative controls

No assertion was kept without being observed to fail. The pre-fix driver was restored
and every new test re-run against it:

| test | verdict against the pre-fix driver |
|---|---|
| `test-export-hardening.sh` | FAIL — exported port `19003:80` bound `0.0.0.0`, not `127.0.0.1` |
| `test-down-reports-survivors.sh` | FAIL — `down` exited 0 with the network still present |
| `test-depends-on-phantom.sh` | FAIL — sort order was `cache web db`; the phantom was queued first |
| `test-arch-and-mount-guards.sh` | FAIL — `run --arch bogus-arch` produced `rc=1` and **empty** output |
| `test-name-gate-at-scale.sh` | FAIL — the name was not found in a 144 KB list |
| `test-env-literal-null.sh` | FAIL — the container got `A=<unset>` |
| `test-compose-interop.sh` | FAIL — died in `load_config` (the vendor gate) with no verdict |
| `phase4-podman/tests/test-compose-export.sh` | FAIL — bare port exported without the loopback default |
| `phase5-lxd/tests/test-yaml-escaping.sh` | FAIL — `a\` emitted `"a\"` |

Three assertions were **shadowed** in that run — an earlier one in the same file failed
first, so they were never observed biting — and were measured separately against the
pre-fix driver: healthcheck compactness (`test: [` incomplete → complete), export name
validation (`ACCEPTED rc=0` → refused), and the mount advisory for `/run/docker.sock`
and `//` (both `silent` → both `WARNED`). `test-name-gate-at-scale.sh` additionally
carries its **own** control inline: it re-implements the old `| grep -qx` shape and
fails if that shape does *not* break on the fixture, so the test cannot pass for the
uninteresting reason that its fixture was too small.

### 7.5 Not verified by the fix pass — UNKNOWN, not PASS

- **Phase 5's live LXD paths were not run.** The change there is confined to
  `_yaml_str`, whose only consumers are the two `cmd_export` call sites, and it has a
  pure unit test. But `phase5-lxd/tests/run-all.sh` includes `test-profiles-projects.sh`,
  and profile **writes** are documented to wedge `incus` on this host with recovery
  requiring a `sudo systemctl restart incus` this agent cannot perform. Four pure tests
  ran (`test-yaml-escaping`, `test-validation`, `test-naming`, `test-harness-net`); the
  instance-lifecycle tests did **not**.
- **No IPv6-only host was tested.** P3-1's original reproduction observed `[::]:19099`
  from a dual-stack daemon; the fix is asserted through `docker compose config`'s
  resolved `host_ip`, which reports the bind address rather than the sockets finally
  opened.
- **The 64 KiB threshold was re-derived on this kernel only.** `test-name-gate-at-scale.sh`
  asserts its fixture exceeds the pipe buffer and fails loudly if it does not, so a
  kernel with a different buffer produces an honest failure rather than a silent pass.

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

- **P3-1 (MED)** — `export` drops the F4 loopback default: the same TOML that
  `up` binds to `127.0.0.1` binds `0.0.0.0` **and `[::]`** when run through the
  exported compose file. AUDIT.md records F4 as resolved with *"**every** publish
  site routes through it."*
- **P3-2 (MED)** — `export` emits unescaped, unvalidated scalars. **3 of 14**
  config-reachable fields inject a *resolved* compose attribute (demonstrated:
  `privileged: true` plus a bind mount of `/`), **9 corrupt** the artifact, and
  only **2 round-trip** — the two that happen to be escaped. Ordinary values
  break it: 4 of 5 realistic `command` strings produce a file compose refuses.
- **P3-3 (LOW/MED)** — `down` reports `── lab 'x' torn down ──` and exits **0**
  while a network it failed to remove is still present. A false success, the
  class CLAUDE.md ranks above an honest failure.
- **P3-4 (LOW)** — the `depends_on` **"soft-check"** is fatal: a dependency not
  in the topology is warned about as tolerable (*"may be a cross-engine
  service"*), then queued as a service to start, and kills the whole `up`.

One suspicion — that the three `docker ps … | grep -qx` gates fail open under
SIGPIPE at realistic scale — was **investigated and largely cleared** (§4); the
threshold was measured rather than assumed, and my first reproduction of it was
an artifact of my own fixture.

Phase 3 addresses containers by validated name and label, never by path or PID,
so neither the Phase 1 **P1-1** basename-collision class nor the Phase 2
**P2-2** pidfile-identity class exists here.

---

## 2. Findings

### P3-1 — MED — `export` drops the F4 loopback default; the artifact binds `0.0.0.0`

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

### P3-2 — MED — `export` emits unescaped, unvalidated scalars → injected compose attributes, and routine corruption

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

### P3-3 — LOW/MED — `down` reports success while leaving a network behind

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

### P3-4 — LOW — the `depends_on` "soft-check" is fatal

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

## 3. Minor / robustness (not standalone findings)

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

## 3b. Not verified by this pass — UNKNOWN, not PASS

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

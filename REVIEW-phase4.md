# Review — Phase 4 (`phase4-podman/lab-podman.sh`)

**Date:** 2026-08-16
**Scope:** Phase 4 only — `lab-podman.sh` (2157 LOC), its `tests/` (14 files), and
the shared harness-net checker as it applies to Phase 4. Audited for **safety**
(host damage), **soundness** (correctness/data-integrity), **security**
(isolation/injection), and **feature completeness** — the same axes and format as
[`REVIEW-phase1.md`](REVIEW-phase1.md), [`REVIEW-phase2.md`](REVIEW-phase2.md)
and [`REVIEW-phase3.md`](REVIEW-phase3.md).
**Method:** the driver read end-to-end; every finding reproduced against a **live
rootless podman** (5.x on this host) with a control before being recorded. Builds
on [`REVIEW-phases-1-5.md`](REVIEW-phases-1-5.md) (2026-07-08) and
[`AUDIT.md`](AUDIT.md) — the F4 loopback-publish item is re-opened again here
(P4-5), which also **corrects a claim this reviewer wrote into AUDIT.md
yesterday**.

---

## 1. Verdict

Phase 4 carries the most defensive machinery of any phase, and most of it is
excellent: a rootless-first gate with an explicit `--allow-root` escape hatch,
`sanitize_unit_value` refusing newlines in **every** quadlet field (the systemd
analogue of shell injection, and applied consistently across `Image`,
`PublishPort`, `Volume`, `Environment`, `HealthCmd`, `AutoUpdate` and `Exec`),
`resolve_userns_flags` using a **nameref** so a `userns` value can no longer
word-split `--privileged` into the argv (Finding 2), a raw-uidmap regex, an
`awk`-based subuid lookup because `grep "^${user}:"` treats `.` as a wildcard
(Finding 11), `:z` chosen over `:Z` with the reasoning recorded (Review M3), a
`podman network rm --` guard, a `rm -rf` prefix assertion on the state dir, and a
`pod inspect` shim that accepts both podman 4's object and podman 5's array. The
suite is green (**14/14 ran, 13 passed, 1 skipped, 0 failed**).

That machinery makes the residue more interesting, not less: **six real defects,
all reproduced, and five of them are a guard that exists in this repo being
absent from one of its call sites.** The recurring shape is not a missing idea —
it is an idea applied to the path someone was looking at:

| the guard | where it is | where it is not |
|---|---|---|
| `-`-leading image check (Review M1) | Phase 3's `run` **and** `up` | **all** of Phase 4 → **P4-1** |
| `validate_name` on lab/service/pod | `cmd_up`, `cmd_down` | `cmd_generate` → **P4-2** |
| `engine =` cross-phase routing | the plain path | the pod **and** quadlet paths → **P4-4** |
| `_pub_host` loopback default (F4) | quadlet `PublishPort=`, all `run` paths | `export --format compose` → **P4-5** |

- **P4-1 (MED, security)** — a TOML `image` value beginning with `-` is passed as
  the first positional to `podman run`, so it is parsed as a **flag**.
  Demonstrated live: a config that never says "privileged" produced a running
  container with `Privileged=true`.
- **P4-2 (MED, security)** — `generate` performs **no** name validation, while
  `up` validates lab, service *and* pod names precisely because they "become
  quadlet unit *paths*". A `../`-bearing lab name made `generate` create a
  directory **two levels above** the state dir and copy the spec into it.
- **P4-3 (MED, soundness)** — the quadlet emitters **report success on a failed
  write**: `rc=0`, `[info] wrote <path>`, zero files on disk, and a **dangling
  symlink** recorded as a tracked unit. Reproduced with entirely valid names, so
  it is independent of P4-2.
- **P4-4 (MED, soundness)** — cross-phase `engine =` routing is honoured by **one
  of three** execution paths. The pod path starts a `engine = "docker"` service
  anyway; the quadlet path writes it a unit.
- **P4-5 (MED, security)** — `export --format compose` drops the F4 loopback
  default **and** emits `image`/`command` raw, injecting resolved compose
  attributes (`privileged: true`, a bind mount of `/`). The same pair as Phase 3's
  P3-1/P3-2.
- **P4-6 (LOW/MED, soundness)** — `down` reports `torn down` and exits 0 with a
  network still live, and deletes the lab's `spec.toml` on the way out — so
  `export` for that lab becomes impossible while the lab is still running.

Phase 4 addresses containers by validated name and label, never by path or PID,
so neither Phase 1's **P1-1** nor Phase 2's **P2-2** class exists here.

---

## 2. Findings

### P4-1 — MED — a `-`-leading `image` injects `podman run` flags → a live privileged container

`start_service_plain` (line 780) and the pod path (line 911) pass the image as the
first positional:

```sh
podman run "${args[@]}" "$simage" "${cmd[@]}"
```

Phase 3 guards exactly this, in **both** its `run` and `up` paths, and says why:

```sh
# Review M1: the image is the first POSITIONAL to `docker run`, so an
# `image = "--privileged"` / `"-v"` in a TOML topology would inject flags
[[ -z "$simage" || "$simage" != -* ]] || die "…must not start with '-'…"
```

Phase 4 has **no such guard anywhere** — its only `-`-leading check is on
`devices` (line 133).

**Reproduced live.** `image = "--privileged"` alone merely errors (podman then has
no image argument), which is presumably why this looked harmless. Supplying the
image through `command` completes it:

```toml
[[service]]
name    = "web"
image   = "--privileged"
command = "busybox:latest sleep 600"
```
```
$ lab-podman.sh up --config img2.toml
[info] starting (plain) service 'web' as lab-p4img-web (image=--privileged)
[info] ── lab 'p4img' up ──
$ podman inspect lab-p4img-web --format '{{.ImageName}} Privileged={{.HostConfig.Privileged}}'
docker.io/library/busybox:latest Privileged=true
```

The TOML contains the string "privileged" exactly once, in the **image** field.
`podman run` consumed it as a flag, took `busybox:latest` from the command as the
image, and ran the rest as the command.

Rootless podman bounds the damage — `--privileged` is still confined by the user
namespace — but it drops seccomp and the AppArmor/SELinux confinement *within*
that namespace and exposes host devices, and `--allow-root` removes the bound
entirely. Any flag works, not just this one: `-v` mounting a host path is the same
one-line change.

**Fix direction:** port Review M1's guard to Phase 4 — the plain path, the pod
path, and `cmd_run`'s `--image` — and prefer `podman run … -- "$simage"` where the
subcommand supports `--`, so the positional cannot be re-read as an option at all.

### P4-2 — MED — `generate` skips the name validation `up` performs, and writes paths from the result

`cmd_up` validates every name up front, and the comment states the reason exactly
(lines 1169–1179):

```sh
# Review (name validation): the lab name was validated but service/pod names
# were not — yet they become quadlet unit *paths*, `--name`/`--hostname`,
# label values, and `grep` patterns.  Validate them ALL up front, before any
# state dir or unit file is written…
validate_name "$lab_name" "lab name"
… validate_name "$_n" "service name"
… validate_name "$_n" "pod name"
```

`cmd_generate` (line 1969) calls `validate_name` **zero** times, and then does the
same writes — `install -d "$(lab_dir "$lab")"`, `cp -f "$OPT_CONFIG"
"$(lab_dir "$lab")/spec.toml"`, and `emit_pod_unit` / `emit_container_unit`.
Repo-wide, `validate_name` appears at only four call sites, all in `cmd_up` and
`cmd_down`.

**Reproduced** (everything redirected into a scratch tree):

```
$ cat trav.toml
[lab]
name = "../../ESCAPED"

$ lab-podman.sh up       --config trav.toml
[error] invalid lab name '../../ESCAPED': use only [a-zA-Z0-9._-], …

$ lab-podman.sh generate --config trav.toml
[info] ── quadlet units generated for lab '../../ESCAPED' ──      ← rc=0

$ find $W -name spec.toml -o -name '*.container'
$W/ESCAPED/spec.toml                                ← two levels ABOVE the state dir
$W/ESCAPED/quadlet-links/ESCAPED-web.container
```

`lab_dir` is `$LAB_STATE_DIR/podman/<lab>`, and `install -d` happily walks `..`
components, so the directory and the copied config land outside the tree
`cmd_down`'s `rm -rf` prefix assertion is written to protect. The content written
is the user's own config, so this is a write-where-it-should-not primitive rather
than an arbitrary-content one — but the containment `down` assumes is gone, and
`down` will refuse that lab name, so nothing the tool offers can clean it up.

The **unit-file** path resists traversal for an incidental reason worth recording
so nobody assumes it is a defence: the unit name is `lab-<lab>-<svc>.container`,
so a leading `..` lands inside a component `lab-..` that does not exist, and the
write fails. It fails *silently* — which is P4-3.

**Fix direction:** call the same three validation loops in `cmd_generate`. Better,
hoist them into a `validate_topology_names CFG_JSON` helper that both entry points
call, so the next entry point is correct by default — the accessor-guard reasoning
from P1-1 rather than a rule restated at each call site.

### P4-3 — MED — the quadlet emitters report success on a failed write

`emit_container_unit` (line 582) writes the unit with a group redirect:

```sh
{
    printf '# Generated by …'
    …
} > "$unit"
track_quadlet_link "$lab" "$unit"
printf '%s' "$unit"
```

If the redirect fails, the group's failure is discarded by the two commands after
it: `track_quadlet_link` succeeds, `printf` succeeds, so the function returns 0
and its caller records a unit that was never written.

**Reproduced with entirely valid names** — `lab = "goodname"`, `service = "web"` —
by making the target path a directory, so the failure is name-independent:

```
$ lab-podman.sh generate --config ok.toml
lab-podman.sh: line 582: …/systemd/lab-goodname-web.container: Is a directory
[info] wrote …/systemd/lab-goodname-web.container          ← false
[info] ── quadlet units generated for lab 'goodname' ──
rc=0
real unit files written:    0
recorded in quadlet-links:  1
```

The tool prints `wrote <path>` for a path it did not write, exits 0, and leaves a
**dangling symlink** in `quadlet-links/` — the directory whose entire job is to
record what `down` must reverse. A record with no subject, which is the mirror of
the class CLAUDE.md catalogues (a record that outlives its subject), and it is a
false success, which that document ranks above an honest failure.

Downstream, `start_lab_quadlet` compounds it: a failed
`systemctl --user start` is also downgraded to `log_warn` (lines 959–960), so the
quadlet path can fail at both the write and the start and still exit 0.

**Fix direction:** check the redirect — write to a temp file and `mv` it into
place, or capture the group's status and `die` on failure — and only
`track_quadlet_link` after the file demonstrably exists. A unit that failed to
write must not be recorded as one that did.

### P4-4 — MED — cross-phase `engine =` routing is honoured by one of three paths

Phase 4's headline cross-phase feature is that one topology can span engines: a
service carrying `engine = "docker"` belongs to Phase 3 and Phase 4 must leave it
alone. The plain-services loop does this (lines 1293–1299). The **pod** loop
(`start_services_in_pod`, from line 834) and the **quadlet** loop
(`start_lab_quadlet`, from line 937) never read `engine` at all.

**Reproduced, with the plain path as the control** — the same two services, one of
them `engine = "docker"`, run three ways:

| path | result |
|---|---|
| plain (no `pod =`) | `[info] skipped 1 service(s) with engine != podman`; only `lab-p4eng-mine` started ✓ |
| pod | `starting (pod=p) service 'mine'` **and** `'theirs'`; both running under podman ✗ |
| quadlet (`generate`) | wrote `lab-p4eng-mine.container` **and** `lab-p4eng-theirs.container` ✗ |

So the control proves the routing works and is understood; two of the three paths
simply never consult it. A user following the documented cross-phase workflow
gets the docker-owned service started twice — once by each tool — with the podman
copy silently attached to podman's network instead of the one its author chose.

**Fix direction:** the engine check belongs where the service is *selected*, not
in one consumer. Filter `.service[]` by engine once in `cmd_up` (and
`cmd_generate`) and hand the three paths an already-filtered list, so a fourth
path cannot reintroduce this.

### P4-5 — MED — `export --format compose` drops the F4 default and injects compose attributes

This is Phase 3's P3-1 **and** P3-2 recurring in Phase 4's compose exporter, which
is a separate implementation of the same idea.

**Facet (a) — the F4 loopback default is not applied** (line 1897). The contrast
is inside this one driver, from one spec, in two artifacts it generates:

```
quadlet unit (.container):        compose export (--format compose):
  PublishPort=127.0.0.1:18097:80    - "18097:80"
  PublishPort=127.0.0.1:18096:80    - "127.0.0.1:18096:80"
```

The quadlet writer routes through `_pub_host` (lines 574, 612); the compose writer
does not. Same tool, same input, one artifact guarded and one not — so this is an
omission, not a design decision.

> **This corrects a claim I wrote into [`AUDIT.md`](AUDIT.md) on 2026-08-16.**
> Re-opening F4 for Phase 3 yesterday, I wrote *"Phase 4's generated quadlets do
> route `PublishPort=` through `_pub_host` …, so the gap is Phase 3's export
> alone."* That was derived from grepping `_pub_host`'s **call sites** and finding
> five in Phase 4 — a mechanism check standing in for the question *"does every
> generated artifact carry the default?"* Phase 4 has two artifact generators and
> only one of them was in that list. The AUDIT.md row has been corrected.

**Facet (b) — `image` and `command` are emitted raw** (lines 1891, 1914), under a
comment that states the assumption explicitly:

```sh
# Finding 8 + Review L1: emit the free-text values (env values,
# ports, volumes) as escaped YAML scalars via _yaml_str … Image and
# command keep their original format (engine-validated / plain).
```

"Engine-validated" cannot apply to a file the engine never sees — `--format
compose` is a pure text transformation that reads `spec.toml` and prints YAML.
**Reproduced**, asserting on the attribute compose *resolves*, not on the text:

```
$ lab-podman.sh export inj4 --format compose | tee inj4.yml
    command: sleep 600
    privileged: true
    volumes:
      - /:/host
$ docker compose -f inj4.yml config --format json | …
  service web: privileged=True  volumes=['/']
```

The env **key** is likewise raw (line 1904) while its value is escaped, the same
asymmetry Phase 3 has.

**Fix direction:** identical to P3-1/P3-2 — `_pub_host` the port, route every
scalar through `_yaml_str`, and reject control characters. Phase 4 already owns
the right primitive for the last part in `sanitize_unit_value`; the exporter
simply does not call it. Also drop the obsolete `version: "3.9"` key (line 1879),
which current Compose warns about and Phase 3 already omits deliberately.

### P4-6 — LOW/MED — `down` reports success while a network survives, and deletes the spec on the way out

Every removal in `cmd_down` is `|| true` (lines 1338–1361), and nothing between
them and the banner asks what actually happened:

```
$ podman run -d --name p4squat --network lab-p4down-net busybox sleep 600
$ lab-podman.sh down --lab p4down
[info] removing 1 network(s)
[info] ── lab 'p4down' torn down ──          ← rc=0
$ podman network ls | grep p4down
lab-p4down-net                                ← still there
```

Phase 3 has the same shape (P3-3), but Phase 4 adds a consequence: `down` then
unconditionally `rm -rf`s the lab's state dir (line 1370), which holds the
`spec.toml` copy. Measured in the same run — state dir **deleted**, network
**alive**. Since `export --format compose` requires that file, a lab that is still
running can no longer be exported:

> `no spec.toml for lab 'p4down' (was it brought up via 'up --config'?)`

— a message that blames the user for not doing the thing they did.

**Fix direction:** re-query after removal, name what survived, and make the state
dir removal conditional on the resources actually being gone. `down` need not fail
hard (a network held by a foreign container is legitimate), but it must not call
that *torn down*, and it must not discard the record while the subject lives.

---

## 3. Minor / robustness (not standalone findings)

- **`cmd_run` does not validate `--name`.** Phase 3 calls
  `validate_name "$name" "container name"`; Phase 4's `cmd_run` (line 1045) calls
  nothing, and builds `cname="lab-${name}"` plus label values from it. podman
  rejects most malformed names itself, so this is defence-in-depth rather than a
  hole — but it is the fourth instance of the same asymmetry, and the cheapest to
  close.

- **Five `podman … | grep -q` gates** (lines 668, 782, 840, 1079, 1246) put a
  verdict downstream of a pipe. Same latent class as Phase 3's, measured there:
  they fail open only once the producer's output exceeds the 64 KiB pipe buffer
  (~4,000 containers), because podman writes its listing in one `write(2)`.
  Latent, not live. `cmd_destroy` (line 1802) already uses the correct
  capture-then-`grep -Fxq` shape; the other five are a two-line change each.

- **`install -d -m 0755` resets the mode of an existing directory.** Noticed while
  building a control for P4-3: an attempt to make `QUADLET_USER_DIR` read-only was
  silently undone by `emit_container_unit`'s own `install -d`, which re-chmods it
  to 0755 on every call. Harmless for the user's own directory, but it means the
  tool quietly widens permissions on a path it did not create, and it is why the
  P4-3 control had to be built a different way. `mkdir -p` would not do this.

- **A literal env value of `"null"`** has the same collision noted in Phase 3 §3 —
  `jq -r` renders JSON `null` and the string `"null"` identically. Phase 4's
  consumers (lines 634, 739, 880) do **not** test for it, so unlike Phase 3 they
  do not silently drop the variable; recorded only so the difference between the
  two phases is deliberate rather than accidental.

## 3b. Not verified by this pass — UNKNOWN, not PASS

- **The rootful (`--allow-root`) path was not exercised.**
  `tests/test-allow-root.sh` skipped: *"sudo -n not available; can't simulate root
  invocation"*, and this reviewer's shell cannot sudo. So `require_rootless`'s
  refusal, the warning it prints, and every `[[ $EUID -eq 0 ]]` early-return in the
  preflights (`check_subuid_subgid`, `check_linger_if_quadlet`,
  `check_ip_unprivileged_port_start`, `detect_rootless_network`) are unmeasured
  here. This matters for **P4-1** in particular: the reasoning that rootless
  confines a `--privileged` container does not apply on that path, and the
  escalation there is bounded only by root itself — asserted from the code, not
  measured, and recorded as such.
- **SELinux-enforcing behaviour** (`check_selinux_label`, the `:z` suffix logic) was
  not exercised — this host is not enforcing, so `check_selinux_label` returns
  empty and every relabel branch was dead during this audit.

## 4. Investigated and cleared (so it is not re-raised)

- **`cmd_up`'s `trap "_partial_up_cleanup_4 '${lab_name}'" EXIT` (line 1237).**
  Same interpolated-trap shape as Phase 3's, and safe for the same reason:
  `validate_name` runs at line 1168, *before* the trap is installed, and its regex
  admits no quote, space or `$`. Cleared on success (line 1306). Its
  fresh-vs-incremental split is deliberate and correct: with nothing pre-existing
  it calls `cmd_down` for a full rollback; otherwise it diffs pod/container/network
  IDs against the pre-run snapshot so a healthy lab survives a failed incremental
  `up`.
- **`resolve_userns_flags`.** Finding 2's nameref conversion is genuinely correct —
  the raw-uidmap branch validates each `N:N:N` segment before use, and no path
  returns a string that a caller word-splits. This is the pattern P4-1 needs.
- **`stop_lab_quadlet`'s symlink handling (lines 973–998).** Finding 15's guard
  holds: `readlink -f` then a prefix test against `QUADLET_USER_DIR`, refusing (and
  removing only the link) when a target points elsewhere. A replaced symlink cannot
  make `down` delete arbitrary user files.
- **My own first attempt at a P4-3 control.** Making the quadlet directory
  unwritable "proved" the write succeeded — because `install -d -m 0755` reset the
  mode before writing (see §3). The finding stands, but the first control was
  measuring nothing; recorded because a control that silently defeats itself is
  exactly the failure mode this repo's conventions exist to catch.

## 5. Feature completeness

Phase 4's surface is the widest of the container phases and is coherent: three
runtime modes (plain, pod, quadlet), four image sources (image, from-chroot with a
readability preflight, from-tarball, build), six arches, rootless preflights that
name the fix command for subuid/linger/unprivileged-port-start, `--userns`
including raw uidmaps, CDI device passthrough (`nvidia.com/gpu=all`), SELinux
relabel handling, `inspect --json` covering **both** containers and pods behind a
`kind` discriminator, two export formats (`kube` via podman itself, `compose`
synthesized), and `generate` as a units-only sibling of `up`. Stated limitations
carry reasons in-code (quadlet mode does not auto-build). No missing feature rises
to a finding.

## 6. Calibration — good patterns preserved

`sanitize_unit_value` is the model the rest of this review keeps pointing back to:
one primitive, applied at **every** field of the artifact it protects, with the
injection it prevents named in the comment. Finding 2's nameref fix removed a
word-splitting class rather than patching an instance. The `awk`-based subuid
lookup (Finding 11) is a real outcome-vs-mechanism fix — `grep "^user:"` matching
`alice.bob` against `aliceXbob` is precisely the "cheap check is a different
question" trap. Review M3's `:z`-over-`:Z` default is documented with the failure
it avoids (locking the host out of its own files). The `pod inspect` array/object
shim carries both the podman-5 breakage *and* the note that an apostrophe in that
very comment would terminate the enclosing jq program — a comment that records its
own near-miss. `cmd_export`'s gate placement (lines 1828–1840) was moved *inside*
the format branches on the reasoning that a usage error must be diagnosable
without a working podman, and that a pure text transformation must not require a
container engine — which is exactly right, and is why P4-5's compose path is
reachable on a podman-less host and worth fixing there.

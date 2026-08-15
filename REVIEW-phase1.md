# Review — Phase 1 (`phase1-chroot/lab-chroot.sh`)

**Date:** 2026-08-12
**Scope:** Phase 1 only — `lab-chroot.sh` (2506 LOC), its `tests/`, and the
shared harness-net checker as it applies to Phase 1. Audited for **safety**
(host damage), **soundness** (correctness/data-integrity), **security**
(isolation/injection), and **feature completeness**.
**Method:** the driver read end-to-end; every finding reproduced from the
running script (this pass ran as root, so the root-gated paths were exercised,
not just reasoned about) with a control before being recorded. Builds on the
prior [`REVIEW-phases-1-5.md`](REVIEW-phases-1-5.md) (2026-07-08) and
[`AUDIT.md`](AUDIT.md) — the H1 mount-guard and the F7/F8 items there were
re-checked against today's code.

---

## 1. Verdict

Phase 1 remains one of the more disciplined shell codebases in the repo: `set
-euo pipefail`, TOML→JSON→`jq --arg` (no `eval`/`source` of config), a strict
`validate_spec` name regex, `_safe_rm_rf` with a `/proc/mounts` ground-truth
sweep, kill-by-nothing (no `pkill`), awk-parsed `os-release`, and an in-tree
audit trail of ~18 prior numbered findings. The happy paths and declared
guardrails are well tested (12 pass / 10 self-skip here, 0 fail).

The residue is **three real defects**, none an open barn door, but two of them
reopen guarantees the repo already believes it closed:

> **Status 2026-08-15: all three are FIXED**, each with a regression test that runs
> **unprivileged** — deliberately, since Phase 1's pre-existing mount test was root-gated and
> therefore skipped on every CI run, which is how this class of guard rots unwatched. Each test
> carries a **negative control** that re-injects the original defect and watches the
> assertion bite, and each fix was additionally verified by reverting it in the driver.
> **§3's two minor items are now fixed too** (see §3), along with a root-gated test that had
> been skipping on every CI run (§3b) — and un-gating it found a further defect in the test
> itself. The `tests/` count went 10 passed / 12 skipped → **15 passed / 11 skipped, 0 failed**.
> Fixing §3's export item also turned up something the review had filed as "mild": the
> existing `-e` guard is defeated by a **dangling symlink**, in a root-run verb writing to a
> predictable name in a world-writable directory.

- **P1-1 (MED)** — ✅ **FIXED 2026-08-15.** Path-mode verbs bind to the wrong chroot by
  basename collision; `destroy` on an unrelated path silently **orphans** a managed
  chroot (tree survives, manifest deleted, invisible to `list`).
- **P1-2 (MED, conditionally HIGH)** — ✅ **FIXED 2026-08-15.** The H1 fail-closed `rm -rf`
  mount guard is **blind to any chroot path containing a space**, reopening the exact
  host-`/dev`-deletion class H1 exists to prevent.
- **P1-3 (LOW/process)** — ✅ **FIXED 2026-08-15.** `tools/check-harness-net.sh` still can't
  see a **multi-line** `trap … EXIT`; one Phase 1 test disarms the safety net and the
  checker passes anyway. A liar-checker of the class CLAUDE.md itself documents.

All three were reproduced. A fourth suspicion (a stdin-reading `post_command`
draining the multi-spec config stream) was **investigated and cleared** by a
negative control — recorded in §4 so it is not re-raised.

---

## 2. Findings

### P1-1 — MED — path-mode name synthesis collides with real manifests — ✅ FIXED 2026-08-15

> **Fixed**, via this section's option (a). A path-mode chroot with no matching manifest now
> gets the sentinel name `(unmanaged)` — parentheses are outside `validate_spec`'s
> `[a-zA-Z0-9_.-]+`, so it **cannot be the key of a manifest that exists** — and
> `read_manifest_field`/`remove_manifest` refuse that name by name.
>
> Guarding the two **accessors** rather than each of the ~10 call sites was deliberate: it
> makes a call site added later safe by *default*, whereas a per-site fix silently reopens
> the hole the first time someone forgets one. Anything that wants something to *print*
> (the destroy prompt, `inspect`'s name row and `.name`, the default `/tmp/<x>.tar.gz` /
> `.ext4` / `-initrd.gz` / `-vmlinuz` outputs, the `enter …` hints) calls the new
> `chroot_label NAME TARGET`, which falls back to the target's basename — so user-visible
> output and the `inspect --json` contract are **unchanged**.
>
> **Correction to this finding as written:** `verify` does *not* leak. It reads no manifest
> fields at all — only `target`, `/etc/os-release` and `uname`. `inspect` was the only
> leaking verb, and it is fixed.
>
> Regression: [`phase1-chroot/tests/test-path-mode-name-collision.sh`](phase1-chroot/tests/test-path-mode-name-collision.sh),
> which runs **unprivileged and builds no chroot** — the defect is entirely in name
> resolution, so the fixture is one manifest (written by the driver's own `write_manifest`,
> not hand-rolled, so it cannot drift from the schema) plus two empty directories. It covers
> all three symptoms, and the privilege-gate one is *sharpest* as an ordinary user, since
> that is exactly who the flipped gate would have let through. Five sections: the leak, the
> gate, the orphaning, a **control** that lookups by a real name still resolve (without it,
> a guard that broke `read_manifest_field` for *every* name would pass everything above),
> and a **negative control** that re-injects the basename synthesis and watches it orphan
> the managed chroot. Reverting the fix in the driver was also run, and the test failed on
> the leak assertion.


`resolve_target_and_manager()` (line ~1273), given an absolute path with **no
manifest whose `target` matches**, synthesizes the chroot name from the path's
basename:

```sh
printf '%s\t%s\t%s\n' "${arg##*/}" "$arg" "none"
```

Every path-mode verb then calls `read_manifest_field "$name" …` /
`remove_manifest "$name"` with that synthesized basename — and `manifest_path`
maps a **bare name**, not a path. So the lookups silently bind to any *unrelated*
managed chroot that happens to share the basename.

`cmd_destroy` is the damaging one: it tears down the path it was given (correct),
then runs `remove_manifest "$name"` against the colliding manifest.

**Reproduced (as root):**
```
$ lab-chroot create --backend host-copy --target .../real/shared --name shared --binaries /bin/ls
$ mkdir -p .../elsewhere/shared          # unrelated directory, same basename
$ lab-chroot destroy .../elsewhere/shared --force
[info] destroyed: shared
$ ls $STATE/chroots/                       # -> empty: shared.toml is GONE
$ [ -d .../real/shared ] && echo ORPHANED  # -> ORPHANED (tree on disk, no manifest)
$ lab-chroot list                          # -> shows nothing; the managed chroot is now invisible
```

Two secondary effects from the same root cause:
- **`inspect`/`verify` leak a foreign chroot's metadata.** `inspect
  .../elsewhere/box` on an empty unrelated dir printed the managed `box`'s
  `backend=host-copy` and `lab=SECRETLAB`. (Reproduced.)
- **The misread `rootless` field can flip the privilege gate.** `cmd_destroy`
  reads `rootless` by the synthesized name; a colliding `rootless=true` manifest
  would make it skip the `EUID==0` requirement for a path that is *not* that
  rootless tree.

**Fix direction:** in path-mode with no matching manifest, do **not** reuse the
basename as a manifest key. Either (a) return an explicit sentinel name (empty /
`__unmanaged__`) and have `remove_manifest`/`read_manifest_field` no-op on it, or
(b) only `remove_manifest` when a manifest was actually *matched by target* in
the scan loop (track a `matched` flag), never by basename. `enter`/`inspect`/
`export-*` should likewise treat "path had no manifest" as "no manifest fields",
not "look one up by basename."

### P1-2 — MED (conditionally HIGH) — the H1 mount guard is blind to spaces in the target path — ✅ FIXED 2026-08-15

> **Fixed.** `_mounts_under` now decodes `/proc/mounts`' octal escapes (`\040` `\011` `\012`
> `\134`) before **both** the comparison and the output — the output too, because the caller
> feeds each line straight to `umount -l "$mp"`, which would choke on a literal `\040`. A
> mountpoint containing a *newline* still cannot be unmounted through this line-oriented
> interface, but it is now **detected**, so `_safe_rm_rf` refuses instead of recursing: the
> failure moves from "silently deletes the host's `/dev`" to "refuses and says why".
>
> Regression: [`phase1-chroot/tests/test-mount-guard-escaped-paths.sh`](phase1-chroot/tests/test-mount-guard-escaped-paths.sh).
> It runs **unprivileged** — it re-execs itself inside `unshare -rm`, so a bind mount needs
> CAP_SYS_ADMIN only in its own namespace. That was deliberate: Phase 1's other mount test is
> root-gated and therefore skipped on every CI run, which is how a guard rots unwatched.
> **Unprivileged is not automatically CI-wide**, though: Ubuntu 24.04 sets
> `kernel.apparmor_restrict_unprivileged_userns=1`, so on a stock runner this skipped too
> (measured on PR #199) — CI now relaxes that sysctl and warns in the log if it cannot.
> Three assertions, two of them controls: the positive (guard sees the mount, `_safe_rm_rf`
> refuses, bind source intact); a **space-free tree with no mounts is still removed**, so the
> positive cannot be passing because the guard began refusing everything; and a **negative
> control that re-injects the pre-fix parser and watches it delete the bind source through
> the live mount**. Reverting the fix in the driver was also run, and assertion 1 bit with
> its named `REGRESSION:` message.


`_mounts_under()` (line ~977) is the ground truth behind both
`_force_unmount_tree` and the fail-closed assertion in `_safe_rm_rf` that H1
added. It matches the target against field `$2` of `/proc/mounts` **literally**:

```awk
$2==t || index($2, t "/")==1 { print length($2) "\t" $2 }
```

But `/proc/mounts` **octal-escapes** whitespace: a mount at `/x/spacey dir/dev`
appears as `/x/spacey\040dir/dev`. The literal compare never matches, so a live
bind mount under a space-bearing chroot path is **not detected** — neither
force-unmounted nor caught by the "still has active mounts — refusing rm -rf"
assertion. `rm -rf` then recurses straight through the live bind (host `/dev`),
which is precisely the H1 incident.

**Reproduced (as root):**
```
$ mount -t tmpfs tmpfs "$PWD/spacey dir/tree/dev"
$ grep -c spacey /proc/mounts          # -> 1  (kernel sees the mount)
$ _mounts_under "$PWD/spacey dir/tree" | wc -l   # -> 0  (the guard does NOT)
```

The code comment on `_mounts_under` waves this away —"lab targets live under the
state dir and don't contain such characters" — but that is only true for the
auto-derived state path. **Path-mode `enter` and `destroy` accept an arbitrary
absolute path from the user**, `bind_essentials` will mount `/dev` et al. under
it, and nothing rejects a space. The guarantee is asserted, not enforced.

**Fix direction:** decode the octal escapes before comparing (un-escape `\040`
`\011` `\012` `\134` in `$2`), or compare on device/inode rather than the path
string. Alternatively (defense in depth) reject whitespace in `--target` at
`validate_spec` the way the *name* is already regex-gated — but the decode is the
real fix, since `enter <path>` never goes through `validate_spec`.

### P1-3 — LOW / process — the harness-net checker misses multi-line EXIT traps — ✅ FIXED 2026-08-15

> **Fixed.** `tools/check-harness-net.sh`'s §1 is no longer a regex over a physical line:
> it is a bounded lexer (`_exit_trap_offenders`) that tracks quoting, comments, heredocs
> and backslash-continuations and asks *"is `trap` run as a command here, with `EXIT`
> among its arguments?"* — the property, not its usual textual shape. The three tests it
> had been passing over (`phase1-chroot/tests/test-cli-vs-config-parity.sh`,
> `phase4-podman/` and `phase5-lxd/tests/test-inspect-json.sh`) now register teardown with
> `on_exit` instead; the phase-4 and phase-5 ones were re-run live and their cleanup
> verified by the absence of leftover containers/instances, not by the call alone.
>
> **The durable part is §1a.** Sections 2–6 of that checker each prove themselves against a
> fixture; §1 never did, which is precisely why §1 is the section that has now been wrong
> twice — *a scan that matches nothing and a scan that is broken print the same green ✓*.
> §1 now runs the scanner over **8 shapes it must catch and 8 it must not** before it is
> pointed at any real test, in every suite, on every invocation. Both historical
> regressions were re-injected and watched to bite (the 2026-08-08 line anchor: blind to 5;
> the 2026-08-12 single-line match: blind to 4), as was an over-firing scanner (6 false
> positives). The controls also found a **third** blind spot neither audit named:
> `if true; then trap 'x' EXIT; fi` — `then` is not one of the `; && || | ( ) { }`
> separators, so the 2026-08-12 pattern missed it as well.



`tools/check-harness-net.sh` enforces the CLAUDE.md rule that no test may install
its own `trap … EXIT` (which silently replaces `lib.sh`'s verdict net). Its awk
matches `trap … EXIT` **on a single physical line**:

```awk
/(^|[;&|(){}])[[:space:]]*trap[[:space:]]+.*[[:space:]]EXIT([[:space:]]|;|$)/
```

`phase1-chroot/tests/test-cli-vs-config-parity.sh` opens with a **multi-line**
trap:

```sh
trap '
    cleanup_target "$t_cli" "$n_cli"
    ...
' EXIT
```

`trap` and `EXIT` are on different lines, so the pattern never matches. The
checker prints *"no test overrides lib.sh's EXIT trap at any command position,
mid-line included (22 files checked) ✓"* and **PASSES** — while that test has in
fact replaced the net. If the parity test dies early (e.g. an uncaught `create`
failure under `set -e`), its own trap runs cleanup and it exits **with no
verdict line** — the silent-exit defect the whole mechanism exists to prevent.

This is the same "liar-checker" shape the CLAUDE.md history describes: the
2026-08-08 rewrite added the `; && || | ( ) { }` command-position anchor and its
comment claims *"mid-line included,"* but a trap body that spans lines still
slips past. Repo-wide the blind spot also hides `phase4-podman/tests/test-inspect-json.sh`
and `phase5-lxd/tests/test-inspect-json.sh` (out of Phase 1 scope, noted for the
shared-tool fix).

**Fix direction:** scan logically, not by physical line — e.g. slurp each file
and match `trap` at a command position whose argument list reaches an unquoted
`EXIT` (a multi-line-aware regex, or a token pass). Then convert the parity test
(and the two phase-4/5 siblings) to `on_exit '<cmd>'`, and re-inject a multi-line
trap to watch the check bite.

---

## 3. Minor / robustness (not security) — ✅ BOTH FIXED 2026-08-15

- **Relative `--target` breaks every `write_files` entry.** The jail check
  compares an absolute `realpath -m` result against a *relative* `$target/`
  prefix, so a legitimate relative target refuses all writes:
  `write_files[1]: path '/hello.txt' escapes chroot root — refusing` (reproduced).
  Fail-closed, so not a hole — but it rejects a valid config. Normalize `target`
  to absolute once, early (it is already assumed absolute by `_safe_rm_rf` and
  the manifest). 

  > **Fixed** by `spec_absolutize_target`, applied once in `create_one` right after
  > `validate_spec` — one chokepoint rather than the **seven** `spec_get "$spec" target`
  > call sites, for the same reason as P1-1's accessor guard: a call site added later is
  > then correct by default. Regression:
  > [`tests/test-relative-target.sh`](phase1-chroot/tests/test-relative-target.sh), which
  > runs unprivileged. Its most important section is not the fix but the **security
  > control**: normalizing the target changes what a traversal jail compares against, so it
  > re-runs `path = "/../escapee.txt"` against *both* relative and absolute targets, asserts
  > both are refused, and greps the whole scratch tree to confirm nothing escaped. A "fix"
  > that let traversal out would have been far worse than the bug.

- **Default export outputs collide on basename.** `export-tarball` /
  `export-initrd` default to `/tmp/<name>-…` keyed on basename and overwrite
  without `--force` (only `export-rootfs` refuses an existing file). Two chroots
  sharing a basename silently clobber each other's artifacts, and a predictable
  `/tmp` name is a mild clobber/symlink vector. Consider `mktemp`-style suffixes
  or the `--force` gate `export-rootfs` already has.

  > **Fixed** with the `--force` gate, hoisted into one shared `refuse_existing_output`
  > called by all **four** output paths (tarball, initrd, extracted kernel, rootfs), before
  > any work is done rather than after.
  >
  > **And the symlink half turned out to be more than "mild".** The pre-existing
  > `export-rootfs` guard tested `[[ -e "$out" ]]` — and **`-e` follows the symlink**, so a
  > *dangling* symlink at the output path reads as "does not exist", the guard stays quiet,
  > and the write lands on the link's target. `/tmp/<basename>.ext4` is a predictable name
  > in a world-writable directory and **`export-rootfs` runs as root**, which makes that an
  > arbitrary-file-write primitive, not a clobber. The shared guard tests `-L` first, and
  > **`--force` does not override it** — `--force` means "I accept losing the file at this
  > path", not "follow a link somewhere else".
  >
  > Regression: [`tests/test-export-output-guards.sh`](phase1-chroot/tests/test-export-output-guards.sh),
  > unprivileged. Both defects were re-injected and watched to bite (removing the tarball
  > guard → the clobber assertion fired; restoring the `-e`-only check → the dangling-symlink
  > assertion fired). §4 asserts all four paths call the *one* guard, so the evidence carries
  > to root-only `export-rootfs`, which the test cannot execute.

## 3b. Also fixed in the same pass — a test that skipped on every CI run

[`tests/test-destroy-mount-guard.sh`](phase1-chroot/tests/test-destroy-mount-guard.sh) — the
H1 regression test — opened with `require_root`, so on any unprivileged run it **SKIPped**,
and the guard it exists to protect went unwatched. A bind mount needs `CAP_SYS_ADMIN` only in
the namespace doing the mounting, so it now re-execs itself into `unshare -rm` (same shape as
the two tests written for P1-2 and P1-1) and CI enables the sysctl that permits it.

Un-gating it immediately paid for itself. Re-injecting the H1 defect showed the test **dying
with no verdict** — `manager_none_destroy` was called bare, so `_safe_rm_rf`'s `die` blew past
every assertion and the run ended on the harness net's generic *"test exited early (rc=1)"*.
A net firing is not a diagnosis. The call is now subshelled and the two failure modes are
told apart by name: *"the first guard is broken and only `_safe_rm_rf`'s fail-closed
assertion stopped it"* versus *"the rm recursed through the bind"*. Verified: zero generic
net-only failures, one specific `REGRESSION:` line.

**Phase 1 tests: 15 passed, 11 skipped, 0 failed** — from 10 passed / 12 skipped when this
review was written.

## 4. Investigated and cleared (so it is not re-raised)

- **stdin-reading `post_command` draining the config spec stream.** Hypothesis:
  `cmd_create`'s `while read spec; do create_one; done < <(specs_from_config)`
  gives every `chroot_exec bash -c "$cmd"` fd 0 = the spec pipe, so a
  `post_command` that reads stdin would eat the later specs. **Control run
  disproved it:** two specs, spec-1 `post_commands=["cat >/dev/null"]`, both
  built. `apply_post_commands` runs its command inside an inner `while … done <
  <(jq … post_commands)`, so the `cat` drains the *post-commands* stream (its own
  last line), not the outer spec stream. No defect. (An earlier apparent skip was
  a `die` on a `bash`-less host-copy tree, not FD consumption — caught by adding
  `bash` to the tree and re-running.)

## 5. Feature completeness

Phase 1's declared surface is complete and internally consistent: three backends
(debootstrap / dnf / host-copy), three managers (none / schroot / nspawn), six
arches with foreign-arch via qemu-user-static + binfmt, rootless via
fakechroot+fakeroot (honestly documented as *not* a sandbox), CLI/TOML parity
(test-verified identical trees), and four export bridges to later phases
(tarball → P4, initrd → netboot, rootfs → P7/Firecracker, plus `inspect --json`
for P6). Gaps are intentional and stated in-code with reasons (XFS/squashfs
refused by `export-rootfs`; dnf limited to Rocky; foreign-arch dnf flagged
experimental). No missing feature rises to a finding.

## 6. Calibration — good patterns preserved

Real-parser TOML→jq with `--arg` (no shell-injection surface); strict name
regex + dot-prefix rejection guarding `manifest_path`/`schroot_conf_path`/
`nspawn_machines_link`; dnf suite constrained to a version number (repo-file
injection closed); schroot/chpasswd newline stripping; `write_files` `realpath`
jail (holds for absolute targets); `_safe_rm_rf` depth + absolute + `/` guards;
awk-parsed `os-release`; the `bind_essentials` symlink-pre-truncation guard
(Finding 10); and honest three-outcome verification in `export-rootfs`
("UNKNOWN ≠ pass"). The two host-touching defects above are edge-condition holes
in otherwise-sound guards, not absent guards.

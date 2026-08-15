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

- **P1-1 (MED)** — path-mode verbs bind to the wrong chroot by basename
  collision; `destroy` on an unrelated path silently **orphans** a managed
  chroot (tree survives, manifest deleted, invisible to `list`).
- **P1-2 (MED, conditionally HIGH)** — the H1 fail-closed `rm -rf` mount guard
  is **blind to any chroot path containing a space**, reopening the exact
  host-`/dev`-deletion class H1 exists to prevent.
- **P1-3 (LOW/process)** — ✅ **FIXED 2026-08-15.** `tools/check-harness-net.sh` still can't
  see a **multi-line** `trap … EXIT`; one Phase 1 test disarms the safety net and the
  checker passes anyway. A liar-checker of the class CLAUDE.md itself documents.

All three were reproduced. A fourth suspicion (a stdin-reading `post_command`
draining the multi-spec config stream) was **investigated and cleared** by a
negative control — recorded in §4 so it is not re-raised.

---

## 2. Findings

### P1-1 — MED — path-mode name synthesis collides with real manifests

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

### P1-2 — MED (conditionally HIGH) — the H1 mount guard is blind to spaces in the target path

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

## 3. Minor / robustness (not security)

- **Relative `--target` breaks every `write_files` entry.** The jail check
  compares an absolute `realpath -m` result against a *relative* `$target/`
  prefix, so a legitimate relative target refuses all writes:
  `write_files[1]: path '/hello.txt' escapes chroot root — refusing` (reproduced).
  Fail-closed, so not a hole — but it rejects a valid config. Normalize `target`
  to absolute once, early (it is already assumed absolute by `_safe_rm_rf` and
  the manifest). 
- **Default export outputs collide on basename.** `export-tarball` /
  `export-initrd` default to `/tmp/<name>-…` keyed on basename and overwrite
  without `--force` (only `export-rootfs` refuses an existing file). Two chroots
  sharing a basename silently clobber each other's artifacts, and a predictable
  `/tmp` name is a mild clobber/symlink vector. Consider `mktemp`-style suffixes
  or the `--force` gate `export-rootfs` already has.

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

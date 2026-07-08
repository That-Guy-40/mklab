# Review — Phases 1–5 (the host-touching drivers)

**Date:** 2026-07-08
**Scope:** the five Bash phase-drivers that actually touch the host —
`phase1-chroot/lab-chroot.sh`, `phase2-qemu-vm/lab-vm.sh`,
`phase3-docker/lab-docker.sh`, `phase4-podman/lab-podman.sh`,
`phase5-lxd/lab-lxd.sh` (~11k LOC total). Phases 6/6b (the read-only TUI/web
surfaces) were out of scope by request.
**Method:** each driver read end-to-end, `shellcheck -x`'d, and its test suite
audited; every finding was verified against the code (line-cited) with a
concrete failure scenario before being recorded.
**Relationship to [`AUDIT.md`](AUDIT.md):** that audit (2026-05-20) was a
repo-wide static pass. This review re-checks the phase drivers against **today's**
code — after the May per-phase hardening wave (commits `64c4887`, `2f99362`,
`c0a02bf`, `275b5dc`, `61ded02`, which closed ~100 numbered findings) — with a
sharper focus on host-damage, lab-escape, and cleanup-correctness. It also
**fixes** the issues it found; see *Status* per finding.

---

## 1. Verdict

The toolkit is genuinely well-built and security-conscious — better than almost
any shell codebase of this size. All five drivers use `set -euo pipefail`, parse
TOML through a real `→ JSON → jq --arg` pipeline (no `eval`, no `source`, no
config string ever reaching a shell), validate the primary lab name against a
strict regex, kill by PID, and carry an in-tree audit trail of prior hardening.
The injection surface is closed at nearly every point.

The residue was **not open barn doors** — a handful of edge defects that cluster
into a few repeated *shapes*. Two could damage the **host** (not just the lab);
the rest were lab-scoped data-loss or correctness bugs. All HIGH and MED items
below were fixed in this pass, each with a regression test where one was runnable.

## 2. Cross-cutting patterns (fix the class, not the instance)

The same mistake recurred across drivers — the valuable part of the review.

1. **`destroy` was name-scoped while `down` was label-scoped.** Every phase's
   `down` filters teardown on *both* `lab-create.tool=<this tool>` **and**
   `lab-create.lab=<name>`, so a student's `down` can't reap another student's
   containers. But `destroy` resolved a name → `lab-<x>` and force-removed
   whatever *had that name*, with no ownership check. **Fixed in all three
   container/instance phases** (M2).

2. **The partial-`up` cleanup trap tore down the *whole* lab on an incremental
   re-`up`.** `up` is idempotent ("existing services left as-is"), so re-running
   it to add one service is supported — but the failure trap ran a full
   label-scoped `down`, wiping the previously-healthy instances too. **Fixed** by
   a transactional rollback: snapshot the lab's resources *before* the run, and on
   failure remove only what appeared *this run* (H4).

3. **Cleanup traps whose *type* was wrong for `die`-based code.** `die` is
   `exit`; a `RETURN` trap never fires on `exit`, and a later `trap … EXIT`
   silently replaces an earlier one (one handler per signal). This leaked
   root-owned loop devices + live mounts (phase 2), and clobbered the caller's
   EXIT trap (phase 5). **Fixed** by moving each resource-owning body into a
   **subshell with a single EXIT trap** — fires on `die`, and is subshell-local
   so it cannot clobber the caller's trap (H2 + trap-shape class).

4. **TOML sub-element names / positional values skipped the validation the lab
   name got.** The image value is the first *positional* to `docker run`, so
   `image = "--privileged"` injected flags (M1). Service/pod/instance names
   weren't run through `validate_name` (noted; traversal is contained by the
   `lab-<lab>-` prefix — see *Deferred*).

## 3. Findings & status

Severity: **HIGH** = host damage or silent data loss · **MED** = isolation/
correctness · **LOW** = polish. All HIGH+MED fixed this pass.

| # | Sev | Phase | Finding | Status |
|---|-----|-------|---------|--------|
| **H1** | HIGH | 1 | `destroy` trusted `.lab-chroot-mounts`; a stale/missing file while `/dev` was bind-mounted let `rm -rf` recurse into the host's real `/dev`. | **Fixed** — `/proc/mounts` ground-truth sweep + force-unmount before any `rm -rf`, and a fail-closed assertion at the single `_safe_rm_rf` chokepoint. Test: `test-destroy-mount-guard.sh` (root-gated). |
| **H2** | HIGH | 2 | `backend_vm_from_chroot` cleanup was a `RETURN` trap → never fired on `die`, leaking a root-owned loop device + live mount per failed build. | **Fixed** — subshell + EXIT trap (`ok=1` success flag keeps the output). Test: `test-from-chroot-cleanup.sh` (root-gated; stubs `mkfs.ext4` to force mid-build failure, asserts the loop device was detached). |
| **H3** | HIGH | 5 | `backend_from_chroot` used `tar -h`, dereferencing **every** symlink: absolute symlinks baked host files into the image; a dangling symlink (systemd's `/etc/resolv.conf → /run/…`) aborted the build under `set -e`. | **Fixed** — tar the chroot directly under a `rootfs/` prefix via `--transform`, no `-h`; symlinks preserved as symlinks. Test: `test-from-chroot-symlink.sh` (no root needed, **green**). |
| **H3b** | HIGH | 3·4·5 | *Same code path:* the readability preflight `find … -not -readable` flagged a **dangling symlink** as "unreadable" and `die`d before tar — so `from_chroot` broke on any systemd chroot regardless of H3. | **Fixed** — `! -type l` guard in all three phases (a symlink is never an "unreadable file"; its real in-chroot target is still walked). |
| **H4** | HIGH | 3·4·5 | Partial-`up` trap force-deleted healthy pre-existing instances on an incremental re-`up` (pattern ②). | **Fixed** — transactional rollback (snapshot-before, diff-after; phase 4 also gates the quadlet blanket-stop on "was this a fresh up"). Test: `test-partial-up-rollback.sh` (phase 3, **green** — proves pre-existing survives *and* new is rolled back). |
| **M1** | MED | 3 | `image = "-…"` in a topology injected flags into `docker run` (first positional), defeating the "no privileged / no host-mounts from config" posture. | **Fixed** — reject `-`-leading image in `up` and `run` (the guard already used for push tags / net drivers). |
| **M2** | MED | 3·4·5 | `destroy` lacked the tool-label ownership guard `down` has (pattern ①). | **Fixed** — `destroy` now requires the `lab-create.tool` label; refuses an unowned like-named container/instance with a clear error. |
| **M3** | MED | 4 | Auto-`:Z` recursively relabeled the host tree with a private MCS category → mounting `/usr`/`/home` could lock the host out of its own files. | **Fixed** — default to `:z` (shared) and `log_warn` the relabel; explicit `:Z`/`:z`/`:O` still honored. |
| **M4** | MED | 2 | Manifest field injection via un-escaped **newline** (the fix only escaped `"`): `--append $'…\nnetwork_mode = tap'` silently flipped a VM's network/disk on re-read. | **Fixed** — `_mf_clean` strips CR/LF *then* escapes `"`, applied to every free-text field. |
| **M5** | MED | 5 | `exec`/`logs`/`status`/`destroy` ignored `--project` → instances in a `[[project]]` were unreachable. | **Fixed** — `_instance_project` finds the instance across all projects; each verb re-scopes `--project`. |
| **M6** | MED | 5 | `list` (and the both-engines-down diagnostic) exited 1 on zero results because `grep -c`/a failing pipeline returns non-zero under `set -e`. | **Fixed** — `\|\| true` on the count and the diagnostic substitutions. |
| **M7** | MED | 2 | `default_pubkey`'s `ecdsa- ` regex never matched real `ecdsa-sha2-nistp256` keys → ECDSA-only users silently fell back to `lab`/`lab` password auth. | **Fixed** — match a known type prefix + `[^ ]*` + space; covers ecdsa-sha2-* and sk-* hardware keys (verified against all key types). |
| **L2** | LOW | 3·4 | `… ps -a \| grep -qx` existence checks: SIGPIPE-invertible under `pipefail`; `.` in a name is a regex wildcard. | **Fixed** (folded into M2) — read names into a var, match with `grep -Fxq`. |
| **—** | LOW | 3·5 | Source guard inconsistency: phase 3 used `[[ … ]] && main` (returns 1 when sourced, trips a caller's `set -e`); phase 5 had **no** guard (`main` ran on `source`). | **Fixed** — both normalized to the `if … then main; fi` form (matches phase 1/2/4), enabling unit tests to source them. |

### Trap-shape class — full sweep (phase 5)

Beyond H2, the phase-5 VM/image staging functions all had the wrong-trap-type /
trap-clobbering shape and were converted to the subshell+EXIT idiom:
`backend_from_chroot` (H3), `backend_from_tarball`, `backend_from_chroot_vm`
(was setting `RETURN EXIT INT TERM` traps that clobbered `cmd_up`'s partial-up
EXIT trap, disabling the H4 rollback mid-run), `backend_from_tarball_vm`, and
`backend_from_qcow2`. `backend_from_tarball_vm` also gained the
`--no-absolute-names` its container sibling already had.

## 4. Deferred / recommended

**A second pass (also 2026-07-08) closed the deferred items below.** What
remains is one intentional tradeoff, noted for the future.

- **L1 — compose/YAML export escaping.** **Fixed** — `_yaml_str` now escapes
  backslash-then-quote, and the free-text values (env values, ports, volumes)
  route through it; image/command/keys keep their original format.
- **Sub-element name validation.** **Fixed (phase 4)** — every service/pod name
  is run through `validate_name` up front in `cmd_up`, before any state dir or
  unit file is written. (Phases 3/5 already validated their sub-names.)
- **F4 — published ports default to loopback.** **Fixed** — a bare `"8080:80"`
  now binds `127.0.0.1` via a shared `_pub_host` helper at every publish site
  (run/pod/quadlet); an explicit bind IP is the opt-in to a wider bind, and
  `LAB_PUBLISH_HOST` overrides the default. Test: `test-publish-loopback.sh`.
- **F6 — CI.** **Fixed** — `.github/workflows/ci.yml` runs `bash -n` +
  `shellcheck`, the link/routing doc gates, the shell test suites (daemon/root
  tests self-skip), and pytest for phases 6/6b.
- **F9 — LICENSE.** **Fixed** — MIT `LICENSE` added at the repo root.

- **Phase-4 quadlet incremental residual (intentional tradeoff, not fixed).**
  The H4 rollback removes new containers/pods/networks on an incremental re-`up`,
  but a *new quadlet unit file* written for the failed service is left on disk
  (the next `down` clears it). Acceptable vs. the previous whole-lab teardown;
  noted for a future per-unit rollback.
- **F4's LAN-exposure default was a behavior change** — documented in the phase 3
  README ports row and the phase 4 SHOWCASE so existing labs know how to opt back
  into a wider bind.

## 5. Calibration — good patterns preserved

Real-parser TOML→jq (no shell-injection surface across 11k lines); strict
`validate_name` gates; **kill-by-PID** everywhere (phase 2's `cmd_stop` is
textbook); `/etc/os-release` awk-parsed, never sourced; label-scoped `down`;
per-VM qcow2 overlays so `destroy` never corrupts a shared base; sha256/sha512
verification of downloaded images (the May **F2** gap is closed); guarded
`_safe_rm_rf` on every teardown path; honest documentation of the
rootless/fakechroot boundary as *not* a sandbox.

## 6. Test-coverage note

The existing suites exercise happy paths and declared guardrails well, but none
exercised the risky isolation/cleanup paths this review targeted. Four regression
tests were added to close that gap:

| Test | Phase | Proves | Runs here |
|---|---|---|---|
| `test-destroy-mount-guard.sh` | 1 | destroy unmounts a live bind before `rm -rf`; never recurses into it | root-gated (skips) |
| `test-from-chroot-cleanup.sh` | 2 | cleanup trap fires on mid-build failure; no leaked loop device | root-gated (skips) |
| `test-from-chroot-symlink.sh` | 5 | symlinks preserved, no host leak, no build break | **green** |
| `test-partial-up-rollback.sh` | 3 | partial-`up` rolls back only this run's containers; pre-existing intact | **green** |

**Verification status:** all five drivers pass `bash -n` and `shellcheck -x`
(no new findings). The full non-root test set across all phases passes with no
regressions. The two root-gated tests (H1, H2) skip cleanly as non-root and are
ready to run under `sudo` on a host with loop devices + syslinux.

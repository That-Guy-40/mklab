# Codebase Audit — `mklab` / LAB_CREATE_V2

**Date:** 2026-05-20
**Scope:** Full repository at branch `claude/audit-codebase-pLsT1`
**Reviewer:** Automated code audit (read-only; no source files were modified)

> **Follow-up:** a deeper, phase-driver-focused review was done on 2026-07-08 —
> see [`REVIEW-phases-1-5.md`](REVIEW-phases-1-5.md). It re-checks phases 1–5
> against current code and fixes the HIGH/MED issues it found (host-damage,
> lab-escape, cleanup correctness) with regression tests. A companion review of
> the Phase 6 UIs (Textual TUI + FastAPI/HTMX web) followed the same day —
> see [`REVIEW-phase6.md`](REVIEW-phase6.md).

> **Remediation update (2026-07-24):** three findings below have since been
> addressed (annotated inline in the table and their detail sections):
> **F6 RESOLVED** — CI added: [`.github/workflows/ci.yml`](.github/workflows/ci.yml)
> runs shellcheck + `bash -n`, `link_check.py` + `paths.py --check`, the phase
> shell suites, and phase6 pytest on push/PR. **F9 RESOLVED** — top-level MIT
> [`LICENSE`](LICENSE) added. **F2 PARTIALLY RESOLVED** — cloud-image + Kali
> downloads are now SHA256-verified (`verify_sha256` in
> `phase2-qemu-vm/lab-vm.sh`); only the Alpine `--allow-untrusted` gap remains.
> Everything else in this 2026-05-20 snapshot stands as written.

---

## 1. Executive summary

`mklab` (internally "LAB_CREATE_V2") is a staged toolkit for spinning up
*throwaway* lab environments — chroots, QEMU VMs, Docker/Podman containers,
LXD/Incus instances, and a netboot pipeline — across six CPU architectures.
It is organized as five self-contained Bash phase-scripts (~9.3K LOC) plus a
Python/Textual TUI (~2.8K LOC) that surfaces them, all driven by declarative
TOML configs.

**Overall assessment: this is a well-engineered, unusually disciplined
codebase for a collection of shell scripts.** It shows deliberate attention
to safety (`set -euo pipefail` everywhere, reversible teardown, quoted
destructive ops), a clean architecture (TOML → JSON → `jq`; argv-list
subprocess in Python), strong documentation, and an extensive test suite.
There are **no critical or high-severity security defects.** The notable
findings are inherent to its "throwaway lab" purpose — weak default
credentials and unverified image downloads — and (as of the 2026-05-20 snapshot)
a process gap of no CI. *(That CI gap (F6) and the LICENSE gap (F9) have since
been closed, and image-download verification (F2) largely so — see the
Remediation update above.)*

### Findings at a glance

| # | Severity | Area | Finding |
|---|----------|------|---------|
| F1 | Medium | Security | Weak, hardcoded default credentials for VMs (`lab`/`lab`, root password `lab`, `ssh_pwauth: true`, NOPASSWD sudo); blank-password dropbear fallback for microvms |
| F2 | Medium | Security / Supply chain | ⚠️ **PARTLY RESOLVED (2026-07-24)** — cloud-image + Kali downloads are now SHA256-verified (`verify_sha256`, `phase2-qemu-vm/lab-vm.sh`); Alpine `--allow-untrusted` gap remains. *Original:* Downloaded cloud images & Kali archives are not checksum/signature-verified (SHA256SUMS is fetched but used only for filename resolution); Alpine uses `--allow-untrusted` |
| F3 | Low | Security | TOML configs execute arbitrary commands as root (`post_commands`, `init_script`); trust boundary not called out as such |
| F4 | Low | Security | Default port publishing binds `0.0.0.0` (all interfaces) for Docker/Podman labs |
| F5 | Low | Supply chain / Reproducibility | iPXE built from moving `master` ref; `debian:bookworm` base image unpinned (no digest) |
| F6 | Low | Process | ✅ **RESOLVED (2026-07-24)** — CI (`.github/workflows/ci.yml`) now runs the suites on push/PR. *Original:* Comprehensive test suites exist but there is no CI to run them automatically |
| F7 | Low | Robustness | `destroy` does `rm -rf -- "$target"` using the manifest's `target` value with no path-sanity guard |
| F8 | Info | Robustness | `--user name:pass` truncates passwords containing `:` |
| F9 | Info | Hygiene | ✅ **RESOLVED (2026-07-24)** — top-level MIT `LICENSE` added. *Original:* `pyproject.toml` declares MIT but no top-level `LICENSE` file exists |

---

## 2. Methodology

Static review of all shell and Python sources, plus the example TOMLs and
docs. Specifically scanned for: `eval`/`curl|bash` execution sinks, `sudo`
and privilege-escalation paths, temp-file handling, secret/credential
handling, destructive operations (`rm -rf`, `mkfs`, `dd`, loop mounts),
network downloads and their verification, TOML/config parsing as an
untrusted-input surface, Python `subprocess` usage (`shell=True`), committed
secrets, world-writable permissions, and error-handling discipline. No code
was executed.

---

## 3. Strengths

These are genuine and worth preserving:

- **Defensive shell discipline.** Every `.sh` file (verified across the
  whole tree) uses `set -euo pipefail`. Variables are consistently quoted;
  `rm -rf` calls use `--` and quoted operands and are paired with `trap`
  cleanup (e.g. `phase2-qemu-vm/lab-vm.sh:1842`,
  `phase1-chroot/lab-chroot.sh:828`).
- **No dangerous execution sinks.** No `eval`, no `curl … | bash`, no
  `os.system`. Config values flow through a **TOML → JSON → `jq`** pipeline
  (`phase1-chroot/lab-chroot.sh:176-194`, `:320-344`) using `--arg` /
  `--argjson`, which structurally avoids shell-string injection.
- **Injection-safe Python.** The TUI shells out exclusively via argv lists
  (`subprocess.run(argv, …)`, `asyncio.create_subprocess_exec(*argv)`) with
  **no `shell=True` anywhere** (`phase6-tui/lab_tui/backends/base.py:155`).
  The destroy command is even shown to the user in a confirm modal before it
  runs (`base.py:135-139`).
- **Reversible teardown.** Bind-mounts are recorded to
  `.lab-chroot-mounts` and unwound in reverse on destroy
  (`phase1-chroot/lab-chroot.sh:779-811`).
- **Clean architecture.** Backends are framework-agnostic (an explicit "NO
  `textual` imports here, ever" contract in `base.py:8`), use Pydantic
  models, and are reused as-is by the Phase 6b web UI (`phase6b-web/`). The bash/Python
  split — Python never reimplements provisioning, only surfaces it — is a
  sound boundary.
- **Repo hygiene.** No committed secrets or private keys, no world-writable
  `chmod`, and just **one** inline `TODO`/`FIXME` marker in the project's
  own source (`micro-linux/mlbuild.sh` — a since-resolved note; the
  deliberate `TODO.md` backlog doc is separate). `.gitignore`
  correctly excludes state, caches, venvs, and downloaded artifacts.
- **Documentation.** README, a 57 KB `PLAN.md`, a `NETBOOT_LAB_PLAN.md`, and
  per-phase `README` / `SHOWCASE` / `MANUAL_TESTING` docs. Comments explain
  *why* (trap-scope quirks, locale fallbacks, serial-console TERM handling)
  rather than narrating the obvious.
- **Tests.** Each phase ships an autotools-style suite (exit 77 = skip, 0 =
  pass) with a `run-all.sh`, including CLI-vs-config parity tests and JSON
  inspection contracts.

---

## 4. Security findings

### F1 — Weak, hardcoded default credentials (Medium)

**Where:** `phase2-qemu-vm/lab-vm.sh:1252-1278` (cloud-init seed),
`:1172` & `:1179` (Alpine microvm dropbear).

VMs are seeded with a known-weak posture:

- user `lab` with `plain_text_passwd: 'lab'`,
- root password set to `lab` via `chpasswd`,
- `ssh_pwauth: true`,
- `sudo: ALL=(ALL) NOPASSWD:ALL` (and a `doas permit nopass` rule on Alpine).

For microvms with `ssh=true` but no host pubkey, the script **clears the
root password entirely** and falls back to `dropbear -B` (blank-password
auth) — `:1172`, `:1179`.

**Assessment.** This is intentional for disposable labs and is honestly
disclosed in user-facing output ("default password 'lab'",
`lab-vm.sh:1998`). The risk is **deployment context, not the code**: QEMU's
default user-mode (slirp) networking with host-forwarding to `127.0.0.1`
contains it, but any VM bridged onto a routable network — or any forwarded
port bound beyond loopback — becomes a trivially-compromised box (`lab`/`lab`
+ passwordless root). The blank-password dropbear path is the sharpest edge.

**Recommendation.** Keep the convenience default, but: (a) prefer
pubkey-only and make password auth opt-in (`--insecure-password` or
similar); (b) avoid the blank-password dropbear fallback — refuse `ssh=true`
without a key, or generate an ephemeral keypair instead; (c) add a one-line
"do not expose these VMs to untrusted networks" banner to the README
security notes.

### F2 — Downloaded images are not integrity-verified (Medium)

> ⚠️ **PARTLY RESOLVED (2026-07-24):** cloud-image + Kali downloads are now
> SHA256-verified — `verify_sha256()` in `phase2-qemu-vm/lab-vm.sh` is called for
> cloud images and Kali, and the Kali path hard-fails if `SHA256SUMS` can't be
> fetched. The Alpine `--allow-untrusted` gap described below still stands. The
> original finding is preserved for the record.

**Where:** `phase2-qemu-vm/lab-vm.sh:433-506` (`cache_image`),
`:393-421` (`kali_resolve_suite`), `:752-767` & `:786` (Alpine apk).

`cache_image()` downloads cloud images (and, for Kali, a `.7z`) over HTTPS
and uses them directly — there is **no SHA256/GPG verification of the
payload.** The Kali path *does* fetch `/current/SHA256SUMS`
(`lab-vm.sh:404`), but only to parse the current filename/release tag — the
hash column is never compared against the downloaded file. Alpine artifacts
are installed with apk's `--allow-untrusted` (`:786`).

**Assessment.** TLS protects transit and the upstreams are reputable, so
this is not trivially exploitable. But there is no integrity pinning: a
compromised/typo-squatted mirror, an HTTP→HTTPS misconfig, or a tampered CDN
object would be accepted silently. It also undermines reproducibility.

**Recommendation.** Since `SHA256SUMS` is already being fetched for Kali,
extend it to actually verify the downloaded artifact (`sha256sum -c`).
Verify cloud images against upstream `SHA256SUMS`/`SHA512SUMS` where
published; drop `--allow-untrusted` in favor of Alpine's signed indexes
where feasible. At minimum, document that images are unverified.

### F3 — TOML configs run arbitrary code as root (Low / by-design)

**Where:** `phase1-chroot/lab-chroot.sh:1248-1262` (`apply_post_commands`
runs each string via `bash -c` inside the chroot), `:1182-1196`
(`init_script` copies an arbitrary host path in as `/init`).

A `--config` TOML is, effectively, **a root shell script**: `post_commands`
are executed verbatim and the README's quick-starts invoke
`sudo lab-chroot.sh create --config examples/…`. This is appropriate for the
tool's purpose, but the trust boundary is implicit.

**Recommendation.** Document explicitly that config files are
trust-sensitive and must not be run from untrusted sources under `sudo`.
This is a docs fix, not a code change.

### F4 — Default port publishing binds all interfaces (Low)

**Where:** `phase3-docker/lab-docker.sh:901`,
`phase4-podman/lab-podman.sh:1493` (both default `host_ip` to `0.0.0.0`).

Published lab ports default to `0.0.0.0`, exposing services on every host
interface. This is standard Docker/Podman behavior, but combined with lab
workloads it widens exposure more than a "throwaway local lab" implies.

**Recommendation.** Consider defaulting to `127.0.0.1` and making
all-interfaces an explicit opt-in, or at least note it in docs.

### F5 — Non-reproducible / unpinned build inputs (Low)

**Where:** `netboot/build-ipxe.sh:148` (`debian:bookworm`, no digest),
`netboot/ipxe-build-inner.sh:72` (iPXE default ref `master`),
`phase3-docker/lab-docker.sh:154` (`docker run --privileged tonistiigi/binfmt`
suggested for binfmt setup).

iPXE builds default to a moving `master` branch and an untagged base image,
so artifacts are not reproducible and silently track upstream drift.

**Recommendation.** Default `--ipxe-ref` to a tagged release; pin the base
image by tag+digest. The Python side is fine here — `pyproject.toml` uses
`>=` floors but `uv.lock` pins exact versions with hashes.

---

## 5. Fitness for purpose

**Strong.** The toolkit does what it claims, and the design choices match
the stated goal of *disposable, multi-arch lab environments*:

- **Coherent layering.** Phases are independent ("deleting later-phase
  directories does not break earlier ones") yet compose — `from-chroot`
  import bridges Phase 1 → 3/4/5, and the netboot pipeline chains
  chroot → initrd → iPXE → QEMU.
- **Two input paths, kept honest.** CLI flags and TOML are tested for
  byte-equivalent output (`test-cli-vs-config-parity.sh`), which is a
  thoughtful guarantee most tools skip.
- **Multi-arch is real**, not aspirational: `qemu-user-static` + `binfmt`
  for foreign-arch chroots, TCG system emulation for VMs, `buildx` for
  containers.
- **The TUI is appropriately scoped** — read-only inventory + cross-phase
  topology bring-up/tear-down, with create-wizards explicitly deferred. It
  surfaces the bash phases rather than duplicating them.

**Caveats.** The tool is inherently root-heavy (debootstrap, loop mounts,
`mkfs`, bind mounts, `extlinux`) and depends on a wide host toolchain
(`qemu-img`, `parted`, `rsync`, `genisoimage`/`xorriso`, a 7z extractor, a
TOML parser, `jq`, Docker/Podman/Incus). Preflight checks and install hints
are present and good, so this is documented friction rather than a defect.

---

## 6. Code quality & maintainability

- **Consistency across phases.** All five scripts share the same skeleton
  (logging helpers, `install_hint`, `require_cmd`, spec→JSON, `--config`
  handling), which makes the ~9K lines navigable.
- **Readable error handling.** `die`/`log_*` helpers, `${VAR:?msg}` required
  args, and targeted preflight diagnostics (e.g. the rpmkeys-missing message
  in `lab-chroot.sh:557-567`).
- **Minor robustness gaps:**
  - **F7 (Low):** `manager_none_destroy` / `destroy` run
    `rm -rf -- "$target"` using `target` read back from the manifest
    (`lab-chroot.sh:842-845`, `:896`, `:950`). The manifest is tool-written
    and marked "do not edit by hand," but there is no guard that `target` is
    non-empty / lives under an expected state root. A hand-corrupted manifest
    with `target = "/"` would be catastrophic. Cheap defense-in-depth: refuse
    to destroy paths that are empty, `/`, or outside the configured lab root.
  - **F8 (Info):** `IFS=: read -r uname upass` for `--user name:pass`
    (`lab-chroot.sh:314`) truncates any password containing a `:`. TOML
    `[[users]]` avoids this; the CLI form should document the limitation or
    split on the first `:` only.
- **F9 (Info): ✅ RESOLVED 2026-07-24.** `pyproject.toml` declares
  `license = { text = "MIT" }`; a top-level MIT [`LICENSE`](LICENSE) file has now
  been added, so the license is enforceable and unambiguous. *(Original: no
  `LICENSE`/`COPYING` at the repo root.)*

---

## 7. Testing & CI

- **Tests: good.** Per-phase `tests/` with a consistent `lib.sh`, autotools
  skip/pass/fail semantics, `run-all.sh`, plus pytest for the TUI
  (`asyncio_mode = "auto"`, pilot tests, backend fixtures). Coverage spans
  validation, lifecycle, naming, inspect-JSON contracts, and CLI-vs-config
  parity.
- **CI: ✅ RESOLVED 2026-07-24 (was F6, Low).** `.github/workflows/ci.yml` now
  runs on push/PR: `shellcheck` + `bash -n` (lint), `link_check.py` +
  `paths.py --check` (docs), the phase shell suites, and phase6/6b pytest —
  exactly the workflow this section recommended. *(Original finding: "no
  `.github/workflows/`; nothing runs the tests on push/PR.")*

**Recommendation (done).** ~~Add a CI workflow (lint + test).~~ Landed in
`.github/workflows/ci.yml`; `shellcheck` is included, locking in the discipline.

---

## 8. Prioritized recommendations

1. **(F2 — ⚠️ mostly done)** Verify downloaded images against published
   checksums. *Done for cloud images + Kali (`verify_sha256`); remaining: the
   Alpine `--allow-untrusted` path.* *(Medium)*
2. **(F1)** Make VM password auth opt-in; eliminate the blank-password
   dropbear fallback; add a network-exposure warning. *(Medium)*
3. **(F6 — ✅ done)** ~~Add CI (pytest + shell suites + `shellcheck`).~~ Landed:
   `.github/workflows/ci.yml`. *(Low, high ROI)*
4. **(F7)** Add a path-sanity guard before `rm -rf "$target"` in destroy.
   *(Low)*
5. **(F4/F5)** Default published ports to loopback; pin iPXE ref and base
   image. *(Low)*
6. **(F3 / F9 — ✅ F9 done)** Document the config-as-root trust boundary;
   ~~add a `LICENSE` file.~~ *(top-level MIT `LICENSE` added.)* *(Info)*

---

## 9. Conclusion

This is a mature, carefully written toolkit that handles a genuinely
privileged and finicky problem domain with above-average rigor. The security
findings are not implementation bugs so much as the intrinsic trade-offs of a
"convenient disposable lab" tool — weak defaults and unverified downloads —
which are reasonable *if* the boundaries are made explicit and a couple of
sharp edges (blank-password SSH, unverified images, unguarded destroy) are
sanded down. The biggest *process* gap is the absence of CI to exercise the
already-solid test suite. None of the issues block use in the intended
local/lab context; addressing the Medium items would make it safe to
recommend more broadly.

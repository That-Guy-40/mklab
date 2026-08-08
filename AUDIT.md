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

> **Remediation update (2026-07-24):** **F6 RESOLVED** — CI added:
> [`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs shellcheck + `bash -n`,
> `link_check.py` + `paths.py --check`, the phase shell suites, and phase6 pytest on
> push/PR. **F9 RESOLVED** — top-level MIT [`LICENSE`](LICENSE) added.
>
> **Re-derivation (2026-08-06): two open findings and two open halves of findings
> were already fixed, and this file was the last thing still saying otherwise.**
> **F2** is now RESOLVED in full — the Alpine half closed when `alpine_apk_add` gained
> `--keys-dir` and dropped `--allow-untrusted` (and the function's own header comment
> still described the removed behaviour; corrected). **F4** is RESOLVED — both container
> drivers default a published port to `127.0.0.1` via `_pub_host`, with regression tests
> in both. **F3** was documented and **F7** had been fixed before the list that asks for
> it was written; **F8** was never a defect.
>
> **F5 is now RESOLVED too (2026-08-07)** — the iPXE ref, its commit, and the base image
> digest are pinned in [`netboot/versions.env`](netboot/versions.env), and a moved tag is
> refused by name instead of silently building different source. Worth noting *why* it
> stayed open: a tagged release did not exist until iPXE cut **v2.0.0 on 2026-03-06**;
> the newest tag before that was from 2020. One third of the finding — the
> `tonistiigi/binfmt` citation — does not hold: that image appears only inside an error
> message as advice, and is not a build input.
>
> **F1 is WON'T FIX, by decision (2026-08-07).** Weak default VM credentials are a
> deliberate trade in a toolkit whose entire premise is *disposable* lab environments: every
> VM here is created to be destroyed, none is exposed beyond the host, and the guests exist
> to be broken on purpose. Hardening them would add friction to the common path to guard
> something that is not a real exposure here. Recorded so the question stops being re-asked
> — an open finding nobody intends to act on is a queue entry that never drains.
>
> **That leaves nothing open in this audit.** Everything else in the 2026-05-20 snapshot
> stands as written, and the six findings that were live have been resolved or shown not to
> be defects.
>
> The pattern is worth more than any of the fixes: **an audit finding is a cached fact
> about the code, and nothing re-checks it.** Every correction here was made by reading
> the code at the cited line and finding something else there.

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
| F1 | Medium | Security | 🚫 **WON'T FIX — decided 2026-08-07.** The premise of this toolkit is *disposable* labs: every VM is created to be destroyed, none is exposed beyond the host, and several exist specifically to be broken. Hardening the default adds friction to the common path to guard something that is not an exposure here. Recorded as a decision so it stops being re-raised — an open finding nobody intends to act on is a queue entry that never drains. *Original:* Weak, hardcoded default credentials for VMs (`lab`/`lab`, root password `lab`, `ssh_pwauth: true`, NOPASSWD sudo); blank-password dropbear fallback for microvms |
| F2 | Medium | Security / Supply chain | ✅ **RESOLVED — verified 2026-08-06.** Cloud-image + Kali downloads are SHA256-verified (`verify_sha256`), and the Alpine gap is closed too: `alpine_apk_add` passes `--keys-dir "$root/etc/apk/keys"` and **no** `--allow-untrusted`, so package RSA signatures are checked against Alpine's own bundled keys (Finding 14). The function's header comment still claimed the opposite and was corrected with this row. *Original:* Downloaded cloud images & Kali archives are not checksum/signature-verified (SHA256SUMS is fetched but used only for filename resolution); Alpine uses `--allow-untrusted` |
| F3 | Low | Security | ✅ **RESOLVED 2026-08-06** — documented in [`phase1-chroot/README.md`](phase1-chroot/README.md#-trust-boundary--a-toml-config-is-a-root-shell-script) (*a TOML config is a root shell script*), plus a contrasting note in [`phase2-qemu-vm`](phase2-qemu-vm/README.md), whose `runcmd` is root **inside a VM**. A repo-wide check found only those two phases execute config-supplied strings at all; 3/4/5/7 do not. *Original:* TOML configs execute arbitrary commands as root (`post_commands`, `init_script`); trust boundary not called out as such |
| F4 | Low | Security | ✅ **RESOLVED — verified 2026-08-06.** Both drivers default a published port to `127.0.0.1` via `_pub_host` (`phase3-docker/lab-docker.sh:93`, `phase4-podman/lab-podman.sh:108`), with `LAB_PUBLISH_HOST` as the opt-in to a wider bind, and **every** publish site routes through it. Regression-tested in both labs. *Original:* Default port publishing binds `0.0.0.0` (all interfaces) for Docker/Podman labs |
| F5 | Low | Supply chain / Reproducibility | ✅ **RESOLVED 2026-08-07.** [`netboot/versions.env`](netboot/versions.env) pins the iPXE release, **the commit that release must resolve to**, and the base image by digest; the builder compares hashes after cloning and refuses a moved tag **by name** rather than building different source under an unchanged ref. Verified live (v2.0.0 built clean with `--imgverify --serial-console --nic-rom` together) and guarded headlessly by [`test-ipxe-pin.sh`](netboot/tests/test-ipxe-pin.sh). *Original:* iPXE built from moving `master` ref; `debian:bookworm` base image unpinned (no digest) |
| F6 | Low | Process | ✅ **RESOLVED (2026-07-24)** — CI (`.github/workflows/ci.yml`) now runs the suites on push/PR. *Original:* Comprehensive test suites exist but there is no CI to run them automatically |
| F7 | Low | Robustness | ✅ **RESOLVED — verified 2026-08-06.** The guard was implemented as `_safe_rm_rf` (credited to "Finding 14") and wired into all three destroy paths; this row had simply never been updated. Its four path-sanity refusals had also never been *observed* firing — now covered by [`test-destroy-path-guards.sh`](phase1-chroot/tests/test-destroy-path-guards.sh), with a positive control. *Original:* `destroy` does `rm -rf -- "$target"` using the manifest's `target` value with no path-sanity guard |
| F8 | Info | Robustness | ❌ **NOT A DEFECT — measured 2026-08-06, this finding was wrong.** `read` assigns the remaining fields *including their delimiters* to the last variable, so `IFS=: read -r uname upass` already splits on the **first** colon only: `alice:pa:ss:word` → password `pa:ss:word`, intact. F8 named a mechanism that looks lossy and inferred an outcome without measuring it. Pinned by [`test-user-password-colons.sh`](phase1-chroot/tests/test-user-password-colons.sh) so a refactor cannot make it true. *Original claim:* `--user name:pass` truncates passwords containing `:` |
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

> ✅ **RESOLVED — both halves, verified 2026-08-06.** Cloud-image + Kali downloads are
> SHA256-verified: `verify_sha256()` in `phase2-qemu-vm/lab-vm.sh` is called for cloud
> images and Kali, and the Kali path hard-fails if `SHA256SUMS` can't be fetched
> (2026-07-24).
>
> **The Alpine half was closed too, and this note did not notice.** `alpine_apk_add`
> passes `--keys-dir "$root/etc/apk/keys"` and no longer passes `--allow-untrusted`, so
> apk verifies package RSA signatures against the official Alpine keys shipped inside
> the minirootfs. The removal is credited in-line to "Finding 14".
>
> **The function's own header comment still described the removed behaviour** — *"Uses
> --allow-untrusted since we're not threading Alpine's signing keys through; … HTTPS …
> is our trust boundary here"* — four lines above the `--keys-dir` that contradicts it.
> A reader checking this property would have taken the comment's word for it. Corrected
> 2026-08-06. A stale comment about a security property is worse than none.
>
> The original finding is preserved below for the record.

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

> ✅ **DONE 2026-08-06.** [`phase1-chroot/README.md`](phase1-chroot/README.md#-trust-boundary--a-toml-config-is-a-root-shell-script)
> now carries a *Trust boundary* section stating plainly that **a `--config` file executes
> as root on your host** — treat it as a script you are about to `sudo bash`.
>
> **Mapping the blast radius first made the answer better than the recommendation.** Only
> **two** phases execute config-supplied command strings: phase 1 (`post_commands` via
> `bash -c`, `init_script`) and phase 2 (`runcmd` via cloud-init). Phases 3, 4, 5 and 7 do
> not, so a blanket warning across all of them would have been noise.
>
> And the two are **not equivalent**, which is the part worth writing down: phase 1's
> commands run as uid 0 **on your host's kernel, against a directory tree on your
> filesystem** — a chroot is not a security boundary, and hostile input does not need to
> escape anything because it is already outside. Phase 2's `runcmd` is also root, but
> **inside a VM**, which is a real boundary. The two READMEs now say so and link each other.

### F4 — Default port publishing binds all interfaces (Low) — ✅ **RESOLVED, verified 2026-08-06**

The recommendation below was implemented, and this row went on saying otherwise —
the same stale-record shape as F7. The two lines the finding cites no longer hold the
code it describes (`lab-docker.sh:901` is now a healthcheck branch;
`lab-podman.sh:1493` is a comment).

**What is there now.** Both drivers pass every published port through `_pub_host`
([`phase3-docker/lab-docker.sh:93`](phase3-docker/lab-docker.sh),
[`phase4-podman/lab-podman.sh:108`](phase4-podman/lab-podman.sh)):

```bash
_pub_host() {
    local spec="$1" host="${LAB_PUBLISH_HOST-127.0.0.1}"
```

A bare `8080:80` becomes `127.0.0.1:8080:80`; a spec that already names a bind IP
(`ip:host:container`, or `[ipv6]:…`) is left alone — that is the explicit opt-in to a
wider bind — and `LAB_PUBLISH_HOST=0.0.0.0` restores all-interfaces. Verified that
**no publish site bypasses it**: every `-p` / `PublishPort=` in either driver is
`_pub_host`-wrapped (the remaining raw matches are `yq -p toml` and
`loginctl -p Linger`).

Two `0.0.0.0` literals survive in each driver and are **not** defaults: they are
`status`/`inspect` *display* code rendering what the engine reports for a port with no
recorded bind IP (`lab-docker.sh:1274`, `lab-podman.sh:1745`). Asserting the mechanism
here would have mis-read them as the defect.

**Regression coverage in both labs** — this is what makes the fix durable rather than
incidental:

- [`phase3-docker/tests/test-publish-loopback.sh`](phase3-docker/tests/test-publish-loopback.sh)
  unit-tests `_pub_host` directly: bare specs get the loopback default, an explicit bind
  IP is preserved, the proto suffix survives, `LAB_PUBLISH_HOST` overrides, and an
  *empty* override restores the engine's own default.
- [`phase4-podman/tests/test-quadlet-generate.sh:49`](phase4-podman/tests/test-quadlet-generate.sh)
  asserts the generated unit carries `PublishPort=127.0.0.1:19999:80`, so the quadlet
  path — which does not go through `podman run` — is covered too.

### F5 — Non-reproducible / unpinned build inputs (Low) — ✅ RESOLVED 2026-08-07

**Where:** `netboot/build-ipxe.sh:148` (`debian:bookworm`, no digest),
`netboot/ipxe-build-inner.sh:72` (iPXE default ref `master`),
`phase3-docker/lab-docker.sh:154` (`docker run --privileged tonistiigi/binfmt`
suggested for binfmt setup).

iPXE builds default to a moving `master` branch and an untagged base image,
so artifacts are not reproducible and silently track upstream drift.

**Recommendation.** Default `--ipxe-ref` to a tagged release; pin the base
image by tag+digest. The Python side is fine here — `pyproject.toml` uses
`>=` floors but `uv.lock` pins exact versions with hashes.

**What was done — and the one place the recommendation was not followed.**

[`netboot/versions.env`](netboot/versions.env) now carries the pin, sourced by
`build-ipxe.sh`:

```
IPXE_REF=v2.0.0
IPXE_COMMIT=12798ec29aa8a64d8675c4378b99f5fe28447afb
IPXE_BUILD_IMAGE="debian:bookworm@sha256:813017f3…"
```

**A tagged release alone would not have been a fix.** When this finding was
written, upstream's newest tag was **v1.21.1 (2020-12)** — five years stale, and
missing things this pipeline compiles in. Defaulting to it would have traded a
moving ref for a broken one. iPXE cut **v2.0.0 on 2026-03-06**, which is what
made the recommendation actionable; the ref stayed `master` in the interim
because there was nothing better to point at, and nothing recorded that.

**The tag is pinned WITH its commit, which the recommendation did not ask for.**
A git tag is a mutable pointer: a re-tagged `v2.0.0` clones cleanly, reports the
ref it was asked for, and hands the build different source. That is this repo's
own [stale-record class](CLAUDE.md) — *a version string is not an identity;
compare hashes* — so `ipxe-build-inner.sh` re-reads `git rev-parse HEAD` after
cloning and refuses a mismatch, naming both hashes, **before `make` runs**.
An explicit `--ipxe-ref <other>` is not checked (it is a deliberate override) but
the build announces itself as unpinned rather than looking identical to a pinned
one.

**`tonistiigi/binfmt` was deliberately left alone.** Re-reading
`phase3-docker/lab-docker.sh:173-196`, the script never runs that image: it
appears inside a `die` message as the *second* of two suggested install paths,
after `apt-get install qemu-user-static`. It is advice in an error string, not a
build input to any artifact this repo produces, and pinning a tag there would
enshrine a version nobody had verified. F5 cited it alongside two real inputs;
that part of the finding does not hold.

**Coverage.** [`netboot/tests/test-ipxe-pin.sh`](netboot/tests/test-ipxe-pin.sh)
asserts the pin file names a fixed ref + a 40-hex commit + a digest, that the
builder forwards the commit for the pinned ref and *not* for an override, and —
by running the real inner script against shimmed git/make in a private mount
namespace — that a wrong commit stops the build before `make`, while the right
one does not. All seven of those assertions were watched to fire against
injected defects. The directory also gained the `lib.sh` / `run-all.sh` /
`test-harness-net.sh` shape and is now in CI; before this it had one test, no
runner, and CI ran none of it.

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
  - **F7 (Low) — ✅ RESOLVED, verified 2026-08-06.** The recommendation below was
    implemented as `_safe_rm_rf` and wired into all three destroy paths; only this
    record lagged. It refuses an empty path, a relative path, `/`, and anything
    shallower than `/a/b`, and additionally fails closed if *anything* is still
    mounted under the tree. Four of those five refusals had never been observed
    firing — [`test-destroy-path-guards.sh`](phase1-chroot/tests/test-destroy-path-guards.sh)
    now watches each one bite, with a positive control so a guard that refuses
    *everything* cannot pass. *(Original:* `manager_none_destroy` / `destroy` run
    `rm -rf -- "$target"` using `target` read back from the manifest; no guard that
    `target` is non-empty or lives under an expected state root, so a hand-corrupted
    manifest with `target = "/"` would be catastrophic.*)*
  - **F8 (Info) — ❌ NOT A DEFECT. Measured 2026-08-06; the finding was wrong.**
    `read` assigns the remaining fields **including the delimiters between them** to
    the last variable, so `IFS=: read -r uname upass` already does exactly what the
    recommendation asked for — split on the first `:` only: `alice:pa:ss:word` yields
    name `alice` and password `pa:ss:word`, intact. F8 named a *mechanism* that looks
    lossy and inferred an *outcome* without measuring it — this repo's bug class #2,
    committed in a document rather than a test. Nothing needed fixing, and a
    well-meant patch here could easily have **introduced** the truncation. Since no
    test touched `--user` at all, the correct behaviour was one refactor away from
    becoming wrong; [`test-user-password-colons.sh`](phase1-chroot/tests/test-user-password-colons.sh)
    pins it, with a negative control (inject a third `read` field and the assertion
    fires). *(Original claim:* `--user name:pass` truncates any password containing a
    `:`.*)*
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
   checksums. ~~*Done for cloud images + Kali (`verify_sha256`); remaining: the
   Alpine `--allow-untrusted` path.*~~ ✅ **Both halves done** — the Alpine path
   verifies with `--keys-dir` and drops `--allow-untrusted`; verified 2026-08-06. *(Medium)*
2. **(F1)** Make VM password auth opt-in; eliminate the blank-password
   dropbear fallback; add a network-exposure warning. *(Medium)*
3. **(F6 — ✅ done)** ~~Add CI (pytest + shell suites + `shellcheck`).~~ Landed:
   `.github/workflows/ci.yml`. *(Low, high ROI)*
4. ~~**(F7)** Add a path-sanity guard before `rm -rf "$target"` in destroy.~~ ✅ **Already done** — `_safe_rm_rf`, verified 2026-08-06; the guard predated this list and the list was never updated.
   *(Low)*
5. ~~**(F4)** Default published ports to loopback~~ ✅ **Already done** — `_pub_host`
   in both container drivers, regression-tested in both; verified 2026-08-06, and like
   F7 the list had never been updated. ~~**(F5)** Pin the iPXE ref and the base image~~
   ✅ **Done 2026-08-07** — [`netboot/versions.env`](netboot/versions.env) pins
   `v2.0.0` **with its commit** and the base image by digest, and a moved tag is
   refused rather than built. *(Low)*
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

# SURVEY — the examples corpus: synergies not wired, families with a hole

*2026-08-26. A desk survey of `examples/` (70 directories — 69 labs plus the generated
`learning-paths/` — and 12 flat `.toml` specs), the two catalogues that index it
([`examples/00-INDEX.md`](examples/00-INDEX.md), ~147 table rows;
[`examples/learning-paths.toml`](examples/learning-paths.toml), 11 paths + 16 collections +
2 capstones), the seven phase drivers, and `.github/workflows/ci.yml`.*

**What was actually run**, so the difference between a measurement and a reading is legible:

| ran | result |
|---|---|
| `tools/link_check.py` | **0 broken links**, 0 orphans |
| `tools/paths.py --check` | every ref resolves · every unit routed · generated docs fresh |
| `tools/check-harness-net.sh` against **all 21** `tests/` directories | **13 pass, 5 fail, 3 n/a** — see §A1 |
| `lab-*.sh --help` on all six shell drivers, verb sets diffed | see §C2 |
| shape matrix over every lab dir (README / PLAN / MANUAL_TESTING / tests / upstream-tutorial / hand-walk) | feeds §A, §D |
| `tools/check-tree-diagrams.sh` · `tools/check-doc-verbs.sh` | tree ✓; doc-verbs **must be run unprivileged** — under `EUID 0` its `verb_present` returns "present" by design (it refuses to invoke verbs that build host networking next to a live cluster), which makes its own §0.2 control fire. Re-run as uid 1000: **all six §0 controls pass.** Not a defect; noted because a root shell reads it as one. |

Everything else below is a reading of the corpus and is marked as such.

The corpus is in good shape. Routing is complete, provenance is vendored, the backlog is
drained to three open boxes. So this survey deliberately does **not** relitigate what is
already tracked — it looks for the things nobody has written down. They fall into four
kinds, and the first kind is the one worth reading first: **a check whose selector cannot
see its own negative case.**

---

## A. Measured — the EXIT-trap net is enforced by a selector keyed on the defect

### A1. Five shell suites are outside the CI loop, and one of them is `tools/tests`

[`ci.yml`](.github/workflows/ci.yml) enforces the repo's central harness rule like this:

```
for lib in $(git ls-files '*/tests/lib.sh'); do
  d="$(dirname "$lib")"; bash tools/check-harness-net.sh "$d"
```

The loop enumerates **`lib.sh` files**. But the first thing
[`check-harness-net.sh`](tools/check-harness-net.sh) checks is *whether a `lib.sh` exists
at all* — it prints `FAIL: no lib.sh in … — there is no shared net to check` and exits 1.
**So the enumeration is keyed on the very artifact whose absence is the defect**: a
`tests/` directory with no shared net is not a failure, it is not a row.

Pointed by hand at every `tests/` directory in the repo:

| suite | rc | has `lib.sh` | in the CI loop |
|---|---|---|---|
| 13 suites — the 6 phases, `netboot/`, `micro-linux/`, bmc-toolkit, maas, micro-cloud, nested-calico, zfsbootmenu | **0** | ✅ | ✅ |
| `examples/almalinux-packer-images/tests` | **1** | ❌ | ❌ |
| `examples/kali-packer-vagrant/tests` | **1** | ❌ | ❌ |
| `examples/openbios-the-rival-that-shipped/tests` | **1** | ❌ | ❌ |
| `examples/package-mirror-ram/tests` | **1** | ❌ | ❌ |
| **`tools/tests`** | **1** | ❌ | ❌ |
| `phase6-tui/tests`, `phase6b-web/tests`, `…/upstream-repo/…/tests` | n/a | — | pytest / vendored |

Thirteen of thirteen enrolled suites pass. **Five shell suites were never enrolled** — and
the last row is `tools/tests`, the directory holding the meta-checkers that enforce this
rule on everyone else.

This is [`CLAUDE.md`](CLAUDE.md)'s own §"a scan that matches nothing and a scan that is
broken print the same green ✓", moved up one level: not a broken *pattern* this time but a
broken *population*. The EXIT-trap checker was rewritten twice for exactly this class of
error and then handed a corpus that excludes its own negative case.

**Fix:** enumerate `tests/` **directories** that contain `*.sh`, not `lib.sh` files. That is
a one-line change with a known blast radius — the five rows above go red on the next run,
which is the point.

### A2. Three of those four labs hand-roll a private copy of the net; one has already drifted weaker

`CLAUDE.md`: *"The net belongs in `lib.sh`, and a test must NEVER install its own `trap …
EXIT`."* And: *"Extract the shipped thing; never re-implement it. A copy drifts from its
subject and then proves something about the copy."* Both are being broken in the same four
directories, and the drift has already happened:

| file | shape |
|---|---|
| `almalinux-packer-images/tests/test-offline-archive.sh` | private `_VERDICT` + `_on_exit` + `trap _on_exit EXIT`, lines 20–35 |
| `kali-packer-vagrant/tests/test-offline-archive.sh` | the same block, lines 27–42 — a near-identical second copy |
| `package-mirror-ram/tests/test-state-mount-guard.sh` | **the drifted one**: `trap 'rc=$?; rm -rf -- "$TMP"; [[ $rc == 0 \|\| $rc == 77 \|\| $rc == 1 ]] \|\| …'` — **no `_VERDICT` flag at all**, and `rc == 1` is whitelisted |

That third one is the failure `CLAUDE.md` opens with. A `die` inside the script under test
exits **1**; the trap whitelists 1; there is no `_VERDICT` to notice a verdict was never
printed — so the run ends on a bare `rc=1` **with no `FAIL:` line**, which is precisely the
silent-exit the net exists to make impossible. Nothing catches it, because of §A1.

### A3. Four `tests/` dirs have no `run-all.sh`; the list moved into CI instead

CI compensates by naming seven paths by hand at
[`ci.yml`](.github/workflows/ci.yml) (`for t in examples/kali-packer-vagrant/… \`). That is
the *"a test file in no list"* shape the ratio rule was built to kill —
[`tools/tests/test-run-all-reports-a-ratio.sh`](tools/tests/test-run-all-reports-a-ratio.sh)
drives **every** `*/tests/run-all.sh` and asserts what it prints, and these four
directories have no runner for it to drive. The hand-maintained list did not disappear; it
relocated to a YAML file no ratio check reads.

---

## B. Assets that exist and were never wired to each other

These are the four places where the repo already owns both halves and no line connects them.

### B1. `netboot/` mints its own snakeoil CA next door to `lab-ca/` 🥇

[`netboot/sign-payload.sh`](netboot/sign-payload.sh) signs kernels/initrds as CMS so iPXE's
`imgverify` accepts them. Its own header says:

> `--gen-keys` mints a *snakeoil* CA + signer, fine for a lab … but **NOT a real trust
> anchor**. In production … point `--keydir` at real material (`ca.crt`/`ca.key` +
> `codesign.crt`/`codesign.key`) and drop `--gen-keys`.

[`examples/lab-ca/`](examples/lab-ca/README.md) — collection theme: *"One reusable trust
anchor for real HTTPS + signed artifacts across labs"* — ships
[`make-ca.sh`](examples/lab-ca/make-ca.sh) and
[`issue-signing-cert.sh`](examples/lab-ca/issue-signing-cert.sh), which produce **exactly
that material**.

`git grep lab-ca netboot/` → **nothing**. The seam is already cut, documented, and named in
the header of the file that needs it; the counterpart is two directories away. `lab-ca`
currently has two real consumers (`linuxboot-uefi-kexec/`, `libvirt-ipxe-http-pxe/https/`)
and this is the third, at the cost of one `--keydir` argument and a paragraph.

*Why it matters beyond tidiness:* the whole RAM-infra family's thesis is "reboot pulls the
newest **verified** image." Today each lab's verification chains to a key it minted for
itself, so nothing in the repo demonstrates **one** anchor trusted by several consumers —
which is the only part of PKI that is actually hard.

### B2. A package mirror nobody installs from

[`examples/package-mirror-ram/`](examples/package-mirror-ram/README.md) is a stateless node
serving a full Debian mirror tree. The four zero-touch install labs — `debian-pxe-lab/`,
`debian-preseed-gallery/`, `rocky-pxe-lab/`, `almalinux-pxe-lab/` — all install from public
mirrors.

`git grep -l package-mirror examples/` returns only the RAM plans, `metal-as-a-service`'s
ramdisk catalogue, the two catalogues, and the lab itself. **No install lab points at it.**

Pointing a preseed at it is `d-i mirror/http/hostname`; a kickstart, `url --url=`. What that
buys is not a shortcut — it is **the air-gapped install**, which is the reason mirrors exist
and which no lab in the repo currently demonstrates end to end. It would also give
`package-mirror-ram`'s ⏳ author-run half its first consumer-side proof.

### B3. `push` exists in exactly one phase, and there is nothing to push to

Verb diff across the six shell drivers (`--help`, verbatim):

| verb | p1 chroot | p2 vm | p3 docker | p4 podman | p5 lxd | p7 fc |
|---|---|---|---|---|---|---|
| `push` | — | — | **✓** | ✗ | ✗ | — |
| `snapshot` | — | **✓** | ✗ | ✗ | ✗ | **✓** (+`clone`) |
| `stop` | — | ✓ | ✗ | ✗ | ✗ | ✓ |
| `start` | — | ✓ | ✓ | ✓ | ✓ | ✓ |
| `verify` | **✓** | ✗ | ✗ | ✗ | ✗ | ✗ |

`registry:2` appears in **zero** files repo-wide. So phase 3's `push` has no in-repo target,
and phase 4 — the *rootless* flagship, where `podman push` to a local registry is the
interesting demo — cannot push at all. A ~30-line rootless registry lab (`registry:2` in a
phase-4 pod) would: give `push` somewhere to go, justify the verb in phases 4 and 5, and —
with §B1 — be the repo's first **TLS** registry with a real trust anchor.

### B4. Signing exists in the boot domain and nowhere in the container domain

The repo signs iPXE payloads (CMS/`imgverify`) and System-Transparency OSPKGs, and refuses
unsigned ones. `cosign`/`sigstore`/`notary` → **0 files**. Meanwhile
`metal-as-a-service` verifies golden images by **sha256 only** — defensible, and its
`# image-sha256:` stamping is the good pattern — but the repo has an opinion about signed
boot artifacts and no opinion at all about signed *container* artifacts, while shipping
three container phases and a `push` verb.

---

## C. Families with a hole

### C1. distro × workflow

Reading the corpus (`ls examples/`), the provisioning family is a matrix with one full row
and three sparse ones:

| | pxe-lab | preseed/kickstart gallery | vm-builder | packer factory | nonroot-chroot | hands-off-install |
|---|---|---|---|---|---|---|
| **debian** | ✓ | ✓ | ✓ | ✗ | ✓ | ✓ |
| **kali** | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |
| **rocky** | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ |
| **almalinux** | ✓ | ✓ | ✗ | **✓** | ✗ | ✗ |

The two rows that read as deliberate: Debian/Kali share d-i, Alma/Rocky share Anaconda, so
several holes are "the sibling covers it." The two that do **not** read that way:

- **`debian-hands-off-install/` has no RHEL-family counterpart** — and TODO §5 ("AlmaLinux:
  demo + automated run, mirror Rocky") is the closest thing to it, aimed elsewhere.
- **`rocky-`/`almalinux-vm-builder`** — `debian-vm-builder` and `kali-vm-builder` exist and
  are small; the RHEL family reaches VMs only via Packer or PXE.

Absent as whole families, and worth a decision rather than a silence: **Ubuntu autoinstall**
(already catalogued below), **openSUSE AutoYaST** (the fourth big ZTP idiom — the repo has
two of four), and **Ignition/Butane** (`butane` → 0 files) despite
[`rhel-bootc-minimal/`](examples/rhel-bootc-minimal/README.md) sitting right next to it.

### C2. `start` without `stop` — the mirror image of TODO A.3

TODO **A.3** closed a real gap: `up` is create-if-absent, so a **stopped** container was a
state no phase-6 verb could repair; phases 3/4/5 gained `start`. The mirror was not
considered: **a running container is a state no phase-6 verb can pause.** Phases 3, 4 and 5
have `start` and no `stop` — the only way down is `destroy`/`down --lab`, which reaps the
container. Phases 2 and 7 have both.

[`phase6-tui/lab_tui/reconcile.py`](phase6-tui/lab_tui/reconcile.py) makes it explicit:
`"stopped": "start"` maps observed→verb in one direction only, and
[`topology.py`](phase6-tui/lab_tui/topology.py) issues a real `stop` for the `fc` slot
alone. So "I want this service **stopped**" is not expressible as desired state anywhere in
the toolkit.

Same shape, different verb: `snapshot` lives only in phases 2 and 7, though `incus snapshot`
is first-class and `podman container checkpoint` (CRIU) exists — and micro-cloud's
[`preserve.sh`](examples/micro-cloud/preserve.sh) reimplements preserve/restore at the lab
level over drivers that have no snapshot verb underneath.

*Both are readings, not measurements* — whether either verb is wanted is a design call, and
A.3's own reasoning (put the fix in the driver, never a second owner on one lifecycle) is
the right frame for it.

### C3. Already catalogued as gaps — restated so this survey is not read as a full list

[`examples/micro-cloud/install-catalog.toml`](examples/micro-cloud/install-catalog.toml)
already names two, with `status = "gap"` and a why: **`ubuntu-autoinstall`** (subiquity) and
**`whole-disk-capture`** (Clonezilla-style). That file is the right mechanism and this
survey found no third install method missing from it. Worth noting that its
`ubuntu-autoinstall` row records the same trap this survey hit twice: an earlier grep "hit"
was `dkms autoinstall`, a false positive. (Mine: `u-boot` matched *zfsbootme**nu-boot**
-environments*. Real U-Boot coverage is zero — see §E2.)

---

## D. A convention that forked, and the newer half is invisible

**This is the biggest structural finding, and it is not a defect — it is an upgrade nobody
wrote down.**

`CLAUDE.md` documents one answer to *"let me type this tutorial by hand"*: a **`hand-walk/`**
subdir = `Containerfile` (the author's distro as code) + `RUNBOOK.md`, driven through a
phase tool. There are **10**, they have their own 00-INDEX section and a
`tutorial-hand-walks` collection.

The repo has since grown a **second, different, better** answer — and never named it:

> `README.md` + `RUNBOOK.md` + `setup-workshop.sh` + **`<lab>-debian.toml` *and*
> `<lab>-alpine.toml`**, brought up with `phase5-lxd/lab-lxd.sh up`.

**13 labs** use it: the eight `UNIX-*`/`AI-*` Matt-Might labs, the three `shell-*`
workshops, `oils-shell-container/`, `linux-proc-vfs-internals/`. And the second `.toml` is
not a convenience — it is a **cross-libc parity oracle**:

- [`UNIX-ls-without-ls/README.md`](examples/UNIX-ls-without-ls/README.md): the
  reimplementation is *"byte-identical on Debian **and** Alpine"*.
- [`UNIX-floating-point-arithmetic-in-bash/README.md`](examples/UNIX-floating-point-arithmetic-in-bash/README.md):
  *"All 25 pass identically on Debian and Alpine"*, plus a table of what each base actually
  ships (`bc` **absent** on Debian, a **BusyBox applet** on Alpine; `mawk` vs BusyBox awk;
  `ksh93` installable vs not in Alpine `main`).

That second column is a genuine finding-generator — it is where "the recipe works" becomes
"the recipe works on **musl + BusyBox**, and here is the line where GNU was load-bearing."
It is strictly more than the `hand-walk/` shape offers.

**Three consequences today:**

1. A reader browsing *"🚶 Hand-walk the tutorials"* in 00-INDEX sees **10 of 23** ways to
   walk a tutorial by hand. The other 13 are filed under shell/learning paths, indexed by
   *subject*, never as *the same kind of thing*.
2. `CLAUDE.md`'s hand-walk convention describes only the older shape, so the next
   tutorial-based lab will be authored to the weaker pattern by default.
3. **Nothing asserts the two halves stay in step.** No check compares
   `<lab>-debian.toml` against `<lab>-alpine.toml`, so one can gain a package the other
   lacks and the parity claim in the README quietly stops being true — the repo's own
   *"a record that outlives the thing it describes"* class, aimed at a claim rather than a
   cache.

**Cheapest useful move:** name the shape in `CLAUDE.md` beside the hand-walk section, add a
`cross-libc-parity` collection so the 13 are findable as a family, and let the parity claim
be checked — the labs already print per-distro proof, so the check is *"both tomls exist and
the workshop's own verdict is PASS under each"*, not a diff of TOML keys.

---

## E. Shapes obviously missing — ranked by (value ÷ cost)

Readings, not measurements. Ordered by what I would build first.

1. **A rootless local registry lab** (§B3). Smallest thing that turns a dangling verb into a
   family: `registry:2` in a phase-4 pod, `lab-podman.sh build` → `lab-docker.sh push` →
   pull it back in phase 5. With §B1 it becomes the repo's first TLS registry on a shared
   anchor; with §B4 it is where `cosign` would live.
2. **U-Boot** — the ARM/embedded counterpart to five IEEE-1275 labs, and **zero coverage**
   (the 25 grep hits were all `zfsbootme`***nu-boot***`-environments`). QEMU boots U-Boot on
   `virt`/`versatile` under TCG, so it needs no hardware; it drops straight into the
   `multi-arch-tcg` and `close-to-the-metal` collections; and it is the natural contrast to
   `openbios-the-rival-that-shipped`'s thesis — *the same job, a third answer, and the one
   that actually won on ARM*. The repo has Forth firmware, coreboot+LinuxBoot and UEFI/OVMF;
   the mainstream embedded loader is the hole.
3. **Air-gapped install** (§B2) — wire one gallery at `package-mirror-ram` and prove an
   install with the upstream mirror unreachable. Cheap, and it makes an existing ⏳ author-run
   lab consumer-proven.
4. **A chaos ladder for `anycast-dns-ram`.** The ladder is well adopted (maas, micro-cloud,
   nested-calico, `phase6-tui/lab_tui/chaos.py`) — this is not a repo-wide gap. But
   `anycast-dns-ram` is the one lab whose entire thesis **is** graded failure ("announces the
   VIP only while healthy, **withdraws on failure**, re-announces on recovery"), and it has
   `demo-anycast.sh`, **no `tests/` at all**, and no rung grading. Its withdraw/re-announce is
   a textbook ABSORBED → DEGRADED → HALTED walk, and its no-fault control already exists.
5. **Split `boot-and-crash`.** It is the repo's densest path — 9 steps + 2 branches — and it
   carries two journeys: *recovery & forensics* (`root-password-reset` → `kdump` →
   `zfsbootmenu`) and *firmware internals* (five OF/OpenBIOS labs, four `PLAN.md`s, plus the
   active TODO §12–14 work). The firmware half is the deepest cluster in the repo and reaches
   the reader as steps 4–8 of somebody else's path.
6. **A third `rewrite-the-classics`.** Two members (`ls`, `less`), and the theme —
   *reimplement in bash builtins, then diff against the original* — is the corpus's best
   self-checking shape. `sort` (with `sqlite3` already established as an oracle in the
   sibling collection) or `find` are the obvious next.

---

## F. One small concrete defect found in passing

[`examples/zfsbootmenu-boot-environments/zbm-debian.toml`](examples/zfsbootmenu-boot-environments/zbm-debian.toml)
line 21 hard-codes an absolute path into this machine's home directory:

```
image      = "/home/user/mklab/examples/zfsbootmenu-boot-environments/out/root-on-zfs.qcow2"
```

It is the **only** `/home/user/` in any tracked `.toml` (`grep -rn '/home/user/' --include=*.toml`
→ 1 hit). The README explains *why* it must be absolute — `lab-vm.sh` uses it as a qcow2
backing file and layers a per-VM CoW overlay — which is right, and is a different question
from *whose* home it points at. In a repo whose premise is "point a tool at a `.toml`", this
one spec runs for one user on one machine.

---

## What this survey did not look at

Named so the coverage is legible rather than implied: it did not read the seven `*_LAB_PLAN.md`
files for unbuilt increments beyond TODO's B.1/B.2 (`RESILIENT_REGION`, `SECURITY_RANGE` —
both **BUILD-READY** since 2026-08-08 and both still open boxes, which is by far the largest
piece of already-scoped unbuilt work in the repo); it did not run any lab; it did not audit
the openbios firmware work in TODO §12–14; and it made no judgement about the ~78 UNPROBED
doc-verb rows (TODO 11.4a), which are already named as declined rather than covered.

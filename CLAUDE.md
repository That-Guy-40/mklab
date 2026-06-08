# CLAUDE.md — mklab

A multi-phase lab-building toolkit: `phase1-chroot` → `phase2-qemu-vm` →
`phase3-docker` → `phase4-podman` → `phase5-lxd` → `phase6-tui`/`phase6b-web`.
Ready-to-run `.toml` lab specs live in `examples/`, catalogued in
[`examples/00-INDEX.md`](examples/00-INDEX.md). Cohesive multi-file labs get
their own subdir under `examples/` (e.g. `tiny-linux-experiments/`,
`almalinux-pxe-lab/`, `pxe-boot-mechanics/`).

## Working practices

### "Fix a value everywhere" tasks: map the full blast radius BEFORE the first edit

When changing a value, path, or name that recurs across the repo (a **port**, a
**filename**, a config key, a VM name), `git grep` the **whole repo** for every
occurrence and **classify each hit** — in-scope vs. coincidental vs.
intentionally-different — *before* editing anything. Editing first and learning
the true scope afterward causes thrash and risks corrupting unrelated hits.

The loop:
1. `git grep -n '<value>'` repo-wide (or `tools/link_check.py --impact <file>` for file references).
2. Classify every hit: the thing you're changing / merely shares the string / deliberately different.
3. Edit only the in-scope set, then re-grep to confirm nothing stray remains **and** nothing unrelated was touched.

Real example (netboot HTTP port → 8181): `8080` appeared ~100× — some were the
netboot pipeline (change), many were unrelated (Open WebUI, the web UI, generic
docker/podman demos, test fixtures → leave), and one was a note explaining *why*
this host uses `8181` (`8080` is occupied by SABnzbd → must stay). A blanket
replace would have broken the unrelated hits; a too-narrow grep produced two
wrong guesses about direction. The full-repo grep + per-hit classification is
what got it right. **Host-specific values (ports especially) are often
intentional — verify what the host/configs actually use before changing them.**

### Doc/link integrity

`tools/link_check.py` validates Markdown cross-links repo-wide and maps file
references (`--impact <name>` shows every place a file is referenced — the edit
list before a rename/move/delete). Run it before/after any such change; it must
report **0 broken links** (it also exits non-zero on broken links, for CI/commit
gating).

### Provenance: vendor the upstream source for tutorial-based labs

Any lab that **operationalizes a specific external write-up** keeps a byte-exact,
attributed archive of that source *alongside* the operationalization, so the lab
is reproducible offline and its provenance is explicit (sources move, rot, or
get paywalled). Two tiers, by how tightly the lab tracks one source:

- **Built from one specific tutorial / blog post → vendor it.** Add an
  `upstream-tutorial/` subdir with the page saved **byte-exact** (HTML + its
  primary CSS so it renders offline) plus a `README.md` carrying: a provenance
  table (Title / Author / Canonical URL / Published / **Retrieved** date), a
  per-file **`sha256`** table, a note of what's left un-vendored (images, JS,
  fonts — absolute links to the live site), and a copyright/attribution
  paragraph ("all rights remain with the author; archived for offline reference;
  `git rm` to remove"). The parent lab's README/PLAN **must link the archive**
  (else `link_check.py` flags it as an orphan). Exemplars:
  [`examples/tiny-linux-experiments/floppinux/upstream-tutorial/`](examples/tiny-linux-experiments/floppinux/upstream-tutorial/),
  [`examples/debian-http-boot/upstream-tutorial/`](examples/debian-http-boot/upstream-tutorial/).
- **Follows official docs / an upstream catalog / upstream code (not one page)
  → cite, don't mirror.** Capture the exact URL(s) + a **retrieved/as-of date**
  + a one-line note in the lab's README; don't archive whole doc sites. (Labs
  that *fetch* their upstream live — gallery/ansible/vm-builder wrappers — pin or
  date the fetch instead.)

Fetching is allowed for archival (`curl`/`wget` of HTML/CSS is fine — the agent
Bash runner only gates fetch+**exec** of prebuilt toolchains). **Verify each URL
resolves 200 + has the expected title before hashing** — never enshrine an error
page's `sha256` as "the tutorial." Two labs sharing one source each keep their
own copy (self-containment rule), byte-identical. Keep `link_check.py` green
after every add.

### Hand-walk sandboxes: reproduce the author's environment to follow a tutorial by hand

For a tutorial-based lab, a `hand-walk/` subdir (sibling of `upstream-tutorial/`)
gives a **disposable container that reproduces the author's working environment**,
so a human can type the recipe step-by-step — distinct from the automated
`build-*.sh`. The deliverable per lab is a fixed shape:

- **`Containerfile`** — the environment *as code*: base = **the author's distro**
  where the tutorial is distro-specific (Arch for floppinux, Rocky for the
  Lorax-based rocky-pxe, Kali for kali-llm), a **neutral Debian** base where it's
  "any POSIX" (micro-linux, muxup, debian-http-boot, almalinux-server). Bake the
  tutorial's exact `apt`/`dnf`/`pacman` prereqs as readable `RUN` lines, one
  comment per line tying it to a tutorial step. Include the tool the post *runs in*
  (e.g. `qemu-system-*`) so build **and** boot happen in one box.
- **`RUNBOOK.md`** — walks the upstream steps with the **why** at each, links the
  vendored sibling `../upstream-tutorial/` as the source of truth, and contrasts
  with the repo's automated counterpart.
- **A 00-INDEX entry + an inbound link** from the parent lab's README (else
  `link_check.py` orphans it). Cataloged under *🚶 Hand-walk the tutorials*.

**Drive it through the existing phases** (`lab-podman.sh build`/`up` with a
`build =` Containerfile) — no one-off images — *unless* a step needs a privilege
the phase tool won't inject (muxup's `binfmt` → `--cap-add SYS_ADMIN
--security-opt systempaths=unconfined`); then build the image via the phase tool
and document the `podman run` launch. **Reproduce the author's env, then build +
boot it yourself to verify** — examining prereqs this way *surfaces* the real
gotchas (a hosted-C cross needs `libc6-dev-<arch>-cross`; `gcc` alone lacks
`<stdint.h>` for iPXE's host helper; debootstrap's `mknod` needs `fakeroot`;
`unshare --mount-proc` needs `/proc` un-masked). **Partition by what the sandbox
can run:** a step that hits the **toolchain-fetch gate** (musl.cc) or needs
**loop-mount/`mknod`** (blocked here even `--privileged`) is **authored with an
explicit "you run this" marker**, not silently claimed as verified — the agent
authors the Containerfile (a clean reproducible layer); the user runs the build.
Exemplars: [`micro-linux/hand-walk/`](micro-linux/hand-walk/) (clean, fully
verified), [`phase1-chroot/hand-walk/`](phase1-chroot/hand-walk/) (cap/binfmt),
[`examples/tiny-linux-experiments/floppinux/hand-walk/`](examples/tiny-linux-experiments/floppinux/hand-walk/) (author-only steps).

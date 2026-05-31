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

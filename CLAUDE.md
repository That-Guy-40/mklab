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

### Driving a boot loader / firmware serial console from a script: no flow control

Scripting a **serial console** (GRUB, SeaBIOS, an initramfs shell, a getty login)
over QEMU's unix `serial.sock` — e.g. driving a `lab-vm.sh` VM to interrupt GRUB
and edit the kernel command line — hits a trap nothing warns you about: **GRUB's
serial input has no flow control and silently DROPS characters** fed faster than
it consumes them. A long `linux …` line or a rapid key burst arrives garbled, the
edit "didn't take", and there is **no error**. (Found the hard way building
[`examples/root-password-reset/`](examples/root-password-reset/) — ~18 failed boot
cycles, all this one bug.)

- **Slow-send everything you "type":** one byte at a time with a **~40 ms** delay
  (`for ch in s: sock.sendall(bytes([ch])); sleep(0.04)`). Faster drops chars.
  Space out keystrokes (~0.3–0.4 s) and **single-step** them — bursts drop keys.
- **Arrow-key escapes (`\x1b[B`) are unreliable** in GRUB's editor — the leading
  `Esc` reads as "discard edits / exit". Use single-byte emacs keys
  (`Ctrl-n`/`Ctrl-p`/`Ctrl-a`/`Ctrl-e`). Even then, blind multi-line navigation of
  a **wrapping** menu entry is fragile; for *deterministic automation* the GRUB
  **command line** (`c` → one slow-typed `search` / `linux … init=/bin/bash` /
  `initrd` / `boot`) beats editing the entry. Document the faithful `e`-menu-edit
  for **humans** (who navigate it visually with no trouble) — the fragility is
  purely an automation concern.
- **Catch the menu** with `EXPECT "automatically in"` (countdown, reprinted each
  second) or `"Welcome to GRUB"` (not "GNU GRUB"); **any keypress cancels** the
  countdown (the menu then waits forever — looks hung). **One client at a time** on
  the serial socket — a stray second connection silently steals the bytes. QEMU
  monitor **`sendkey` does not reach a serial GRUB** (it targets the emulated
  PS/2/VGA keyboard). For deterministic reruns, power-cycle with
  `lab-vm.sh stop --force && start` (ssh `reboot` races the attach/boot timing).
- **Ground-truth the result** with the booted kernel's **`/proc/cmdline`**, not by
  screen-scraping GRUB's noisy per-keystroke ANSI redraws.

Cloud images also bake `timeout=0` into their `grub.cfg` (menu hidden); a one-time
prestage that sets `GRUB_TIMEOUT=5` + `GRUB_TIMEOUT_STYLE=menu` and regenerates
(Debian `update-grub`, Rocky `grub2-mkconfig`) restores an interruptible **serial**
menu — lab setup, not part of the reset. Exemplar:
[`examples/root-password-reset/`](examples/root-password-reset/)
([`RUNBOOK-init-shell.md`](examples/root-password-reset/RUNBOOK-init-shell.md) +
[`MANUAL_TESTING.md`](examples/root-password-reset/MANUAL_TESTING.md)) — verified
end-to-end on Debian/BIOS.

### Killing a process: by PID, never by pattern

When a process must be killed, resolve it to a **PID first** (`pgrep`, `ps`, a
recorded `$!`, a pidfile) and `kill <pid>`. **Never** use `pkill -f` / `pkill` /
`killall` on a name or command-line substring to do the actual kill.

A pattern matches *every* process whose argv contains the string — including ones
you didn't mean and, crucially, **the very thing the pattern names**. Real
incident: `pkill -f <vm>/serial.sock` to reap a capture `socat` also matched
**QEMU itself** (its `-chardev …serial.sock` carries that exact path), so it
killed the VM — and the agent's own shell — with **exit 144**. The path you grep
for is usually shared by the workload you are trying to protect.

- **Find with a pattern, kill by PID:** `pgrep -f <pat>` to *list*, eyeball the
  hits, then `kill` the specific PID(s). Inspecting the match before killing is
  the whole point.
- This applies to any shared-substring footgun — `serial.sock` paths, a port
  number, a config filename, a lab/VM name that recurs across cmdlines.
- Prefer the tool's own lifecycle verb when there is one (`lab-vm.sh stop`,
  `lab-lxd.sh down`, `incus delete -f <name>`) over a raw signal.

# UNIX-less-without-less — `ddpager`, a less-style pager in bash builtins + dd + tput

A **throwaway system container** with **bash**, **GNU coreutils** (the **`dd`**
whose stderr report is the pager's binary-file detector), **`tput`**,
**python3** (the pty harness that types at the pager one byte every 40 ms,
like a careful human), a non-root **`learner`** user, and a
`~/less-without-less/` sandbox holding the pager **verbatim**, the driver,
and a runnable **`demo.sh`** that does not merely *show* a TUI — it **drives
one through a real pty and greps the screen bytes for evidence**. Built and
driven through the repo's **Phase-5** tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically.

`ddpager` is a working `less`: alternate screen, raw keyboard, `j`/`k`/paging
with vi-style numeric prefixes (`10j`, `25G`), `/`-search with reverse-video
highlighting, `&`-filtering, a multi-file ring (`:n`/`:p`/`:e`), follow mode
(`F`, a `tail -f`), editor handoff (`v`), binary detection — ~1350 lines of
bash under the constraint: **bash builtins, `dd`, and `tput`. No sed, no awk,
no grep, no cat — and above all no `less`.**

Unlike the sibling Matt Might labs, the upstream here is **first-party**:
pair-written by this repo's author and an earlier Claude instance (spring
2026), with its own git repo and six companion documents — all vendored
byte-exact under [`upstream-source/`](upstream-source/README.md). **The
script is canonical; the docs are period documentation** (the author warns
they may not match the code — the lab checked, and the findings below are
the interesting part).

**Series:** [1. ls without ls](../UNIX-ls-without-ls/README.md) →
**2. less without less** *(this lab)*. Same constraint family, same `dd`
branding — and the running gag pays off here: `ddls` never calls `dd`;
**`ddpager` earns it** (two call sites, both load-bearing).

## The dd trick — the cleverest fifteen lines in either lab

How do you detect a binary file with *no* `file`, no `grep`, no `od`? You
exploit a bash wart as a sensor:

1. `dd if=file bs=512 count=1` — read the first block; **dd's stderr reports
   how many bytes it really copied** ("512 bytes ... copied").
2. Read the same block into a bash variable with `$( )` — which **silently
   strips every NUL byte** (and would eat trailing newlines, so the code
   appends a sentinel `X` inside the substitution and strips it after).
3. Compare lengths. **Shorter variable ⇒ NULs were present ⇒ binary.**

The wart *is* the detector. `demo.sh` reproduces the trick standalone and
then confirms the pager's `WARNING: binary file detected` end-to-end.

## The raw-mode illusion — what `stty raw` doesn't do

The pager's `term_init` runs `stty -echo -icanon raw min 1 time 0`. Raw mode
turns **ICRNL** off (Enter should arrive as a dead `\r`) and **ISIG** off
(Ctrl-C should be a plain byte 3). And yet: **Enter scrolls, and Ctrl-C kills
the pager with exit 130** — exactly what its `USAGE.md` documents.

The resolution, proven in `demo.sh` section 4: **bash's `read -n1` swaps its
own termios in for the duration of every read** — ICRNL and ISIG come back
on, then the old settings are restored. Replace the reader with `dd bs=1
count=1` (an external that cannot touch termios) under the *same* stty line
on the *same* pty, and the raw bytes reappear:

```
   [ok]  Ctrl-C exits 130 -- exactly what USAGE.md documents, DESPITE stty raw
   [ok]  ...and bash still ran the EXIT trap: rmcup restored the terminal
   [ok]  dd sees Enter as byte 13 (\r survives: ICRNL really is off for dd)
```

Your pager's keyboard works **because bash's `read` is doing the terminal
handling you thought your `stty` did**. If you ever port a bash TUI to
another language and the Enter key dies, this is why.

## Testing a TUI honestly: the pty driver

You cannot pipe keystrokes into a raw-mode program and call it a test — and
this lab's probing found that even `script(1)` does not deliver raw-mode
fidelity from a pipe. So [`drive-pager.py`](drive-pager.py) forks the pager
on a **real pty master**, fixes the geometry at 24×80 (deterministic status
lines), types **one byte every 40 ms** — the same slow-send discipline as
the repo's serial-console drivers, and for the same reason — captures every
screen byte, and reports the child's true exit status. `demo.sh` then greps
the captured bytes:

```
   [ok]  open a file, press q: clean exit 0
   [ok]  the status line shows 'line 1/100'
   [ok]  the alternate screen was entered (smcup)...
   [ok]  ...and left again on quit (rmcup): your shell gets its screen back
   [ok]  opening a NUL-laden file shows the binary WARNING
   [ok]  25G jumps to line 25 (numeric prefix, vi-style)
   [ok]  /needle jumps to the first hit at line 60
   [ok]  &needle filters the view: '2 matching lines'
   [ok]  :n switches to '(file 2 of 2)'
   [ok]  v hands off to $EDITOR and reloads: 'Reloaded after edit'
   ...
PASS: all 28 checks hold (ddpager's features verified through a real
      pty; the dd trick and the raw-mode illusion both reproduce)
```

The `test_cmds.sh` in the vendored original prints manual instructions and
admits *"This is complex - better to manual test"*. This harness is the
automation it wished for.

## Documented findings: where the docs and the code part ways

The six vendored documents describe the *intent*; the lab verified the
*mechanics*. What cross-examination found (each pinned in `demo.sh` or noted
in the [RUNBOOK](RUNBOOK.md)):

| # | The claim / expectation | The verified truth |
|---|---|---|
| 1 | `USAGE.md`: "130 — Interrupted (Ctrl+C)" | **True — but only by accident.** `stty raw` disables ISIG; it is bash's `read -n1` that re-enables it mid-read. The EXIT trap still runs, so the terminal is restored. |
| 2 | README: "optionally uses socat for readline integration" | **No code path invokes socat.** An aspiration recorded as a feature. |
| 3 | `test_cmds.sh` (the project's test) | A stub that prints manual instructions. Replaced here by `drive-pager.py` + 28 checks. |
| 4 | Quit path | `do_quit` calls `term_cleanup`, then the EXIT trap calls it *again* — harmless (rmcup twice), but visible in the captured bytes. |
| 5 | Search jump on a short file | A file shorter than the screen always shows `line 1/N`: `draw_screen` clamps the offset to 0, so a "successful" search looks like nothing happened. Not a bug — a consequence of never scrolling past EOF — but it fooled this lab's first probe. |
| 6 | `read_prompt()` | Dead code (each prompt inlines its own reader) that would return its result **on stderr**. Study it as a what-not-to-do. |

## Quick start

Both bases are first-class — pick either (or run both; the labs are
independent and coexist). The flow is identical bar the name:

```bash
# ── Debian 13 (trixie / glibc base) ─────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-less-without-less/less-without-less-debian.toml
examples/UNIX-less-without-less/setup-workshop.sh less-without-less-debian/shell   # ~1 min
phase5-lxd/lab-lxd.sh exec less-without-less-debian/shell -- su - learner          # start paging
phase5-lxd/lab-lxd.sh down --lab less-without-less-debian                          # tear down

# ── Alpine (musl / BusyBox base) ────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-less-without-less/less-without-less-alpine.toml
examples/UNIX-less-without-less/setup-workshop.sh less-without-less-alpine/shell
phase5-lxd/lab-lxd.sh exec less-without-less-alpine/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab less-without-less-alpine
```

Then, inside the `su - learner` shell:

```bash
bash ~/less-without-less/demo.sh                              # the 28 checks
bash ~/less-without-less/bin/ddpager /etc/passwd /etc/hosts   # drive it yourself:
#   j/k scroll · 25G goto · /root search · &nologin filter · :n next file · h help · q quit
```

## Documented divergence: the missing tripod

| | Debian 13 (trixie) | Alpine |
|---|---|---|
| `bash` | ✅ present | ❌ **absent** — the interpreter itself |
| `dd` | ✅ GNU coreutils | ⚠️ **BusyBox dd** — a different stderr dialect for `detect_binary` to parse |
| `tput` | ✅ ncurses-bin | ❌ **absent** — every escape the pager draws with |

"Just bash, dd, tput" sounds like it runs anywhere; on the most popular
container base, every leg of the tripod is missing or different.
[`setup-workshop.sh`](setup-workshop.sh) installs the real things on both
bases, after which the demo passes identically ([proof per distro in
MANUAL_TESTING](MANUAL_TESTING.md)).

## Files

| File | Purpose |
|---|---|
| [`less-without-less-debian.toml`](less-without-less-debian.toml) / [`less-without-less-alpine.toml`](less-without-less-alpine.toml) | Phase-5 specs: one container each |
| [`setup-workshop.sh`](setup-workshop.sh) | Provision bash + coreutils + tput + python3 + `learner` + the sandbox |
| [`demo.sh`](demo.sh) | **28 checks**: the dd trick, the pager through a pty, the raw-mode illusion; ends on `PASS:`/`FAIL:` |
| [`drive-pager.py`](drive-pager.py) | The pty harness: real master, fixed 24×80, 40 ms/byte slow-send, true exit status |
| [`bin/ddpager`](bin/ddpager) | The pager — **verbatim**, sha256-guarded |
| [`RUNBOOK.md`](RUNBOOK.md) | The tutorial: how ddpager works, mechanism by mechanism |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Real captured transcripts (both distros) |
| [`upstream-source/`](upstream-source/README.md) | Byte-exact archive: the pager + its six docs + provenance + sha256 |

## Scope & caveats

- **Throwaway lab.** Containers are disposable; `down` wipes them.
- **A teaching artifact, not a tool.** The whole file lives in one bash
  array (`mapfile`); search and filter are glob-substring, not regex;
  truncation counts bytes, not columns. Its own README says so — honestly.
- **No `bin/fixed/` here.** The pager's defects are in its *documentation*,
  not its behavior (the one dead function is left as a specimen); the
  corrected artifact is this lab's RUNBOOK + harness. The sibling ddls lab
  is where behavior needed fixing.
- **The learner drives it interactively** — the demo proves the machinery,
  but a pager is for humans: `exec ... su - learner` and go read something.
- **Non-root `learner`.** The container's root is only used by
  `setup-workshop.sh`.

## Prerequisites

- **LXD or Incus initialised** — `incus admin init` (or `lxd init`). See the
  Phase-5 docs: [`START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- Outbound network from the container (to `apt`/`apk` the tools).

## Sources

First-party: pair-written by this repo's author and an earlier Claude
instance, spring 2026; the pager, its git identity (single commit `930b975`,
2026-04-15) and all six companion docs vendored byte-exact with sha256 under
[`upstream-source/`](upstream-source/README.md).

This lab sits in the **shell-fluency track** right after its sibling
[ls without ls](../UNIX-ls-without-ls/README.md) and before
[floating-point arithmetic in bash](../UNIX-floating-point-arithmetic-in-bash/README.md):
first you rebuild the report generator, then the screen you read it on —
and then you ask the shell for a number it cannot give you.

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog.

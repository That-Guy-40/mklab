# shell-intermediate-workshop — a BASH scripting box for "Bash by example"

A **throwaway system container** with **BASH** and the standard complement of
Unix tools, plus a non-root **`learner`** user and a `~/bash-by-example/`
scratch directory, so you can work through **Daniel Robbins'** classic
**["Bash by example"](upstream-tutorial/README.md)** series — *writing and running
scripts* as you read. This is the programming-focused follow-on to
[`shell-novice-workshop/`](../shell-novice-workshop/README.md): novice teaches
you to *drive* the shell, this teaches you to *program* it. Built and driven
through the repo's **Phase-5** tool ([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)),
which speaks **LXD or Incus** identically.

The three articles are vendored byte-exact as PDFs under
[`upstream-tutorial/`](upstream-tutorial/README.md) — read them on one screen,
type in the container on the other.

Two bases, both first-class and **verified end-to-end** ([proof per distro in
MANUAL_TESTING](MANUAL_TESTING.md)):

| Spec | Base | Default userland | What `setup-workshop.sh` installs |
|---|---|---|---|
| [`shell-intermediate-debian.toml`](shell-intermediate-debian.toml) | Debian 13 (trixie) | **already bash + GNU coreutils** | nano, less, man-db + bash-doc, bc, diffutils, tree, file, gawk |
| [`shell-intermediate-alpine.toml`](shell-intermediate-alpine.toml) | Alpine | ash + **BusyBox**, **no bash** | **bash + GNU coreutils/grep/sed/findutils** + man + the above |

> These articles are pure **bash programming** — bashisms like `[[ ]]`, `${x^^}`,
> arrays, and `(( ))` are the whole point. Alpine's default `/bin/sh` is BusyBox
> *ash*, which doesn't speak them, so the Alpine track installs real bash — a
> documented divergence, [below](#documented-divergence-bare-alpine-has-no-bash).

## Quick start

Both bases are first-class — pick either (or run both; the labs are independent
and coexist). The flow is identical bar the name:

```bash
# ── Alpine (musl / BusyBox base, no bash by default) ────────────
phase5-lxd/lab-lxd.sh up --config examples/shell-intermediate-workshop/shell-intermediate-alpine.toml
examples/shell-intermediate-workshop/setup-workshop.sh shell-intermediate-alpine/shell    # ~1 min
phase5-lxd/lab-lxd.sh exec shell-intermediate-alpine/shell -- su - learner                # start scripting
phase5-lxd/lab-lxd.sh down --lab shell-intermediate-alpine                                # tear down

# ── Debian 13 (trixie / glibc base) ─────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/shell-intermediate-workshop/shell-intermediate-debian.toml
examples/shell-intermediate-workshop/setup-workshop.sh shell-intermediate-debian/shell
phase5-lxd/lab-lxd.sh exec shell-intermediate-debian/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab shell-intermediate-debian
```

Then **open the PDFs** ([`upstream-tutorial/bash.pdf`](upstream-tutorial/bash.pdf),
`bash2.pdf`, `bash3.pdf`) in your viewer and follow along, writing scripts in
`~/bash-by-example/` inside the `su - learner` shell. A runnable starter
(`demo.sh`) is already there.

## What `setup-workshop.sh` does

Automated counterpart to the by-hand walk in [RUNBOOK.md](RUNBOOK.md); it touches
the guest **only** through `lab-lxd.sh exec` (engine-agnostic), in five steps:

1. **detect** the distro (`/etc/alpine-release` vs `/etc/debian_version`);
2. **install** bash + the standard complement of Unix tools (`apt`/`apk`);
3. **create** a non-root `learner` user with a bash login shell;
4. **create** `~/bash-by-example/` with a benign starter script exercising
   Part 1–2 constructs (variable expansion, a function, `[[ ]]`, a `for` loop,
   `(( ))` arithmetic);
5. **verify** as `learner` — print `bash --version` and **run the starter**.

## The series

Roughly an evening-to-a-day at a steady pace ([provenance + `sha256`](upstream-tutorial/README.md)):

1. **Part 1 — Fundamental programming in bash** ([`bash.pdf`](upstream-tutorial/bash.pdf)):
   why bash, variables, quoting, the environment, redirection, builtins.
2. **Part 2 — More bash programming fundamentals** ([`bash2.pdf`](upstream-tutorial/bash2.pdf)):
   conditionals (`if`/`test`/`[[ ]]`), loops (`for`/`while`/`until`), `case`,
   functions, `getopts`.
3. **Part 3 — Exploring the ebuild system** ([`bash3.pdf`](upstream-tutorial/bash3.pdf)):
   how Gentoo's package format uses bash as its scripting language — a real-world
   case study. **Reading material**: it's Gentoo-specific, so its `emerge`/ebuild
   commands don't run on this Debian/Alpine box, but the bash patterns it shows do.

Everything Parts 1–2 need is installed and verified on **both** bases.

### Documented divergence: bare Alpine has no bash

A fresh Alpine container has **no `bash` at all** — `/bin/sh` is BusyBox *ash*,
which rejects the bashisms these articles are built on:

```
$ command -v bash || echo "bash: NOT INSTALLED"
bash: NOT INSTALLED
$ x=hello; echo "${x^^}"          # bash-4 parameter expansion
sh: syntax error: bad substitution
```

So the Alpine track installs `bash` (+ GNU coreutils, and `man bash` via
`bash-doc`). After that, the articles run **identically** to Debian — same
`${x^^}`, same `[[ ]]`, same `(( ))`. Captured verbatim in
[MANUAL_TESTING](MANUAL_TESTING.md#documented-divergence-bare-alpine-has-no-bash).
(Debian ships bash already, so it needs no such fix.)

## Files

| File | Purpose |
|---|---|
| [`shell-intermediate-debian.toml`](shell-intermediate-debian.toml) / [`shell-intermediate-alpine.toml`](shell-intermediate-alpine.toml) | Phase-5 specs: one container each |
| [`setup-workshop.sh`](setup-workshop.sh) | Provision tools + `learner` user + playground |
| [`RUNBOOK.md`](RUNBOOK.md) | The by-hand walk — every step, with the *why* |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Real captured transcripts (both distros) |
| [`upstream-tutorial/`](upstream-tutorial/README.md) | Byte-exact `bash{,2,3}.pdf` (© Robbins/IBM) + provenance |

## Scope & caveats

- **Throwaway lab.** Containers are disposable; `down` wipes them. No persistent
  state, no real credentials. Re-run the quick start for a clean slate.
- **Non-root `learner`.** Scripting is done as an ordinary user; the container's
  root is only used by `setup-workshop.sh`.
- **System container, not a VM.** Plenty for a scripting course.
- **Part 3 is reading.** The ebuild article is Gentoo-specific; the bash lessons
  transfer, the `emerge` commands don't run here.
- **Read the PDFs on the host, type in the container.** They live in this repo;
  open them in your viewer, run commands via `exec … su - learner`.

## Prerequisites

- **LXD or Incus initialised** — `incus admin init` (or `lxd init`). See the
  Phase-5 docs: [`START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- Outbound network from the container (to `apt`/`apk` the tools).

## Sources

The three articles are © Daniel Robbins / IBM developerWorks (2000) and are
**not** open-licensed — vendored byte-exact for offline educational reference
under [`upstream-tutorial/`](upstream-tutorial/README.md) (provenance + `sha256`
+ attribution). Mirror used:

- <https://theory.stanford.edu/~sbansal/tut/bash/bash.pdf>
- <https://theory.stanford.edu/~sbansal/tut/bash/bash2.pdf>
- <https://theory.stanford.edu/~sbansal/tut/bash/bash3.pdf>

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog.

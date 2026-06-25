# shell-intermediate-programming-by-example — a BASH box for Matt Might's "bash by example"

A **throwaway system container** with **BASH** and the standard complement of
Unix tools, plus a non-root **`learner`** user and a `~/bash-by-example/`
scratch directory (with a runnable starter script), so you can work through
**Matt Might's**
**["Shell programming with bash: by example, by counter-example"](upstream-tutorial/articles/bash-by-example/index.html)**
— *writing and running scripts* as you read. Built and driven through the repo's
**Phase-5** tool ([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks
**LXD or Incus** identically.

Might's guide is a dense, one-shot tour of intermediate bash: arrays, parameter
expansion, the `* versus @` quirk, arithmetic, scope, redirection, pipes, process
substitution, globs, control structures, subroutines — and the **counter-examples**
(the pitfalls) that make each stick. It's the programming companion to his
[*survival guide*](../UNIX_novice_survival_guide/README.md) (which he names as the
prerequisite), and a Matt-Might-flavoured alternative to the Daniel-Robbins
[`shell-intermediate-workshop/`](../shell-intermediate-workshop/README.md).

The guide is vendored byte-exact under
[`upstream-tutorial/`](upstream-tutorial/README.md) — read it on one screen, type
in the container on the other.

Two bases, both first-class and **verified end-to-end** ([proof per distro in
MANUAL_TESTING](MANUAL_TESTING.md)):

| Spec | Base | Default userland | What `setup-workshop.sh` installs |
|---|---|---|---|
| [`bash-by-example-debian.toml`](bash-by-example-debian.toml) | Debian 13 (trixie) | **already bash + GNU coreutils** | nano, less, man-db + bash-doc, bc, diffutils, tree, file, gawk |
| [`bash-by-example-alpine.toml`](bash-by-example-alpine.toml) | Alpine | ash + **BusyBox**, **no bash** | **bash + GNU coreutils/grep/sed/findutils** + man + the above |

> This article is pure **bash** — arrays, `${var/x/y}`, `(( ))`, `declare -i`,
> `${!indirect}` are the whole point. Alpine's default `/bin/sh` is BusyBox
> *ash*, which has no arrays and no `(( ))`, so the Alpine track installs real
> bash — a documented divergence, [below](#documented-divergence-bare-alpine-has-no-bash).

## Quick start

Both bases are first-class — pick either (or run both; the labs are independent
and coexist). The flow is identical bar the name:

```bash
# ── Alpine (musl / BusyBox base, no bash by default) ────────────
phase5-lxd/lab-lxd.sh up --config examples/shell-intermediate-programming-by-example/bash-by-example-alpine.toml
examples/shell-intermediate-programming-by-example/setup-workshop.sh bash-by-example-alpine/shell    # ~1 min
phase5-lxd/lab-lxd.sh exec bash-by-example-alpine/shell -- su - learner                               # start scripting
phase5-lxd/lab-lxd.sh down --lab bash-by-example-alpine                                               # tear down

# ── Debian 13 (trixie / glibc base) ─────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/shell-intermediate-programming-by-example/bash-by-example-debian.toml
examples/shell-intermediate-programming-by-example/setup-workshop.sh bash-by-example-debian/shell
phase5-lxd/lab-lxd.sh exec bash-by-example-debian/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab bash-by-example-debian
```

Then **open the guide**
([`upstream-tutorial/articles/bash-by-example/index.html`](upstream-tutorial/articles/bash-by-example/index.html))
in your viewer and follow along, writing scripts in `~/bash-by-example/` inside
the `su - learner` shell. A runnable starter (`demo.sh`) is already there.

## What `setup-workshop.sh` does

Automated counterpart to the by-hand walk in [RUNBOOK.md](RUNBOOK.md); it touches
the guest **only** through `lab-lxd.sh exec` (engine-agnostic), in five steps:

1. **detect** the distro (`/etc/alpine-release` vs `/etc/debian_version`);
2. **install** bash + the standard complement of Unix tools (`apt`/`apk`);
3. **create** a non-root `learner` user with a bash login shell;
4. **create** `~/bash-by-example/demo.sh` — a benign starter exercising constructs
   from the article (arrays + `${#a[@]}`, parameter expansion, `(( ))` arithmetic,
   a factorial function);
5. **verify** as `learner` — print `bash --version` and **run the starter**
   (`5! = 120`).

## The article

A single dense page — an evening-to-a-day at a steady pace ([provenance +
`sha256`](upstream-tutorial/README.md)). It moves through:

- **Variables/arrays** — every variable is an array; `${foo[@]}`, copy quirks
- **Special variables** — `$0 $1 $# $? $$ $!`, exit status, background + `wait`
- **Operations on variables** — `${foo/x/y}`, `${path##*/bin}`, `${str:6:3}`,
  existence tests (`${var:-default}`, `:=`, `+`, `?`), `${!indirect}`
- **`* versus @`** — the quoting counter-example, and `IFS`
- **Strings/quoting**, **scope** (`export`), **arithmetic** (`expr`, `(( ))`,
  `$(( ))`, `declare -i`)
- **Files and redirection** — `< > >> << 2> M>&N 2>&1`, backticks/`$( )`, `exec`
- **Pipes** and **process substitution** `<( )`; **processes** (`&`, `$!`, `wait`)
- **Globs and patterns** — `* ? [a-b]`, brace expansion, the "bash bomb"
- **Control structures** — `if`/`test`/`[ ]`, `while`, `for`, subroutines
- **Pitfalls** — the counter-examples throughout

Everything it needs is installed and verified on **both** bases.

### Documented divergence: bare Alpine has no bash

A fresh Alpine container has **no `bash` at all** — `/bin/sh` is BusyBox *ash*,
which lacks the two pillars this array-heavy article is built on:

```
$ command -v bash || echo "bash: NOT INSTALLED"
bash: NOT INSTALLED
$ foo=(a b c); echo "${foo[1]}"   # arrays — the article's core topic
sh: syntax error: unexpected "("
$ (( y = 3 * 12 )); echo "$y"     # the (( )) arithmetic command
sh: y: not found
```

So the Alpine track installs `bash` (+ GNU coreutils, and `man bash` via
`bash-doc`). After that, the article runs **identically** to Debian. (BusyBox ash
*does* handle simple `${x/cat/dog}`, so not everything breaks — but without arrays
or `(( ))`, most of the guide can't run.) Captured verbatim in
[MANUAL_TESTING](MANUAL_TESTING.md#documented-divergence-bare-alpine-has-no-bash).
(Debian ships bash already, so it needs no such fix.)

## Files

| File | Purpose |
|---|---|
| [`bash-by-example-debian.toml`](bash-by-example-debian.toml) / [`bash-by-example-alpine.toml`](bash-by-example-alpine.toml) | Phase-5 specs: one container each |
| [`setup-workshop.sh`](setup-workshop.sh) | Provision tools + `learner` user + playground |
| [`RUNBOOK.md`](RUNBOOK.md) | The by-hand walk — every step, with the *why* |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Real captured transcripts (both distros) |
| [`upstream-tutorial/`](upstream-tutorial/README.md) | Byte-exact guide (© Matt Might) + images + CSS + provenance |

## Scope & caveats

- **Throwaway lab.** Containers are disposable; `down` wipes them. No persistent
  state, no real credentials. Re-run the quick start for a clean slate.
- **Non-root `learner`.** Scripting is done as an ordinary user; the container's
  root is only used by `setup-workshop.sh`.
- **System container, not a VM.** Plenty for a scripting course.
- **A few examples reference extra tools** (`convert` from ImageMagick, `gcc`)
  used only to *illustrate* parallelism/loops; they aren't installed by default —
  `apt install imagemagick` / `apk add imagemagick` if you want to run those
  verbatim. The bash lessons don't depend on them.
- **Read the guide on the host, type in the container.** It lives in this repo;
  open it in your viewer, run commands via `exec … su - learner`.

## Prerequisites

- **LXD or Incus initialised** — `incus admin init` (or `lxd init`). See the
  Phase-5 docs: [`START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- Outbound network from the container (to `apt`/`apk` the tools).

## Sources

The guide is © **Matt Might** and carries no explicit open license; it is vendored
byte-exact for **offline educational reference** under
[`upstream-tutorial/`](upstream-tutorial/README.md) (provenance + `sha256` +
attribution, including the two inline screenshots).

- Guide: <https://matt.might.net/articles/bash-by-example/>

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog.

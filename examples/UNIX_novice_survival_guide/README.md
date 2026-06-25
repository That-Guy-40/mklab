# UNIX_novice_survival_guide — a ready box for Matt Might's Unix survival guide

A **throwaway system container** with **BASH** and the standard complement of
Unix tools, plus a non-root **`learner`** user and a small `~/unix-survival/`
sandbox that **mirrors the guide's running examples**, so you can read
**Matt Might's [*"A survival guide for Unix beginners"*](upstream-tutorial/articles/basic-unix/index.html)**
on one screen and type the very commands it shows on the other — and get matching
output. Built and driven through the repo's **Phase-5** tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically.

This is a *survival guide*, not a course: it's the gentle on-ramp that comes
**before** [`shell-novice-workshop/`](../shell-novice-workshop/README.md) (a
full-day hands-on lesson) and [`shell-intermediate-workshop/`](../shell-intermediate-workshop/README.md)
(bash scripting). Might's article is the "what is this and why should I care"
read that makes the rest click.

The guide is vendored byte-exact under
[`upstream-tutorial/`](upstream-tutorial/README.md) — open it in your browser and
read offline.

Two bases, both first-class and **verified end-to-end** ([proof per distro in
MANUAL_TESTING](MANUAL_TESTING.md)):

| Spec | Base | Default userland | What `setup-workshop.sh` installs |
|---|---|---|---|
| [`unix-survival-debian.toml`](unix-survival-debian.toml) | Debian 13 (trixie) | **already bash + GNU + man + ssh** | less, nano, vim, man-db/manpages, info, tree, file, gawk |
| [`unix-survival-alpine.toml`](unix-survival-alpine.toml) | Alpine | ash + **BusyBox**, **no `man`, no `ssh`** | **bash + GNU tools + `man` (mandoc) + `apropos` + `ssh`** + the above |

> The guide walks through `ls`/`cd`/`pwd`, symlinks, `cat`/`less`, editors,
> `man`/`apropos`/`info`, `grep`/`find`, pipes & redirection, permissions, and
> `ssh`. Debian has all of it out of the box; **bare Alpine has neither `man` nor
> `ssh`** — two whole sections of the guide — so the Alpine track installs them, a
> documented divergence, [below](#documented-divergence-bare-alpine-has-no-man-or-ssh).

## Quick start

Both bases are first-class — pick either (or run both; the labs are independent
and coexist). The flow is identical bar the name:

```bash
# ── Alpine (musl / BusyBox base, no man/ssh by default) ─────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX_novice_survival_guide/unix-survival-alpine.toml
examples/UNIX_novice_survival_guide/setup-workshop.sh unix-survival-alpine/shell    # ~1 min
phase5-lxd/lab-lxd.sh exec unix-survival-alpine/shell -- su - learner               # start reading
phase5-lxd/lab-lxd.sh down --lab unix-survival-alpine                               # tear down

# ── Debian 13 (trixie / glibc base) ─────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX_novice_survival_guide/unix-survival-debian.toml
examples/UNIX_novice_survival_guide/setup-workshop.sh unix-survival-debian/shell
phase5-lxd/lab-lxd.sh exec unix-survival-debian/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab unix-survival-debian
```

Then **open the guide**
([`upstream-tutorial/articles/basic-unix/index.html`](upstream-tutorial/articles/basic-unix/index.html))
in your browser and follow along, typing in the `su - learner` shell. You'll land
in `/home/learner` with the sandbox ready — try `find . | grep READ` or
`ls -l unix-survival` and watch the guide's examples come to life.

## What `setup-workshop.sh` does

Automated counterpart to the by-hand walk in [RUNBOOK.md](RUNBOOK.md); it touches
the guest **only** through `lab-lxd.sh exec` (engine-agnostic), in five steps:

1. **detect** the distro (`/etc/alpine-release` vs `/etc/debian_version`);
2. **install** bash + the standard complement of Unix tools (`apt`/`apk`) — incl.
   `man`/`apropos`/`info` and `ssh` (the parts bare Alpine lacks);
3. **create** a non-root `learner` user with a bash login shell;
4. **build** `~/unix-survival/` mirroring the guide's examples — a `README.txt`, a
   `Desktop/READINGLIST.txt`, and a `baz -> bar` symlink — so the article's
   commands produce matching output;
5. **verify** as `learner` — run a few commands straight from the guide
   (`find . | grep READ`, the symlink `ls -l`, `man ls`).

## What the guide covers

Matt Might's article is a single readable page ([provenance + `sha256`](upstream-tutorial/README.md)),
roughly an evening's read, organized as:

1. **What is computing with Unix?** / getting access / reaching the command line
2. **The filesystem** — `ls`, `cd`, paths, `pwd`
3. **Symbolic links** — `ln -s`, and `ls -l` to see where a link points
4. **Working with text** — `cat`, `less`, and the editors `emacs`/`vim`
5. **Help yourself: man up** — `man`, `apropos`, `info`
6. **Search for it** — `grep` and `find`
7. **Pipes and redirection** — `>`, `<`, and the `|` pipe
8. **Permissions** — `chmod`/`chown`/`chgrp` and reading the `ls -l` columns
9. **Package managers** and **Remote access: `ssh`** (`ssh-keygen`, `~/.ssh/config`)

Everything it walks through is installed and verified on **both** bases.

### Documented divergence: bare Alpine has no `man` or `ssh`

A fresh Alpine container is BusyBox — `/bin/sh` is *ash*, and two whole sections
of the guide simply can't run, because neither `man` nor `ssh` (nor `bash`) is
present:

```
$ command -v man || echo "man: NOT INSTALLED"
man: NOT INSTALLED
$ man ls                 # the guide's "man command" advice
sh: man: not found
$ ssh user@host          # the guide's "ssh user@address" advice
sh: ssh: not found
```

So the Alpine track installs `bash` + GNU tools, **`mandoc`/`man-pages`** (for
`man`), **`mandoc-apropos`** (for `apropos`), **`texinfo`** (for `info`), and
**`openssh-client`** (for `ssh`/`ssh-keygen`). After that the guide runs
**identically** to Debian. Captured verbatim in
[MANUAL_TESTING](MANUAL_TESTING.md#documented-divergence-bare-alpine-has-no-man-and-no-ssh).
(Debian ships all of it already, so it needs no such fix.)

## Files

| File | Purpose |
|---|---|
| [`unix-survival-debian.toml`](unix-survival-debian.toml) / [`unix-survival-alpine.toml`](unix-survival-alpine.toml) | Phase-5 specs: one container each |
| [`setup-workshop.sh`](setup-workshop.sh) | Provision tools + `learner` user + the `~/unix-survival` sandbox |
| [`RUNBOOK.md`](RUNBOOK.md) | The by-hand walk — every step, with the *why* |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Real captured transcripts (both distros) |
| [`upstream-tutorial/`](upstream-tutorial/README.md) | Byte-exact guide (© Matt Might) + CSS + provenance |

## Scope & caveats

- **Throwaway lab.** Containers are disposable; `down` wipes them. No persistent
  state, no real credentials. Re-run the quick start for a clean slate.
- **Non-root `learner`.** You read the guide as an ordinary user (authentic
  prompt + `whoami`); the container's root is only used by `setup-workshop.sh`.
- **System container, not a VM.** Plenty for a survival-guide read-along.
- **Editors:** the guide recommends `emacs` *or* `vim`; this box installs **`vim`**
  (with `vimtutor`) and **`nano`**. Prefer emacs? It's one `apt install emacs` /
  `apk add emacs` away.
- **Mac/Windows bits are read-only.** The guide also covers OS X and PuTTY; those
  paragraphs are just reading on this Linux box.
- **Read the guide on the host, type in the container.** The page is a file in
  this repo — open it in your browser; run commands via `exec … su - learner`.

## Prerequisites

- **LXD or Incus initialised** — `incus admin init` (or `lxd init`). See the
  Phase-5 docs: [`START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- Outbound network from the container (to `apt`/`apk` the tools).

## Sources

The guide is © **Matt Might** and carries no explicit open license; it is vendored
byte-exact for **offline educational reference** under
[`upstream-tutorial/`](upstream-tutorial/README.md) (provenance + `sha256` +
attribution). The author explicitly encourages forwarding it.

- Guide: <https://matt.might.net/articles/basic-unix/>

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog.

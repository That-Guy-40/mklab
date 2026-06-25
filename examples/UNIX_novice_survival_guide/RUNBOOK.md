# RUNBOOK — prepare the survival-guide box by hand, step by step

This is the **by-hand walk**: every command [`setup-workshop.sh`](setup-workshop.sh)
runs, with the *why* at each step. Do it once by hand to understand what a Unix
"survival" environment needs; use the script afterward. It prepares a BASH box
with the standard tools and a small sandbox for **Matt Might's**
[*"A survival guide for Unix beginners"*](upstream-tutorial/articles/basic-unix/index.html)
— the gentle on-ramp before
[`shell-novice-workshop/`](../shell-novice-workshop/README.md) and
[`shell-intermediate-workshop/`](../shell-intermediate-workshop/README.md).

Everything goes through the Phase-5 tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically. Run commands from the repo root.

## Pick a base — Debian **or** Alpine (both fully supported)

Both bases are first-class and **verified end-to-end** ([proof for each in
MANUAL_TESTING](MANUAL_TESTING.md)). They differ only in the package manager and
in *how much* needs installing — Debian already has bash + GNU + `man` + `ssh`;
Alpine has **neither `man` nor `ssh`** by default (see
[bare Alpine has no man or ssh](#bare-alpine-has-no-man-or-ssh)):

| | Debian 13 (trixie) | Alpine |
|---|---|---|
| spec | [`unix-survival-debian.toml`](unix-survival-debian.toml) | [`unix-survival-alpine.toml`](unix-survival-alpine.toml) |
| image | `images:debian/13` (glibc, GNU userland) | `images:alpine/latest` (musl, BusyBox userland) |
| lab/service handle | `unix-survival-debian/shell` | `unix-survival-alpine/shell` |
| installer | `apt-get` | `apk` |

Pick your base — the rest of the walk reads the same for both:

```bash
LAB=unix-survival-debian        # Debian 13 (trixie)
# - or -
LAB=unix-survival-alpine        # Alpine
```

(Just want it ready without the narration? Jump to
[Just run it](#just-run-it-either-base).)

## 0. Prerequisites

LXD or Incus must be initialised (`incus admin init` or `lxd init`). See
[`../../phase5-lxd/START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
The container needs outbound network to fetch the tools.

## 1. Bring up the container

```bash
phase5-lxd/lab-lxd.sh up --config examples/UNIX_novice_survival_guide/$LAB.toml
```

One unprivileged **system container** — a full userland with a package manager
and an init — which is what we want: we install tools and add a user, like
setting up a real Linux box to find your feet on.

## 2. Install BASH + the standard complement of tools

The guide walks through navigation (`ls`/`cd`/`pwd`), symlinks (`ln -s`), text
(`cat`/`less`/editors), docs (`man`/`apropos`/`info`), search (`grep`/`find`),
pipes, permissions, and `ssh`. This is the step that differs by base:

```bash
# Debian (unix-survival-debian/shell) — base already has bash + GNU coreutils +
# man + ssh; add the viewers/editors, info, and reading tools:
phase5-lxd/lab-lxd.sh exec unix-survival-debian/shell -- \
    sh -c 'apt-get update -qq && apt-get install -y --no-install-recommends \
           bash coreutils findutils grep sed gawk \
           nano vim less man-db manpages info \
           openssh-client ca-certificates file tree procps'

# Alpine (unix-survival-alpine/shell) — base has NO man and NO ssh (see below).
# Install bash + GNU tools, man (mandoc) + apropos (mandoc-apropos) + per-tool
# man pages (`*-doc`), info (texinfo), and ssh (openssh-client), then build the
# apropos index (Debian's man-db does this automatically):
phase5-lxd/lab-lxd.sh exec unix-survival-alpine/shell -- \
    sh -c 'apk add --no-cache bash coreutils findutils grep sed gawk \
           nano vim less mandoc mandoc-apropos man-pages texinfo \
           openssh-client ca-certificates \
           coreutils-doc grep-doc sed-doc findutils-doc \
           file tree procps-ng shadow
           makewhatis /usr/share/man 2>/dev/null || true'
```

### bare Alpine has no man or ssh

A fresh Alpine container is **BusyBox**: `/bin/sh` is *ash*, and two whole
sections of the guide — **"Help yourself: man up"** and **"Remote access: ssh"** —
have nothing to run, because neither `man` nor `ssh` (nor `bash`) is installed
(`man ls` → `sh: man: not found`). So on Alpine we install them; after that,
every example runs exactly as on Debian. The bare-Alpine behavior is captured in
[MANUAL_TESTING](MANUAL_TESTING.md#documented-divergence-bare-alpine-has-no-man-and-no-ssh).
(Debian already ships bash, man, and ssh, so it needs no such fix.)

## 3. Create the non-root `learner` user

You explore Unix as an ordinary user — authentic prompt, real `whoami`, sane file
ownership (and a safe place to learn `chmod`).

```bash
# Debian:
phase5-lxd/lab-lxd.sh exec unix-survival-debian/shell -- \
    sh -c 'id learner >/dev/null 2>&1 || useradd -m -s /bin/bash learner'

# Alpine (adduser, not useradd):
phase5-lxd/lab-lxd.sh exec unix-survival-alpine/shell -- \
    sh -c 'id learner >/dev/null 2>&1 || adduser -D -s /bin/bash learner'
```

## 4. Build a sandbox that mirrors the guide's examples

Recreate the files the guide uses so its commands produce **matching output** —
e.g. `find . | grep READ` finds `README.txt` + `Desktop/READINGLIST.txt`, and
`ls -l` shows the `baz -> bar` symlink the "Symbolic links" section describes:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- su - learner -c '
mkdir -p ~/Documents ~/Desktop ~/unix-survival
printf "%s\n%s\n" "* A README file for my home directory." "Documents contains my files." > ~/README.txt
printf "%s\n%s\n%s\n" "The UNIX Programming Environment" "The Cathedral and the Bazaar" "Classic Shell Scripting" > ~/Desktop/READINGLIST.txt
cd ~/unix-survival
: > foo
: > bar
ln -sf bar baz                                       # symlink demo: baz -> bar
printf "%s\n%s\n" "hello unix" "the command line is a language" > notes.txt
'
```

## 5. Verify, then start reading

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- su - learner -c \
    'cd ~ && find . | grep READ; ls -l ~/unix-survival | grep -- "-> bar"; man ls | head -1'
```

You should see both `READ*` files, the `baz -> bar` symlink, and the `ls(1)` man
page header. Now **drop into the learner's shell**:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- su - learner
```

For example, starting on **Alpine** is just:

```bash
phase5-lxd/lab-lxd.sh exec unix-survival-alpine/shell -- su - learner
```

…and Debian is identical bar the name. Then open
[`upstream-tutorial/articles/basic-unix/index.html`](upstream-tutorial/articles/basic-unix/index.html)
in your browser and read along, trying each command in `~/unix-survival/`.

## 6. Teardown

```bash
phase5-lxd/lab-lxd.sh down --lab $LAB        # unix-survival-debian or -alpine
```

`down` stops and deletes the container; nothing persists.

## Just run it (either base)

Steps 2–5 are exactly what [`setup-workshop.sh`](setup-workshop.sh) automates.
The full path, shown concretely for **both** bases — pick whichever (or run both,
they're independent):

```bash
# ── Alpine (musl / BusyBox, no man/ssh by default) ──────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX_novice_survival_guide/unix-survival-alpine.toml
examples/UNIX_novice_survival_guide/setup-workshop.sh unix-survival-alpine/shell   # tools + learner + sandbox
phase5-lxd/lab-lxd.sh exec unix-survival-alpine/shell -- su - learner              # start reading
phase5-lxd/lab-lxd.sh down --lab unix-survival-alpine                              # done

# ── Debian 13 (glibc) ───────────────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX_novice_survival_guide/unix-survival-debian.toml
examples/UNIX_novice_survival_guide/setup-workshop.sh unix-survival-debian/shell
phase5-lxd/lab-lxd.sh exec unix-survival-debian/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab unix-survival-debian
```

## Gotchas

- **`man: not found` / `ssh: not found` on Alpine** → you skipped step 2's
  `mandoc`/`openssh-client`. Bare Alpine has neither. See
  [bare Alpine has no man or ssh](#bare-alpine-has-no-man-or-ssh).
- **`apropos` finds nothing on Alpine** → install `mandoc-apropos` and run
  `makewhatis /usr/share/man` to build the index (step 2 does both). On Debian,
  `man-db` builds it automatically.
- **`emacs: command not found`** → this box installs `vim` + `nano`, not emacs;
  the guide recommends either. `apt install emacs` / `apk add emacs` if you prefer it.
- **Image won't download / `up` hangs** → the `images:` remote can stall; it's
  not a lab bug. Pre-pull once with `incus image copy images:alpine/3.24 local:`
  (or `images:debian/13`) and retry.

# RUNBOOK — prepare the workshop box by hand, step by step

This is the **by-hand walk**: every command [`setup-workshop.sh`](setup-workshop.sh)
runs, with the *why* at each step. Do it once by hand to understand what the
workshop environment needs; use the script afterward. It prepares the **Linux
track** of the [`shell-novice` setup](upstream-tutorial/aio.html) — a BASH shell
with the standard tools and the lesson data ready to go.

Everything goes through the Phase-5 tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically. Run commands from the repo root.

## Pick a base — Debian **or** Alpine (both fully supported)

Both bases are first-class and **verified end-to-end** ([proof for each in
MANUAL_TESTING](MANUAL_TESTING.md)). They differ only in the package manager and
in *how much* needs installing — Debian already has bash + GNU tools; Alpine
needs them added (see [BusyBox vs GNU](#busybox-vs-gnu)):

| | Debian 13 (trixie) | Alpine |
|---|---|---|
| spec | [`shell-novice-debian.toml`](shell-novice-debian.toml) | [`shell-novice-alpine.toml`](shell-novice-alpine.toml) |
| image | `images:debian/13` (glibc, GNU userland) | `images:alpine/latest` (musl, BusyBox userland) |
| lab/service handle | `shell-novice-debian/shell` | `shell-novice-alpine/shell` |
| installer | `apt-get` | `apk` |

Pick your base — the rest of the walk reads the same for both:

```bash
LAB=shell-novice-debian        # Debian 13 (trixie)
# - or -
LAB=shell-novice-alpine        # Alpine
```

(Just want it ready without the narration? Jump to
[Just run it](#just-run-it-either-base).)

## 0. Prerequisites

LXD or Incus must be initialised (`incus admin init` or `lxd init`). See
[`../../phase5-lxd/START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
The container needs outbound network to fetch the tools.

## 1. Bring up the container

```bash
phase5-lxd/lab-lxd.sh up --config examples/shell-novice-workshop/$LAB.toml
```

This launches one unprivileged **system container** — a full userland with a
package manager and an init — which is what we want: we'll install tools and add
a user, just like setting up a real Linux box for the workshop.

## 2. Install BASH + the standard complement of tools

The lesson assumes **bash** and the **GNU** core tools (`ls -F`, `wc -l`,
`sort -n`, `head -n`, `man`, …). This is the step that differs by base:

```bash
# Debian (shell-novice-debian/shell) — base already has bash + GNU coreutils;
# add the interactive tools, man pages, and unzip:
phase5-lxd/lab-lxd.sh exec shell-novice-debian/shell -- \
    sh -c 'apt-get update -qq && apt-get install -y --no-install-recommends \
           bash coreutils findutils grep sed gawk nano less \
           man-db manpages unzip wget ca-certificates file tree procps'

# Alpine (shell-novice-alpine/shell) — base is BusyBox, so install the REAL
# bash + GNU tools (see "BusyBox vs GNU" below). Per-tool man pages are in
# `*-doc` subpackages on Alpine:
phase5-lxd/lab-lxd.sh exec shell-novice-alpine/shell -- \
    apk add --no-cache bash coreutils findutils grep sed gawk nano less \
           mandoc man-pages coreutils-doc grep-doc sed-doc findutils-doc \
           unzip wget ca-certificates file tree procps-ng shadow
```

### BusyBox vs GNU

A fresh Alpine container is **BusyBox**: `/bin/ls`, `/bin/sh`, etc. are all
symlinks to one `/bin/busybox` multi-call binary, there's **no `bash`** and **no
`man`**, and BusyBox's applets accept a smaller flag set than GNU (e.g.
`ls --version` errors). The lesson is written against bash + GNU coreutils, so on
Alpine we install the real ones — after which the workshop behaves **exactly** as
on Debian. The bare-BusyBox behavior is captured in
[MANUAL_TESTING](MANUAL_TESTING.md#documented-divergence-busybox-vs-gnu).
(Debian already ships bash + GNU coreutils, so it needs no such fix.)

## 3. Create the non-root `learner` user

Attendees don't work as root — a normal account gives the authentic `$` prompt,
a real `whoami`, and file ownership that behaves like the lesson expects.

```bash
# Debian:
phase5-lxd/lab-lxd.sh exec shell-novice-debian/shell -- \
    sh -c 'id learner >/dev/null 2>&1 || useradd -m -s /bin/bash learner'

# Alpine (adduser, not useradd):
phase5-lxd/lab-lxd.sh exec shell-novice-alpine/shell -- \
    sh -c 'id learner >/dev/null 2>&1 || adduser -D -s /bin/bash learner'
```

## 4. Unzip the workshop data into the learner's home

The lesson's first move is to unzip `shell-lesson-data.zip` and `cd` into it.
Stream the vendored zip in through the phase tool (`exec` forwards stdin), unzip,
and hand ownership to `learner`:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- \
    sh -c 'cat > /tmp/shell-lesson-data.zip' \
    < examples/shell-novice-workshop/shell-lesson-data.zip

phase5-lxd/lab-lxd.sh exec $LAB/shell -- \
    sh -c 'cd /home/learner && unzip -q /tmp/shell-lesson-data.zip \
           && chown -R learner:learner shell-lesson-data && rm -f /tmp/shell-lesson-data.zip'
```

## 5. Verify, then start the workshop

Confirm the environment as the learner:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- su - learner -c \
    'whoami; bash --version | head -1; ls -F ~/shell-lesson-data'
```

Now **drop into the learner's shell** — this is where the attendee lives for the
day:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- su - learner
```

For example, starting the **Alpine** workshop is just:

```bash
phase5-lxd/lab-lxd.sh exec shell-novice-alpine/shell -- su - learner
```

…and Debian is identical bar the name. Then open
[`upstream-tutorial/aio.html`](upstream-tutorial/aio.html) in your browser
(host-side) and work the **Linux track** — `cd ~/shell-lesson-data` and follow
along.

## 6. Teardown

```bash
phase5-lxd/lab-lxd.sh down --lab $LAB        # shell-novice-debian or shell-novice-alpine
```

`down` stops and deletes the container; nothing persists.

## Just run it (either base)

Steps 2–5 are exactly what [`setup-workshop.sh`](setup-workshop.sh) automates.
The full path, shown concretely for **both** bases — pick whichever (or run both,
they're independent):

```bash
# ── Alpine (musl / BusyBox) ─────────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/shell-novice-workshop/shell-novice-alpine.toml
examples/shell-novice-workshop/setup-workshop.sh shell-novice-alpine/shell    # tools + learner + data
phase5-lxd/lab-lxd.sh exec shell-novice-alpine/shell -- su - learner          # start the workshop
phase5-lxd/lab-lxd.sh down --lab shell-novice-alpine                          # done

# ── Debian 13 (glibc) ───────────────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/shell-novice-workshop/shell-novice-debian.toml
examples/shell-novice-workshop/setup-workshop.sh shell-novice-debian/shell
phase5-lxd/lab-lxd.sh exec shell-novice-debian/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab shell-novice-debian
```

## Gotchas

- **BusyBox surprises on Alpine** → you skipped step 2's `bash`/`coreutils`. A
  command behaving oddly (`ls --version` errors, no `man`) means you're on a
  BusyBox applet, not the GNU tool. See [BusyBox vs GNU](#busybox-vs-gnu).
- **`man ls` says "No manual entry"** on Alpine → per-tool man pages live in
  `*-doc` subpackages (`coreutils-doc`, `grep-doc`, …); step 2 installs them.
- **`man`/`less`/`nano`/`clear` looks garbled / "unknown terminal type"** → your
  client's `$TERM` (e.g. Ghostty's `xterm-ghostty`) has no terminfo entry inside
  the container. `lab-lxd.sh exec` sets `TERM=xterm` for interactive sessions to
  avoid this; override with `LAB_TERM` (e.g. `LAB_TERM=xterm-256color`). See
  [START_HERE](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- **Image won't download / `up` hangs** → the `images:` remote can stall; it's
  not a lab bug. Pre-pull once with `incus image copy images:alpine/3.24 local:`
  (or `images:debian/13`) and retry.
- **Edits vanish on teardown** → that's by design; the container is disposable.
  Re-run the quick start for a fresh box.

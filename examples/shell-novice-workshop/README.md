# shell-novice-workshop — a ready BASH box for the Software Carpentry shell lesson

A **throwaway system container** with **BASH** and the standard complement of
Unix tools, pre-loaded with the workshop dataset, so you (or a class) can work
through The Carpentries' **[*The Unix Shell* (`shell-novice`)](upstream-tutorial/aio.html)**
lesson — a gentle, ~full-day intro to the command line — without touching your
real machine. Built and driven through the repo's **Phase-5** tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically.

The whole lesson is vendored byte-exact as a single page
([`upstream-tutorial/aio.html`](upstream-tutorial/aio.html), "All in One View")
so you can read it offline on one screen while typing in the container on the
other. The workshop data ([`shell-lesson-data.zip`](shell-lesson-data.zip)) is
unzipped into a non-root **`learner`** user's home — so the prompt, `whoami`, and
file ownership all feel like a real account, the way an attendee experiences it.

Two bases, both first-class and **verified end-to-end** ([proof per distro in
MANUAL_TESTING](MANUAL_TESTING.md)):

| Spec | Base | Default userland | What `setup-workshop.sh` installs |
|---|---|---|---|
| [`shell-novice-debian.toml`](shell-novice-debian.toml) | Debian 13 (trixie) | **already bash + GNU coreutils** | nano, less, man-db/manpages, unzip, wget, tree, file, gawk |
| [`shell-novice-alpine.toml`](shell-novice-alpine.toml) | Alpine | ash + **BusyBox applets** | **bash + GNU coreutils/grep/sed/findutils** + man (mandoc) + the above |

> The lesson assumes **bash + GNU tools**. Debian has them out of the box; Alpine
> ships BusyBox, so the Alpine track installs the real bash + GNU tools to follow
> the lesson faithfully — a documented divergence, [below](#documented-divergence-busybox-vs-gnu).

## Quick start

Both bases are first-class — pick either (or run both; the labs are independent
and coexist). The flow is identical bar the name:

```bash
# ── Alpine (musl / BusyBox base) ────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/shell-novice-workshop/shell-novice-alpine.toml
examples/shell-novice-workshop/setup-workshop.sh shell-novice-alpine/shell    # ~1 min: tools + learner + data
phase5-lxd/lab-lxd.sh exec shell-novice-alpine/shell -- su - learner          # start the workshop
phase5-lxd/lab-lxd.sh down --lab shell-novice-alpine                          # tear down

# ── Debian 13 (trixie / glibc base) ─────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/shell-novice-workshop/shell-novice-debian.toml
examples/shell-novice-workshop/setup-workshop.sh shell-novice-debian/shell
phase5-lxd/lab-lxd.sh exec shell-novice-debian/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab shell-novice-debian
```

Then **open [`upstream-tutorial/aio.html`](upstream-tutorial/aio.html) in your
browser** (host side) and follow the **Linux track**, typing the commands in the
`su - learner` shell. You'll land in `/home/learner` with `shell-lesson-data/`
ready to go.

## What `setup-workshop.sh` does

Automated counterpart to the by-hand walk in [RUNBOOK.md](RUNBOOK.md); it touches
the guest **only** through `lab-lxd.sh exec` (engine-agnostic), in five steps:

1. **detect** the distro (`/etc/alpine-release` vs `/etc/debian_version`);
2. **install** bash + the standard complement of Unix tools (`apt`/`apk`);
3. **create** a non-root `learner` user with a bash login shell;
4. **unzip** the vendored `shell-lesson-data.zip` into `/home/learner` (streamed
   in over `exec` stdin — no separate file-push step);
5. **verify** as `learner` — `whoami`, `bash --version`, GNU `ls`, a `wc -l` on
   the data.

## The workshop

The lesson is the seven `shell-novice` episodes — roughly a full day at a gentle
pace ([read it in `aio.html`](upstream-tutorial/aio.html)):

1. **Introducing the Shell** — what & why; `pwd`, `whoami`
2. **Navigating Files and Directories** — `ls -F`, `cd`, paths
3. **Working With Files and Directories** — `mkdir`, `nano`, `mv`, `cp`, `rm`, wildcards
4. **Pipes and Filters** — `wc`, `sort`, `head`/`tail`, `uniq`, `cut`, `|`, `>`
5. **Loops** — `for` loops over files
6. **Shell Scripts** — save commands to a `.sh`, arguments, `bash script.sh`
7. **Finding Things** — `grep`, `find`

Everything those episodes need is installed and verified on **both** bases.

### Documented divergence: BusyBox vs GNU

A fresh Alpine container ships **BusyBox**, not the bash + GNU coreutils the
lesson assumes — `/bin/ls -> /bin/busybox`, **no `bash`**, **no `man`**, and
GNU-isms like `ls --version` error out:

```
$ ls --version
ls: unrecognized option: version
BusyBox v1.37.0 ... multi-call binary.
```

So the Alpine track installs `bash coreutils grep sed findutils gawk` (+ man via
`mandoc`/`*-doc`). After that, the lesson runs **identically** to Debian — same
`ls -F`, same `wc -l … | sort -n | head`, same `man ls`. Captured verbatim in
[MANUAL_TESTING](MANUAL_TESTING.md#documented-divergence-busybox-vs-gnu).
(Debian's base already includes them, so it needs no such fix.)

## Files

| File | Purpose |
|---|---|
| [`shell-novice-debian.toml`](shell-novice-debian.toml) / [`shell-novice-alpine.toml`](shell-novice-alpine.toml) | Phase-5 specs: one container each |
| [`setup-workshop.sh`](setup-workshop.sh) | Provision tools + `learner` user + data |
| [`RUNBOOK.md`](RUNBOOK.md) | The by-hand walk — every step, with the *why* |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Real captured transcripts (both distros) |
| [`shell-lesson-data.zip`](shell-lesson-data.zip) | Vendored workshop data ([provenance](upstream-tutorial/README.md)) |
| [`upstream-tutorial/`](upstream-tutorial/README.md) | Byte-exact `aio.html` lesson (CC-BY 4.0) + CSS |

## Scope & caveats

- **Throwaway lab.** Containers are disposable; `down` wipes them. No persistent
  state, no real credentials. Re-run the quick start for a clean slate.
- **Non-root `learner`.** The workshop is done as an ordinary user (authentic
  prompt + `whoami`); the container's root is only used by `setup-workshop.sh`.
- **System container, not a VM.** An unprivileged system container is plenty for
  a shell lesson. (For a hardware VM under the same tool, see
  [`lxd-examples/`](../lxd-examples/README.md).)
- **Read the lesson on the host, type in the container.** `aio.html` is a file
  in this repo — open it in your browser; run commands via `exec … su - learner`.

## Prerequisites

- **LXD or Incus initialised** — `incus admin init` (or `lxd init`). See the
  Phase-5 docs: [`START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- Outbound network from the container (to `apt`/`apk` the tools).

## Sources

The lesson and its data are © The Carpentries, **CC-BY 4.0**, vendored byte-exact
under [`upstream-tutorial/`](upstream-tutorial/README.md) (provenance + `sha256`).
We follow the lesson's **Linux** setup track; the container *is* the prepared
Linux environment that track asks you to create.

- Lesson (all-in-one): <https://swcarpentry.github.io/shell-novice/aio.html>
- Data zip: <https://swcarpentry.github.io/shell-novice/data/shell-lesson-data.zip>
- Lesson home: <https://swcarpentry.github.io/shell-novice/>

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog.

# RUNBOOK — build Oils by hand, step by step

This is the **by-hand walk**: every command [`setup-oils.sh`](setup-oils.sh)
runs, with the *why* at each step. Do it once by hand to understand the build;
use the script afterward. It follows the upstream docs in order — first
[INSTALL](upstream-tutorial/doc/INSTALL.html), then
[Getting Started](upstream-tutorial/doc/getting-started.html) — both vendored
under [`upstream-tutorial/`](upstream-tutorial/README.md).

Everything goes through the Phase-5 tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically. Run commands from the repo root.

## Pick a target — Debian **or** Alpine (both fully supported)

Both bases are first-class and **verified end-to-end** ([proof for each in
MANUAL_TESTING](MANUAL_TESTING.md)). They differ in exactly two places — the
image and the package manager — and are identical everywhere else:

| | Debian 13 (trixie) | Alpine |
|---|---|---|
| spec | [`oils-debian.toml`](oils-debian.toml) | [`oils-alpine.toml`](oils-alpine.toml) |
| image | `images:debian/13` (glibc) | `images:alpine/latest` (musl/BusyBox) |
| lab/service handle | `oils-debian/shell` | `oils-alpine/shell` |
| build deps | `apt-get install build-essential libreadline-dev` | `apk add build-base readline-dev` |

The walk below is written for **either** — set the handle once and the commands
read the same for both. Pick your base:

```bash
LAB=oils-debian        # Debian 13 (trixie)
# - or -
LAB=oils-alpine        # Alpine
V=0.37.0               # Oils version (used in the source paths below)
```

(If you just want it built without the narration, jump to
[Just run it](#just-run-it-either-base) — the one-liner path, shown for both.)

## 0. Prerequisites

LXD or Incus must be initialised (`incus admin init` or `lxd init`). See
[`../../phase5-lxd/START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
The container needs outbound network to fetch build deps.

## 1. Bring up the container

```bash
phase5-lxd/lab-lxd.sh up --config examples/oils-shell-container/$LAB.toml
```

This launches one unprivileged **system container** — `images:debian/13` or
`images:alpine/latest` depending on your spec — and tags it with the lab's
labels. It's a full userland (a package manager, an init, etc.), not a
single-process app container, which is exactly what you want for compiling and
poking at a shell. Confirm it's up and which base you're on:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- cat /etc/os-release
```

## 2. Install the build dependencies

Oils' [system requirements](upstream-tutorial/doc/INSTALL.html) are tiny: a
**C++11 compiler** (with libc + libstdc++), a **POSIX shell** to run the build,
and — for us — **GNU readline**. This is the one step that differs by base:

```bash
# Debian (oils-debian/shell):
phase5-lxd/lab-lxd.sh exec oils-debian/shell -- \
    sh -c 'apt-get update -qq && apt-get install -y build-essential libreadline-dev'

# Alpine (oils-alpine/shell) — NOTE the upstream INSTALL one-liner is
#     apk add libc-dev gcc readline-dev
#   DON'T use it: `gcc` ships no C++ compiler, so the build dies `c++: not found`
#   (see "Alpine deps" below). Use `build-base`, which is equally first-class:
phase5-lxd/lab-lxd.sh exec oils-alpine/shell -- \
    apk add --no-cache build-base readline-dev
```

### readline

We install readline and (in step 4) configure `--with-readline` **on purpose**.
Upstream lists readline as *optional* — without it Oils still runs, but the
interactive prompt has no history, no line editing, no completion. Since this
lab is for *experimenting at the prompt*, readline is treated as a **hard
dependency**: `--with-readline` makes `./configure` **fail** if the library is
missing, instead of silently building a worse shell. `libreadline-dev` /
`readline-dev` provide the headers + `.so` to link against.

### Alpine deps

The upstream Alpine one-liner is `apk add libc-dev gcc readline-dev`. **That
fails for Oils** — Oils is C++, and the build invokes `c++` (the g++ driver),
which the `gcc` package does *not* contain. You get `c++: not found` at the
first `.cc`. The fix is `build-base` (Alpine's build-tools meta-package: gcc,
**g++**, libc-dev, make, …) — with it, Alpine builds Oils exactly as cleanly as
Debian. The faithful failure is captured verbatim in
[MANUAL_TESTING](MANUAL_TESTING.md#alpine-deps-divergence). (Debian's
`build-essential` already includes `g++`, so its one-liner is correct as-is.)

## 3. Get the source into the container, and extract

The release tarball is vendored next to this file. Stream it in through the
phase tool — `exec` forwards stdin, so no separate file-push command is needed —
then extract exactly as INSTALL shows (`tar -x --gz`):

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- \
    sh -c "cat > /root/oils-for-unix-$V.tar.gz" \
    < examples/oils-shell-container/oils-for-unix-$V.tar.gz

phase5-lxd/lab-lxd.sh exec $LAB/shell -- \
    sh -c "cd /root && tar -x --gz < oils-for-unix-$V.tar.gz"
```

This is the **release tarball**, not a git checkout: it already ships the
generated C++ under `_gen/` and the `_build/oils.sh` build script, so you need
*no* Python, re2c, or mycpp to build it — just the C++ compiler from step 2.
(That tiny dependency surface is why both a glibc and a musl box build it the
same way.)

## 4. `./configure --with-readline`

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- \
    sh -c "cd /root/oils-for-unix-$V && ./configure --with-readline"
```

`configure` is quick — it probes the system (does readline exist? which
compiler?) and writes `_build/detected-config.sh` + headers. `--with-readline`
turns the readline probe from "nice to have" into "**fail unless available**",
which is the guarantee we want (see [readline](#readline) above). It does **not**
run `make` — Oils' build is a plain shell script, next step.

## 5. `_build/oils.sh` — compile

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- \
    sh -c "cd /root/oils-for-unix-$V && _build/oils.sh"
```

30–60 seconds. This compiles the pre-translated C++ (`cxx = c++`, `variant =
opt`) into `_bin/cxx-opt-sh/oils-for-unix` — a single statically-structured
binary with `osh`/`ysh` as symlinks, busybox-style. You can run it in place
before installing:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- \
    /root/oils-for-unix-$V/_bin/cxx-opt-sh/osh -c 'echo hi'
```

## 6. `./install`

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- \
    sh -c "cd /root/oils-for-unix-$V && ./install"
```

Installs to `/usr/local/bin/oils-for-unix` with `osh` and `ysh` symlinks, plus
the man page. (Inside a throwaway container we just install as root; INSTALL's
**non-root** variant — `./configure --prefix ~ --datarootdir ~/.local/share` →
`~/bin` — is the recipe for a real machine where you lack root.)

## 7. First run — pop into the shell you just built

OSH is a POSIX/bash-compatible shell; YSH adds structured data (JSON, typed
values). The upstream Getting-Started smoke tests:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- osh -c 'echo hi'
phase5-lxd/lab-lxd.sh exec $LAB/shell -- ysh -c 'json write ({x: 42})'
phase5-lxd/lab-lxd.sh exec $LAB/shell -- \
    sh -c "cd /root/oils-for-unix-$V && osh -n configure"   # parse-tree dump
```

Then **pop into an interactive shell** to feel readline (history, `Ctrl-R`, line
editing, tab completion) — this is the payoff:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- osh
phase5-lxd/lab-lxd.sh exec $LAB/shell -- ysh
```

For example, dropping straight into the freshly built **Alpine** OSH is just:

```bash
phase5-lxd/lab-lxd.sh exec oils-alpine/shell -- osh
```

…and the Debian one is identical bar the name (`exec oils-debian/shell -- osh`).
Confirm readline really linked in (not a no-readline fallback):

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- \
    sh -c 'ldd "$(command -v oils-for-unix)" | grep readline'
```

## 8. Teardown

```bash
phase5-lxd/lab-lxd.sh down --lab $LAB            # oils-debian or oils-alpine
```

`down` stops and deletes the container; nothing persists. To also drop the
cached base image, use `incus image delete` / `lxc image delete`.

## Just run it (either base)

Steps 2–7 are exactly what [`setup-oils.sh`](setup-oils.sh) automates. The full
path, shown concretely for **both** bases — pick whichever (or run both, they're
independent):

```bash
# ── Alpine (musl) ───────────────────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/oils-shell-container/oils-alpine.toml
examples/oils-shell-container/setup-oils.sh oils-alpine/shell      # deps + build + install
phase5-lxd/lab-lxd.sh exec oils-alpine/shell -- osh                # pop in
phase5-lxd/lab-lxd.sh down --lab oils-alpine                       # done

# ── Debian 13 (glibc) ───────────────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/oils-shell-container/oils-debian.toml
examples/oils-shell-container/setup-oils.sh oils-debian/shell
phase5-lxd/lab-lxd.sh exec oils-debian/shell -- osh
phase5-lxd/lab-lxd.sh down --lab oils-debian
```

## Gotchas

- **`c++: not found` on Alpine** → you installed `gcc`, not `build-base`. See
  [Alpine deps](#alpine-deps).
- **`./configure` fails on readline** → `--with-readline` is doing its job;
  install `libreadline-dev` / `readline-dev` first. To build *without* readline,
  use `./configure --without-readline` (you lose interactive niceties).
- **The `osh`/`ysh` REPL or `vim`/`less` looks garbled / "unknown terminal
  type"** → your client's `$TERM` (e.g. Ghostty's `xterm-ghostty`) has no
  terminfo entry inside the container. `lab-lxd.sh exec` sets `TERM=xterm` for
  interactive sessions so the shell you just built has working line editing;
  override with `LAB_TERM` (e.g. `LAB_TERM=xterm-256color`). See
  [START_HERE](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- **Image won't download / `up` hangs** → the `images:` remote can stall; it's
  not a lab bug. Pre-pull once with `incus image copy images:alpine/3.24 local:`
  (or `images:debian/13`) and retry.
- **`out-of-tree builds not supported`** → stay in the
  `oils-for-unix-0.37.0/` directory for `configure`/build/install.

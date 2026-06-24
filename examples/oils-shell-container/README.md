# oils-shell-container — build & run Oils in a system container

Give yourself a **throwaway system container** to experiment with
[**Oils for Unix**](https://oils.pub/) — the small, fast, nearly
dependency-free shell project (OSH, a POSIX/bash-compatible shell; and YSH, its
structured-data successor). The container is built and driven entirely through
the repo's **Phase-5** tool ([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which
speaks **LXD or Incus** identically — so this lab works on either.

Oils ships as a C++ source tarball with a tiny dependency surface: *a C++11
compiler, a POSIX shell to run the build, and (optionally) GNU readline*. This
lab builds it from the **vendored 0.37.0 release**
([`oils-for-unix-0.37.0.tar.gz`](oils-for-unix-0.37.0.tar.gz)) on **two distinct
base systems** so you can see the same source land on a glibc and a musl box:

| Spec | Base | libc / userland | Image | Build deps installed |
|---|---|---|---|---|
| [`oils-debian.toml`](oils-debian.toml) | Debian 13 (trixie) | glibc / GNU coreutils | `images:debian/13` | `build-essential libreadline-dev` |
| [`oils-alpine.toml`](oils-alpine.toml) | Alpine | musl / BusyBox | `images:alpine/latest` | `build-base readline-dev` |

> **readline is treated as a hard dependency here**, on purpose (the lab author
> wants the interactive UX: history, line editing, completion). Upstream lists
> readline as *optional*; we install it **and** configure with `--with-readline`,
> which makes `./configure` **fail** if readline is missing rather than quietly
> building a binary without line editing. See the [RUNBOOK](RUNBOOK.md#readline).

## Quick start

Both bases are first-class — pick either (or run both; the labs are independent
and coexist). The flow is identical bar the name:

```bash
# ── Alpine (musl / BusyBox) ─────────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/oils-shell-container/oils-alpine.toml
examples/oils-shell-container/setup-oils.sh oils-alpine/shell      # ~2 min: deps + build + install
phase5-lxd/lab-lxd.sh exec oils-alpine/shell -- osh                # pop into your fresh OSH
phase5-lxd/lab-lxd.sh down --lab oils-alpine                       # tear down

# ── Debian 13 (trixie / glibc) ──────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/oils-shell-container/oils-debian.toml
examples/oils-shell-container/setup-oils.sh oils-debian/shell
phase5-lxd/lab-lxd.sh exec oils-debian/shell -- osh
phase5-lxd/lab-lxd.sh down --lab oils-debian
```

A few things to try once you're in (either base):

```bash
phase5-lxd/lab-lxd.sh exec oils-alpine/shell -- osh -c 'echo hi from OSH'
phase5-lxd/lab-lxd.sh exec oils-alpine/shell -- ysh -c 'json write ({x: 42})'
phase5-lxd/lab-lxd.sh exec oils-alpine/shell -- ysh                # interactive — readline line editing
```

## What `setup-oils.sh` does

It is the automated counterpart to the by-hand walk in [RUNBOOK.md](RUNBOOK.md),
and it touches the guest **only** through `lab-lxd.sh exec` (no engine-specific
commands), in six steps that mirror Oils' [INSTALL](upstream-tutorial/doc/INSTALL.html):

1. **detect** the distro (`/etc/alpine-release` vs `/etc/debian_version`);
2. **install build deps** — the C++11 toolchain + GNU readline (`apt`/`apk`);
3. **push + extract** the vendored tarball into `/root` (streamed in over
   `exec` stdin — no separate file-push step needed);
4. **`./configure --with-readline`** — readline made mandatory;
5. **`_build/oils.sh`** then **`./install`** → `/usr/local/bin/{oils-for-unix,osh,ysh}`;
6. **smoke test** — `osh -c`, `ysh -c 'json write …'`, and an `ldd` check that
   `libreadline.so` is actually linked.

## Files

| File | Purpose |
|---|---|
| [`oils-debian.toml`](oils-debian.toml) / [`oils-alpine.toml`](oils-alpine.toml) | Phase-5 specs: one container each |
| [`setup-oils.sh`](setup-oils.sh) | Build + install Oils in a running container |
| [`RUNBOOK.md`](RUNBOOK.md) | The by-hand walk — every step, with the *why* |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Real captured transcripts (both distros) |
| [`oils-for-unix-0.37.0.tar.gz`](oils-for-unix-0.37.0.tar.gz) | Vendored upstream source ([provenance](upstream-tutorial/README.md)) |
| [`upstream-tutorial/`](upstream-tutorial/README.md) | Byte-exact INSTALL + Getting-Started docs |

## Scope & caveats

- **Throwaway lab.** Containers are disposable; `down`/`destroy` wipes them. No
  persistent state, no real credentials.
- **System container, not a VM.** The default is an unprivileged system
  container — enough for a shell, with negligible overhead. (For a hardware VM
  under the same tool, see [`lxd-examples/`](../lxd-examples/README.md).)
- **Built from source, not packaged.** Oils isn't in the distro repos; the point
  of the lab is to drive its own `configure`/build, exactly as a packager would.

### Documented divergence: the Alpine C++ compiler

The upstream INSTALL doc's Alpine line is:

```
apk add libc-dev gcc readline-dev
```

**This lab does not use it — it fails.** Oils is **C++**, and the build invokes
`c++` (the g++ driver), which the Alpine `gcc` package does *not* provide. With
that line, `./configure --with-readline` *passes* (readline is present) but
`_build/oils.sh` dies at the first translation unit:

```
_build/oils.sh: line 359: c++: not found        # exit 127
```

So we install **`build-base`** instead (Alpine's build-tools meta-package: gcc,
**g++**, `libc-dev`, make, …). The faithful failure and the fix are captured
verbatim in [MANUAL_TESTING](MANUAL_TESTING.md#alpine-deps-divergence), walked in
the [RUNBOOK](RUNBOOK.md#alpine-deps), and called out at the command itself in
[`setup-oils.sh`](setup-oils.sh) and [`oils-alpine.toml`](oils-alpine.toml).
(Debian's `build-essential` already bundles `g++`, so its upstream one-liner is
correct as-is.)

## Prerequisites

- **LXD or Incus initialised** — `incus admin init` (or `lxd init`). See the
  Phase-5 docs: [`START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- Outbound network from the container (to `apt`/`apk` the build deps).

## Sources

Built against the **Oils 0.37.0** release (published 2025-11-30). The two docs
this lab follows are vendored byte-exact under
[`upstream-tutorial/`](upstream-tutorial/README.md) (with provenance + `sha256`):

1. **INSTALL** — <https://oils.pub/release/0.37.0/doc/INSTALL.html> (followed first)
2. **Getting Started** — <https://oils.pub/release/0.37.0/doc/getting-started.html> (followed second)

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog.

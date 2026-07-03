# linux-proc-vfs-internals — a hands-on box for Ciro Costa's two `/proc` articles

A **throwaway system container** with a **C toolchain + `strace`**, a non-root
**`learner`** user, and a `~/proc-lab/` sandbox (the articles' two C programs +
a runnable `demo.sh`), so you can work through **Ciro S. Costa's** ops.tips pair —
**["What is /proc?"](upstream-tutorial/what-is-slash-proc.html)** and
**["How is /proc able to list process IDs?"](upstream-tutorial/how-is-proc-able-to-list-pids.html)**
— *reading `/proc`, tracing `getdents64`, and compiling the code as you read it.*
Built and driven through the repo's **Phase-5** tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically.

The two articles take procfs apart from opposite ends. **Article 1** answers
*what* `/proc` is: a **virtual filesystem** where "files" hold no bytes on disk —
the kernel **generates their content the instant you `read()`** them, via the
VFS `file_operations` interface (`open()` → `f_op->read`). **Article 2** answers
*how* one specific magic trick works — listing PIDs: `ls /proc` is really
`openat(…, O_DIRECTORY)` + a loop of **`getdents64`**, and the numeric entries
are **synthesized on the fly** by the kernel's `proc_pid_readdir()` from the
caller's **PID namespace**. The lab lets you watch both happen.

Both articles are vendored byte-exact under
[`upstream-tutorial/`](upstream-tutorial/README.md) (prose + the five diagrams) —
read them on one screen, type in the container on the other.

Two bases, both first-class and **verified end-to-end** ([proof per distro in
MANUAL_TESTING](MANUAL_TESTING.md)):

| Spec | Base / libc | What `setup-workshop.sh` installs |
|---|---|---|
| [`linux-proc-vfs-internals-debian.toml`](linux-proc-vfs-internals-debian.toml) | Debian 13 (trixie) / **glibc** | `build-essential` + `strace` + `procps` + the sandbox |
| [`linux-proc-vfs-internals-alpine.toml`](linux-proc-vfs-internals-alpine.toml) | Alpine / **musl** (BusyBox) | `build-base` + **`linux-headers`** + `strace` + the sandbox |

> `/proc` is **kernel-provided**, so its *contents* are identical on both bases —
> the interest is the **toolchain**: musl vs glibc, and Alpine needing
> `linux-headers` for the raw-`getdents64` program to compile. A documented
> divergence, [below](#debian-glibc-vs-alpine-musl-divergences).

## Quick start

Both bases are first-class — pick either (or run both; the labs are independent
and coexist). The flow is identical bar the name:

```bash
# ── Debian 13 (glibc) ───────────────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/linux-proc-vfs-internals/linux-proc-vfs-internals-debian.toml
examples/linux-proc-vfs-internals/setup-workshop.sh linux-proc-vfs-internals-debian/shell   # ~1 min
phase5-lxd/lab-lxd.sh exec linux-proc-vfs-internals-debian/shell -- su - learner             # start exploring
phase5-lxd/lab-lxd.sh down --lab linux-proc-vfs-internals-debian                             # tear down

# ── Alpine (musl / BusyBox) ─────────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/linux-proc-vfs-internals/linux-proc-vfs-internals-alpine.toml
examples/linux-proc-vfs-internals/setup-workshop.sh linux-proc-vfs-internals-alpine/shell
phase5-lxd/lab-lxd.sh exec linux-proc-vfs-internals-alpine/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab linux-proc-vfs-internals-alpine
```

`setup-workshop.sh` finishes by running `~/proc-lab/demo.sh` as the `learner`, so
you see the whole tour immediately. Then **open the articles**
([Article 1](upstream-tutorial/what-is-slash-proc.html),
[Article 2](upstream-tutorial/how-is-proc-able-to-list-pids.html)) in your viewer
and follow along, poking `/proc` and editing the C in the `su - learner` shell.

## What's in this directory

| Path | What it is |
|---|---|
| [`linux-proc-vfs-internals-debian.toml`](linux-proc-vfs-internals-debian.toml) / [`-alpine.toml`](linux-proc-vfs-internals-alpine.toml) | Phase-5 specs — one Debian 13 container, one Alpine container. |
| [`setup-workshop.sh`](setup-workshop.sh) | Provisions a launched container: toolchain + `strace` + a `learner` user + the sandbox, then runs the demo. Auto-detects the distro. |
| [`sandbox/open-fd.c`](sandbox/open-fd.c) | **Article 1's** program — `open()` a file, print the descriptor (an index into the per-process fd table `/proc/<pid>/fd` exposes). |
| [`sandbox/list-pids.c`](sandbox/list-pids.c) | **Article 2's** program — call the **raw `getdents64` syscall** on `/proc` and print every entry; the numeric ones are PIDs. |
| [`sandbox/demo.sh`](sandbox/demo.sh) | The guided tour the setup runs: reads `/proc`, `strace`s `ls`, compiles + runs both programs, and spotlights the two container gems. |
| [`RUNBOOK.md`](RUNBOOK.md) | The by-hand walk — every step `setup-workshop.sh` automates, with the **why**, mapped to the two articles. |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Verified pass transcripts on **both** bases (real captured output). |
| [`upstream-tutorial/`](upstream-tutorial/README.md) | The two articles vendored byte-exact + CSS + the five diagrams + provenance/`sha256`/attribution. |

## The gems (what to spotlight)

1. **A `/proc` file has size 0 but is full of content** — `ls -l /proc/self/status`
   shows `0` bytes (nothing on disk), yet `head /proc/self/status` prints a page
   the kernel produces *on read*. That is Article 1's thesis in two commands.
2. **A file descriptor is just an index** — `open-fd.c` prints `fd=3`, and
   `ls -l /proc/<pid>/fd` shows that same table of open files as symlinks.
3. **`ls` is `openat(O_DIRECTORY)` + `getdents64`** — `strace` proves it, and
   `list-pids.c` does the two syscalls itself with no `ls` and no libc `readdir()`.
4. **PIDs are made up per-namespace** — inside the container, `list-pids.c` and
   `ls /proc/[0-9]*` show only the **container's** PIDs (init = 1), because
   `proc_pid_readdir()` walks the caller's PID namespace.
5. **lxcfs makes the point physical** — in this container `/proc/meminfo`,
   `/proc/cpuinfo`, `/proc/uptime` (etc.) are served by **lxcfs, a FUSE
   filesystem**, so they report the container's cgroup limits rather than the
   host's. Procfs content isn't merely *computed* here — it's computed by a
   *userspace program*, the cleanest possible demonstration of "generated on read."

## Debian (glibc) vs Alpine (musl) divergences

Everything about `/proc` itself is identical (same host kernel). The divergences
are all in the **toolchain** — which is exactly the lab's second lesson:

| # | Divergence | Debian (glibc) | Alpine (musl / BusyBox) |
|---|---|---|---|
| 1 | Kernel UAPI headers for `<linux/types.h>` | ship with `libc6-dev` (via `build-essential`) | **separate `linux-headers` package** — without it `list-pids.c` fails to compile |
| 2 | Same C source, two libcs | glibc 2.41 | musl — compiles unchanged (the struct uses plain `long`/`off_t`, not glibc's `ino64_t`/`off64_t`) |
| 3 | `ls` opening the directory | GNU coreutils → **`openat(AT_FDCWD, "/tmp/ciro", …O_DIRECTORY)`** | BusyBox → the older **`open("/tmp/ciro", …O_DIRECTORY)`** — same `getdents64` after |
| 4 | Default `Max open files` (soft) in `/proc/self/limits` | `1024` | `1048576` |
| 5 | Compiler driver | `build-essential` → `gcc` + `cc` | `build-base` → `gcc` (no `cc` symlink; the demo calls `gcc`) |
| 6 | Login `/bin/sh` | `dash` | BusyBox `ash` |

## What's deliberately left out (privileged / author-run)

The articles also show pieces that need **root and/or BPF**, which an unprivileged
container can't do — these are described in [RUNBOOK.md](RUNBOOK.md) but not run:

- `echo 3 > /proc/sys/vm/drop_caches` and `mount -t proc proc /proc` — need root
  and a writable `/proc/sys` (read-only here).
- **bcc `trace.py` / `funccount`, `bpftrace`** — the kernel-stack traces that show
  `proc_pid_limits` / `proc_root_readdir` firing need `CAP_BPF`/`CAP_SYS_ADMIN`
  and matching kernel headers; run them on a real host you control.

## Verification

**Verified end-to-end, rootless Incus, no sudo, 2026-07-03**, on both bases:
`up` → `setup-workshop.sh` → `demo.sh` compiles and runs both C programs, `strace`
shows the `open`/`openat`+`getdents64` pair, and the lxcfs gem fires. Full
transcripts (Debian *and* Alpine) in [MANUAL_TESTING.md](MANUAL_TESTING.md).

## Credits

Articles © **Ciro S. Costa** — [ops.tips](https://ops.tips/). Vendored with
attribution for offline study; see [`upstream-tutorial/`](upstream-tutorial/README.md).
This lab only wraps his writing in a reproducible sandbox.

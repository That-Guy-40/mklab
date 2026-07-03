# linux-proc-vfs-internals — a hands-on box for Ciro Costa's `/proc` series

**Throwaway system containers** with a **C toolchain + `strace`**, a non-root
**`learner`** user, and a `~/proc-lab/` sandbox (the articles' C programs + a
runnable demo), so you can work through **Ciro S. Costa's** six consecutive
ops.tips `/proc` articles — *reading `/proc`, tracing syscalls, watching cgroups
bite, catching a blocked process's kernel stack, and compiling the code as you
read it.* Built and driven through the repo's **Phase-5** tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically.

The series takes procfs apart from six angles, and the lab splits into **three
container "sets"** that mirror them:

| Set | Container spec | Articles | Setup + demo |
|---|---|---|---|
| **A — the VFS box** (unlimited) | `…-debian.toml` / `…-alpine.toml` | **1** [What is /proc?](upstream-tutorial/what-is-slash-proc.html) · **2** [How is /proc able to list PIDs?](upstream-tutorial/how-is-proc-able-to-list-pids.html) | [`setup-workshop.sh`](setup-workshop.sh) → [`sandbox/demo.sh`](sandbox/demo.sh) |
| **B — the capped box** (512 MiB, swap off) | `…-debian-limited.toml` / `…-alpine-limited.toml` | **3** [Why top/free show wrong memory](upstream-tutorial/why-top-inside-container-wrong-memory.html) · **4** [Resource limits under the hood](upstream-tutorial/proc-pid-limits-under-the-hood.html) | [`setup-limits.sh`](setup-limits.sh) → [`sandbox/demo-limits.sh`](sandbox/demo-limits.sh) |
| **C — the debug box** (gdb/strace/iproute2) | `…-debian-debug.toml` / `…-alpine-debug.toml` | **5** [Getting a process' stack trace](upstream-tutorial/using-procfs-to-get-process-stack-trace.html) · **6** [How Linux creates sockets](upstream-tutorial/how-linux-creates-sockets.html) | [`setup-observe.sh`](setup-observe.sh) → [`sandbox/demo-observe.sh`](sandbox/demo-observe.sh) |

- **Article 1** — *what* `/proc` is: a **virtual filesystem** whose "files" hold
  no bytes on disk; the kernel **generates their content the instant you
  `read()`** them, via the VFS `file_operations` interface (`open()` → `f_op->read`).
- **Article 2** — *how* PID listing works: `ls /proc` is really
  `openat(…, O_DIRECTORY)` + a loop of **`getdents64`**, and the numeric entries
  are **synthesized on the fly** by `proc_pid_readdir()` from the caller's **PID
  namespace**.
- **Article 3** — why `top`/`free` in a container show the **host's** memory:
  `/proc/meminfo` reads **global** kernel counters, blind to the cgroup limit —
  unless **lxcfs** overlays it. The capped box makes this visible, and the
  allocator gets **OOM-killed** at the cap.
- **Article 4** — how `/proc/<pid>/limits` works: `ulimit`, `getrlimit(2)` and
  `setrlimit(2)` all funnel into one syscall, **`prlimit(2)`**, reading/writing
  the same `tsk->signal->rlim` the limits file prints.
- **Article 5** — what a process is *doing right now*: a server blocked in
  `accept()` reveals it via **`/proc/<pid>/wchan`** (the exact kernel function —
  `inet_csk_accept`), with `/proc/<pid>/stack` and `gdb` for the full kernel /
  userspace stacks.
- **Article 6** — how `socket(2)` works: it returns an fd that shows up as
  **`socket:[inode]`** under `/proc/<pid>/fd` and is counted in
  `/proc/<pid>/net/sockstat` (`sys_socket` → `__sock_create` → `sock_alloc`).

All six are vendored byte-exact under
[`upstream-tutorial/`](upstream-tutorial/README.md) (prose + fifteen diagrams) —
read them on one screen, type in the container on the other. Every base is
first-class and **verified end-to-end** ([proof per distro in
MANUAL_TESTING](MANUAL_TESTING.md)).

## Quick start

Pick a set and a base (or run all six; the labs are independent and coexist).

```bash
# ── Set A: the VFS box (articles 1–2) — Debian shown; swap "debian"→"alpine" for musl
phase5-lxd/lab-lxd.sh up --config examples/linux-proc-vfs-internals/linux-proc-vfs-internals-debian.toml
examples/linux-proc-vfs-internals/setup-workshop.sh linux-proc-vfs-internals-debian/shell    # ~1 min, runs demo.sh
phase5-lxd/lab-lxd.sh exec linux-proc-vfs-internals-debian/shell -- su - learner              # explore
phase5-lxd/lab-lxd.sh down --lab linux-proc-vfs-internals-debian                              # tear down

# ── Set B: the memory-capped box (articles 3–4) — note the "-limited" specs + setup-limits.sh
phase5-lxd/lab-lxd.sh up --config examples/linux-proc-vfs-internals/linux-proc-vfs-internals-debian-limited.toml
examples/linux-proc-vfs-internals/setup-limits.sh linux-proc-vfs-internals-debian-limited/shell   # runs demo-limits.sh
phase5-lxd/lab-lxd.sh exec linux-proc-vfs-internals-debian-limited/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab linux-proc-vfs-internals-debian-limited

# ── Set C: the debug box (articles 5–6) — note the "-debug" specs + setup-observe.sh
phase5-lxd/lab-lxd.sh up --config examples/linux-proc-vfs-internals/linux-proc-vfs-internals-debian-debug.toml
examples/linux-proc-vfs-internals/setup-observe.sh linux-proc-vfs-internals-debian-debug/shell    # runs demo-observe.sh
phase5-lxd/lab-lxd.sh exec linux-proc-vfs-internals-debian-debug/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab linux-proc-vfs-internals-debian-debug
```

Each setup script finishes by running its demo as the `learner`, so you see the
whole tour immediately. Then **open the articles** in your viewer and follow
along, poking `/proc` and editing the C in the `su - learner` shell.

> `/proc` is **kernel-provided**, so its *contents* are identical on both bases —
> the interest is the **toolchain** and the **container view**: musl vs glibc,
> Alpine needing `linux-headers`, `open` vs `openat`, and lxcfs re-writing
> `/proc/meminfo`. All documented [below](#debian-glibc-vs-alpine-musl-divergences).

## What's in this directory

| Path | What it is |
|---|---|
| [`…-debian.toml`](linux-proc-vfs-internals-debian.toml) / [`…-alpine.toml`](linux-proc-vfs-internals-alpine.toml) | **Set A** specs — one Debian, one Alpine container, unlimited. |
| [`…-debian-limited.toml`](linux-proc-vfs-internals-debian-limited.toml) / [`…-alpine-limited.toml`](linux-proc-vfs-internals-alpine-limited.toml) | **Set B** specs — same, but **512 MiB memory cap + swap off** (`limits.memory`). |
| [`…-debian-debug.toml`](linux-proc-vfs-internals-debian-debug.toml) / [`…-alpine-debug.toml`](linux-proc-vfs-internals-alpine-debug.toml) | **Set C** specs — provisioned with a **gdb/strace/iproute2** debug toolset. |
| [`setup-workshop.sh`](setup-workshop.sh) | Provisions a Set-A box: toolchain + `strace` + a `learner` + the VFS sandbox, then runs `demo.sh`. Auto-detects distro. |
| [`setup-limits.sh`](setup-limits.sh) | Provisions a Set-B box: toolchain + `strace` + **`procps`** (real `free`/`top`) + the cgroups/limits sandbox, then runs `demo-limits.sh`. |
| [`setup-observe.sh`](setup-observe.sh) | Provisions a Set-C box: toolchain + **`gdb`** + `strace` + `iproute2` + `procps` + the observability sandbox, then runs `demo-observe.sh`. |
| [`sandbox/open-fd.c`](sandbox/open-fd.c) | **Article 1** — `open()` a file, print the descriptor (an index into the fd table `/proc/<pid>/fd` exposes). |
| [`sandbox/list-pids.c`](sandbox/list-pids.c) | **Article 2** — call the **raw `getdents64` syscall** on `/proc`; the numeric entries are PIDs. |
| [`sandbox/mem-hog.c`](sandbox/mem-hog.c) | **Article 3** — allocate + touch memory until the cgroup **OOM-kills** it. |
| [`sandbox/limit-open-files.c`](sandbox/limit-open-files.c) | **Article 4** — use **`prlimit()`** to get-and-set another PID's `RLIMIT_NOFILE`. |
| [`sandbox/accept.c`](sandbox/accept.c) | **Article 5** — a TCP server that **blocks in `accept()`** so you can read its `wchan`/stack. |
| [`sandbox/socket.c`](sandbox/socket.c) | **Article 6** — `socket()` N times, then sleep; each fd appears as `socket:[inode]`. |
| [`sandbox/demo.sh`](sandbox/demo.sh) / [`demo-limits.sh`](sandbox/demo-limits.sh) / [`demo-observe.sh`](sandbox/demo-observe.sh) | The three guided tours the setups run (VFS/getdents; memory/rlimits; stacks/sockets). |
| [`RUNBOOK.md`](RUNBOOK.md) | The by-hand walk — every step the setups automate, with the **why**, mapped to all six articles. |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Verified pass transcripts for all three sets on **both** bases (real captured output). |
| [`upstream-tutorial/`](upstream-tutorial/README.md) | The six articles vendored byte-exact + CSS + the fifteen diagrams + provenance/`sha256`/attribution. |

## The gems (what to spotlight)

**Set A — the VFS box:**

1. **A `/proc` file has size 0 but is full of content** — `ls -l /proc/self/status`
   shows `0` bytes (nothing on disk), yet `head /proc/self/status` prints a page
   the kernel produces *on read*. Article 1's thesis in two commands.
2. **A file descriptor is just an index** — `open-fd.c` prints `fd=3`, and
   `ls -l /proc/<pid>/fd` shows that same table of open files as symlinks.
3. **`ls` is `openat(O_DIRECTORY)` + `getdents64`** — `strace` proves it, and
   `list-pids.c` does the two syscalls itself with no `ls` and no libc `readdir()`.
4. **PIDs are made up per-namespace** — inside the container, `list-pids.c` and
   `ls /proc/[0-9]*` show only the **container's** PIDs (init = 1).

**Set B — the capped box:**

5. **`free` shows the cap, not the host** — the container is limited to 512 MiB,
   and `/proc/meminfo` MemTotal reads `524288 kB` — because **lxcfs** (a FUSE fs)
   overlays it. Article 3's problem (Docker without lxcfs shows host memory) here
   appears *solved*, and you can see exactly who does it. Procfs content isn't
   merely *computed* — it's computed by a **userspace program**.
6. **The cgroup actually bites** — `mem-hog.c` climbs past 512 MiB and the kernel
   **OOM-kills it** (exit `137`); the enforcing knob is cgroup **v2**
   `/sys/fs/cgroup/memory.max`.
7. **`ulimit` is `prlimit` under the hood** — `ulimit -n` and `/proc/self/limits`
   agree, and `limit-open-files.c` changes another PID's `RLIMIT_NOFILE` live
   (visible in `/proc/<pid>/limits`); **raising the hard limit needs
   `CAP_SYS_RESOURCE`** → without it, `EPERM`.

**Set C — the debug box:**

8. **A blocked process names its kernel frame for free** — `accept.c` parks in
   the kernel, and `cat /proc/<pid>/wchan` prints **`inet_csk_accept`** — the top
   of the kernel stack, readable by any user with no ptrace. The *full*
   `/proc/<pid>/stack` needs init-namespace `CAP_SYS_ADMIN` (host-only, denied
   even to container-root — shown failing), and `gdb -p` gives the **userspace**
   stack (`main → … → accept`) with root/`CAP_SYS_PTRACE`.
9. **A socket is just an fd** — `socket.c` opens a TCP socket and `ls -l
   /proc/<pid>/fd` shows it as **`socket:[inode]`**; the 100-socket variant makes
   `/proc/<pid>/net/sockstat`'s `sockets: used` climb, and `strace` catches the
   raw **`socket(AF_INET, SOCK_STREAM, …) = 3`**.

## Debian (glibc) vs Alpine (musl) divergences

Everything about `/proc` itself is identical (same host kernel). The divergences
are all in the **toolchain** / **container view** — which is the lab's second lesson:

| # | Divergence | Debian (glibc) | Alpine (musl / BusyBox) |
|---|---|---|---|
| 1 | Kernel UAPI headers for `<linux/types.h>` | ship with `libc6-dev` (via `build-essential`) | **separate `linux-headers` package** — without it `list-pids.c` fails to compile |
| 2 | Same C source, two libcs | glibc 2.41 | musl — `list-pids.c` compiles unchanged (struct uses plain `long`/`off_t`, not glibc's `ino64_t`/`off64_t`); `prlimit()`/`mem-hog` build clean too |
| 3 | `ls`/`free` opening a file | GNU → **`openat(…, …)`** | BusyBox `ls` **and** musl's `free` → the older **`open(…)`** — same `getdents64`/read after |
| 4 | Default `Max open files` (soft) in `/proc/self/limits` | `1024` | `1048576` |
| 5 | Compiler driver | `build-essential` → `gcc` + `cc` | `build-base` → `gcc` (no `cc` symlink; the demos call `gcc`) |
| 6 | Login `/bin/sh` | `dash` | BusyBox `ash` |
| 7 | `cat` of a denied file (Set C `/proc/<pid>/stack`) | `cat: …: Permission denied` | BusyBox → `cat: read error: Permission denied` |

The kernel-provided views are **identical on both bases** (kernel + lxcfs, not
libc): 512 MiB `MemTotal`, cgroup v2 `memory.max`, `mem-hog` OOM-killed at the
cap, `wchan = inet_csk_accept`, and `socket:[inode]` fds all match.

## What's deliberately left out (privileged / author-run)

The articles also show pieces that need **root and/or BPF**, which an unprivileged
container can't do — described in [RUNBOOK.md](RUNBOOK.md) but not run:

- `echo 3 > /proc/sys/vm/drop_caches` and `mount -t proc proc /proc` — need root
  and a writable `/proc/sys` (read-only here).
- **`/proc/<pid>/stack`** (Set C) — the full kernel stack needs `CAP_SYS_ADMIN`
  **in the initial user namespace**, so it is denied even to container-root; read
  it on the host. `gdb -p` / `/proc/<pid>/syscall` need root or `CAP_SYS_PTRACE`
  in this `ptrace_scope=1` box (the demo shows the free `wchan` proxy instead),
  and **`ip netns`** (Set C, article 6) needs `CAP_NET_ADMIN`.
- **bcc `trace.py` / `funccount`, `bpftrace`** — the kernel traces that show
  `proc_pid_readdir`, **`page_counter_try_charge`** (memory charge/OOM),
  **`do_prlimit`**, or **`__sock_create`** firing need `CAP_BPF`/`CAP_SYS_ADMIN`
  and matching kernel headers; run them on a real host you control.

## Verification

**Verified end-to-end, rootless Incus, no sudo, 2026-07-03**, all six
base×set combinations. **Set A:** `demo.sh` compiles both C programs, `strace`
shows the `open`/`openat`+`getdents64` pair, the lxcfs gem fires. **Set B:**
provisions under the 512 MiB cap, `free` reads the cap, `mem-hog` is OOM-killed
(exit 137) **without taking the container down**, `limit-open-files` lowers a
PID's `RLIMIT_NOFILE` (`EPERM` on the hard-limit raise). **Set C:** the blocked
`accept.c` shows `wchan = inet_csk_accept`, `socket.c` shows `socket:[inode]` fds
+ a climbing `sockstat` + `strace` of `socket()`; the privileged `gdb -p`
backtrace and `/proc/<pid>/stack` denial are captured too. Full transcripts in
[MANUAL_TESTING.md](MANUAL_TESTING.md).

## Credits

Articles © **Ciro S. Costa** — [ops.tips](https://ops.tips/). Vendored with
attribution for offline study; see [`upstream-tutorial/`](upstream-tutorial/README.md).
This lab only wraps his writing in a reproducible sandbox.

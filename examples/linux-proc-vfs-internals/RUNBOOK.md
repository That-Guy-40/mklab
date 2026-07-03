# RUNBOOK — exploring `/proc` by hand

This walks the same build [`setup-workshop.sh`](setup-workshop.sh) automates, but
step by step with the **why** at each stop, mapped to Ciro Costa's two articles
([archived here](upstream-tutorial/README.md)). The script is the source of truth
for exact commands; this is for *understanding* and for poking one thing at a time.

Everything runs through `phase5-lxd/lab-lxd.sh`. Shorthand used below:

```bash
cd examples/linux-proc-vfs-internals
L() { ../../phase5-lxd/lab-lxd.sh "$@"; }   # L exec linux-proc-vfs-internals-debian/shell -- …
T=linux-proc-vfs-internals-debian/shell     # or -alpine/shell
```

`/proc` is provided by the **host kernel**, so it behaves the same on Debian and
Alpine — the only real forks are in the toolchain, flagged **⚠ DIVERGENCE**.

---

## Setup — the box

```bash
L up --config linux-proc-vfs-internals-debian.toml     # or the -alpine spec
```

Then install the tools. **⚠ DIVERGENCE 1** is the sharp one: Article 2's
`list-pids.c` `#include`s `<linux/types.h>` and calls the raw `getdents64`
syscall. Those kernel UAPI headers ride along with `libc6-dev` on Debian, but on
Alpine they are a **separate `linux-headers` package** — omit it and the compile
dies with *"linux/types.h: No such file or directory"*.

```bash
# Debian:
L exec $T -- sh -c 'DEBIAN_FRONTEND=noninteractive apt-get update -qq &&
                    apt-get install -y --no-install-recommends build-essential strace procps'
# Alpine:
L exec $T -- apk add --no-cache build-base linux-headers strace
```

A non-root `learner` (no bash needed — this is C + `/proc`, not shell scripting):

```bash
# Debian:  L exec $T -- useradd -m -s /bin/sh learner
# Alpine:  L exec $T -- adduser -D -s /bin/sh learner
```

Then push the sandbox (`open-fd.c`, `list-pids.c`, `demo.sh`) into
`~learner/proc-lab/` — see the `push()` helper in `setup-workshop.sh`.

---

## Article 1 — *What is /proc?* (the VFS view)

*Upstream: [what-is-slash-proc.html](upstream-tutorial/what-is-slash-proc.html) —
procfs as a virtual filesystem; `open()`→`f_op->read`; fds and `/proc/<pid>/fd`.*

### `/proc` files are virtual — generated on read

```bash
L exec $T -- su - learner -c 'ls -l /proc/self/status; head -3 /proc/self/status'
```

`ls` reports **size 0** — there is no file on disk. Yet `head` prints a full page:
the kernel runs a function (`proc_pid_status`) that formats the answer **at read
time**. Costa's point: a procfs "file" is a **method**, not bytes. Reading any
file goes `read(fd)` → VFS `vfs_read` → `file->f_op->read(...)`, and procfs just
plugs its own `f_op` implementations into that interface (see the article's
`vfs-abstraction.svg` and `procfs-file-operations.svg`).

### A file descriptor is an index into a per-process table

```bash
L exec $T -- su - learner -c 'sleep 30 </etc/hostname & p=$!; sleep 1;
                              ls -l /proc/$p/fd; kill $p'
```

`/proc/<pid>/fd` is that process's open-file table, one symlink per descriptor
(0/1/2 = stdin/stdout/stderr; the redirected `sleep` shows fd 0 → `/etc/hostname`).
Now the article's C program, which just prints the number `open()` returns:

```bash
L exec $T -- su - learner -c 'cd ~/proc-lab && : > /tmp/file.txt &&
                              gcc -Wall -o open-fd open-fd.c && ./open-fd'   # fd=3
```

> The article's in-page snippet drops the `;` after its `printf` and assumes
> `/tmp/file.txt` exists; [`open-fd.c`](sandbox/open-fd.c) fixes both so it runs.

### Per-process limits, also synthesized

```bash
L exec $T -- su - learner -c 'grep -E "Max open files|Max processes" /proc/self/limits'
```

**⚠ Author-run (needs root + BPF).** Costa traces the kernel stack of a
`cat /proc/<pid>/limits` with bcc's `trace.py` and shows it landing in
`proc_pid_limits → seq_read → vfs_read → sys_read`. That needs `CAP_BPF` and
kernel headers, so it's **not** run in this unprivileged container — do it on a
host you control. Same for `echo 3 > /proc/sys/vm/drop_caches` (root + writable
`/proc/sys`).

---

## Article 2 — *How is /proc able to list process IDs?* (the getdents view)

*Upstream: [how-is-proc-able-to-list-pids.html](upstream-tutorial/how-is-proc-able-to-list-pids.html) —
`ls` → `openat(O_DIRECTORY)` + `getdents64`; `proc_pid_readdir()` and PID namespaces.*

### Watch `ls` do it

```bash
L exec $T -- su - learner -c 'mkdir -p /tmp/ciro;
   strace -f -e trace=open,openat,getdents64 ls /tmp/ciro 2>&1 |
   grep -E "open(at)?\(.*O_DIRECTORY|getdents"'
```

Listing a directory is two syscalls: **open the dir with `O_DIRECTORY`**, then
loop **`getdents64`** until it returns 0. **⚠ DIVERGENCE 3:** GNU `ls` (Debian)
uses `openat(AT_FDCWD, "/tmp/ciro", …O_DIRECTORY)`; BusyBox `ls` (Alpine) uses the
older `open("/tmp/ciro", …O_DIRECTORY)`. Both then call the same `getdents64` —
which is why the filter matches the open by its **`O_DIRECTORY` flag**, not the
syscall name.

### Do it yourself, raw

[`list-pids.c`](sandbox/list-pids.c) skips `ls` *and* libc's `readdir()` wrapper
and calls `syscall(SYS_getdents64, …)` on `/proc` directly:

```bash
L exec $T -- su - learner -c 'cd ~/proc-lab && gcc -Wall -o list-pids list-pids.c &&
                              ./list-pids /proc | grep -E "^[0-9]+$" | sort -n | head'
```

The numeric entries are **PIDs** — they exist nowhere on disk. The kernel's
`proc_root_readdir()` first lists the static files (`meminfo`, `cpuinfo`, …) then
calls **`proc_pid_readdir()`**, which walks *the caller's PID namespace* and
`snprintf`s each tgid into a directory name (article's `ls-proc.svg` /
`getdents-under-the-hood.svg`). That namespace bit is why, **inside this
container**, you see only the container's PIDs with init as PID 1 — not the host's.

**⚠ Author-run (needs root + BPF).** Costa confirms the call path with
`funccount 'proc_*readdir'` and `bpftrace`. Same privilege story as above — run
on a real host.

---

## The container bonus — lxcfs

```bash
L exec $T -- su - learner -c 'grep lxcfs /proc/mounts | grep -E "meminfo|cpuinfo|uptime"'
```

In an Incus/LXD container, several `/proc` files are **bind-mounted from lxcfs, a
FUSE filesystem**, so they report the container's cgroup limits instead of the
host's. This is Article 1's "generated on read" thesis at its most literal: the
content is produced by a **userspace program** on each read. (Note these
FUSE-backed files advertise a real size, unlike the size-0 native procfs file
above — a handy tell for which is which.)

---

## Tear down

```bash
L down --lab linux-proc-vfs-internals-debian     # or -alpine
```

## Going further

- Read `/proc/<pid>/maps`, `/proc/<pid>/stat`, `/proc/<pid>/cmdline` and match the
  fields to `man 5 proc`.
- On a **host you control**, run the article's bcc/bpftrace one-liners to see the
  kernel stacks; compare `funccount 'proc_*'` while something reads `/proc`.
- Point `list-pids.c` at other directories (`./list-pids /etc`) and watch `d_type`.

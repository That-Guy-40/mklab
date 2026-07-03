# Manual testing — linux-proc-vfs-internals

Verified **end-to-end, rootless Incus, no sudo**, 2026-07-03, on **both** bases
(Debian 13 / glibc and Alpine / musl), for **all three container sets**: Set A
(the unlimited VFS box, articles 1–2), Set B (the 512 MiB-capped box, articles
3–4), and Set C (the gdb/strace debug box, articles 5–6). Each setup script ends
by running its demo as the `learner`; the transcripts below are that real
captured output. Host kernel: `Linux 6.8.0-134-generic`.

## Full run — Set A (VFS box, articles 1–2)

```bash
cd examples/linux-proc-vfs-internals
phase5-lxd/lab-lxd.sh up --config linux-proc-vfs-internals-debian.toml   # or -alpine
./setup-workshop.sh linux-proc-vfs-internals-debian/shell                # ~1 min; runs demo.sh
phase5-lxd/lab-lxd.sh exec linux-proc-vfs-internals-debian/shell -- su - learner
```

Toolchain the setup reported:

```text
# Debian:  gcc (Debian 14.2.0-19) 14.2.0   ·   glibc 2.41   ·   strace 6.13
# Alpine:  gcc (Alpine …)                  ·   musl          ·   strace …
```

## Debian 13 (glibc) — `demo.sh`

```text
== ARTICLE 1 — /proc is virtual: files are generated on read, not stored ==
   ls reports size 0 for a kernel-native procfs file — nothing on disk:
-r--r--r-- 1 learner learner 0 Jul  3 15:04 /proc/self/status
   ...yet it is full of content the instant the kernel produces it on read:
Name:	head
Umask:	0002
State:	R (running)

== ARTICLE 1 — a file descriptor is an index into a per-process table ==
   background pid 1134 has these open fds (0/1/2 = stdin/stdout/stderr):
lr-x------ 1 learner learner 64 Jul  3 15:04 0 -> /etc/hostname
l-wx------ 1 learner learner 64 Jul  3 15:04 1 -> pipe:[6245001]
l-wx------ 1 learner learner 64 Jul  3 15:04 2 -> pipe:[6245002]

== ARTICLE 1 — the C program (open-fd.c): open() returns the next free fd ==
fd=3

== ARTICLE 1 — per-process limits, also synthesized on read (/proc/self/limits) ==
Max processes             unlimited            unlimited            processes
Max open files            1024                 1048576              files

== ARTICLE 2 — ls /proc = openat(O_DIRECTORY) + getdents64 (see the syscalls) ==
openat(AT_FDCWD, "/tmp/ciro", O_RDONLY|O_NONBLOCK|O_CLOEXEC|O_DIRECTORY) = 3
getdents64(3, 0x602bbb202d20 /* 2 entries */, 32768) = 48
getdents64(3, 0x602bbb202d20 /* 0 entries */, 32768) = 0

== ARTICLE 2 — the C program (list-pids.c): call getdents64 on /proc ourselves ==
   numeric entries the kernel synthesized for us are PIDs:
1 132 153 158 167 180 181 190 192 1111 1115 1117 1126 1130 1156 1157 1158 1159

== GEM — those numbers ARE the live PIDs, listed straight from the /proc dir ==
1 132 153 158 167 180 181 190 192 1111 1115 1117 1126 1130 1160 1161

== GEM — in THIS container /proc/meminfo is served by lxcfs (a FUSE fs) ==
lxcfs /proc/cpuinfo fuse.lxcfs rw,nosuid,nodev,relatime,user_id=0,group_id=0,allow_other 0 0
lxcfs /proc/meminfo fuse.lxcfs rw,nosuid,nodev,relatime,user_id=0,group_id=0,allow_other 0 0
lxcfs /proc/uptime fuse.lxcfs rw,nosuid,nodev,relatime,user_id=0,group_id=0,allow_other 0 0
-r--r--r-- 1 nobody nogroup 1535 Jul  3 15:04 /proc/meminfo
```

## Alpine (musl / BusyBox) — `demo.sh`

Same tour, the differences called out below it:

```text
== ARTICLE 1 — /proc is virtual: files are generated on read, not stored ==
-r--r--r--    1 learner  learner          0 Jul  3 15:04 /proc/self/status
Name:	head
Umask:	0022
State:	R (running)

== ARTICLE 1 — the C program (open-fd.c): open() returns the next free fd ==
fd=3

== ARTICLE 1 — per-process limits, also synthesized on read (/proc/self/limits) ==
Max processes             unlimited            unlimited            processes
Max open files            1048576              1048576              files

== ARTICLE 2 — ls /proc = openat(O_DIRECTORY) + getdents64 (see the syscalls) ==
open("/tmp/ciro", O_RDONLY|O_LARGEFILE|O_CLOEXEC|O_DIRECTORY) = 3
getdents64(3, 0x78b1f2934038 /* 2 entries */, 2048) = 48
getdents64(3, 0x78b1f2934038 /* 0 entries */, 2048) = 0

== ARTICLE 2 — the C program (list-pids.c): call getdents64 on /proc ourselves ==
   numeric entries the kernel synthesized for us are PIDs:
1 286 314 417 485 599 624 625 626 627

== GEM — in THIS container /proc/meminfo is served by lxcfs (a FUSE fs) ==
lxcfs /proc/meminfo fuse.lxcfs rw,nosuid,nodev,relatime,user_id=0,group_id=0,allow_other 0 0
-r--r--r--    1 nobody   nobody        1535 Jul  3 15:04 /proc/meminfo
```

## Divergences observed (Debian glibc vs Alpine musl)

1. **`linux-headers` on Alpine.** `list-pids.c` `#include <linux/types.h>`. On
   Debian those UAPI headers come with `build-essential`; on Alpine you must
   `apk add linux-headers` or the compile fails outright. **Both then build the
   identical source** — the struct uses plain `long`/`off_t`, so no `#ifdef` is
   needed for musl.
2. **`open` vs `openat`.** GNU `ls` (Debian) opens the directory with
   `openat(AT_FDCWD, "/tmp/ciro", …O_DIRECTORY)`; BusyBox `ls` (Alpine) uses the
   older `open("/tmp/ciro", …O_DIRECTORY)`. **Both loop `getdents64` afterward** —
   the article's actual claim. (The demo greps the open by its `O_DIRECTORY`
   flag, not the syscall name, so both show up.)
3. **`Max open files` soft limit** differs by distro default: `1024` (Debian)
   vs `1048576` (Alpine) in `/proc/self/limits`.
4. **`fd=3` and the size-0 `/proc/self/status`** are identical on both — the
   kernel, not libc, produces those.

## The gems, close up

- **Virtual files.** `/proc/self/status` is `0` bytes to `ls` yet full of content
  to `cat` — the kernel formats it on read. That is the whole of Article 1 in two
  commands.
- **PID namespacing.** `list-pids.c` (raw `getdents64` on `/proc`) and
  `ls /proc/[0-9]*` agree, and both show only the **container's** PIDs with init
  as **PID 1** — because `proc_pid_readdir()` walks the caller's PID namespace.
  (The two lists differ by a few entries only because short-lived processes came
  and went between the two commands.)
- **lxcfs.** `/proc/meminfo`, `/proc/cpuinfo`, `/proc/uptime` are `fuse.lxcfs`
  mounts here, so they report the container's cgroup view. Procfs content
  produced by a *userspace* program — "generated on read" made physical. (Tell:
  these FUSE files show a real size, e.g. `1535`, unlike the size-0 native file.)

## Full run — Set B (memory-capped box, articles 3–4)

```bash
phase5-lxd/lab-lxd.sh up --config linux-proc-vfs-internals-debian-limited.toml   # 512 MiB, swap off
./setup-limits.sh linux-proc-vfs-internals-debian-limited/shell                  # runs demo-limits.sh
```

The cap applied and lxcfs reflected it before provisioning even started:

```text
$ … exec …-debian-limited/shell -- sh -c 'cat /sys/fs/cgroup/memory.max; grep MemTotal /proc/meminfo'
536870912
MemTotal:         524288 kB
```

### Debian 13 (glibc) — `demo-limits.sh`

```text
== ARTICLE 3 — free reads /proc/meminfo; in a plain container that is the HOST view ==
               total        used        free      shared  buff/cache   available
Mem:           512Mi        28Mi       386Mi       132Ki        96Mi       483Mi
Swap:             0B          0B          0B
   MemTotal straight from /proc/meminfo (lxcfs = the limit we set):
MemTotal:         524288 kB

== ARTICLE 3 — the cgroup that enforces it (modern kernels = cgroup v2 memory.max) ==
   cgroup v2:  /sys/fs/cgroup/memory.max = 536870912 bytes

== ARTICLE 3 — free really does open /proc/meminfo (strace proof) ==
openat(AT_FDCWD, "/proc/meminfo", O_RDONLY) = 3

== ARTICLE 3 — the allocator (mem-hog.c): exceed the cap → the cgroup OOM-kills it ==
   asking for far more than the limit; the cgroup page_counter stops us:
Killed
   >>> mem-hog exit status: 137  (137 = 128 + SIGKILL(9) = OOM-killed)

== ARTICLE 4 — ulimit -n and /proc/self/limits agree (both are prlimit under the hood) ==
   ulimit -n           = 1024
Max open files            1024                 1048576              files

== ARTICLE 4 — limit-open-files.c: use prlimit() to change another PID’s NOFILE ==
   target background pid = 939 — lower its open-files limit to 12/12:
before: soft=1024; hard=1048576
now:    soft=12; hard=12
   confirm through the kernel’s own view, /proc/939/limits:
Max open files            12                   12                   files

== ARTICLE 4 — raising the HARD limit needs CAP_SYS_RESOURCE (we lack it → EPERM) ==
prlimit - get and set: Operation not permitted
```

### Alpine (musl / BusyBox) — `demo-limits.sh`

Identical container view; the libc/tool differences are called out below:

```text
== ARTICLE 3 — free reads /proc/meminfo … ==
Mem:           512Mi       2.2Mi       503Mi        60Ki       5.9Mi       509Mi
MemTotal:         524288 kB
   cgroup v2:  /sys/fs/cgroup/memory.max = 536870912 bytes

== ARTICLE 3 — free really does open /proc/meminfo (strace proof) ==
open("/proc/meminfo", O_RDONLY|O_LARGEFILE) = 3        # musl free uses open(), not openat()

== ARTICLE 3 — the allocator (mem-hog.c) … ==
allocating: 100000MB
Killed
   >>> mem-hog exit status: 137  (137 = 128 + SIGKILL(9) = OOM-killed)

== ARTICLE 4 — ulimit -n … ==
   ulimit -n           = 1048576                        # Alpine default (Debian = 1024)
Max open files            1048576              1048576              files

== ARTICLE 4 — limit-open-files.c … ==
before: soft=1048576; hard=1048576
now:    soft=12; hard=12
Max open files            12                   12                   files

== ARTICLE 4 — raising the HARD limit … ==
prlimit - get and set: Operation not permitted
```

### Set B divergences observed

1. **`open` vs `openat` again** — GNU `free` (Debian) opens `/proc/meminfo` with
   `openat`; musl's `free` (Alpine) uses the older `open`. Same split as `ls` in
   Set A — it's the libc, not the tool.
2. **Default soft `NOFILE`** — Debian `1024`, Alpine `1048576` (same as Set A).
3. **Everything cgroup-side is identical** on both bases — 512 MiB `MemTotal`,
   `memory.max = 536870912`, `mem-hog` OOM-killed at `137` — because that view is
   the kernel + lxcfs, not libc.
4. **Provisioning survived the cap** and **the OOM stayed contained**: the demo
   ran straight through article 4 after `mem-hog` was killed — the cgroup OOM
   killer took only the allocator, not the container's init.
5. One **transient** `apk` DNS hiccup fetching `APKINDEX` on Alpine; a plain
   re-run of `setup-limits.sh` succeeded (a network flake, not the lab).

## Full run — Set C (debug box, articles 5–6)

```bash
phase5-lxd/lab-lxd.sh up --config linux-proc-vfs-internals-debian-debug.toml
./setup-observe.sh linux-proc-vfs-internals-debian-debug/shell                   # runs demo-observe.sh
```

### Debian 13 (glibc) — `demo-observe.sh` (as the `learner`)

```text
== ARTICLE 5 — a TCP server that BLOCKS in accept(); what is it doing? ==
listening on port 32000 (pid 1327) — now blocking in accept()
   /proc/1327/status — it is asleep:
State:	S (sleeping)

== ARTICLE 5 — /proc/<pid>/wchan: the KERNEL function it is parked in (unprivileged!) ==
   wchan = inet_csk_accept

== ARTICLE 5 — the FULL kernel stack (/proc/<pid>/stack) needs CAP_SYS_ADMIN ==
   cat /proc/1327/stack → cat: /proc/1327/stack: Permission denied

== ARTICLE 6 — socket() returns an fd that appears as socket:[inode] ==
   /proc/1338/fd (fd 3 is the socket the program made):
lrwx------ 1 learner learner 64 … 3 -> socket:[6513569]

== ARTICLE 6 — the 100-socket variant: watch /proc/<pid>/net/sockstat ==
   socket:[inode] fds held by pid 1342 (the 100 we opened):
100
   the kernel's own tally, /proc/1342/net/sockstat:
sockets: used 201

== ARTICLE 6 — strace: the socket(2) syscall itself, returning a small fd ==
socket(AF_INET, SOCK_STREAM, IPPROTO_IP) = 3
```

### Alpine (musl / BusyBox) — same, differences noted

```text
== ARTICLE 5 — wchan ==
   wchan = inet_csk_accept
== ARTICLE 5 — /proc/<pid>/stack ==
   cat /proc/554/stack → cat: read error: Permission denied    # BusyBox cat wording
== ARTICLE 6 — socket:[inode] ==
3 -> socket:[6530354]
== ARTICLE 6 — 100 sockets ==
100
sockets: used 102          # different baseline count; the +100 is what matters
== ARTICLE 6 — strace ==
socket(AF_INET, SOCK_STREAM, IPPROTO_IP) = 3
```

### The privileged view (run as **root**, for reference)

`/proc/<pid>/wchan` gives the top kernel frame unprivileged; the full stacks need
privilege. As container-root:

```text
# gdb -p <pid> -batch -ex bt   → the USERSPACE stack (works with CAP_SYS_PTRACE):
#2  accept () from /lib/x86_64-linux-gnu/libc.so.6
#3  server_accept_and_close ()
#4  main ()

# cat /proc/<pid>/stack   → the full KERNEL stack, DENIED even to container-root:
cat: /proc/<pid>/stack: Permission denied
```

That denial is the sharp lesson: `/proc/<pid>/stack` wants `CAP_SYS_ADMIN` in the
**initial** user namespace, which no rootless container has — so `wchan` (the top
frame) is the best you get inside a container, and the full kernel stack is a
host-only read.

### Set C divergences observed

1. **BusyBox `cat` wording** — a denied read prints `cat: read error: Permission
   denied` (Alpine) vs `cat: <path>: Permission denied` (Debian). The EPERM is
   identical; only the message differs.
2. **`ptrace_scope = 1`** in both containers → as the `learner`, `gdb -p` and
   `/proc/<pid>/syscall` are denied (not a descendant, no `CAP_SYS_PTRACE`); the
   demo uses the unprivileged `wchan`. `strace ./socket` works because strace
   launches the program as its **own child**.
3. **Everything kernel-provided is identical** on both bases — `wchan`,
   `socket:[inode]`, the `socket()` syscall trace.
4. One **transient** `apk` DNS hiccup fetching `APKINDEX` on Alpine again; a plain
   re-run of `setup-observe.sh` succeeded.

## Not run here (privileged / needs BPF) — by design

The articles' kernel-stack traces (bcc `trace.py` / `funccount`, `bpftrace`) and
`echo 3 > /proc/sys/vm/drop_caches` / `mount -t proc proc /proc` need root and/or
`CAP_BPF` and a writable `/proc/sys`, which an unprivileged container does not
have. They are documented in [RUNBOOK.md](RUNBOOK.md) as **run-on-a-host-you-own**,
not claimed as verified here.

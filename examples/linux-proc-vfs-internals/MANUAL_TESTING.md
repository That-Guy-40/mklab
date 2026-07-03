# Manual testing — linux-proc-vfs-internals

Verified **end-to-end, rootless Incus, no sudo**, 2026-07-03, on **both** bases
(Debian 13 / glibc and Alpine / musl). The box is built by `setup-workshop.sh`
(which ends by running `~/proc-lab/demo.sh` as the `learner`); the transcripts
below are that demo's real captured output. Host kernel: `Linux 6.8.0-134-generic`.

## Full run (either base)

```bash
cd examples/linux-proc-vfs-internals
phase5-lxd/lab-lxd.sh up --config linux-proc-vfs-internals-debian.toml   # or -alpine
./setup-workshop.sh linux-proc-vfs-internals-debian/shell                # ~1 min; runs the demo
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

## Not run here (privileged / needs BPF) — by design

The articles' kernel-stack traces (bcc `trace.py` / `funccount`, `bpftrace`) and
`echo 3 > /proc/sys/vm/drop_caches` / `mount -t proc proc /proc` need root and/or
`CAP_BPF` and a writable `/proc/sys`, which an unprivileged container does not
have. They are documented in [RUNBOOK.md](RUNBOOK.md) as **run-on-a-host-you-own**,
not claimed as verified here.

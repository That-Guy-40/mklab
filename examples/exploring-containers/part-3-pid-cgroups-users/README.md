# Part 3 — PID, cgroup & user namespaces

A faithful, by-hand reproduction of **Thomas Van Laere's
*[Exploring Containers - Part 3](upstream-tutorial/)*** — the last three primitives
that make a process into a container, walked with your own hands in a throwaway
Alpine box:

- **PID** — enter a new process tree where your shell is **PID 1** and the host's
  processes are gone (`unshare --pid --fork --mount-proc`).
- **cgroup (memory)** — cap a runaway allocator ([`alloc.c`](alloc.c)) and watch
  the kernel's **OOM killer** end it at the limit (exit 137).
- **cgroup namespace** — hide the cgroup hierarchy above you.
- **user** — become "root" inside a namespace without any real privilege
  (`--map-root-user`); the **gatekeeper** that lets an unprivileged user create all
  the other namespaces (this is why rootless containers exist).

## Quick start

```bash
# from the repo root — build the author's environment, launch it privileged:
phase4-podman/lab-podman.sh build --tag ec-part3 \
    --context examples/exploring-containers/part-3-pid-cgroups-users
podman run --rm -it --privileged ec-part3 /bin/sh
```

Then follow [`RUNBOOK.md`](RUNBOOK.md). The taste, inside the box:

```sh
unshare --pid --fork --mount-proc ash -c 'echo $$; ps -e'   # you are PID 1
unshare --user --map-root-user ash -c 'id -u; cat /proc/$$/uid_map'   # root, mapped
```

And the OOM demo (needs the cap on the `run`, so it's a fresh box):

```bash
podman run --rm --memory=50m --memory-swap=50m ec-part3 sh -c 'gcc alloc.c -o alloc; ./alloc'
# → Total 10 MB … (killed);  exit 137 = OOM
```

## What's here

| File | What it is |
|---|---|
| [`README.md`](README.md) | This file — the lesson + quick start. |
| [`RUNBOOK.md`](RUNBOOK.md) | The full by-hand walk, post-ordered, with the **why** at each step, the **v1→v2** cgroup mapping, and the rootless/rootful split. |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Verified pass/fail with **real captured output**. |
| [`Containerfile`](Containerfile) | The environment as code: **latest Alpine** + `procps` + `build-base` + `util-linux`. |
| [`alloc.c`](alloc.c) | The author's 10-MB-at-a-time memory hog, **verbatim**. |
| [`upstream-tutorial/`](upstream-tutorial/) | Byte-exact archive of the post + provenance (sha256, attribution). |

## The lesson in one paragraph

A container is a process wearing namespaces *and* wearing a cgroup. Namespaces
control what it can **see** (its own PID tree, its own hostname); cgroups control
what it can **use** (how much memory, CPU, PIDs). The **PID** namespace makes your
shell PID 1 — but only with `--mount-proc`, because `/proc` lives in the *mount*
namespace, a reminder that "a container" is always several namespaces at once. A
**memory cgroup** is a hard limit the kernel enforces with the OOM killer. A
**user** namespace is the keystone: it hands you `CAP_SYS_ADMIN` *inside* itself,
which is exactly what lets an ordinary user create all the others — the mechanism
behind rootless containers.

## Faithfulness notes & divergences

- **cgroups v1 → v2 (era-divergence, the star).** The 2018 post uses cgroup **v1**
  (`/sys/fs/cgroup/memory/…/memory.limit_in_bytes`, `tasks`). Every current distro
  boots the **v2 unified hierarchy** (this host: kernel 6.8) where those paths
  don't exist — the knob is `memory.max` in one tree, processes join via
  `cgroup.procs`, and a controller must be enabled in the parent's
  `cgroup.subtree_control` first. [`RUNBOOK.md` §2](RUNBOOK.md) carries the full
  mapping and shows both forms.
- **Rootless can't hand-write cgroupfs.** The post creates the cgroup by hand
  (`mkdir`, `echo … > memory.max`); rootless podman doesn't delegate the memory
  controller, so those writes get `Permission denied`. The **verified in-box** OOM
  instead lets the runtime set the cap (`podman run --memory`) — same OOM killer,
  privileged writer. Hand-writing the tree is the **rootful/author-run** path.
- **cgroup-namespace re-root looks muted here.** Rootless podman starts the
  container at its *delegated* cgroup root (`0::/`), so `unshare --cgroup` has
  nothing above to hide (before/after both read `0::/`). The masking is only
  visible from a deeper cgroup — create one rootful first.
- **Base bumped 3.11 → latest Alpine**, matching Part 2 (the cgroup-namespace demo
  again wants a newer `unshare`; nothing here needs 3.11 specifically). **`alloc.c`
  is verbatim.** All in-box steps verified — see [`MANUAL_TESTING.md`](MANUAL_TESTING.md).

## Provenance

Operationalises **Thomas Van Laere**, *Exploring Containers - Part 3*
(<https://thomasvanlaere.com/posts/2020/12/exploring-containers-part-3/>, 2020-12;
retrieved 2026-07-03). Byte-exact archive + sha256 + attribution in
[`upstream-tutorial/`](upstream-tutorial/). All rights remain with the author.

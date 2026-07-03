# Hand-walk: *PID, cgroup & user namespaces*, by hand, in a box

Follow Thomas Van Laere's **[*Exploring Containers - Part 3*](upstream-tutorial/)**
inside a disposable Alpine box — the final three primitives that turn a process
into a container: a **PID** namespace (its own process tree, where it is PID 1), a
**memory cgroup** (a resource limit the kernel enforces, with the OOM killer as
the teeth), a **cgroup** namespace (hide the cgroup hierarchy above you), and a
**user** namespace (be "root" without being root — the gatekeeper that makes the
others usable unprivileged).

- **The post (byte-exact archive):** [`upstream-tutorial/`](upstream-tutorial/) ·
  canonical: <https://thomasvanlaere.com/posts/2020/12/exploring-containers-part-3/>
- **The environment as code:** [`Containerfile`](Containerfile) — **latest Alpine**
  + `procps` + `build-base` + `util-linux` (same base bump as Part 2).
- **The allocator:** [`alloc.c`](alloc.c) — the author's verbatim 10-MB-at-a-time
  memory hog that the cgroup OOM-kills.

> **Two things reshape this part vs. the 2018 post, and they're the lesson, not a
> footnote:**
> 1. **cgroups v1 → v2.** The post uses cgroup **v1** paths
>    (`/sys/fs/cgroup/memory/…/memory.limit_in_bytes`). Every current distro
>    (this host: kernel 6.8) boots the **v2 unified hierarchy** — those v1 paths
>    don't exist; the knob is `memory.max` in a single unified tree. §2 shows the
>    v2 form.
> 2. **Rootless can't hand-write cgroupfs.** Rootless podman mounts
>    `/sys/fs/cgroup` so the memory controller isn't yours to write by hand
>    (`Permission denied`). But the *runtime* can set your cap for you
>    (`podman run --memory`), which triggers the exact same OOM — verified in-box.
>    Hand-writing the cgroup tree is the **rootful/author-run** path.
>
> The `# →` lines are this box's real output — see [`MANUAL_TESTING.md`](MANUAL_TESTING.md).

---

## 0. Bring up the box

```bash
# from the repo root:
phase4-podman/lab-podman.sh build --tag ec-part3 \
    --context examples/exploring-containers/part-3-pid-cgroups-users
podman run --rm -it --privileged ec-part3 /bin/sh
# for the cgroup OOM demo specifically, add a cap:  --memory=50m --memory-swap=50m
```

---

## 1. PID namespace — your own process tree, where you are PID 1

```sh
unshare --pid --fork --mount-proc ash
echo $$
# → 1                       ← inside, this shell is PID 1
ps -e -o pid,comm
# → 1 ash                   ← the tree starts here; the host's hundreds of PIDs are gone
# → 2 ps
```

**Why the two extra flags matter — the post's key quirk.**

- **`--fork`** is mandatory. `unshare --pid` alone makes a new PID namespace but
  leaves `unshare` itself in the *old* one; the first child it tries to `exec`
  becomes PID 1 of the new namespace — and if it exits, further forks fail with
  `Cannot allocate memory`. `--fork` makes `unshare` fork the shell *into* the new
  namespace as PID 1, which is what you want.
- **`--mount-proc`** remounts `/proc` for the new namespace. Without it, `/proc`
  is still the **host's** (a PID namespace doesn't touch the mount namespace), so
  `ps` would list every host process even though you're "isolated". A container
  needs *both* namespaces; this is why.

---

## 2. Memory cgroup — a limit with teeth (the OOM killer)

`alloc.c` allocates 10 MB, touches it (so pages are really backed), prints a
running total, sleeps 1 s, repeats — forever. Unbounded it would eat all RAM. A
memory cgroup caps it; crossing the cap invokes the OOM killer.

### 2a. Verified in-box — let the runtime set the cap (`podman run --memory`)

```bash
# from the repo root — a fresh box whose memory.max podman pins to 50 MiB:
podman run --rm --memory=50m --memory-swap=50m ec-part3 sh -c 'gcc alloc.c -o alloc; ./alloc'
```

```sh
cat /sys/fs/cgroup/memory.max
# → 52428800                ← 50 MiB, in the v2 unified tree, set by podman
./alloc
# → Total   10 MB
# → (killed)               ← crossing 50 MiB → OOM killer fires
# exit status 137 = 128 + 9 (SIGKILL). The container survives; only alloc dies.
```

**Why `--memory-swap=50m` too.** If swap isn't also capped, the kernel spills over
the memory limit into swap and the process limps on instead of dying — the OOM is
no longer deterministic. Equal memory and memory+swap limits = zero swap headroom.

### 2b. The author's hand-written form — rootful/author-run, and v1→v2

The post creates the cgroup by hand. In **v1** (the post):

```sh
mkdir /sys/fs/cgroup/memory/my-oom-example
echo 50m > /sys/fs/cgroup/memory/my-oom-example/memory.limit_in_bytes
echo $$  > /sys/fs/cgroup/memory/my-oom-example/tasks
./alloc                                    # → OOM at 50 MB; confirm with `dmesg`
```

The same thing in **v2** (this host's reality) — run the box **rootful**:

```sh
# sudo podman run --rm -it --privileged --cgroupns=host ec-part3 /bin/sh
mkdir /sys/fs/cgroup/my-oom-example
echo +memory > /sys/fs/cgroup/cgroup.subtree_control   # delegate the controller down
echo 52428800 > /sys/fs/cgroup/my-oom-example/memory.max
echo 0        > /sys/fs/cgroup/my-oom-example/memory.swap.max
echo $$ > /sys/fs/cgroup/my-oom-example/cgroup.procs    # v2: cgroup.procs, not "tasks"
./alloc                                                 # → OOM at ~50 MiB
```

> **⚠️ Why 2b is rootful.** In a **rootless** box, `/sys/fs/cgroup`'s memory
> controller isn't delegated to you: `echo +memory > cgroup.subtree_control` and
> writing `memory.max` both return `Permission denied` (captured in
> [`MANUAL_TESTING.md`](MANUAL_TESTING.md)). The cap in 2a works precisely because
> **podman/crun** — not you — writes `memory.max` at container creation, from the
> privileged side. Same kernel mechanism, different writer.

**v1 → v2 cheat-sheet:** `memory.limit_in_bytes` → `memory.max` · `memory.memsw.limit_in_bytes`
→ `memory.swap.max` (swap-only, not mem+swap) · `tasks`/`cgroup.procs` → `cgroup.procs`
· a controller must be enabled in the parent's `cgroup.subtree_control` before a
child cgroup can use it.

---

## 3. cgroup namespace — hide the hierarchy above you

```sh
cat /proc/self/cgroup
# → 0::/                     ← what path does this process think its cgroup is?
unshare --cgroup --mount ash -c 'cat /proc/self/cgroup'
# → 0::/
```

**What the post shows (and why it looks muted here).** In the post's Docker
context the process starts at a *deep* path like
`0::/docker/<id>/my-cgroup-example`; entering a new cgroup namespace re-roots that
view to `0::/`, hiding everything above — so a process in a container can't see the
host's cgroup layout. In **this** box the process is already at `0::/` (rootless
podman put the container at the root of its *delegated* cgroup tree), so there's
nothing above to hide and before/after both read `0::/`. The mechanism is real;
the demo is only visible when you start below the root — run the rootful
hand-written cgroup in §2b, then `unshare --cgroup` from inside it to watch the
path collapse to `/`.

---

## 4. User namespace — be "root" without being root (the gatekeeper)

```sh
id -u
# → 0                        ← we're root in the container…
unshare --user ash -c 'id -u; id -un'
# → 65534
# → nobody                   ← …but a plain user namespace maps us to nobody: no real power
```

Map our uid to 0 *inside* the new namespace instead:

```sh
unshare --user --map-root-user ash -c 'id -u; cat /proc/$$/uid_map'
# → 0
# → 0          0          1  ← "uid 0 inside = uid 0 outside, range 1": root in here only
```

And this is the **keystone**: a user namespace grants you `CAP_SYS_ADMIN` *within
it*, which is what lets an unprivileged user create the **other** namespaces. Nest
one to rename the host with no privilege at all:

```sh
unshare --user --map-root-user --uts ash
hostname thomas
hostname
# → thomas                   ← a UTS namespace change, driven entirely rootless
```

> This is why rootless containers exist at all: the user namespace is the
> permission gate. It's also the same trick Part 2 §5 used to get a **time**
> namespace with no `--privileged`.

---

## 5. Tear down & provenance

`exit` the `--rm` box and the process tree, cgroup, and namespaces all vanish.

```bash
podman rmi ec-part3          # drop the image when done
```

- **Provenance.** The archived post under [`upstream-tutorial/`](upstream-tutorial/)
  is the work of **Thomas Van Laere**; all rights remain with the author.
  [`alloc.c`](alloc.c) is his program verbatim. Prefer the [canonical
  page](https://thomasvanlaere.com/posts/2020/12/exploring-containers-part-3/).
- **Verified in this box (rootless):** the PID namespace (PID 1 + isolated tree),
  the memory-cgroup **OOM kill** (exit 137, via `podman --memory`), the cgroup
  namespace (path read), and the user namespace (nobody → mapped root → rootless
  UTS rename). The **hand-written cgroupfs** form (§2b) and the *visible* cgroup-ns
  re-rooting (§3) are the **rootful/author-run** steps. Captured output:
  [`MANUAL_TESTING.md`](MANUAL_TESTING.md).

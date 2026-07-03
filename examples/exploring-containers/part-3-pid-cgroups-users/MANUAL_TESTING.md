# Manual testing — Part 3 (PID, cgroup & user namespaces)

Real captured output, verified **2026-07-03** on kernel `6.8.0` (**cgroup v2
unified**) with **rootless podman 4.9.3**, image built from `alpine:3.23`
(util-linux 2.41.4) via `phase4-podman/lab-podman.sh build`. In-box steps ran
rootless `--privileged`; the two *rootful/author-run* steps are marked.

## Build

```console
$ phase4-podman/lab-podman.sh build --tag ec-part3 \
      --context examples/exploring-containers/part-3-pid-cgroups-users
…
Successfully tagged localhost/ec-part3:latest
```

## §1 PID namespace — PID 1 + isolated tree ✅

```console
$ podman run --rm --privileged ec-part3 sh -c '
    unshare --pid --fork --mount-proc ash -c "echo my-pid=\$\$; ps -e -o pid,comm"'
my-pid=1                     ← inside the new PID namespace, this shell is PID 1
    PID COMMAND
      1 ps                   ← isolated tree; none of the host's PIDs are visible
```

## §2 Memory cgroup — OOM kill via `podman run --memory` ✅

```console
$ podman run --rm --memory=50m --memory-swap=50m ec-part3 sh -c '
    gcc alloc.c -o alloc
    echo "container memory.max = $(cat /sys/fs/cgroup/memory.max) bytes"
    ./alloc'; echo "EXIT=$?"
container memory.max = 52428800 bytes        ← 50 MiB, v2 unified tree, set by podman
Total 	10 MB
EXIT=137                                      ← 128 + SIGKILL(9): the OOM killer fired
```

The container itself survives — only `alloc` is killed.

### §2b hand-written cgroupfs — the rootless wall ⚠️

```console
$ podman run --rm --privileged ec-part3 sh -c '
    mkdir -p /sys/fs/cgroup/x
    echo +memory > /sys/fs/cgroup/cgroup.subtree_control
    echo 52428800 > /sys/fs/cgroup/x/memory.max'
sh: can't create /sys/fs/cgroup/x/memory.max: Permission denied
```

The memory controller isn't delegated to a rootless user — writing the cgroup tree
by hand needs **rootful** podman (`sudo podman run --privileged --cgroupns=host`).
That's why §2 lets podman set the cap instead. Same kernel mechanism, different
writer.

## §3 cgroup namespace — muted at the delegated root ✅ (read)

```console
$ podman run --rm --privileged ec-part3 sh -c '
    echo before: $(cat /proc/self/cgroup)
    unshare --cgroup --mount ash -c "echo after: \$(cat /proc/self/cgroup)"'
before: 0::/
after: 0::/          ← both read 0::/: rootless podman already starts us at the delegated root,
                       so there's nothing above to hide. Re-root is visible only from a deeper
                       cgroup (create one rootful in §2b, then unshare --cgroup from inside it).
```

## §4 User namespace — nobody → mapped root → rootless UTS rename ✅

```console
$ podman run --rm --privileged ec-part3 sh -c 'unshare --user ash -c "id -u; id -un"'
65534
nobody               ← a plain user ns maps our uid to nobody: no real authority

$ podman run --rm --privileged ec-part3 sh -c '
    unshare --user --map-root-user ash -c "id -u; cat /proc/\$\$/uid_map"'
0
         0          0          1     ← uid 0 inside == uid 0 outside, range 1: root in here only

$ podman run --rm --privileged ec-part3 sh -c '
    hostname; unshare --user --map-root-user --uts ash -c "hostname thomas; hostname"'
98eebc084047         ← the container's original hostname
thomas               ← renamed inside a UTS namespace we created with NO privilege (userns gate)
```

## Summary

| Section | Result |
|---|---|
| §1 PID namespace (PID 1, isolated tree) | ✅ verified in-box (rootless) |
| §2 memory cgroup OOM (exit 137) | ✅ verified in-box (rootless, `podman --memory`) |
| §2b hand-written cgroupfs | ⚠️ rootful — `Permission denied` rootless (wall captured) |
| §3 cgroup namespace | ✅ read verified; visible re-root is rootful (v2 + delegated-root note) |
| §4 user namespace (nobody / map-root / rootless UTS) | ✅ verified in-box (rootless) |

**Era note:** the post's cgroup **v1** paths (`/sys/fs/cgroup/memory/…/memory.limit_in_bytes`,
`tasks`) do not exist on this **v2**-unified host; §2 uses the v2 equivalents
(`memory.max`, `cgroup.procs`). See [`RUNBOOK.md` §2](RUNBOOK.md) for the full
v1→v2 mapping.

# Part 2 — IPC, network & time namespaces

A faithful, by-hand reproduction of **Thomas Van Laere's
*[Exploring Containers - Part 2](upstream-tutorial/)***. Part 1 proved a chroot is
not a boundary and pointed at namespaces; here you walk three of them with your
own hands inside a throwaway Alpine box:

- **IPC** — write a message into System V shared memory, then watch it vanish when
  you read from a different IPC namespace (`processA`/`processB` + `unshare --ipc`).
- **Network** — build the container-networking primitive from scratch: **veth**
  pairs (virtual cables) + a **bridge** (virtual switch) joining two network
  namespaces, then ping across it; finally NAT out to the world.
- **Time** — give a process its own `CLOCK_BOOTTIME` offset so it reports a
  different uptime than the host (`unshare --time --boottime`).

## Quick start

```bash
# from the repo root — build the author's environment, launch it privileged:
phase4-podman/lab-podman.sh build --tag ec-part2 \
    --context examples/exploring-containers/part-2-namespaces
podman run --rm -it --privileged ec-part2 /bin/sh
```

Then follow [`RUNBOOK.md`](RUNBOOK.md). The 30-second taste, inside the box:

```sh
gcc processA.c -o processA && gcc processB.c -o processB
./processA "hi from $$"; ./processB          # host IPC ns: reads "hi from …"
./processA "hi from $$"; unshare --ipc ./processB   # new IPC ns: reads EMPTY
unshare --time --boottime 86400 uptime       # this process thinks we booted a day earlier
```

## What's here

| File | What it is |
|---|---|
| [`README.md`](README.md) | This file — the lesson + quick start. |
| [`RUNBOOK.md`](RUNBOOK.md) | The full by-hand walk, post-ordered, with the **why** at each step and the rootless/rootful split called out. |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Verified pass/fail with **real captured output**. |
| [`Containerfile`](Containerfile) | The environment as code: **latest Alpine** + `build-base` + `iproute2` + `iptables` + `util-linux`. |
| [`processA.c`](processA.c) / [`processB.c`](processB.c) | The author's System V shared-memory writer/reader, **verbatim**. |
| [`upstream-tutorial/`](upstream-tutorial/) | Byte-exact archive of the post + provenance (sha256, attribution). |

## The lesson in one paragraph

A "container" is not a kernel object — it's a process wrapped in a set of
**namespaces**, each virtualizing one class of kernel resource. Part 2 makes three
of them concrete. An **IPC** namespace scopes System V IPC, so the same `ftok` key
names a different segment inside than out. A **network** namespace is a whole
private network stack (its own `lo`, interfaces, routes, iptables); real container
networking is then just **veth** cables stitched to a **bridge** — exactly what
Docker's `docker0` does, built here by hand. A **time** namespace (Linux 5.6+)
offsets a process's monotonic/boot clocks. None of these is a wall you politely
agree to; they are separations the kernel enforces.

## Faithfulness notes & divergences

- **Base bumped from 3.11 → latest Alpine — on purpose.** Part 1 needs 3.11's
  exact musl loader name; Part 2 needs the opposite — a **newer** `unshare`
  (util-linux ≥ 2.36) for the time namespace. Alpine 3.11 ships 2.34; the author
  worked around it by pulling `util-linux=2.36` from Alpine **edge**, a trick that
  no longer resolves in 2026 (edge rotated its signing key → `UNTRUSTED signature`;
  the pinned version is gone). Using a current Alpine gets util-linux 2.41
  natively — the author's intent, reproducibly. See [`RUNBOOK.md` §5](RUNBOOK.md).
- **`ip netns` bridge form → `unshare`+`nsenter` form.** The author's persistent
  named-namespace commands (`ip netns add/exec`) remount `/sys`, which needs
  init-userns `CAP_SYS_ADMIN` that rootless podman lacks (`mount of /sys failed`).
  The RUNBOOK gives both: the author's form (run the box **rootful** to use it)
  and a **PID-named** equivalent that reaches the identical veth+bridge end state
  and **is** verified rootless in this box.
- **Outbound NAT is author-run.** The `iptables MASQUERADE` + `ping 8.8.8.8` step
  needs real root and a routable uplink; under rootless podman the container's own
  egress is a userspace shim, so it's documented, not claimed as verified.
- **`processA.c`/`processB.c` are verbatim** — including the author's harmless
  `shmat(...) == -1` pointer/int comparison (gcc warns; it runs). All in-box steps
  are verified — see [`MANUAL_TESTING.md`](MANUAL_TESTING.md).

## Provenance

Operationalises **Thomas Van Laere**, *Exploring Containers - Part 2*
(<https://thomasvanlaere.com/posts/2020/08/exploring-containers-part-2/>, 2020-08;
retrieved 2026-07-03). Byte-exact archive + sha256 + attribution in
[`upstream-tutorial/`](upstream-tutorial/). All rights remain with the author.

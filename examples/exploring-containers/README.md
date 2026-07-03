# exploring-containers — *build a container by hand, one primitive at a time*

A faithful, by-hand operationalization of **Thomas Van Laere's three-part
*Exploring Containers*** series. The through-line: **"a container" does not exist
as a single kernel object** — it is an ordinary process wrapped in a stack of
**namespaces** (what it can *see*) and **cgroups** (what it can *use*). Across the
series you assemble that stack yourself, in disposable Alpine containers, and watch
each primitive do its one job.

| Part | Primitive(s) | Directory | Base |
|---|---|---|---|
| **1** | `chroot` is *not* a boundary → escape it; then UTS/mount namespaces + `pivot_root` | [`part-1-chroot/`](part-1-chroot/) | Alpine **3.11** |
| **2** | **IPC** (SysV shm) · **network** (veth + bridge + NAT) · **time** namespaces | [`part-2-namespaces/`](part-2-namespaces/) | **latest** Alpine |
| **3** | **PID** · **cgroup** (memory OOM) · **cgroup ns** · **user** namespaces | [`part-3-pid-cgroups-users/`](part-3-pid-cgroups-users/) | **latest** Alpine |

Each part is self-contained: its own `Containerfile`, verbatim author source, a
`RUNBOOK.md` (the by-hand walk with the *why* at each step), a `MANUAL_TESTING.md`
(real captured output), and a byte-exact `upstream-tutorial/` archive with sha256
+ attribution. Start at Part 1 and go in order — the argument builds.

## Why two different Alpine bases (the interesting divergence)

Part 1 **pins Alpine 3.11**, the author's exact distro, because its chroot escape
depends on 3.11's exact musl loader name (`ld-musl-x86_64.so.1`). Parts 2 and 3
**bump to the latest Alpine** — deliberately — because they need the *opposite*: a
**newer** `unshare` (util-linux ≥ 2.36) for the **time** and **cgroup**
namespaces. Alpine 3.11 ships util-linux 2.34, which is why the *author himself*
reached out to Alpine **edge** back in 2020. That 2020 workaround is now dead
(edge rotated its signing key → `UNTRUSTED signature`; the pinned version is gone),
so the labs use a current Alpine where the tooling ships natively — the author's
intent, made reproducible. Each part's README/RUNBOOK documents this in place.

## Verified vs. author-run (honest split)

Everything runs in **rootless `--privileged` podman** and is verified end-to-end
(kernel 6.8, cgroup **v2**, podman 4.9.3) **except** a few steps that need real
(init-user-namespace) root, which rootless podman does not grant. Those are marked
in each RUNBOOK and given a **rootless-friendly equivalent** wherever one exists:

- Part 2 — the `ip netns` bridge form (needs a sysfs remount → use the verified
  `unshare`+`nsenter` form) and the outbound **NAT** rule (rootful).
- Part 3 — **hand-written cgroupfs** writes (rootless can't delegate the memory
  controller → the OOM is verified via `podman run --memory` instead) and the
  *visible* cgroup-namespace re-root.

Two genuine **era-divergences** (2018/2020 post → 2026 host) are the payoff, not
footnotes: **cgroups v1 → v2** (Part 3 §2) and the **edge util-linux trick rotting
away** (Part 2 §5).

## Relationship to `examples/chroot-breakout/`

[`part-1-chroot/`](part-1-chroot/) is a **byte-identical copy** of the standalone
[`../chroot-breakout/`](../chroot-breakout/) lab, kept here so the series reads as
a whole. The standalone lab remains in place for anyone who lands on the chroot
escape directly; both are catalogued in [`../00-INDEX.md`](../00-INDEX.md). (Two
labs sharing one source each keep their own copy — the repo's self-containment
convention.)

## Provenance

Operationalises **Thomas Van Laere**, *Exploring Containers* Parts 1–3
(<https://thomasvanlaere.com/>, 2020; retrieved 2026-06-09 / 2026-07-03). Each
part vendors its source byte-exact under `part-*/upstream-tutorial/` with a
per-file sha256 table and an all-rights-reserved attribution. All rights remain
with the author; `git rm` any archive to remove it.

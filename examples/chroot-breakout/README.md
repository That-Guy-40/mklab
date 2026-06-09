# chroot-breakout — *a chroot is not a security boundary*

A faithful, by-hand reproduction of **Thomas Van Laere's
*[Exploring Containers - Part 1](upstream-tutorial/)*** chroot escape. You build a
busybox `chroot` jail with your own hands inside a throwaway Alpine 3.11 container,
then **walk back out of it** with the author's 12-line C program — and then see the
primitives that *actually* isolate (namespaces + `pivot_root`).

This is the Phase-1 chroot concept turned inside-out: not "how to make a chroot,"
but "why a chroot was never a jail." The escape is the centerpiece; the namespaces
and `pivot_root` sections are the post's payoff.

> ⚠️ **Why this lives in a container.** `breakout.c` escapes a chroot to the *real
> root* of whatever it runs in. Inside this `--privileged` **throwaway container**
> that's the container's root — harmless, gone on `exit`. Run the same program as
> root on your **host** and it walks into your host's `/`. The container isn't
> incidental; it's the safety boundary that makes this an educational lab instead
> of an attack. Never run `breakout.c` on a machine you care about.

## Quick start

```bash
# from the repo root — build the author's environment, launch it privileged:
phase4-podman/lab-podman.sh build --tag chroot-breakout --context examples/chroot-breakout
podman run --rm -it --privileged chroot-breakout /bin/sh
```

Then follow [`RUNBOOK.md`](RUNBOOK.md) step by step. The 60-second version, inside
the box:

```sh
cat /etc/issue                                   # Welcome to Alpine Linux 3.11
mkdir /newroot && echo Hello! >> /newroot/foo.txt
chroot /newroot/ sh                              # FAILS: no shell in the jail yet
mkdir /newroot/bin && cp /bin/busybox /newroot/bin/
for a in sh ls cd cat; do ln -s busybox /newroot/bin/$a; done
mkdir /newroot/lib && cp /lib/ld-musl-x86_64.so.1 /newroot/lib/
ln -s ld-musl-x86_64.so.1 /newroot/lib/libc.musl-x86_64.so.1
cp /root/breakout.c /newroot/breakout.c          # baked into the box by the Containerfile
gcc /newroot/breakout.c -o /newroot/bin/breakout
chroot /newroot sh                               # now the jail works
# inside the jail:  ls /  ->  bin foo.txt lib   (your whole world)
#                   breakout
#                   ls /  ->  the ENTIRE container root   ← escaped
```

## What's here

| File | What it is |
|---|---|
| [`README.md`](README.md) | This file — the lesson + quick start. |
| [`RUNBOOK.md`](RUNBOOK.md) | The full by-hand walk, post-ordered, with the **why** at each line (incl. §4 *why the four escape lines work*). |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Verified pass/fail with **real captured output** — the escape proven by the before/after `ls /` contrast. |
| [`Containerfile`](Containerfile) | The author's environment as code: Alpine 3.11 + `build-base` + `util-linux`. |
| [`breakout.c`](breakout.c) | The author's escape program, **verbatim**. |
| [`upstream-tutorial/`](upstream-tutorial/) | Byte-exact archive of the post + provenance (sha256, attribution). |

## The lesson in one paragraph

`chroot()` changes what `/` means for a process — but it does **not** move the
process's current working directory, and `..` from a directory left *outside* the
new root is not clamped back to it. So `mkdir`→`chroot`→`chdir("../../../")`→
`chroot(".")` walks right out. There is one root pointer per process; re-calling
`chroot` overwrites it rather than nesting. This is documented behaviour, not a
bug: `chroot(2)`'s man page says *"This call does not change the current working
directory, so that after the call `.` can be outside the tree rooted at `/`"* and
ships the escape as a worked example (`mkdir foo; chroot foo; cd ..;`). chroot was
a 1979 convenience for build trees, not a security mechanism. Real containers reach
for **mount/UTS/PID/net namespaces** and
**`pivot_root`** (§5–§6), which give the kernel-enforced separation chroot only
pretended to. [`RUNBOOK.md` §4](RUNBOOK.md) breaks the escape down line by line.

## Faithfulness notes

- **Distro pinned to Alpine 3.11** — the post's exact base (`cat /etc/issue`
  proves it). 3.11 is EOL but its package repo is still served, so `apk add`
  resolves; the musl loader name (`ld-musl-x86_64.so.1`) and busybox layout the
  recipe depends on are 3.11's.
- **`docker run --privileged` → `podman build` + `podman run --privileged`** — the
  one structural change. The escape (§1–§4) needs only `CAP_SYS_CHROOT`; the
  namespaces/`pivot_root` half (§5–§6) needs `CAP_SYS_ADMIN`, hence `--privileged`,
  matching the post's flag. Built via the repo's Phase-4 tool rather than a bare
  `docker run` so it slots into the lab framework.
- **Every command is the post's**, in the post's order; `breakout.c` is verbatim.
  All steps are **verified in-box** — see [`MANUAL_TESTING.md`](MANUAL_TESTING.md).

## Provenance

Operationalises **Thomas Van Laere**, *Exploring Containers - Part 1*
(<https://thomasvanlaere.com/posts/2020/04/exploring-containers-part-1/>, 2020-04;
retrieved 2026-06-09). Byte-exact archive + sha256 + attribution in
[`upstream-tutorial/`](upstream-tutorial/). All rights remain with the author.

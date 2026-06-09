# Manual testing — chroot-breakout

Every step below was **run end-to-end in a privileged Alpine 3.11 container** on
this host (podman 4.9.3) and the real output captured. The escape (§B) is the
load-bearing check — it must show a *sparse jail* before and the *full container
root* after. Nothing here is "documented but unrun."

Reproduce the whole thing in one shot, or walk it by hand via
[`RUNBOOK.md`](RUNBOOK.md).

---

## A. Build the box

```bash
phase4-podman/lab-podman.sh build --tag chroot-breakout --context examples/chroot-breakout
# or directly:
podman build -t chroot-breakout examples/chroot-breakout
```

**PASS** when `apk add --no-cache build-base util-linux` resolves (Alpine 3.11's
v3.11 repo is still served despite EOL) and the image carries `gcc` + `pivot_root`.

---

## B. The escape (the centerpiece) — verified output

Launch and run the faithful sequence:

```bash
podman run --rm --privileged chroot-breakout /bin/sh
```

Captured, verbatim, from this host:

```
=== /etc/issue ===
Welcome to Alpine Linux 3.11

=== naive 'chroot /newroot/ sh' (EXPECT failure) ===
chroot: can't execute 'sh': No such file or directory
  -> failed as expected (no /bin/sh yet)

=== chroot now WORKS — view confined root ===
inside-chroot ls /:
total 12
drwxr-xr-x    2 0        0             4096 bin
-rw-r--r--    1 0        0                7 foo.txt
drwxr-xr-x    2 0        0             4096 lib
foo.txt:
Hello!

=== ESCAPE ===
confined-PID=25
confined ls /:
bin
breakout.c
foo.txt
lib

Time to break things
escaped-PID=27
escaped ls / (the full container root):
bin   dev   etc   home  lib   media mnt   newroot opt
proc  root  run   sbin  srv   sys   tmp   usr   var
```

**PASS** criteria (all observed):
1. naive `chroot` fails with `can't execute 'sh'` — *before* busybox is copied in;
2. after busybox + `ld-musl-x86_64.so.1`, the jail's `ls /` is **only** `bin
   foo.txt lib`;
3. `breakout` prints `Time to break things` and the **next** `ls /` is the entire
   container root (`dev etc proc sys usr var …`) — the escape;
4. the escaped shell is a new PID (25 → 27): `execl` replaced the process with a
   fresh `ash` rooted at the real `/` (the post saw 207 → 209 — same behaviour).

> Proof, not vibes: the contrast between the two `ls /` outputs *is* the escape.
> A run that only showed `breakout` exiting 0 would prove nothing.

---

## C. Namespaces — verified output

```
== unshare --uts (hostname isolation) ==
child hostname: thomas
parent hostname: ac460d9d5b50      # parent UNCHANGED — isolated

== mount -t proc inside a fresh dir (in --mount ns) ==  -> OK
== mount -t tmpfs (mount namespace demo) ==
Filesystem           1K-blocks   Used Available Use% Mounted on
tmpfs                    10240      0     10240   0% /mytempfs   -> OK
```

**PASS** — `unshare --uts` renames the host only inside the child; the parent's
hostname is untouched. `mount -t proc` and a private `tmpfs` both succeed in a
`--mount` namespace.

---

## D. `pivot_root` — the post's exact commands, verified output

```
pivot_root from util-linux 2.34
downloaded: 2.6M                       # wget alpine-minirootfs-3.11.6-x86_64.tar.gz
extracted /myrootfs top-level:
bin dev etc home lib media mnt opt proc root run sbin srv sys tmp usr var

after pivot_root, ls -lA / :
.oldrootfs bin dev …                   # old root parked at /.oldrootfs

after umount -l, ls /.oldrootfs (EXPECT empty):
total 0                                # the way back is GONE
```

**PASS** — the literal `wget … alpine-minirootfs-3.11.6 … / pivot_root . .oldrootfs
/ umount -l .oldrootfs` sequence runs; `/.oldrootfs` is empty afterward (matches
the post's final block exactly). The v3.11 minirootfs URL still resolves (2.6 MB).

---

## E. Sandbox / capability notes

| Step | Needs | Status here |
|---|---|---|
| chroot build + `gcc` + **escape** (§B) | `CAP_SYS_CHROOT` | ✅ verified |
| `unshare --uts` / `--mount`, `mount -t proc/tmpfs` (§C) | `CAP_SYS_ADMIN` | ✅ verified (`--privileged`) |
| `mount --bind` + `pivot_root` (§D) | `CAP_SYS_ADMIN` | ✅ verified (`--privileged`) |

No step here hits the sandbox's loop-mount/`mknod` limits — `mount --bind`,
`tmpfs`, `proc`, and `pivot_root` are all permitted under `--privileged`. So,
unusually for a tutorial-walk in this repo, **every mechanism the post introduces
is verified in-box** — nothing gated, nothing author-only.

## F. Faithful divergences (verified ≠ identical)

- **Multi-shell observational steps not reproduced.** The post opens a *second*
  shell (`docker exec … ash`) to watch the chroot'd process in `top` and to
  `nsenter --target 21 --uts` into the unshared namespace. Those are two-terminal
  *observations*, not new mechanisms — the underlying primitives (`chroot`,
  `unshare`, the `/proc/$$/ns/*` inodes) are all verified above; only the
  side-by-side viewing isn't scripted here.
- **The escape "tell" differs by runtime.** The post's post-escape `ls /` shows
  `.dockerenv` (it ran under Docker); under **podman** the equivalent marker is
  `/run/.containerenv`. Same proof — you're looking at the container's real root,
  not the jail — just a different breadcrumb.

> ⚠️ `--privileged` matters only because the escape must land somewhere
> *throwaway*. Don't run `breakout.c` as root on a host you care about — there the
> escape walks into your real `/`.

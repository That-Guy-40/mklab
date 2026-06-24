# MANUAL_TESTING — captured transcripts

Real output from building this lab end-to-end on the host (Incus, system
containers), both distros. Oils **0.37.0**, built from the vendored tarball with
GNU readline as a hard dependency. Throwaway containers; trimmed only for length
(package-manager noise), never edited.

| Step | Debian 13 (glibc) | Alpine (musl) |
|---|---|---|
| `up` container | ✅ | ✅ |
| build deps | ✅ `build-essential libreadline-dev` | ✅ `build-base readline-dev` (upstream `gcc` line fails — §below) |
| `./configure --with-readline` | ✅ | ✅ |
| `_build/oils.sh` + `./install` | ✅ | ✅ (21.5 s compile) |
| `osh -c` / `ysh json write` | ✅ | ✅ |
| readline linked (`ldd`) | ✅ `libreadline.so.8` | ✅ `libreadline.so.8` |
| interactive `history` | ✅ | ✅ |

---

## Debian 13 (trixie) — full build, green

```
$ phase5-lxd/lab-lxd.sh up --config examples/oils-shell-container/oils-debian.toml
[info] launching container 'shell' as lab-oils-debian-shell (image=images:debian/13)
[info] ── lab 'oils-debian' up (1 incus instance(s), 0 skipped) ──

$ examples/oils-shell-container/setup-oils.sh oils-debian/shell
==> [1/6] detecting distro in oils-debian/shell
    distro=debian
==> [2/6] installing build deps (C++11 toolchain + GNU readline)
  ...  g++ gcc libreadline-dev libreadline8t64 libstdc++-14-dev ...  (67 packages)
==> [3/6] pushing + extracting the release tarball into /root
==> [4/6] ./configure --with-readline   (readline is mandatory)
./configure: Wrote _build/detected-config.sh
==> [5/6] _build/oils.sh   (compile; 30-60s)
CXX _gen/bin/oils_for_unix.mycpp.cc
  ... 40 translation units ...
LINK _bin/cxx-opt-sh/oils-for-unix
    osh -> oils-for-unix
    ysh -> oils-for-unix
==> [5/6] ./install   (-> /usr/local/bin/{oils-for-unix,osh,ysh})
    Installed /usr/local/bin/oils-for-unix
    Created 'osh' symlink
    Created 'ysh' symlink
==> [6/6] smoke test
OSH says: hi
{
  "build": "ok",
  "readline": true
}
    readline linked in?
	libreadline.so.8 => /lib/x86_64-linux-gnu/libreadline.so.8 (0x000075617de2f000)
==> done.  Oils 0.37.0 is installed in oils-debian/shell.
```

Version + the INSTALL doc's `osh -n` parse-tree smoke + the readline `history`
builtin under an interactive `osh -i`:

```
$ phase5-lxd/lab-lxd.sh exec oils-debian/shell -- osh --version
Oils 0.37.0		https://oils.pub/
git commit = a9e1764bc62097e63e385a631a476c04bce534e8

$ ... -- sh -c 'cd /root/oils-for-unix-0.37.0 && osh -n configure'
(command.CommandList
  children:[
    (command.ShAssignment

$ ... printf 'echo one\necho two\nhistory\n' | osh -i
osh-0.37# two
osh-0.37#     1  echo one
    2  echo two
    3  history
```

---

## Alpine deps divergence

The upstream Alpine line installs `gcc` — but Oils is **C++**, and the build
calls `c++` (the g++ driver), which `gcc` doesn't provide. Captured failure:

```
$ phase5-lxd/lab-lxd.sh exec oils-alpine/shell -- apk add --no-cache libc-dev gcc readline-dev
(13/25) Installing gcc (15.2.0-r5)
(14/25) Installing musl-dev (1.2.6-r2)
(25/25) Installing readline-dev (8.3.3-r1)
OK: 201.3 MiB in 57 packages
APK_EXIT=0

$ ... -- sh -c 'cd /root/oils-for-unix-0.37.0 && ./configure --with-readline && _build/oils.sh'
./configure: Wrote _build/detected-config.sh          # configure is fine — readline IS present
_build/oils.sh: Building oils-for-unix: _bin/cxx-opt-sh/oils-for-unix
CXX _gen/bin/oils_for_unix.mycpp.cc
_build/oils.sh: line 359: c++: not found              # <-- the C++ compiler is missing
time: can't execute 'c++': No such file or directory
Command exited with non-zero status 127
BUILD_EXIT=127
```

Note `./configure --with-readline` **passed** — readline was installed, so the
hard-dependency check is satisfied; the failure is purely the missing C++
compiler. The fix is `build-base` (pulls `g++` + `libstdc++-dev`), which is what
`setup-oils.sh` installs.

## Alpine (musl) — full build, green

```
$ examples/oils-shell-container/setup-oils.sh oils-alpine/shell
==> [2/6] installing build deps (C++11 toolchain + GNU readline)
(3/8) Installing libstdc++-dev (15.2.0-r5)
(4/8) Installing g++ (15.2.0-r5)
(8/8) Installing build-base (0.5-r4)
==> [4/6] ./configure --with-readline   (readline is mandatory)
==> [5/6] _build/oils.sh   (compile; 30-60s)
CXX _gen/bin/oils_for_unix.mycpp.cc
  ...
_build/obj/cxx-opt-sh/_gen/bin/oils_for_unix.mycpp.o { elapsed: 21.54, max_RSS: 609484 }
LINK _bin/cxx-opt-sh/oils-for-unix
==> [5/6] ./install
    Installed /usr/local/bin/oils-for-unix
==> [6/6] smoke test
OSH says: hi
{
  "build": "ok",
  "readline": true
}
    readline linked in?
	libreadline.so.8 => /usr/lib/libreadline.so.8 (0x7725d9fde000)
==> done.  Oils 0.37.0 is installed in oils-alpine/shell.
```

Same version, parse-tree, and interactive `history` proof as Debian:

```
$ phase5-lxd/lab-lxd.sh exec oils-alpine/shell -- osh --version
Oils 0.37.0		https://oils.pub/
git commit = a9e1764bc62097e63e385a631a476c04bce534e8

$ ... printf 'echo one\necho two\nhistory\n' | osh -i
osh-0.37#     1  echo one
    2  echo two
    3  history
```

---

## Note on the `images:` remote

During this capture the `images:` (linuxcontainers) remote stalled while
fetching the Alpine image — `incus launch images:alpine/3.24` hung with no local
image and no active operation. The Debian image from the **same** remote pulled
fine minutes earlier, so this is a transient remote hiccup, **not** a lab bug.
Workaround (also in the RUNBOOK gotchas): pre-pull once, then launch reuses the
cached image by fingerprint:

```
$ incus image copy images:alpine/3.24 local: --alias oils-alpine-base
Image copied successfully!
```

The `lab-lxd.sh up` path with `images:alpine/latest` is the normal flow (proven
by the Debian run); the Alpine build steps above are identical regardless of how
the base image arrived.

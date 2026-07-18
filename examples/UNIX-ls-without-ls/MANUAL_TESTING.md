# MANUAL_TESTING — UNIX-ls-without-ls

Verification log: every command below was **actually run** on this repo's
host (2026-07-18), and the output shown is **captured, not typed from
memory**. Environments:

| | Debian container | Alpine container |
|---|---|---|
| image | `images:debian/13` → Debian **13.6** (trixie) | `images:alpine/latest` → Alpine **3.24.1** |
| bash | 5.2.37 (glibc) | 5.3.9 (musl) — *installed by setup* |
| coreutils | 9.7 | 9.11 — *installed by setup* |
| engine | Incus (via `phase5-lxd/lab-lxd.sh`) | same |

## 1. Bring-up + provision + demo (Debian)

```console
$ phase5-lxd/lab-lxd.sh up --config examples/UNIX-ls-without-ls/ls-without-ls-debian.toml
[info] launching container 'shell' as lab-ls-without-ls-debian-shell (image=images:debian/13)
[info] ── lab 'ls-without-ls-debian' up (1 incus instance(s), 0 skipped) ──

$ examples/UNIX-ls-without-ls/setup-workshop.sh ls-without-ls-debian/shell
==> [1/5] detecting distro in ls-without-ls-debian/shell
    distro=debian
==> [2/5] installing bash + GNU coreutils + tput + script
...
==> [5/5] verifying the sandbox (as learner): run demo.sh
  whoami : learner
  bash   : GNU bash, version 5.2.37(1)-release (x86_64-pc-linux-gnu)
  ls     : ls (GNU coreutils) 9.7
  stat   : stat (GNU coreutils) 9.7
  tput   : /usr/bin/tput
  --- running ~/ls-without-ls/demo.sh ---
```

**Success signature** (the demo's final lines, Debian):

```
   [ok]  ddls -la == ls -la -- perms, links, owner, sizes, dates, total line: all of it
...
----------------------------------------------------------------
PASS: all 32 checks hold (ddls == GNU ls byte-for-byte on the core;
      all 4 divergences pinned exactly; the fixed twin closes every one)
```

## 2. The same on Alpine

```console
$ phase5-lxd/lab-lxd.sh up --config examples/UNIX-ls-without-ls/ls-without-ls-alpine.toml
$ examples/UNIX-ls-without-ls/setup-workshop.sh ls-without-ls-alpine/shell
...
  whoami : learner
  bash   : GNU bash, version 5.3.9(1)-release (x86_64-alpine-linux-musl)
  ls     : ls (GNU coreutils) 9.11
  stat   : stat (GNU coreutils) 9.11
  tput   : /usr/bin/tput
  --- running ~/ls-without-ls/demo.sh ---
...
PASS: all 32 checks hold (ddls == GNU ls byte-for-byte on the core;
      all 4 divergences pinned exactly; the fixed twin closes every one)
```

Same verdict, different libc, different coreutils version — `LC_ALL=C`
doing its job.

## 3. Documented divergence: Alpine before setup (captured verbatim)

Every dependency claim in the README, demonstrated on the freshly launched
Alpine container **before** `setup-workshop.sh`:

```console
$ lab-lxd.sh exec ls-without-ls-alpine/shell -- sh -c 'command -v bash || echo "NO bash"'
NO bash

$ ... -- sh -c 'stat --printf "%F" /etc/hostname'
stat: unrecognized option: printf
BusyBox v1.37.0 (2026-01-10 15:38:28 UTC) multi-call binary.

$ ... -- sh -c 'command -v tput || echo "NO tput"'
NO tput

$ ... -- sh -c 'ls --version | head -1; readlink -f $(command -v ls)'
ls: unrecognized option: version
/bin/busybox
```

Four for four: no interpreter, no `--printf` engine, no terminal probe, and
an `ls` that is not GNU (so it cannot even be the demo's oracle — `demo.sh`
would exit 77 `SKIP:` here rather than report vacuous diffs).

## 4. The pinned divergences, seen raw (Debian, any host with GNU ls)

```console
$ head -c 1025 /dev/zero > kilo.plus
$ bash bin/ddls -lh kilo.plus | awk '{print $5}'      # verbatim: floor
1.0K
$ ls -lh kilo.plus | awk '{print $5}'                 # GNU ls: ceiling
1.1K

$ mkdir tie && touch -d '2026-01-01 10:00:00.900' tie/zzz \
            && touch -d '2026-01-01 10:00:00.100' tie/aaa
$ bash bin/ddls -t -1 tie | tr '\n' ' '               # whole seconds -> name order
aaa zzz
$ ls -t -1 tie | tr '\n' ' '                          # nanoseconds -> zzz is newer
zzz aaa
```

The `--color=never` and `-i` divergences need a tty; `demo.sh` section 4
drives them through `script(1)` — see the `[ok] REGRESSION:` lines in the
transcripts above.

## 5. Notes for reproducers (a.k.a. things that bit the author)

- **The `-i` drop count is geometry-dependent.** The verbatim bug shows
  `num_rows` of 12 entries, and `num_rows` depends on the pty width the
  harness gets (host run showed 2, container run showed 1). The demo asserts
  the *invariant* (fewer than 12, no error), not a magic number.
- **Fixture mtimes are relative** (`N days ago`, `400 days ago`) so the
  six-month `-l` format boundary can never drift into the fixture as
  calendar time passes.
- **The demo's oracle diffs run with stdout NOT a tty** (one-per-line, no
  color) — that is what makes them byte-deterministic. The tty-only behavior
  is quarantined in section 4 behind `script(1)`.

## 6. Teardown

```console
$ phase5-lxd/lab-lxd.sh down --lab ls-without-ls-debian
$ phase5-lxd/lab-lxd.sh down --lab ls-without-ls-alpine
```

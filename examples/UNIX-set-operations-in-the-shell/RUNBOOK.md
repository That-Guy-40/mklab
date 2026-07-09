# RUNBOOK — prepare the set-operations box by hand, step by step

This is the **by-hand walk**: every command [`setup-workshop.sh`](setup-workshop.sh)
runs, with the *why* at each step. Do it once by hand to understand what a
set-operations sandbox needs; use the script afterward. It prepares a
`comm`/`uniq`/`awk` + `sqlite3` playground for **Peteris Krumins'**
[*"Set Operations in the Unix Shell"*](upstream-tutorial/catonmat/set-operations-in-unix-shell/index.html)
(plus its [cheat sheet](upstream-tutorial/catonmat/set-operations-in-unix-shell-simplified/index.html)
and the [Google Treasure Hunt puzzle](upstream-tutorial/catonmat/solving-google-treasure-hunt-prime-number-problem-four/index.html)
that inspired it) and **Thomas Guest's**
[*"He Sells Shell Scripts to Intersect Sets"*](upstream-tutorial/accu/journals/overload/15/80/guest_1410/index.html).

Part 2 of the series that starts with
[relational algebra](../UNIX-relational-algebra-sql-in-the-shell/README.md).

Everything goes through the Phase-5 tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically. Run commands from the repo root.

## Pick a base — Debian **or** Alpine (both fully supported)

Both are first-class and **verified end-to-end** ([proof for each in
MANUAL_TESTING](MANUAL_TESTING.md)). They lack **different** pieces of what the
articles assume (see [what each base lacks](#what-each-base-lacks)):

| | Debian 13 (trixie) | Alpine |
|---|---|---|
| spec | [`set-operations-debian.toml`](set-operations-debian.toml) | [`set-operations-alpine.toml`](set-operations-alpine.toml) |
| image | `images:debian/13` (glibc, GNU userland) | `images:alpine/latest` (musl, BusyBox userland) |
| lab/service handle | `set-operations-debian/shell` | `set-operations-alpine/shell` |
| installer | `apt-get` | `apk` |
| `bash` | present | **absent** |
| `join` | present (coreutils) | **absent** (no BusyBox applet) |
| `perl`, `sqlite3` | perl only | neither |
| default `awk` | **mawk** | BusyBox awk |

Pick your base — the rest of the walk reads the same for both:

```bash
LAB=set-operations-debian        # Debian 13 (trixie)
# - or -
LAB=set-operations-alpine        # Alpine
```

(Just want it ready without the narration? Jump to
[Just run it](#just-run-it-either-base).)

## 0. Prerequisites

LXD or Incus must be initialised (`incus admin init` or `lxd init`). See
[`../../phase5-lxd/START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
The container needs outbound network to fetch the tools.

## 1. Bring up the container

```bash
phase5-lxd/lab-lxd.sh up --config examples/UNIX-set-operations-in-the-shell/$LAB.toml
```

One unprivileged **system container** — a full userland with a package manager and
an init.

## 2. Install bash, GNU coreutils, gawk, perl, sqlite3, busybox

Each has a specific job:

- **bash** — every `comm` recipe in both articles is spelled
  `comm -12 <(sort A) <(sort B)`. Process substitution is bash, not POSIX `sh`.
- **GNU coreutils** — `comm`, `uniq`, `sort`, **`join`** (BusyBox has no `join`
  applet at all), and **`factor`**, which will generate the primes that
  `treasure-hunt.sh` needs.
- **gawk** — the cheat sheet's `awk` implementation of every operation. Debian's
  default `awk` is **mawk**; Alpine's is BusyBox awk.
- **perl** — Krumins' power-set one-liner.
- **sqlite3** — the **set oracle**. Its `UNION`, `INTERSECT` and `EXCEPT` *are* the
  set operators; its job is to be an independent implementation that is allowed to
  disagree with your pipeline.
- **busybox** — so that *both* bases can show what BusyBox `sort` and `grep` do
  differently. On Alpine it is the base system; on Debian it is one small package.

```bash
# Debian — has bash, coreutils, perl; needs gawk + sqlite3 + busybox:
phase5-lxd/lab-lxd.sh exec set-operations-debian/shell -- \
    sh -c 'export DEBIAN_FRONTEND=noninteractive
           apt-get update -qq && apt-get install -y --no-install-recommends \
               bash coreutils gawk perl sqlite3 diffutils busybox less'

# Alpine — has none of bash / join / perl / sqlite3:
phase5-lxd/lab-lxd.sh exec set-operations-alpine/shell -- \
    apk add --no-cache bash coreutils gawk perl sqlite grep sed diffutils less shadow
```

Then make `awk` mean **gawk** on both. `/usr/local/bin` is first in `PATH`:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- \
    sh -c 'ln -sf "$(command -v gawk)" /usr/local/bin/awk'
```

### What each base lacks

Prove it to yourself on a fresh container, *before* installing anything:

```bash
# Alpine: no bash, no join.
phase5-lxd/lab-lxd.sh exec set-operations-alpine/shell -- \
    sh -c 'command -v bash join || echo MISSING'
phase5-lxd/lab-lxd.sh exec set-operations-alpine/shell -- \
    sh -c 'busybox --list | grep -x join || echo "busybox has no join applet"'
```

And the surprise that runs the other way — Debian's `/bin/sh` is **dash**, which
has no process substitution, so it cannot even *parse* the articles' `comm`
recipes; Alpine's BusyBox **ash can**:

```bash
phase5-lxd/lab-lxd.sh exec set-operations-debian/shell -- /bin/sh -c 'comm -12 <(echo a) <(echo a)'
#   /bin/sh: 1: Syntax error: "(" unexpected
phase5-lxd/lab-lxd.sh exec set-operations-alpine/shell -- /bin/sh -c 'comm -12 <(echo a) <(echo a)'
#   a
```

Everyone "knows" Alpine's shell is the impoverished one. Check, don't assume.
Full capture in
[MANUAL_TESTING](MANUAL_TESTING.md#documented-divergence-neither-base-ships-what-the-articles-assume).

## 3. Create the non-root `learner` user — with a **bash** login

```bash
# Debian:
phase5-lxd/lab-lxd.sh exec set-operations-debian/shell -- \
    sh -c 'id learner >/dev/null 2>&1 || useradd -m -s /bin/bash learner'

# Alpine (adduser, not useradd):
phase5-lxd/lab-lxd.sh exec set-operations-alpine/shell -- \
    sh -c 'id learner >/dev/null 2>&1 || adduser -D -s /bin/bash learner'
```

## 4. Install the sandbox

Push the recipes, their corrected twins, both authors' data, and the two scripts.
Use the wrapper's **stdin** — cleaner than escaping the awk programs and regexes
these files are full of:

```bash
SBX=/home/learner/set-operations
phase5-lxd/lab-lxd.sh exec $LAB/shell -- sh -c "mkdir -p $SBX/bin/fixed $SBX/data"

# The recipes as published, and their corrected twins.
for f in setops powerset powerset.pl; do
    phase5-lxd/lab-lxd.sh exec $LAB/shell -- sh -c "cat > $SBX/bin/$f" \
        < examples/UNIX-set-operations-in-the-shell/bin/$f
    phase5-lxd/lab-lxd.sh exec $LAB/shell -- sh -c "cat > $SBX/bin/fixed/$f" \
        < examples/UNIX-set-operations-in-the-shell/bin/fixed/$f
done

# Krumins' sets, the collation landmine (P, Q), and Guest's Apache logs.
for f in A B Asub Anotsub Aequal Bequal P Q access_log1 access_log2; do
    phase5-lxd/lab-lxd.sh exec $LAB/shell -- sh -c "cat > $SBX/data/$f" \
        < examples/UNIX-set-operations-in-the-shell/sample-data/$f
done

for s in demo.sh treasure-hunt.sh; do
    phase5-lxd/lab-lxd.sh exec $LAB/shell -- sh -c "cat > $SBX/$s" \
        < examples/UNIX-set-operations-in-the-shell/$s
done
phase5-lxd/lab-lxd.sh exec $LAB/shell -- \
    sh -c "chmod +x $SBX/*.sh $SBX/bin/powerset* $SBX/bin/fixed/powerset*; chown -R learner $SBX"
```

`bin/setops` is a **library, not a program** — Guest explicitly suggests storing
these one-liners as sourceable shell functions. Use it that way:

```bash
. bin/setops
set_intersect data/A data/B
```

The data: Krumins' hand-crafted `A` and `B` (he chose them so `1, 2, 3` are the
only elements in common), the subset/equality fixtures, **`P = {1,9,10}` and
`Q = {10}`** — the pair that exposes the `comm` collation bug — and two synthetic
Apache logs for Guest's real problem.

## 5. Verify, then start intersecting

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- su - learner -c \
    'bash ~/set-operations/demo.sh && bash ~/set-operations/treasure-hunt.sh'
```

`demo.sh` walks all fourteen operations, computing each with two or more
*independent* algorithms, and ends on a single verdict line:

```
PASS: all 28 set identities hold (merge == count == hash == SQL)
```

`treasure-hunt.sh` then reproduces Google Treasure Hunt 2008 puzzle 4:

```
PASS: puzzle 4 answer is 7830239 (prime, and a sum of 7, 17, 41 and 541 consecutive primes);
      his sort -nm|uniq -d pipeline finds it, his article's comm+sort -n recipe does not
```

Now drop into the learner's shell and work through the articles:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- su - learner
```

## 6. Teardown

```bash
phase5-lxd/lab-lxd.sh down --lab $LAB        # set-operations-debian or -alpine
```

## Just run it (either base)

```bash
# ── Debian 13 (glibc) ───────────────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-set-operations-in-the-shell/set-operations-debian.toml
examples/UNIX-set-operations-in-the-shell/setup-workshop.sh set-operations-debian/shell
phase5-lxd/lab-lxd.sh exec set-operations-debian/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab set-operations-debian

# ── Alpine (musl / BusyBox) ─────────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-set-operations-in-the-shell/set-operations-alpine.toml
examples/UNIX-set-operations-in-the-shell/setup-workshop.sh set-operations-alpine/shell
phase5-lxd/lab-lxd.sh exec set-operations-alpine/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab set-operations-alpine
```

## The three algorithm families

Everything in both articles is one of three shapes. Knowing which you are holding
tells you what can go wrong:

| Family | Recipe | Cost | Requires | Fails when… |
|---|---|---|---|---|
| **Merge** | `comm`, `join`, `sort -m` | O(n + m), O(1) memory | inputs sorted **the way the tool compares** | your sort order ≠ the tool's compare order. **Silently.** |
| **Count** | `sort \| uniq -d`, `uniq -u`, `uniq -c` | O(n log n) | equal lines merely **adjacent** | your filter matches too much (`grep "^ *2"` matches `20`) |
| **Hash** | `awk` arrays, `grep -xF -f` | O(n + m) time, O(m) memory | nothing | the smaller side doesn't fit in memory |

The count family is **immune** to the collation trap, because `uniq` only needs
adjacency, and any consistent order gives that. That is exactly why Krumins' own
puzzle pipeline (`sort -nm … | uniq -d`) was right while his article's `comm`
recipe was wrong.

## The exercises

1. **Find a set where `comm -12 <(sort -n A) <(sort -n B)` gives a *wrong non-empty*
   answer**, not just an empty one. (Hint: you need elements that interleave
   differently under the two orders.)
2. **Krumins asks:** "Can you think of a way to do the power set with Unix tools?"
   His own answers are a recursive bash function and a perl one-liner. Try
   `printf` + `seq` over the bit patterns `0 … 2^n-1` — one subset per pattern.
3. **Guest asks** you to identify eight set operations from a bare command history
   (near the end of his article). Do it before reading his answer key.
4. **Rewrite the treasure hunt** using `join` instead of `uniq -d`. Watch it fail,
   then make it work. `join` has the same byte-wise merge assumption as `comm`.

## Gotchas

- **`comm` or `join` silently returns too few rows** → you sorted numerically
  (`sort -n`) and they merge **byte-wise**. Sort lexicographically for `comm`/`join`
  and apply `sort -n` to the *output*. Pin the collation with `export LC_ALL=C` so
  glibc and musl agree. This is the lab's central lesson.
- **`comm: file 1 is not in sorted order`** on stderr → the warning for the above.
  It is a warning, not an error: exit status stays 0 and the answer is just wrong.
  In a pipeline you will never see it.
- **A recipe hangs forever** → you typed `>(...)` where you meant `<(...)`.
  `>(...)` is an *output* process substitution; `comm` waits to read from a
  write-only pipe.
- **`set -um set1 set2` printed nothing** → that is bash's `set` builtin, not
  `sort -um`. It just turned on `nounset` in your shell.
- **`awk: syntax error` near `if !(`** → `awk` requires `if (!(...))`. The cheat
  sheet's subset test has this bug.
- **`sort -t. +0n -1n` works for you but not for a colleague** → obsolete POSIX
  key syntax. GNU `sort` still accepts it; **BusyBox `sort` rejects it**. Write
  `sort -t. -k1,1n -k2,2n -k3,3n -k4,4n`, or `sort -V`.
- **`grep "^ *2"` matched an element seen 20 times** → the pattern is unanchored
  on the right. Use `awk '$1 == 2'`.
- **`awk: function gensub never defined`** → that's mawk (Debian's default `awk`),
  not gawk. The `awk` → `gawk` symlink from step 2 fixes it.
- **The power set never finishes** → `|P(A)| = 2^|A|`. Thirty elements is a billion
  subsets. That is not a bug.
- **`#!/bin/bash` script says `not found` and the file clearly exists** → the
  *interpreter* is missing. You are on bare Alpine.
- **Image won't download / `up` hangs** → the `images:` remote can stall; it's not
  a lab bug. Pre-pull with `incus image copy images:alpine/3.24 local:` and retry.

# RUNBOOK — prepare the relational-shell box by hand, step by step

This is the **by-hand walk**: every command [`setup-workshop.sh`](setup-workshop.sh)
runs, with the *why* at each step. Do it once by hand to understand what a
relational-algebra sandbox needs; use the script afterward. It prepares a
`join`/`comm`/`cut`/`awk` + `sqlite3` playground for **Matt Might's**
[*"Relational shell programming"*](upstream-tutorial/matt-might/articles/sql-in-the-shell/index.html)
and **Jason Walsh's**
[*"SQL in the Shell"*](upstream-tutorial/wal-sh/research/relational-algebra/index.html)
— a sibling to the other Matt-Might labs
([survival guide](../UNIX_novice_survival_guide/README.md),
[bash by example](../shell-intermediate-programming-by-example/README.md),
[sculpting text](../UNIX-sculpting-text-regex-grep-sed-awk/README.md),
[Hello, Perceptron](../AI-build-a-perceptron/README.md)).

Everything goes through the Phase-5 tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically. Run commands from the repo root.

## Pick a base — Debian **or** Alpine (both fully supported)

Both bases are first-class and **verified end-to-end** ([proof for each in
MANUAL_TESTING](MANUAL_TESTING.md)). They are missing **different** pieces of what
the articles assume (see [what each base lacks](#what-each-base-lacks)):

| | Debian 13 (trixie) | Alpine |
|---|---|---|
| spec | [`relational-algebra-debian.toml`](relational-algebra-debian.toml) | [`relational-algebra-alpine.toml`](relational-algebra-alpine.toml) |
| image | `images:debian/13` (glibc, GNU userland) | `images:alpine/latest` (musl, BusyBox userland) |
| lab/service handle | `relational-algebra-debian/shell` | `relational-algebra-alpine/shell` |
| installer | `apt-get` | `apk` |
| `bash` | present | **absent** |
| `join` | present (coreutils) | **absent** (no BusyBox applet) |
| default `awk` | **mawk** | BusyBox awk |
| `sqlite3` | absent | absent |

Pick your base — the rest of the walk reads the same for both:

```bash
LAB=relational-algebra-debian        # Debian 13 (trixie)
# - or -
LAB=relational-algebra-alpine        # Alpine
```

(Just want it ready without the narration? Jump to
[Just run it](#just-run-it-either-base).)

## 0. Prerequisites

LXD or Incus must be initialised (`incus admin init` or `lxd init`). See
[`../../phase5-lxd/START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
The container needs outbound network to fetch the tools.

## 1. Bring up the container

```bash
phase5-lxd/lab-lxd.sh up --config examples/UNIX-relational-algebra-sql-in-the-shell/$LAB.toml
```

One unprivileged **system container** — a full userland with a package manager and
an init — which is what we want: we install tools and add a user, like setting up
a real Linux box to learn on.

## 2. Install bash, GNU coreutils, gawk, and sqlite3

Four requirements, each for a concrete reason:

- **bash** — Might's four scripts carry a `#!/bin/bash` shebang, and the modern
  one-liners lean on `<(sort A)` process substitution and `$'\t'`.
- **GNU coreutils** — for **`join`** and `comm`. This is not cosmetic on Alpine:
  **BusyBox has no `join` applet at all.**
- **gawk** — Debian's default `awk` is **mawk**; Alpine's is BusyBox awk.
- **sqlite3** — the **SQL oracle**. Neither base ships it. Its whole job is to be
  an independent implementation that is *allowed to disagree* with your pipeline.

```bash
# Debian — has bash, GNU coreutils and GNU grep/sed already; needs gawk + sqlite3:
phase5-lxd/lab-lxd.sh exec relational-algebra-debian/shell -- \
    sh -c 'export DEBIAN_FRONTEND=noninteractive
           apt-get update -qq && apt-get install -y --no-install-recommends \
               bash coreutils gawk sqlite3 diffutils less'

# Alpine — has none of bash / join / sqlite3; BusyBox applets for the rest:
phase5-lxd/lab-lxd.sh exec relational-algebra-alpine/shell -- \
    apk add --no-cache bash coreutils gawk sqlite grep sed diffutils less shadow
```

Then make `awk` mean **gawk** on both bases. `/usr/local/bin` is first in `PATH`,
so a symlink there wins without fighting the package manager:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- \
    sh -c 'ln -sf "$(command -v gawk)" /usr/local/bin/awk'
```

### What each base lacks

Worth proving to yourself *before* you install anything, on a fresh container:

```bash
# On bare Alpine: bash and join simply are not there.
phase5-lxd/lab-lxd.sh exec relational-algebra-alpine/shell -- \
    sh -c 'command -v bash join || echo MISSING'
phase5-lxd/lab-lxd.sh exec relational-algebra-alpine/shell -- \
    sh -c 'busybox --list | grep -x join || echo "busybox has no join applet"'
```

A `#!/bin/bash` script on bare Alpine fails with a famously misleading message:

```
sh: /tmp/s: not found      # the SCRIPT is right there. The INTERPRETER is missing.
```

And the surprise that runs the other way — Debian's `/bin/sh` is **dash**, which
has no process substitution, while Alpine's BusyBox **ash does**:

```bash
phase5-lxd/lab-lxd.sh exec relational-algebra-debian/shell -- /bin/sh -c 'cat <(echo OK)'
#   /bin/sh: 1: Syntax error: "(" unexpected
phase5-lxd/lab-lxd.sh exec relational-algebra-alpine/shell -- /bin/sh -c 'cat <(echo OK)'
#   OK
```

Everyone "knows" Alpine's shell is the impoverished one. Check, don't assume.
Full capture in
[MANUAL_TESTING](MANUAL_TESTING.md#documented-divergence-neither-base-ships-what-the-articles-assume).

## 3. Create the non-root `learner` user — with a **bash** login

Unlike the sibling [sculpting-text](../UNIX-sculpting-text-regex-grep-sed-awk/README.md)
lab (whose learner logs into `/bin/sh`), here the login shell **is bash**: the
article's scripts declare it, and `<(…)`/`$'\t'` are bash features.

```bash
# Debian:
phase5-lxd/lab-lxd.sh exec relational-algebra-debian/shell -- \
    sh -c 'id learner >/dev/null 2>&1 || useradd -m -s /bin/bash learner'

# Alpine (adduser, not useradd):
phase5-lxd/lab-lxd.sh exec relational-algebra-alpine/shell -- \
    sh -c 'id learner >/dev/null 2>&1 || adduser -D -s /bin/bash learner'
```

## 4. Install the sandbox

Give the learner Might's scripts, the corrected twins, both articles' relations,
and a runnable `demo.sh`. Push them with the wrapper's **stdin** (cleaner than
escaping the awk programs and regexes these files are full of):

```bash
SBX=/home/learner/relational-algebra
phase5-lxd/lab-lxd.sh exec $LAB/shell -- sh -c "mkdir -p $SBX/bin/fixed $SBX/data"

# Might's four scripts, verbatim -- and their corrected twins.
for f in cartesian memberp difference equijoin; do
    phase5-lxd/lab-lxd.sh exec $LAB/shell -- sh -c "cat > $SBX/bin/$f" \
        < examples/UNIX-relational-algebra-sql-in-the-shell/bin/$f
    phase5-lxd/lab-lxd.sh exec $LAB/shell -- sh -c "cat > $SBX/bin/fixed/$f" \
        < examples/UNIX-relational-algebra-sql-in-the-shell/bin/fixed/$f
done

# Both articles' sample relations, and the demo.
for f in passwd etc-passwd bad.db f1 f2 employees.tsv departments.tsv; do
    phase5-lxd/lab-lxd.sh exec $LAB/shell -- sh -c "cat > $SBX/data/$f" \
        < examples/UNIX-relational-algebra-sql-in-the-shell/sample-data/$f
done
phase5-lxd/lab-lxd.sh exec $LAB/shell -- sh -c "cat > $SBX/demo.sh" \
    < examples/UNIX-relational-algebra-sql-in-the-shell/demo.sh

# `difference` calls `memberp` through PATH, exactly as the article assumes.
phase5-lxd/lab-lxd.sh exec $LAB/shell -- sh -c \
    "printf '%s\n' 'PATH=\"\$HOME/relational-algebra/bin:\$PATH\"' >> /home/learner/.profile"
phase5-lxd/lab-lxd.sh exec $LAB/shell -- \
    sh -c "chmod +x $SBX/demo.sh $SBX/bin/* $SBX/bin/fixed/*; chown -R learner $SBX"
```

**Why `bin/` on `PATH` matters.** `difference` invokes `memberp` bare, resolved by
`PATH`. That is how the article writes it, and it means the script's behaviour
depends on where you run it from — a real lesson about ambient lookup. (The
corrected `bin/fixed/difference` prepends its own directory instead.)

The data: Might's simplified four-line `passwd` and his `bad.db` (needed to
reproduce his published output byte-for-byte), a realistic `etc-passwd` (his
`uid != gid` selection selects **nothing** from the simplified file, where uid
always equals gid), his `f1`/`f2` for the `paste`-is-not-a-product demo, and
Walsh's tab-separated `employees.tsv` / `departments.tsv`.

## 5. Verify, then start querying

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- su - learner -c \
    'bash --version | head -1; join --version | head -1; sqlite3 --version; bash ~/relational-algebra/demo.sh'
```

`demo.sh` walks the six primitives and then runs **nine equality checks**, ending
on a single verdict line:

```
PASS: all 9 relational identities hold (Might's scripts == coreutils == SQL)
```

Every check compares two *independent implementations* of the same relational
expression — Might's quadratic bash against `comm`/`join`, and both against
`sqlite3`. If a check ever prints `[BAD]`, it dumps the `diff`. Now **drop into
the learner's shell**:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- su - learner
```

Then open both articles in your viewer and work through them against
`~/relational-algebra/data/`.

## 6. Teardown

```bash
phase5-lxd/lab-lxd.sh down --lab $LAB        # relational-algebra-debian or -alpine
```

`down` stops and deletes the container; nothing persists.

## Just run it (either base)

Steps 2–5 are exactly what [`setup-workshop.sh`](setup-workshop.sh) automates:

```bash
# ── Debian 13 (glibc) ───────────────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-relational-algebra-sql-in-the-shell/relational-algebra-debian.toml
examples/UNIX-relational-algebra-sql-in-the-shell/setup-workshop.sh relational-algebra-debian/shell
phase5-lxd/lab-lxd.sh exec relational-algebra-debian/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab relational-algebra-debian

# ── Alpine (musl / BusyBox) ─────────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-relational-algebra-sql-in-the-shell/relational-algebra-alpine.toml
examples/UNIX-relational-algebra-sql-in-the-shell/setup-workshop.sh relational-algebra-alpine/shell
phase5-lxd/lab-lxd.sh exec relational-algebra-alpine/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab relational-algebra-alpine
```

## The Exercise

Might closes his article with one, and it is the best thing in it:

> Some of these scripts have quadratic time complexity. Add a `-s` flag to
> `equijoin` and `difference` that assumes the inputs have been sorted by `sort`
> and produces a sorted output. Show that `-s` can achieve better time complexity.
> Then, rewrite the account-deletion example to eliminate Cartesian product and
> use fast `equijoin` instead.

The sandbox hands you the answer's shape without spoiling it. `demo.sh` §6 and §8
already prove that

```
difference A B   ==   comm -23 <(sort A) <(sort B)
equijoin A B 3 1 ==   join -t$'\t' -1 3 -2 1 A B      (both pre-sorted)
```

so `comm` and `join` **are** the linear implementations — they stream-merge two
sorted inputs in O(n + m) and never materialize the product. Your `-s` flag has to
do what they do. Two honest routes:

1. **Merge join** — advance two file descriptors in lockstep, emitting on key
   equality. O(n + m) time, O(1) memory, requires sorted input. This is `join(1)`.
2. **Hash join** — `awk 'NR==FNR { b[$c2] = $0; next } ($c1 in b) { … }' rel2 rel1`.
   O(n + m) time, O(|rel2|) memory, and it does **not** need sorted input. This is
   what a modern query planner picks when the input isn't already ordered.

Contrasting the two is the lesson that outlives the shell: **sortedness is what
buys you constant memory.** Then re-do the account deletion with `join` instead of
`cartesian` and watch a 2×4 product (8 rows materialized) collapse to a streamed
merge.

## Gotchas

- **`equijoin -t` returns zero rows and no error** → you hit erratum 3. The
  original sets `delim="\t"` and emits it with `echo` under `#!/bin/bash`, which
  does not expand escapes, so the delimiter is a literal backslash-`t` that matches
  nothing. Use `-d "$(printf '\t')"`, or `bin/fixed/equijoin -t`. An empty result
  set never tells you *why* it is empty.
- **`cartesian -t` prints `a\td`** → same bug, visible this time. `cat -A` is your
  friend: `^I` is a tab, `\t` is two characters.
- **`memberp: not found` from `difference`** → `~/relational-algebra/bin` is not on
  `PATH`. That is step 4's `.profile` line; `su - learner` (with the dash) reads it.
- **`join: input is not in sorted order`** → `join` and `comm` stream-merge, so
  they *require* sorted input, and `sort` must have used the same collation. Pin it
  with `export LC_ALL=C`; otherwise glibc and musl disagree and your join silently
  drops rows.
- **`sort -k3` is not `sort -k3,3`** → a bare `-k3` sorts from field 3 **to end of
  line**. It happens to work on this data. It will not always.
- **A `grep -E '\t'` that matches nothing** → POSIX ERE has no `\t`. GNU grep 3.11
  reads it as a literal `t` silently; 3.12 warns `stray \ before t`; BusyBox grep
  and ugrep treat it as a real tab. Use `[[:blank:]]`, or a literal tab, or
  `grep -P`. See [erratum 2](README.md#documented-errata-three-published-commands-that-dont-do-what-they-say).
- **`diff` gave me a weird answer for set difference** → `diff` is not `−`. It
  computes an edit script between two *ordered* files. `comm -23` (on sorted input)
  is set difference.
- **`awk: function gensub never defined`** → that's mawk (Debian's default awk),
  not gawk. The `awk` → `gawk` symlink from step 2 fixes it.
- **Image won't download / `up` hangs** → the `images:` remote can stall; it's not
  a lab bug. Pre-pull once with `incus image copy images:alpine/3.24 local:` (or
  `images:debian/13`) and retry.

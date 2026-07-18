# UNIX-ls-without-ls — `ddls`, an ls replacement in bash builtins + GNU stat + tput

A **throwaway system container** with **bash**, **GNU coreutils** — playing
*both* roles: the **`stat --printf`** that `ddls` is built on, and the **real
`ls`** that the demo uses as its oracle — **`tput`**, util-linux **`script`**
(the tty harness for the color and column checks), a non-root **`learner`**
user, and a `~/ls-without-ls/` sandbox holding the script **verbatim**, a
corrected twin under `bin/fixed/`, and a runnable **`demo.sh`** that does not
merely *show* the reimplementation — it **diffs it against the real thing,
byte for byte**. Built and driven through the repo's **Phase-5** tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically.

You type `ls` fifty times a day. Could you *write* it? `ddls` is that
exercise taken seriously: ~900 lines of bash that reimplement `-l -a -A -R
-h -F -i -d -r -S -t -U -n -1 --color`, columns, symlink targets, device
nodes and the `total` line — under a hard constraint: **bash builtins, GNU
`stat`, and `tput`. No awk, no sed, no grep, and above all no `ls`.**

Unlike the sibling Matt Might labs, the upstream here is **first-party**:
`ddls` was pair-written by this repo's author and an earlier Claude instance
(spring 2026) as a private experiment, and is vendored byte-exact under
[`upstream-source/`](upstream-source/README.md) — provenance, sha256, and the
delightful caveat that **the script's own header lies about it three times**
(see errata below). The script is canonical; its self-description is data.

**Series:** **1. ls without ls** *(this lab)* →
[2. less without less](../UNIX-less-without-less/README.md). Same constraint
family, same `dd` branding — with the running gag that *this* lab's tool
never actually calls `dd`, and the sibling's does.

## The one honest test for a reimplementation

If you rewrite `ls`, the only oracle that matters is `ls`. So `demo.sh`
builds one crafted directory (regular files, a hidden file, an executable, a
FIFO, a live symlink, a dangling symlink, a nested subdir — sizes and mtimes
all distinct) and diffs the two implementations byte-for-byte:

```
2. THE ORACLE: same directory, both tools, diff the bytes.
   [ok]  ddls -1  ==  ls -1
   [ok]  ddls -a -1  ==  ls -a -1
   [ok]  ddls -A -1  ==  ls -A -1
   [ok]  ddls -S -1  ==  ls -S -1
   [ok]  ddls -r -1  ==  ls -r -1
   [ok]  ddls -F -1  ==  ls -F -1
   [ok]  ddls -t -1  ==  ls -t -1
   [ok]  ddls -n  ==  ls -n
   [ok]  ddls -la == ls -la -- perms, links, owner, sizes, dates, total line: all of it
   [ok]  ddls -R == ls -R -1 (recursion, headers, blank lines)
```

Sit with that `-la` line for a second: permissions, hard-link counts, owner,
group, column alignment, the six-month time-format switchover, the `total`
blocks line — **byte-identical** to GNU ls, from a bash script. And where the
two *disagree*, the demo pins the divergence exactly (so it can't drift) and
holds the corrected twin to the stricter standard — it must match `ls`:

```
PASS: all 32 checks hold (ddls == GNU ls byte-for-byte on the core;
      all 4 divergences pinned exactly; the fixed twin closes every one)
```

`LC_ALL=C` is load-bearing: ls's sort order is collation-dependent and its
`-l` time format is locale-dependent — one export is why the run is
byte-identical on Debian *and* Alpine.

## The techniques worth stealing

The [RUNBOOK](RUNBOOK.md) walks the code; these are the headlines:

| Technique | Where | The idea |
|---|---|---|
| **One `stat`, twelve fields** | `stat_file()` | One `stat --printf` call per file with `$'\x01'`-delimited fields, split by parameter expansion — not twelve `$(stat ...)` forks. The delimiter is a byte that can't appear in the data. |
| **`printf %(...)T`** | `format_time()` | Bash ≥ 4.2 formats epoch seconds natively — the whole reason `date` isn't needed. |
| **Parallel arrays as structs** | `ENT_*[]` | Bash has no records; fifteen parallel arrays indexed together are the classic workaround, and column widths fall out of the collection pass. |
| **Indirect insertion sort** | `sort_entries()` | Sorts an *index* array with a pluggable comparator — pure bash, stable, no `sort` fork. Quadratic, and honest about it. |
| **Column packing** | `print_columns()` | The same widest-entry / column-major layout GNU ls uses, from `tput cols`. |
| **Fixed-point human sizes** | `human_size()` | `-h` in tenths with integer `$(( ))` — no bc, no awk. (Rounds the wrong way, though — see errata.) |

## Documented errata

The script was **executed and cross-examined**, not just read. Eight findings,
every one pinned by a `demo.sh` check (the verbatim script is asserted to
*keep* each quirk, so nothing can drift silently; `bin/fixed/` must not have
them). First, the header-vs-code lies:

| # | The claim | The truth |
|---|---|---|
| 1 | Header: "using BASH builtins, stat, tput, **and dd**" | **Nothing in the script invokes dd.** The `dd` in `ddls` is family branding (its sibling `ddpager` earns it). |
| 2 | Comment: "Use `-L` to NOT follow symlinks" | Backwards — `-L` would *follow* them. The code is right (GNU stat lstat's by default) and never passes `-L`; only the comment is wrong. |
| 3 | Constraint: "no other text-processing externals" | One `dirname` call slipped in (symlink-target coloring). The fixed twin replaces it with a parameter expansion. |

Then the behavioral divergences from GNU ls:

| # | Flag | Verbatim | GNU ls | Why |
|---|---|---|---|---|
| 4 | `--color=never` | **still colors** on a tty | off | auto-color runs *after* `parse_args` and overwrites the flag; only the `DDLS_NO_COLOR` env var actually works |
| 5 | `-i` (columns) | shows **2 of 12** files | all 12 | the one-per-line fallback lives *inside* the row loop, so it stops after `num_rows` entries — silent data loss |
| 6 | `-t` | same-second ties break by **name** | by **nanosecond** | sorts on `stat %Y` (whole seconds); ls compares full timespecs |
| 7 | `-h` | `1025 B → 1.0K`, `1048575 B → 1023K` | `1.1K`, `1.0M` | truncates where ls's `human_readable()` takes the ceiling |
| 8 | multiple file args | argv order, blank-line separated, minor as `%3d` | one sorted listing, dynamic padding | structural — see `main()` |

**#5 is the sharpest lesson**: the bug produces no error, no garble — just a
*shorter listing*, which is the failure mode you don't notice. **#4 is the
subtlest**: the flag parses fine, the code path exists, and a later
"sensible default" quietly wins.

### `bin/` vs `bin/fixed/`

[`bin/ddls`](bin/ddls) is **verbatim** (sha256-checked against the archive on
every demo run) — the object of study. [`bin/fixed/ddls`](bin/fixed/ddls) is
the **drop-in corrected twin**: every erratum above closed, each fix labeled
`FIXED:` in place. Diff them — that's the exercise:

```bash
diff -u bin/ddls bin/fixed/ddls
```

## Documented divergence: the land you live off is GNU

`ddls` "lives off the land" — but the land it assumes is GNU. The two bases
disagree about every single dependency:

| | Debian 13 (trixie) | Alpine |
|---|---|---|
| `bash` | ✅ present | ❌ **absent** — the interpreter itself |
| `stat --printf` | ✅ coreutils | ❌ BusyBox stat has `-c`, **no `--printf`** |
| `tput` | ✅ ncurses-bin | ❌ **absent** |
| `ls` (the oracle) | ✅ GNU | ⚠️ BusyBox applet — **not GNU**, can't be the oracle |

A constraint set that *sounds* minimal — "just bash, stat, tput" — is three
GNU/ncurses dependencies that the most popular container base doesn't ship.
[`setup-workshop.sh`](setup-workshop.sh) installs the real things on both
bases, after which `demo.sh` passes identically ([proof per distro in
MANUAL_TESTING](MANUAL_TESTING.md)).

## Quick start

Both bases are first-class — pick either (or run both; the labs are
independent and coexist). The flow is identical bar the name:

```bash
# ── Debian 13 (trixie / glibc base) ─────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-ls-without-ls/ls-without-ls-debian.toml
examples/UNIX-ls-without-ls/setup-workshop.sh ls-without-ls-debian/shell     # ~1 min
phase5-lxd/lab-lxd.sh exec ls-without-ls-debian/shell -- su - learner        # start listing
phase5-lxd/lab-lxd.sh down --lab ls-without-ls-debian                        # tear down

# ── Alpine (musl / BusyBox base) ────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-ls-without-ls/ls-without-ls-alpine.toml
examples/UNIX-ls-without-ls/setup-workshop.sh ls-without-ls-alpine/shell
phase5-lxd/lab-lxd.sh exec ls-without-ls-alpine/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab ls-without-ls-alpine
```

Then, inside the `su - learner` shell:

```bash
bash ~/ls-without-ls/demo.sh                      # the 32 checks
bash ~/ls-without-ls/bin/ddls -la --color /etc    # drive it yourself
diff <(bash ~/ls-without-ls/bin/ddls -la /etc) <(ls -la /etc)   # your own oracle check
```

## Files

| File | Purpose |
|---|---|
| [`ls-without-ls-debian.toml`](ls-without-ls-debian.toml) / [`ls-without-ls-alpine.toml`](ls-without-ls-alpine.toml) | Phase-5 specs: one container each |
| [`setup-workshop.sh`](setup-workshop.sh) | Provision bash + coreutils + tput + script + `learner` + the sandbox |
| [`demo.sh`](demo.sh) | **32 checks**: oracle diffs, pinned divergences, tty behavior; ends on `PASS:`/`FAIL:` |
| [`bin/ddls`](bin/ddls) | The script — **verbatim**, sha256-guarded |
| [`bin/fixed/ddls`](bin/fixed/ddls) | Drop-in corrected twin; `diff -u` them |
| [`RUNBOOK.md`](RUNBOOK.md) | The tutorial: how ddls works, technique by technique |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Real captured transcripts (both distros) |
| [`upstream-source/`](upstream-source/README.md) | Byte-exact archive of the original + provenance + sha256 |

## Scope & caveats

- **Throwaway lab.** Containers are disposable; `down` wipes them. Re-run the
  quick start for a clean slate.
- **A teaching artifact, not a tool.** The sort is quadratic, every `stat` and
  color lookup is a `$( )` fork (the demo's census: `stat` ×4 call sites,
  `tput` ×1, `dirname` ×1 — *every* external is a fork), and a big directory
  will feel it. Use real `ls` in anger; read `ddls` to understand what `ls`
  does for you.
- **GNU stat is a hard dependency** — `--printf` with `%F`/`%a`/`%t:%T` and
  (fixed twin) `%.9Y`. That's the honest cost of one-call-per-file.
- **The oracle needs GNU ls.** `demo.sh` refuses (exit 77, `SKIP:`) rather
  than diff against BusyBox ls and report vacuous failures.
- **Non-root `learner`.** Listing is done as an ordinary user; the container's
  root is only used by `setup-workshop.sh`.

## Prerequisites

- **LXD or Incus initialised** — `incus admin init` (or `lxd init`). See the
  Phase-5 docs: [`START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- Outbound network from the container (to `apt`/`apk` the tools).

## Sources

First-party: pair-written by this repo's author and an earlier Claude
instance, spring 2026; vendored byte-exact with provenance and sha256 under
[`upstream-source/`](upstream-source/README.md). The lab's RUNBOOK is the
tutorial that project never had — written against the code, not the header.

This lab sits in the **shell-fluency track** between
[set operations](../UNIX-set-operations-in-the-shell/README.md) and
[floating-point arithmetic in bash](../UNIX-floating-point-arithmetic-in-bash/README.md):
after querying text like a database, you rebuild the most-typed command in
Unix — and learn it was a database report generator all along (gather
records, sort, project, format). Its sibling
[less without less](../UNIX-less-without-less/README.md) does the same for
the screen you read that report on.

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog.

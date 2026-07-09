# UNIX-relational-algebra-sql-in-the-shell — SQL-shaped operations in the shell

A **throwaway system container** with **bash**, the **GNU coreutils** that make
relational algebra tractable (`join`, `comm`, `cut`, `sort`, `uniq`, `paste`),
**gawk**, and **`sqlite3` as a live SQL oracle** — plus a non-root **`learner`**
user and a `~/relational-algebra/` sandbox holding **Matt Might's four scripts
verbatim**, corrected twins under `bin/fixed/`, both articles' sample relations,
and a runnable **`demo.sh`** that does not merely *show* the correspondence
between relational algebra, Unix pipelines and SQL — it **proves** it. Built and
driven through the repo's **Phase-5** tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically.

Unix, as Might puts it, is *"a bestiary of ad hoc databases"* — `/etc/passwd`,
`/etc/hosts`, `netstat -nr`, every log file: comma-, colon-, tab- and
space-separated **relations**, one tuple per line. Shell scripts compose them
with, usually without knowing it, **five of relational algebra's six primitive
operations**. This lab makes that relationality explicit and then holds it to the
only standard that matters: *does it agree with a real database?*

Two sources, deliberately paired, both vendored byte-exact under
[`upstream-tutorial/`](upstream-tutorial/README.md):

| Source | Year | What it gives you |
|---|---|---|
| **Matt Might**, [*Relational shell programming*](upstream-tutorial/matt-might/articles/sql-in-the-shell/index.html) | c. 2010 | Implements the primitives **by hand in bash** — including `cartesian`, the one Unix never shipped — and closes with a worked "delete the bad users" pipeline. |
| **Jason Walsh**, [*SQL in the Shell*](upstream-tutorial/wal-sh/research/relational-algebra/index.html) | 2026 | Maps the same algebra onto the **native tools** (`join`, `comm`, `uniq -c`), adds aggregation, and cross-checks against **SQL**. |

Read Might for *why the primitives are what they are*; read Walsh for *what to
type today*. The lab runs both, side by side, against the same relations.

## The six primitives, and where the shell keeps them

| Operation | Notation | SQL | Unix |
|---|---|---|---|
| Union | ∪ | `UNION` | `cat` (then `sort -u`, because a relation is a **set**) |
| Selection | σ | `WHERE` | `grep`, `awk`, `sed` |
| Projection | π | `SELECT cols` | `cut` (`awk` when you must **reorder**) |
| Rename | ρ | `AS` | *nothing to do* — Unix columns are named **positionally** |
| Cartesian product | × | `CROSS JOIN` | **nothing** — Might writes `cartesian` in 15 lines of bash |
| Difference | − | `EXCEPT` | `comm -23` (**not** `diff`, which is an edit script) |
| *(derived)* Intersection | ∩ | `INTERSECT` | `comm -12` |
| *(derived)* Equijoin | ⋈ | `JOIN … ON` | `join` — i.e. **product, then selection** |
| *(not algebra)* Aggregation | — | `GROUP BY` | `sort \| uniq -c`, `awk` associative arrays |

## Quick start

Both bases are first-class — pick either (or run both; the labs are independent
and coexist). The flow is identical bar the name:

```bash
# ── Debian 13 (trixie / glibc base) ─────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-relational-algebra-sql-in-the-shell/relational-algebra-debian.toml
examples/UNIX-relational-algebra-sql-in-the-shell/setup-workshop.sh relational-algebra-debian/shell   # ~1 min
phase5-lxd/lab-lxd.sh exec relational-algebra-debian/shell -- su - learner                            # start querying
phase5-lxd/lab-lxd.sh down --lab relational-algebra-debian                                            # tear down

# ── Alpine (musl / BusyBox base) ────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-relational-algebra-sql-in-the-shell/relational-algebra-alpine.toml
examples/UNIX-relational-algebra-sql-in-the-shell/setup-workshop.sh relational-algebra-alpine/shell
phase5-lxd/lab-lxd.sh exec relational-algebra-alpine/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab relational-algebra-alpine
```

Then **open the two articles** in your viewer and follow along, running pipelines
in `~/relational-algebra/` inside the `su - learner` shell.

## `demo.sh` proves it, it doesn't just show it

The sandbox's `demo.sh` walks all six primitives, then runs **nine equality
checks**. Each one asserts that two *independent implementations* of the same
relational expression return the same relation:

```
   [ok]  DIFFERENCE: Might's difference(3)  ==  comm -23
   [ok]  EQUIJOIN: Might's equijoin(3)  ==  join(1)
   [ok]  WORKED EXAMPLE: output == the article's published output
   [ok]  SELECTION:   awk  ==  SQL WHERE
   [ok]  JOIN+PROJ:   join(1) | cut -f3,5  ==  SQL JOIN
   [ok]  AGGREGATION: awk arrays  ==  SQL GROUP BY
   [ok]  FIXED cartesian: -t  ==  -d $'\t'
   [ok]  FIXED difference: == the verbatim original
   [ok]  FIXED equijoin -t: == join(1)

PASS: all 9 relational identities hold (Might's scripts == coreutils == SQL)
```

Four implementations of one algebra — a 2010 bash script, its corrected twin,
coreutils, and an SQL engine — over identical data. **All nine checks pass
identically on Debian and Alpine** ([proof per distro in
MANUAL_TESTING](MANUAL_TESTING.md)).

Two ideas do the work, and both are worth internalizing:

- **A relation is a *set*: unordered, no duplicates.** To compare two of them you
  must first canonicalize order — which is what `sort` is for. It is also *why*
  `join` and `comm` demand sorted input: they stream-merge.
- **Collation is locale-dependent**, so `sort` on glibc and on musl would disagree
  and every check would fail. One `export LC_ALL=C` at the top of `demo.sh` is
  the entire reason the two bases produce byte-identical output.

## Documented errata: three published commands that don't do what they say

Both articles were **executed**, not just read. Three commands are wrong, and all
three fail **quietly** — no error, just a wrong or empty answer. They are
preserved unmodified in the archive and in `bin/`; the corrections live in
`bin/fixed/` and in `demo.sh`.

| # | Source | As published | What actually happens |
|---|---|---|---|
| 1 | Walsh, *Natural Join* | `join … \| cut -f2,4` under the heading `SELECT e.name, d.dept_name` | `join` emits `dept_id,id,name,salary,dept_name,location`, so `-f2,4` projects **`id, salary`**. The stated SQL needs **`cut -f3,5`**. |
| 2 | Walsh, *Selection* | `grep -E '^(id\|.*\tengineering)' departments.tsv` | **Prints nothing** on GNU grep. The header is `dept_id`, so `^id` never matches; and POSIX ERE has no `\t` escape, so `.*\tengineering` hunts for `…tengineering`. |
| 3 | Might, *Cartesian product* | `cartesian -t` (tab-delimited) | Sets `delim="\t"` and emits it with `echo` under `#!/bin/bash` — bash's `echo` does **not** expand escapes, so the delimiter is a literal backslash-`t`. `equijoin -t` inherits the bug and silently returns **zero rows**. |

**Erratum 2 is the sharpest teaching moment in the lab**, because *the same
command behaves three different ways depending on which grep you have* — and none
of them tells you:

```
Debian 13, GNU grep 3.11  ->  (no output; \t silently means a literal "t")
Alpine,     GNU grep 3.12  ->  grep: warning: stray \ before t
Alpine,     BusyBox grep   ->  10  engineering  sf      (\t IS a tab here)
```

The portable spelling is the POSIX class: `grep -E '^(dept_id|.*[[:blank:]]engineering)'`.

Erratum 3 is the one most likely to bite you, because an empty result set reads as
*"nothing matched"*, not as *"your delimiter is wrong"*:

```
original equijoin -t on TSV -> 0 row(s)
fixed    equijoin -t on TSV -> 5 row(s)
```

### `bin/` vs `bin/fixed/`

`bin/` holds Might's four scripts **verbatim** — the object of study; you cannot
learn from code that was silently rewritten. `bin/fixed/` holds **drop-in
corrected twins**: `-t` emits a real tab, `IFS= read -r` stops backslash-eating
and whitespace-stripping, paths are quoted, `exit -1` becomes `exit 1`, and
`difference` calls *its own* `memberp` rather than whatever `PATH` finds. Diff
them — that's the exercise:

```bash
diff -u bin/cartesian bin/fixed/cartesian
```

Both are **quadratic** by design, faithfully to the article. Making them linear is
Might's own closing Exercise; see [RUNBOOK.md](RUNBOOK.md#the-exercise).

## Documented divergence: what each base is missing

Neither base ships what the articles assume, and they are missing **different**
things — captured verbatim in
[MANUAL_TESTING](MANUAL_TESTING.md#documented-divergence-neither-base-ships-what-the-articles-assume):

| | Debian 13 (trixie) | Alpine |
|---|---|---|
| `bash` | ✅ present | ❌ **absent** — Might's `#!/bin/bash` scripts die with the misleading `not found` (it's the *interpreter* that's missing) |
| `join` | ✅ coreutils | ❌ **BusyBox has no `join` applet at all** |
| `comm` | ✅ coreutils | ⚠️ BusyBox applet |
| `awk` | ⚠️ **mawk** | ⚠️ BusyBox awk |
| `sqlite3` | ❌ absent | ❌ absent |
| `grep -E '\t'` | literal `t` (3.11, silent) | literal `t` (3.12, **warns**); BusyBox: **a tab** |
| `<(…)` in `/bin/sh` | ❌ dash: `Syntax error: "(" unexpected` | ✅ **BusyBox ash has it** |

That last row is the fun one — **the usual story inverted**. Everyone "knows"
Alpine's shell is the impoverished one, yet BusyBox `ash` implements process
substitution (a bash-compat extension) while Debian's `dash` does not. The lab
installs `bash` on both anyway, because Might's scripts declare it.

So `setup-workshop.sh` installs **bash + GNU coreutils + gawk + sqlite3** on both
and points `awk` at `gawk`, after which every pipeline runs identically on glibc
and musl.

## What `setup-workshop.sh` does

Automated counterpart to the by-hand walk in [RUNBOOK.md](RUNBOOK.md); it touches
the guest **only** through `lab-lxd.sh exec` (engine-agnostic), in five steps:

1. **detect** the distro (`/etc/alpine-release` vs `/etc/debian_version`);
2. **install** `bash`, GNU `coreutils` (for `join`/`comm`), `gawk`, `sqlite3`,
   `diffutils`, `less` — and symlink `awk` → `gawk` on both bases;
3. **create** a non-root `learner` user with a **bash** login (unlike the sibling
   text lab: the articles' scripts are `#!/bin/bash`, and `<(…)`/`$'\t'` are bash);
4. **install** the `~/relational-algebra/` sandbox — `bin/` (verbatim),
   `bin/fixed/`, `data/`, `demo.sh` — and put `bin/` on the learner's `PATH`,
   because `difference` looks up `memberp` there, exactly as the article assumes;
5. **verify** as `learner` — print tool versions and **run `demo.sh`**, which must
   end on `PASS:`.

## Files

| File | Purpose |
|---|---|
| [`relational-algebra-debian.toml`](relational-algebra-debian.toml) / [`relational-algebra-alpine.toml`](relational-algebra-alpine.toml) | Phase-5 specs: one container each |
| [`setup-workshop.sh`](setup-workshop.sh) | Provision bash + coreutils + gawk + sqlite3 + `learner` + the sandbox |
| [`demo.sh`](demo.sh) | The six primitives, then **nine equality checks**; ends on `PASS:`/`FAIL:` |
| [`bin/`](bin/) | Might's `cartesian`, `memberp`, `difference`, `equijoin` — **verbatim** |
| [`bin/fixed/`](bin/fixed/) | Drop-in corrected twins; `diff -u` them against `bin/` |
| [`sample-data/`](sample-data/) | Might's `passwd`/`bad.db`/`f1`/`f2`, a realistic `etc-passwd`, Walsh's `employees.tsv`/`departments.tsv` |
| [`RUNBOOK.md`](RUNBOOK.md) | The by-hand walk — every step, with the *why* |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Real captured transcripts (both distros) + the errata proofs |
| [`upstream-tutorial/`](upstream-tutorial/README.md) | Byte-exact archives of both articles + CSS + provenance |

## Scope & caveats

- **Throwaway lab.** Containers are disposable; `down` wipes them. No persistent
  state, no real credentials. Re-run the quick start for a clean slate.
- **Non-root `learner`.** Querying is done as an ordinary user; the container's
  root is only used by `setup-workshop.sh`.
- **`data/passwd` is Might's simplified four-line file**, not a real one — it is
  what his worked example is written against, and reproducing his exact published
  output requires it. `data/etc-passwd` is a realistic excerpt, used where the
  article's own examples run against a real `/etc/passwd` (his `uid != gid`
  selection selects nothing from the simplified file, since uid always equals gid).
- **These scripts are teaching artifacts, not tools.** They are quadratic, they
  `read` without `-r` (the verbatim set), and they are the *reason* `join` and
  `comm` exist. Use coreutils in anger.
- **`sqlite3` is here as an oracle**, not as a subject. The point is not to teach
  SQL; it is to have an independent implementation that can disagree with you.
- **Read the articles on the host, type in the container.** Both live in this
  repo; open them in your viewer, run pipelines via `exec … su - learner`.

## Prerequisites

- **LXD or Incus initialised** — `incus admin init` (or `lxd init`). See the
  Phase-5 docs: [`START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- Outbound network from the container (to `apt`/`apk` the tools).

## Sources

Both articles carry **no explicit open license**; they are vendored byte-exact for
**offline educational reference** under
[`upstream-tutorial/`](upstream-tutorial/README.md) (provenance + `sha256` +
attribution).

- Might: <https://matt.might.net/articles/sql-in-the-shell/>
- Walsh: <https://wal.sh/research/relational-algebra>

This is a Phase-5 sibling to the other Matt Might labs — the
[*survival guide*](../UNIX_novice_survival_guide/README.md),
[*bash by example*](../shell-intermediate-programming-by-example/README.md),
[*sculpting text*](../UNIX-sculpting-text-regex-grep-sed-awk/README.md), and
[*Hello, Perceptron*](../AI-build-a-perceptron/README.md) — same "vendor the page,
build the sandbox, learn by doing" shape. It is the natural sequel to *sculpting
text*: there you learn to wield `grep`/`sed`/`awk`; here you discover that when
you compose them you have been writing a database engine all along.

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog.

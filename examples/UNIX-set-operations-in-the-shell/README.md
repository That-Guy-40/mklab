# UNIX-set-operations-in-the-shell — sets, and the recipes that quietly get them wrong

**Part 2 of the shell-as-a-database series.** Part 1,
[*relational algebra*](../UNIX-relational-algebra-sql-in-the-shell/README.md),
showed that composing `cut`/`awk`/`join` is relational algebra. This one drops a
level: **the sets underneath**, the tools that manipulate them (`sort`, `uniq`,
`comm`, `grep`, `join`, `diff`, `wc`, `head`, `tail`), and a collation bug that
silently destroys results — including, as it happens, the very puzzle answer that
inspired the canonical article on the subject.

A **throwaway system container** with **bash**, **GNU coreutils** (`comm`, `join`,
`uniq`, and `factor`), **gawk**, **perl**, **`sqlite3` as a set oracle**, and
**busybox** for the BusyBox-vs-GNU contrast — plus a non-root **`learner`** user
and a `~/set-operations/` sandbox holding the articles' fourteen recipes as
sourceable shell functions (**verbatim**), corrected twins under `bin/fixed/`,
both authors' sample data, a **`demo.sh`** that runs **28 equality checks**, and a
**`treasure-hunt.sh`** that reproduces Google's 2008 puzzle answer from scratch in
under a second. Built and driven through the repo's **Phase-5** tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically.

## Four sources, one story

All vendored byte-exact under [`upstream-tutorial/`](upstream-tutorial/README.md):

| # | Source | Year | Why it's here |
|---|---|---|---|
| 1 | **Krumins**, [*Solving Google Treasure Hunt Puzzle 4*](upstream-tutorial/catonmat/solving-google-treasure-hunt-prime-number-problem-four/index.html) | 2008 | **The problem.** He solves it entirely in the shell; the crux is a four-way set intersection. *This is what made him write about sets at all.* |
| 2 | **Krumins**, [*Set Operations in the Unix Shell*](upstream-tutorial/catonmat/set-operations-in-unix-shell/index.html) | 2008 | **The article.** Fourteen set operations, explained. |
| 3 | **Krumins**, [*…Simplified*](upstream-tutorial/catonmat/set-operations-in-unix-shell-simplified/index.html) + [`setops.txt`](upstream-tutorial/catonmat/ftp/setops.txt) | 2008 | **The cheat sheet.** The same fourteen, plus an `awk` implementation of each. |
| 4 | **Thomas Guest**, [*He Sells Shell Scripts to Intersect Sets*](upstream-tutorial/accu/journals/overload/15/80/guest_1410/index.html) | ACCU *Overload* 80, Aug **2007** | **The counterpoint.** Same operations, reached by **counting** (`uniq -c`) instead of **merging** (`comm`), on real Apache logs — then an argument about what the shell tools *teach*. |

Guest's piece **predates** Krumins' puzzle by nearly a year, and neither cites the
other. They converge on the same operations and diverge on the algorithm, which is
exactly why the pair is worth more than either alone: **two independent
implementations can be checked against each other.**

## The fourteen operations

| Operation | Notation | Merge family | Count family | Hash family | SQL |
|---|---|---|---|---|---|
| Membership | `a ∈ A` | — | — | `grep -xq` | — |
| Equality | `A = B` | `diff -q` on sorted | — | `awk` | — |
| Cardinality | `\|A\|` | — | `wc -l` | `awk END{NR}` | `COUNT(DISTINCT)` |
| Subset | `S ⊆ A` | `comm -23` empty | — | `awk` | `EXCEPT` empty |
| Union | `A ∪ B` | `sort -mu` | `sort -u` | `awk '!a[$0]++'` | `UNION` |
| Intersection | `A ∩ B` | `comm -12` | `uniq -d`, `uniq -c` | `grep -xF -f`, `awk` | `INTERSECT` |
| Complement | `A − B` | `comm -23` | `sort B B A \| uniq -u` | `grep -vxF -f`, `awk` | `EXCEPT` |
| Symmetric difference | `A △ B` | `comm -3` | `uniq -u` | two `grep`s | `EXCEPT`/`UNION` |
| Disjoint | `A ∩ B = Ø` | `comm -12` empty | — | `awk` | — |
| Empty | `A = Ø` | — | `wc -l` = 0 | `awk` | — |
| Minimum / Maximum | `min/max(A)` | `sort -n \| head/tail` | — | `awk` | `MIN`/`MAX` |
| Cartesian product | `A × B` | — | — | nested loops, `awk` | `CROSS JOIN` |
| Power set | `P(A)` | — | — | recursion (bash, perl) | — |

Three algorithm families, and they are genuinely different: **merge** streams two
sorted inputs; **count** tallies occurrences and filters on the tally; **hash**
loads one side into a table. When they disagree, someone is wrong.

## Quick start

```bash
# ── Debian 13 (trixie / glibc base) ─────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-set-operations-in-the-shell/set-operations-debian.toml
examples/UNIX-set-operations-in-the-shell/setup-workshop.sh set-operations-debian/shell   # ~1 min
phase5-lxd/lab-lxd.sh exec set-operations-debian/shell -- su - learner                    # start intersecting
phase5-lxd/lab-lxd.sh down --lab set-operations-debian                                    # tear down

# ── Alpine (musl / BusyBox base) ────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-set-operations-in-the-shell/set-operations-alpine.toml
examples/UNIX-set-operations-in-the-shell/setup-workshop.sh set-operations-alpine/shell
phase5-lxd/lab-lxd.sh exec set-operations-alpine/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab set-operations-alpine
```

## `demo.sh` proves it, it doesn't just show it

Twenty-eight checks, each asserting that two *independent implementations* of the
same set expression return the same set:

```
   [ok]  INTERSECTION: comm(merge)  ==  uniq -d(count)
   [ok]  INTERSECTION: comm(merge)  ==  uniq -c(Guest)
   [ok]  INTERSECTION: comm(merge)  ==  grep -xF(hash)
   [ok]  INTERSECTION: comm(merge)  ==  awk(hash)
   [ok]  INTERSECTION: comm(merge)  ==  SQL INTERSECT
   ...
   [ok]  LANDMINE:     published comm+sort -n loses the intersection
   [ok]  LANDMINE:     fixed  ==  SQL INTERSECT  ==  {10}

PASS: all 28 set identities hold (merge == count == hash == SQL)
```

`sqlite3` is the oracle, and it is not a stretch: **`UNION`, `INTERSECT` and
`EXCEPT` *are* the set operators**, which is the thread back to
[part 1](../UNIX-relational-algebra-sql-in-the-shell/README.md). The whole demo
transcript is **byte-identical on Debian and Alpine** ([proof per distro in
MANUAL_TESTING](MANUAL_TESTING.md)) — because of one line at the top:

```sh
export LC_ALL=C
```

A set is unordered with no duplicates, so comparing two of them means
canonicalizing order with `sort` — and `sort`'s collation is locale-dependent. It
is also *why* `comm` and `join` demand sorted input: they stream-merge.

## The landmine: `comm` merges byte-wise

Krumins repeats, throughout the article, *"if you have a numeric set, then `sort`
must take `-n` option"*, and writes `comm -12 <(sort -n set1) <(sort -n set2)`.

**For `comm` and `join`, that advice is backwards, and it fails silently.**

```
P = {1, 9, 10}    Q = {10}    so  P ∩ Q  =  {10}

comm -12 <(sort -n P) <(sort -n Q)  ->  (empty)     WRONG
comm -12 <(sort    P) <(sort    Q)  ->  10          right
```

`comm` compares lines **byte by byte**. `sort -n` orders `1 < 9 < 10`; `comm`
expects `1 < 10 < 9`. Given the wrong order it walks off the end of a file and
reports no match — exit status `0`, no output, and only *sometimes* a warning on
stderr. The same trap makes his **subset test report a subset as not-a-subset**.

Why did nobody notice? Because on his own hand-crafted `A = {3,5,1,2,4}` and
`B = {11,1,12,3,2}`, both spellings happen to agree. `demo.sh` checks that too.

### The article's recipe destroys the puzzle that inspired the article

This is not hypothetical. `treasure-hunt.sh` reproduces Google Treasure Hunt 2008,
Puzzle 4 — *the smallest prime that is a sum of 7, 17, 41 and 541 consecutive
primes* — whose crux is a four-way intersection of files of numbers:

```
[3/4] four-way intersection, his pipeline:  sort -nm | uniq -d
      candidates: 7830239
[4/4] factor 7830239 -> 7830239: 7830239        it is prime.

== The same intersection, done the way his ARTICLE recommends ==
   step 1 (comm + sort -n)  -> 0 elements
   ground truth (awk hash)  -> 9 elements
   final answer             -> ''
   comm + lexicographic sort -> '7830239'
```

His **puzzle pipeline** uses `sort -nm … | uniq -d`, which is correct: `uniq` only
needs equal lines to be **adjacent**, and any consistent sort delivers that. His
**article** recommends `comm` with `sort -n`, which loses the answer at step one.
The count family is immune to the collation trap; the merge family is not.

> `treasure-hunt.sh` also swaps Krumins' 500 MB download of 50 million primes
> (from a list that has since moved) for one coreutils pipeline —
> `seq 2 1200000 | factor | awk 'NF==2 {print $2}'` — which yields 92,938 primes
> in about 0.2 s. It then **asserts** that each sliding-window sum file overshoots
> the cap, so a missing answer can never be mistaken for "not enough primes".

## Documented errata: eight published commands that don't do what they say

Every one fails **quietly**. They are preserved unmodified in `bin/setops` and in
the archive; corrections live in `bin/fixed/` and are demonstrated live by
`demo.sh` §10.

| # | Source | As published | What actually happens |
|---|---|---|---|
| 1 | Krumins, throughout | `comm -12 <(sort -n A) <(sort -n B)` | **`comm` merges byte-wise.** Silently misses matches; empties the intersection; makes the subset test lie. |
| 2 | Krumins, Union | `set -um set1 set2` | Typo for `sort -um`. In bash `set -u -m` is a **builtin**: it turns on `nounset`, assigns `$1`/`$2`, prints nothing, returns 0. |
| 3 | Krumins, Symmetric Difference | `comm -3 <(sort -n A) >(sort -n B)` | `>(…)` is an **output** process substitution. `comm` gets a write-only pipe and **hangs forever**. |
| 4 | Krumins, Maximum | `head -1 <(sort -n Abig)`, printed as the max | `head -1` of an ascending sort is the **minimum**. The prose says `tail`; the example runs `head`. |
| 5 | Krumins, cheat sheet, Subset | `awk '… { if !($0 in a) exit 1 }'` | **gawk syntax error** — `if` needs parentheses. That cheat-sheet line has never run. |
| 6 | Krumins, Cartesian product | `while read a; … done < set1; done < set2` | The **inner** loop reads `set1`, so it emits `set2 × set1`. |
| 7 | Krumins, power set (perl) | `print @$p` | No separator: for `{1,2,12}` the subsets `{1,2}` and `{12}` both print as `12`. Eight subsets, **seven distinct lines**. |
| 8 | Guest, intersection | `sort -m IP1 IP2 \| uniq -c \| grep "^ *2"` | Correct for true sets (counts 1 or 2), as he says. On a **multiset**, `^ *2` also matches counts `20`, `21`, `200`… Use `awk '$1 == 2'`. |

Guest's `sort -t. +0n -1n …` for natural IP ordering is a ninth, softer case: the
obsolete POSIX `+POS -POS` key syntax. **GNU `sort` still accepts it** (even under
`POSIXLY_CORRECT`); **BusyBox `sort` rejects it**. Modern spelling:
`sort -t. -k1,1n -k2,2n -k3,3n -k4,4n`, or just `sort -V`.

> Guest's article also contains `rm -rf $TEMP_WORK_DIR/*` under the heading
> *"Don't try this at home!"* — as a deliberate illustration of shell scripts not
> failing safely when a variable is unset. It is quoted here and **never executed
> anywhere in this lab**, which is precisely his point.

### `bin/` vs `bin/fixed/`

`bin/setops` holds all fourteen recipes as **sourceable shell functions** — which
is Guest's own suggestion ("these simple one-line scripts can be stored as
functions which can be sourced") applied to Krumins' recipes, warts included. It
is the object of study. `bin/fixed/setops` is the drop-in corrected twin. Diff
them; that's the exercise:

```bash
. bin/fixed/setops && set_intersect data/A data/B
diff -u bin/setops bin/fixed/setops
```

Same for `bin/powerset` (bash) and `bin/powerset.pl` (perl).

## Documented divergence: what each base is missing

| | Debian 13 (trixie) | Alpine |
|---|---|---|
| `bash` | ✅ | ❌ **absent** (a `#!/bin/bash` script reports the misleading `not found`) |
| `join` | ✅ coreutils | ❌ **BusyBox has no `join` applet at all** |
| `comm`, `uniq`, `factor` | ✅ coreutils | ⚠️ BusyBox applets (yes, BusyBox has `factor`) |
| `awk` | ⚠️ **mawk** | ⚠️ BusyBox awk |
| `sqlite3`, `gawk` | ❌ absent | ❌ absent |
| `perl` | ✅ | ❌ absent |
| `sort +0n -1n` | accepted (GNU) | accepted (GNU) — but `busybox sort` **rejects** it |
| `<(…)` in `/bin/sh` | ❌ dash: `Syntax error: "(" unexpected` | ✅ **BusyBox ash has it** |

That last row is the fun one, and it is the same inversion
[part 1](../UNIX-relational-algebra-sql-in-the-shell/README.md#documented-divergence-what-each-base-is-missing)
found: everyone "knows" Alpine's shell is the impoverished one, yet BusyBox `ash`
implements process substitution — which every `comm` recipe in both articles is
written with — while Debian's `dash` does not.

`setup-workshop.sh` installs **bash + GNU coreutils + gawk + perl + sqlite3 +
busybox** on both, after which the whole demo is byte-identical across glibc and
musl.

## Files

| File | Purpose |
|---|---|
| [`set-operations-debian.toml`](set-operations-debian.toml) / [`set-operations-alpine.toml`](set-operations-alpine.toml) | Phase-5 specs: one container each |
| [`setup-workshop.sh`](setup-workshop.sh) | Provision the tools + `learner` + the sandbox |
| [`demo.sh`](demo.sh) | 14 operations × 3 algorithm families + SQL; **28 checks**; ends on `PASS:`/`FAIL:` |
| [`treasure-hunt.sh`](treasure-hunt.sh) | Reproduces Google Treasure Hunt puzzle 4 (`7830239`) — and shows the article's own recipe losing it |
| [`bin/`](bin/) | `setops` (14 recipes as functions), `powerset`, `powerset.pl` — **verbatim** |
| [`bin/fixed/`](bin/fixed/) | Drop-in corrected twins; `diff -u` them against `bin/` |
| [`sample-data/`](sample-data/) | Krumins' `A`,`B`,`Asub`,`Anotsub`,`Aequal`,`Bequal`; the landmine `P`,`Q`; Guest's `access_log1`,`access_log2` |
| [`RUNBOOK.md`](RUNBOOK.md) | The by-hand walk — every step, with the *why* |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Real captured transcripts (both distros) + the errata proofs |
| [`upstream-tutorial/`](upstream-tutorial/README.md) | Byte-exact archives of all four pages + the cheat sheet + CSS + provenance |

## Scope & caveats

- **Throwaway lab.** Containers are disposable; `down` wipes them. Re-run the
  quick start for a clean slate.
- **Non-root `learner`.** The container's root is only used by `setup-workshop.sh`.
- **`bin/setops` is deliberately wrong in places.** It is the article, transcribed.
  Use `bin/fixed/setops` for anything real.
- **The power set is exponential.** `|P(A)| = 2^|A|`. A 30-element set is a
  billion lines. Do not "just try it on a big file."
- **`treasure-hunt.sh` is faithful from step 2 onward.** Step 1 (obtaining primes)
  swaps a dead 500 MB download for `factor`; everything after is Krumins' pipeline.
- **`sqlite3` is an oracle, not a subject.** Its job is to be an independent
  implementation that is allowed to disagree with you.
- **Read the articles on the host, type in the container.** All four live in this
  repo; open them in your viewer, run pipelines via `exec … su - learner`.

## Prerequisites

- **LXD or Incus initialised** — `incus admin init` (or `lxd init`). See the
  Phase-5 docs: [`START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- Outbound network from the container (to `apt`/`apk` the tools).

## Sources

Krumins' pages carry **no license statement**; ACCU's carry **"Copyright (c)
2018-2025 ACCU; all rights reserved."** All four are vendored byte-exact for
**offline educational reference** under
[`upstream-tutorial/`](upstream-tutorial/README.md) (provenance + `sha256` +
attribution).

- <https://catonmat.net/solving-google-treasure-hunt-prime-number-problem-four>
- <https://catonmat.net/set-operations-in-unix-shell>
- <https://catonmat.net/set-operations-in-unix-shell-simplified>
- <https://accu.org/journals/overload/15/80/guest_1410/>

**Series:** [1. relational algebra / SQL in the shell](../UNIX-relational-algebra-sql-in-the-shell/README.md)
→ **2. set operations in the shell** *(this lab)*.
Part 1 builds relations out of the algebra's six primitives; part 2 examines the
sets those relations are made of — and what happens when `sort` and `comm`
disagree about what "sorted" means.

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog.

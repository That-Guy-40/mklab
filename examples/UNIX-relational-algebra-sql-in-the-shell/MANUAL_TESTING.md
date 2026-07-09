# MANUAL_TESTING — captured transcripts

Real output from preparing and exercising this lab end-to-end on the host (Incus,
system containers), both distros. The environment is provisioned, then the
sandbox's `demo.sh` — the six primitive operations, straight from the two articles
— is run **as the `learner` user**. Trimmed only for length (package noise), never
edited.

`demo.sh` does not merely print pipelines: it ends with **nine equality checks**,
each asserting that two *independent implementations* of the same relational
expression return the same relation.

| Check | Debian 13 (glibc) | Alpine (musl) |
|---|---|---|
| `up` container | ✅ | ✅ |
| install bash + coreutils + gawk + sqlite3 | ✅ (gawk, sqlite3 new) | ✅ (bash, join, sqlite3 **all** new) |
| `awk` → gawk symlink | ✅ | ✅ |
| `learner` user, **bash** login | ✅ | ✅ |
| `demo.sh` runs | ✅ | ✅ |
| DIFFERENCE: Might's `difference` == `comm -23` | ✅ | ✅ |
| EQUIJOIN: Might's `equijoin` == `join(1)` | ✅ | ✅ |
| WORKED EXAMPLE == the article's published output | ✅ | ✅ |
| SELECTION / JOIN+PROJ / AGGREGATION == `sqlite3` | ✅ ✅ ✅ | ✅ ✅ ✅ |
| FIXED `cartesian -t` / `difference` / `equijoin -t` | ✅ ✅ ✅ | ✅ ✅ ✅ |
| **final verdict** | ✅ `PASS: all 9` | ✅ `PASS: all 9` |

Versions actually exercised:

| | Debian 13 (trixie) | Alpine 3.24 |
|---|---|---|
| bash | 5.2.37 | 5.3.9 (musl) |
| coreutils (`join`) | 9.7 | 9.11 |
| gawk | 5.2.1 | 5.3.2 |
| sqlite3 | 3.46.1 | 3.53.2 |
| grep | GNU 3.11 | GNU 3.12 |

The two `demo.sh` transcripts are **byte-identical except for a single line** —
and that line is the subject of erratum 2 (see [below](#the-one-line-that-differs)).
All nine checks, and the `PASS:` verdict, are identical.

---

## Debian 13 (trixie)

```
$ phase5-lxd/lab-lxd.sh up --config examples/UNIX-relational-algebra-sql-in-the-shell/relational-algebra-debian.toml
[info] launching container 'shell' as lab-relational-algebra-debian-shell (image=images:debian/13)
[info] ── lab 'relational-algebra-debian' up (1 incus instance(s), 0 skipped) ──

$ examples/UNIX-relational-algebra-sql-in-the-shell/setup-workshop.sh relational-algebra-debian/shell
==> [1/5] detecting distro in relational-algebra-debian/shell
    distro=debian
==> [2/5] installing bash + GNU coreutils + gawk + sqlite3
bash is already the newest version (5.2.37-2+b9).
coreutils is already the newest version (9.7-3).
The following NEW packages will be installed:
  gawk less libmpfr6 libreadline8t64 libsigsegv2 readline-common sqlite3
==> [3/5] creating the non-root 'learner' user (bash login)
==> [4/5] installing the ~/relational-algebra sandbox
==> [5/5] verifying the sandbox (as learner): run demo.sh
  whoami : learner
  bash   : GNU bash, version 5.2.37(1)-release (x86_64-pc-linux-gnu)
  join   : join (GNU coreutils) 9.7
  awk    : GNU Awk 5.2.1, API 3.2, PMA Avon 8-g1, (GNU MPFR 4.2.2, GNU MP 6.3.0)
  sqlite : 3.46.1 2024-08-13 09:16:08 (64-bit)
  --- running ~/relational-algebra/demo.sh ---

== 0. Unix is a bestiary of ad hoc databases: each line is a tuple ==
--- data/passwd  (colon-separated relation, as /etc/passwd is)
root:*:0:0:The Admin:/root:/bin/sh
matt:*:500:500:Matt:/home/matt:/bin/bash
john:*:501:501:John:/home/john:/bin/bash
bob:*:502:502:Bob:/home/bob:/bin/bash
--- data/employees.tsv  (tab-separated, with a header)
id	name	dept_id	salary
1	alice	10	95000
2	bob	20	87000
3	carol	10	102000
4	dave	30	78000
5	eve	20	91000

== 1. UNION (∪) = cat   ... and `sort -u` for true SET semantics ==
a b c d e f
--- a relation is a SET, so duplicates must go:  cat A A | sort -u
a b c

== 2. SELECTION (σ) = awk / grep   — keep the rows a predicate accepts ==
--- Might: accounts whose uid != gid  (against a realistic /etc/passwd)
sync:x:4:65534:sync:/bin:/bin/sync
games:x:5:60:games:/usr/games:/usr/sbin/nologin
man:x:6:12:man:/var/cache/man:/usr/sbin/nologin
--- Walsh: employees earning over 90000 (NR==1 keeps the header)
id	name	dept_id	salary
1	alice	10	95000
3	carol	10	102000
5	eve	20	91000
--- Walsh, as published:  grep -E '^(id|.*\tengineering)' departments.tsv
      (nothing — rc=1)
    ^ ERRATUM. Two independent bugs, so on GNU grep it prints NOTHING:
        (a) the header row is "dept_id", so ^id never matches it; and
        (b) POSIX ERE has no \t escape. GNU grep reads it as a literal "t",
            so ".*\tengineering" hunts for "...tengineering".
      Your grep decides: GNU 3.11 silently matches "t"; GNU 3.12 warns
      "stray \ before t"; BusyBox grep and ugrep DO treat \t as a tab.
      An empty result never says which of those just happened to you.
    Working spelling, portable — the POSIX [[:blank:]] class:
dept_id	dept_name	location
10	engineering	sf

== 3. PROJECTION (π) = cut   — keep columns, discard the rest ==
--- Might: cut -d ":" -f 1,7   (name and shell)
root:/bin/bash
daemon:/usr/sbin/nologin
[...]
--- cut cannot REORDER columns; awk can:  awk -F":" "{ print $7 ":" $1 }"
/bin/sh:root
/bin/bash:matt
/bin/bash:john
/bin/bash:bob

== 4. RENAME (ρ) = nothing to do   — Unix columns are named positionally ==

== 5. CARTESIAN PRODUCT (×) = the one primitive Unix never shipped ==
--- `paste -d "," f1 f2` joins CORRESPONDING lines — NOT a product:
a,d
b,e
c,f
--- `cartesian f1 f2` is the real 3x3 product (Might, verbatim):
a,d a,e a,f b,d b,e b,f c,d c,e c,f
--- ERRATUM: `cartesian -t` is broken under its own #!/bin/bash shebang —
    bash's echo does not expand \t, so the delimiter is a literal backslash-t:
a\td$
    the working spelling passes a real tab:  -d "$(printf '\t')"
a^Id$

== 6. DIFFERENCE (−): Might`s O(n*m) script  vs  comm -23 (linear, sorted) ==
--- difference data/passwd kill.db   (rescans kill.db per line: quadratic)
root:*:0:0:The Admin:/root:/bin/sh
john:*:501:501:John:/home/john:/bin/bash
--- comm -23 <(sort passwd) <(sort kill.db)   (stream-merge: linear)
john:*:501:501:John:/home/john:/bin/bash
root:*:0:0:The Admin:/root:/bin/sh
--- `diff` is NOT set difference: it reports an edit script, not a relation.
   [ok]  DIFFERENCE: Might's difference(3)  ==  comm -23

== 7. INTERSECTION (∩) = comm -12   — derived, not primitive:  A ∩ B = A − (A − B) ==
bob:*:502:502:Bob:/home/bob:/bin/bash
matt:*:500:500:Matt:/home/matt:/bin/bash

== 8. EQUIJOIN (⋈): product + selection   —   Might`s equijoin  vs  join(1) ==
--- Might: equijoin emp dept 3 1   (builds the whole product, then selects)
alice	engineering
bob	sales
carol	engineering
dave	support
eve	sales
--- native: join -t$TAB -1 3 -2 1   (streams two sorted inputs)
alice	engineering
bob	sales
carol	engineering
dave	support
eve	sales
--- ERRATUM (Walsh): under the heading "SELECT e.name, d.dept_name" he pipes
    join to `cut -f2,4`. join emits  dept_id,id,name,salary,dept_name,location
    so -f2,4 projects id+salary. The stated SQL needs -f3,5. As published:
      1	95000
      2	87000
      3	102000
      4	78000
      5	91000
   [ok]  EQUIJOIN: Might's equijoin(3)  ==  join(1)

== 9. AGGREGATION (GROUP BY) — NOT relational algebra, but what you always want ==
--- headcount per dept:  cut -f3 | sort | uniq -c
      2 10
      2 20
      1 30
--- count + mean salary per dept, via awk associative arrays
10	2	98500
20	2	89000
30	1	78000

== 10. Might's worked example: delete a list of bad users, relationally ==
--- bad.db:
matt bob
--- 1) product:  cartesian -d ":" bad.db passwd
matt:root:*:0:0:The Admin:/root:/bin/sh
matt:matt:*:500:500:Matt:/home/matt:/bin/bash
matt:john:*:501:501:John:/home/john:/bin/bash
    ... (8 rows = 2 x 4)
--- 2) select:   awk -F: "{ if ( $1 == $2 ) print }"
matt:matt:*:500:500:Matt:/home/matt:/bin/bash
bob:bob:*:502:502:Bob:/home/bob:/bin/bash
--- 3) project:  cut -d ":" -f2-
matt:*:500:500:Matt:/home/matt:/bin/bash
bob:*:502:502:Bob:/home/bob:/bin/bash
--- 4) difference passwd kill.db  ->  the new password file:
root:*:0:0:The Admin:/root:/bin/sh
john:*:501:501:John:/home/john:/bin/bash
   [ok]  WORKED EXAMPLE: output == the article's published output

== 11. The SQL oracle: sqlite3 must agree with the pipelines ==
--- σ  WHERE salary > 90000
alice	95000
carol	102000
eve	91000
   [ok]  SELECTION:   awk  ==  SQL WHERE
--- ⋈ + π  JOIN ... ON e.dept_id = d.dept_id, project (name, dept_name)
   [ok]  JOIN+PROJ:   join(1) | cut -f3,5  ==  SQL JOIN
--- GROUP BY dept_id: COUNT(*), AVG(salary)
   [ok]  AGGREGATION: awk arrays  ==  SQL GROUP BY

== 12. The corrected scripts: bin/fixed/ — same algebra, without the papercuts ==
bin/       = the article's code, verbatim (the object of study)
bin/fixed/ = drop-in corrected versions.   diff -u bin/x bin/fixed/x

--- the QUIET failure: the original `equijoin -t` on TSV finds ZERO rows,
    because its delimiter is a literal backslash-t that matches nothing:
    original -> 0 row(s)
    fixed    -> 5 row(s)
    An empty result reads as "nothing matched", not as "your delimiter is wrong".
--- `cartesian -t` now emits a real tab (first row, cat -A):
a^Id$
   [ok]  FIXED cartesian: -t  ==  -d $'\t'
   [ok]  FIXED difference: == the verbatim original
   [ok]  FIXED equijoin -t: == join(1)

== VERDICT ==
Four independent implementations of the same algebra — a 2010 bash script,
its corrected twin, coreutils, and an SQL engine — over the same relations.

PASS: all 9 relational identities hold (Might's scripts == coreutils == SQL)
==> done.  Relational-shell sandbox ready in relational-algebra-debian/shell.
```

---

## Alpine

```
$ phase5-lxd/lab-lxd.sh up --config examples/UNIX-relational-algebra-sql-in-the-shell/relational-algebra-alpine.toml
[info] resolved images:alpine/latest → images:alpine/3.24
[info] ── lab 'relational-algebra-alpine' up (1 incus instance(s), 0 skipped) ──

$ examples/UNIX-relational-algebra-sql-in-the-shell/setup-workshop.sh relational-algebra-alpine/shell
==> [1/5] detecting distro in relational-algebra-alpine/shell
    distro=alpine
==> [2/5] installing bash + GNU coreutils + gawk + sqlite3
==> [3/5] creating the non-root 'learner' user (bash login)
==> [4/5] installing the ~/relational-algebra sandbox
==> [5/5] verifying the sandbox (as learner): run demo.sh
  whoami : learner
  bash   : GNU bash, version 5.3.9(1)-release (x86_64-alpine-linux-musl)
  join   : join (GNU coreutils) 9.11
  awk    : GNU Awk 5.3.2, API 4.0
  sqlite : 3.53.2 2026-06-03 19:12:13 (64-bit)
  --- running ~/relational-algebra/demo.sh ---

[ ... sections 0-12 identical to the Debian transcript above, except the one
      line noted below ... ]

   [ok]  DIFFERENCE: Might's difference(3)  ==  comm -23
   [ok]  EQUIJOIN: Might's equijoin(3)  ==  join(1)
   [ok]  WORKED EXAMPLE: output == the article's published output
   [ok]  SELECTION:   awk  ==  SQL WHERE
   [ok]  JOIN+PROJ:   join(1) | cut -f3,5  ==  SQL JOIN
   [ok]  AGGREGATION: awk arrays  ==  SQL GROUP BY
   [ok]  FIXED cartesian: -t  ==  -d $'\t'
   [ok]  FIXED difference: == the verbatim original
   [ok]  FIXED equijoin -t: == join(1)

== VERDICT ==
PASS: all 9 relational identities hold (Might's scripts == coreutils == SQL)
==> done.  Relational-shell sandbox ready in relational-algebra-alpine/shell.
```

### The one line that differs

Diffing the two 174-line `demo.sh` transcripts:

```
$ diff -u debian.demo alpine.demo
@@ -28,7 +28,7 @@
  --- Walsh, as published:  grep -E '^(id|.*\tengineering)' departments.tsv
-      (nothing — rc=1)
+      grep: warning: stray \ before t
```

That is the *entire* difference — Alpine's GNU grep 3.12 warns where Debian's 3.11
is silent. Both find nothing, both `PASS`. The lab's subject matter is also its
only cross-base divergence, which is a pleasing accident.

---

## Documented errata: three published commands that don't do what they say

Both articles were **executed**, not just read. All three failures are **silent**.

### 1. Walsh's join projects the wrong columns

Under the heading `SELECT e.name, d.dept_name`, the article pipes `join` to
`cut -f2,4`. But `join -1 3 -2 1` emits the **join key first**, then the rest of
file 1, then the rest of file 2:

```
$ join -t$'\t' -1 3 -2 1 <(...) <(...) | head -1 | awk -F'\t' '{for(i=1;i<=NF;i++) printf "  f%d=%s\n", i, $i}'
  f1=10            <- dept_id (the join key)
  f2=3             <- id
  f3=carol         <- name
  f4=102000        <- salary
  f5=engineering   <- dept_name
  f6=sf            <- location

$ ... | cut -f2,4      # as published -> id, salary
3	102000
$ ... | cut -f3,5      # what the stated SQL asks for -> name, dept_name
carol	engineering
```

### 2. Walsh's grep selection: one command, three behaviours

```
--- Debian 13, GNU grep 3.11:
    grep (GNU grep) 3.11
    (no output, rc=1)
    does \t match a literal t?  YES (so \t == t)

--- Alpine, GNU grep 3.12:
    grep (GNU grep) 3.12
    grep: warning: stray \ before t

--- Alpine, BusyBox grep (still installed alongside):
    10	engineering	sf
```

Two independent bugs: the header row is `dept_id`, so `^id` never matches it; and
**POSIX ERE has no `\t` escape**. GNU grep treats `\t` as a literal `t` (3.11
silently, 3.12 with a warning), so `.*\tengineering` hunts for `…tengineering`
and matches nothing. BusyBox grep — and ugrep — *do* read `\t` as a tab, so the
same command "works" for them.

The portable spelling uses a POSIX character class:

```
$ grep -E '^(dept_id|.*[[:blank:]]engineering)' data/departments.tsv
dept_id	dept_name	location
10	engineering	sf
```

> **Trap for the reviewer, not just the reader.** While verifying this, the host's
> `grep` turned out to be a shell function wrapping **ugrep 7.5.0**, which *does*
> honour `\t` — so the first interactive test "proved" the opposite of the truth.
> Only running it inside a clean container (and non-interactively, where the
> function doesn't exist) gave the real GNU behaviour. Ground-truth your tools.

### 3. Might's `-t` flag emits a literal backslash-t

The script sets `delim="\t"` and emits it with `echo`, under a `#!/bin/bash`
shebang. **bash's `echo` does not expand escapes** (dash's and ash's do), so:

```
  original cartesian -t (first row, cat -A):
      a\td$
  fixed    cartesian -t (first row, cat -A):
    a^Id$
```

`^I` is a tab; `\t` is two characters. `equijoin` inherits the same bug, where it
is far nastier because it fails **quietly** — the delimiter matches nothing, every
field collapses into `$1`, and the equality test never fires:

```
  original equijoin -t on TSV -> 0 row(s)
  fixed    equijoin -t on TSV -> 5 row(s)
```

An empty result set reads as *"nothing matched"*, not as *"your delimiter is
wrong"*. This is why the lab ships `bin/fixed/` alongside the verbatim `bin/`.

---

## Documented divergence: neither base ships what the articles assume

The articles assume **bash**, **GNU coreutils** (`join`!), **gawk** and
**sqlite3**. Captured on **bare** containers, before `setup-workshop.sh` ran:

```
=== which tools exist on a BARE Alpine? ===
  bash    -> MISSING
  join    -> MISSING
  comm    -> /usr/bin/comm      (BusyBox applet)
  sqlite3 -> MISSING
  awk     -> /usr/bin/awk       (BusyBox applet)

=== does BusyBox itself provide join / comm? ===
  applet: comm
  applet: cut
  applet: paste
  applet: sort
  applet: uniq
  (join absent above => BusyBox has no join applet)

=== bare Debian ===
  bash    -> /usr/bin/bash
  join    -> /usr/bin/join
  gawk    -> MISSING           (default awk is mawk 1.3.4)
  sqlite3 -> MISSING
```

A `#!/bin/bash` script on bare Alpine fails with a famously misleading message —
the script is right there; it is the **interpreter** that is missing:

```
$ printf '#!/bin/bash\necho alive\n' > /tmp/s; chmod +x /tmp/s; /tmp/s
sh: /tmp/s: not found
```

### The surprise that runs the other way

Every one of these labs documents Alpine as the impoverished base. Not here.
Debian's `/bin/sh` is **dash**, which has **no process substitution** — the very
syntax `comm -23 <(sort A) <(sort B)` is always written in. Alpine's BusyBox
**ash has it** (a bash-compat extension, with `/dev/fd` present):

```
  Debian /bin/sh (dash) : /bin/sh: 1: Syntax error: "(" unexpected
  Alpine /bin/sh (ash)  : OK
```

BusyBox ash also accepts `$'\t'` and `[[ ]]`, though **not** `${x^^}`
(`bad substitution`) — the same boundary the
[bash-by-example lab](../shell-intermediate-programming-by-example/README.md)
found. The lab installs real `bash` on both bases anyway, because Might's scripts
declare `#!/bin/bash` and it costs one package.

### After provisioning: who provides what

```
=== Alpine, after setup-workshop.sh ===
  bash     -> /bin/bash
  join     -> /usr/bin/join          (GNU coreutils 9.11 — BusyBox had none)
  comm     -> /usr/bin/comm
  awk      -> /usr/local/bin/awk  ->  /usr/bin/gawk
  grep     -> /bin/grep              (GNU grep 3.12, over the BusyBox applet)
  sqlite3  -> /usr/bin/sqlite3
```

After this step every pipeline in both articles runs identically on glibc and
musl — which is exactly what the nine checks assert, on both bases.

The one thing that makes byte-identical output possible across the two libcs is a
single line at the top of `demo.sh`:

```sh
export LC_ALL=C
```

A relation is a **set**, so comparing two of them means canonicalizing order with
`sort` — and `sort`'s collation is locale-dependent. Without `LC_ALL=C`, glibc and
musl order the rows differently, `join` and `comm` silently drop rows on input they
consider unsorted, and every check fails. It is also *why* `join` and `comm` demand
sorted input in the first place: they stream-merge.

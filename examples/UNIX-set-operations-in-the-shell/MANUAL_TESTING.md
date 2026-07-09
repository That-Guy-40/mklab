# MANUAL_TESTING — captured transcripts

Real output from preparing and exercising this lab end-to-end on the host (Incus,
system containers), both distros. The environment is provisioned, then the
sandbox's `demo.sh` and `treasure-hunt.sh` are run **as the `learner` user**.
Trimmed only for length (package noise), never edited.

`demo.sh` does not merely print pipelines: it runs **28 equality checks**, each
asserting that two *independent implementations* of the same set expression return
the same set — merge (`comm`) vs count (`uniq`) vs hash (`awk`) vs `sqlite3`.

| Check | Debian 13 (glibc) | Alpine (musl) |
|---|---|---|
| `up` container | ✅ | ✅ |
| install bash + coreutils + gawk + perl + sqlite3 | ✅ (gawk, sqlite3, busybox new) | ✅ (bash, join, perl, sqlite3 **all** new) |
| `awk` → gawk symlink | ✅ | ✅ |
| `learner` user, **bash** login | ✅ | ✅ |
| `demo.sh` — 28 checks | ✅ `PASS: all 28` | ✅ `PASS: all 28` |
| MEMBERSHIP / UNION (3) | ✅ | ✅ |
| INTERSECTION — 5 recipes, 3 algorithms | ✅ | ✅ |
| COMPLEMENT (4) / SYMDIFF (3) | ✅ | ✅ |
| SUBSET / EQUALITY / CARDINALITY / DISJOINT / MIN / MAX | ✅ | ✅ |
| CARTESIAN PRODUCT / POWER SET | ✅ | ✅ |
| Guest's Apache-log intersection | ✅ | ✅ |
| LANDMINE: `comm` + `sort -n` loses the intersection | ✅ | ✅ |
| `treasure-hunt.sh` → **7830239**, prime | ✅ | ✅ |
| **byte-identical demo output across bases** | ✅ | ✅ |

Versions actually exercised:

| | Debian 13 (trixie) | Alpine 3.24 |
|---|---|---|
| bash | 5.2.37 | 5.3.9 (musl) |
| coreutils (`comm`) | 9.7 | 9.11 |
| gawk | 5.2.1 | 5.3.2 |
| perl | v5.40.1 | v5.42.2 |
| sqlite3 | 3.46.1 | 3.53.2 |

Both 119-line `demo.sh` transcripts are **byte-identical**, and so are the
`treasure-hunt.sh` transcripts. Installing `busybox` on Debian is what makes the
BusyBox-vs-GNU contrast (and therefore the output) the same on both bases.

---

## Debian 13 (trixie)

```
$ phase5-lxd/lab-lxd.sh up --config examples/UNIX-set-operations-in-the-shell/set-operations-debian.toml
[info] ── lab 'set-operations-debian' up (1 incus instance(s), 0 skipped) ──

$ examples/UNIX-set-operations-in-the-shell/setup-workshop.sh set-operations-debian/shell
==> [1/5] detecting distro in set-operations-debian/shell
    distro=debian
==> [2/5] installing bash + GNU coreutils + gawk + perl + sqlite3 + busybox
==> [3/5] creating the non-root 'learner' user (bash login)
==> [4/5] installing the ~/set-operations sandbox
==> [5/5] verifying the sandbox (as learner): demo.sh, then treasure-hunt.sh
  whoami : learner
  bash   : GNU bash, version 5.2.37(1)-release (x86_64-pc-linux-gnu)
  comm   : comm (GNU coreutils) 9.7
  awk    : GNU Awk 5.2.1, API 3.2, PMA Avon 8-g1, (GNU MPFR 4.2.2, GNU MP 6.3.0)
  perl   : perl v5.40.1
  sqlite : 3.46.1 2024-08-13 09:16:08 (64-bit)
  --- running ~/set-operations/demo.sh ---

== 0. A set is a file: one element per line ==
--- data/A and data/B (Krumins hand-crafted these so 1,2,3 are in common)
    A=3   B=11
    A=5   B=1
    A=1   B=12
    A=2   B=3
    A=4   B=2

== 1. MEMBERSHIP  (a ∈ A)  —  grep -xq   vs   awk ==
    grep -xc 4   A -> 1
    grep -xc 999 A -> 0
   [ok]  MEMBERSHIP:  grep -xq  ==  awk

== 2. UNION  (A ∪ B)  —  cat is union; sort -u makes it a SET again ==
--- cat A B  (a multiset: 1, 2 and 3 appear twice)
3 5 1 2 4 11 1 12 3 2
--- sort -u A B
1 11 12 2 3 4 5
   [ok]  UNION:        sort -u  ==  awk '!a[$0]++'
   [ok]  UNION:        sort -u  ==  SQL UNION

== 3. INTERSECTION  (A ∩ B)  —  five recipes, three different algorithms ==
    comm -12          : 1 2 3
    sort | uniq -d    : 1 2 3
    uniq -c '$1==2'   : 1 2 3
    grep -xF -f       : 1 2 3
    awk hash          : 1 2 3
   [ok]  INTERSECTION: comm(merge)  ==  uniq -d(count)
   [ok]  INTERSECTION: comm(merge)  ==  uniq -c(Guest)
   [ok]  INTERSECTION: comm(merge)  ==  grep -xF(hash)
   [ok]  INTERSECTION: comm(merge)  ==  awk(hash)
   [ok]  INTERSECTION: comm(merge)  ==  SQL INTERSECT

== 4. COMPLEMENT  (A − B)  —  comm, grep, the sort B B A trick, awk ==
    comm -23              : 4 5
    grep -vxF -f B A      : 4 5
    sort B B A | uniq -u  : 4 5
   [ok]  COMPLEMENT:   comm -23  ==  grep -vxF
   [ok]  COMPLEMENT:   comm -23  ==  sort B B A|uniq -u
   [ok]  COMPLEMENT:   comm -23  ==  awk hash
   [ok]  COMPLEMENT:   comm -23  ==  SQL EXCEPT

== 5. SYMMETRIC DIFFERENCE  (A △ B)  =  (A−B) ∪ (B−A) ==
    comm -3 | tr -d       : 11 12 4 5
    sort A B | uniq -u    : 11 12 4 5
   [ok]  SYMDIFF:      comm -3  ==  uniq -u
   [ok]  SYMDIFF:      comm -3  ==  grep pair
   [ok]  SYMDIFF:      comm -3  ==  SQL EXCEPT/UNION

== 6. SUBSET, EQUALITY, CARDINALITY, DISJOINT, EMPTY, MIN, MAX ==
    Asub ⊆ A ? yes        Anotsub ⊆ A ? no
   [ok]  SUBSET:       comm  ==  awk  ==  SQL (empty EXCEPT)
    Aequal = Bequal ? yes     A = B ? no
   [ok]  EQUALITY:     diff -q on sorted sets
    |A| = 5
   [ok]  CARDINALITY:  wc -l  ==  awk NR  ==  SQL COUNT
    A ∩ B = Ø ? no        Anotsub ∩ A = Ø ? yes
   [ok]  DISJOINT:     intersection-is-empty test
    empty? Ø:yes A:no      min(A)=1  max(A)=5
   [ok]  EMPTY/MIN/MAX: head/tail  ==  SQL MIN/MAX

== 7. CARTESIAN PRODUCT (A × B)  and  POWER SET (2^A) ==
    |A × B| = 25   (must be |A|·|B| = 25)
   [ok]  PRODUCT:      bash loops  ==  awk
   [ok]  PRODUCT:      bash loops  ==  SQL CROSS JOIN
    |A|=5  so |P(A)| must be 2^5 = 32   (bash: 32, perl: 32)
   [ok]  POWER SET:    |P(A)| = 2^|A|, bash and perl agree

== 8. Guest's real problem: which IP addresses hit BOTH Apache logs? ==
    |IP1| = 6   |IP2| = 5
--- his count-based intersection: sort -m | uniq -c | grep "^ *2" | tr -s " " | cut -f3 -d" "
      12.30.66.226
      65.214.44.29
      74.6.87.40
   [ok]  APACHE LOGS:  Guest's uniq -c  ==  comm -12  ==  awk
   [ok]  APACHE LOGS:  comm -12  ==  awk hash
--- and his point about ordering: lexicographic sort is not natural for IPs
      sort    : 12.30.66.226 122.152.128.49 58.167.213.128 65.214.44.29 74.6.86.212 74.6.87.40
      sort -V : 12.30.66.226 58.167.213.128 65.214.44.29 74.6.86.212 74.6.87.40 122.152.128.49

== 9. THE LANDMINE:  comm merges BYTE-wise, so `sort -n` breaks it ==
    P = {1, 9, 10}    Q = {10}    so  P ∩ Q  =  {10}
    bin/setops       (article's sort -n)   -> ''   <-- EMPTY. WRONG.
    bin/fixed/setops (lexicographic sort)  -> '10 '
    sqlite3 INTERSECT                      -> '10 '
    comm walks 1 < 9 < 10 expecting 1 < 10 < 9, runs off the end, finds nothing.
   [ok]  LANDMINE:     published comm+sort -n loses the intersection
   [ok]  LANDMINE:     fixed  ==  SQL INTERSECT  ==  {10}
--- why nobody noticed: on Krumins own A and B, both spellings agree
    published -> '1 2 3 '
    fixed     -> '1 2 3 '
   [ok]  LANDMINE:     both agree on the article's toy sets (1 2 3)

== 10. The other published commands that do not do what they say ==
--- Krumins, Union:  "$ set -um set1 set2"   (a typo for `sort -um`)
    rc=0, printed nothing, and nounset is now: ON
    In bash, `set -u -m` is a SHELL BUILTIN: it enables nounset and assigns $1/$2.
--- Krumins, Symmetric Difference:  comm -3 <(sort -n A) >(sort -n B)
    running it with a 3s timeout ... HUNG (rc=124).  >(...) is an OUTPUT process substitution.
--- Krumins, Maximum:  the prose says `tail -1`, the example runs `head -1`
    head -1 <(sort -n A) = 1
    tail -1 <(sort -n A) = 5
--- Krumins, cheat sheet, Subset Test:  awk ... { if !($0 in a) exit 1 }
    awk: cmd. line:1: NR==FNR { a[$0]; next } { if !($0 in a) exit 1 }
    awk: cmd. line:1:                              ^ syntax error
    ^ awk requires parentheses:  if (!($0 in a))
--- Guest, intersection filter:  grep "^ *2"  on a MULTISET
         20 many
          2 twice
    ^ "many" has count 20, and "^ *2" matches the 2 in 20.  Use awk '$1==2'.
--- Guest, natural IP ordering:  sort -t. +0n -1n +1n -2n +2n -3n +3n
    GNU sort still accepts the obsolete +POS -POS keys.
    busybox sort REJECTS them (invalid option -- 1). Use -k1,1n … or sort -V.

== VERDICT ==
Three algorithm families — merge (comm), count (uniq), hash (awk) — plus an
SQL engine, over the same sets. Where they disagree, someone is wrong.

PASS: all 28 set identities hold (merge == count == hash == SQL)

  --- running ~/set-operations/treasure-hunt.sh ---
== Google Treasure Hunt 2008, Puzzle 4 ==
   smallest prime that is a sum of 7, 17, 41 AND 541 consecutive primes

[1/4] generating primes <= 1200000 with coreutils `factor`
      92938 primes, largest 1199999
[2/4] sliding-window sums of N consecutive primes, keeping those <= 8000000
      sums of   7 consecutive primes:  88798 kept (max 7999977, overshoot 8399675)
      sums of  17 consecutive primes:  39268 kept (max 7999995, overshoot 20398159)
      sums of  41 consecutive primes:  17564 kept (max 7999615, overshoot 49189471)
      sums of 541 consecutive primes:   1462 kept (max 7996397, overshoot 647147589)
      every window overshoots the cap => the four sum files are COMPLETE below it
[3/4] four-way intersection, his pipeline:  sort -nm | uniq -d
      candidates: 7830239
[4/4] take the smallest candidate and test primality with `factor`
      factor 7830239 -> 7830239: 7830239
      it is prime.

== The same intersection, done the way his ARTICLE recommends ==
   article: 'if you have a numeric set, then sort must take -n option'
            comm -12 <(sort -n set1) <(sort -n set2)
   step 1 (comm + sort -n)  -> 0 elements
   ground truth (awk hash)  -> 9 elements
   final answer             -> ''

   comm merges BYTE-wise. Fed 'sort -n' order it walks off the end of a file
   and reports no match -- no error, exit status 0, just a missing answer.
   Used correctly (lexicographic sort), comm gets it right:
   comm + lexicographic sort -> '7830239 '

PASS: puzzle 4 answer is 7830239 (prime, and a sum of 7, 17, 41 and 541 consecutive primes);
      his sort -nm|uniq -d pipeline finds it, his article's comm+sort -n recipe does not

==> done.  Set-operations sandbox ready in set-operations-debian/shell.
```

---

## Alpine

```
$ phase5-lxd/lab-lxd.sh up --config examples/UNIX-set-operations-in-the-shell/set-operations-alpine.toml
[info] resolved images:alpine/latest → images:alpine/3.24
[info] ── lab 'set-operations-alpine' up (1 incus instance(s), 0 skipped) ──

$ examples/UNIX-set-operations-in-the-shell/setup-workshop.sh set-operations-alpine/shell
==> [1/5] detecting distro in set-operations-alpine/shell
    distro=alpine
==> [2/5] installing bash + GNU coreutils + gawk + perl + sqlite3 + busybox
==> [3/5] creating the non-root 'learner' user (bash login)
==> [4/5] installing the ~/set-operations sandbox
==> [5/5] verifying the sandbox (as learner): demo.sh, then treasure-hunt.sh
  whoami : learner
  bash   : GNU bash, version 5.3.9(1)-release (x86_64-alpine-linux-musl)
  comm   : comm (GNU coreutils) 9.11
  awk    : GNU Awk 5.3.2, API 4.0
  perl   : perl v5.42.2
  sqlite : 3.53.2 2026-06-03 19:12:13 (64-bit)
  --- running ~/set-operations/demo.sh ---

[ ... all 119 lines BYTE-IDENTICAL to the Debian transcript above ... ]

PASS: all 28 set identities hold (merge == count == hash == SQL)

  --- running ~/set-operations/treasure-hunt.sh ---
[ ... byte-identical ... ]
PASS: puzzle 4 answer is 7830239 (prime, and a sum of 7, 17, 41 and 541 consecutive primes);
      his sort -nm|uniq -d pipeline finds it, his article's comm+sort -n recipe does not

==> done.  Set-operations sandbox ready in set-operations-alpine/shell.
```

Verified mechanically:

```
$ diff -u debian.demo alpine.demo && echo IDENTICAL
IDENTICAL                                  # 119 lines each
$ diff -q debian.treasure alpine.treasure && echo IDENTICAL
IDENTICAL
```

The single line that made this possible is at the top of `demo.sh`:
`export LC_ALL=C`. Without it, glibc and musl order the sets differently, `comm`
silently drops rows on input it considers unsorted, and the checks fail.

---

## Documented errata: eight published commands that don't do what they say

All four pages were **executed**, not just read. Every failure below is silent.

### 1. `comm` merges byte-wise — `sort -n` breaks it

The article says, repeatedly, *"if you have a numeric set, then `sort` must take
`-n` option"*. For `comm` and `join`, that is backwards:

```
  P={1,9,10}  Q={10}   ->  P ∩ Q must be {10}
    comm -12 <(sort -n P) <(sort -n Q)  =    <-- EMPTY. WRONG.
    comm -12 <(sort   P) <(sort   Q)  = 10   <-- correct

  And his SUBSET TEST, same trap:  is {10} a subset of {1,9,10}? (yes)
    comm -23 <(sort -n Q|uniq) <(sort -n P|uniq) | head -1  -> '10'  <-- 'not a subset'. WRONG.
    comm -23 <(sort   Q|uniq) <(sort   P|uniq) | head -1  -> ''    <-- is a subset. correct.
```

`join` has the identical assumption, and at least says so out loud:

```
$ join <(sort -n X2) <(sort -n Y2)
join: /dev/fd/63:3: is not sorted: 10
join: /dev/fd/62:2: is not sorted: 10
2
10
join: input is not in sorted order
```

`comm` warns too — sometimes — but **exit status stays 0**, and in a pipeline the
warning goes to stderr where nobody reads it.

#### The article's recipe destroys the puzzle that inspired the article

Krumins' Treasure Hunt solution intersects four files of prime sums. His *puzzle*
used `sort -nm … | uniq -d`. His *article* recommends `comm` with `sort -n`. Run
both against the same data:

```
4-way intersect, his puzzle pipeline  (sort -nm | uniq -d) -> 7830239
4-way intersect, his article's recipe (comm + sort -n)     -> (empty)
4-way intersect, comm used correctly  (comm + sort)        -> 7830239

step 1 alone:  comm + sort -n -> 0 elements
               awk hash       -> 9 elements   (ground truth)

why:  sort -n head: 978042 981957 985873
      sort    head: 1001563 1005493 1009441
```

The **count** family (`uniq -d`, `uniq -u`, `uniq -c`) is immune, because `uniq`
only requires equal lines to be **adjacent**, which any consistent order provides.
The **merge** family (`comm`, `join`, `sort -m`) is not.

### 2. `set -um set1 set2` is not `sort -um`

```
$ ( set -um A B; echo "rc=$? \$1=$1 \$2=$2 nounset=$(shopt -o -q nounset && echo ON || echo off)" )
    rc=0 ; $1=A $2=B ; nounset now: ON
```

`set` is a bash **builtin**. `set -u -m` enables `nounset` and job control, assigns
the positional parameters, prints nothing, and returns 0. The union never happens.

### 3. `>(...)` is an *output* process substitution — it hangs

```
$ timeout 5 bash -c 'comm -3 <(sort -n A) >(sort -n B)'
    rc=124 (124 = hung)
```

`comm` is handed a write-only pipe to read from, and waits forever. The article's
symmetric-difference *test run* uses `>(sort -n B)` where its own recipe (two
lines above) correctly says `<(sort set2)`.

### 4. The "Maximum" example runs `head -1`

```
    head -1 <(sort -n A) = 1        <-- this is the MINIMUM
    tail -1 <(sort -n A) = 5        <-- this is the maximum
```

The prose says `tail -1 <(sort set)`. The worked example types `head -1
<(sort -n Abig)` and prints `4294906714` — which is what `tail` would return.

### 5. The cheat sheet's subset test has never run

```
$ gawk 'NR==FNR { a[$0]; next } { if !($0 in a) exit 1 }' P Q
    gawk: cmd. line:1: NR==FNR { a[$0]; next } { if !($0 in a) exit 1 }
    gawk: cmd. line:1:                              ^ syntax error
    rc=1

$ gawk 'NR==FNR { a[$0]; next } !($0 in a) { exit 1 }' P Q     # corrected
    rc=0 (0 = Q is a subset of P)
```

`awk` requires `if (!(...))`. The published line is a syntax error, so it "returns
1" — which the cheat sheet reads as *"not a subset"* — for **every** input.

### 6. The Cartesian product is `set2 × set1`

```
while read a; do while read b; do echo "$a, $b"; done < set1; done < set2
                                                      ^^^^        ^^^^
```

The **inner** loop reads `set1`, so the outer element (from `set2`) is printed
first. The article calls it `A × B`.

### 7. The perl power set has no separator

```
    set {1,2,12} -> perl powerset lines:
      []  [12]  [2]  [212]  [1]  [112]  [12]  [1212]
    ^^ which line is {1,2} and which is {12}? Both print as '12'.

    distinct lines: 7 of 8   <-- collision!
```

`print @$p` concatenates with no separator. One character fixes it —
`print "@$p"` — after which all 8 subsets are distinct. See
[`bin/fixed/powerset.pl`](bin/fixed/powerset.pl).

The bash power set is sound, with one cosmetic wart: singleton subsets print with
a **trailing space** (`"a "`), because the recursion always emits `"$1 $r"` and
`$r` is empty at the base case.

### 8. `grep "^ *2"` over-matches on multisets

```
  sort M | uniq -c :
         20 many
          1 once
          2 twice
  Guest's filter  grep '^ *2'  (wants elements seen exactly twice):
         20 many
          2 twice
    ^^ 'many' (count 20) matched too -- ^ *2 matches the '2' of '20'.
  correct: anchor the count, e.g. awk '$1==2'
          2 twice
```

Guest states the precondition — the inputs are **sets**, so counts are 1 or 2 —
and within that precondition the recipe is correct. It is the *reuse* on a
multiset that bites, and it bites silently.

### 9 (soft). Guest's obsolete `sort` key syntax

```
  plain GNU sort            : accepted
  POSIXLY_CORRECT=1         : accepted
  _POSIX2_VERSION=200809    : accepted
  busybox sort              : sort: invalid option -- '1'
```

`sort -t. +0n -1n +1n -2n +2n -3n +3n` uses the obsolete POSIX `+POS -POS` key
form. GNU `sort` still honours it — I expected it to fail and it did not. **BusyBox
`sort` rejects it outright.** Modern spelling: `sort -t. -k1,1n -k2,2n -k3,3n
-k4,4n`, or `sort -V`.

> **Trap for the reviewer, not just the reader.** While checking erratum 9 the
> host's `grep` turned out to be a shell function wrapping **ugrep**, which made an
> earlier check report the opposite of GNU's behaviour. Every claim above was
> re-run **inside a clean container**, non-interactively. Ground-truth your tools.

### Quoted, never executed

Guest's article contains, under the heading *"Don't try this at home!"*:

```sh
# Don't try this at home!
$ rm -rf $TEMP_WORK_DIR/*
```

as a deliberate illustration of shell scripts not failing safely when a variable
is unset. It appears in the vendored archive and in prose here. It is **not
present in any script in this lab** and is never executed. That is his point.

---

## Documented divergence: neither base ships what the articles assume

Captured on **bare** containers, before `setup-workshop.sh` ran:

```
--- alpine:
    bash     -> MISSING
    join     -> MISSING
    comm     -> /usr/bin/comm      (BusyBox applet)
    uniq     -> /usr/bin/uniq      (BusyBox applet)
    factor   -> /usr/bin/factor    (BusyBox has factor!)
    awk      -> /usr/bin/awk       (BusyBox applet)
    gawk     -> MISSING
    sqlite3  -> MISSING
    perl     -> MISSING
    busybox  -> /bin/busybox

--- debian:
    bash     -> /usr/bin/bash
    join     -> /usr/bin/join
    comm     -> /usr/bin/comm
    factor   -> /usr/bin/factor
    awk      -> /usr/bin/awk       (mawk 1.3.4)
    gawk     -> MISSING
    sqlite3  -> MISSING
    perl     -> /usr/bin/perl
    busybox  -> MISSING
```

BusyBox genuinely has **no `join` applet**, though it does have `factor`:

```
$ busybox --list | grep -x -E "join|comm|uniq|sort|factor"
    applet: comm
    applet: factor
    applet: sort
    applet: uniq
    (join absent above => BusyBox never had it)
$ join --version | head -1        # after apk add coreutils
join (GNU coreutils) 9.11
```

### The surprise that runs the other way

Every `comm` recipe in both articles is written with `<(...)`. Debian's `/bin/sh`
is **dash**, which cannot parse it. Alpine's BusyBox **ash can**:

```
  debian  /bin/sh -> /bin/sh: 1: Syntax error: "(" unexpected
  alpine  /bin/sh -> a
```

Same inversion the
[relational-algebra lab](../UNIX-relational-algebra-sql-in-the-shell/MANUAL_TESTING.md#the-surprise-that-runs-the-other-way)
found. The lab installs real `bash` on both anyway.

And BusyBox's `sort` is where Guest's obsolete key syntax finally dies — with a
different message on each base's BusyBox build:

```
--- debian (busybox 1.36.1):  sort: invalid option -- '1'
--- alpine (busybox 1.37.0):  sort: unrecognized option: 1
```

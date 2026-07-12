# MANUAL_TESTING — floating-point arithmetic in Bash

Captured transcripts from real runs. **Both bases verified end-to-end on 2026-07-12**:
Debian 13 (trixie, glibc, bash 5.2.37) and Alpine 3.24 (musl/BusyBox, bash 5.3.9),
via `phase5-lxd/lab-lxd.sh` on Incus. Every claim in the README is reproduced below.

## The full run

```bash
# Debian
phase5-lxd/lab-lxd.sh up --config examples/UNIX-floating-point-arithmetic-in-bash/float-math-debian.toml
examples/UNIX-floating-point-arithmetic-in-bash/setup-workshop.sh float-math-debian/shell

# Alpine
phase5-lxd/lab-lxd.sh up --config examples/UNIX-floating-point-arithmetic-in-bash/float-math-alpine.toml
examples/UNIX-floating-point-arithmetic-in-bash/setup-workshop.sh float-math-alpine/shell
```

Each ends by running `demo.sh` as the `learner`. **Result on both: `PASS: all 25
checks hold`** (exit 0).

### `demo.sh` — Debian 13 (verbatim)

```
================================================================
 Floating-point arithmetic in Bash -- because they said it couldn't be done
================================================================

1. THE WALL: Bash's $(( )) is integer-only -- and it fails SILENTLY.
  $((1/3))  -> 0          <- not 0.333..., just 0. No error.
  $((7/2))  -> 3          <- not 3.5. No error.
   [ok]  WALL: $((1/3)) truncates to 0, silently
   [ok]  WALL: $((7/2)) truncates to 3, silently
   [ok]  WALL: $((1.5+1)) is a hard syntax error (Bash cannot even parse a decimal)
       bash says: line 1: 1.5 + 1: syntax error: invalid arithmetic operator (error token is ".5 + 1")

2. ...but the shell next door has done this for decades.
  zsh  $((1.0/3)) -> 0.33333333333333331
   [ok]  ZSH: native float arithmetic in $(( )) -- same syntax, works
  ksh  $((1.0/3)) -> 0.333333333333333333   <- long double, even more digits than zsh
  So 'the shell can't do floats' is really 'BASH can't'. Hence everything below.

3. THE CORE IDENTITY: bc == awk == div (pure bash) == shellmath
   [ok]  QUOTIENT 1/3 = 0.33333333  (all four agree)
   [ok]  QUOTIENT 2/3 = 0.66666666  (all four agree)
   [ok]  QUOTIENT 7/34 = 0.20588235  (all four agree)
   [ok]  QUOTIENT 1080/633 = 1.70616113  (all four agree)
   [ok]  QUOTIENT 8/32 = 0.25000000  (all four agree)
   [ok]  QUOTIENT 22/7 = 3.14285714  (all four agree)

4. Reproduce the sources' own published output.
   [ok]  PUBLISHED: Cyrus's five printed results reproduce byte-for-byte
   [ok]  SHELLMATH: slower_e_demo == faster_e_demo (the optimization is sound)
   [ok]  SHELLMATH: e agrees with bc to 10 decimals
  shellmath e (deg-15 Maclaurin) = 2.718281828458994464
  bc        e (bc -l)            = 2.71828182845904523536

5. 0.1 + 0.2: where they are SUPPOSED to disagree (decimal vs binary).
  bc        0.1+0.2 -> .3   (arbitrary-precision DECIMAL)
  shellmath 0.1+0.2 -> 0.3      (DECIMAL: splits int/frac parts)
  awk       0.1+0.2 -> 0.30000000000000004441   (binary IEEE-754)
   [ok]  DECIMAL: bc says 0.1+0.2 == 0.3 exactly
   [ok]  DECIMAL: shellmath says 0.1+0.2 == 0.3 exactly
   [ok]  BINARY:  awk says 0.1+0.2 != 0.3  (and awk is RIGHT -- 0.1 is not representable in base 2)

6. ERRATA -- found by RUNNING the sources, not reading them.
   [ok]  REGRESSION: div -7 2 still emits the documented garbage '-3.-5' (verbatim bug preserved)
   [ok]  FIXED: fixed/div -7 2 = -3.5
   [ok]  FIXED: fixed/div -1 3 = -0.333333333333
   [ok]  REGRESSION: div overflows int64 on a big divisor and prints garbage (0.-8-4-4-6-7-4-40-7-3-70)
   [ok]  FIXED: fixed/div refuses the overflowing divisor (loudly, non-zero exit)
  shellmath  1 + 2e-2   -> 1.2000   <- WRONG (e-2 treated as e-1)
  shellmath  1 + 0.02  -> 1.0200   <- correct, via sci2dec
   [ok]  REGRESSION: shellmath 1+2e-2 is still wrong (1.2, not 1.02)
   [ok]  FIXED: sci2dec expands 2e-2 -> shellmath gets 1.02 right
  shellmath README example: 1.009 + 4.223e-2 -> 1.26430  (should be 1.05123)
   [ok]  REGRESSION: shellmath's own README example is wrong (1.2643)
   [ok]  FIXED: with sci2dec, the README example gives 1.05123

----------------------------------------------------------------
PASS: all 25 checks hold (bc == awk == pure-bash div == shellmath;
      decimal and binary disagree exactly where they must; all 4 errata reproduce)
```

### `demo.sh` — Alpine: identical, but for **two** lines

Alpine produces the **same 25 `[ok]`s and the same `PASS:`**. `diff` against the
Debian transcript shows exactly two differences, and *neither* is a failure — both
are findings:

```diff
-       bash says: line 1: 1.5 + 1: syntax error: invalid arithmetic operator (error token is ".5 + 1")
+       bash says: line 1: 1.5 + 1: arithmetic syntax error: invalid arithmetic operator (error token is ".5 + 1")

-  ksh  $((1.0/3)) -> 0.333333333333333333   <- long double, even more digits than zsh
```

1. **bash 5.3 reworded the error.** Debian ships bash **5.2.37** (`syntax error:`);
   Alpine ships **5.3.9** (`arithmetic syntax error:`). Even the message that tells
   you Bash can't do this has changed. It is a *bash-version* difference, **not** a
   glibc/musl one.
2. **Alpine's `main` has no `ksh`** (only `loksh`/`mksh`), so that line is absent.
   `zsh` is present on both and carries the point.

Everything else — all 25 checks, every computed digit — is **byte-identical across
glibc and musl**. That is `export LC_ALL=C` plus pointing `awk` at `gawk` on both
bases; without the first, §6 below shows what happens.

---

## The baseline: what each base actually ships

Captured on **stock containers, before `setup-workshop.sh`**:

```
                      Debian 13 (trixie)        Alpine 3.24
  bash                /usr/bin/bash             ABSENT
  bc                  ABSENT                    /usr/bin/bc   (BusyBox applet)
  dc                  ABSENT                    /usr/bin/dc   (BusyBox applet)
  awk                 /usr/bin/awk  (mawk)      /usr/bin/awk  (BusyBox awk)
  python3             ABSENT                    ABSENT
  perl                /usr/bin/perl             ABSENT
  ksh / zsh           ABSENT                    ABSENT
```

```
$ busybox --list | grep -xE 'bc|dc|awk|printf|expr'     # on Alpine
awk
bc
dc
expr
printf
```

**The two bases are exact mirror images.** Debian has the *language* (`bash`) but not
the *calculator* (`bc`/`dc`); Alpine has the *calculator* — as BusyBox applets — but
not the *language*. The canonical advice *"Bash can't do floats, just use `bc`"*
**does not work on a stock Debian container**, because `bc` is not installed. And on
Alpine, where `bc` is right there, there is no `bash` to call it from.

---

## Errata: four published things that don't do what they say

All four are **silent**: exit status 0, no warning, a plausible-looking wrong answer.

### 1 & 2 — Cyrus's `div`: negatives and int64 overflow

```
$ div -7 2
-3.-5                                    <- not a number; should be -3.5
$ div 7 -2
-3.-5
$ div -1 3
0.-3-3-3-3-3-3-3-3-3-3-3-3               <- should be -0.333...
$ echo $?
0                                        <- and it reports success
```

Bash's `/` truncates toward zero, so `-7/2 = -3` with remainder `-1`; the negative
remainder is fed back into the recursion and **every digit carries its own sign**.

```
$ div 999999999999999999 1000000000000000000
0.-8-4-4-6-7-4-40-7-3-70                 <- ordinary POSITIVE integers!
$ echo "scale=12; 999999999999999999/1000000000000000000" | bc
.999999999999
```

Each step computes `e*10` with `0 ≤ e < divisor`. Once the divisor passes
`INTMAX/10 = 922337203685477580`, that multiply **wraps int64**. The corrected twin
refuses instead:

```
$ bin/fixed/div -7 2
-3.5
$ bin/fixed/div -1 3
-0.333333333333
$ bin/fixed/div 999999999999999999 1000000000000000000
div: divisor > INTMAX/10 -- 'e*10' would overflow int64
$ echo $?
1
```

### 3 — `shellmath`: additive ops mis-scale scientific notation (`e ≤ -2`)

The exponent sweep that pins it down (`awk` gives the correct value):

```
  add       1        2e1      -> 2.1e1          (awk: 21          ) ok
  add       1        2e0      -> 3.0e0          (awk: 3           ) ok
  add       1        2e-1     -> 1.2e0          (awk: 1.2         ) ok
  add       1        2e-2     -> 1.2e0          (awk: 1.02        ) WRONG
  add       1        2e-3     -> 1.2e0          (awk: 1.002       ) WRONG
  add       1        2e-4     -> 1.2e0          (awk: 1.0002      ) WRONG

  subtract  1        2e-1     -> 0.8            (awk: 0.8         ) ok
  subtract  1        2e-2     -> 0.8            (awk: 0.98        ) WRONG
  subtract  1        2e-3     -> 0.8            (awk: 0.998       ) WRONG

  multiply  1        2e-1     -> 2.0e-1         (awk: 0.2         ) ok
  multiply  1        2e-2     -> 2.0e-2         (awk: 0.02        ) ok
  multiply  1        2e-3     -> 2.0e-3         (awk: 0.002       ) ok
  divide    1        2e-1     -> 5.0e0          (awk: 5           ) ok
  divide    1        2e-2     -> 5.0e1          (awk: 50          ) ok
  divide    1        2e-3     -> 5.0e2          (awk: 500         ) ok
```

**Every exponent ≤ `e-2` is treated as `e-1`** — `add` and `subtract` only.
`multiply`/`divide` handle the identical operands correctly.

And the sharp one — **the README's own headline example**:

```
$ _shellmath_add 1.009 4.223e-2 ; _shellmath_getReturnValue sum ; echo "$sum"
1.2643e0
$ echo '1.009 + 0.04223' | bc
1.05123
$ awk 'BEGIN{print 1.009 + 4.223e-2}'
1.05123
```

The first call a new user copies out of the documentation is wrong by an order of
magnitude. The workaround (we do **not** fork the library — it is correct on plain
decimals):

```
$ bin/fixed/sci2dec 4.223e-2
0.04223
$ _shellmath_add 1.009 "$(bin/fixed/sci2dec 4.223e-2)" ; _shellmath_getReturnValue sum ; echo "$sum"
1.05123
```

### 4 — `shellmath` README: the published `e` does not reproduce

```
README:  $ slower_e_demo.sh 15
         e = 2.7182818284589936

actual (pinned commit f2cbc6c, bash 5.2 / Debian 13 and bash 5.3 / Alpine):
         $ ./slower_e_demo.sh 15
         e = 2.718281828458994464
         $ ./faster_e_demo.sh 15
         e = 2.718281828458994464
```

The two demos still agree **with each other** (so the no-subshell optimization is
sound) and with `bc`'s `e` to 10 decimals — the limiting factor there is the
**15th-degree Maclaurin polynomial**, not `shellmath`:

```
shellmath e (deg-15 Maclaurin) = 2.718281828458994464
bc        e (bc -l)            = 2.71828182845904523536
true e                         = 2.718281828459045235...
```

The published figure was evidently captured from an older build or another platform
(the author's timings in the same README are from minGW64 on Windows).

---

## The locale trap — why `demo.sh` opens with `export LC_ALL=C`

The decimal separator is **locale-dependent**, and the tools do not agree about it.
Captured on Debian 13 with `de_DE.UTF-8` generated (`decimal_point = ,`):

```
$ LC_ALL=C           printf '%.2f\n' 1.5
1.50

$ LC_ALL=de_DE.UTF-8 printf '%.2f\n' 1.5          # bash BUILTIN printf
bash: printf: 1.5: Ungültige Zahl.                # "invalid number" -- it wants 1,5
1,00                                              # ...and it prints a WRONG VALUE

$ LC_ALL=de_DE.UTF-8 /usr/bin/printf '%.2f\n' 1.5 # coreutils printf
1,50                                              # parses it, emits a comma

$ LC_ALL=de_DE.UTF-8 awk  'BEGIN{printf "%.2f\n", 1.5}'
1.50                                              # ignores the locale: a DOT

$ LC_ALL=de_DE.UTF-8 gawk 'BEGIN{printf "%.2f\n", 1.5}'
1.50

$ LC_ALL=de_DE.UTF-8 sh -c 'echo "scale=2; 3/2" | bc'
1.50                                              # bc is locale-independent: a DOT
```

**Four tools, three behaviours, one silent corruption.** Bash's own `printf` cannot
parse `1.5` in that locale — it errors *and still prints `1,00`* — and the comma it
emits cannot be fed back into `awk` or `bc`, which want a dot. Any shell script doing
decimal arithmetic without pinning `LC_NUMERIC` is a bug waiting for a German user.

One `export LC_ALL=C` at the top of `demo.sh` is the entire reason its output is
byte-identical on both bases.

---

## Reproducing the sources' published output

Cyrus's answer prints five results. The **verbatim** `bin/div` reproduces all five
byte-for-byte:

```
  div 1080 633     -> 1.706161137440
  div 7 34         -> 0.205882352941
  div 8 32         -> 0.25
  div 246891510 2  -> 123445755
  div 5000000 177  -> 28248.587570621468
```

---

## Provenance verification

```bash
cd examples/UNIX-floating-point-arithmetic-in-bash/upstream-tutorial
sha256sum -c <<'EOF'
f67e6a941a90b0c9599271d67e71a56b17a9c70ed6998fdb7c1c602250ce01b4  shellmath/README.md
db7e21c3012bc7e72adbdd6063fc4529a4270039d70cbf84547074d648085a23  shellmath/image.png
0fffe06c242a5e695a6b656f60b338eec854cbaca815145cbb9e0dc9072326e5  stackoverflow/index.html
EOF
# shellmath/README.md: OK
# shellmath/image.png: OK
# stackoverflow/index.html: OK
```

`setup-workshop.sh` clones `shellmath` at the **pinned** commit and prints it, so a
force-push upstream cannot silently change the errata above:

```
    shellmath pinned at f2cbc6c (2023-09-28)
```

---

## Teardown

```bash
phase5-lxd/lab-lxd.sh down --lab float-math-debian
phase5-lxd/lab-lxd.sh down --lab float-math-alpine
```

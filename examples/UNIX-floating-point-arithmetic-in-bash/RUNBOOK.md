# RUNBOOK — floating-point arithmetic in Bash, by hand

The by-hand walk that [`setup-workshop.sh`](setup-workshop.sh) automates — every
step, with the *why*. Do this once manually; after that use the script.

Everything below is typed inside the container as the non-root `learner`:

```bash
phase5-lxd/lab-lxd.sh up --config examples/UNIX-floating-point-arithmetic-in-bash/float-math-debian.toml
phase5-lxd/lab-lxd.sh exec float-math-debian/shell -- su - learner
```

---

## 0. Meet the wall

Before installing anything, prove to yourself that the problem is real:

```bash
echo $((1/3))        # -> 0        NOT 0.333...   and NOT an error
echo $((7/2))        # -> 3        NOT 3.5
echo $((1.5 + 1))    # -> syntax error: invalid arithmetic operator
```

Sit with the first one. **Bash did not fail.** It returned `0`, exit status 0, and
moved on. Every "why is my average always zero" bug in every shell script ever
written is this line. The third one at least has the decency to shout.

Bash's arithmetic is `intmax_t` — 64-bit **integers**, full stop. That is not an
oversight; it is what POSIX specifies for `$(( ))`.

## 1. …but it is a *Bash* limitation, not a *shell* limitation

This is the fact that reframes everything else:

```bash
zsh -c 'echo $((1.0/3))'     # -> 0.33333333333333331      (binary double)
ksh -c 'echo $((1.0/3))'     # -> 0.333333333333333333     (long double!)
bash -c 'echo $((1.0/3))'    # -> syntax error
```

Same syntax. Same decade. zsh and ksh93 simply implemented it. So `shellmath` is not
a stunt against the laws of nature — it is a **backport** of a feature the shell next
door has had for thirty years.

> On Alpine, `ksh` is not in `main` (only `loksh`/`mksh`), so that line is
> Debian-only. `zsh` works on both.

## 2. Install what your base is missing — and notice *what* that is

```bash
# Debian: has bash, has NO bc, NO dc
sudo apt-get install -y bc dc gawk zsh ksh git

# Alpine: has bc AND dc (BusyBox applets!), has NO bash at all
sudo apk add bash bc gawk zsh git
```

**Stop and look at that.** The two bases are exact mirror images:

- **Debian gives you the language but not the calculator.** The canonical advice —
  *"Bash can't do floats, just use `bc`"* — **fails out of the box**, because `bc`
  isn't installed.
- **Alpine gives you the calculator but not the language.** `bc` and `dc` are right
  there as BusyBox applets… and there is no `bash` to call them from. A `#!/bin/bash`
  script on stock Alpine dies with `not found` — which refers to the *interpreter*,
  not the script, and misleads everyone the first time.

## 3. The orthodox answer, and what it costs

```bash
echo "scale=12; 1/3" | bc      # -> .333333333333    (note: NO leading zero!)
awk 'BEGIN{print 1/3}'         # -> 0.333333
python3 -c 'print(1/3)'        # -> 0.3333333333333333
```

All correct. All **fork a process**. In a loop over 10,000 rows that is 10,000
`fork()`+`exec()` pairs, and it is why shell scripts that do arithmetic are slow.

Two gotchas to bank now, because `demo.sh` has to defend against both:

- **`bc` omits the leading zero.** `.333…`, not `0.333…`. A naive string comparison
  against any other tool fails.
- **`bc`'s `scale=` truncates; it does not round.** `scale=12; 2/3` → `.666666666666`,
  never `…667`. (Cyrus's `div` truncates too — which is exactly *why* the two can be
  compared digit-for-digit. `awk`'s `%.12f` **rounds**, so it must be truncated to the
  same width first.)

## 4. Cyrus's `div` — long division, 12 lines, no fork

```bash
. ~/float-math/bin/div      # the VERBATIM script
div 1080 633                # -> 1.706161137440
div 8 32                    # -> 0.25
div 5000000 177             # -> 28248.587570621468
```

Read it. It is grade-school long division: take the integer quotient, print it;
multiply back; take the remainder; **multiply the remainder by ten**; recurse. One
digit of the answer per recursion, `p=12` of them, entirely inside integer `$(( ))`.

The `local c=${c:-0}` line is the clever bit — it uses Bash's *dynamic scoping* to
thread a recursion counter through without a parameter.

### Now break it

```bash
div -7 2        # -> -3.-5        <- that is not a number
div -1 3        # -> 0.-3-3-3-3-3-3-3-3-3-3-3-3
echo $?         # -> 0            <- and it says everything is FINE
```

**Why.** Bash's `/` truncates *toward zero*, so `-7/2` is `-3` and the remainder is
`-1`. That negative remainder is fed straight back into the recursion, and every
digit it produces carries its own minus sign. The published function never restricts
its arguments to positives — nothing warns you.

```bash
div 999999999999999999 1000000000000000000     # -> 0.-8-4-4-6-7-4-40-7-3-70
echo "scale=12; 999999999999999999/1000000000000000000" | bc   # -> .999999999999
```

**Why.** Each step computes `e*10`, where `0 ≤ e < divisor`. Once the divisor exceeds
`INTMAX/10` (`9223372036854775807 / 10`), that multiply **wraps int64** and goes
negative — same garbage, from perfectly innocent positive inputs. *This* is the one
that will bite you in production.

### The fix

```bash
diff -u ~/float-math/bin/div ~/float-math/bin/fixed/div
~/float-math/bin/fixed/div -7 2                              # -> -3.5
~/float-math/bin/fixed/div 999999999999999999 1000000000000000000
# -> div: divisor > INTMAX/10 -- 'e*10' would overflow int64      (exit 1)
```

Hoist the sign out, divide the magnitudes, put the sign back once. Refuse the
overflow **loudly** rather than printing nonsense. That is the whole diff — and it is
the exercise.

## 5. `shellmath` — the whole library, still no fork

```bash
cd ~/float-math/shellmath
. ./shellmath.sh

_shellmath_add 0.1 0.2;         _shellmath_getReturnValue s;  echo "$s"   # -> 0.3
_shellmath_multiply 1 2 3 4 5 6; _shellmath_getReturnValue f; echo "$f"   # -> 720
_shellmath_divide 1 3;          _shellmath_getReturnValue q;  echo "$q"   # -> 0.333333333333333333
```

It splits each number into integer and fractional parts, does integer arithmetic on
the parts, and recombines with the carries — "if we can get carrying, borrowing, place
value, and the distributive law right, then the sky's the limit."

**The point of `_shellmath_getReturnValue`.** A shell function can only "return" a
number 0–255. The usual escape is `x=$(func …)` — but `$( )` **forks a subshell**,
which is the very cost we're trying to avoid. So `shellmath` writes its answer into a
global and hands it to you with a getter. Set `__shellmath_isOptimized=1` and it never
subshells at all. That is why it beats `bc` on speed:

```bash
./slower_e_demo.sh -t 15     # subshell-per-operation
./faster_e_demo.sh -t 15     # returns through globals   <- feel the difference
```

Both compute *e* from its 15th-degree Maclaurin polynomial (31 arithmetic calls).

### Now break this one too

```bash
_shellmath_add 1 2e-1; _shellmath_getReturnValue r; echo "$r"    # -> 1.2      correct
_shellmath_add 1 2e-2; _shellmath_getReturnValue r; echo "$r"    # -> 1.2      WRONG (1.02)
_shellmath_add 1 2e-3; _shellmath_getReturnValue r; echo "$r"    # -> 1.2      WRONG (1.002)
```

Every exponent `≤ e-2` is treated as if it were `e-1`. And now the sharp bit — the
**README's own headline example**:

```bash
_shellmath_add 1.009 4.223e-2; _shellmath_getReturnValue sum; echo "$sum"
# -> 1.2643e0        the correct answer is 1.05123
```

The first call a new user copies out of the documentation is wrong by an order of
magnitude, silently. `_shellmath_multiply` and `_shellmath_divide` handle the same
operands correctly, so it is specific to the additive path.

**The fix is not to fork the library** — `shellmath` is correct on plain decimals, so
normalize the operand first:

```bash
. ~/float-math/bin/fixed/sci2dec
sci2dec 4.223e-2                                   # -> 0.04223
_shellmath_add 1.009 "$(sci2dec 4.223e-2)"; _shellmath_getReturnValue sum; echo "$sum"
# -> 1.05123        correct
```

`sci2dec` is pure Bash string manipulation — no `bc`, no `awk`, no subshell math. In
the spirit of the thing.

## 6. The trap that will ruin your day: the decimal point is not a constant

```bash
LC_ALL=C           printf '%.2f\n' 1.5      # -> 1.50
LC_ALL=de_DE.UTF-8 printf '%.2f\n' 1.5      # -> bash: printf: 1.5: invalid number
                                            #    1,00              <- AND a wrong value
LC_ALL=de_DE.UTF-8 /usr/bin/printf '%.2f\n' 1.5   # -> 1,50        (comma)
LC_ALL=de_DE.UTF-8 awk 'BEGIN{printf "%.2f\n", 1.5}'  # -> 1.50    (dot!)
LC_ALL=de_DE.UTF-8 bc <<< 'scale=2; 3/2'              # -> 1.50    (dot!)
```

Under a comma locale, **Bash's own `printf` refuses to parse `1.5`** — it wants `1,5`
— errors, and *still prints a wrong number*. Meanwhile `awk` and `bc` carry on using a
dot, so Bash's comma output can't even be piped back into them. Four tools, three
different answers, one silent corruption.

**This is why `demo.sh` opens with `export LC_ALL=C`,** and it is the single most
practical thing in this lab. If your script does decimal arithmetic and you have not
pinned `LC_NUMERIC`, it is a bug waiting for a German user.

## 7. Run the proof

```bash
bash ~/float-math/demo.sh
# ...
# PASS: all 25 checks hold (bc == awk == pure-bash div == shellmath;
#       decimal and binary disagree exactly where they must; all 4 errata reproduce)
```

## The exercise

1. **`div` still truncates.** Make `bin/fixed/div` *round* the last digit (look one
   digit further and carry). Careful: `0.999…` must round up through the decimal point.
2. **Make it non-recursive.** The recursion costs a function call per digit. Rewrite
   the digit loop iteratively and time it against the original with `time`.
3. **Fix `shellmath` properly.** `sci2dec` works around the additive bug from the
   outside. Find the actual defect in `_shellmath_add`'s exponent alignment and send
   Michael Wood a patch — it's GPL-3.0, and the repo is right there.
4. **Answer the real question.** Time `bc`, `awk`, `div` and `shellmath` over 10,000
   divisions. At what loop count does avoiding the fork actually pay for itself? *Is*
   pure-Bash arithmetic ever the right engineering call — or is it, as its own author
   half-admits, mostly a glorious demonstration that it can be done?

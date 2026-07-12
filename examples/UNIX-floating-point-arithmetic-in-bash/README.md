# UNIX-floating-point-arithmetic-in-bash — crossing the decimal point

> *"Introducing floating-point arithmetic libraries for the Bash shell, **because
> they said it couldn't be done**."* — Michael Wood, `shellmath`

A **throwaway system container** with **bash**, **`bc`/`dc`** (the orthodox
external calculators), **gawk** (the binary-IEEE oracle), **zsh + ksh** (which have
had decimal arithmetic in `$(( ))` for *decades*), a non-root **`learner`** user,
and a `~/float-math/` sandbox holding **Cyrus's `div` verbatim**, corrected twins
under `bin/fixed/`, a **pinned clone of `shellmath`**, and a runnable **`demo.sh`**
that does not merely *show* that Bash can do decimal math — it **proves it**, by
making four independent implementations agree on the same numbers. Built and driven
through the repo's **Phase-5** tool ([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)),
which speaks **LXD or Incus** identically.

Bash's `$(( ))` is **integer-only**, and it does not warn you:

```bash
$ echo $((1/3))      # not 0.333... — just 0. No error. No exit code. Nothing.
0
$ echo $((1.5 + 1))  # and it cannot even PARSE a decimal
bash: 1.5 + 1: syntax error: invalid arithmetic operator (error token is ".5 + 1")
```

That silent `0` is the whole problem. The orthodox answer is *"shell out to `bc`"* —
which is correct, and costs you **a fork per operation**. This lab takes the two
people who refused to accept that, and runs their code.

## Two sources, already in conversation

Both are vendored under [`upstream-tutorial/`](upstream-tutorial/README.md). This is
**not an arbitrary pairing** — `shellmath`'s own README points at the Stack Overflow
answer as its prior art:

> *"A **diamond-in-the-rough** buried elsewhere on Stack Overflow. This down-and-dirty
> milestone computes the decimal quotient of two integer arguments… an entirely
> different approach than `shellmath`'s."*

| Source | Year | What it gives you |
|---|---|---|
| **Cyrus**, [Stack Overflow `a/24431665`](upstream-tutorial/stackoverflow/index.html) | 2014 | The *minimum viable* decimal: grade-school **long division**, one digit per recursion, in **12 lines** of integer `$(( ))`. Integers in, decimal string out. No fork. |
| **Michael Wood**, [`shellmath`](upstream-tutorial/shellmath/README.md) | 2020–23 | The *fully general* one: **+ − × ÷** on decimals and scientific notation, arbitrary arity, `e` via a Maclaurin series — and an argument for **why**: it returns through globals to avoid the `$( )` subshell, making it *faster than `bc`*. |

Read Cyrus for *how little it takes*; read Wood for *how far it goes*.

## The premise, in one table

|  | Bash | zsh | ksh93 | `bc` | `awk` |
|---|---|---|---|---|---|
| `$((1.0/3))` | ❌ syntax error | ✅ `0.33333333333333331` | ✅ `0.333333333333333333` | — | — |
| Arithmetic model | integer only | binary (double) | binary (long double) | **arbitrary-precision decimal** | binary (IEEE-754 double) |
| Costs a fork? | no | no | no | **yes** | **yes** |

**"The shell can't do floating point" is false.** *Bash* can't. zsh and ksh93 have
had it all along, with the same `$(( ))` syntax — which reframes `shellmath` not as a
stunt but as a **backport**.

## Quick start

Both bases are first-class — pick either (or run both; they coexist):

```bash
# ── Debian 13 (trixie / glibc base) ─────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-floating-point-arithmetic-in-bash/float-math-debian.toml
examples/UNIX-floating-point-arithmetic-in-bash/setup-workshop.sh float-math-debian/shell   # ~1 min
phase5-lxd/lab-lxd.sh exec float-math-debian/shell -- su - learner                          # start calculating
phase5-lxd/lab-lxd.sh down --lab float-math-debian                                          # tear down

# ── Alpine (musl / BusyBox base) ────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-floating-point-arithmetic-in-bash/float-math-alpine.toml
examples/UNIX-floating-point-arithmetic-in-bash/setup-workshop.sh float-math-alpine/shell
phase5-lxd/lab-lxd.sh exec float-math-alpine/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab float-math-alpine
```

## `demo.sh` proves it, it doesn't just show it

It runs **25 checks**. The core ones assert that **four independent implementations
of decimal division — two of them forks, two of them pure Bash — return the same
number**:

```
3. THE CORE IDENTITY: bc == awk == div (pure bash) == shellmath
   [ok]  QUOTIENT 1/3 = 0.33333333  (all four agree)
   [ok]  QUOTIENT 22/7 = 3.14285714  (all four agree)
   ...
4. Reproduce the sources' own published output.
   [ok]  PUBLISHED: Cyrus's five printed results reproduce byte-for-byte
   [ok]  SHELLMATH: slower_e_demo == faster_e_demo (the optimization is sound)
   [ok]  SHELLMATH: e agrees with bc to 10 decimals

PASS: all 25 checks hold (bc == awk == pure-bash div == shellmath;
      decimal and binary disagree exactly where they must; all 4 errata reproduce)
```

**All 25 pass identically on Debian and Alpine** ([proof per distro in
MANUAL_TESTING](MANUAL_TESTING.md)).

Two ideas do the work here, and both are worth internalizing:

- **`LC_ALL=C` is load-bearing — the decimal point is not a constant.** Under a
  comma locale (`de_DE`), Bash's own `printf` **refuses to parse `1.5`** and prints
  a *wrong value* (`1,00`) while `awk` and `bc` keep using a dot. One `export` at
  the top of `demo.sh` is the entire reason the two bases produce identical output.
- **Truncation is not rounding.** `bc`'s `scale=` truncates, and so does Cyrus's
  `div` — which is precisely *why* they can be compared digit-for-digit. `awk`'s
  `%.12f` **rounds**, so it must be truncated to the same width before comparison.

## The disagreement that is *correct*

`demo.sh` also asserts a **disagreement**, because getting this one "wrong" is the
right answer:

```
   [ok]  DECIMAL: bc says 0.1+0.2 == 0.3 exactly
   [ok]  DECIMAL: shellmath says 0.1+0.2 == 0.3 exactly
   [ok]  BINARY:  awk says 0.1+0.2 != 0.3   (and awk is RIGHT)
                  awk 0.1+0.2 -> 0.30000000000000004441
```

`bc` and `shellmath` do **decimal** arithmetic, so `0.1 + 0.2` is exactly `0.3`.
`awk` does **binary IEEE-754**, where `0.1` is not representable at all — so it
isn't. *Both are correct.* Which one you want depends on whether you are counting
money or measuring the world, and **that** is the question a shell script never asks
out loud.

## Documented errata: four published things that don't do what they say

Both sources were **executed**, not just read. All four failures are **silent** — no
error, exit status 0, just a plausible-looking wrong answer. They are preserved
unmodified in the archive and in `bin/`; the corrections live in `bin/fixed/` and are
regression-guarded in `demo.sh`.

| # | Source | As published | What actually happens |
|---|---|---|---|
| 1 | Cyrus, `div` | `div -7 2` | **`-3.-5`** — not a number. Bash's `/` truncates toward zero so the remainder is negative too, and *every recursive digit carries its own minus sign*: `div -1 3` → `0.-3-3-3-3-3-3-3-3-3-3-3-3`. |
| 2 | Cyrus, `div` | `div 999999999999999999 1000000000000000000` | The step `e*10` **wraps int64** once the divisor passes `INTMAX/10` → `0.-8-4-4-6-7-4-40-7-3-70`. **The inputs are ordinary positive integers.** |
| 3 | Wood, `shellmath` | `_shellmath_add 1.009 4.223e-2` — **the README's own first example** | Returns **`1.2643`**; the answer is **`1.05123`**. `add`/`subtract` collapse *any* exponent ≤ `e-2` to `e-1`. `multiply`/`divide` are fine. |
| 4 | Wood, `shellmath` README | *"`slower_e_demo.sh 15` → `e = 2.7182818284589936`"* | The shipped code prints **`e = 2.718281828458994464`**. The published figure can't be reproduced by the repo it documents. |

**Erratum 3 is the sharpest teaching moment in the lab**: it is the library's *own
documented example*, the first line a new user copies — and it is wrong by an order
of magnitude, in silence.

```
shellmath  1 + 2e-1  -> 1.2     ✅        multiply 1 2e-2 -> 0.02   ✅
shellmath  1 + 2e-2  -> 1.2     ❌ (1.02)  multiply 1 2e-3 -> 0.002  ✅
shellmath  1 + 2e-3  -> 1.2     ❌ (1.002) divide   1 2e-3 -> 500    ✅
```

None of the four undermines either author's claim. **You really can do floating-point
arithmetic in Bash** — that is the point, and both sources prove it. The errata are
what it costs.

### `bin/` vs `bin/fixed/`

`bin/div` is Cyrus's function **verbatim** — the object of study; you cannot learn
from code that was silently rewritten. `bin/fixed/` holds **drop-in corrected twins**:
the sign is hoisted out and the magnitudes divided, the overflowing divisor is
**refused loudly** instead of printing garbage, `echo -n` becomes `printf`, and
expansions are quoted. `bin/fixed/sci2dec` is the `shellmath` workaround — it expands
scientific notation to a plain decimal *in pure Bash*, so the library gets operands it
handles correctly. **We do not fork `shellmath`.** Diff them — that's the exercise:

```bash
diff -u bin/div bin/fixed/div
```

## Documented divergence: the two bases are exact mirror images

This is the joke the lab is built on. Each base ships **precisely what the other
lacks**, and this lab needs **both**:

| | Debian 13 (trixie) | Alpine |
|---|---|---|
| `bash` — to *run* the code | ✅ 5.2.37 | ❌ **absent** — and both sources are `#!/bin/bash` |
| `bc` — the arbitrary-precision oracle | ❌ **absent** | ✅ present (**a BusyBox applet!**) |
| `dc` | ❌ **absent** | ✅ BusyBox applet |
| `awk` | ⚠️ mawk | ⚠️ BusyBox awk |
| `zsh` (native float `$(( ))`) | ➕ installable | ➕ installable |
| `ksh93` (native float `$(( ))`) | ➕ installable | ❌ **not in Alpine `main`** (only `loksh`/`mksh`) |
| `$((1.5+1))` error text | `syntax error: …` | `arithmetic syntax error: …` (bash **5.3** reworded it) |

**Debian gives you the language but not the calculator; Alpine gives you the
calculator but not the language.** The canonical advice — *"Bash can't do floats,
just use `bc`"* — **does not work out of the box on Debian**, because `bc` isn't
installed. And on Alpine, where `bc` *is* right there as a BusyBox applet, there is
no `bash` to say it to.

So `setup-workshop.sh` installs **bash + bc + gawk + zsh (+ksh on Debian)** on both,
after which every calculation runs identically on glibc and musl.

## What `setup-workshop.sh` does

Automated counterpart to the by-hand walk in [RUNBOOK.md](RUNBOOK.md); it touches the
guest **only** through `lab-lxd.sh exec` (engine-agnostic), in five steps:

1. **detect** the distro (`/etc/alpine-release` vs `/etc/debian_version`);
2. **install** `bash`, `bc`/`dc`, `gawk`, `zsh`, `ksh` (Debian), `git` — and point
   `awk` at `gawk` on both bases so the two produce identical bytes;
3. **create** a non-root `learner` with a **bash** login (both sources are
   `#!/bin/bash`, and `shellmath`'s no-subshell trick depends on Bash semantics);
4. **install** the `~/float-math/` sandbox — `bin/div` (verbatim), `bin/fixed/`,
   `demo.sh` — and **clone `shellmath` at a pinned commit** (`f2cbc6c`; a moving
   `master` would silently change the errata);
5. **verify** as `learner` — print tool versions and **run `demo.sh`**, which must
   end on `PASS:`.

## Files

| File | Purpose |
|---|---|
| [`float-math-debian.toml`](float-math-debian.toml) / [`float-math-alpine.toml`](float-math-alpine.toml) | Phase-5 specs: one container each |
| [`setup-workshop.sh`](setup-workshop.sh) | Provision bash + bc + gawk + zsh/ksh + `learner` + the sandbox (pinned `shellmath`) |
| [`demo.sh`](demo.sh) | **25 checks**: the wall, the four-way identity, the correct disagreement, all four errata. Ends on `PASS:`/`FAIL:` |
| [`bin/div`](bin/div) | Cyrus's recursive long division — **verbatim** |
| [`bin/fixed/div`](bin/fixed/div) | Corrected twin: signs, overflow guard, `printf`, quoting |
| [`bin/fixed/sci2dec`](bin/fixed/sci2dec) | Pure-Bash scientific → plain decimal; the `shellmath` additive-bug workaround |
| [`RUNBOOK.md`](RUNBOOK.md) | The by-hand walk — every step, with the *why* |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Real captured transcripts (both distros) + the errata proofs |
| [`upstream-tutorial/`](upstream-tutorial/README.md) | Byte-exact archives of both sources + provenance + `sha256` |

## Scope & caveats

- **Throwaway lab.** Containers are disposable; `down` wipes them. No persistent
  state, no real credentials.
- **`shellmath` is fetched, not vendored.** It is a codebase, not a page — house
  convention is *vendor a page, cite a codebase*. `setup-workshop.sh` clones it at a
  **pinned commit**, so the lab needs outbound network at setup time (it already does,
  for `apt`/`apk`).
- **These are teaching artifacts, not a numerics library.** If you need real decimal
  arithmetic in a shell script, use `bc` (or `python3`, or `awk`) and pay the fork —
  it is almost always the right trade. The interesting question is *why* two people
  decided it wasn't, and what they learned.
- **Pure Bash is not magic — it is `intmax_t`.** Both implementations are built on
  64-bit integer arithmetic, which is exactly why erratum 2 (overflow) exists.
  `bc`'s arbitrary precision has no such ceiling.
- **Read the sources on the host, type in the container.** The SO archive renders
  unstyled over `file://` (its CSS is linked by absolute URL); the prose and all the
  code are there.

## Prerequisites

- **LXD or Incus initialised** — `incus admin init` (or `lxd init`). See the Phase-5
  docs: [`START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- Outbound network from the container (to `apt`/`apk` the tools and clone `shellmath`).

## Sources

- Cyrus, Stack Overflow answer `24431665` — **CC BY-SA 4.0**: <https://stackoverflow.com/a/24431665>
- Michael Wood, `shellmath` — **GPL-3.0**: <https://github.com/clarity20/shellmath>

Provenance, `sha256`, licences and the full errata write-up:
[`upstream-tutorial/README.md`](upstream-tutorial/README.md).

This is a Phase-5 sibling to the other shell labs — the
[*survival guide*](../UNIX_novice_survival_guide/README.md),
[*bash by example*](../shell-intermediate-programming-by-example/README.md),
[*sculpting text*](../UNIX-sculpting-text-regex-grep-sed-awk/README.md),
[*relational algebra*](../UNIX-relational-algebra-sql-in-the-shell/README.md) and
[*set operations*](../UNIX-set-operations-in-the-shell/README.md) — same "vendor the
page, build the sandbox, learn by doing" shape. Those labs teach you to wield the
shell on **text**; this one is what happens when you ask it for a **number**.

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog.

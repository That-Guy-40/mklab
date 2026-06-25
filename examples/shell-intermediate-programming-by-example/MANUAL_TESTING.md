# MANUAL_TESTING — captured transcripts

Real output from preparing and exercising this lab end-to-end on the host
(Incus, system containers), both distros. The environment is provisioned, then a
spread of **bash constructs straight from the article** is run **as the `learner`
user** to prove the scripting environment works. Trimmed only for length (package
noise), never edited.

| Check | Debian 13 (glibc) | Alpine (musl) |
|---|---|---|
| `up` container | ✅ | ✅ |
| install tools | ✅ (bash already present) | ✅ (**bash installed over BusyBox**) |
| `learner` user, bash login | ✅ | ✅ |
| starter `demo.sh` runs | ✅ `5! = 120` | ✅ `5! = 120` |
| arrays + `${#a[@]}` vs `${#a}` | ✅ `3` vs `1` | ✅ `3` vs `1` |
| `${path##*/bin}`, `${str:2:3}` | ✅ | ✅ |
| `declare -i`, `${!indirect}` | ✅ | ✅ |
| brace expansion `{0,1}{0,1}` | ✅ | ✅ |
| process substitution `<( )` | ✅ | ✅ |
| `man bash` | ✅ man-db | ✅ bash-doc/mandoc |

---

## Debian 13 (trixie)

```
$ phase5-lxd/lab-lxd.sh up --config examples/shell-intermediate-programming-by-example/bash-by-example-debian.toml
[info] ── lab 'bash-by-example-debian' up (1 incus instance(s), 0 skipped) ──

$ examples/shell-intermediate-programming-by-example/setup-workshop.sh bash-by-example-debian/shell
==> [2/5] installing BASH + the standard complement of Unix tools
  ... NEW: bash-doc bc diffutils file gawk less man-db manpages nano tree ...
==> [4/5] creating the ~/bash-by-example playground with a starter script
==> [5/5] verifying the playground (as learner): run the starter script
  whoami : learner
  shell  : GNU bash, version 5.2.37(1)-release (x86_64-pc-linux-gnu)
  pwd    : /home/learner
  --- running ~/bash-by-example/demo.sh ---
array   : count=3  second=ripe banana
replace : the dog sat
strip   : /usr
slice   : fan
arith   : 3 * 12 = 36, 7 + 5 = 12
fact    : 5! = 120
==> done.  Bash-scripting playground ready in bash-by-example-debian/shell.
```

A spread of constructs straight from the article, run as `learner`:

```
$ phase5-lxd/lab-lxd.sh exec bash-by-example-debian/shell -- su - learner

# "String/array manipulation" — the article's own counter-example
$ ARRAY=(a b c); echo "${#ARRAY} vs ${#ARRAY[@]}"
1 vs 3                         # ${#ARRAY} is len of element 0, NOT the count

# "Operations on variables" — replace-all + longest-prefix strip
$ foo="I am a cat, she is a cat"; echo "${foo//cat/dog}"
I am a dog, she is a dog
$ minipath="/usr/bin:/bin:/sbin"; echo "${minipath##*/bin}"
:/sbin

# "Expressions and arithmetic" — declare -i forces evaluation
$ declare -i number; number=2+4*10; echo "$number"
42

# "Indirect look-up"
$ bar=42; foo=bar; echo "${!foo}"
42

# "Globs and patterns" — the (small) bash bomb
$ echo {0,1}{0,1}{0,1}
000 001 010 011 100 101 110 111

# "Processes" / process substitution + a subroutine
$ diff <(echo same) <(echo same) && echo identical
identical
$ man bash | head -1
BASH(1)                     General Commands Manual                     BASH(1)
```

---

## Alpine

```
$ phase5-lxd/lab-lxd.sh up --config examples/shell-intermediate-programming-by-example/bash-by-example-alpine.toml
[info] resolved images:alpine/latest → images:alpine/3.24
[info] ── lab 'bash-by-example-alpine' up (1 incus instance(s), 0 skipped) ──

$ examples/shell-intermediate-programming-by-example/setup-workshop.sh bash-by-example-alpine/shell
==> [2/5] installing BASH + the standard complement of Unix tools
  Executing bash-5.3.9-r1.post-install
==> [5/5] verifying the playground (as learner): run the starter script
  whoami : learner
  shell  : GNU bash, version 5.3.9(1)-release (x86_64-alpine-linux-musl)
  --- running ~/bash-by-example/demo.sh ---
array   : count=3  second=ripe banana
replace : the dog sat
strip   : /usr
slice   : fan
arith   : 3 * 12 = 36, 7 + 5 = 12
fact    : 5! = 120
==> done.  Bash-scripting playground ready in bash-by-example-alpine/shell.
```

The same constructs — **identical results** to Debian on a musl base, once bash
is installed:

```
$ phase5-lxd/lab-lxd.sh exec bash-by-example-alpine/shell -- su - learner -c '...'
$ ARRAY=(a b c); echo "${#ARRAY} vs ${#ARRAY[@]}"
1 vs 3
$ minipath="/usr/bin:/bin:/sbin"; echo "${minipath##*/bin}"
:/sbin
$ declare -i number; number=2+4*10; echo "$number"
42
$ bar=42; foo=bar; echo "${!foo}"
42
$ echo {0,1}{0,1}
00 01 10 11
$ man bash | head -1
BASH(1)                     General Commands Manual                    BASH(1)
```

---

## Documented divergence: bare Alpine has no bash

A **bare** Alpine container (before `setup-workshop.sh`) has **no `bash`** — its
`/bin/sh` is BusyBox *ash*. This article is built on bash features ash doesn't
have: **arrays** (its single biggest theme) and the **`(( ))` arithmetic
command**. Captured from a throwaway `images:alpine/3.24`:

```
$ command -v bash || echo "bash: NOT INSTALLED"
bash: NOT INSTALLED

$ foo=(a b c); echo "${foo[1]}"      # arrays — the article's core topic
sh: syntax error: unexpected "("

$ (( y = 3 * 12 )); echo "$y"        # the (( )) arithmetic command
sh: y: not found
```

(Interestingly, BusyBox ash *does* handle simple `${x/cat/dog}` replacement — so
not every example breaks — but without arrays or `(( ))`, most of the article
can't run.) That's why the Alpine track installs `bash` (+ `bash-doc` for
`man bash`, + GNU coreutils). With bash in place, every example above runs exactly
as on Debian. Debian's base already includes bash, so it needs no such step.

# MANUAL_TESTING — captured transcripts

Real output from preparing and exercising this lab end-to-end on the host
(Incus, system containers), both distros. The environment is provisioned, then a
spread of **bash-programming** constructs from Parts 1–2 is run **as the
`learner` user** to prove the scripting environment works. Trimmed only for
length (package noise), never edited.

| Check | Debian 13 (glibc) | Alpine (musl) |
|---|---|---|
| `up` container | ✅ | ✅ |
| install tools | ✅ (bash already present) | ✅ (**bash installed over BusyBox**) |
| `learner` user, bash login | ✅ | ✅ |
| starter `demo.sh` runs | ✅ `sum 1..5 = 15` | ✅ `sum 1..5 = 15` |
| `${x^^}` + `${#x}` (Part 1) | ✅ | ✅ |
| `case` (Part 2) | ✅ | ✅ |
| function + `(( ))` (Part 2) | ✅ | ✅ |
| `man bash` | ✅ man-db | ✅ bash-doc/mandoc |

---

## Debian 13 (trixie)

```
$ phase5-lxd/lab-lxd.sh up --config examples/shell-intermediate-workshop/shell-intermediate-debian.toml
[info] ── lab 'shell-intermediate-debian' up (1 incus instance(s), 0 skipped) ──

$ examples/shell-intermediate-workshop/setup-workshop.sh shell-intermediate-debian/shell
==> [2/5] installing BASH + the standard complement of Unix tools
  ... NEW: bash-doc bc diffutils file gawk less man-db manpages nano tree ...
==> [3/5] creating the non-root 'learner' user (bash login shell)
==> [4/5] creating the scripting playground ~/bash-by-example with a starter script
==> [5/5] verifying the playground (as learner): run the starter script
  whoami : learner
  shell  : GNU bash, version 5.2.37(1)-release (x86_64-pc-linux-gnu)
  pwd    : /home/learner
  --- running ~/bash-by-example/demo.sh ---
Hello from learner!
sum 1..5 = 15  (loop + arithmetic OK)
==> done.  Bash-scripting playground ready in shell-intermediate-debian/shell.
```

A spread of Part 1–2 constructs, run as `learner`:

```
$ phase5-lxd/lab-lxd.sh exec shell-intermediate-debian/shell -- su - learner

# Part 1 — parameter expansion / quoting
$ name="bash by example"; echo "${name^^}  (len=${#name})"
BASH BY EXAMPLE  (len=15)

# Part 2 — conditionals (case)
$ for x in cat dog fish; do case $x in cat|dog) echo "$x: pet";; *) echo "$x: other";; esac; done
cat: pet
dog: pet
fish: other

# Part 2 — functions with return status + (( )) arithmetic
$ is_even() { (( $1 % 2 == 0 )); }; is_even 4 && echo "4 is even"
4 is even

$ man bash | head -1
BASH(1)                     General Commands Manual                     BASH(1)
```

---

## Alpine

```
$ phase5-lxd/lab-lxd.sh up --config examples/shell-intermediate-workshop/shell-intermediate-alpine.toml
[info] resolved images:alpine/latest → images:alpine/3.24
[info] ── lab 'shell-intermediate-alpine' up (1 incus instance(s), 0 skipped) ──

$ examples/shell-intermediate-workshop/setup-workshop.sh shell-intermediate-alpine/shell
==> [2/5] installing BASH + the standard complement of Unix tools
( 4/37) Installing bash (5.3.9-r1)
( 5/37) Installing bash-doc (5.3.9-r1)
( 6/37) Installing bc (1.08.2-r1)
  ... coreutils findutils grep sed gawk less mandoc man-pages *-doc tree ...
OK: 37.8 MiB in 69 packages
==> [5/5] verifying the playground (as learner): run the starter script
  whoami : learner
  shell  : GNU bash, version 5.3.9(1)-release (x86_64-alpine-linux-musl)
  --- running ~/bash-by-example/demo.sh ---
Hello from learner!
sum 1..5 = 15  (loop + arithmetic OK)
==> done.  Bash-scripting playground ready in shell-intermediate-alpine/shell.
```

The same Part 1–2 constructs — **identical results** to Debian on a musl base,
once bash is installed:

```
$ phase5-lxd/lab-lxd.sh exec shell-intermediate-alpine/shell -- su - learner -c '...'
$ echo "${name^^}  (len=${#name})"
BASH BY EXAMPLE  (len=15)
$ for x in cat dog fish; do case $x in cat|dog) echo "$x: pet";; *) echo "$x: other";; esac; done
cat: pet
dog: pet
fish: other
$ is_even() { (( $1 % 2 == 0 )); }; is_even 4 && echo "4 is even"
4 is even
$ man bash | head -1
BASH(1)                     General Commands Manual                    BASH(1)
```

---

## Documented divergence: bare Alpine has no bash

A **bare** Alpine container (before `setup-workshop.sh`) has **no `bash`** — its
`/bin/sh` is BusyBox *ash*, which rejects the bash extensions the articles teach.
Captured from a throwaway `images:alpine/3.24`:

```
$ command -v bash || echo "bash: NOT INSTALLED"
bash: NOT INSTALLED

$ x=hello; echo "${x^^}"          # a bash-4 parameter expansion the lesson uses
sh: syntax error: bad substitution
```

That's why the Alpine track installs `bash` (+ `bash-doc` for `man bash`, + GNU
coreutils). With bash in place, every example above runs exactly as on Debian.
Debian's base already includes bash, so it needs no such step.

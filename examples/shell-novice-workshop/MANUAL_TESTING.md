# MANUAL_TESTING — captured transcripts

Real output from preparing and exercising this lab end-to-end on the host
(Incus, system containers), both distros. The environment is provisioned, then a
representative command from each `shell-novice` episode is run **as the `learner`
user** to prove the lesson actually works. Trimmed only for length (package
noise), never edited.

| Check | Debian 13 (glibc) | Alpine (musl) |
|---|---|---|
| `up` container | ✅ | ✅ |
| install tools | ✅ (bash+GNU already present) | ✅ (bash+GNU installed over BusyBox) |
| `learner` user, bash login | ✅ | ✅ |
| data unzipped in `~learner` | ✅ | ✅ |
| `ls -F` (Ep. 2) | ✅ | ✅ |
| `wc -l` → `sort -n` → `head` pipe (Ep. 4) | ✅ | ✅ |
| `for` loop (Ep. 5) | ✅ | ✅ |
| `grep -c` / `find` (Ep. 7) | ✅ | ✅ |
| `man ls` | ✅ man-db | ✅ mandoc |

---

## Debian 13 (trixie)

```
$ phase5-lxd/lab-lxd.sh up --config examples/shell-novice-workshop/shell-novice-debian.toml
[info] launching container 'shell' as lab-shell-novice-debian-shell (image=images:debian/13)
[info] ── lab 'shell-novice-debian' up (1 incus instance(s), 0 skipped) ──

$ examples/shell-novice-workshop/setup-workshop.sh shell-novice-debian/shell
==> [1/5] detecting distro in shell-novice-debian/shell
    distro=debian
==> [2/5] installing BASH + the standard complement of Unix tools
  bash is already the newest version (5.2.37-2+b9).
  coreutils is already the newest version (9.7-3).      # Debian base already has GNU tools
  ... NEW: file gawk less man-db manpages nano tree unzip wget ...
==> [3/5] creating the non-root 'learner' user (bash login shell)
==> [4/5] unzipping the workshop data into /home/learner
==> [5/5] verifying the workshop environment (as learner)
  whoami : learner
  shell  : -bash (GNU bash, version 5.2.37(1)-release (x86_64-pc-linux-gnu))
  pwd    : /home/learner
  data   : exercise-data/
north-pacific-gyre/
  GNU ls : ls (GNU coreutils) 9.7
  count  : 5 lines in exercise-data/numbers.txt
==> done.  Workshop ready in shell-novice-debian/shell.
```

A representative command from each episode, run as `learner`:

```
$ phase5-lxd/lab-lxd.sh exec shell-novice-debian/shell -- su - learner
learner@...:~$ cd ~/shell-lesson-data/exercise-data

# Ep. 2 — Navigating
$ ls -F
alkanes/  animal-counts/  creatures/  numbers.txt  writing/

# Ep. 4 — Pipes & Filters
$ wc -l alkanes/*.pdb | sort -n | head -3
   9 alkanes/methane.pdb
  12 alkanes/ethane.pdb
  15 alkanes/propane.pdb

# Ep. 5 — Loops
$ for f in alkanes/c*.pdb; do echo "-- $f"; head -1 "$f"; done
-- alkanes/cubane.pdb
COMPND      CUBANE

# Ep. 7 — Finding things
$ grep -c ATOM alkanes/cubane.pdb
16
$ find . -name "*.csv"
./animal-counts/animals.csv

$ man ls | head -2
LS(1)                            User Commands                            LS(1)
```

---

## Alpine

```
$ phase5-lxd/lab-lxd.sh up --config examples/shell-novice-workshop/shell-novice-alpine.toml
[info] resolved images:alpine/latest → images:alpine/3.24
[info] ── lab 'shell-novice-alpine' up (1 incus instance(s), 0 skipped) ──

$ examples/shell-novice-workshop/setup-workshop.sh shell-novice-alpine/shell
==> [2/5] installing BASH + the standard complement of Unix tools
(12/39) Installing coreutils (9.11-r0)
(13/39) Installing coreutils-doc (9.11-r0)
  ... bash findutils grep gawk sed less mandoc man-pages *-doc tree unzip wget procps-ng shadow ...
OK: 37.5 MiB in 71 packages
==> [5/5] verifying the workshop environment (as learner)
  whoami : learner
  shell  : -bash (GNU bash, version 5.3.9(1)-release (x86_64-alpine-linux-musl))
  pwd    : /home/learner
  data   : exercise-data/
north-pacific-gyre/
  GNU ls : ls (GNU coreutils) 9.11
  count  : 5 lines in exercise-data/numbers.txt
==> done.  Workshop ready in shell-novice-alpine/shell.
```

The same episode commands — **identical results** to Debian on a musl/BusyBox
base, now that bash + GNU tools are installed:

```
$ phase5-lxd/lab-lxd.sh exec shell-novice-alpine/shell -- su - learner -c '...'
# Ep. 2
$ ls -F
alkanes/  animal-counts/  creatures/  numbers.txt  writing/
# Ep. 4
$ wc -l alkanes/*.pdb | sort -n | head -3
   9 alkanes/methane.pdb
  12 alkanes/ethane.pdb
  15 alkanes/propane.pdb
# Ep. 7
$ grep -c ATOM alkanes/cubane.pdb
16
$ find . -name "*.csv"
./animal-counts/animals.csv
$ man ls | head -2          # mandoc
LS(1)                            User Commands                           LS(1)
```

---

## Documented divergence: BusyBox vs GNU

A **bare** Alpine container (before `setup-workshop.sh`) ships BusyBox, not the
bash + GNU coreutils the lesson assumes. Captured from a throwaway
`images:alpine/3.24`:

```
$ ls -l /bin/sh /bin/ls
/bin/ls -> /bin/busybox
/bin/sh -> /bin/busybox          # one multi-call binary backs every applet

$ command -v bash || echo "bash: NOT INSTALLED"
bash: NOT INSTALLED

$ command -v man || echo "man: NOT INSTALLED"
man: NOT INSTALLED

$ ls --version                   # a GNU-ism the lesson uses
ls: unrecognized option: version
BusyBox v1.37.0 ... multi-call binary.
```

That's why the Alpine track installs `bash coreutils grep sed findutils gawk`
(+ `mandoc`/`*-doc` for `man`). With those in place the workshop runs exactly as
shown above — same flags, same output as Debian. Debian's base already includes
them, so it needs no such step.

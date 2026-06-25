# MANUAL_TESTING — captured transcripts

Real output from preparing and exercising this lab end-to-end on the host
(Incus, system containers), both distros. The environment is provisioned, then a
spread of commands **straight from Matt Might's guide** is run **as the `learner`
user** to prove the survival-guide environment works. Trimmed only for length
(package noise), never edited.

| Check | Debian 13 (glibc) | Alpine (musl) |
|---|---|---|
| `up` container | ✅ | ✅ |
| install tools | ✅ (bash + GNU already present) | ✅ (**bash/man/ssh installed over BusyBox**) |
| `learner` user, bash login | ✅ | ✅ |
| `~/unix-survival` sandbox built | ✅ | ✅ |
| `ls -F`, `cat`, `pwd` (Filesystem) | ✅ | ✅ |
| `ln -s` → `ls -l` shows `baz -> bar` (Symlinks) | ✅ | ✅ |
| `find . \| grep READ` (Pipes) | ✅ | ✅ |
| `grep` in a file (Search) | ✅ | ✅ |
| `ls -l` permissions column (Permissions) | ✅ | ✅ |
| `man ls` (Help: man up) | ✅ man-db | ✅ mandoc |
| `apropos directory` | ✅ | ✅ mandoc-apropos |
| `ssh` / `ssh-keygen` present (Remote access) | ✅ | ✅ openssh-client |

---

## Debian 13 (trixie)

```
$ phase5-lxd/lab-lxd.sh up --config examples/UNIX_novice_survival_guide/unix-survival-debian.toml
[info] launching container 'shell' as lab-unix-survival-debian-shell (image=images:debian/13)
[info] ── lab 'unix-survival-debian' up (1 incus instance(s), 0 skipped) ──

$ examples/UNIX_novice_survival_guide/setup-workshop.sh unix-survival-debian/shell
==> [2/5] installing BASH + the standard complement of Unix tools
  ... NEW: file gawk groff-base info less man-db manpages nano tree ...   # vim, ssh already in base
==> [3/5] creating the non-root 'learner' user (bash login shell)
==> [4/5] building the ~/unix-survival sandbox (mirrors the guide's examples)
==> [5/5] verifying the sandbox (as learner): a few commands straight from the guide
  whoami : learner
  shell  : GNU bash, version 5.2.37(1)-release (x86_64-pc-linux-gnu)
  pwd    : /home/learner
  --- find . | grep READ  (the guide's pipe example) ---
./Desktop/READINGLIST.txt
./README.txt
  --- ls -l ~/unix-survival  (symbolic link) ---
lrwxrwxrwx 1 learner learner  3 Jun 25 04:04 baz -> bar
  --- man ls | head -1  (documentation works) ---
LS(1)                            User Commands                            LS(1)
==> done.  Survival-guide box ready in unix-survival-debian/shell.
```

A spread of commands straight from the guide, run as `learner`:

```
$ phase5-lxd/lab-lxd.sh exec unix-survival-debian/shell -- su - learner

# "The filesystem: ls and cd" + "Working with text: cat"
$ ls -F
Desktop/  Documents/  README.txt  unix-survival/
$ cat README.txt
* A README file for my home directory.
Documents contains my files.

# "Symbolic links" — ln -s reveals where a symlink points
$ cd ~/unix-survival && ls -l
-rw-rw-r-- 1 learner learner  0 Jun 25 04:04 bar
lrwxrwxrwx 1 learner learner  3 Jun 25 04:04 baz -> bar
-rw-rw-r-- 1 learner learner  0 Jun 25 04:04 foo
-rw-rw-r-- 1 learner learner 42 Jun 25 04:04 notes.txt

# "Pipes and redirection" — the guide's exact example
$ cd ~ && find . | grep READ
./Desktop/READINGLIST.txt
./README.txt

# "Search for it: grep"
$ grep -n command ~/unix-survival/notes.txt
2:the command line is a language

# "Help yourself: man up"
$ man ls | head -1
LS(1)                            User Commands                            LS(1)
$ apropos directory | head -2
basename (1)         - strip directory and suffix from filenames
chroot (8)           - run command or interactive shell with special root dir...

# "Remote access: ssh"
$ command -v ssh ssh-keygen
/usr/bin/ssh
/usr/bin/ssh-keygen
```

---

## Alpine

```
$ phase5-lxd/lab-lxd.sh up --config examples/UNIX_novice_survival_guide/unix-survival-alpine.toml
[info] resolved images:alpine/latest → images:alpine/3.24
[info] ── lab 'unix-survival-alpine' up (1 incus instance(s), 0 skipped) ──

$ examples/UNIX_novice_survival_guide/setup-workshop.sh unix-survival-alpine/shell
==> [2/5] installing BASH + the standard complement of Unix tools
  Executing mandoc-apropos-1.14.6-r15.trigger
OK: 116.9 MiB in 78 packages
==> [5/5] verifying the sandbox (as learner): a few commands straight from the guide
  whoami : learner
  shell  : GNU bash, version 5.3.9(1)-release (x86_64-alpine-linux-musl)
  pwd    : /home/learner
  --- find . | grep READ  (the guide's pipe example) ---
./README.txt
./Desktop/READINGLIST.txt
  --- ls -l ~/unix-survival  (symbolic link) ---
lrwxrwxrwx 1 learner learner  3 Jun 25 04:07 baz -> bar
  --- man ls | head -1  (documentation works) ---
LS(1)                            User Commands                           LS(1)
==> done.  Survival-guide box ready in unix-survival-alpine/shell.
```

The same guide commands — **identical results** to Debian on a musl base, once
bash + the GNU/man/ssh tools are installed:

```
$ phase5-lxd/lab-lxd.sh exec unix-survival-alpine/shell -- su - learner -c '...'
$ cd ~/unix-survival && ls -l | grep -- "-> bar"
lrwxrwxrwx 1 learner learner  3 Jun 25 04:07 baz -> bar
$ cd ~ && find . | grep READ
./README.txt
./Desktop/READINGLIST.txt
$ grep -n command ~/unix-survival/notes.txt
2:the command line is a language
$ man ls | head -1
LS(1)                            User Commands                           LS(1)
$ apropos directory | head -3                       # mandoc-apropos + makewhatis
basename(1) - strip directory and suffix from filenames
chroot(1) - run command or interactive shell with special root directory
dir(1) - list directory contents
$ command -v ssh ssh-keygen vim info
/usr/bin/ssh
/usr/bin/ssh-keygen
/usr/bin/vim
/usr/bin/info
```

---

## Documented divergence: bare Alpine has no `man` and no `ssh`

A **bare** Alpine container (before `setup-workshop.sh`) is BusyBox: `/bin/sh` is
*ash*, and two whole sections of the guide — **"Help yourself: man up"** and
**"Remote access: ssh"** — have *nothing to run*, because neither `man` nor `ssh`
(nor `bash`) is installed. Captured from a throwaway `images:alpine/3.24`:

```
$ ls -l /bin/sh
/bin/sh -> /bin/busybox            # one multi-call binary backs every applet

$ command -v bash || echo "bash: NOT INSTALLED"
bash: NOT INSTALLED
$ command -v man  || echo "man: NOT INSTALLED"
man: NOT INSTALLED
$ command -v ssh  || echo "ssh: NOT INSTALLED"
ssh: NOT INSTALLED

$ man ls                           # the guide's "man command" advice
sh: man: not found
$ ssh user@host                    # the guide's "ssh user@address" advice
sh: ssh: not found
```

That's why the Alpine track installs `bash` + the GNU tools, **`mandoc`/`man-pages`
for `man`, `mandoc-apropos` for `apropos`**, and **`openssh-client` for
`ssh`/`ssh-keygen`**. With those in place, every command above runs exactly as on
Debian. Debian's base already includes bash, man, and ssh, so it needs no such step.

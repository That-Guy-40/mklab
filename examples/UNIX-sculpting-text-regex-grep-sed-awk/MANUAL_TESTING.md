# MANUAL_TESTING — captured transcripts

Real output from preparing and exercising this lab end-to-end on the host (Incus,
system containers), both distros. The environment is provisioned, then the
sandbox's `demo.sh` — a spread of grep/sed/awk constructs **straight from the
article** — is run **as the `learner` user**. Trimmed only for length (package
noise), never edited.

| Check | Debian 13 (glibc) | Alpine (musl) |
|---|---|---|
| `up` container | ✅ | ✅ |
| install GNU grep/sed/gawk | ✅ (gawk over mawk) | ✅ (GNU over BusyBox) |
| `awk` → gawk symlink | ✅ | ✅ |
| `learner` user, `/bin/sh` login | ✅ | ✅ |
| `/usr/share/dict/words` populated | ✅ | ✅ |
| `demo.sh` runs | ✅ | ✅ |
| grep ERE backreference `^(.*)\1$` | ✅ | ✅ |
| sed GNU `\U` | ✅ `MAT` | ✅ `MAT` |
| awk `-F:` pattern-action + function | ✅ | ✅ |
| **identical output across bases** | ✅ | ✅ |

The provisioned run is **identical** on Debian's GNU grep 3.11 / gawk 5.2.1 and
Alpine's GNU grep 3.12 / gawk 5.3.2 — once the GNU trio is in place, glibc vs musl
makes no difference.

---

## Debian 13 (trixie)

```
$ phase5-lxd/lab-lxd.sh up --config examples/UNIX-sculpting-text-regex-grep-sed-awk/sculpting-text-debian.toml
[info] ── lab 'sculpting-text-debian' up (1 incus instance(s), 0 skipped) ──

$ examples/UNIX-sculpting-text-regex-grep-sed-awk/setup-workshop.sh sculpting-text-debian/shell
==> [2/5] installing GNU grep/sed/gawk (the article's dialects)
  ... NEW: gawk less libmpfr6 libreadline8t64 libsigsegv2 readline-common ...
==> [3/5] creating the non-root 'learner' user (POSIX /bin/sh login)
==> [4/5] installing the ~/sculpting-text sandbox + /usr/share/dict/words
==> [5/5] verifying the sandbox (as learner): run demo.sh
  whoami : learner
  grep   : grep (GNU grep) 3.11
  sed    : sed (GNU sed) 4.9
  awk    : GNU Awk 5.2.1, API 3.2, PMA Avon 8-g1, (GNU MPFR 4.2.2, GNU MP 6.3.0)
  --- running ~/sculpting-text/demo.sh ---

== grep (ERE backreference): words that are a doubled string  ^(.*)\1$ ==
murmur
tartar
couscous
hotshots
cancan
tutu
papa
bonbon
dodo
froufrou
beriberi
pawpaw
tomtom

== grep -Ec: how many words contain a doubled letter  (.)\1 ==
38

== egrep alternation: oo...ee or ee...oo ==
bookkeeper
bootees
beetroot

== sed: substitute, then GNU \U to upper-case the match ==
the dog sat on the MAT

== sed: delete comment lines (/^#/d), leaving the accounts ==
root:x:0:0:root:/root:/bin/sh
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
alice:x:1000:1000:Alice Example:/home/alice:/bin/bash
bob:x:1001:1001:Bob Builder:/home/bob:/bin/bash
carol:x:1002:1002:Carol Coder:/home/carol:/bin/sh

== awk -F: pattern-action — skip comments, print name + uid ==
root 0
daemon 1
www-data 33
alice 1000
bob 1001
carol 1002

== awk: real users only (uid >= 1000) ==
alice
bob
carol

== awk: dedup preserving first-seen order  !seen[$0]++ ==
apple
banana
cherry
date

== awk + sort|uniq: busiest client IPs in the access log ==
      3 192.168.1.10
      2 10.0.0.5
      1 192.168.1.11

== awk function: palindromes in the word list ==
level
civic
radar
rotor
kayak
noon
deed
refer
madam
peep
sees
==> done.  Text-sculpting sandbox ready in sculpting-text-debian/shell.
```

---

## Alpine

```
$ phase5-lxd/lab-lxd.sh up --config examples/UNIX-sculpting-text-regex-grep-sed-awk/sculpting-text-alpine.toml
[info] resolved images:alpine/latest → images:alpine/3.24
[info] ── lab 'sculpting-text-alpine' up (1 incus instance(s), 0 skipped) ──

$ examples/UNIX-sculpting-text-regex-grep-sed-awk/setup-workshop.sh sculpting-text-alpine/shell
==> [2/5] installing GNU grep/sed/gawk (the article's dialects)
==> [3/5] creating the non-root 'learner' user (POSIX /bin/sh login)
==> [4/5] installing the ~/sculpting-text sandbox + /usr/share/dict/words
==> [5/5] verifying the sandbox (as learner): run demo.sh
  whoami : learner
  grep   : grep (GNU grep) 3.12
  sed    : sed (GNU sed) 4.9
  awk    : GNU Awk 5.3.2, API 4.0
  --- running ~/sculpting-text/demo.sh ---

== grep (ERE backreference): words that are a doubled string  ^(.*)\1$ ==
murmur
tartar
couscous
hotshots
cancan
tutu
papa
bonbon
dodo
froufrou
beriberi
pawpaw
tomtom

== sed: substitute, then GNU \U to upper-case the match ==
the dog sat on the MAT

== awk -F: pattern-action — skip comments, print name + uid ==
root 0
daemon 1
www-data 33
alice 1000
bob 1001
carol 1002

== awk function: palindromes in the word list ==
level
civic
radar
rotor
kayak
noon
deed
refer
madam
peep
sees
==> done.  Text-sculpting sandbox ready in sculpting-text-alpine/shell.
```

(The omitted sections — `grep -Ec`, the alternation, `sed /^#/d`, the uid filter,
the dedup, the IP histogram — are **identical** to the Debian transcript above.)

---

## Documented divergence: BusyBox (and mawk) are not GNU

The article's pipelines assume the **GNU** tools. The stock containers don't all
provide them — Alpine's grep/sed/awk are **BusyBox** applets, and even Debian's
default `awk` is **mawk**. Captured on the Alpine box by calling the BusyBox
applets explicitly and contrasting with the installed GNU tools:

```
$ phase5-lxd/lab-lxd.sh exec sculpting-text-alpine/shell -- sh -c '...'

--- sed \U case-conversion ---
busybox : Uhello                 # BusyBox sed takes \U literally
GNU sed : HELLO                  # GNU sed upper-cases the match

--- grep -E backreference  ^(.*)\1$  (doubled string) ---
busybox : (matches: none)        # BusyBox grep has no backreferences -> silent miss
GNU grep: murmur tartar          # GNU grep finds the doubled-string words

--- which provides each tool now ---
grep  -> /bin/grep
sed   -> /bin/sed
awk   -> /usr/local/bin/awk
gawk  -> /usr/bin/gawk
(awk -> /usr/local/bin/awk -> /usr/bin/gawk)
```

Two failure modes worth internalizing, both **silent**: BusyBox `sed` emits a
plausible-but-wrong `Uhello` (no error), and BusyBox `grep -E` with a
backreference matches **nothing** rather than complaining — you'd think no word is
a doubled string. On Debian the trap is `awk`: its default is mawk, so
gawk-only built-ins like `gensub()` report *"function gensub never defined"*. That
is why the lab installs **GNU grep + sed + gawk** on both and points `awk` at
gawk — after which every example in this file runs the same on glibc and musl.

There is also no `wamerican`/`words` package on Alpine (Debian has one), so the lab
ships its own compact `/usr/share/dict/words`; using the same file on both bases is
what makes the grep-against-the-dictionary output match exactly.

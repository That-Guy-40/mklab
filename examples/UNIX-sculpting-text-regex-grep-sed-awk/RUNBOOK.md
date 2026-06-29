# RUNBOOK — prepare the text-sculpting box by hand, step by step

This is the **by-hand walk**: every command [`setup-workshop.sh`](setup-workshop.sh)
runs, with the *why* at each step. Do it once by hand to understand what a
text-processing sandbox needs; use the script afterward. It prepares a
**grep/sed/awk** playground for **Matt Might's**
[*"Sculpting text with regex, grep, sed and awk"*](upstream-tutorial/articles/sculpting-text/index.html)
— a sibling to the other Matt-Might labs
([survival guide](../UNIX_novice_survival_guide/README.md),
[bash by example](../shell-intermediate-programming-by-example/README.md),
[Hello, Perceptron](../AI-build-a-perceptron/README.md)).

Everything goes through the Phase-5 tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically. Run commands from the repo root.

## Pick a base — Debian **or** Alpine (both fully supported)

Both bases are first-class and **verified end-to-end** ([proof for each in
MANUAL_TESTING](MANUAL_TESTING.md)). They differ in which text tools ship by
default — and **neither default set is fully GNU** (see
[BusyBox/mawk vs GNU](#busybox-and-mawk-vs-gnu)):

| | Debian 13 (trixie) | Alpine |
|---|---|---|
| spec | [`sculpting-text-debian.toml`](sculpting-text-debian.toml) | [`sculpting-text-alpine.toml`](sculpting-text-alpine.toml) |
| image | `images:debian/13` (glibc, GNU userland) | `images:alpine/latest` (musl, BusyBox userland) |
| lab/service handle | `sculpting-text-debian/shell` | `sculpting-text-alpine/shell` |
| installer | `apt-get` | `apk` |
| default grep/sed | **GNU** | BusyBox |
| default awk | **mawk** | BusyBox awk |

Pick your base — the rest of the walk reads the same for both:

```bash
LAB=sculpting-text-debian        # Debian 13 (trixie)
# - or -
LAB=sculpting-text-alpine        # Alpine
```

(Just want it ready without the narration? Jump to
[Just run it](#just-run-it-either-base).)

## 0. Prerequisites

LXD or Incus must be initialised (`incus admin init` or `lxd init`). See
[`../../phase5-lxd/START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
The container needs outbound network to fetch the tools.

## 1. Bring up the container

```bash
phase5-lxd/lab-lxd.sh up --config examples/UNIX-sculpting-text-regex-grep-sed-awk/$LAB.toml
```

One unprivileged **system container** — a full userland with a package manager and
an init — which is what we want: we install tools and add a user, like setting up
a real Linux box to learn on.

## 2. Install the GNU text trio

The article is written for the **GNU** dialects: `grep -E` with backreferences,
GNU `sed`'s `\U`/`\L`, and **gawk**'s functions and arrays. So install `grep`,
`sed`, `gawk` (and a pager). This is the step that differs by base:

```bash
# Debian — already has GNU grep/sed; its default awk is mawk, so add gawk:
phase5-lxd/lab-lxd.sh exec sculpting-text-debian/shell -- \
    sh -c 'apt-get update -qq && apt-get install -y --no-install-recommends \
           grep sed gawk coreutils less'

# Alpine — default grep/sed/awk are BusyBox applets; install the GNU trio:
phase5-lxd/lab-lxd.sh exec sculpting-text-alpine/shell -- \
    apk add --no-cache grep sed gawk coreutils less shadow
```

Then make `awk` mean **gawk** on both (Debian's default is mawk, Alpine's is
BusyBox awk). `/usr/local/bin` is first in `PATH`, so a symlink there wins without
fighting the package manager:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- \
    sh -c 'ln -sf "$(command -v gawk)" /usr/local/bin/awk'
```

### BusyBox (and mawk) vs GNU

Why bother? Because the stock tools quietly differ from what the article expects:

```bash
# GNU sed's \U upper-cases; BusyBox sed prints \U literally:
phase5-lxd/lab-lxd.sh exec sculpting-text-alpine/shell -- \
    sh -c "echo hello | busybox sed 's/.*/\U&/'"     # -> Uhello
phase5-lxd/lab-lxd.sh exec sculpting-text-alpine/shell -- \
    sh -c "echo hello | sed 's/.*/\U&/'"             # -> HELLO

# GNU grep -E has backreferences (the article's doubled-string finder);
# BusyBox grep does not, and silently matches nothing.
```

Captured in full in
[MANUAL_TESTING](MANUAL_TESTING.md#documented-divergence-busybox-and-mawk-are-not-gnu).
After this step, every pipeline runs identically on both bases.

## 3. Create the non-root `learner` user

You learn as an ordinary user — authentic prompt, real `whoami`, sane file
ownership. No bash is installed (this lab is about the text tools, not shell
scripting), so the login shell is the base `/bin/sh` (dash on Debian, BusyBox ash
on Alpine):

```bash
# Debian:
phase5-lxd/lab-lxd.sh exec sculpting-text-debian/shell -- \
    sh -c 'id learner >/dev/null 2>&1 || useradd -m -s /bin/sh learner'

# Alpine (adduser, not useradd):
phase5-lxd/lab-lxd.sh exec sculpting-text-alpine/shell -- \
    sh -c 'id learner >/dev/null 2>&1 || adduser -D -s /bin/sh learner'
```

## 4. Install the sandbox + a dictionary

Give the learner sample data to sculpt and a runnable `demo.sh`. The files live in
this lab ([`sample-data/`](sample-data/) + [`demo.sh`](demo.sh)); push them into
the container with the wrapper's **stdin** (cleaner than escaping the single-quoted
regex they are full of):

```bash
SBX=/home/learner/sculpting-text
phase5-lxd/lab-lxd.sh exec $LAB/shell -- sh -c "mkdir -p $SBX /usr/share/dict"
for f in words passwd access_log dupes.txt; do
    phase5-lxd/lab-lxd.sh exec $LAB/shell -- sh -c "cat > $SBX/$f" \
        < examples/UNIX-sculpting-text-regex-grep-sed-awk/sample-data/$f
done
phase5-lxd/lab-lxd.sh exec $LAB/shell -- sh -c "cat > $SBX/demo.sh" \
    < examples/UNIX-sculpting-text-regex-grep-sed-awk/demo.sh
# The article's flagship data source is /usr/share/dict/words. Real boxes get this
# from `wamerican`/`words` (Debian); Alpine has no clean equivalent, so the lab
# supplies a compact curated list — the same on both, so examples match.
phase5-lxd/lab-lxd.sh exec $LAB/shell -- sh -c "cat > /usr/share/dict/words" \
    < examples/UNIX-sculpting-text-regex-grep-sed-awk/sample-data/words
phase5-lxd/lab-lxd.sh exec $LAB/shell -- \
    sh -c "chmod +x $SBX/demo.sh; chown -R learner $SBX"
```

The sample data: a curated `words` list (doubled strings, palindromes, double
letters — chosen so the regex examples produce satisfying output), a colon-
delimited `passwd` (for `awk -F:`), an `access_log` (for column extraction and
`sort | uniq -c`), and a `dupes.txt` (for the `!seen[$0]++` dedup idiom).

## 5. Verify, then start sculpting

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- su - learner -c \
    'grep --version | head -1; sed --version | head -1; awk --version | head -1; sh ~/sculpting-text/demo.sh'
```

You should see GNU grep / GNU sed / GNU Awk, then the demo print the doubled-string
words, the `\U`-upper-cased `MAT`, the awk field reports, and the palindromes — the
**same on both bases**. Now **drop into the learner's shell**:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- su - learner
```

For example, starting on **Alpine** is just:

```bash
phase5-lxd/lab-lxd.sh exec sculpting-text-alpine/shell -- su - learner
```

…and Debian is identical bar the name. Then open
[`upstream-tutorial/articles/sculpting-text/index.html`](upstream-tutorial/articles/sculpting-text/index.html)
in your viewer and work through it, trying the examples against
`~/sculpting-text/` and `/usr/share/dict/words`.

## 6. Teardown

```bash
phase5-lxd/lab-lxd.sh down --lab $LAB        # sculpting-text-debian or -alpine
```

`down` stops and deletes the container; nothing persists.

## Just run it (either base)

Steps 2–5 are exactly what [`setup-workshop.sh`](setup-workshop.sh) automates. The
full path, shown concretely for **both** bases — pick whichever (or run both,
they're independent):

```bash
# ── Alpine (musl / BusyBox) ─────────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-sculpting-text-regex-grep-sed-awk/sculpting-text-alpine.toml
examples/UNIX-sculpting-text-regex-grep-sed-awk/setup-workshop.sh sculpting-text-alpine/shell   # GNU tools + learner + sandbox
phase5-lxd/lab-lxd.sh exec sculpting-text-alpine/shell -- su - learner                          # start sculpting
phase5-lxd/lab-lxd.sh down --lab sculpting-text-alpine                                          # done

# ── Debian 13 (glibc) ───────────────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-sculpting-text-regex-grep-sed-awk/sculpting-text-debian.toml
examples/UNIX-sculpting-text-regex-grep-sed-awk/setup-workshop.sh sculpting-text-debian/shell
phase5-lxd/lab-lxd.sh exec sculpting-text-debian/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab sculpting-text-debian
```

## Gotchas

- **`\U` prints `Uhello`, or `grep -E '^(.*)\1$'` matches nothing** → you're on
  BusyBox (or mawk), not the GNU tools. Make sure step 2 installed `grep sed
  gawk`; the symlink makes `awk` mean gawk. See
  [BusyBox/mawk vs GNU](#busybox-and-mawk-vs-gnu).
- **`gensub`/`asort` "never defined"** → that's mawk (Debian's default awk), not
  gawk. The `awk` → `gawk` symlink from step 2 fixes it; or call `gawk` directly.
- **`/usr/share/dict/words` is small** → the lab ships a compact curated list so
  the examples are crisp and identical on both bases. For the full system
  dictionary on Debian: `apt install wamerican` (Alpine has no clean equivalent —
  its only word list is the junk-filled `cracklib-words`).
- **`less`/an editor looks garbled / "unknown terminal type"** → your client's
  `$TERM` (e.g. Ghostty's `xterm-ghostty`) has no terminfo entry inside the
  container. `lab-lxd.sh exec` sets `TERM=xterm` for interactive sessions so paging
  works; override with `LAB_TERM` (e.g. `LAB_TERM=xterm-256color`). See
  [START_HERE](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- **Image won't download / `up` hangs** → the `images:` remote can stall; it's not
  a lab bug. Pre-pull once with `incus image copy images:alpine/3.24 local:` (or
  `images:debian/13`) and retry.

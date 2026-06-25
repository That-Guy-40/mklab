# RUNBOOK — prepare the scripting box by hand, step by step

This is the **by-hand walk**: every command [`setup-workshop.sh`](setup-workshop.sh)
runs, with the *why* at each step. Do it once by hand to understand what a bash-
scripting environment needs; use the script afterward. It prepares a BASH
playground for **Matt Might's**
[*"Shell programming with bash: by example, by counter-example"*](upstream-tutorial/articles/bash-by-example/index.html)
— his intermediate bash guide, the programming companion to the
[survival guide](../UNIX_novice_survival_guide/README.md) and a Matt-Might
alternative to the Daniel-Robbins
[`shell-intermediate-workshop/`](../shell-intermediate-workshop/README.md).

Everything goes through the Phase-5 tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically. Run commands from the repo root.

## Pick a base — Debian **or** Alpine (both fully supported)

Both bases are first-class and **verified end-to-end** ([proof for each in
MANUAL_TESTING](MANUAL_TESTING.md)). They differ only in the package manager and
in *how much* needs installing — Debian already has bash; Alpine has **no bash at
all** by default (see [bash vs BusyBox ash](#bash-vs-busybox-ash)):

| | Debian 13 (trixie) | Alpine |
|---|---|---|
| spec | [`bash-by-example-debian.toml`](bash-by-example-debian.toml) | [`bash-by-example-alpine.toml`](bash-by-example-alpine.toml) |
| image | `images:debian/13` (glibc, GNU userland) | `images:alpine/latest` (musl, BusyBox userland) |
| lab/service handle | `bash-by-example-debian/shell` | `bash-by-example-alpine/shell` |
| installer | `apt-get` | `apk` |

Pick your base — the rest of the walk reads the same for both:

```bash
LAB=bash-by-example-debian        # Debian 13 (trixie)
# - or -
LAB=bash-by-example-alpine        # Alpine
```

(Just want it ready without the narration? Jump to
[Just run it](#just-run-it-either-base).)

## 0. Prerequisites

LXD or Incus must be initialised (`incus admin init` or `lxd init`). See
[`../../phase5-lxd/START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
The container needs outbound network to fetch the tools.

## 1. Bring up the container

```bash
phase5-lxd/lab-lxd.sh up --config examples/shell-intermediate-programming-by-example/$LAB.toml
```

One unprivileged **system container** — a full userland with a package manager
and an init — which is what we want: we install tools and add a user, like
setting up a real Linux box to learn scripting on.

## 2. Install BASH + the standard complement of tools

The article is pure **bash** — arrays, `${var/x/y}`, `(( ))`, `declare -i`,
`${!indirect}`. This is the step that differs by base:

```bash
# Debian (bash-by-example-debian/shell) — base already has bash + GNU coreutils;
# add the reading/scripting tools, the bash man page, bc, diff:
phase5-lxd/lab-lxd.sh exec bash-by-example-debian/shell -- \
    sh -c 'apt-get update -qq && apt-get install -y --no-install-recommends \
           bash coreutils findutils grep sed gawk nano less \
           man-db manpages bash-doc file tree procps bc diffutils'

# Alpine (bash-by-example-alpine/shell) — base has NO bash; install it + GNU
# tools (see "bash vs BusyBox ash"). `man bash` needs bash-doc; per-tool man
# pages are in `*-doc` subpackages on Alpine:
phase5-lxd/lab-lxd.sh exec bash-by-example-alpine/shell -- \
    apk add --no-cache bash bash-doc coreutils findutils grep sed gawk \
           nano less mandoc man-pages coreutils-doc grep-doc sed-doc findutils-doc \
           file tree procps-ng shadow bc diffutils
```

### bash vs BusyBox ash

A fresh Alpine container has **no `bash`** — `/bin/sh` is BusyBox *ash*, which
lacks the two pillars this array-heavy article is built on: **arrays**
(`foo=(a b c)` → `sh: syntax error: unexpected "("`) and the **`(( ))` arithmetic
command** (`(( y = 3 * 12 ))` → `sh: y: not found`). So on Alpine we install real
bash; after that, every example runs exactly as on Debian. The bare-Alpine
behavior is captured in
[MANUAL_TESTING](MANUAL_TESTING.md#documented-divergence-bare-alpine-has-no-bash).
(Debian already ships bash, so it needs no such fix.)

## 3. Create the non-root `learner` user

You learn scripting as an ordinary user — authentic prompt, real `whoami`, sane
file ownership.

```bash
# Debian:
phase5-lxd/lab-lxd.sh exec bash-by-example-debian/shell -- \
    sh -c 'id learner >/dev/null 2>&1 || useradd -m -s /bin/bash learner'

# Alpine (adduser, not useradd):
phase5-lxd/lab-lxd.sh exec bash-by-example-alpine/shell -- \
    sh -c 'id learner >/dev/null 2>&1 || adduser -D -s /bin/bash learner'
```

## 4. Make a scripting playground

Give the learner somewhere to write scripts, with a tiny runnable starter that
exercises a few of the article's constructs (arrays, parameter expansion, `(( ))`
arithmetic, and the factorial subroutine the article ends on):

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- su - learner -c '
mkdir -p ~/bash-by-example
cat > ~/bash-by-example/demo.sh <<"EOS"
#!/usr/bin/env bash
fruits=("apple" "ripe banana" "cherry")
echo "array   : count=${#fruits[@]}  second=${fruits[1]}"   # count=3
phrase="the cat sat"; echo "replace : ${phrase/cat/dog}"    # the dog sat
path="/usr/bin:/bin:/sbin"; echo "strip   : ${path%%/bin*}" # /usr
sentence="a fan of dogs"; echo "slice   : ${sentence:2:3}"  # fan
(( product = 3 * 12 )); echo "arith   : 3 * 12 = $product"  # 36
fact() { local r=1 n=$1; while (( n >= 1 )); do (( r = n * r )); (( n -= 1 )); done; echo "$r"; }
echo "fact    : 5! = $(fact 5)"                             # 120
EOS
chmod +x ~/bash-by-example/demo.sh'
```

## 5. Verify, then start scripting

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- su - learner -c \
    'bash --version | head -1; bash ~/bash-by-example/demo.sh'
```

You should see the demo print `5! = 120` (plus the array/replace/slice lines).
Now **drop into the learner's shell**:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/shell -- su - learner
```

For example, starting on **Alpine** is just:

```bash
phase5-lxd/lab-lxd.sh exec bash-by-example-alpine/shell -- su - learner
```

…and Debian is identical bar the name. Then open
[`upstream-tutorial/articles/bash-by-example/index.html`](upstream-tutorial/articles/bash-by-example/index.html)
in your viewer and work through it, writing scripts in `~/bash-by-example/`.

## 6. Teardown

```bash
phase5-lxd/lab-lxd.sh down --lab $LAB        # bash-by-example-debian or -alpine
```

`down` stops and deletes the container; nothing persists.

## Just run it (either base)

Steps 2–5 are exactly what [`setup-workshop.sh`](setup-workshop.sh) automates.
The full path, shown concretely for **both** bases — pick whichever (or run both,
they're independent):

```bash
# ── Alpine (musl / BusyBox, no bash by default) ─────────────────
phase5-lxd/lab-lxd.sh up --config examples/shell-intermediate-programming-by-example/bash-by-example-alpine.toml
examples/shell-intermediate-programming-by-example/setup-workshop.sh bash-by-example-alpine/shell   # tools + learner + playground
phase5-lxd/lab-lxd.sh exec bash-by-example-alpine/shell -- su - learner                             # start scripting
phase5-lxd/lab-lxd.sh down --lab bash-by-example-alpine                                             # done

# ── Debian 13 (glibc) ───────────────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/shell-intermediate-programming-by-example/bash-by-example-debian.toml
examples/shell-intermediate-programming-by-example/setup-workshop.sh bash-by-example-debian/shell
phase5-lxd/lab-lxd.sh exec bash-by-example-debian/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab bash-by-example-debian
```

## Gotchas

- **`syntax error: unexpected "("` / `[[: not found` on Alpine** → you're in
  BusyBox `ash`, not bash (it has no arrays and no `(( ))`). Run scripts with
  `bash script.sh` (or `#!/usr/bin/env bash` + `chmod +x`), and make sure step 2
  installed `bash`. See [bash vs BusyBox ash](#bash-vs-busybox-ash).
- **`man bash` says "No manual entry"** → install `bash-doc` (Alpine) — step 2
  does. On Alpine, per-tool man pages also need their `*-doc` subpackage.
- **`convert`/`gcc` examples don't run** → a few of the article's examples call
  ImageMagick's `convert` or `gcc` only to *illustrate* loops/parallelism; they
  aren't installed. `apt install imagemagick` / `apk add imagemagick` (or `gcc`)
  if you want them. The bash lessons don't depend on them.
- **`vim`/`nano`/`less`/`clear` looks garbled / "unknown terminal type"** → your
  client's `$TERM` (e.g. Ghostty's `xterm-ghostty`) has no terminfo entry inside
  the container. `lab-lxd.sh exec` sets `TERM=xterm` for interactive sessions so
  editing your scripts works; override with `LAB_TERM` (e.g.
  `LAB_TERM=xterm-256color`). See
  [START_HERE](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- **Image won't download / `up` hangs** → the `images:` remote can stall; it's
  not a lab bug. Pre-pull once with `incus image copy images:alpine/3.24 local:`
  (or `images:debian/13`) and retry.

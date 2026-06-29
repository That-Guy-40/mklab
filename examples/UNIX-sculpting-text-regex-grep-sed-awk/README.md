# UNIX-sculpting-text-regex-grep-sed-awk — a text-processing box for Matt Might's "Sculpting text"

A **throwaway system container** with the **GNU** text trio — **grep, sed, gawk**
— a non-root **`learner`** user, a populated `/usr/share/dict/words`, and a
`~/sculpting-text/` sandbox (sample data + a runnable `demo.sh`), so you can work
through **Matt Might's**
**["Sculpting text with regex, grep, sed and awk"](upstream-tutorial/articles/sculpting-text/index.html)**
— *running the pipelines as you read them*. Built and driven through the repo's
**Phase-5** tool ([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks
**LXD or Incus** identically.

Might's guide is a dense, practical tour of the three classic Unix text tools and
the **regular expressions** that drive them: regex theory (regular languages,
BRE/ERE/PCRE) → **grep** (basic + extended, useful flags, the backreference
"prime-finder") → **sed** (addresses, the substitute command, flags, scripts) →
**awk** (the pattern-action model, fields, arrays, special variables, functions)
— closing with a nod to regex in **vim** and **emacs**. The author reckons it
covers "80–90%" of his real-world text-munging.

The guide is vendored byte-exact under
[`upstream-tutorial/`](upstream-tutorial/README.md) — read it on one screen, type
in the container on the other.

Two bases, both first-class and **verified end-to-end** ([proof per distro in
MANUAL_TESTING](MANUAL_TESTING.md)):

| Spec | Base | Default text tools | What `setup-workshop.sh` installs |
|---|---|---|---|
| [`sculpting-text-debian.toml`](sculpting-text-debian.toml) | Debian 13 (trixie) | **GNU grep/sed**, but `awk` = **mawk** | `gawk` (+ less) + the sandbox |
| [`sculpting-text-alpine.toml`](sculpting-text-alpine.toml) | Alpine | **BusyBox** grep/sed/awk | **GNU grep + sed + gawk** + the sandbox |

> The article is written for the **GNU** dialects — `grep -E` backreferences, GNU
> `sed`'s `\U`, gawk functions/arrays. Alpine's default tools are BusyBox applets
> that quietly diverge (and Debian's default `awk` is mawk, which lacks gawk
> features), so the lab installs the GNU trio on both — a documented divergence,
> [below](#documented-divergence-busybox-and-mawk-are-not-gnu).

## Quick start

Both bases are first-class — pick either (or run both; the labs are independent
and coexist). The flow is identical bar the name:

```bash
# ── Alpine (musl / BusyBox base) ────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-sculpting-text-regex-grep-sed-awk/sculpting-text-alpine.toml
examples/UNIX-sculpting-text-regex-grep-sed-awk/setup-workshop.sh sculpting-text-alpine/shell   # ~1 min
phase5-lxd/lab-lxd.sh exec sculpting-text-alpine/shell -- su - learner                          # start sculpting
phase5-lxd/lab-lxd.sh down --lab sculpting-text-alpine                                          # tear down

# ── Debian 13 (trixie / glibc base) ─────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/UNIX-sculpting-text-regex-grep-sed-awk/sculpting-text-debian.toml
examples/UNIX-sculpting-text-regex-grep-sed-awk/setup-workshop.sh sculpting-text-debian/shell
phase5-lxd/lab-lxd.sh exec sculpting-text-debian/shell -- su - learner
phase5-lxd/lab-lxd.sh down --lab sculpting-text-debian
```

Then **open the guide**
([`upstream-tutorial/articles/sculpting-text/index.html`](upstream-tutorial/articles/sculpting-text/index.html))
in your viewer and follow along, running pipelines in `~/sculpting-text/` inside
the `su - learner` shell. A runnable `demo.sh` and sample data are already there.

## What `setup-workshop.sh` does

Automated counterpart to the by-hand walk in [RUNBOOK.md](RUNBOOK.md); it touches
the guest **only** through `lab-lxd.sh exec` (engine-agnostic), in five steps:

1. **detect** the distro (`/etc/alpine-release` vs `/etc/debian_version`);
2. **install** the GNU text trio — `grep`, `sed`, `gawk` (+ `less`) — and symlink
   `awk` → `gawk` so it means gawk on both bases;
3. **create** a non-root `learner` user (POSIX `/bin/sh` login — this lab is about
   the text tools, not shell scripting);
4. **install** the `~/sculpting-text/` sandbox (sample `words`, `passwd`,
   `access_log`, `dupes.txt`, and `demo.sh`) and populate `/usr/share/dict/words`;
5. **verify** as `learner` — print the tool versions and **run `demo.sh`**.

## The guide

A single dense page ([provenance + `sha256`](upstream-tutorial/README.md)). It
moves through:

- **Regex theory** — regular languages, DFAs/NFAs, the regex operators
- **grep** — POSIX **basic** regex; useful flags (`-i -v -c -n -o -E`); POSIX
  **extended** regex (egrep); the **backreference** prime/doubled-string trick
- **sed** — numeric and pattern **addresses**; the **substitute** command and its
  flags; delete/print/append; multi-command scripts; worked examples
- **awk** — the **pattern { action }** model; fields and `-F`; **expressions**,
  **arrays** (associative), **special variables** (`NR`, `NF`, `$0`…),
  **control statements**, **functions**, built-ins, useful flags
- **vim & emacs** — the same regex muscle inside your editor

Everything it needs is `grep`/`sed`/`gawk` and a little sample data — installed
and verified on **both** bases. The sandbox's `demo.sh` runs a spread of the
article's constructs and prints the **same output on Debian and Alpine**:

```
== grep (ERE backreference): words that are a doubled string  ^(.*)\1$ ==
murmur
tartar
couscous
...
== sed: substitute, then GNU \U to upper-case the match ==
the dog sat on the MAT
== awk -F: pattern-action — skip comments, print name + uid ==
root 0
...
```

### Documented divergence: BusyBox (and mawk) are not GNU

This is the lab's honest teaching beat. The article's pipelines assume the **GNU**
tools; the stock containers don't all provide them. Captured from a **bare**
Alpine (BusyBox), contrasted with GNU:

```
# GNU sed's \U upper-cases the match; BusyBox sed takes \U literally:
$ echo hello | busybox sed 's/.*/\U&/'      ->  Uhello
$ echo hello | sed         's/.*/\U&/'      ->  HELLO

# GNU grep -E supports backreferences (the article's doubled-string finder);
# BusyBox grep does not, so it silently matches nothing:
$ printf 'murmur\ntartar\n' | busybox grep -E '^(.*)\1$'   ->  (no matches)
$ printf 'murmur\ntartar\n' | grep         -E '^(.*)\1$'   ->  murmur / tartar
```

And it is not only Alpine: **Debian's default `awk` is mawk**, which has no
`gensub()` and a smaller feature set than gawk. So the lab installs **gawk on
both** and points `awk` at it. There is no `wamerican`/`words` dictionary package
on Alpine either (Debian has one), so the lab ships its own compact
`/usr/share/dict/words` — identical on both, which is *why* the examples above
match exactly. After setup, every pipeline runs the same on glibc and musl. The
bare-BusyBox behavior is captured verbatim in
[MANUAL_TESTING](MANUAL_TESTING.md#documented-divergence-busybox-and-mawk-are-not-gnu).

## Files

| File | Purpose |
|---|---|
| [`sculpting-text-debian.toml`](sculpting-text-debian.toml) / [`sculpting-text-alpine.toml`](sculpting-text-alpine.toml) | Phase-5 specs: one container each |
| [`setup-workshop.sh`](setup-workshop.sh) | Provision GNU tools + `learner` + the sandbox |
| [`demo.sh`](demo.sh) | The runnable spread of grep/sed/awk examples |
| [`sample-data/`](sample-data/) | `words`, `passwd`, `access_log`, `dupes.txt` — the demo's inputs |
| [`RUNBOOK.md`](RUNBOOK.md) | The by-hand walk — every step, with the *why* |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Real captured transcripts (both distros) |
| [`upstream-tutorial/`](upstream-tutorial/README.md) | Byte-exact guide (© Matt Might) + CSS + provenance |

## Scope & caveats

- **Throwaway lab.** Containers are disposable; `down` wipes them. No persistent
  state, no real credentials. Re-run the quick start for a clean slate.
- **Non-root `learner`.** Sculpting is done as an ordinary user; the container's
  root is only used by `setup-workshop.sh`.
- **System container, not a VM.** Plenty for a text-processing course.
- **A compact, curated `/usr/share/dict/words`.** Real systems have a much larger
  one (from `wamerican`/`words` on Debian; Alpine ships no clean equivalent). The
  lab supplies a small list so the examples are crisp and **identical** on both
  bases — `apt install wamerican` inside the Debian box if you want the full
  ~100k-word dictionary to explore.
- **Read the guide on the host, type in the container.** It lives in this repo;
  open it in your viewer, run pipelines via `exec … su - learner`.

## Prerequisites

- **LXD or Incus initialised** — `incus admin init` (or `lxd init`). See the
  Phase-5 docs: [`START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- Outbound network from the container (to `apt`/`apk` the tools).

## Sources

The guide is © **Matt Might** and carries no explicit open license; it is vendored
byte-exact for **offline educational reference** under
[`upstream-tutorial/`](upstream-tutorial/README.md) (provenance + `sha256` +
attribution).

- Guide: <https://matt.might.net/articles/sculpting-text/>

This is a Phase-5 sibling to the other Matt Might labs — the
[*survival guide*](../UNIX_novice_survival_guide/README.md),
[*bash by example*](../shell-intermediate-programming-by-example/README.md), and
[*Hello, Perceptron*](../AI-build-a-perceptron/README.md) — same "vendor the page,
build the sandbox, learn by doing" shape, different subject.

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog.

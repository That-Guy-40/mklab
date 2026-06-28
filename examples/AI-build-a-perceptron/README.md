# AI-build-a-perceptron — a Python box for Matt Might's "Hello, Perceptron"

A **throwaway system container** with **Python 3** (standard library only — no
numpy, no frameworks), a non-root **`learner`** user, and a `~/hello-perceptron/`
scratch directory (with a runnable starter that **trains a perceptron from
scratch**), so you can work through **Matt Might's**
**["Hello, Perceptron: An introduction to artificial neural networks"](upstream-tutorial/articles/hello-perceptron/index.html)**
— *building and training the simplest neural unit by hand* as you read. Built and
driven through the repo's **Phase-5** tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically.

Might's article is a from-first-principles tour: a biological neuron → the
**perceptron** (a weighted sum past a threshold) → a **classifier** → the
**perceptron learning algorithm** that discovers weights from examples. You train
one to compute **AND** and **OR**, then hit the famous wall — a single perceptron
**cannot** learn **XOR** (it is not linearly separable) — which is exactly why
real networks stack neurons into **layers**. ~40 lines of plain Python, no
libraries, and the whole "how does a neural net actually learn?" mystery cracked
open.

The article is vendored byte-exact under
[`upstream-tutorial/`](upstream-tutorial/README.md) — read it on one screen, type
in the container on the other.

Two bases, both first-class and **verified end-to-end** ([proof per distro in
MANUAL_TESTING](MANUAL_TESTING.md)):

| Spec | Base | Default interpreter | What `setup-workshop.sh` installs |
|---|---|---|---|
| [`perceptron-debian.toml`](perceptron-debian.toml) | Debian 13 (trixie) | **none** (no python at all) | `python3` (3.13) + nano + less |
| [`perceptron-alpine.toml`](perceptron-alpine.toml) | Alpine | **none** (no python at all) | `python3` (3.14) + nano + less |

> Unlike the shell labs, **neither** base ships an interpreter, so both install
> `python3`. The pure-stdlib code then runs **byte-for-byte identically** on
> glibc and musl. The one real difference is in *naming*, and it runs the other
> way from the usual "Alpine is the spartan one" — [below](#documented-divergence-on-debian-python-is-not-python3).

## Quick start

Both bases are first-class — pick either (or run both; the labs are independent
and coexist). The flow is identical bar the name:

```bash
# ── Alpine (musl / BusyBox base) ────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/AI-build-a-perceptron/perceptron-alpine.toml
examples/AI-build-a-perceptron/setup-workshop.sh perceptron-alpine/python      # ~1 min
phase5-lxd/lab-lxd.sh exec perceptron-alpine/python -- su - learner            # start hacking
phase5-lxd/lab-lxd.sh down --lab perceptron-alpine                             # tear down

# ── Debian 13 (trixie / glibc base) ─────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/AI-build-a-perceptron/perceptron-debian.toml
examples/AI-build-a-perceptron/setup-workshop.sh perceptron-debian/python
phase5-lxd/lab-lxd.sh exec perceptron-debian/python -- su - learner
phase5-lxd/lab-lxd.sh down --lab perceptron-debian
```

Then **open the article**
([`upstream-tutorial/articles/hello-perceptron/index.html`](upstream-tutorial/articles/hello-perceptron/index.html))
in your viewer and follow along, writing code in `~/hello-perceptron/` inside the
`su - learner` shell. A runnable starter (`demo.py`) is already there.

## What `setup-workshop.sh` does

Automated counterpart to the by-hand walk in [RUNBOOK.md](RUNBOOK.md); it touches
the guest **only** through `lab-lxd.sh exec` (engine-agnostic), in five steps:

1. **detect** the distro (`/etc/alpine-release` vs `/etc/debian_version`);
2. **install** `python3` + a small editor/pager (`apt`/`apk`) — no third-party
   Python packages, because the article uses none;
3. **create** a non-root `learner` user (POSIX `/bin/sh` login — this lab is about
   Python, not the shell);
4. **create** `~/hello-perceptron/demo.py` — the article's own `perceptron()` and
   `train_perceptron()`, training **AND** and **OR** (which succeed) and **XOR**
   (which cannot), with a seeded RNG so the run is reproducible;
5. **verify** as `learner` — print `python3 --version` and **run the starter**.

## The article

A single page, an evening at a steady pace ([provenance +
`sha256`](upstream-tutorial/README.md)). It moves through:

- **What is a (biological) neuron** — the inspiration, then the abstraction
- **The perceptron** — inputs × weights, summed, past a **threshold**; in code,
  `perceptron(inputs, weights, threshold)`
- **Classifiers & linear separability** — what one neuron can decide
- **NOT, AND, OR by hand** — pick weights yourself, then…
- **The perceptron learning algorithm** — `train_perceptron()`: present examples,
  measure the error, nudge the weights, repeat until it converges
- **The XOR wall** — train and train and it **still** fails; *why* (one straight
  line cannot separate XOR)
- **Onward to real nets** — multilayer perceptrons, activation functions
  (sigmoid/tanh/ReLU), backpropagation and gradient descent

Everything it needs is `python3` and a text editor — installed and verified on
**both** bases.

### Documented divergence: on Debian, `python` is *not* `python3`

The interpreter runs the article's code identically on both distros (it is pure
stdlib — only `random`). The honest difference is in the **command name**, and it
is the *reverse* of the usual story:

```
# Debian 13 — Python 3.13, and only `python3` exists:
$ python --version
bash: python: command not found        # Debian/PEP 394 reserve the bare name
$ python3 --version
Python 3.13.5

# Alpine — Python 3.14, and the apk ALSO provides `python`:
$ python --version
Python 3.14.5                           # /usr/bin/python is present
```

So here **Alpine is the more forgiving base** (newer interpreter, and a bare
`python` that just works), while **Debian** deliberately ships only `python3`
(running `python` needs the `python-is-python3` package). This lab uses `python3`
everywhere, so it works the same on both — but it is a classic real-world gotcha,
captured verbatim in
[MANUAL_TESTING](MANUAL_TESTING.md#documented-divergence-on-debian-python-is-not-python3).
The deeper point the article rides on — *pure-stdlib Python is portable across
libc and version* — is why the trained weights come out **bit-identical** on
glibc-3.13 and musl-3.14 (Python's RNG is the same Mersenne Twister everywhere).

## Files

| File | Purpose |
|---|---|
| [`perceptron-debian.toml`](perceptron-debian.toml) / [`perceptron-alpine.toml`](perceptron-alpine.toml) | Phase-5 specs: one container each |
| [`setup-workshop.sh`](setup-workshop.sh) | Provision python3 + `learner` user + playground |
| [`RUNBOOK.md`](RUNBOOK.md) | The by-hand walk — every step, with the *why* |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Real captured transcripts (both distros) |
| [`upstream-tutorial/`](upstream-tutorial/README.md) | Byte-exact article (© Matt Might) + diagrams + CSS + provenance |

## Scope & caveats

- **Throwaway lab.** Containers are disposable; `down` wipes them. No persistent
  state, no real credentials. Re-run the quick start for a clean slate.
- **Non-root `learner`.** Coding is done as an ordinary user; the container's root
  is only used by `setup-workshop.sh`.
- **System container, not a VM.** Plenty for a from-scratch ML tutorial.
- **No GPU, no frameworks — and that is the point.** The article builds a neuron
  in plain Python so nothing is hidden behind a library. The later sections
  (backprop, gradient descent) are *described*, not coded; this lab gives you the
  perceptron the article actually implements.
- **Read the article on the host, type in the container.** It lives in this repo;
  open it in your viewer, run code via `exec … su - learner`.

## Prerequisites

- **LXD or Incus initialised** — `incus admin init` (or `lxd init`). See the
  Phase-5 docs: [`START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- Outbound network from the container (to `apt`/`apk` the interpreter).

## Sources

The article is © **Matt Might** and carries no explicit open license; it is
vendored byte-exact for **offline educational reference** under
[`upstream-tutorial/`](upstream-tutorial/README.md) (provenance + `sha256` +
attribution, including the two inline diagrams).

- Article: <https://matt.might.net/articles/hello-perceptron/>

This is a Phase-5 sibling to the Matt Might **shell** labs — the
[*survival guide*](../UNIX_novice_survival_guide/README.md) and
[*bash by example*](../shell-intermediate-programming-by-example/README.md) — same
"vendor the page, build the sandbox, learn by doing" shape, different subject.

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog.

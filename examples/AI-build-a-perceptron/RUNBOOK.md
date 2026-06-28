# RUNBOOK — prepare the perceptron box by hand, step by step

This is the **by-hand walk**: every command [`setup-workshop.sh`](setup-workshop.sh)
runs, with the *why* at each step. Do it once by hand to understand what a
from-scratch ML sandbox needs; use the script afterward. It prepares a **Python 3**
playground for **Matt Might's**
[*"Hello, Perceptron: An introduction to artificial neural networks"*](upstream-tutorial/articles/hello-perceptron/index.html)
— his neural-net primer, a sibling to the Matt-Might shell guides
([survival guide](../UNIX_novice_survival_guide/README.md),
[bash by example](../shell-intermediate-programming-by-example/README.md)).

Everything goes through the Phase-5 tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically. Run commands from the repo root.

## Pick a base — Debian **or** Alpine (both fully supported)

Both bases are first-class and **verified end-to-end** ([proof for each in
MANUAL_TESTING](MANUAL_TESTING.md)). For this lab they differ only in the package
manager and in interpreter *naming* — **neither** ships Python by default (see
[the `python` vs `python3` divergence](#python-vs-python3)):

| | Debian 13 (trixie) | Alpine |
|---|---|---|
| spec | [`perceptron-debian.toml`](perceptron-debian.toml) | [`perceptron-alpine.toml`](perceptron-alpine.toml) |
| image | `images:debian/13` (glibc, GNU userland) | `images:alpine/latest` (musl, BusyBox userland) |
| lab/service handle | `perceptron-debian/python` | `perceptron-alpine/python` |
| installer | `apt-get` | `apk` |
| Python after install | 3.13, `python3` only | 3.14, `python3` **and** `python` |

Pick your base — the rest of the walk reads the same for both:

```bash
LAB=perceptron-debian        # Debian 13 (trixie)
# - or -
LAB=perceptron-alpine        # Alpine
```

(Just want it ready without the narration? Jump to
[Just run it](#just-run-it-either-base).)

## 0. Prerequisites

LXD or Incus must be initialised (`incus admin init` or `lxd init`). See
[`../../phase5-lxd/START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
The container needs outbound network to fetch the interpreter.

## 1. Bring up the container

```bash
phase5-lxd/lab-lxd.sh up --config examples/AI-build-a-perceptron/$LAB.toml
```

One unprivileged **system container** — a full userland with a package manager and
an init — which is what we want: we install an interpreter and add a user, like
setting up a real Linux box to learn on.

## 2. Install Python 3 (+ a small editor/pager)

The article is **pure standard-library Python** — the only import is `random`. So
there are **no** third-party packages to install; we just need the interpreter,
plus `nano`/`less` to edit and read code. This is the step that differs by base —
and the difference is smaller than the shell labs, because **neither** base ships
Python:

```bash
# Debian (perceptron-debian/python) — base has no python; install python3 + tools:
phase5-lxd/lab-lxd.sh exec perceptron-debian/python -- \
    sh -c 'apt-get update -qq && apt-get install -y --no-install-recommends \
           python3 nano less'

# Alpine (perceptron-alpine/python) — base has no python either; same idea, apk.
# (`shadow` provides useradd-style tooling; we use adduser below, but it is handy.)
phase5-lxd/lab-lxd.sh exec perceptron-alpine/python -- \
    apk add --no-cache python3 nano less shadow
```

### `python` vs `python3`

After this step, run `python3 --version` on each base. You will get **Python 3.13**
on Debian and **3.14** on Alpine — both new enough; the article uses nothing
version-specific. But try the bare name:

```bash
phase5-lxd/lab-lxd.sh exec perceptron-debian/python -- python --version
# bash: python: command not found        ← Debian ships ONLY python3 (PEP 394 /
#                                           Debian policy reserve the bare name)

phase5-lxd/lab-lxd.sh exec perceptron-alpine/python -- python --version
# Python 3.14.5                           ← Alpine's python3 apk also drops in
#                                           /usr/bin/python
```

So, unusually, **Alpine is the more forgiving base here**. We always invoke
`python3` in this lab, so it works the same on both; on Debian you would
`apt install python-is-python3` if you wanted the bare `python` to work. The
bare-base behavior is captured in
[MANUAL_TESTING](MANUAL_TESTING.md#documented-divergence-on-debian-python-is-not-python3).

## 3. Create the non-root `learner` user

You learn as an ordinary user — authentic prompt, real `whoami`, sane file
ownership. No bash is installed (this lab is about Python, not the shell), so the
login shell is the base `/bin/sh` (dash on Debian, BusyBox ash on Alpine) — plenty
to edit a file and run `python3`.

```bash
# Debian:
phase5-lxd/lab-lxd.sh exec perceptron-debian/python -- \
    sh -c 'id learner >/dev/null 2>&1 || useradd -m -s /bin/sh learner'

# Alpine (adduser, not useradd):
phase5-lxd/lab-lxd.sh exec perceptron-alpine/python -- \
    sh -c 'id learner >/dev/null 2>&1 || adduser -D -s /bin/sh learner'
```

## 4. Make a coding playground

Give the learner somewhere to write code, with a runnable starter — the article's
own `perceptron()` and `train_perceptron()`, training **AND** and **OR** (which
converge) and **XOR** (which cannot), with a seeded RNG so the result reproduces:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/python -- su - learner -c '
mkdir -p ~/hello-perceptron
cat > ~/hello-perceptron/demo.py <<"EOS"
#!/usr/bin/env python3
import random

def perceptron(inputs, weights, threshold):
    weighted_sum = sum(x * w for x, w in zip(inputs, weights))
    return 1 if weighted_sum >= threshold else 0

def train_perceptron(data, learning_rate=0.1, max_iter=1000):
    num_inputs = len(data[0][0])
    weights = [random.random() for _ in range(num_inputs)]
    threshold = random.random()
    for _ in range(max_iter):
        num_errors = 0
        for inputs, desired in data:
            output = perceptron(inputs, weights, threshold)
            error = desired - output
            if error != 0:
                num_errors += 1
                for i in range(num_inputs):
                    weights[i] += learning_rate * error * inputs[i]
                threshold -= learning_rate * error
        if num_errors == 0:
            break
    return weights, threshold

AND = [((0, 0), 0), ((0, 1), 0), ((1, 0), 0), ((1, 1), 1)]
OR  = [((0, 0), 0), ((0, 1), 1), ((1, 0), 1), ((1, 1), 1)]
XOR = [((0, 0), 0), ((0, 1), 1), ((1, 0), 1), ((1, 1), 0)]

def report(name, data, max_iter=1000):
    weights, threshold = train_perceptron(data, max_iter=max_iter)
    correct = 0
    rows = []
    for inputs, desired in data:
        got = perceptron(inputs, weights, threshold)
        ok = (got == desired)
        correct += ok
        rows.append("    %s -> got %d  want %d  %s"
                    % (inputs, got, desired, "ok" if ok else "WRONG"))
    verdict = "LEARNED" if correct == len(data) else "FAILED to learn"
    print("%s: %s (%d/%d rows correct)" % (name, verdict, correct, len(data)))
    print("\n".join(rows))
    print()

random.seed(1)
report("AND", AND)
report("OR",  OR)
report("XOR", XOR, max_iter=10000)
print("Why XOR fails: a single perceptron draws ONE straight line, and XOR is")
print("not linearly separable -- no straight line splits its 1s from its 0s.")
EOS
chmod +x ~/hello-perceptron/demo.py'
```

(The full file, with the article-matching comments, is what
[`setup-workshop.sh`](setup-workshop.sh) writes.)

## 5. Verify, then start hacking

```bash
phase5-lxd/lab-lxd.sh exec $LAB/python -- su - learner -c \
    'python3 --version; python3 ~/hello-perceptron/demo.py'
```

You should see **AND** and **OR** report `LEARNED (4/4)` and **XOR** report
`FAILED to learn` — the article's punchline, that one perceptron cannot do XOR.
Now **drop into the learner's shell**:

```bash
phase5-lxd/lab-lxd.sh exec $LAB/python -- su - learner
```

For example, starting on **Alpine** is just:

```bash
phase5-lxd/lab-lxd.sh exec perceptron-alpine/python -- su - learner
```

…and Debian is identical bar the name. Then open
[`upstream-tutorial/articles/hello-perceptron/index.html`](upstream-tutorial/articles/hello-perceptron/index.html)
in your viewer and work through it, editing `~/hello-perceptron/demo.py` (e.g. try
your own weights for NOT/AND, or feed `train_perceptron` a new truth table).

## 6. Teardown

```bash
phase5-lxd/lab-lxd.sh down --lab $LAB        # perceptron-debian or -alpine
```

`down` stops and deletes the container; nothing persists.

## Just run it (either base)

Steps 2–5 are exactly what [`setup-workshop.sh`](setup-workshop.sh) automates. The
full path, shown concretely for **both** bases — pick whichever (or run both,
they're independent):

```bash
# ── Alpine (musl / BusyBox) ─────────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/AI-build-a-perceptron/perceptron-alpine.toml
examples/AI-build-a-perceptron/setup-workshop.sh perceptron-alpine/python   # python3 + learner + playground
phase5-lxd/lab-lxd.sh exec perceptron-alpine/python -- su - learner         # start hacking
phase5-lxd/lab-lxd.sh down --lab perceptron-alpine                          # done

# ── Debian 13 (glibc) ───────────────────────────────────────────
phase5-lxd/lab-lxd.sh up --config examples/AI-build-a-perceptron/perceptron-debian.toml
examples/AI-build-a-perceptron/setup-workshop.sh perceptron-debian/python
phase5-lxd/lab-lxd.sh exec perceptron-debian/python -- su - learner
phase5-lxd/lab-lxd.sh down --lab perceptron-debian
```

## Gotchas

- **`python: command not found` on Debian** → Debian ships only `python3` (it
  reserves the bare `python` name). Use `python3`, or
  `apt install python-is-python3`. On Alpine the `python3` apk already provides
  `python`. See [`python` vs `python3`](#python-vs-python3).
- **XOR "failing" looks like a bug — it isn't.** A single perceptron *provably*
  cannot learn XOR (it is not linearly separable). The starter even gives XOR 10×
  the training cycles to make the point. That wall is the whole reason the article
  moves on to multilayer networks.
- **Re-running training gives different weights** → that is expected;
  `train_perceptron` starts from `random` weights. The starter calls
  `random.seed(1)` so its printed run is reproducible; delete the seed to watch it
  vary (AND/OR still converge, XOR still fails).
- **`nano`/`less`/REPL looks garbled / "unknown terminal type"** → your client's
  `$TERM` (e.g. Ghostty's `xterm-ghostty`) has no terminfo entry inside the
  container. `lab-lxd.sh exec` sets `TERM=xterm` for interactive sessions so
  editing your code and the `python3` REPL behave; override with `LAB_TERM` (e.g.
  `LAB_TERM=xterm-256color`). See
  [START_HERE](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- **The two diagrams show as broken images offline** → the byte-exact page links
  them by absolute URL; they load with network, and are archived alongside for
  provenance. The lesson text reads fine offline. See
  [`upstream-tutorial/README.md`](upstream-tutorial/README.md).
- **Image won't download / `up` hangs** → the `images:` remote can stall; it's not
  a lab bug. Pre-pull once with `incus image copy images:alpine/3.24 local:` (or
  `images:debian/13`) and retry.

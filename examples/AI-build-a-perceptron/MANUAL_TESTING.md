# MANUAL_TESTING — captured transcripts

Real output from preparing and exercising this lab end-to-end on the host (Incus,
system containers), both distros. The environment is provisioned, then perceptron
code **straight from the article** is run **as the `learner` user** to prove the
sandbox works. Trimmed only for length (package noise), never edited.

| Check | Debian 13 (glibc) | Alpine (musl) |
|---|---|---|
| `up` container | ✅ | ✅ |
| install `python3` | ✅ 3.13.5 | ✅ 3.14.5 |
| `learner` user, `/bin/sh` login | ✅ | ✅ |
| starter `demo.py` runs | ✅ | ✅ |
| AND trains | ✅ `LEARNED (4/4)` | ✅ `LEARNED (4/4)` |
| OR trains | ✅ `LEARNED (4/4)` | ✅ `LEARNED (4/4)` |
| XOR fails (the point) | ✅ `FAILED to learn (1/4)` | ✅ `FAILED to learn (1/4)` |
| identical output across versions | ✅ (same Mersenne-Twister RNG) | ✅ |
| NOT / is_nonnegative by hand | ✅ | ✅ |
| `python` (bare name) | ❌ absent (only `python3`) | ✅ `/usr/bin/python` |

The seeded run is **bit-identical** on Debian's Python 3.13 and Alpine's 3.14 —
pure-stdlib Python is portable across libc and interpreter version.

---

## Debian 13 (trixie)

```
$ phase5-lxd/lab-lxd.sh up --config examples/AI-build-a-perceptron/perceptron-debian.toml
[info] ── lab 'perceptron-debian' up (1 incus instance(s), 0 skipped) ──

$ examples/AI-build-a-perceptron/setup-workshop.sh perceptron-debian/python
==> [1/5] detecting distro in perceptron-debian/python
    distro=debian
==> [2/5] installing Python 3 + a small editor/pager
  ... NEW packages: less nano ...   (python3 already 3.13.5-1)
==> [3/5] creating the non-root 'learner' user (POSIX /bin/sh login)
==> [4/5] creating the ~/hello-perceptron playground with a starter script
==> [5/5] verifying the playground (as learner): run the starter script
  whoami : learner
  python : Python 3.13.5
  pwd    : /home/learner
  --- running ~/hello-perceptron/demo.py ---
AND: LEARNED (4/4 rows correct)
    (0, 0) -> got 0  want 0  ok
    (0, 1) -> got 0  want 0  ok
    (1, 0) -> got 0  want 0  ok
    (1, 1) -> got 1  want 1  ok

OR: LEARNED (4/4 rows correct)
    (0, 0) -> got 0  want 0  ok
    (0, 1) -> got 1  want 1  ok
    (1, 0) -> got 1  want 1  ok
    (1, 1) -> got 1  want 1  ok

XOR: FAILED to learn (1/4 rows correct)
    (0, 0) -> got 1  want 0  WRONG
    (0, 1) -> got 1  want 1  ok
    (1, 0) -> got 0  want 1  WRONG
    (1, 1) -> got 1  want 0  WRONG

Why XOR fails: a single perceptron draws ONE straight line, and XOR is
not linearly separable -- no straight line splits its 1s from its 0s.
That wall is exactly why real networks stack many neurons into layers.
==> done.  Perceptron sandbox ready in perceptron-debian/python.
```

A couple of the article's hand-built gates, run as `learner`:

```
$ phase5-lxd/lab-lxd.sh exec perceptron-debian/python -- python3 --version
Python 3.13.5

# "NOT, AND, OR" — the perceptron with hand-picked weights (no training)
$ python3 - <<'PY'
def perceptron(inputs, weights, threshold):
    return 1 if sum(x*w for x,w in zip(inputs,weights)) >= threshold else 0
def not_function(x):   return perceptron([x], [-1], -0.5)
def is_nonnegative(x): return perceptron([x], [1], 0)
print("NOT(0) =", not_function(0), "  NOT(1) =", not_function(1))
print("is_nonnegative(5) =", is_nonnegative(5), "  is_nonnegative(-3) =", is_nonnegative(-3))
PY
NOT(0) = 1   NOT(1) = 0
is_nonnegative(5) = 1   is_nonnegative(-3) = 0
```

---

## Alpine

```
$ phase5-lxd/lab-lxd.sh up --config examples/AI-build-a-perceptron/perceptron-alpine.toml
[info] resolved images:alpine/latest → images:alpine/3.24
[info] ── lab 'perceptron-alpine' up (1 incus instance(s), 0 skipped) ──

$ examples/AI-build-a-perceptron/setup-workshop.sh perceptron-alpine/python
==> [2/5] installing Python 3 + a small editor/pager
  (1/8) Installing less ... nano ... shadow (4.18.0-r1)
  OK: 52.0 MiB in 57 packages
==> [5/5] verifying the playground (as learner): run the starter script
  whoami : learner
  python : Python 3.14.5
  pwd    : /home/learner
  --- running ~/hello-perceptron/demo.py ---
AND: LEARNED (4/4 rows correct)
    (0, 0) -> got 0  want 0  ok
    (0, 1) -> got 0  want 0  ok
    (1, 0) -> got 0  want 0  ok
    (1, 1) -> got 1  want 1  ok

OR: LEARNED (4/4 rows correct)
    (0, 0) -> got 0  want 0  ok
    (0, 1) -> got 1  want 1  ok
    (1, 0) -> got 1  want 1  ok
    (1, 1) -> got 1  want 1  ok

XOR: FAILED to learn (1/4 rows correct)
    (0, 0) -> got 1  want 0  WRONG
    (0, 1) -> got 1  want 1  ok
    (1, 0) -> got 0  want 1  WRONG
    (1, 1) -> got 1  want 0  WRONG

Why XOR fails: a single perceptron draws ONE straight line, and XOR is
not linearly separable -- no straight line splits its 1s from its 0s.
That wall is exactly why real networks stack many neurons into layers.
==> done.  Perceptron sandbox ready in perceptron-alpine/python.
```

Same hand-built gates — **identical results** to Debian on a musl base, on a
*newer* interpreter:

```
$ phase5-lxd/lab-lxd.sh exec perceptron-alpine/python -- python3 --version
Python 3.14.5

$ python3 - <<'PY'   # same script as Debian
...
PY
NOT(0) = 1   NOT(1) = 0
is_nonnegative(5) = 1   is_nonnegative(-3) = 0
```

Note the AND/OR/XOR run above is **byte-for-byte the same** as Debian's despite
3.14 vs 3.13 — the starter seeds `random`, and CPython's RNG is the same Mersenne
Twister on every platform and version.

---

## Documented divergence: on Debian, `python` is not `python3`

Neither bare base ships Python, so both install `python3`. The one real
difference is the **command name** — and it runs opposite to the usual "Alpine is
the spartan one":

```
# Debian 13 — only python3 exists; the bare name is reserved (PEP 394 / policy)
$ phase5-lxd/lab-lxd.sh exec perceptron-debian/python -- sh -c 'command -v python || echo ABSENT'
ABSENT
$ phase5-lxd/lab-lxd.sh exec perceptron-debian/python -- python3 --version
Python 3.13.5

# Alpine — the python3 apk ALSO provides /usr/bin/python
$ phase5-lxd/lab-lxd.sh exec perceptron-alpine/python -- sh -c 'command -v python'
/usr/bin/python
$ phase5-lxd/lab-lxd.sh exec perceptron-alpine/python -- python --version
Python 3.14.5
```

So on Debian, `python demo.py` gives `command not found`; use `python3` (or
install `python-is-python3`). This lab invokes `python3` everywhere, so the
article runs identically on both. Debian deliberately keeps the bare `python` name
unbound to avoid the historical Python-2-vs-3 ambiguity; Alpine wires it to
`python3`.

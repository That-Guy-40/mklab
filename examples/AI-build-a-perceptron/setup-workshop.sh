#!/usr/bin/env bash
# setup-workshop.sh — turn a fresh LXD/Incus container into a ready Python sandbox
# for Matt Might's "Hello, Perceptron": Python 3 (stdlib only — no numpy, no
# frameworks), a non-root `learner` user, and a `~/hello-perceptron/` playground
# with a runnable starter that builds a perceptron, trains it on AND and OR, and
# watches it FAIL on XOR (the tutorial's punchline).
#
# It drives ONLY the Phase-5 tool (phase5-lxd/lab-lxd.sh exec), so it is
# engine-agnostic (LXD or Incus). Run it AFTER `lab-lxd.sh up`:
#
#   phase5-lxd/lab-lxd.sh up --config examples/AI-build-a-perceptron/perceptron-debian.toml
#   examples/AI-build-a-perceptron/setup-workshop.sh perceptron-debian/python
#
# Distro (Debian vs Alpine) is auto-detected; override with DISTRO=debian|alpine.
# This is the automated counterpart to the by-hand walk in RUNBOOK.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LXD="$REPO_ROOT/phase5-lxd/lab-lxd.sh"
LEARNER="learner"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <lab>/<service>   (e.g. perceptron-debian/python)" >&2; exit 1; }
[[ -x "$LXD" ]] || { echo "not found: $LXD" >&2; exit 1; }

# Every guest command goes through the phase tool.
g() { "$LXD" exec "$TARGET" -- "$@"; }

echo "==> [1/5] detecting distro in $TARGET"
DISTRO="${DISTRO:-}"
if [[ -z "$DISTRO" ]]; then
    if   g sh -c '[ -f /etc/alpine-release ]'; then DISTRO=alpine
    elif g sh -c '[ -f /etc/debian_version ]'; then DISTRO=debian
    else echo "could not detect distro; set DISTRO=debian|alpine" >&2; exit 1; fi
fi
echo "    distro=$DISTRO"

echo "==> [2/5] installing Python 3 + a small editor/pager"
# The tutorial needs NO third-party libraries — only the stdlib `random` module.
# So we install just the interpreter plus nano/less to edit and read code.
# NOTE on naming: Debian installs only `python3` (Debian policy / PEP 394 reserves
# the bare `python`); Alpine's python3 apk ALSO provides `/usr/bin/python`. That
# difference is the lab's documented divergence — see RUNBOOK.md.
case "$DISTRO" in
    debian)
        g sh -c 'export DEBIAN_FRONTEND=noninteractive
                 apt-get update -qq
                 apt-get install -y --no-install-recommends python3 nano less' ;;
    alpine)
        g sh -c 'apk add --no-cache python3 nano less shadow' ;;
    *) echo "unknown DISTRO=$DISTRO" >&2; exit 1 ;;
esac

echo "==> [3/5] creating the non-root '$LEARNER' user (POSIX /bin/sh login)"
# No bash is installed (this lab is about Python, not the shell), so the learner
# logs into the base /bin/sh — dash on Debian, BusyBox ash on Alpine. Plenty to
# edit a file and run `python3`.
case "$DISTRO" in
    debian) g sh -c "id $LEARNER >/dev/null 2>&1 || useradd -m -s /bin/sh $LEARNER" ;;
    alpine) g sh -c "id $LEARNER >/dev/null 2>&1 || adduser -D -s /bin/sh $LEARNER" ;;
esac

echo "==> [4/5] creating the ~/hello-perceptron playground with a starter script"
# Quoted heredoc delimiter ("EOS") => nothing in the body is expanded when it is
# written; demo.py is stored verbatim and only runs when the learner does. The
# body deliberately avoids apostrophes so the single-quoted `-c '...'` wrapper
# needs no escaping. The perceptron() and train_perceptron() functions are taken
# faithfully from the article.
g su - "$LEARNER" -c '
mkdir -p ~/hello-perceptron
cat > ~/hello-perceptron/demo.py <<"EOS"
#!/usr/bin/env python3
# "Hello, Perceptron" by example: build a perceptron, train it on AND and OR,
# then watch it FAIL on XOR -- the punchline of the Matt Might tutorial.
# Pure standard library (only the random module); no numpy, no frameworks.

import random

# A perceptron: a weighted sum of inputs fired through a step threshold.
def perceptron(inputs, weights, threshold):
    weighted_sum = sum(x * w for x, w in zip(inputs, weights))
    return 1 if weighted_sum >= threshold else 0

# The perceptron learning algorithm: nudge the weights toward the desired output
# whenever the current guess is wrong; stop early once a full pass has no errors.
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

# Truth tables for the three classic two-input logic functions.
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

random.seed(1)   # fixed seed so the trained weights -- and this output -- repeat
report("AND", AND)
report("OR",  OR)
report("XOR", XOR, max_iter=10000)   # ten times the cycles, and it STILL cannot

print("Why XOR fails: a single perceptron draws ONE straight line, and XOR is")
print("not linearly separable -- no straight line splits its 1s from its 0s.")
print("That wall is exactly why real networks stack many neurons into layers.")
EOS
chmod +x ~/hello-perceptron/demo.py'

echo "==> [5/5] verifying the playground (as $LEARNER): run the starter script"
g su - "$LEARNER" -c '
echo "  whoami : $(whoami)"
echo "  python : $(python3 --version)"
echo "  pwd    : $(pwd)"
echo "  --- running ~/hello-perceptron/demo.py ---"
python3 ~/hello-perceptron/demo.py'

echo
echo "==> done.  Perceptron sandbox ready in $TARGET."
echo "    start it:  $LXD exec $TARGET -- su - $LEARNER"
echo "    then open  examples/AI-build-a-perceptron/upstream-tutorial/articles/hello-perceptron/index.html  and follow along."

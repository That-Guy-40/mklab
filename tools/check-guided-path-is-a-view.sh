#!/usr/bin/env bash
# check-guided-path-is-a-view.sh — §0.2's invariant, made mechanical.
#
#   usage:  tools/check-guided-path-is-a-view.sh [--quiet]
#   exits:  0 = every guided step names a command you could type · 1 = one does not
#
# ── THE INVARIANT ───────────────────────────────────────────────────────────────────────
# MICRO_CLOUD_LAB_PLAN §0.2: *"The guided path is a VIEW of the raw path, never a parallel
# implementation."* Two consequences it draws, and this is the second one:
#
#   > A guided step must name the exact command it runs, and that command must be invocable
#   > by hand. Delete the guided path and nothing is lost.
#
# A guided path that can do something the CLI cannot is the failure the invariant exists to
# catch, and §0.2 asks for exactly this: *"a test asserts that every guided step's declared
# command resolves to a real verb of a real tool."*
#
# ── WHAT COUNTS AS A GUIDED STEP HERE ───────────────────────────────────────────────────
#   * every TUI wizard's `run_hint()` — the commands a novice is told to run after saving
#     the spec the wizard generated. This is the surface the plan calls a teaching ladder,
#     and it is the one that had never been checked.
#   * every `verify_cmd` in examples/learning-paths.toml that names a repo tool.
#
# The five START_HERE_*_WIZARD.md documents are NOT re-checked here: tools/wizard-walkthrough.sh
# already executes their instructions end to end, which is strictly stronger than what this
# does. Two checkers asking the same question is how one of them goes stale.
#
# ── HOW A VERB IS CHECKED, AND WHY IT IS NOT A GREP ─────────────────────────────────────
# Grepping a tool's dispatch `case` for the verb would be a regex over a physical line
# standing in for a question about a command — the mistake tools/check-harness-net.sh made
# twice. So ASK THE TOOL: a driver answers a verb it does not have EXACTLY as it answers a
# verb nobody has. Run both, normalise the verb token out of each answer, and compare.
#
# WORD BOUNDARIES ARE LOAD-BEARING, not tidiness. The same probe in lab_tui/topology.py once
# reported `up` as present on two drivers that never had it, because `sed s/up/VERB/g` also
# rewrote "gro*up*" and "set*up*" in the usage text — different substitutions, different
# strings, "the verb exists". Without \b the probe INVERTS.
#
# ── AND THE SAFETY QUESTION, WHICH IS REAL ──────────────────────────────────────────────
# This probe INVOKES the verb, and the verbs a wizard hands a novice include `up`, `create`
# and `down`. Running those for real would be this repo's opening rule — never let test data
# execute as a live command — broken by its own guard.
#
# It is safe here because every driver in this repo refuses a verb whose required arguments
# are missing, BEFORE doing anything. That is MEASURED, not assumed: all 15 commands the five
# wizards emit were run bare on 2026-08-19 and every one produced a usage refusal with no
# effect (`lab-docker.sh down` → "need a lab name"; `lab-podman.sh up` → "usage: … --config";
# container count unchanged). Three further defences, because a verb added later might not:
#   1. LAB_STATE_DIR is pointed at a throwaway directory for the whole run, so a write lands
#      somewhere disposable;
#   2. a probe whose output does NOT look like a refusal is reported as a WARNING row rather
#      than being quietly accepted — the first verb that acts is named, loudly;
#   3. the probe never passes the wizard's own arguments, only the bare verb. `--lab <lab>`
#      and `--config <file>` are placeholders in a hint, and a placeholder is exactly the
#      kind of test data that must not reach a shell.
#
# ── IT PROVES ITSELF FIRST ──────────────────────────────────────────────────────────────
# §1's scan is aimed at nothing until §0 has watched it catch 3 shapes it must catch and pass
# 4 it must not. The lesson is check-harness-net.sh's, learned twice there: a scan that
# matches nothing and a scan that is broken print the same green ✓.
#
# Its verdict helpers are its own on purpose — a checker that sourced the harness it is
# checking would be supplying its own oracle.
set -uo pipefail

REPO="${REPO:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

say()  { (( QUIET )) || printf '%s\n' "$*"; }
ok()   { (( QUIET )) || printf '  ✓ %s\n' "$*"; }
bad()  { printf '  ✗ %s\n' "$*" >&2; PROBLEMS+=("$*"); }
warn() { printf '  ! %s\n' "$*" >&2; WARNINGS+=("$*"); }

PROBLEMS=(); WARNINGS=()
WORK="$(mktemp -d)"; trap 'rm -rf -- "$WORK"' EXIT
# Every probe runs with state pointed somewhere disposable — see the safety note above.
export LAB_STATE_DIR="$WORK/state"

# The probe and the command parser live in a lib, because tools/check-doc-verbs.sh (TODO
# §11.4) asks the identical question of documentation and must not ask it with a COPY.
# shellcheck source=tools/lib/verb-probe.sh
. "$REPO/tools/lib/verb-probe.sh"

# ── §0. THE CHECKER PROVES ITSELF, BEFORE IT IS AIMED AT ANYTHING REAL ──────────────────
say "§0 controls — the checker is aimed at fixtures first"
_c0_fail=0
_ctl() {  # _ctl <expect: catch|pass> <label> <command-line>
    local expect="$1" label="$2" line="$3" before=${#PROBLEMS[@]}
    check_command "ctl" "$line" >/dev/null 2>&1
    local caught=$(( ${#PROBLEMS[@]} > before ))
    if [[ "$expect" == catch ]] && (( ! caught )); then
        printf '  ✗ CONTROL FAILED (must catch, did not): %s\n' "$label" >&2; _c0_fail=1
    elif [[ "$expect" == pass ]] && (( caught )); then
        printf '  ✗ CONTROL FAILED (must NOT catch, did): %s\n' "$label" >&2; _c0_fail=1
    fi
    PROBLEMS=("${PROBLEMS[@]:0:$before}")   # controls must not pollute the real result
}
_ctl catch "a real tool with a verb it does not have" "phase4-podman/lab-podman.sh zzzznope"
_ctl catch "a tool that does not exist"               "phase9-nothing/lab-nope.sh up"
_ctl catch "a tool named with no verb at all"         "phase4-podman/lab-podman.sh"
_ctl pass  "a flag-first command on a tool with no verbs" "examples/debian-preseed-gallery/fetch-preseeds.sh --no-refresh"
_ctl pass  "a real tool and a real verb"              "phase4-podman/lab-podman.sh up"
_ctl pass  "the same, behind sudo"                    "sudo phase1-chroot/lab-chroot.sh enter"
_ctl pass  "a non-repo command this checker does not judge" "ssh root@10.0.0.1 uptime"

# A CONTROL ON THE SAFETY WARNING ITSELF. Its refusal vocabulary has been widened twice —
# once for `FAIL: must run as root` (fabric.sh) and once for `need --config` (lab-fc.sh) —
# and widening a pattern until a warning stops firing is precisely how a real signal gets
# silenced. So: a tool that ACTS instead of refusing must still trip it. `tools/link_check.py`
# is not it (this checker only judges *.sh), so the subject is a fixture that behaves the way
# a mutating verb would: it prints something that is not a refusal.
_wctl_before=${#WARNINGS[@]}
mkdir -p "$WORK/fixture"
printf '#!/usr/bin/env bash
printf "created 3 widgets\n"
' > "$WORK/fixture/acts.sh"
chmod +x "$WORK/fixture/acts.sh"
verb_present "$WORK/fixture/acts.sh" doit >/dev/null 2>&1 || true
if (( ${#WARNINGS[@]} == _wctl_before )); then
    printf '  ✗ CONTROL FAILED: a verb that ACTS instead of refusing did not raise the safety warning — the refusal vocabulary has been widened until it catches nothing\n' >&2
    _c0_fail=1
fi
WARNINGS=("${WARNINGS[@]:0:$_wctl_before}")
(( _c0_fail == 0 )) || { printf 'FAIL: the checker failed its own controls — nothing below would have meant anything\n' >&2; exit 1; }
ok "8 controls behaved (3 must-catch, 4 must-not-catch, and a verb that ACTS still trips the safety warning)"

# ── §1. EVERY TUI WIZARD'S run_hint() ───────────────────────────────────────────────────
say
say "§1 TUI wizards — the commands each one tells a novice to run"
TUI="$REPO/phase6-tui"
PY=""
for cand in "$TUI/.venv/bin/python" "$(command -v python3 || true)"; do
    [[ -x "$cand" ]] || continue
    "$cand" -c 'import textual' 2>/dev/null && { PY="$cand"; break; }
done
if [[ -z "$PY" ]]; then
    warn "UNKNOWN: no python with textual available — the wizard hints were NOT checked on this run"
else
    # The extractor renders each wizard's REAL run_hint(), with the query helpers patched the
    # way phase6-tui/tests/test_wizards.py patches them. Reading the f-strings out of the
    # source instead would be asserting the mechanism: a hint assembled at runtime from a
    # variable would be invisible to it.
    cat > "$WORK/extract.py" <<'PY'
import importlib, sys
from pathlib import Path
from unittest.mock import patch

# A fixture FIRST, so the extractor is known to do what §1 needs before it is trusted with
# the real wizards: it must emit command lines and drop comments and blanks.
class _Fixture:
    # These exist only so patch.object has something to replace — the real WizardModal
    # defines them, and a fixture that did not would fail for a reason unrelated to what
    # it is fixturing.
    _val = _sel = _chk = staticmethod(lambda w, s: "")

    def run_hint(self, path):
        return "# a comment\n\nphase4-podman/lab-podman.sh up --config x\n\n# another\n"

def _render(obj, cls, val, chk):
    with patch.object(cls, "_val", staticmethod(lambda w, s: val)), \
         patch.object(cls, "_sel", staticmethod(lambda w, s: val)), \
         patch.object(cls, "_chk", staticmethod(lambda w, s: chk)):
        text = obj.run_hint(Path("examples/generated.toml"))
    return [ln.strip() for ln in text.splitlines()
            if ln.strip() and not ln.strip().startswith("#")]


def hint_lines(obj, cls):
    """Every command this wizard can emit, over BOTH shapes of its form.

    Rendering only the empty form misses any branch a hint takes when a field IS set — and
    that is exactly where an unchecked command hides. Phase 7's wizard emits two extra
    `fabric.sh` commands only when a tap was named, so with an empty form those two lines
    do not exist and the checker would have reported a clean run over a hint it had never
    fully seen. Both renders are unioned, order preserved.
    """
    seen, out = set(), []
    for val, chk in (("", False), ("x", True)):
        for line in _render(obj, cls, val, chk):
            if line not in seen:
                seen.add(line)
                out.append(line)
    return out

fx = hint_lines(_Fixture(), _Fixture)
if fx != ["phase4-podman/lab-podman.sh up --config x"]:
    print("EXTRACTOR-CONTROL-FAILED", fx, file=sys.stderr)
    sys.exit(2)

# The registry is DERIVED from the package, not listed here: a sixth wizard added without a
# line in this file would otherwise be a guided surface nothing checks.
import lab_tui.screens.wizards as pkg
from lab_tui.screens.wizards.base import WizardModal
found = 0
for modname in sorted(p.stem for p in Path(pkg.__file__).parent.glob("*.py")
                      if p.stem not in ("__init__", "base")):
    mod = importlib.import_module(f"lab_tui.screens.wizards.{modname}")
    for attr in dir(mod):
        cls = getattr(mod, attr)
        if not (isinstance(cls, type) and issubclass(cls, WizardModal) and cls is not WizardModal):
            continue
        if cls.__module__ != mod.__name__:
            continue
        found += 1
        for line in hint_lines(object.__new__(cls), cls):
            print(f"{attr}\t{line}")
if found == 0:
    print("NO-WIZARDS-FOUND", file=sys.stderr)
    sys.exit(3)
print(f"WIZARDS\t{found}", file=sys.stderr)
PY
    if ! (cd "$TUI" && "$PY" "$WORK/extract.py" > "$WORK/cmds.txt" 2> "$WORK/extract.err"); then
        bad "the wizard-hint extractor failed: $(head -2 "$WORK/extract.err")"
    else
        nwiz="$(sed -n 's/^WIZARDS\t//p' "$WORK/extract.err")"
        ok "extractor self-control passed; $nwiz wizard(s) discovered from the package"
        while IFS=$'\t' read -r cls line; do
            [[ -n "$line" ]] || continue
            check_command "$cls" "$line"
        done < "$WORK/cmds.txt"
        (( $(wc -l < "$WORK/cmds.txt") > 0 )) \
            || bad "no commands were extracted from any wizard — a hint that names no command is a guided step that teaches nothing"
    fi
fi

# ── §2. learning-paths.toml verify_cmd ──────────────────────────────────────────────────
say
say "§2 learning paths — every verify_cmd that names a repo tool"
LP="$REPO/examples/learning-paths.toml"
if [[ ! -r "$LP" ]]; then
    warn "UNKNOWN: $LP is not readable — the learning-path checkpoints were NOT checked"
else
    n=0
    while IFS= read -r cmd; do
        [[ -n "$cmd" ]] || continue
        n=$((n+1))
        check_command "learning-paths" "$cmd"
    done < <(sed -n 's/^[[:space:]]*verify_cmd[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$LP")
    (( n > 0 )) && ok "$n verify_cmd line(s) examined" \
                || say "  (no verify_cmd lines in $LP)"
fi

# ── §3. micro-cloud.sh's plan ───────────────────────────────────────────────────────────
# Slice 10's `micro-cloud.sh plan` prints the whole lab as commands, and §0.2's invariant is
# the reason that verb exists at all: *delete the guided path and nothing is lost.*  A plan
# naming a verb no driver has would satisfy the letter of that and none of the point — and
# it is the surface MOST likely to acquire one, because the plan is generated from
# `lab_tui/topology.py`'s per-slot verb table rather than typed by hand.  So the generator's
# OUTPUT is checked here, not its source: the table said `lab-chroot.sh up` and `lab-vm.sh
# up` for months, and neither has ever existed at any commit.
#
# The check lives in this file rather than in the lab's own suite because the probe does —
# a second copy of `verb_present`, aimed at the same question, is exactly the duplication
# §4.1 names.  The lab's tests/test-guided-path-is-a-view.sh execs this file, so the rows
# below run inside micro-cloud's run-all.sh too.
say
say "§3 micro-cloud — every command in \`micro-cloud.sh plan\`"
MC="$REPO/examples/micro-cloud/micro-cloud.sh"
if [[ ! -x "$MC" ]]; then
    warn "UNKNOWN: $MC is missing or not executable — the lab plan was NOT checked"
elif (( EUID == 0 )); then
    warn "UNKNOWN: running as root, so the micro-cloud plan was NOT rendered (its steps name the fabric, and this checker will not invoke host networking beside a live cluster)"
else
    n=0
    if ! (cd "$REPO" && timeout 60 "$MC" plan) > "$WORK/mc-plan.txt" 2>"$WORK/mc-plan.err"; then
        bad "micro-cloud: \`micro-cloud.sh plan\` exited non-zero as an unprivileged user — it must run nothing, so it must need nothing: $(head -2 "$WORK/mc-plan.err")"
    else
        # Command lines only: the plan interleaves `#` comments, a `cd`, and `echo` steps
        # the drivers emit as advice. Absolute paths are made repo-relative because that is
        # what check_command matches on, and %q escaping is undone the only safe way — by
        # dropping the backslashes that %q adds before punctuation, never by eval.
        while IFS= read -r line; do
            [[ "$line" == "$REPO/"* ]] || continue
            line="${line#"$REPO"/}"
            line="${line//\\/}"
            n=$((n+1))
            check_command "micro-cloud plan" "$line"
        done < "$WORK/mc-plan.txt"
        (( n > 0 )) \
            && ok "$n command(s) in the lab plan examined" \
            || bad "micro-cloud: the plan named no repo tool at all — a plan that orders nothing is not a view of anything"
    fi
fi

# ── §4. micro-cloud's install catalogue ─────────────────────────────────────────────────
# §11.1 decision 13: micro-cloud CATALOGUES install methods and builds none, naming the lab
# that owns each and the exact command. That makes the catalogue a set of guided steps in
# every sense §0.2 means, and a survey of what this repo can do is the worst possible place
# for a command that cannot be typed — a reader takes an unrunnable row as evidence the
# capability exists.
#
# Two things are checked per row: the command (same probe as everything else here) and the
# `owners`, which are directory paths under examples/. A row pointing at a renamed lab is
# this repo's signature stale record, and unlike a broken link it trips no other checker:
# link_check.py reads Markdown, and this is TOML.
say
say "§4 micro-cloud install catalogue — every command, and every owner directory"
IC="$REPO/examples/micro-cloud/install-catalog.toml"
if [[ ! -r "$IC" ]]; then
    warn "UNKNOWN: $IC is not readable — the install catalogue was NOT checked"
elif ! command -v python3 >/dev/null 2>&1; then
    warn "UNKNOWN: python3 is absent, so the install catalogue (TOML) was NOT parsed"
else
    if ! python3 - "$IC" > "$WORK/catalog.tsv" 2>"$WORK/catalog.err" <<'CATPY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
rows = doc.get("method") or []
if not rows:
    raise SystemExit("no [[method]] rows")
for m in rows:
    for owner in m.get("owners") or []:
        print(f"owner\t{m['id']}\t{owner}")
    cmd = m.get("command")
    if cmd:
        print(f"cmd\t{m['id']}\t{cmd}")
    elif m.get("status") != "gap":
        print(f"nocmd\t{m['id']}\t")
CATPY
    then
        bad "micro-cloud catalogue: could not be parsed: $(head -2 "$WORK/catalog.err")"
    else
        n=0
        while IFS=$'\t' read -r kind id val; do
            case "$kind" in
                cmd)   n=$((n+1)); check_command "install-catalog:$id" "$val" ;;
                owner) [[ -d "$REPO/examples/$val" ]] \
                           || bad "install-catalog:$id names owner '$val', which is not a directory under examples/ — the lab was renamed or removed and the catalogue still points at it" ;;
                nocmd) bad "install-catalog:$id claims status other than 'gap' but names no command — a method nobody can invoke is a gap wearing an owner's clothes" ;;
            esac
        done < "$WORK/catalog.tsv"
        (( n > 0 )) \
            && ok "$n catalogue command(s) examined, and every owner directory exists" \
            || bad "micro-cloud catalogue: no row named a command at all"
    fi
fi

# ── verdict ─────────────────────────────────────────────────────────────────────────────
say
if (( ${#WARNINGS[@]} )); then
    printf 'UNKNOWN: %d thing(s) could not be checked or need a look:\n' "${#WARNINGS[@]}" >&2
    printf '  - %s\n' "${WARNINGS[@]}" >&2
fi
if (( ${#PROBLEMS[@]} )); then
    printf 'FAIL: %d guided step(s) name something the CLI cannot do:\n' "${#PROBLEMS[@]}" >&2
    printf '  - %s\n' "${PROBLEMS[@]}" >&2
    exit 1
fi
printf 'PASS: every guided step names a command you could type — each tool exists, is executable, and its dispatch accepts the verb (asked, not grepped), after 8 self-controls behaved: 3 shapes it must catch, 4 it must not, and a verb that ACTS rather than refusing still trips the safety warning\n'

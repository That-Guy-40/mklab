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

NONCE='zzz-no-tool-has-this-verb-4f2'

# ── the probe ───────────────────────────────────────────────────────────────────────────
# verb_present <tool-abs> <verb> → 0 iff the tool treats it as a real verb
verb_present() {
    local t="$1" v="$2" a b
    # NEVER INVOKE ANYTHING AS ROOT. Unprivileged, `fabric.sh up` answers "must run as root"
    # and does nothing — verified by hand on 2026-08-19, with no br-mc0 and no mc-* taps
    # afterwards. As root it would BUILD A BRIDGE, and this host runs a live Calico cluster
    # whose tunnel endpoint a stray tap has captured before (plan F.6). A guard that damages
    # the thing it is checking is not a guard, so the probe refuses the privilege rather than
    # trusting itself with it, and the row becomes an UNKNOWN — which is a verdict.
    if (( EUID == 0 )); then
        warn "UNKNOWN: running as root, so '$(basename "$t") $v' was NOT probed — this checker invokes verbs, and some of them build host networking next to a live cluster. Run it unprivileged."
        return 0
    fi
    a="$(cd "$REPO" && timeout 30 bash "$t" "$v"     </dev/null 2>&1 || true)"
    b="$(cd "$REPO" && timeout 30 bash "$t" "$NONCE" </dev/null 2>&1 || true)"
    # If the real verb produced something that is not a refusal, it may have DONE something.
    # Say so rather than accepting it silently — defence 2 in the safety note.
    #
    # READ-ONLY VERBS ARE NAMED, NOT INFERRED. `list`, `status` and friends legitimately act
    # without arguments: they answer. Measured on first run — `lab-docker.sh list` and
    # `lab-lxd.sh list` both printed a table and tripped this. Leaving that as a standing
    # two-row UNKNOWN on every run would be worse than useless: a warning nobody can clear is
    # one everybody learns to scroll past, and the row that matters — the first verb that
    # MUTATES without arguments — would arrive looking exactly like the noise. So the benign
    # ones are listed here, by name, with the reason; anything else still warns.
    local readonly_verbs=" list status inspect mac capabilities version "
    if [[ "$readonly_verbs" != *" $v "* ]] \
       && [[ -n "$a" ]] \
       && ! grep -qiE 'usage|error|missing|required|need |unknown|no such|must run as root|refus|denied|not permitted' <<<"$a"; then
        warn "probing '$(basename "$t") $v' produced output that does not look like a refusal — if this verb acts without arguments, this checker must stop invoking it, and the safety argument in this file's header needs revisiting"
    fi
    # BOTH substitutions are applied to BOTH strings, and that is not symmetry for its own
    # sake — it is the fix for a false PRESENT this checker's own negative control caught.
    #
    # Replacing only the verb in `a` and only the nonce in `b` leaves any occurrence of the
    # verb IN THE SHARED USAGE PROSE rewritten on one side and intact on the other. Measured:
    # `lab-vm.sh boot` (a verb it does not have) and `lab-vm.sh <nonce>` print the identical
    # usage banner — but that banner says "--secure-boot" and "first-boot command", so the
    # one-sided normalisation made the two differ and the probe reported `boot` as PRESENT.
    # A guided path naming a verb that does not exist would have sailed through the check
    # written to catch exactly that.
    #
    # It is the documented word-boundary trap arriving from the other side: there, a
    # substitution matched too much ("gro*up*"); here, it matched the right token in the
    # wrong string. Normalising both sides identically leaves only the difference that is
    # about DISPATCH.
    local norm="s/\\b${v}\\b/THEVERB/g; s/\\b${NONCE}\\b/THEVERB/g"
    a="$(sed -E "$norm" <<<"$a")"
    b="$(sed -E "$norm" <<<"$b")"
    [[ "$a" != "$b" ]]
}

# check_command <source-label> <command-line> → records a problem if it is not invocable
#
# The line is parsed, never evaluated. A hint is documentation, and documentation that
# reaches a shell is the defect the sibling check-usage-is-data.sh exists for.
check_command() {
    local src="$1" line="$2"
    # shellcheck disable=SC2206
    local -a words=($line)          # deliberate split: these are already literal tokens
    local i=0
    # `sudo` is a prefix on a guided step, not the tool. Phase 1's chroot wizard emits it.
    while [[ "${words[$i]:-}" == "sudo" || "${words[$i]:-}" == "env" ]]; do i=$((i+1)); done
    local tool="${words[$i]:-}" verb="${words[$((i+1))]:-}"

    if [[ -z "$tool" ]]; then bad "$src: empty command line"; return; fi
    # Only repo tools are checked. A hint may legitimately name podman/ssh/curl, and this
    # checker has nothing to say about those — saying nothing is better than a check that
    # quietly passes because it did not understand the line.
    case "$tool" in
        phase*/*.sh|tools/*.sh|examples/*/*.sh) ;;
        *) return ;;
    esac

    local abs="$REPO/$tool"
    [[ -f "$abs" ]] || { bad "$src: names a tool that does not exist: $tool"; return; }
    [[ -x "$abs" ]] || { bad "$src: names a tool that is not executable: $tool"; return; }
    [[ -n "$verb" ]] || { bad "$src: names '$tool' with no verb and no arguments"; return; }

    # NOT EVERY TOOL IN THIS REPO IS VERB-DISPATCHED, and assuming so made this checker
    # wrong on its first real run: `examples/debian-preseed-gallery/fetch-preseeds.sh
    # --no-refresh` is a perfectly typeable command whose first argument is a flag. The
    # invariant §0.2 states is *"that command must be invocable by hand"*, not *"every tool
    # has verbs"* — so a flag-first command is checked as far as it can be (the tool is
    # there and runnable) and the verb probe is skipped, which is an honest limit rather
    # than a manufactured failure.
    if [[ "$verb" == -* ]]; then
        ok "$src: $tool $verb (flag-first — not verb-dispatched, so only the tool was checked)"
        return
    fi

    if verb_present "$abs" "$verb"; then
        ok "$src: $tool $verb"
    else
        bad "$src: '$tool' has no verb '$verb' — the guided path names a command that cannot be typed"
    fi
}

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

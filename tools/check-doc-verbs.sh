#!/usr/bin/env bash
# check-doc-verbs.sh — every `<tool>.sh <verb>` a DOCUMENT types must be a verb that tool has.
#
# WHY (TODO §11.4). Two of the nine findings in REVIEW-docs-micro-cloud-maas.md were exactly
# this: a document naming a verb the tool refuses. Both were found by hand, by reading. The
# repo has a checker for LINKS (link_check.py) that has no opinion on the sentence around
# them, and a checker for the GENERATED guided path (check-guided-path-is-a-view.sh) that
# looks only at a rendered plan and install-catalog.toml. Prose was gated by nobody.
#
# HOW. It asks the tool, it does not grep the dispatch table — see tools/lib/verb-probe.sh,
# which both checkers share so neither drifts from the other.
#
# THE HARD PART IS THE FALSE POSITIVE, and that is what §0 is for. A document is not a
# script: it contains tree diagrams (`├── preserve.sh`), prose that names a tool without
# calling it ("`preserve.sh` has two tiers"), placeholders (`lab-vm.sh <verb>`), output
# transcripts, and flag-first invocations. Every one of those must be passed over, and the
# only way to know that it is, is to watch it happen on fixtures BEFORE aiming the scan at
# a real file — the lesson of check-usage-is-data.sh §0 and of check-harness-net.sh §1a,
# which was wrong twice for want of exactly this.
#
# WHAT IT READS. Commands inside fenced code blocks, and inline `code spans`, in the docs
# named on argv (default: every tracked *.md). A "command" is a line whose FIRST token --
# after an optional `sudo`/`env`/`bash`/`$`/`#` prompt -- is a repo script path.
#
# Own verdict helpers on purpose: it must not source a suite's lib.sh.
set -uo pipefail

REPO="${REPO:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO" || { echo "FAIL: cannot cd to repo root" >&2; exit 1; }

_V=0
pass() { _V=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
fail() { _V=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
skip() { _V=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
say()  { printf '%s\n' "$*"; }
ok()   { (( ${QUIET:-0} )) || printf '  ✓ %s\n' "$*"; }
bad()  { printf '  ✗ %s\n' "$*" >&2; PROBLEMS+=("$*"); }
warn() { printf '  ! %s\n' "$*" >&2; WARNINGS+=("$*"); }
PROBLEMS=(); WARNINGS=(); UNPROBED=()

WORK=""
_on_exit() {
    local rc=$?
    [[ -n "$WORK" ]] && rm -rf -- "$WORK"
    if (( rc != 0 && rc != 77 )) && (( _V == 0 )); then
        printf 'FAIL: check-doc-verbs.sh exited early (rc=%d) — no verdict printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT
WORK="$(mktemp -d)"
export LAB_STATE_DIR="$WORK/state"

# shellcheck source=tools/lib/verb-probe.sh
. "$REPO/tools/lib/verb-probe.sh"

# ── the extractor ───────────────────────────────────────────────────────────────────────
# extract_commands <file> → one candidate command line per output line.
#
# Deliberately narrow. Every widening below was added because a fixture in §0 demanded it,
# and a widening nobody can point at a fixture for is a guess.
extract_commands() {
    local f="$1"
    # ALL of the filtering happens in awk, and that is not a style preference. The first
    # version post-filtered with `grep -vE '\t[[:space:]]*$'` -- and in an ERE, `\t` is not a
    # tab, it is a literal `t`. That pattern therefore dropped every line ENDING IN THE
    # LETTER T, which silently swallowed `… lab-lxd.sh list` and `… lab-docker.sh list` and
    # left the extractor reporting two of its own fixtures as missing. A tab is a tab in awk.
    awk '
        # A `$ ` PROMPT MARKS A TRANSCRIPT, and that is measured, not assumed. Counted across
        # every tracked document on 2026-08-23: 1234 command lines sit in ```bash fences with
        # NO prompt (an instruction to type), while ALL 74 in untagged fences carry `$ `, as
        # do the 26 in ```console fences (a recording of what happened). The convention is
        # unambiguous, so the prompt decides -- a prompted line is a quotation and can never
        # be a hard failure. phase6-tui/SHOWCASE.md is why: it quotes `$ lab-chroot.sh up
        # --config mc.toml` as the broken output a planner ONCE produced, while explaining
        # that the verb has never existed. An earlier draft stripped the prompt before
        # classifying and so reported that correct document as a defect -- erasing the one
        # signal that answers the question.
        function emit(ctx, text,   prompted) {
            sub(/^[[:space:]]+/, "", text)
            sub(/[[:space:]]+$/, "", text)
            prompted = (text ~ /^[$#][[:space:]]+/)
            sub(/^[$#][[:space:]]+/, "", text)
            if (text == "") return
            if (text ~ /^(#|\||└|├|─|│)/) return        # comments and tree-diagram glyphs
            if (prompted) ctx = "PROMPT"
            print ctx "\t" text
        }
        # Fenced blocks: track the fence and its info string. A block tagged as data is not
        # commands, and reading it as commands turns a tree diagram into a "missing verb".
        /^[[:space:]]*```/ {
            if (infence) { infence = 0; lang = "" }
            else {
                infence = 1
                lang = $0
                sub(/^[[:space:]]*```[[:space:]]*/, "", lang)
                sub(/[[:space:]].*$/, "", lang)
            }
            next
        }
        infence {
            if (lang ~ /^(toml|json|yaml|yml|text|txt|tree|output|ini|conf|cfg|diff|c|python|py|make|dockerfile|containerfile)$/) next
            emit("BLOCK", $0)
            next
        }
        # An INDENTED code block (four spaces) is code in Markdown too. Section 0 caught this
        # on the very first run. Prose indented under a list item passes through harmlessly,
        # because candidate() requires the first token to be a repo script PATH.
        /^    [^ \t]/ { emit("BLOCK", $0); next }
        # Outside a block: inline code spans only, and only ones containing a space (a bare
        # `preserve.sh` names a file, it does not call it).
        {
            line = $0
            while (match(line, /`[^`]+`/)) {
                span = substr(line, RSTART+1, RLENGTH-2)
                if (span ~ /[[:space:]]/) emit("INLINE", span)
                line = substr(line, RSTART+RLENGTH)
            }
        }
    ' "$f"
}

# candidate <line> <doc> → prints "<class> <tool> <verb>" or nothing.
#
# TWO CLASSES, AND THE SPLIT IS THE WHOLE DESIGN:
#
#   hard  a PATH-QUALIFIED invocation (`examples/micro-cloud/micro-cloud.sh up`). Nothing
#         else in English looks like that, so a missing verb here is a defect and fails.
#   soft  a BARE name (`lab-fc.sh clone`), resolved against the document\'s own directory or
#         a unique basename. This is where the audit\'s D5 and D7 actually lived -- and it is
#         also where prose is STRUCTURALLY IDENTICAL to a command: "`preserve.sh` two tiers"
#         parses as tool=preserve.sh verb=two exactly as "`lab-fc.sh clone`" parses as
#         tool=lab-fc.sh verb=clone. No amount of pattern-tightening separates those, so a
#         bare mismatch is reported as a WARNING for a human to read, never as a failure.
#         A checker that cannot tell prose from a command must not fail a build on the
#         difference; saying "I could not decide" is a verdict, and pretending otherwise
#         would make this gate the liar it exists to catch.
candidate() {
    local ctx="${1%%$'\t'*}" line="${1#*$'\t'}" doc="${2:-}"
    # shellcheck disable=SC2206
    local -a w=($line)
    local i=0
    while [[ "${w[$i]:-}" =~ ^(sudo|env|bash|sh|time)$ ]]; do i=$((i+1)); done
    local tool="${w[$i]:-}" verb="${w[$((i+1))]:-}"
    [[ -n "$tool" && -n "$verb" ]] || return 0
    # Metasyntax is not a path: `phase{N}-*/lab-*.sh` is a SHAPE a document is describing,
    # and reading it as a command manufactures a missing tool. Caught by the first bounded
    # repo-wide run, which reported it as a hard failure in a document that is correct.
    case "$tool" in *[\{\}\*\<\>\$]*) return 0 ;; esac
    # CONTEXT decides "command" vs "mention", not path-qualification. phase6-tui/SHOWCASE.md
    # types `lab-chroot.sh up --config …` INSIDE A SENTENCE, in the course of explaining that
    # the planner once emitted exactly that and that neither driver has ever had the verb.
    # The document is CORRECT and is quoting the defect as data; the first version of this
    # checker called it a hard failure. A fenced or indented block says "type this"; an
    # inline span says "I am talking about this". Only the first can be a broken instruction.
    local class=hard
    # INLINE = a mention inside a sentence. PROMPT = a line quoted from a transcript.
    # Neither is an instruction, so neither can fail the build; both are reported.
    [[ "$ctx" == INLINE || "$ctx" == PROMPT ]] && class=soft
    case "$tool" in
        phase*/*.sh|tools/*.sh|examples/*/*.sh|netboot/*.sh|micro-linux/*.sh) ;;
        */*) return 0 ;;                      # some other path: not ours to judge
        *.sh)
            # Bare name. Resolve against the document\'s directory first, then a unique
            # basename across tracked scripts. Ambiguous or unknown -> say nothing at all.
            local cand="" base="${tool#./}"
            if [[ -n "$doc" && -f "$(dirname "$doc")/$base" ]]; then
                cand="$(dirname "$doc")/$base"
            else
                local -a hits
                mapfile -t hits < <(git ls-files "*/$base" "$base" 2>/dev/null)
                (( ${#hits[@]} == 1 )) && cand="${hits[0]}"
            fi
            [[ -n "$cand" ]] || return 0
            tool="$cand"; class=soft ;;
        *) return 0 ;;
    esac
    # A verb is a bare lowercase word. Flags, paths, <placeholders>, $VARS, {braces} and
    # ALL-CAPS metasyntax are not verbs, and treating them as such manufactures failures.
    [[ "$verb" =~ ^[a-z][a-z0-9-]*$ ]] || return 0
    printf '%s %s %s\n' "$class" "$tool" "$verb"
}

# ── THE PROBE-SAFETY BOUNDARY ───────────────────────────────────────────────────────────
# This checker INVOKES verbs. tools/check-guided-path-is-a-view.sh does too, and carries a
# careful safety argument for doing so — but that argument covers SIX catalogue commands it
# can enumerate and reason about. It does not extend to sweeping every script in the repo.
#
# Measured on the first repo-wide run (2026-08-23): the sweep reached `smoke-nvram.sh all`,
# `mlbuild.sh`, and `build-verifying-rom.sh`. Nothing was harmed — no taps, no VMs, no stray
# files afterwards, and the 30s timeout bounds each call — but "it happened not to break
# anything" is not a safety argument, and a smoke script whose `all` verb boots a VM is one
# edit away from being one that boots a slow one.
#
# So the probe is bounded to verb-dispatched DRIVERS, and everything else is reported as an
# UNKNOWN row, BY NAME, rather than probed or silently passed.
#
# YES, THIS IS A LIST, one week after §11.3b deleted a list. The difference is the direction
# it fails in. A coverage list silently under-covers: the file it forgot is simply not
# checked, and nothing says so. This one is a SAFETY boundary that names every row it did
# not check, so its omissions arrive as UNKNOWNs in the verdict instead of as silence.
# A DESTRUCTIVE VERB IS NEVER INVOKED, whatever tool it belongs to. This list beats the
# allowlist below and is checked first.
#
# It exists because the allowlist was not enough, and the proof cost something real: on
# 2026-08-23 this checker probed `vbmc-lab.sh destroy` -- an allowlisted tool -- and the verb
# DID ITS JOB. It removed the vbmcd container, undefined the `alpine-node` domain and removed
# the image. (The lab's own design left the disk and the BMC configs, so it was a recoverable
# teardown rather than data loss.) The safety note in tools/lib/verb-probe.sh says a guard
# that damages the thing it is checking is not a guard; that was this checker, doing it.
#
# The allowlist asks "is this tool a driver?", which is the wrong question for `destroy`. A
# driver is exactly the kind of tool whose destructive verbs WORK. So the verb is asked about
# too, and a verb on this list becomes an UNPROBED row -- named in the output, never silently
# passed, and never run.
verb_is_destructive() {
    case "$1" in
        # PREFIXES, not exact names. `sandbox.sh down2` is a real verb whose own usage line
        # reads "destroy the two-node pair", and an exact-match list sailed straight past it
        # -- so the checker went on invoking a destroy verb every run, which is the same
        # defect as the vbmc one wearing a digit.
        down*|destroy*|delete*|remove*|rm|reset*|wipe*|purge*|stop*|kill*|clean*|prune*|\
        teardown*|undefine*|abort*|release*|deprovision*|unmaintenance*|nuke*|reap*)
            return 0 ;;
        *) return 1 ;;
    esac
}

# ── TIER B: ask the tool WITHOUT running any verb it has ────────────────────────────────
# TODO 11.4a. 93 rows were UNPROBED because invoking their verbs could do work. The way out
# is that a NONCE verb is the safest possible call: no tool has it, so a verb-dispatched tool
# can only refuse. What comes back with that refusal is the tool's own usage text, and that
# is a real oracle -- the tool's self-description, not a regex over its source.
#
# It is WEAKER than tier A and is labelled as such wherever it speaks: tier A asks the
# dispatch itself (a verb it lacks is answered exactly like a verb nobody has), while this
# asks what the tool SAYS it accepts. A tool whose usage is out of date will be believed.
# That is worth having anyway, because the alternative for these rows is nothing at all.
#
# LAYERED, because "only the nonce" still invokes something. A script with no argument
# parsing ignores the nonce and just runs, so it is filtered out STATICALLY first and never
# invoked at all. The grep is a PRE-FILTER for safety, not the oracle -- the oracle is still
# the tool's answer.
has_dispatch() {
    local t="$1"
    grep -qE 'case[[:space:]]+"?\$\{?(1|verb|VERB|cmd|CMD|subcmd|action)' "$t" 2>/dev/null && return 0
    grep -qE '^[[:space:]]*(usage|print_usage|show_help)\(\)' "$t" 2>/dev/null && return 0
    return 1
}

# usage_verbs <tool-abs> — invoke ONLY the nonce, bounded, in a scratch cwd, and print the
# verb-looking tokens from whatever it says back. Prints nothing if it did not clearly refuse.
usage_verbs() {
    local t="$1" out rc scratch
    scratch="$(mktemp -d "$WORK/scratch.XXXXXX")"
    out="$( cd "$scratch" && LAB_STATE_DIR="$scratch/state" timeout 10 bash "$t" "$NONCE" </dev/null 2>&1 )"; rc=$?
    rm -rf -- "$scratch"
    # A timeout means it did NOT refuse -- it started doing something. Say nothing, and let
    # the caller record an UNKNOWN rather than guess from a half-finished run.
    (( rc == 124 )) && return 1
    [[ -n "$out" ]] || return 1
    grep -qiE 'usage|unknown|unrecognis|unrecogniz|invalid|no such|not a (known|valid)|expected one of' <<<"$out" || return 1
    # THE REFUSAL OFTEN DOES NOT CONTAIN THE VERB LIST. Measured 2026-08-23: be.sh answers a
    # nonce with `error: unknown command '…' (try --help)` and nothing else, so reading only
    # this output made every documented verb look absent -- 21 false warnings on the first
    # run. The listing is one call further on, and `--help` is no more dangerous than the
    # nonce: neither is a verb the tool has, and has_dispatch() already established there is
    # a dispatch to refuse them. Concatenate both and read the pair.
    local help_out scratch2
    scratch2="$(mktemp -d "$WORK/help.XXXXXX")"
    help_out="$( cd "$scratch2" && LAB_STATE_DIR="$scratch2/state" timeout 10 bash "$t" --help </dev/null 2>&1 )"
    rm -rf -- "$scratch2"
    out="$out
$help_out"
    # Verb-looking tokens: a bare lowercase word at the start of a line or after a pipe,
    # which is how every usage block in this repo lists them.
    printf '%s\n' "$out" \
        | grep -oE '(^|[[:space:]|])[a-z][a-z0-9-]{1,20}([[:space:]|]|$)' \
        | tr -d ' |' | sort -u
}

# subverb_of <tool-abs> <verb> — does the tool spell this verb as "<parent> <verb>"?
# Asked of the tool's own usage output, same as tier B, not of its source.
subverb_of() {
    local t="$1" v="$2" out scratch
    scratch="$(mktemp -d "$WORK/sv.XXXXXX")"
    out="$( cd "$scratch" && LAB_STATE_DIR="$scratch/state" timeout 10 bash "$t" --help </dev/null 2>&1
            cd "$scratch" && LAB_STATE_DIR="$scratch/state" timeout 10 bash "$t" "$NONCE" </dev/null 2>&1 )"
    rm -rf -- "$scratch"
    [[ -n "$out" ]] || return 1
    # `<parent> <verb>` on one line, or `parent create|list|restore` with the verb among the
    # alternatives -- both are how this repo's usage blocks spell a subverb.
    # Braces and commas count: this repo spells a subverb group as
    #     lab-fc.sh snapshot  {create|list|restore|delete} <name>
    # and a pattern without `{` matched none of them -- subverbs read as 0 on the first run
    # while seven of them sat in the warning list.
    # TWO THINGS THIS COST, both invisible from a pattern that reads correctly:
    #
    #  1. `\$` inside a double-quoted string is a LITERAL DOLLAR, so `(…|\$)` did not mean
    #     "or end of line" -- it meant "or a dollar sign", and the anchor became a required
    #     character. A space is appended to every line instead, so the delimiter always exists.
    #  2. A backslash inside a BRACKET EXPRESSION is not an escape in POSIX ERE, so
    #     `[[:space:]|,}\)\]]` closed at the first `]` and left a stray one that had to match
    #     literally. The class below contains no brackets to misparse: "the verb ends here"
    #     is just "the next character is not one a verb is made of".
    #
    # Subverbs read as 0 for four runs while seven of them sat in the warning list, and the
    # pattern matched every time it was tested at a prompt -- because typing it there goes
    # through different quoting than storing it in a file.
    # `[^a-z]*` was WRONG and its wrongness is instructive: it let the verb sit behind any
    # run of non-lowercase text, so the prose line "create needs it RUNNING; restore needs it
    # STOPPED." matched as if `restore` were a subverb of `it`. Three "subverbs" were found
    # that way on the real tool while THIS fixture -- a clean usage block -- failed. The
    # control fixture disagreeing with the live run is what exposed it.
    #
    # Only an ALTERNATION GROUP counts: `<parent> {a|b|verb|c}`, which is how a usage block
    # spells a subverb and how prose never does.
    # THE VERB MUST FOLLOW A SEPARATOR, not merely appear after some letters. Without the
    # `([a-z0-9,-]+[|,])*` group below, `[a-z0-9|,-]*up` matched the "up" inside
    # `--groups   group,group,...` and excused `lab-chroot.sh up` as a subverb -- the very
    # verb two documents quote as never having existed. A rule that excuses a missing verb
    # is worse than no rule, and this one got there by matching a SUFFIX.
    # THE CHARACTER IMMEDIATELY BEFORE THE VERB MUST BE A GROUP SEPARATOR. Four earlier
    # patterns each admitted prose by a different door, and every one of them looked right:
    #   `[^a-z]*verb`        matched "it RUNNING; restore" -- any non-lowercase run
    #   `[a-z0-9|,-]*up`     matched the "up" inside "--groups group,group" -- a SUFFIX
    #   `([a-z0-9,-]+[|,])*` repeated ZERO times, collapsing to "<word> <verb>", which
    #                        matched "install at first boot"
    # A usage block spells a subverb as `<parent> {a|b|verb|c}`; prose never puts `|`, `,`,
    # `{` or `(` immediately before the word. That is the whole distinction, so ask for it
    # directly rather than approximating it with a quantifier.
    grep -qE "[a-z][a-z0-9-]+[[:space:]]+[^[:space:]]*[{(|,]${v}[^a-z0-9-]" \
        <<<"$(sed 's/$/ /' <<<"$out")"
}

probe_is_safe() {
    case "$1" in
        */lab-*.sh) return 0 ;;                       # the phase drivers
        examples/micro-cloud/micro-cloud.sh|examples/micro-cloud/fabric.sh|examples/micro-cloud/preserve.sh) return 0 ;;
        examples/metal-as-a-service/maas-lab.sh) return 0 ;;
        examples/nested-calico-sandbox/sandbox.sh) return 0 ;;
        examples/virtualbmc-ipmi-lab/vbmc-lab.sh) return 0 ;;
        *) return 1 ;;
    esac
}

# check_doc_command <class> <src> <tool> <verb>
check_doc_command() {
    local class="$1" src="$2" tool="$3" verb="$4"
    # RESOLUTION ORDER. A path-qualified token is not always repo-root-relative:
    # examples/pxe-boot-mechanics/tools/README.md types `tools/pxe-fetch.sh probe`, meaning
    # "from the lab root". The first repo-wide run called that a missing tool four times --
    # a real defect report about a document that was right, which is the false-positive half
    # of this checker being wrong in the expensive direction. So try repo root, then the
    # document's own directory, then each ancestor up to the repo root, and only call it
    # missing when NOTHING resolves.
    local abs="" d
    if [[ -f "$REPO/$tool" ]]; then
        abs="$REPO/$tool"
    else
        d="$(dirname "$REPO/$src")"
        while [[ "$d" == "$REPO"* ]]; do
            if [[ -f "$d/$tool" ]]; then abs="$d/$tool"; break; fi
            [[ "$d" == "$REPO" ]] && break
            d="$(dirname "$d")"
        done
    fi
    # A MISSING TOOL IS ALSO ONLY A HARD FAILURE IN A BLOCK. The class has to be consulted
    # here too, not just at the verb check -- a sentence may legitimately quote a path that
    # does not resolve, and this checker proved that on its own first production run: the
    # TODO §11.4 entry written to DOCUMENT these false positives quotes
    # `tools/pxe-fetch.sh probe` inline as an example, and the docs job failed on it. The
    # checker was right that no such path exists from the repo root and wrong that the
    # document was instructing anyone to run it.
    if [[ -z "$abs" ]]; then
        if [[ "$class" == hard ]]; then
            bad "$src: names a tool that does not exist: $tool"
        else
            warn "$src: mentions '$tool', which resolves to no file from the repo root, this document's directory, or any ancestor. In a sentence that may be deliberate (a historical path, an example, a shape); in a command it would be a broken instruction"
        fi
        return
    fi
    tool="${abs#"$REPO"/}"
    if [[ ! -x "$abs" ]]; then
        if [[ "$class" == hard ]]; then
            bad "$src: names a tool that is not executable: $tool"
        else
            warn "$src: mentions '$tool', which exists but is not executable"
        fi
        return
    fi
    if verb_is_destructive "$verb"; then
        UNPROBED+=("$src: $tool $verb  (destructive verb — never invoked)")
        return
    fi
    if ! probe_is_safe "$tool"; then
        # TIER B — never invoke one of ITS verbs; ask the nonce and read what it says back.
        if ! has_dispatch "$abs"; then
            UNPROBED+=("$src: $tool $verb  (no verb dispatch found — not invoked at all)")
            return
        fi
        local -a uverbs
        mapfile -t uverbs < <(usage_verbs "$abs")
        if (( ${#uverbs[@]} == 0 )); then
            UNPROBED+=("$src: $tool $verb  (did not refuse the nonce with usage — left alone)")
            return
        fi
        # A THIN ANSWER IS NOT EVIDENCE OF ABSENCE. Tier B is a weak oracle, and it may only
        # WARN when the tool actually printed something verb-list-shaped. Measured: without
        # this, `drivers/verify-lib.sh` and `drivers/install.sh` -- SOURCED driver libraries,
        # not verb-dispatched CLIs -- produced "does not list" warnings for interface verbs
        # they implement perfectly well, and an English word in prose ("stays") became a
        # finding about a real tool. UNKNOWN is a verdict; a guess dressed as one is not.
        if (( ${#uverbs[@]} < 5 )); then
            UNPROBED+=("$src: $tool $verb  (its answer was too thin to list verbs — not judged)")
            return
        fi
        if printf '%s\n' "${uverbs[@]}" | grep -qxF "$verb"; then
            ok "$src: $tool $verb  [tier B: the tool's own usage lists it]"
        else
            warn "$src: '$tool' does not list '$verb' in the usage it printed for an unknown verb. TIER B is a WEAKER oracle than asking the dispatch — it believes the tool's self-description, so an out-of-date usage reads as a missing verb. Check the sentence before believing this one"
        fi
        return
    fi
    if verb_present "$abs" "$verb"; then
        ok "$src: $tool $verb"
    elif subverb_of "$abs" "$verb"; then
        # THE THIRD CATEGORY, found by triaging 11.4's warnings: `lab-fc.sh restore` is
        # shorthand for `lab-fc.sh snapshot restore`. The dispatch has no top-level `restore`,
        # so asking it says "no" — correctly, and uselessly, because the document is not
        # wrong so much as abbreviated. Reported as a note, not a defect.
        ok "$src: $tool $verb  [a SUBVERB — the tool spells it '<parent> $verb'; the document abbreviates]"
    elif [[ "$class" == hard ]]; then
        bad "$src: '$tool' has no verb '$verb' — the document types a command that cannot be run"
    else
        warn "$src: \`$(basename "$tool") $verb\` — '$tool' has no verb '$verb'. Read the sentence: this is either a doc naming a verb the tool refuses (the D5/D7 defect) or ordinary prose that happens to parse like a command. This checker cannot tell those apart and will not fail on the guess"
    fi
}

# ── §0. THE EXTRACTOR PROVES ITSELF, BEFORE IT READS A REAL DOC ─────────────────────────
say "§0 controls — the extractor is aimed at fixtures first"
FIX="$WORK/fixture.md"
cat > "$FIX" <<'FIXTURE'
# A fixture

Run it:

```bash
phase2-qemu-vm/lab-vm.sh create --name x
sudo phase1-chroot/lab-chroot.sh create demo
```

The layout is:

```text
examples/micro-cloud/
├── preserve.sh
└── micro-cloud.sh plan
```

Prose: `preserve.sh` has two tiers, and `micro-cloud.sh` is the driver.
Inline call: `phase5-lxd/lab-lxd.sh list` shows them.
Placeholder: `phase2-qemu-vm/lab-vm.sh <verb>` is the shape.
Flag-first: `tools/paths.py --check` is not verb-dispatched.

```toml
[lab]
tool = "lab-vm.sh create"
```

    phase3-docker/lab-docker.sh list
FIXTURE
mapfile -t _got < <(extract_commands "$FIX" | while IFS= read -r l; do candidate "$l" "$FIX"; done)
# The class is part of what must be controlled, not an afterthought: a fenced or indented
# block is an instruction to type (hard), an inline span inside a sentence is a mention
# (soft). phase6-tui/SHOWCASE.md is the reason -- it quotes `lab-chroot.sh up` mid-sentence
# while EXPLAINING that no such verb has ever existed, and the first version of this checker
# reported that correct document as a defect.
_expect=(
 "hard phase2-qemu-vm/lab-vm.sh create"
 "hard phase1-chroot/lab-chroot.sh create"
 "hard phase3-docker/lab-docker.sh list"
 "soft phase5-lxd/lab-lxd.sh list"
)
_c0=0
for e in "${_expect[@]}"; do
    printf '%s\n' "${_got[@]}" | grep -qxF "$e" \
        || { printf '  ✗ CONTROL FAILED (must catch, missed): %s\n' "$e" >&2; _c0=1; }
done
# …and the six shapes it must NOT read as commands.
for n in "preserve.sh" "micro-cloud.sh" "lab-vm.sh create" "paths.py --check"; do
    if printf '%s\n' "${_got[@]}" | grep -qF "$n" && [[ "$n" != "lab-vm.sh create" ]]; then
        printf '  ✗ CONTROL FAILED (must NOT catch): %s\n' "$n" >&2; _c0=1
    fi
done
# The tree-diagram line and the toml block both contain `micro-cloud.sh plan` / `lab-vm.sh
# create` with NO directory prefix; if either were read as a command it would arrive as a
# tool that does not exist, which is a manufactured failure in a document that is correct.
if printf '%s\n' "${_got[@]}" | grep -qE '^(preserve|micro-cloud|lab-vm)\.sh'; then
    printf '  ✗ CONTROL FAILED: a bare filename from a tree diagram or a TOML block was read as a command\n' >&2; _c0=1
fi
if printf '%s\n' "${_got[@]}" | grep -q -- '<verb>'; then
    printf '  ✗ CONTROL FAILED: a <placeholder> was read as a verb\n' >&2; _c0=1
fi
(( _c0 == 0 )) || fail "the extractor's own controls did not hold — it is not aimed at anything real until they do, because a scan that matches nothing and a scan that is broken look identical"
ok "extractor: 4 real invocations found; tree diagram, prose mentions, TOML, placeholder and flag-first all passed over"

# §0.2 — END TO END, because §0.1 only proves the EXTRACTOR. The question this tool exists
# to answer is "does a document naming a verb the tool refuses FAIL the run", and an
# extractor control cannot answer it: the classifier, the probe and the reporting all sit
# between the two. D5 and D7 in REVIEW-docs-micro-cloud-maas.md were exactly this defect and
# were both found by hand; if this section does not fire, they would be again.
_e2e="$WORK/e2e.md"
cat > "$_e2e" <<'E2E'
```bash
phase2-qemu-vm/lab-vm.sh zzznotaverb --name x
```
E2E
_before=${#PROBLEMS[@]}
while IFS= read -r _l; do
    _c="$(candidate "$_l" "$_e2e")" || true
    [[ -n "$_c" ]] || continue
    # shellcheck disable=SC2086
    check_doc_command "${_c%% *}" "$_e2e" ${_c#* } >/dev/null 2>&1
done < <(extract_commands "$_e2e")
if (( ${#PROBLEMS[@]} == _before )); then
    fail "CONTROL FAILED: a fenced \`lab-vm.sh zzznotaverb\` did NOT fail the run. This checker would pass a document naming a verb no tool has, which is the entire defect it was written for (D5, D7)"
fi
PROBLEMS=("${PROBLEMS[@]:0:$_before}")   # the planted finding is not a real one
ok "end-to-end: a fenced command naming a verb the tool refuses DOES fail the run"

# …and the same command, quoted as a transcript, must NOT fail it — or the check that just
# fired is firing on the shape rather than on the question.
_e2e2="$WORK/e2e2.md"
printf '```
$ phase2-qemu-vm/lab-vm.sh zzznotaverb --name x
```
' > "$_e2e2"
_before=${#PROBLEMS[@]}
while IFS= read -r _l; do
    _c="$(candidate "$_l" "$_e2e2")" || true
    [[ -n "$_c" ]] || continue
    # shellcheck disable=SC2086
    check_doc_command "${_c%% *}" "$_e2e2" ${_c#* } >/dev/null 2>&1
done < <(extract_commands "$_e2e2")
if (( ${#PROBLEMS[@]} != _before )); then
    fail "CONTROL FAILED: the SAME command quoted behind a \`$ \` prompt was treated as an instruction. A transcript records what happened; it is not a command the document is telling anyone to type"
fi
ok "end-to-end: the same command quoted as a \`$ \` transcript does NOT fail it"

# §0.3 — TIER B AND THE SUBVERB RULE, both of which are new oracles and neither of which may
# ship unwatched. Fixtures, so the controls do not depend on any real tool's usage text.
_tb="$WORK/tierb-tool.sh"
cat > "$_tb" <<'TBTOOL'
#!/usr/bin/env bash
case "${1:-}" in
    --help)
        cat <<USAGE
usage: tierb-tool.sh <verb>
  start    begin
  stop     end
  status   report
  inspect  look
  snapshot {create|list|restore|delete} <name>
  --groups   group,group,...   (the suffix trap: "gro"+"up" is not a subverb "up")
  install at first boot        (prose: "<word> <verb>" is not a subverb either)
USAGE
        exit 0 ;;
    start|stop|status|inspect|snapshot) exit 0 ;;
    *) echo "unknown command '${1:-}' (try --help)" >&2; exit 1 ;;
esac
TBTOOL
chmod +x "$_tb"
has_dispatch "$_tb" || fail 'CONTROL FAILED: the fixture dispatches on $1 with a case statement and has_dispatch() did not see it — tier B would never be reached for a tool that qualifies. (Single-quoted on purpose: an unescaped backtick in a double-quoted string is command substitution.)' 
mapfile -t _uv < <(usage_verbs "$_tb")
printf '%s\n' "${_uv[@]}" | grep -qxF inspect \
    || fail "CONTROL FAILED: tier B did not read 'inspect' out of a usage block the fixture printed for an unknown verb — the nonce-then---help path is not working, and every tier-B row would read as a missing verb"
printf '%s\n' "${_uv[@]}" | grep -qxF zzzz-not-a-verb \
    && fail "CONTROL FAILED: tier B reported a verb the fixture never printed"
ok "tier B: reads a real verb out of the usage a fixture prints for an unknown one, and invents none"

subverb_of "$_tb" restore \
    || fail "CONTROL FAILED: 'restore' is spelled '{create|list|restore|delete}' after 'snapshot' in the fixture, and subverb_of did not see it. That pattern was wrong FOUR times (a \$ that was a literal dollar, a backslash inside a bracket expression) and matched perfectly every time it was tested at a prompt"
subverb_of "$_tb" nosuchthing \
    && fail "CONTROL FAILED: subverb_of matched a word the fixture does not contain, so it would excuse any missing verb as a subverb"
subverb_of "$_tb" boot \
    && fail "CONTROL FAILED: 'boot' appears in the fixture only as the last word of a PROSE line, and subverb_of took it for a subverb. A quantifier that may repeat zero times collapses to \"<word> <verb>\", which is what prose looks like"
subverb_of "$_tb" up \
    && fail "CONTROL FAILED: 'up' appears only INSIDE the word 'group' in the fixture, and subverb_of took it for a subverb. That is how it excused lab-chroot.sh's non-existent 'up' verb on a real run"
ok "subverb: recognises '<parent> {…|verb|…}' and refuses a word that is not there"

# ── §1. the documents ───────────────────────────────────────────────────────────────────
if (( $# )); then DOCS=("$@"); else mapfile -t DOCS < <(git ls-files '*.md'); fi
(( ${#DOCS[@]} > 0 )) || fail "no documents to check — this would pass vacuously"
say "§1 scanning ${#DOCS[@]} document(s)"

seen=""; n_cmds=0
for d in "${DOCS[@]}"; do
    while IFS= read -r line; do
        c="$(candidate "$line" "$d")" || true
        [[ -n "$c" ]] || continue
        # Probe each (tool,verb) ONCE per run: the probe invokes the tool twice, and a repo
        # this size repeats the same command in a dozen documents.
        key="${c#* }"; key="${key// /|}"
        case "$seen" in *"[$key]"*) continue ;; esac
        seen="${seen}[$key]"   # braces: `$seen[` reads as an array expansion otherwise
        n_cmds=$((n_cmds+1))
        # $c is "<class> <tool> <verb>"; the class comes FIRST. Passing "$d" first made
        # class hold the document path, so `[[ "$class" == hard ]]` was never true and every
        # hard mismatch quietly degraded into a warning — a checker grading its own findings
        # down to advisory, which is the failure mode it exists to prevent.
        # shellcheck disable=SC2086
        check_doc_command "${c%% *}" "$d" ${c#* }
    done < <(extract_commands "$d")
done

say ""
if (( ${#UNPROBED[@]} )); then
    say "${#UNPROBED[@]} command(s) NOT PROBED — outside the probe-safety boundary above. These are"
    say "UNKNOWN, not PASS: this checker declines to invoke a tool that may do real work."
    printf '    ? %s\n' "${UNPROBED[@]}"
fi
if (( ${#WARNINGS[@]} )); then
    say "${#WARNINGS[@]} warning(s) — see the ! lines above"
fi
if (( ${#PROBLEMS[@]} )); then
    fail "$(printf '%d document(s) name a command that cannot be run:' "${#PROBLEMS[@]}"; printf '\n  - %s' "${PROBLEMS[@]}")"
fi
pass "of the $n_cmds distinct \`<tool>.sh <verb>\` commands typed across ${#DOCS[@]} documents, every path-qualified one names a tool that exists and a verb its dispatch accepts — asked of the tool, not grepped from it. ${#UNPROBED[@]} were left UNPROBED by the safety boundary and ${#WARNINGS[@]} bare-name mentions are reported for a human, both named above rather than counted as passes. The extractor proved on fixtures first that it passes over tree diagrams, prose mentions, placeholders, data blocks and flag-first invocations"

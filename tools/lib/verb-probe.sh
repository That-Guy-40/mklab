#!/usr/bin/env bash
# tools/lib/verb-probe.sh — "does this tool really have this verb?", asked the only way that
# is not a regex over a physical line: ASK THE TOOL. A driver answers a verb it does not
# have exactly as it answers a verb nobody has, so run both, normalise the verb token out of
# each answer, and compare.
#
# SOURCED, never executed, and it installs NO EXIT trap: `lib.sh`'s rule applies here too --
# bash keeps one EXIT trap per shell, and a lib that sets one silently disarms its caller's.
# The caller owns WORK, its cleanup, and the reporting helpers.
#
# Two checkers use it and MUST use the same one:
#   * tools/check-guided-path-is-a-view.sh — the verbs a generated plan or wizard hands a novice
#   * tools/check-doc-verbs.sh             — the verbs the DOCUMENTATION types (TODO §11.4)
#
# It lived only in the first of those until 2026-08-23. Copying it into the second would be
# the mistake this repo keeps writing down: a copy drifts from its subject and then proves
# something about the copy. The safety argument inside verb_present is load-bearing for BOTH
# callers, and one of those is far easier to keep honest than two.
#
# CONTRACT. The caller must define, before sourcing:
#   REPO      absolute path to the repo root
#   WORK      a scratch directory it created and will remove
#   ok/bad/warn   reporting helpers; `bad` must append to PROBLEMS
#   PROBLEMS  array, so a caller can count new entries to test the checker itself
# shellcheck shell=bash

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
    # The refusal vocabulary is a HEURISTIC, and it is only as good as the phrasings it has
    # actually met. Measured 2026-08-23: `micro-cloud.sh up` refuses with "'up' needs root:
    # the fabric creates a bridge, taps and nft rules" -- a textbook refusal that matched
    # none of `must run as root`, so the probe warned that a verb might have ACTED. It had
    # not: the scratch state dir was empty and the host had zero mc-* taps afterwards. A
    # false alarm here is not harmless, because a warning nobody can clear is one everybody
    # learns to scroll past -- which is how the real one would arrive unnoticed.
    if [[ "$readonly_verbs" != *" $v "* ]] \
       && [[ -n "$a" ]] \
       && ! grep -qiE 'usage|error|missing|required|need |needs |requires |unknown|no such|(must|has to) run as root|as root|refus|denied|not permitted|not root' <<<"$a"; then
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

#!/usr/bin/env bash
# openbios-tier-b-relevant.sh — does a set of changed files warrant running Tier B?
#
# Reads changed paths on stdin (one per line), prints `true` or `false`, exits 0
# either way. .github/workflows/openbios-tier-b.yml calls this to decide whether
# to spend three minutes building and booting firmware on a pull request.
#
# WHY A SCRIPT AND NOT `on.pull_request.paths`. A workflow-level `paths:` filter
# stops the workflow from running AT ALL on a non-matching PR, so a required
# status check never reports and the PR waits forever on something that will
# never arrive. Deciding here instead means the gate job always reports, and the
# expensive job is the only thing that is skipped.
#
# THIS LIST IS A CACHED FACT about what Tier B depends on, which is bug class #1.
# Two things keep it honest rather than trusting it: tools/tests/
# test-openbios-tier-b-relevance.sh re-derives the `tools/` half from the lab's
# own scripts and fails when this list stops covering them, and the workflow
# keeps a WEEKLY run so a miss costs a week's delay rather than silence.
set -euo pipefail

case "${1:-}" in
    -h|--help)
        cat <<'USAGE'
openbios-tier-b-relevant.sh < changed-paths

Reads changed file paths on stdin, one per line. Prints `true` when any of them
could change what Tier B builds or boots, `false` otherwise. Exit 0 either way;
exit 2 on a usage error.

  git diff --name-only BASE..HEAD | tools/openbios-tier-b-relevant.sh
USAGE
        exit 0 ;;
    "") ;;
    *) echo "unexpected argument: $1" >&2; exit 2 ;;
esac

# Each entry is a bash glob matched against the whole path. Keep the reason with
# the pattern: an entry nobody can justify is an entry nobody can safely delete.
PATTERNS=(
    'examples/openbios-the-rival-that-shipped/*'  # the lab: driver, patches, smoke
    'tools/openbios-*'                            # pin-check, the TESTED-TREE regenerator
    'tools/drive-pty-repl.py'                     # smoke-openbios.sh drives ppc through it
    'tools/drive-serial-repl.py'                  # ...and x86/amd64 through this one
    '.github/workflows/openbios-tier-b.yml'       # the job itself
)

relevant=false
while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    for p in "${PATTERNS[@]}"; do
        # shellcheck disable=SC2053  # the RHS is a glob on purpose; that is the match.
        if [[ "$f" == $p ]]; then relevant=true; break; fi
    done
    [[ "$relevant" == true ]] && break
done
printf '%s\n' "$relevant"

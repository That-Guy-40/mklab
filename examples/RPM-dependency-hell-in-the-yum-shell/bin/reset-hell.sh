#!/usr/bin/env bash
# reset-hell.sh — put the box back into the article's opening state, so the
# hell can be walked again (or walked down a different road):
#
#   installed:      bat-shared-56  + the six innocent bystanders
#   not installed:  the whole bat 5.7 stack
#
# Idempotent; safe to run from any state. Everything comes from the local
# bat-hell repo, so this is offline and takes about a second. Run as root, or
# as the learner (it sudoes its own dnf calls).
set -euo pipefail

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

ALL=(bat-client-57 bat-shared-57 bat-shared-compat-57 bat-shared-56
     meatloaf-mta python-bat perl-DBD-bat hellban hellban-sendmail hell-lsb-core)
BASE=(bat-shared-56 meatloaf-mta python-bat perl-DBD-bat
      hellban hellban-sendmail hell-lsb-core)

inst=()
for p in "${ALL[@]}"; do rpm -q "$p" >/dev/null 2>&1 && inst+=("$p"); done
[ "${#inst[@]}" -gt 0 ] && $SUDO dnf -y -q remove "${inst[@]}" >/dev/null

$SUDO dnf -y -q install "${BASE[@]}" >/dev/null

# Trust nothing: assert the state we claim to have produced.
rpm -q "${BASE[@]}" >/dev/null \
    || { echo "reset-hell: FAILED to restore the baseline (rpm -q disagrees)" >&2; exit 1; }
for p in bat-client-57 bat-shared-57 bat-shared-compat-57; do
    ! rpm -q "$p" >/dev/null 2>&1 \
        || { echo "reset-hell: FAILED — $p is still installed" >&2; exit 1; }
done

echo "hell restored: bat-shared-56 + 6 bystanders installed; the 5.7 stack is not"

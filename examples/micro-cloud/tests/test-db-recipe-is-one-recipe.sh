#!/usr/bin/env bash
# Verdict: db's chroot recipe is described ONCE — the --post-command set the runner executes
# and the one RUNBOOK-micro-cloud.md hands the reader are the same set, character for
# character.
#
# The recipe now has four moving parts (interfaces, dhclient hostname, the enable symlink, the
# wait-for-eth0 drop-in), each added because the lab failed without it, and it lives in TWO
# files: run-privileged-demo.sh RUNS it, the RUNBOOK TEACHES it.  A reader following the
# RUNBOOK builds a real tree from those lines, so a line that gets added to the script and not
# to the doc does not produce a doc that is merely out of date -- it produces a tree that
# starts, gets its veth, and silently never asks for an address.  That is this repo's
# "docs drift from sibling docs" gotcha with a working failure attached.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$LAB_DIR/run-privileged-demo.sh"
DOC="$LAB_DIR/RUNBOOK-micro-cloud.md"
[[ -r "$SCRIPT" ]] || fail "the runner is missing: $SCRIPT"
[[ -r "$DOC" ]]    || fail "the RUNBOOK is missing: $DOC (it carries the second copy of db's recipe, so there is nothing to compare against)"

# strip the indent and the line-continuation backslash; the two files indent differently and
# that is not a difference in the recipe.
extract() { sed -n "s/^[[:space:]]*\(--post-command '.*'\)[[:space:]]*\\\\\?[[:space:]]*$/\1/p" "$1"; }

a="$(extract "$SCRIPT")"; b="$(extract "$DOC")"

# THE EMPTY-MATCH TRAP FIRST: two extractions that both found nothing compare equal, and a
# scan that matches nothing prints the same green as one that matched everything.
n_a=$(printf '%s\n' "$a" | grep -c "post-command" || true)
note "extracted $n_a --post-command lines from the runner"

# Each element of the recipe is named SEPARATELY, by the artifact it writes.  The first draft
# of this asserted `grep -q wait-for-eth0`, and its own control caught it: that string occurs
# on THREE lines (the mkdir, the helper, the drop-in), so deleting the drop-in left the helper
# line matching and the test passed — while printing "including the wait-for-eth0 drop-in".
# A substring shared by several lines cannot guard any one of them.
require() {  # require <pattern> <what-breaks-without-it>
    grep -qF -- "$1" <<<"$a" \
        || fail "REGRESSION: the runner's recipe no longer writes $1 — $2"
}
require '/etc/network/interfaces' \
        "db has no interface config at all, so nothing ever asks for an address"
require 'send host-name' \
        "db registers its DHCP lease under LXD's instance name (lab-micro-cloud-db) and 'getent db' fails from edge (LEDGER L10-13)"
require 'multi-user.target.wants/networking.service' \
        "networking.service is installed but not enabled, so it never runs (LEDGER L10-16)"
require 'until ip link show eth0' \
        "the helper no longer waits on NETLINK. A /sys/class/net test answers for the netns of the sysfs MOUNT, not the caller's, so it can be satisfied while ifup's own lookup still fails -- which is exactly what happened (LEDGER L10-19)"
require '> /usr/local/sbin/wait-for-eth0' \
        "the drop-in's ExecStartPre points at a helper that is never written, and the unit fails before ifup (LEDGER L10-18)"
require 'networking.service.d/wait-for-eth0.conf' \
        "networking.service races the veth's insertion and dies on 'No such device' before eth0 exists (LEDGER L10-18)"

if [[ "$a" != "$b" ]]; then
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -20 >&2
    fail "db's chroot recipe differs between $(basename "$SCRIPT") and $(basename "$DOC") — a reader following the RUNBOOK would build a different tree than the one the lab is verified against (diff above: < runner, > doc)"
fi
note "the runner's recipe and the RUNBOOK's are identical ($n_a lines)"

# ── control: break one copy and watch the comparison bite ────────────────────
tmp="$(mktemp)"; on_exit "rm -f '$tmp'"
sed "s/until ip link show eth0/until ip link show DANGER-PLACEHOLDER/" "$DOC" > "$tmp"
c="$(extract "$tmp")"
[[ "$c" != "$a" ]] || fail "control failed: a doc whose wait-for-eth0 helper watches a different device still compared equal, so the comparison above proves nothing"
note "control: altering the helper's device name in a copy of the doc does make the comparison fail"

pass "db's chroot recipe is one recipe: $n_a --post-command lines, identical in the runner and the RUNBOOK, including the wait-for-eth0 drop-in"

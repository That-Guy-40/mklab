#!/usr/bin/env bash
# rebuild-vbmc-lab.sh — put back what tools/check-doc-verbs.sh tore down on 2026-08-23.
#
# WHAT WAS LOST: the vbmcd-lab container, the alpine-node domain definition, and the
# vbmcd:lab image. NOT lost: the domain's disk under /var/lib/libvirt/images and the BMC
# configs in examples/virtualbmc-ipmi-lab/state/vbmc/ — vbmc-lab.sh's own `destroy` leaves
# both, which is why this is a rebuild and not a recovery.
#
# Needs sudo: the vbmcd container is ROOTFUL on purpose (qemu:///system's socket is
# root:libvirt 0660, and a rootless userns cannot open it).
#
# Report goes to a file rather than only the terminal, so the agent can read the result.
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run me with sudo: sudo bash $0"; exit 2; }
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB="$REPO/examples/virtualbmc-ipmi-lab"
REPORT="${TMPDIR:-/tmp}/rebuild-vbmc-lab.$$.out"
: > "$REPORT"

run() {                        # run <verb> [args…]
    echo "=================== vbmc-lab.sh $* ===================" >> "$REPORT"
    ( cd "$LAB" && timeout 900 bash ./vbmc-lab.sh "$@" ) >> "$REPORT" 2>&1
    local rc=$?
    echo "--- rc=$rc" >> "$REPORT"
    printf '%-14s rc=%s\n' "$*" "$rc"
    return $rc
}

# build -> node -> up -> add, the order its own usage documents.
run build || echo "  (build failed — see $REPORT)"
run node  || echo "  (node failed — the domain may already be defined, which is fine)"
run up    || echo "  (up failed — see $REPORT)"
run add   || echo "  (add failed — see $REPORT)"

echo
echo "=== status (the check that matters) ==="
run status
echo
echo "full output: $REPORT"

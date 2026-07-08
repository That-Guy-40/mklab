#!/usr/bin/env bash
# Regression (Review M2): `destroy` must only remove containers THIS tool
# manages (carry the lab-create.tool label) — like `down` does — so a student
# can't reap another student's like-named container on a shared daemon.
#
# Drives the REAL cmd_destroy with a file-backed `docker` stub. A file in the
# registry whose content is "labeled" is a lab-docker container; "unlabeled" is
# a decoy someone else happens to have named `lab-…`.
#
# shellcheck disable=SC1090,SC2317
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
reg="$work/reg"; mkdir -p "$reg"

docker() {
    local sub="$1"; shift
    case "$sub" in
        ps)   # ps -a --filter label=<tool> --format {{.Names}}
            local labeled_only=0 a
            for a in "$@"; do [[ "$a" == "label=${LAB_LABEL_TOOL}" ]] && labeled_only=1; done
            local f n
            for f in "$reg"/*; do
                [[ -e "$f" ]] || continue; n="$(basename "$f")"
                if (( labeled_only )); then grep -qx labeled "$f" && printf '%s\n' "$n"
                else printf '%s\n' "$n"; fi
            done ;;
        inspect) [[ -e "$reg/${*: -1}" ]] ;;     # exists? 0/1
        rm)      rm -f "$reg/${*: -1}"; return 0 ;;
        stop)    return 0 ;;
        *)       return 0 ;;
    esac
}
export -f docker 2>/dev/null || true

source "$LAB_DOCKER"
require_docker() { :; }

# Two containers named lab-…: one ours (labeled), one a decoy (someone else's).
printf 'labeled\n'   > "$reg/lab-mine"
printf 'unlabeled\n' > "$reg/lab-decoy"

OPT_FORCE=1 EXTRA_ARGS=()

# 1) Destroying the decoy must be REFUSED (no tool label) and leave it intact.
POS_ARGS=(decoy)
if ( cmd_destroy ) >/dev/null 2>&1; then
    fail "REGRESSION: destroy removed a container WITHOUT our tool label (cross-user reap)"
fi
[[ -e "$reg/lab-decoy" ]] || fail "REGRESSION: the decoy container was deleted"
note "decoy (unowned, like-named) refused and left intact"

# 2) Destroying our own labeled container must succeed.
POS_ARGS=(mine)
( cmd_destroy ) >/dev/null 2>&1 || fail "destroy of our OWN labeled container failed"
[[ ! -e "$reg/lab-mine" ]] || fail "our labeled container was not removed"
note "owned container destroyed"

# 3) A name that doesn't exist at all → clean 'no container' failure, no crash.
POS_ARGS=(ghost)
if ( cmd_destroy ) >/dev/null 2>&1; then
    fail "destroy of a nonexistent container unexpectedly succeeded"
fi
note "nonexistent target refused cleanly"

pass "destroy is ownership-scoped: refuses unowned/like-named, removes only ours"

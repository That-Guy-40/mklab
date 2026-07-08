#!/usr/bin/env bash
# Regression (Review H4): a partial 'up' must roll back ONLY the resources THIS
# run created, never the healthy pre-existing ones.
#
# The bug: the partial-'up' EXIT trap ran a full label-scoped `down`, so an
# incremental re-'up' (add one service to a running lab) that failed on the new
# service tore down the whole lab — silent loss of a working lab.
#
# We drive the REAL cmd_up with a file-backed `docker` stub (no daemon).  Scenario:
#   - web1 already exists (pre-existing, "left as-is")
#   - webnew starts fresh (created THIS run)
#   - webfail fails to start  → partial-up rollback fires
# Expect afterwards: web1 KEPT, webnew REMOVED (rolled back), webfail never made.
#
# shellcheck disable=SC1090,SC2317
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq tomlq

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
reg="$work/reg"; mkdir -p "$reg"   # one file per "container", named by id(=name)

# --- docker stub: a tiny name-keyed container registry ---------------------
# id == name for simplicity; only the subcommands cmd_up uses are implemented.
docker() {
    case "$1 $2" in
        "network create"|"network inspect"|"network rm"|"network ls"|"network connect")
            # No networks in this test; `ls -q` prints nothing, others succeed.
            [[ "$2" == ls ]] && return 0
            return 0 ;;
    esac
    case "$1" in
        ps)
            # ps -aq  -> ids (one per registry file); ps -a --format ... -> names
            local f names=()
            for f in "$reg"/*; do [[ -e "$f" ]] && names+=("$(basename "$f")"); done
            printf '%s\n' "${names[@]:-}" | sed '/^$/d'
            return 0 ;;
        run)
            # Parse out --name and the trailing image (first non-flag after flags).
            local name="" image="" prev=""
            for a in "$@"; do
                [[ "$prev" == "--name" ]] && name="$a"
                prev="$a"
            done
            # image = last arg that isn't a flag value we care about; our configs
            # put the image as the token right before any command — grab the arg
            # after the final "--name NAME ... IMAGE".  Simplest: the caller sets
            # image via the registry marker file we check below by name.
            if [[ -e "$reg/$name" ]]; then
                echo "Error: name \"$name\" already in use by container abc" >&2
                return 1
            fi
            # Fail images literally named FAILIMG (webfail); else "create".
            for a in "$@"; do [[ "$a" == "FAILIMG" ]] && image="FAILIMG"; done
            if [[ "$image" == "FAILIMG" ]]; then
                echo "Error: unable to pull FAILIMG: not found" >&2
                return 1
            fi
            : > "$reg/$name"     # register the new container
            echo "$name"
            return 0 ;;
        rm)
            # rm -f ID
            local id="${*: -1}"; rm -f "$reg/$id"; return 0 ;;
        inspect) return 0 ;;
        *) return 0 ;;
    esac
}
export -f docker 2>/dev/null || true

cfg="$work/topo.toml"
cat > "$cfg" <<'EOF'
[lab]
name = "h4demo"

[[service]]
name = "web1"
image = "alpine:3.20"

[[service]]
name = "webnew"
image = "alpine:3.20"

[[service]]
name = "webfail"
image = "FAILIMG"
EOF

source "$LAB_DOCKER"
require_docker() { :; }            # no daemon
_wait_healthy() { :; }

# Pre-existing: web1 is already up for this lab (as if from an earlier `up`).
: > "$reg/lab-h4demo-web1"

# Drive the REAL cmd_up in a subshell so the `die` on webfail (which is `exit`)
# is caught here rather than killing the test.
OPT_CONFIG="$cfg" OPT_LAB="" POS_ARGS=() EXTRA_ARGS=()
( cmd_up ) >/dev/null 2>&1 && fail "cmd_up should have failed on webfail" || true

# Assertions.
[[ -e "$reg/lab-h4demo-web1" ]] \
    || fail "REGRESSION: pre-existing container web1 was torn down by the rollback"
note "pre-existing web1 survived the partial-up"
[[ ! -e "$reg/lab-h4demo-webnew" ]] \
    || fail "REGRESSION: newly-created webnew was NOT rolled back after the failure"
note "newly-created webnew was rolled back"
[[ ! -e "$reg/lab-h4demo-webfail" ]] || fail "webfail should never have been created"

pass "partial-up rolls back only THIS run's containers; pre-existing lab intact"

#!/usr/bin/env bash
# Regression (Review M1): a TOML `image` value beginning with `-` must be
# rejected — otherwise it lands as the first POSITIONAL to `docker run` and
# injects flags (e.g. `image = "--privileged"` / `"-v"`), defeating the "no
# privileged, no host mounts from config" posture.
#
# Drives the REAL cmd_up with a `docker` stub that RECORDS every `run` — the
# test fails if any docker run happens (the guard must fire first).
#
# shellcheck disable=SC1090,SC2317
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq
command -v tomlq >/dev/null 2>&1 || skip "no tomlq (TOML parser) for load_config"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
ran="$work/ran"; : > "$ran"

docker() {
    case "$1" in
        run)     echo "RUN $*" >> "$ran"; echo fakeid; return 0 ;;
        ps)      return 0 ;;   # ps -aq / snapshots → empty
        network) return 0 ;;
        *)       return 0 ;;
    esac
}
export -f docker 2>/dev/null || true

source "$LAB_DOCKER"
require_docker() { :; }
_wait_healthy() { :; }

cfg="$work/inject.toml"
cat > "$cfg" <<'EOF'
[lab]
name = "inj"

[[service]]
name = "evil"
image = "--privileged"
EOF

OPT_CONFIG="$cfg" OPT_LAB="" POS_ARGS=() EXTRA_ARGS=()
out="$( ( cmd_up ) 2>&1 || true )"

# The guard must fire, and NO docker run may have happened.
grep -qi "must not start with '-'" <<<"$out" \
    || fail "REGRESSION: '-'-leading image not rejected (out: $out)"
[[ ! -s "$ran" ]] \
    || fail "REGRESSION: docker run executed despite injected flag image: $(cat "$ran")"
note "image '--privileged' rejected before any docker run"

pass "a '-'-leading image is refused (no flag injection into docker run)"

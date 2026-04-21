#!/usr/bin/env bash
# The container/network naming rules are part of Phase 3's contract — verify
# them by extracting and exercising the resolver.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# Source just the resolver function from the script.
# shellcheck disable=SC1090
source <(awk '/^_resolve_container_name\(\)/,/^}/' "$LAB_DOCKER")
# shellcheck disable=SC1090
source <(awk '/^container_name_for\(\)/,/^}/' "$LAB_DOCKER")

[[ "$(_resolve_container_name foo)"        == "lab-foo"      ]] || fail "ad-hoc resolver wrong"
[[ "$(_resolve_container_name demo/web)"   == "lab-demo-web" ]] || fail "lab/svc resolver wrong"
[[ "$(container_name_for demo web)"        == "lab-demo-web" ]] || fail "container_name_for wrong"

pass "container naming rules OK"

#!/usr/bin/env bash
# Build the same host-copy chroot two ways (CLI flags vs TOML config) and
# verify the resulting trees are identical (modulo timestamps/inodes).

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_root
require_cmd jq ldd diff

probe="/bin/busybox"; [[ -x "$probe" ]] || probe="/bin/ls"

t_cli="$(mktest_target parity-cli)"
t_cfg="$(mktest_target parity-cfg)"
n_cli="parity-cli-$$"
n_cfg="parity-cfg-$$"
cfg="$(mktemp --suffix=.toml)"

# Teardown registers with lib.sh's on_exit rather than installing a second `trap … EXIT`.
# Bash keeps ONE EXIT trap per shell, so a second one silently REPLACES the verdict net and
# lets this test die with a bare rc and no PASS/FAIL line — and this test is `set -e` with
# root-only `create` calls, so dying early is the likely failure, not the exotic one.
# It did exactly that until 2026-08-15 (REVIEW-phase1.md, P1-3), unseen because the checker
# meant to forbid it matched `trap` and `EXIT` on one physical line and this body spans four.
# Single-quoted on purpose: on_exit evaluates the body AT EXIT, so it reads the values then.
on_exit '
    cleanup_target "$t_cli" "$n_cli"
    cleanup_target "$t_cfg" "$n_cfg"
    rm -f "$cfg"
'

cat > "$cfg" <<EOF
[[chroot]]
name     = "${n_cfg}"
backend  = "host-copy"
target   = "${t_cfg}"
binaries = ["${probe}"]
manager  = "none"
EOF

note "build via CLI"
"$LAB_CHROOT" create \
    --backend host-copy --target "$t_cli" --name "$n_cli" \
    --binaries "$probe"

note "build via config"
"$LAB_CHROOT" create --config "$cfg"

# Compare: list of relative file paths under each tree.
list_a="$(mktemp)"; list_b="$(mktemp)"
( cd "$t_cli" && find . -not -name '.lab-chroot-mounts' | sort ) > "$list_a"
( cd "$t_cfg" && find . -not -name '.lab-chroot-mounts' | sort ) > "$list_b"

if ! diff -q "$list_a" "$list_b"; then
    diff -u "$list_a" "$list_b" || true
    rm -f "$list_a" "$list_b"
    fail "CLI and config produced different file sets"
fi
rm -f "$list_a" "$list_b"

pass "CLI and TOML config produced identical chroot trees"

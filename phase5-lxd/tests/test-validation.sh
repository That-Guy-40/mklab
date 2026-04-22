#!/usr/bin/env bash
# Fast guardrail tests — exercise CLI usage errors before any daemon call.
# Does NOT require a reachable LXD/Incus daemon.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# Most of these require_* inside the script would call probe_engine first,
# but that's only fatal if neither binary exists.  On CI images without
# lxc/incus the script dies in probe_engine with an install hint.
# Skip the whole file if that's the case; we can't even hit the usage paths.
command -v incus >/dev/null 2>&1 || command -v lxc >/dev/null 2>&1 \
    || skip "no incus or lxc CLI installed — usage guards can't be exercised"

expect_error "build without --alias"   "usage"               -- build
expect_error "build unknown backend"   "unknown backend"     -- build --alias foo --backend totallyfake
expect_error "build upstream missing SRC" "needs --image SRC" -- build --alias foo --backend upstream
expect_error "build from-chroot missing PATH" "needs --chroot" -- build --alias foo --backend from-chroot
expect_error "build from-tarball missing PATH" "needs --tarball" -- build --alias foo --backend from-tarball
expect_error "build from-qcow2 missing PATH"  "needs --qcow2"   -- build --alias foo --backend from-qcow2

expect_error "run without --name"      "usage"               -- run
expect_error "run without image src"   "specify one of"      -- run --name x

expect_error "up without --config"     "topology.toml"       -- up
expect_error "down without lab or cfg" "usage"               -- down

expect_error "exec no target"          "usage"               -- exec
expect_error "logs no target"          "usage"               -- logs
expect_error "destroy no target"       "usage"               -- destroy

expect_error "export no lab"           "usage"               -- export
expect_error "export bad format"       "unknown export format" -- export somelab --format kube

expect_error "unknown subcommand"      "unknown subcommand"  -- not-a-subcommand

pass "validation guardrails OK"

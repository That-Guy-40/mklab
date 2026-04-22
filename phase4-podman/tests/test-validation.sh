#!/usr/bin/env bash
# Validation guardrails — fast, no podman calls required.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# No podman, no jq needed: all these errors fire before dependency checks.

expect_error "build no tag"                 "tag"                    -- build
expect_error "build bogus backend"          "unknown build backend"  -- build --tag t --backend bogus
expect_error "build from-chroot no path"    "requires --chroot"      -- build --tag t --backend from-chroot
expect_error "run no name"                  "name"                   -- run
expect_error "run no source"                "need one of"            -- run --name foo
expect_error "run manager=quadlet"          "for topology 'up'"      -- run --name foo --image x --manager quadlet
expect_error "run bogus manager"            "unknown --manager"      -- run --name foo --image x --manager bogus
expect_error "up no config"                 "config"                 -- up
expect_error "down no name/cfg"             "lab name"               -- down
expect_error "destroy no target"            "usage"                  -- destroy
expect_error "exec no target"               "usage"                  -- exec
expect_error "logs no target"               "usage"                  -- logs
expect_error "export no lab"                "usage"                  -- export
expect_error "export bogus format"          "unknown export format"  -- export mylab --format bogus
expect_error "generate no config"           "usage"                  -- generate
expect_error "unknown subcommand"           "unknown subcommand"     -- frobnicate

pass "validation guardrails OK"

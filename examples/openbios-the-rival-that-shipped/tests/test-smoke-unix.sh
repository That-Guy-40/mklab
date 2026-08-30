#!/usr/bin/env bash
# Wrapper: ../smoke-openbios.sh stays the single implementation (TODO §14 item 3).
set -uo pipefail
exec "$(dirname -- "${BASH_SOURCE[0]}")/../smoke-openbios.sh" unix

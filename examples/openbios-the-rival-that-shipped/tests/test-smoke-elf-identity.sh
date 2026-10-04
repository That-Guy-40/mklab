#!/usr/bin/env bash
# test-smoke-elf-identity.sh — run smoke-openbios.sh's `elf-identity` track under this suite.
# THE DRIVER STAYS THE SINGLE IMPLEMENTATION (TODO §14, item 3); this wrapper execs it.
exec "$(dirname -- "${BASH_SOURCE[0]}")/../smoke-openbios.sh" elf-identity

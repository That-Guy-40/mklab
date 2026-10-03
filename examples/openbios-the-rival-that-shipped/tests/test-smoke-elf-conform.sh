#!/usr/bin/env bash
# test-smoke-elf-conform.sh — run smoke-openbios.sh's `elf-conform` track under this suite.
# THE DRIVER STAYS THE SINGLE IMPLEMENTATION (TODO §14, item 3); this wrapper execs it.
exec "$(dirname -- "${BASH_SOURCE[0]}")/../smoke-openbios.sh" elf-conform

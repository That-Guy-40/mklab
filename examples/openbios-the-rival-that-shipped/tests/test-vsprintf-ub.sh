#!/usr/bin/env bash
# test-vsprintf-ub.sh — run tools/openbios-check-vsprintf-ub.sh under this suite.
#
# TODO 17.4's llmin case asserts the OUTPUT and cannot tell the fix from the bug:
# on x86-64 the undefined negation happens to produce the right bytes. This is
# the instrument that can — a host build of the SHIPPED libc/vsprintf.c under
# -fsanitize=undefined — and it belongs in the suite because it costs a compile,
# not a boot.
exec "$(dirname -- "${BASH_SOURCE[0]}")/../../../tools/openbios-check-vsprintf-ub.sh" \
     "${OPENBIOS_WORKDIR:-$HOME/openbios-lab}/openbios"

#!/usr/bin/env bash
# build-gdb-iod.sh — compile `pokegdb` (gdb-iod.c), the libpoke embed with a
# gdbstub-backed foreign IO device (Spike 5). HOST-side, GPLv3 wall.
#
# No libpoke -dev package is needed: gdb-iod.c includes the vendored, byte-exact
# vendor/libpoke.h (self-contained — only stdlib/stdint/stdarg) and links the
# SHIPPED runtime library libpoke.so.N directly (we do not rely on a -dev .so
# symlink or pkg-config, neither of which the Debian `poke` package installs).
#
# Prints the built binary path on success. Exit 0 built / 77 prereq missing / 1 fail.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/pokegdb"
SRC="$HERE/gdb-iod.c"
HDR="$HERE/vendor/libpoke.h"

note() { echo "  - $*" >&2; }
skip() { echo "SKIP: $*" >&2; exit 77; }
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v "${CC:-cc}" >/dev/null || skip "no C compiler (set CC=…, or install gcc)"
[[ -f "$SRC" ]] || fail "missing $SRC"
[[ -f "$HDR" ]] || fail "missing the vendored $HDR"

# locate the shipped libpoke runtime (libpoke.so, or the versioned libpoke.so.N)
LIBPOKE=""
if command -v ldconfig >/dev/null; then
    LIBPOKE="$(ldconfig -p 2>/dev/null | awk '/libpoke\.so/{print $NF; exit}')"
fi
if [[ -z "$LIBPOKE" ]]; then
    for c in /usr/lib/*/libpoke.so* /usr/lib/libpoke.so* /usr/local/lib/libpoke.so*; do
        [[ -e "$c" ]] && { LIBPOKE="$c"; break; }
    done
fi
[[ -n "$LIBPOKE" && -e "$LIBPOKE" ]] || skip "libpoke runtime not found (install GNU poke — see deps.sh)"
note "libpoke: $LIBPOKE"

LIBDIR="$(dirname "$LIBPOKE")"
"${CC:-cc}" -O2 -Wall -Wextra -o "$OUT" "$SRC" -I "$HERE/vendor" \
    "$LIBPOKE" -Wl,-rpath,"$LIBDIR" \
    || fail "compile/link failed"

[[ -x "$OUT" ]] || fail "no binary produced"
echo "$OUT"

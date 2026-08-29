#!/usr/bin/env bash
# openbios-check-vsprintf-ub.sh — TODO 17.4's BLIND control, given an instrument
# that can actually see the defect.
#
# number() used to do `num = -num` on a long long with no guard, so LLONG_MIN
# was UNDEFINED BEHAVIOUR (§13.3(B) named it from the source and declined to
# test it, correctly: running the case meant triggering the UB). Patch 46 fixed
# it with an unsigned accumulator -- and the smoke fixture that asserts the
# OUTPUT could not tell the fix from the bug:
#
#     re-inject `-num`, run the llmin case  ->  still GREEN
#
# because on x86-64 GCC the undefined negation happens to compute the
# two's-complement bit pattern, which is the right magnitude. That was reported
# as BLIND rather than hidden, and this is the follow-through.
#
# THE INSTRUMENT MUST OUT-REACH THE DEFECT (CLAUDE.md). A firmware fixture
# compares BYTES, and the bug produces the right bytes here; no arrangement of
# byte comparisons can see it. What CAN see it is a sanitiser, which observes
# the OPERATION rather than its result -- so this compiles the SHIPPED
# libc/vsprintf.c on the host with -fsanitize=undefined and runs the same case.
#
# EXTRACT THE SHIPPED THING, NEVER RE-IMPLEMENT IT. This compiles the real file.
# The only alterations are:
#   * a stand-in config.h that supplies the TYPES the generated one does
#     (stddef/stdint) and nothing else;
#   * -Dsnprintf=/-Dvsnprintf= renames, because the firmware's names collide
#     with the host libc's at link time.
# A hand-written copy of number() would drift and then prove something about
# the copy.
#
# §0 RUNS THE CONTROL FIRST, on a copy with the old signed negation re-injected:
# the sanitiser MUST report it. A sanitiser that reports nothing and a sanitiser
# that is not wired up print the same silence.
#
# Usage: openbios-check-vsprintf-ub.sh <openbios-source-tree>
set -uo pipefail

_VERDICT=0
note() { printf '  - %s\n' "$*" >&2; }
fail() { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
skip() { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
WORK=""
_on_exit() {
    local rc=$?
    [[ -n "$WORK" ]] && rm -rf -- "$WORK"
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: openbios-check-vsprintf-ub.sh exited early (rc=%d) — no verdict was printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT
for sig in TERM INT HUP; do
    # shellcheck disable=SC2064  # $sig must expand now, at trap-install time
    trap "printf 'FAIL: openbios-check-vsprintf-ub.sh killed by SIG%s\n' $sig >&2; exit $((128 + $(kill -l "$sig")))" "$sig"
done

SRC="${1:-$HOME/openbios-lab/openbios}"
[[ -f "$SRC/libc/vsprintf.c" ]] \
    || fail "usage: openbios-check-vsprintf-ub.sh <openbios-source-tree>  (no libc/vsprintf.c under '$SRC')"
command -v gcc >/dev/null || skip "gcc is not installed — the sanitiser is the only instrument that can see this, and no instrument is an UNKNOWN, not a pass"

WORK="$(mktemp -d)"
mkdir -p "$WORK/include/libc" "$WORK/libc"
cp "$SRC/include/libc/vsprintf.h" "$SRC/include/libc/string.h" "$WORK/include/libc/"
cat > "$WORK/include/config.h" <<'EOF'
/* Stand-in for the per-arch generated config.h: the TYPES the real one brings
 * in, and nothing else. */
#include <stddef.h>
#include <stdint.h>
EOF
cat > "$WORK/harness.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include "libc/vsprintf.h"
int main(void)
{
	char buf[64];
	/* -N-1, not the literal: -9223372036854775808 is unary minus applied to
	 * a constant too large for long long -- the same trap one level up. */
	int rc = ob_snprintf(buf, sizeof buf, "%lld", -9223372036854775807LL - 1);
	printf("llmin=[%s] rc=%d\n", buf, rc);
	return strcmp(buf, "-9223372036854775808") != 0;
}
EOF

# -O0, AND THAT IS THE WHOLE INSTRUMENT. Measured 2026-08-29 on gcc 13.3: with
# the old `-num` re-injected, -fsanitize=undefined reports it at -O0 and says
# NOTHING at -O1 or -O2, because GCC legally rewrites the signed negation into
# an unsigned one and the undefined operation stops existing in the object code.
#
# That is also the deeper reason the firmware fixture could not see this: the
# firmware is not built at -O0, so at its own optimisation level the UB has
# already been optimised away and there is nothing left to observe at runtime.
# Undefined behaviour is a property of the SOURCE; -O0 is what keeps enough of
# the source in the binary for a sanitiser to point at it.
#
# -fno-sanitize-recover=all so a diagnostic is also a non-zero exit, rather than
# a line on stderr that a later grep might miss.
CFLAGS=(-std=gnu99 -I "$WORK/include" -Dsnprintf=ob_snprintf -Dvsnprintf=ob_vsnprintf
        -fsanitize=undefined -fno-sanitize-recover=all -g -O0)

# Sets BUILT, OUT and RC as GLOBALS rather than echoing a sentinel. The first
# draft printed 'BUILDFAIL' on stdout and tested $OUT for it -- which the caller
# never sets, because a plain call is not a command substitution. The build was
# failing and the control reported "the sanitiser saw nothing", blaming the
# instrument for a compile error. The control is where the bugs are.
BUILT=0
build_and_run() { # build_and_run <label> <vsprintf.c> -> sets BUILT, OUT, RC
    local label="$1" src="$2"
    BUILT=0; OUT=""; RC=0
    # libc/ctype.c comes along because vsprintf.c's isdigit() reads its
    # _ctype table. Linking the SHIPPED table beats stubbing one: a stub would
    # be a second implementation to get wrong.
    gcc "${CFLAGS[@]}" "$src" "$SRC/libc/ctype.c" "$WORK/harness.c" -o "$WORK/t-$label" 2>"$WORK/cc-$label.log" || return
    BUILT=1
    OUT="$("$WORK/t-$label" 2>&1)"; RC=$?
}

# ── §0: the control. Re-inject the pre-patch-46 signed negation and require the
# sanitiser to name it. Run FIRST, so the instrument proves itself before it is
# aimed at the shipped file.
sed 's|unum = -(unsigned long long)num;|unum = (unsigned long long)(-num);   /* CONTROL */|' \
    "$SRC/libc/vsprintf.c" > "$WORK/libc/vsprintf-ctl.c"
grep -q 'CONTROL' "$WORK/libc/vsprintf-ctl.c" \
    || fail "§0: the control edit did not apply — libc/vsprintf.c no longer contains the unsigned negation this check exists to guard, so the control below would have tested the same code twice"
build_and_run ctl "$WORK/libc/vsprintf-ctl.c"
(( BUILT == 1 )) || fail "§0: the control build failed — $(head -3 "$WORK/cc-ctl.log" | tr '\n' ' ')"
if ! grep -qiE 'runtime error|negation of -9223372036854775808|signed integer overflow' <<<"$OUT"; then
    fail "§0: with the signed negation re-injected, -fsanitize=undefined reported NOTHING (rc=$RC, output: ${OUT//$'\n'/ | }) — the sanitiser is not seeing the operation, so its silence on the shipped file below would mean nothing. This is the check that the firmware fixture could not make."
fi
note "§0 control: the pre-patch-46 \`-num\` is reported by the sanitiser — $(grep -oiE '[^ ]*runtime error[^|]*' <<<"${OUT//$'\n'/ | }" | head -1 | cut -c1-96)"

# ── the shipped file
build_and_run real "$SRC/libc/vsprintf.c"
(( BUILT == 1 )) || fail "the shipped libc/vsprintf.c did not compile on the host — $(head -3 "$WORK/cc-real.log" | tr '\n' ' ')"
if grep -qiE 'runtime error' <<<"$OUT"; then
    fail "REGRESSION: -fsanitize=undefined reports undefined behaviour in the SHIPPED libc/vsprintf.c formatting LLONG_MIN: ${OUT//$'\n'/ | } — patch 46's unsigned accumulator is gone or has been narrowed"
fi
(( RC == 0 )) \
    || fail "the shipped libc/vsprintf.c formatted LLONG_MIN wrongly on the host (rc=$RC): ${OUT//$'\n'/ | }"
note "shipped: $OUT — no sanitiser diagnostic"
pass "TODO 17.4's BLIND control is closed with an instrument that can see the defect: compiling the SHIPPED libc/vsprintf.c under -fsanitize=undefined reports NOTHING for LLONG_MIN, while the same file with patch 46's unsigned accumulator reverted to \`-num\` is reported by name — which is the distinction the firmware fixture structurally could not make, because on x86-64 the undefined negation happens to produce the right bytes"

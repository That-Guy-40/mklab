#!/usr/bin/env bash
# demo.sh — floating-point arithmetic in Bash: prove it, don't just show it.
#
# Runs in ~/float-math/ inside the lab container (see ../setup-workshop.sh).
# Ends on exactly one verdict line: PASS: / FAIL: / SKIP:.
#
# THE PREMISE. Bash's `$(( ))` is integer-only. `$((1/3))` is 0 -- silently, with
# no error. So how do you do decimal math in a Bash script? This demo runs FOUR
# independent answers over the same numbers and checks they agree:
#
#     bc          an external, ARBITRARY-PRECISION DECIMAL calculator (a fork)
#     awk         an external, BINARY IEEE-754 calculator             (a fork)
#     div         Cyrus's recursive long division, PURE BASH          (no fork)
#     shellmath   Michael Wood's full float library, PURE BASH        (no fork)
#
# ...and then it proves that on one famous question they are *supposed* to
# disagree, because two of them are decimal and one of them is binary.
#
# LC_ALL=C is load-bearing. The decimal separator is locale-dependent: under a
# comma locale, Bash's own printf REFUSES to parse "1.5" and prints a wrong value,
# while awk and bc keep using a dot. One export is why this file is reproducible.
export LC_ALL=C

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSED=0; FAILED=0

# ── verdict helpers (house convention) ─────────────────────────────────────────
note() { printf '  %s\n' "$*"; }
ok()   { PASSED=$((PASSED+1)); printf '   [ok]  %s\n' "$*"; }
bad()  { FAILED=$((FAILED+1)); printf '   [XX]  %s\n' "$*"; }
check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"
    else bad "$1"; printf '            expected: [%s]\n            actual:   [%s]\n' "$2" "$3"; fi
}
# EXIT-trap safety net: a bare `exit` must never leave the reader with no verdict.
_verdict_printed=""
trap '[ -n "$_verdict_printed" ] || { rc=$?; [ "$rc" = 0 ] && rc=1; printf "FAIL: demo.sh exited early (rc=%s)\n" "$rc"; }' EXIT

command -v bc  >/dev/null || { _verdict_printed=1; echo "SKIP: bc not installed (run setup-workshop.sh)"; exit 77; }
command -v awk >/dev/null || { _verdict_printed=1; echo "SKIP: awk not installed"; exit 77; }
[ -r "$HERE/shellmath/shellmath.sh" ] || { _verdict_printed=1; echo "SKIP: shellmath not present (run setup-workshop.sh)"; exit 77; }

# The three pure-Bash implementations under test.
. "$HERE/bin/div"                 # Cyrus, VERBATIM  -> div()
. "$HERE/bin/fixed/sci2dec"       # our workaround   -> sci2dec()
. "$HERE/shellmath/shellmath.sh"  # Michael Wood     -> _shellmath_*()
# fixed/div defines div() too, so load it in a subshell-safe way under a new name:
fdiv() { ( . "$HERE/bin/fixed/div"; div "$@" ); }

# Truncate a numeric string to N decimals WITHOUT rounding, and normalize the two
# ways these tools spell the same number:
#   * bc omits the leading zero        ".3"     -> "0.3"
#   * shellmath returns SCIENTIFIC     "1.2e0"  -> "1.2"   (expanded exactly by
#     notation from add/subtract                            sci2dec -- no binary
#                                                           float ever touches it)
trunc() { # trunc <ndecimals> <number>
    local n="$2"
    case "$n" in *[eE]*) n="$(sci2dec "$n")" ;; esac
    awk -v n="$n" -v k="$1" 'BEGIN{
        if (n ~ /^-?\./) sub(/^-?/, "&0", n)          # ".3" -> "0.3"
        neg = (n ~ /^-/); sub(/^-/, "", n)
        i = index(n, "."); if (i == 0) { ip = n; fp = "" } else { ip = substr(n,1,i-1); fp = substr(n,i+1) }
        while (length(fp) < k) fp = fp "0"
        printf "%s%s.%s\n", (neg && (ip+0 != 0 || fp+0 != 0) ? "-" : ""), ip, substr(fp,1,k)
    }'
}

echo "================================================================"
echo " Floating-point arithmetic in Bash -- because they said it couldn't be done"
echo "================================================================"

# ── 1. THE WALL ────────────────────────────────────────────────────────────────
echo
echo "1. THE WALL: Bash's \$(( )) is integer-only -- and it fails SILENTLY."
note "\$((1/3))  -> $((1/3))          <- not 0.333..., just 0. No error."
note "\$((7/2))  -> $((7/2))          <- not 3.5. No error."
check "WALL: \$((1/3)) truncates to 0, silently"  "0" "$((1/3))"
check "WALL: \$((7/2)) truncates to 3, silently"  "3" "$((7/2))"
if err=$(bash -c 'echo $((1.5 + 1))' 2>&1); then
    bad "WALL: \$((1.5+1)) should be a syntax error, but it printed [$err]"
else
    ok "WALL: \$((1.5+1)) is a hard syntax error (Bash cannot even parse a decimal)"
    note "     bash says: ${err#*: }"
fi

# ── 2. IT IS A *BASH* LIMITATION, NOT A *SHELL* LIMITATION ────────────────────
echo
echo "2. ...but the shell next door has done this for decades."
if command -v zsh >/dev/null; then
    z=$(zsh -c 'echo $((1.0/3))' 2>/dev/null)
    note "zsh  \$((1.0/3)) -> $z"
    case "$z" in 0.3333*) ok "ZSH: native float arithmetic in \$(( )) -- same syntax, works" ;;
                 *) bad "ZSH: expected 0.3333..., got [$z]" ;; esac
else
    note "zsh not installed -- skipping (not counted)"
fi
if command -v ksh >/dev/null; then
    k=$(ksh -c 'echo $((1.0/3))' 2>/dev/null)
    note "ksh  \$((1.0/3)) -> $k   <- long double, even more digits than zsh"
fi
note "So 'the shell can't do floats' is really 'BASH can't'. Hence everything below."

# ── 3. FOUR IMPLEMENTATIONS, ONE QUOTIENT ─────────────────────────────────────
echo
echo "3. THE CORE IDENTITY: bc == awk == div (pure bash) == shellmath"
for pair in "1 3" "2 3" "7 34" "1080 633" "8 32" "22 7"; do
    set -- $pair
    a=$1 b=$2
    r_bc=$(trunc 8 "$(echo "scale=12; $a/$b" | bc)")
    r_awk=$(trunc 8 "$(awk -v x="$a" -v y="$b" 'BEGIN{printf "%.15f", x/y}')")
    r_div=$(trunc 8 "$(fdiv "$a" "$b" 12)")
    _shellmath_divide "$a" "$b" >/dev/null; _shellmath_getReturnValue _sm
    r_sm=$(trunc 8 "$_sm")
    if [ "$r_bc" = "$r_awk" ] && [ "$r_bc" = "$r_div" ] && [ "$r_bc" = "$r_sm" ]; then
        ok "QUOTIENT $a/$b = $r_bc  (all four agree)"
    else
        bad "QUOTIENT $a/$b: bc=$r_bc awk=$r_awk div=$r_div shellmath=$r_sm"
    fi
done

# ── 4. THE PUBLISHED OUTPUTS ──────────────────────────────────────────────────
echo
echo "4. Reproduce the sources' own published output."
pub_ok=1
for spec in "1080 633:1.706161137440" "7 34:0.205882352941" "8 32:0.25" \
            "246891510 2:123445755" "5000000 177:28248.587570621468"; do
    args=${spec%%:*}; want=${spec##*:}
    got=$(div $args)                       # the VERBATIM script
    [ "$got" = "$want" ] || { pub_ok=0; note "MISMATCH: div $args -> $got (published: $want)"; }
done
[ "$pub_ok" = 1 ] && ok "PUBLISHED: Cyrus's five printed results reproduce byte-for-byte" \
                  || bad "PUBLISHED: Cyrus's printed results did not reproduce"

# shellmath's two demos must agree with each other and with bc's value of e.
e_slow=$(cd "$HERE/shellmath" && ./slower_e_demo.sh 15 2>/dev/null | sed 's/^e = //')
e_fast=$(cd "$HERE/shellmath" && ./faster_e_demo.sh 15 2>/dev/null | sed 's/^e = //')
e_bc=$(echo "scale=20; e(1)" | bc -l)
check "SHELLMATH: slower_e_demo == faster_e_demo (the optimization is sound)" "$e_slow" "$e_fast"
# 10 decimals, not more: the limit here is the 15th-degree MACLAURIN POLYNOMIAL,
# not shellmath. Degree 15 pins e to ~13 significant figures, so demanding 12
# decimals would be testing calculus, not arithmetic.
check "SHELLMATH: e agrees with bc to 10 decimals" "$(trunc 10 "$e_bc")" "$(trunc 10 "$e_slow")"
note "shellmath e (deg-15 Maclaurin) = $e_slow"
note "bc        e (bc -l)            = $e_bc"

# ── 5. THE DISAGREEMENT THAT IS *CORRECT* ─────────────────────────────────────
echo
echo "5. 0.1 + 0.2: where they are SUPPOSED to disagree (decimal vs binary)."
sm_sum=$(_shellmath_add 0.1 0.2 >/dev/null; _shellmath_getReturnValue s; echo "$s")
bc_eq=$(echo "0.1 + 0.2 == 0.3" | bc)
awk_eq=$(awk 'BEGIN{print (0.1+0.2==0.3) ? 1 : 0}')
note "bc        0.1+0.2 -> $(echo "0.1+0.2" | bc)   (arbitrary-precision DECIMAL)"
note "shellmath 0.1+0.2 -> $sm_sum      (DECIMAL: splits int/frac parts)"
note "awk       0.1+0.2 -> $(awk 'BEGIN{printf "%.20f", 0.1+0.2}')   (binary IEEE-754)"
check "DECIMAL: bc says 0.1+0.2 == 0.3 exactly"          "1"   "$bc_eq"
check "DECIMAL: shellmath says 0.1+0.2 == 0.3 exactly"   "0.3" "$sm_sum"
check "BINARY:  awk says 0.1+0.2 != 0.3  (and awk is RIGHT -- 0.1 is not representable in base 2)" "0" "$awk_eq"

# ── 6. ERRATA: the published code is broken, and it breaks QUIETLY ────────────
echo
echo "6. ERRATA -- found by RUNNING the sources, not reading them."
g=$(div -7 2)
if [ "$g" = "-3.-5" ]; then
    ok "REGRESSION: div -7 2 still emits the documented garbage '-3.-5' (verbatim bug preserved)"
else
    bad "REGRESSION: div -7 2 emitted [$g]; the archive is supposed to be the BROKEN original"
fi
check "FIXED: fixed/div -7 2 = -3.5"            "-3.5"            "$(fdiv -7 2)"
check "FIXED: fixed/div -1 3 = -0.333333333333" "-0.333333333333" "$(fdiv -1 3)"

ovf=$(div 999999999999999999 1000000000000000000)
case "$ovf" in
    *-*) ok "REGRESSION: div overflows int64 on a big divisor and prints garbage ($ovf)" ;;
    *)   bad "REGRESSION: expected overflow garbage from the verbatim div, got [$ovf]" ;;
esac
if fdiv 999999999999999999 1000000000000000000 >/dev/null 2>&1; then
    bad "FIXED: fixed/div should REFUSE a divisor > INTMAX/10"
else
    ok "FIXED: fixed/div refuses the overflowing divisor (loudly, non-zero exit)"
fi

# shellmath: additive ops mis-scale scientific notation with exponent <= -2.
_shellmath_add 1 2e-2 >/dev/null; _shellmath_getReturnValue s1
_shellmath_add 1 "$(sci2dec 2e-2)" >/dev/null; _shellmath_getReturnValue s2
note "shellmath  1 + 2e-2   -> $(trunc 4 "$s1")   <- WRONG (e-2 treated as e-1)"
note "shellmath  1 + $(sci2dec 2e-2)  -> $(trunc 4 "$s2")   <- correct, via sci2dec"
check "REGRESSION: shellmath 1+2e-2 is still wrong (1.2, not 1.02)" "1.2000" "$(trunc 4 "$s1")"
check "FIXED: sci2dec expands 2e-2 -> shellmath gets 1.02 right"    "1.0200" "$(trunc 4 "$s2")"

# The README's OWN example lands in that bug.
_shellmath_add 1.009 4.223e-2 >/dev/null; _shellmath_getReturnValue r1
_shellmath_add 1.009 "$(sci2dec 4.223e-2)" >/dev/null; _shellmath_getReturnValue r2
note "shellmath README example: 1.009 + 4.223e-2 -> $(trunc 5 "$r1")  (should be 1.05123)"
check "REGRESSION: shellmath's own README example is wrong (1.2643)" "1.26430" "$(trunc 5 "$r1")"
check "FIXED: with sci2dec, the README example gives 1.05123"        "1.05123" "$(trunc 5 "$r2")"

# ── verdict ───────────────────────────────────────────────────────────────────
echo
echo "----------------------------------------------------------------"
TOTAL=$((PASSED+FAILED))
_verdict_printed=1
if [ "$FAILED" -eq 0 ]; then
    echo "PASS: all $TOTAL checks hold (bc == awk == pure-bash div == shellmath;"
    echo "      decimal and binary disagree exactly where they must; all 4 errata reproduce)"
    exit 0
else
    echo "FAIL: $FAILED of $TOTAL checks failed"
    exit 1
fi

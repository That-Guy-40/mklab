#!/bin/bash
# treasure-hunt.sh — reproduce Google Treasure Hunt 2008, Puzzle 4, from the shell.
#
#   "Find the smallest number that can be expressed as the sum of 7 consecutive
#    prime numbers, the sum of 17 consecutive prime numbers, the sum of 41
#    consecutive prime numbers, the sum of 541 consecutive prime numbers, and is
#    itself a prime number."
#
# Peteris Krumins solved this entirely with Unix tools on 2008-06-06. The crux is
# a four-way SET INTERSECTION, and it is what led him to write "Set Operations in
# the Unix Shell" in the first place:
#   https://catonmat.net/solving-google-treasure-hunt-prime-number-problem-four
#
# The answer is 7830239.
#
# ── What is faithful, and what is not ────────────────────────────────────────
# Krumins downloaded 50 million primes as 50 zip files from primes.utm.edu and
# reshaped them with awk. That list has since moved, and 50M primes is ~500 MB.
# We generate the primes we need instead, with coreutils' `factor` — no network,
# no download, ~0.2 s. Everything AFTER that is his pipeline, unchanged:
#
#   sort -nm primes541 primes41 | uniq -d | sort -nm primes17 - | uniq -d | ...
#
# ── The point of this script ─────────────────────────────────────────────────
# His pipeline intersects with `sort -nm … | uniq -d`, which is CORRECT: `uniq`
# only needs equal lines to be ADJACENT, and a numeric merge delivers that.
#
# His ARTICLE, meanwhile, recommends `comm -12 <(sort -n set1) <(sort -n set2)`
# for numeric sets. `comm` merges byte-wise. Run that recipe on this puzzle's own
# data and the answer vanishes. This script proves both, side by side.
# No `pipefail`: several pipelines below end in `head`, which exits early and
# SIGPIPEs its producer. That is expected here, not an error.
set -u
export LC_ALL=C

cd "$(dirname "$0")" || exit 1
W="$(mktemp -d)"
trap 'rc=$?; rm -rf "$W"; if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
        echo "FAIL: treasure-hunt.sh exited early (rc=$rc)"; fi' EXIT

ANSWER=7830239
# Primes up to PRIME_MAX; every window-sum we keep is <= MAX_SUM.
PRIME_MAX=1200000
MAX_SUM=8000000
WINDOWS="7 17 41 541"

echo "== Google Treasure Hunt 2008, Puzzle 4 =="
echo "   smallest prime that is a sum of 7, 17, 41 AND 541 consecutive primes"
echo

# ── 1. the primes ────────────────────────────────────────────────────────────
echo "[1/4] generating primes <= $PRIME_MAX with coreutils \`factor\`"
# `factor` prints "n: p q r"; a prime factorises to itself, so NF==2.
seq 2 "$PRIME_MAX" | factor | awk 'NF == 2 { print $2 }' > "$W/primes.txt"
printf '      %s primes, largest %s\n' "$(wc -l < "$W/primes.txt")" "$(tail -1 "$W/primes.txt")"

# ── 2. the four sum files ────────────────────────────────────────────────────
echo "[2/4] sliding-window sums of N consecutive primes, keeping those <= $MAX_SUM"
for N in $WINDOWS; do
    # Keep a ring buffer of the last N primes; emit the running window sum.
    awk -v n="$N" '
        { ring[NR % n] = $1; sum += $1
          if (NR >= n) { print sum; sum -= ring[(NR + 1) % n] } }
    ' "$W/primes.txt" > "$W/all$N.txt"
    awk -v cap="$MAX_SUM" '$1 <= cap' "$W/all$N.txt" > "$W/sums$N.txt"

    # Completeness guard: we must have generated PAST the cap, otherwise we ran
    # out of primes and the sum file is silently truncated -- which would make a
    # missing answer look like "no solution" instead of "not enough primes".
    biggest=$(tail -1 "$W/all$N.txt")
    if [ "$biggest" -le "$MAX_SUM" ]; then
        echo "FAIL: only $PRIME_MAX primes -- window $N tops out at $biggest, below the $MAX_SUM cap."
        echo "      Raise PRIME_MAX; the sum files are incomplete and any answer would be unproven."
        exit 1
    fi
    printf '      sums of %3s consecutive primes: %6s kept (max %s, overshoot %s)\n' \
        "$N" "$(wc -l < "$W/sums$N.txt")" "$(tail -1 "$W/sums$N.txt")" "$biggest"
done
echo "      every window overshoots the cap => the four sum files are COMPLETE below it"

# ── 3. the four-way intersection, Krumins' own pipeline ──────────────────────
echo "[3/4] four-way intersection, his pipeline:  sort -nm | uniq -d"
sort -nm "$W/sums541.txt" "$W/sums41.txt" | uniq -d \
  | sort -nm "$W/sums17.txt" - | uniq -d \
  | sort -nm "$W/sums7.txt"  - | uniq -d > "$W/hits.txt"
printf '      candidates: %s\n' "$(tr '\n' ' ' < "$W/hits.txt")"

# ── 4. smallest candidate, and is it prime? ──────────────────────────────────
echo "[4/4] take the smallest candidate and test primality with \`factor\`"
smallest=$(sort -n "$W/hits.txt" | head -1)
factorisation=$(factor "$smallest")
printf '      factor %s -> %s\n' "$smallest" "$factorisation"
if [ "$factorisation" = "$smallest: $smallest" ]; then
    echo "      it is prime."
else
    echo "FAIL: smallest candidate $smallest is not prime; the puzzle wants a prime."
    exit 1
fi

# ── the moral: his article's own recipe would have lost this answer ──────────
echo
echo "== The same intersection, done the way his ARTICLE recommends =="
echo "   article: 'if you have a numeric set, then sort must take -n option'"
echo "            comm -12 <(sort -n set1) <(sort -n set2)"
comm -12 <(sort -n "$W/sums541.txt") <(sort -n "$W/sums41.txt") 2>/dev/null > "$W/c1"
comm -12 <(sort -n "$W/c1")          <(sort -n "$W/sums17.txt") 2>/dev/null > "$W/c2"
comm -12 <(sort -n "$W/c2")          <(sort -n "$W/sums7.txt")  2>/dev/null > "$W/c3"
printf "   step 1 (comm + sort -n)  -> %s elements\n" "$(wc -l < "$W/c1")"
printf "   ground truth (awk hash)  -> %s elements\n" \
    "$(awk 'NR==FNR { a[$0]; next } $0 in a' "$W/sums541.txt" "$W/sums41.txt" | wc -l)"
printf "   final answer             -> '%s'\n" "$(tr '\n' ' ' < "$W/c3")"
echo
echo "   comm merges BYTE-wise. Fed 'sort -n' order it walks off the end of a file"
echo "   and reports no match -- no error, exit status 0, just a missing answer."
echo "   Used correctly (lexicographic sort), comm gets it right:"
comm -12 <(sort "$W/sums541.txt") <(sort "$W/sums41.txt") > "$W/d1"
comm -12 <(sort "$W/d1")          <(sort "$W/sums17.txt") > "$W/d2"
comm -12 <(sort "$W/d2")          <(sort "$W/sums7.txt")  > "$W/d3"
printf "   comm + lexicographic sort -> '%s'\n" "$(tr '\n' ' ' < "$W/d3")"

echo
lex=$(tr -d '\n' < "$W/d3")
if [ "$smallest" = "$ANSWER" ] && [ "$lex" = "$ANSWER" ] && [ ! -s "$W/c3" ]; then
    echo "PASS: puzzle 4 answer is $ANSWER (prime, and a sum of 7, 17, 41 and 541 consecutive primes);"
    echo "      his sort -nm|uniq -d pipeline finds it, his article's comm+sort -n recipe does not"
    exit 0
fi
echo "FAIL: expected $ANSWER via uniq -d and via lexicographic comm, and nothing via comm+sort -n"
echo "      got: uniq -d='$smallest'  lex-comm='$lex'  comm+sort -n='$(tr -d '\n' < "$W/c3")'"
exit 1

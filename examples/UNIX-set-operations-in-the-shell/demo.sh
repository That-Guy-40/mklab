#!/bin/bash
# demo.sh — 14 set operations, computed three ways, and a proof they agree.
#
# Walks Krumins' fourteen set operations using (a) the merge family (`comm`),
# (b) the count family (`sort | uniq -c/-d/-u`, which is Thomas Guest's route),
# (c) the hash family (`awk` associative arrays, `grep -xF -f`) — then checks all
# of them against a real SQL engine's UNION / INTERSECT / EXCEPT.
#
# Ends on exactly one verdict line: PASS: / FAIL:  (exit 0 / 1)
#
# Requires bash (process substitution), GNU coreutils, gawk, perl, sqlite3.
set -u

cd "$(dirname "$0")" || exit 1

# A set is unordered with no duplicates, so comparing two of them means
# canonicalizing first — that is `sort -u`. And `sort`'s idea of order is
# locale-dependent, so glibc and musl would disagree unless we pin the collation.
# It is also why `comm` and `join` demand sorted input: they stream-merge.
export LC_ALL=C

W="$(mktemp -d)"
CHECKS=0
FAILED=0
trap 'rc=$?; rm -rf "$W"; if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
        echo "FAIL: demo.sh exited early (rc=$rc)"; fi' EXIT

p() { printf '\n== %s ==\n' "$1"; }
canon() { sort -u; }

# check <what> <fileA> <fileB>
check() {
    CHECKS=$((CHECKS + 1))
    if cmp -s "$2" "$3"; then printf '   [ok]  %s\n' "$1"
    else FAILED=$((FAILED + 1)); printf '   [BAD] %s\n' "$1"
         diff -u "$2" "$3" | sed 's/^/          /'; fi
}
# check_str <what> <got> <want>
check_str() {
    CHECKS=$((CHECKS + 1))
    if [ "$2" = "$3" ]; then printf '   [ok]  %s\n' "$1"
    else FAILED=$((FAILED + 1)); printf '   [BAD] %s  (got "%s", want "%s")\n' "$1" "$2" "$3"; fi
}

# ── the SQL oracle: sqlite3's UNION / INTERSECT / EXCEPT are the set operators ──
DB="$W/sets.db"
for t in A B Asub Anotsub Aequal Bequal P Q; do
    lt="$(printf '%s' "$t" | tr 'A-Z' 'a-z')"
    sqlite3 "$DB" "CREATE TABLE $lt(x TEXT);"
    printf '.mode tabs\n.import data/%s %s\n' "$t" "$lt" | sqlite3 "$DB"
done
sq() { sqlite3 -batch -noheader "$DB" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
p '0. A set is a file: one element per line'
echo '--- data/A and data/B (Krumins hand-crafted these so 1,2,3 are in common)'
paste data/A data/B | sed 's/^/    A=/;s/\t/   B=/'

# ─────────────────────────────────────────────────────────────────────────────
p '1. MEMBERSHIP  (a ∈ A)  —  grep -xq   vs   awk'
echo -n '    grep -xc 4   A -> '; grep -xc '4'   data/A
echo -n '    grep -xc 999 A -> '; grep -xc '999' data/A
grep -xqF -- '4' data/A && g4=yes || g4=no
awk -v e=4 '$0 == e { s=1; exit } END { exit !s }' data/A && a4=yes || a4=no
check_str "MEMBERSHIP:  grep -xq  ==  awk" "$g4/$a4" "yes/yes"

# ─────────────────────────────────────────────────────────────────────────────
p '2. UNION  (A ∪ B)  —  cat is union; sort -u makes it a SET again'
echo '--- cat A B  (a multiset: 1, 2 and 3 appear twice)'
cat data/A data/B | tr '\n' ' '; echo
sort -u data/A data/B                                  > "$W/u_sort"
awk '!a[$0]++' data/A data/B            | canon        > "$W/u_awk"
sq 'SELECT x FROM a UNION SELECT x FROM b ORDER BY x;' > "$W/u_sql"
echo '--- sort -u A B'; tr '\n' ' ' < "$W/u_sort"; echo
check "UNION:        sort -u  ==  awk '!a[\$0]++'" "$W/u_sort" "$W/u_awk"
check "UNION:        sort -u  ==  SQL UNION"       "$W/u_sort" "$W/u_sql"

# ─────────────────────────────────────────────────────────────────────────────
p '3. INTERSECTION  (A ∩ B)  —  five recipes, three different algorithms'
sort -u data/A > "$W/a.s"; sort -u data/B > "$W/b.s"
comm -12 "$W/a.s" "$W/b.s"                                    > "$W/i_comm"    # merge
sort data/A data/B | uniq -d                     | canon      > "$W/i_uniqd"   # count
sort -m "$W/a.s" "$W/b.s" | uniq -c | awk '$1==2 {print $2}' \
                                                 | canon      > "$W/i_count"   # count (Guest)
grep -xF -f data/A data/B                        | canon      > "$W/i_grep"    # hash
awk 'NR==FNR { a[$0]; next } $0 in a' data/A data/B | canon   > "$W/i_awk"     # hash
sq 'SELECT x FROM a INTERSECT SELECT x FROM b ORDER BY x;'    > "$W/i_sql"
echo -n '    comm -12          : '; tr '\n' ' ' < "$W/i_comm";  echo
echo -n '    sort | uniq -d    : '; tr '\n' ' ' < "$W/i_uniqd"; echo
echo -n "    uniq -c '\$1==2'   : "; tr '\n' ' ' < "$W/i_count"; echo
echo -n '    grep -xF -f       : '; tr '\n' ' ' < "$W/i_grep";  echo
echo -n '    awk hash          : '; tr '\n' ' ' < "$W/i_awk";   echo
check "INTERSECTION: comm(merge)  ==  uniq -d(count)"  "$W/i_comm" "$W/i_uniqd"
check "INTERSECTION: comm(merge)  ==  uniq -c(Guest)"  "$W/i_comm" "$W/i_count"
check "INTERSECTION: comm(merge)  ==  grep -xF(hash)"  "$W/i_comm" "$W/i_grep"
check "INTERSECTION: comm(merge)  ==  awk(hash)"       "$W/i_comm" "$W/i_awk"
check "INTERSECTION: comm(merge)  ==  SQL INTERSECT"   "$W/i_comm" "$W/i_sql"

# ─────────────────────────────────────────────────────────────────────────────
p '4. COMPLEMENT  (A − B)  —  comm, grep, the sort B B A trick, awk'
comm -23 "$W/a.s" "$W/b.s"                                       > "$W/c_comm"
grep -vxF -f data/B data/A                          | canon      > "$W/c_grep"
sort data/B data/B data/A | uniq -u                 | canon      > "$W/c_trick"
awk 'NR==FNR { b[$0]; next } !($0 in b)' data/B data/A | canon   > "$W/c_awk"
sq 'SELECT x FROM a EXCEPT SELECT x FROM b ORDER BY x;'          > "$W/c_sql"
echo -n '    comm -23              : '; tr '\n' ' ' < "$W/c_comm";  echo
echo -n '    grep -vxF -f B A      : '; tr '\n' ' ' < "$W/c_grep";  echo
echo -n '    sort B B A | uniq -u  : '; tr '\n' ' ' < "$W/c_trick"; echo
check "COMPLEMENT:   comm -23  ==  grep -vxF"          "$W/c_comm" "$W/c_grep"
check "COMPLEMENT:   comm -23  ==  sort B B A|uniq -u" "$W/c_comm" "$W/c_trick"
check "COMPLEMENT:   comm -23  ==  awk hash"           "$W/c_comm" "$W/c_awk"
check "COMPLEMENT:   comm -23  ==  SQL EXCEPT"         "$W/c_comm" "$W/c_sql"

# ─────────────────────────────────────────────────────────────────────────────
p '5. SYMMETRIC DIFFERENCE  (A △ B)  =  (A−B) ∪ (B−A)'
comm -3 "$W/a.s" "$W/b.s" | tr -d '\t'               | canon > "$W/s_comm"
sort data/A data/B | uniq -u                         | canon > "$W/s_uniqu"
{ grep -vxF -f data/A data/B; grep -vxF -f data/B data/A; } | canon > "$W/s_grep"
# NOTE the subqueries: SQLite's compound operators are LEFT-associative, so
# "a EXCEPT b UNION b EXCEPT a" would parse as ((a EXCEPT b) UNION b) EXCEPT a.
sq 'SELECT x FROM (SELECT x FROM a EXCEPT SELECT x FROM b)
    UNION
    SELECT x FROM (SELECT x FROM b EXCEPT SELECT x FROM a) ORDER BY x;' > "$W/s_sql"
echo -n '    comm -3 | tr -d       : '; tr '\n' ' ' < "$W/s_comm";  echo
echo -n '    sort A B | uniq -u    : '; tr '\n' ' ' < "$W/s_uniqu"; echo
check "SYMDIFF:      comm -3  ==  uniq -u"     "$W/s_comm" "$W/s_uniqu"
check "SYMDIFF:      comm -3  ==  grep pair"   "$W/s_comm" "$W/s_grep"
check "SYMDIFF:      comm -3  ==  SQL EXCEPT/UNION" "$W/s_comm" "$W/s_sql"

# ─────────────────────────────────────────────────────────────────────────────
p '6. SUBSET, EQUALITY, CARDINALITY, DISJOINT, EMPTY, MIN, MAX'
. bin/fixed/setops
set_subset data/Asub    data/A && r1=yes || r1=no
set_subset data/Anotsub data/A && r2=yes || r2=no
echo "    Asub ⊆ A ? $r1        Anotsub ⊆ A ? $r2"
sqsub=$(sq 'SELECT COUNT(*) FROM (SELECT x FROM asub EXCEPT SELECT x FROM a);')
check_str "SUBSET:       comm  ==  awk  ==  SQL (empty EXCEPT)" "$r1/$r2/$sqsub" "yes/no/0"

set_equal data/Aequal data/Bequal && e1=yes || e1=no
set_equal data/A      data/B      && e2=yes || e2=no
echo "    Aequal = Bequal ? $e1     A = B ? $e2"
check_str "EQUALITY:     diff -q on sorted sets" "$e1/$e2" "yes/no"

card_wc=$(set_card data/A)
card_awk=$(sort -u data/A | awk 'END { print NR }')
card_sql=$(sq 'SELECT COUNT(DISTINCT x) FROM a;')
echo "    |A| = $card_wc"
check_str "CARDINALITY:  wc -l  ==  awk NR  ==  SQL COUNT" "$card_wc/$card_awk/$card_sql" "5/5/5"

set_disjoint data/A        data/B && d1=yes || d1=no
set_disjoint data/Anotsub  data/A && d2=yes || d2=no
echo "    A ∩ B = Ø ? $d1        Anotsub ∩ A = Ø ? $d2"
check_str "DISJOINT:     intersection-is-empty test" "$d1/$d2" "no/yes"

: > "$W/empty"
set_empty "$W/empty" && z1=yes || z1=no
set_empty data/A     && z2=yes || z2=no
mn=$(set_min data/A); mx=$(set_max data/A)
mn_sql=$(sq 'SELECT MIN(CAST(x AS INTEGER)) FROM a;'); mx_sql=$(sq 'SELECT MAX(CAST(x AS INTEGER)) FROM a;')
echo "    empty? Ø:$z1 A:$z2      min(A)=$mn  max(A)=$mx"
check_str "EMPTY/MIN/MAX: head/tail  ==  SQL MIN/MAX" "$z1/$z2/$mn/$mx" "yes/no/$mn_sql/$mx_sql"

# ─────────────────────────────────────────────────────────────────────────────
p '7. CARTESIAN PRODUCT (A × B)  and  POWER SET (2^A)'
set_product data/A data/B                                   | sort > "$W/x_sh"
awk 'NR==FNR { a[FNR]=$0; n=FNR; next }
     { for (i=1; i<=n; i++) print a[i] ", " $0 }' data/A data/B | sort > "$W/x_awk"
sq "SELECT a.x || ', ' || b.x FROM a, b ORDER BY 1;"        | sort > "$W/x_sql"
echo "    |A × B| = $(wc -l < "$W/x_sh")   (must be |A|·|B| = 25)"
check "PRODUCT:      bash loops  ==  awk"          "$W/x_sh" "$W/x_awk"
check "PRODUCT:      bash loops  ==  SQL CROSS JOIN" "$W/x_sh" "$W/x_sql"

n=$(wc -l < data/A); want=$(( 1 << n ))
bash bin/powerset data/A | sed 's/ *$//' | sort > "$W/ps_sh"
got_sh=$(wc -l < "$W/ps_sh")
got_pl=$(perl bin/fixed/powerset.pl data/A | wc -l)
echo "    |A|=$n  so |P(A)| must be 2^$n = $want   (bash: $got_sh, perl: $got_pl)"
check_str "POWER SET:    |P(A)| = 2^|A|, bash and perl agree" "$got_sh/$got_pl" "$want/$want"

# ─────────────────────────────────────────────────────────────────────────────
p "8. Guest's real problem: which IP addresses hit BOTH Apache logs?"
cut -f1 -d" " data/access_log1 | sort -u > "$W/IP1"
cut -f1 -d" " data/access_log2 | sort -u > "$W/IP2"
echo "    |IP1| = $(wc -l < "$W/IP1")   |IP2| = $(wc -l < "$W/IP2")"
echo '--- his count-based intersection: sort -m | uniq -c | grep "^ *2" | tr -s " " | cut -f3 -d" "'
sort -m "$W/IP1" "$W/IP2" | uniq -c | grep "^ *2" | tr -s " " | cut -f3 -d" " | canon > "$W/g_count"
cat "$W/g_count" | sed 's/^/      /'
comm -12 "$W/IP1" "$W/IP2" > "$W/g_comm"
awk 'NR==FNR { a[$0]; next } $0 in a' "$W/IP1" "$W/IP2" | canon > "$W/g_awk"
check "APACHE LOGS:  Guest's uniq -c  ==  comm -12  ==  awk" "$W/g_count" "$W/g_comm"
check "APACHE LOGS:  comm -12  ==  awk hash"                 "$W/g_comm"  "$W/g_awk"
echo '--- and his point about ordering: lexicographic sort is not natural for IPs'
echo -n '      sort    : '; sort    "$W/IP1" | tr '\n' ' '; echo
echo -n '      sort -V : '; sort -V "$W/IP1" | tr '\n' ' '; echo

# ─────────────────────────────────────────────────────────────────────────────
p '9. THE LANDMINE:  comm merges BYTE-wise, so `sort -n` breaks it'
echo '    P = {1, 9, 10}    Q = {10}    so  P ∩ Q  =  {10}'
pub=$( . bin/setops;       set_intersect data/P data/Q 2>/dev/null | tr '\n' ' ' )
fix=$( . bin/fixed/setops; set_intersect data/P data/Q 2>/dev/null | tr '\n' ' ' )
sqi=$( sq 'SELECT x FROM p INTERSECT SELECT x FROM q;' | tr '\n' ' ' )
echo "    bin/setops       (article's sort -n)   -> '${pub}'   <-- EMPTY. WRONG."
echo "    bin/fixed/setops (lexicographic sort)  -> '${fix}'"
echo "    sqlite3 INTERSECT                      -> '${sqi}'"
echo '    comm walks 1 < 9 < 10 expecting 1 < 10 < 9, runs off the end, finds nothing.'
check_str "LANDMINE:     published comm+sort -n loses the intersection" "$pub" ""
check_str "LANDMINE:     fixed  ==  SQL INTERSECT  ==  {10}" "$fix" "$sqi"

echo '--- why nobody noticed: on Krumins own A and B, both spellings agree'
pubA=$( . bin/setops;       set_intersect data/A data/B | sort -u | tr '\n' ' ' )
fixA=$( . bin/fixed/setops; set_intersect data/A data/B | tr '\n' ' ' )
echo "    published -> '${pubA}'"
echo "    fixed     -> '${fixA}'"
check_str "LANDMINE:     both agree on the article's toy sets (1 2 3)" "$pubA" "$fixA"

# ─────────────────────────────────────────────────────────────────────────────
p '10. The other published commands that do not do what they say'

echo '--- Krumins, Union:  "$ set -um set1 set2"   (a typo for `sort -um`)'
( set -um data/A data/B; printf '    rc=0, printed nothing, and nounset is now: %s\n' \
    "$(shopt -o -q nounset && echo ON || echo off)" )
echo '    In bash, `set -u -m` is a SHELL BUILTIN: it enables nounset and assigns $1/$2.'

echo '--- Krumins, Symmetric Difference:  comm -3 <(sort -n A) >(sort -n B)'
echo -n '    running it with a 3s timeout ... '
if timeout 3 bash -c 'comm -3 <(sort -n data/A) >(sort -n data/B)' >/dev/null 2>&1
then echo 'returned'; else echo "HUNG (rc=$?).  >(...) is an OUTPUT process substitution."; fi

echo '--- Krumins, Maximum:  the prose says `tail -1`, the example runs `head -1`'
echo -n '    head -1 <(sort -n A) = '; head -1 <(sort -n data/A)
echo -n '    tail -1 <(sort -n A) = '; tail -1 <(sort -n data/A)

echo '--- Krumins, cheat sheet, Subset Test:  awk ... { if !($0 in a) exit 1 }'
awk 'NR==FNR { a[$0]; next } { if !($0 in a) exit 1 }' data/A data/Asub 2>&1 \
  | head -2 | sed 's/^/    /'
echo '    ^ awk requires parentheses:  if (!($0 in a))'

echo '--- Guest, intersection filter:  grep "^ *2"  on a MULTISET'
printf 'many\n%.0s' $(seq 20) > "$W/m"; printf 'twice\ntwice\nonce\n' >> "$W/m"
sort "$W/m" | uniq -c | grep "^ *2" | sed 's/^/    /'
echo '    ^ "many" has count 20, and "^ *2" matches the 2 in 20.  Use awk '"'"'$1==2'"'"'.'

echo '--- Guest, natural IP ordering:  sort -t. +0n -1n +1n -2n +2n -3n +3n'
if sort -t. +0n -1n +1n -2n +2n -3n +3n "$W/IP1" >/dev/null 2>&1
then echo '    GNU sort still accepts the obsolete +POS -POS keys.'
else echo '    rejected by this sort.'; fi
if ! command -v busybox >/dev/null 2>&1; then
    echo '    (no busybox here to contrast with; on Alpine it REJECTS them.)'
elif busybox sort -t. +0n -1n "$W/IP1" >/dev/null 2>&1; then
    echo '    busybox sort accepts them too.'
else
    echo '    busybox sort REJECTS them (invalid option -- 1). Use -k1,1n … or sort -V.'
fi

# ─────────────────────────────────────────────────────────────────────────────
p 'VERDICT'
echo "Three algorithm families — merge (comm), count (uniq), hash (awk) — plus an"
echo "SQL engine, over the same sets. Where they disagree, someone is wrong."
echo
if [ "$FAILED" -eq 0 ]; then
    echo "PASS: all $CHECKS set identities hold (merge == count == hash == SQL)"
    exit 0
fi
echo "FAIL: $FAILED of $CHECKS set identities disagreed (see [BAD] above)"
exit 1

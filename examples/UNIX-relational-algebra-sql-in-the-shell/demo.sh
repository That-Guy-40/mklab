#!/bin/bash
# demo.sh — relational algebra, three ways, and a proof they agree.
#
# Walks the six primitive operations of relational algebra using (a) Matt Might's
# hand-rolled bash scripts from "Relational shell programming", (b) the native
# coreutils that Jason Walsh's "SQL in the Shell" reaches for, and (c) real SQL
# via sqlite3 -- then checks all three produce the SAME relations.
#
# Ends on exactly one verdict line: PASS: / FAIL:  (exit 0 / 1)
#
# Requires bash (process substitution), GNU coreutils (join, comm), gawk, sqlite3.
set -u

cd "$(dirname "$0")" || exit 1
PATH="$PWD/bin:$PATH"; export PATH

# Relations are SETS: unordered, no duplicates. To compare two of them you must
# first canonicalize the order -- which is `sort`. And `sort`'s idea of order is
# locale-dependent, so glibc and musl would disagree unless we pin the collation.
# This one line is why every check below is byte-identical on Debian and Alpine.
# (It is also why `join` and `comm` demand sorted input: they stream-merge.)
export LC_ALL=C

TAB="$(printf '\t')"
W="$(mktemp -d)"
CHECKS=0
FAILED=0
# Belt-and-suspenders: never exit silently. Any early death still prints a verdict.
trap 'rc=$?; rm -rf "$W"; if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
        echo "FAIL: demo.sh exited early (rc=$rc)"; fi' EXIT

p() { printf '\n== %s ==\n' "$1"; }

# check <what> <fileA> <fileB> — assert two relations are equal, and say so.
check() {
    CHECKS=$((CHECKS + 1))
    if cmp -s "$2" "$3"; then
        printf '   [ok]  %s\n' "$1"
    else
        FAILED=$((FAILED + 1))
        printf '   [BAD] %s\n' "$1"
        diff -u "$2" "$3" | sed 's/^/          /'
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
p '0. Unix is a bestiary of ad hoc databases: each line is a tuple'
echo '--- data/passwd  (colon-separated relation, as /etc/passwd is)'
cat data/passwd
echo '--- data/employees.tsv  (tab-separated, with a header)'
cat data/employees.tsv

# ─────────────────────────────────────────────────────────────────────────────
p '1. UNION (∪) = cat   ... and `sort -u` for true SET semantics'
cat data/f1 data/f2 | tr '\n' ' '; echo
echo '--- a relation is a SET, so duplicates must go:  cat A A | sort -u'
cat data/f1 data/f1 | sort -u | tr '\n' ' '; echo

# ─────────────────────────────────────────────────────────────────────────────
p '2. SELECTION (σ) = awk / grep   — keep the rows a predicate accepts'
# Might runs this against a REAL /etc/passwd, not his 4-line simplified one (in
# which uid always equals gid, so the predicate selects nothing).
echo '--- Might: accounts whose uid != gid  (against a realistic /etc/passwd)'
awk -F ":" '{ if ( $3 != $4 ) print }' data/etc-passwd
echo '--- Walsh: employees earning over 90000 (NR==1 keeps the header)'
awk -F'\t' 'NR==1 || $4 > 90000' data/employees.tsv
echo "--- Walsh, as published:  grep -E '^(id|.*\\tengineering)' departments.tsv"
# Fold stderr in: GNU grep >= 3.12 WARNS about the stray backslash, 3.11 is silent,
# and BusyBox grep matches the tab outright. Three behaviours, one command.
walsh_grep="$(grep -E '^(id|.*\tengineering)' data/departments.tsv 2>&1)" || true
if [ -n "$walsh_grep" ]; then printf '%s\n' "$walsh_grep" | sed 's/^/      /'
else echo '      (nothing — rc=1)'; fi
echo '    ^ ERRATUM. Two independent bugs, so on GNU grep it prints NOTHING:'
echo '        (a) the header row is "dept_id", so ^id never matches it; and'
echo '        (b) POSIX ERE has no \t escape. GNU grep reads it as a literal "t",'
echo '            so ".*\tengineering" hunts for "...tengineering".'
echo '      Your grep decides: GNU 3.11 silently matches "t"; GNU 3.12 warns'
echo '      "stray \ before t"; BusyBox grep and ugrep DO treat \t as a tab.'
echo '      An empty result never says which of those just happened to you.'
echo '    Working spelling, portable — the POSIX [[:blank:]] class:'
grep -E '^(dept_id|.*[[:blank:]]engineering)' data/departments.tsv

# ─────────────────────────────────────────────────────────────────────────────
p '3. PROJECTION (π) = cut   — keep columns, discard the rest'
echo '--- Might: cut -d ":" -f 1,7   (name and shell)'
cut -d ":" -f 1,7 data/etc-passwd
echo '--- cut cannot REORDER columns; awk can:  awk -F":" "{ print \$7 \":\" \$1 }"'
awk -F":" '{ print $7 ":" $1 }' data/passwd

# ─────────────────────────────────────────────────────────────────────────────
p '4. RENAME (ρ) = nothing to do   — Unix columns are named positionally'
echo 'There are no headers to rename, so ρ has no Unix equivalent. awk reorders;'
echo 'the "name" of a column is just its index. (Walsh: awk {print "new", $2}.)'

# ─────────────────────────────────────────────────────────────────────────────
p '5. CARTESIAN PRODUCT (×) = the one primitive Unix never shipped'
echo '--- `paste -d "," f1 f2` joins CORRESPONDING lines — NOT a product:'
paste -d "," data/f1 data/f2
echo '--- `cartesian f1 f2` is the real 3x3 product (Might, verbatim):'
cartesian data/f1 data/f2 | tr '\n' ' '; echo
echo '--- ERRATUM: `cartesian -t` is broken under its own #!/bin/bash shebang —'
echo "    bash's echo does not expand \\t, so the delimiter is a literal backslash-t:"
cartesian -t data/f1 data/f2 | head -1 | cat -A
echo '    the working spelling passes a real tab:  -d "$(printf '"'"'\t'"'"')"'
cartesian -d "$(printf '\t')" data/f1 data/f2 | head -1 | cat -A

# ─────────────────────────────────────────────────────────────────────────────
p '6. DIFFERENCE (−): Might`s O(n*m) script  vs  comm -23 (linear, sorted)'
# The two rows we want to remove. (Section 10 derives this file *relationally*.)
grep -E '^(matt|bob):' data/passwd > "$W/kill.db"
echo '--- difference data/passwd kill.db   (rescans kill.db per line: quadratic)'
difference data/passwd "$W/kill.db" | tee "$W/diff_might"
echo '--- comm -23 <(sort passwd) <(sort kill.db)   (stream-merge: linear)'
comm -23 <(sort data/passwd) <(sort "$W/kill.db") | tee "$W/diff_comm"
echo '--- `diff` is NOT set difference: it reports an edit script, not a relation.'
sort "$W/diff_might" > "$W/dm.s"; sort "$W/diff_comm" > "$W/dc.s"
check "DIFFERENCE: Might's difference(3)  ==  comm -23" "$W/dm.s" "$W/dc.s"

# ─────────────────────────────────────────────────────────────────────────────
p '7. INTERSECTION (∩) = comm -12   — derived, not primitive:  A ∩ B = A − (A − B)'
comm -12 <(sort data/passwd) <(sort "$W/kill.db")

# ─────────────────────────────────────────────────────────────────────────────
p '8. EQUIJOIN (⋈): product + selection   —   Might`s equijoin  vs  join(1)'
tail -n +2 data/employees.tsv   | sort -t"$TAB" -k3,3 > "$W/emp"    # sort ON the join key
tail -n +2 data/departments.tsv | sort -t"$TAB" -k1,1 > "$W/dept"
echo '--- Might: equijoin emp dept 3 1   (builds the whole product, then selects)'
equijoin -d "$TAB" "$W/emp" "$W/dept" 3 1 | cut -f2,6 | sort > "$W/join_might"
cat "$W/join_might"
echo '--- native: join -t$TAB -1 3 -2 1   (streams two sorted inputs)'
join -t"$TAB" -1 3 -2 1 "$W/emp" "$W/dept" | cut -f3,5 | sort > "$W/join_native"
cat "$W/join_native"
echo '--- ERRATUM (Walsh): under the heading "SELECT e.name, d.dept_name" he pipes'
echo '    join to `cut -f2,4`. join emits  dept_id,id,name,salary,dept_name,location'
echo '    so -f2,4 projects id+salary. The stated SQL needs -f3,5. As published:'
join -t"$TAB" -1 3 -2 1 "$W/emp" "$W/dept" | cut -f2,4 | sort | sed 's/^/      /'
check "EQUIJOIN: Might's equijoin(3)  ==  join(1)" "$W/join_might" "$W/join_native"

# ─────────────────────────────────────────────────────────────────────────────
p '9. AGGREGATION (GROUP BY) — NOT relational algebra, but what you always want'
echo '--- headcount per dept:  cut -f3 | sort | uniq -c'
cut -f3 data/employees.tsv | tail -n +2 | sort | uniq -c
echo '--- count + mean salary per dept, via awk associative arrays'
awk -F'\t' '{ c[$3]++; s[$3] += $4 }
            END { for (d in c) printf "%s\t%d\t%.0f\n", d, c[d], s[d]/c[d] }' "$W/emp" \
    | sort > "$W/agg_shell"
cat "$W/agg_shell"

# ─────────────────────────────────────────────────────────────────────────────
p "10. Might's worked example: delete a list of bad users, relationally"
echo '--- bad.db:'; tr '\n' ' ' < data/bad.db; echo
echo '--- 1) product:  cartesian -d ":" bad.db passwd'
cartesian -d ":" data/bad.db data/passwd > "$W/badpasswd.db"
sed -n '1,3p' "$W/badpasswd.db"; echo '    ... (8 rows = 2 x 4)'
echo '--- 2) select:   awk -F: "{ if ( \$1 == \$2 ) print }"'
awk -F: '{ if ( $1 == $2 ) print }' "$W/badpasswd.db" > "$W/offenders.db"
cat "$W/offenders.db"
echo '--- 3) project:  cut -d ":" -f2-'
cut -d ":" -f2- "$W/offenders.db" > "$W/kill2.db"
cat "$W/kill2.db"
echo '--- 4) difference passwd kill.db  ->  the new password file:'
difference data/passwd "$W/kill2.db" > "$W/final"
cat "$W/final"
# The article publishes this exact output. Hold the code to it.
cat > "$W/expected" <<'EOF'
root:*:0:0:The Admin:/root:/bin/sh
john:*:501:501:John:/home/john:/bin/bash
EOF
check "WORKED EXAMPLE: output == the article's published output" "$W/final" "$W/expected"

# ─────────────────────────────────────────────────────────────────────────────
p '11. The SQL oracle: sqlite3 must agree with the pipelines'
DB="$W/lab.db"
sqlite3 "$DB" <<'SQL'
CREATE TABLE employees  (id INTEGER, name TEXT, dept_id INTEGER, salary INTEGER);
CREATE TABLE departments(dept_id INTEGER, dept_name TEXT, location TEXT);
SQL
sqlite3 "$DB" <<SQL
.mode tabs
.import --skip 1 data/employees.tsv employees
.import --skip 1 data/departments.tsv departments
SQL
sq() { sqlite3 -batch -noheader -separator "$TAB" "$DB" "$1"; }

echo '--- σ  WHERE salary > 90000'
awk -F'\t' '$4 > 90000 { print $2 "\t" $4 }' "$W/emp" | sort > "$W/sel_shell"
sq 'SELECT name, salary FROM employees WHERE salary > 90000 ORDER BY name;' > "$W/sel_sql"
cat "$W/sel_shell"
check "SELECTION:   awk  ==  SQL WHERE" "$W/sel_shell" "$W/sel_sql"

echo '--- ⋈ + π  JOIN ... ON e.dept_id = d.dept_id, project (name, dept_name)'
sq 'SELECT e.name, d.dept_name FROM employees e
    JOIN departments d ON e.dept_id = d.dept_id ORDER BY e.name;' > "$W/join_sql"
check "JOIN+PROJ:   join(1) | cut -f3,5  ==  SQL JOIN" "$W/join_native" "$W/join_sql"

echo '--- GROUP BY dept_id: COUNT(*), AVG(salary)'
sq 'SELECT dept_id, COUNT(*), CAST(ROUND(AVG(salary)) AS INTEGER)
    FROM employees GROUP BY dept_id ORDER BY dept_id;' > "$W/agg_sql"
check "AGGREGATION: awk arrays  ==  SQL GROUP BY" "$W/agg_shell" "$W/agg_sql"

# ─────────────────────────────────────────────────────────────────────────────
p '12. The corrected scripts: bin/fixed/ — same algebra, without the papercuts'
echo "bin/       = the article's code, verbatim (the object of study)"
echo "bin/fixed/ = drop-in corrected versions.   diff -u bin/x bin/fixed/x"
echo
echo '--- the QUIET failure: the original `equijoin -t` on TSV finds ZERO rows,'
echo '    because its delimiter is a literal backslash-t that matches nothing:'
printf '    original -> %s row(s)\n' "$(equijoin -t "$W/emp" "$W/dept" 3 1 | wc -l)"
printf '    fixed    -> %s row(s)\n' "$(bin/fixed/equijoin -t "$W/emp" "$W/dept" 3 1 | wc -l)"
echo '    An empty result reads as "nothing matched", not as "your delimiter is wrong".'

echo '--- `cartesian -t` now emits a real tab (first row, cat -A):'
bin/fixed/cartesian -t data/f1 data/f2 | head -1 | cat -A
bin/fixed/cartesian -t   data/f1 data/f2 | sort > "$W/cart_t"
bin/fixed/cartesian -d "$TAB" data/f1 data/f2 | sort > "$W/cart_d"
check "FIXED cartesian: -t  ==  -d \$'\\t'" "$W/cart_t" "$W/cart_d"

bin/fixed/difference data/passwd "$W/kill.db" | sort > "$W/diff_fixed"
check "FIXED difference: == the verbatim original" "$W/diff_fixed" "$W/dm.s"

bin/fixed/equijoin -t "$W/emp" "$W/dept" 3 1 | cut -f2,6 | sort > "$W/join_fixed"
check "FIXED equijoin -t: == join(1)" "$W/join_fixed" "$W/join_native"

# ─────────────────────────────────────────────────────────────────────────────
p 'VERDICT'
echo "Four independent implementations of the same algebra — a 2010 bash script,"
echo "its corrected twin, coreutils, and an SQL engine — over the same relations."
echo
if [ "$FAILED" -eq 0 ]; then
    echo "PASS: all $CHECKS relational identities hold (Might's scripts == coreutils == SQL)"
    exit 0
fi
echo "FAIL: $FAILED of $CHECKS relational identities disagreed (see [BAD] above)"
exit 1

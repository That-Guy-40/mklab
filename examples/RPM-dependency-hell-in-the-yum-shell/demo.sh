#!/bin/bash
# demo.sh — dependency hell, entered and escaped three ways, with a proof that
# no bystander was harmed.
#
# Walks Sigurd Urdahl's "yum shell - bat out of dependency hell" on Rocky Linux:
# (1) reproduce his conflict, (2) reproduce the naive `remove` that would take
# six innocent packages with it, then escape down three roads — (a) his 2018
# `yum shell` remove+install+run, verbatim; (b) `dnf swap`, the modern spelling;
# (c) `dnf install --allowerasing`, the hint EL9 now prints inside the very
# error message — and assert that each road is ONE transaction that touches
# ONLY the two library packages, and that all three roads agree.
#
# Ends on exactly one verdict line: PASS: / FAIL:  (exit 0 / 1)
#
# Run inside the lab box, as root or as the sudo-capable `learner`.
# Requires: the bat-hell repo (bin/build-bat-hell-repo.sh, installed by
# setup-workshop.sh) and dnf 4 (Rocky 8/9; `yum` is the dnf-3 compat CLI).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
export LC_ALL=C          # dnf table layout and sort order, pinned

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"
run() { $SUDO "$@"; }    # every state-changing package command goes through here

W="$(mktemp -d)"
CHECKS=0
FAILED=0
trap 'rc=$?; rm -rf "$W"; if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
        echo "FAIL: demo.sh exited early (rc=$rc)"; fi' EXIT

p() { printf '\n== %s ==\n' "$1"; }

# check_str <what> <got> <want>
check_str() {
    CHECKS=$((CHECKS + 1))
    if [ "$2" = "$3" ]; then printf '   [ok]  %s\n' "$1"
    else FAILED=$((FAILED + 1)); printf '   [BAD] %s  (got "%s", want "%s")\n' "$1" "$2" "$3"; fi
}
# check_has <what> <file> <regex>  — the transcript must say so
check_has() {
    CHECKS=$((CHECKS + 1))
    if grep -Eq -e "$3" "$2"; then printf '   [ok]  %s\n' "$1"
    else FAILED=$((FAILED + 1)); printf '   [BAD] %s  (pattern "%s" not found in output)\n' "$1" "$3"; fi
}

BYSTANDERS=(meatloaf-mta python-bat perl-DBD-bat hellban hellban-sendmail hell-lsb-core)

# installed_ok pkg... -> yes/no (all installed)
installed_ok() { rpm -q "$@" >/dev/null 2>&1 && echo yes || echo no; }
# bat_state -> the full lab-package inventory, one line per package, sorted
bat_state() {
    local p
    for p in bat-client-57 bat-shared-57 bat-shared-compat-57 bat-shared-56 \
             "${BYSTANDERS[@]}"; do
        if rpm -q "$p" >/dev/null 2>&1; then rpm -q --qf '%{NAME}-%{VERSION}\n' "$p"
        else echo "$p: absent"; fi
    done | sort
}
# last_txn_lines <re> -> how many "Packages Altered" lines of the LAST dnf
# transaction match <re>. The history db is ground truth for "one transaction".
last_txn() { run dnf history info last 2>/dev/null; }

# ─────────────────────────────────────────────────────────────────────────────
p '0. the box: Rocky Linux, where `yum` never went away — it IS dnf'
cat /etc/rocky-release
yum_target="$(readlink -f /usr/bin/yum || true)"
echo "    /usr/bin/yum -> $yum_target"
check_str "yum on this box is the dnf compat CLI (article commands run verbatim)" \
    "$(basename "$yum_target")" "dnf-3"

echo '    --- restoring the article'"'"'s opening state (bin/reset-hell.sh) ---'
"$HERE/bin/reset-hell.sh" | sed 's/^/    /'
check_str "production baseline: bat-shared-56 + all 6 bystanders installed" \
    "$(installed_ok bat-shared-56 "${BYSTANDERS[@]}")" "yes"

# ─────────────────────────────────────────────────────────────────────────────
p '1. THE HELL  —  `yum install bat-client-57` (his opening error, our packages)'
run yum install -y bat-client-57 > "$W/hell" 2>&1
rc=$?
sed -n '/Problem:/,$p' "$W/hell" | sed 's/^/    /'
check_str "the install is refused (exit status)" "$rc" "1"
check_has "the refusal names the crux: compat-57 conflicts with bat-shared-56" \
    "$W/hell" 'bat-shared-compat-57.*conflicts with bat-shared-56'
# 2018's EL7 yum suggested --skip-broken here, which does not help. EL9's dnf
# prints the actual way out inside the error itself. Progress, measured.
check_has "2018 got '--skip-broken' advice; EL9 already hints at --allowerasing" \
    "$W/hell" '\-\-allowerasing'

# ─────────────────────────────────────────────────────────────────────────────
p '2. THE TRAP  —  "OK, so I will just remove it":  yum remove bat-shared-56'
run yum remove --assumeno bat-shared-56 > "$W/trap" 2>&1
rc=$?
sed -n '/^Removing:/,/^Transaction Summary/p' "$W/trap" | grep -v '^ *$' | sed 's/^/    /'
grep -E '^Remove +[0-9]+ Packages' "$W/trap" | sed 's/^/    /'
deps=0
for b in "${BYSTANDERS[@]}"; do
    grep -Eq "^ $b\b" "$W/trap" && deps=$((deps + 1))
done
check_str "the cascade would take all 6 innocent bystanders (\"Very much not OK\")" \
    "$deps" "6"
check_has "transaction summary: Remove 7 Packages — for a 1-package problem" \
    "$W/trap" '^Remove +7 Packages'
check_str "--assumeno said N for us: rc=$rc and nothing was actually removed" \
    "$rc/$(installed_ok bat-shared-56 "${BYSTANDERS[@]}")" "1/yes"

# ─────────────────────────────────────────────────────────────────────────────
p '3. THE ESCAPE  —  his fix, verbatim: remove + install as ONE transaction'
# "Did you notice the use of the word transaction in Transaction Summary from
#  yum? A transaction is actually what I want." — the article's turn. In the
# interactive shell you type these at the `>` prompt; a file scripts it.
cat > "$W/swap.dnfshell" <<'EOF'
remove bat-shared-56
install bat-shared-compat-57
run
exit
EOF
sed 's/^/    > /' "$W/swap.dnfshell"
run yum shell -y "$W/swap.dnfshell" > "$W/shell" 2>&1
rc=$?
sed -n '/^Installing:/,/^Transaction Summary/p' "$W/shell" | grep -v '^ *$' | sed 's/^/    /'
check_str "yum shell ran the swap (exit status)" "$rc" "0"
check_str "the swap took: bat-shared-56 out, bat-shared-compat-57 in" \
    "$(installed_ok bat-shared-56)/$(installed_ok bat-shared-compat-57)" "no/yes"
check_str "all 6 bystanders survived — the entire point of the article" \
    "$(installed_ok "${BYSTANDERS[@]}")" "yes"
last_txn > "$W/txn1"
grep -E '    (Install|Removed) ' "$W/txn1" | sed 's/^/    history: /'
check_str "dnf history agrees: ONE transaction holds both the Install and the Removed" \
    "$(grep -Ec '    (Install bat-shared-compat-57|Removed bat-shared-56)' "$W/txn1")" "2"

# ─────────────────────────────────────────────────────────────────────────────
p '4. THE FINALE  —  "And then finally": the original install now just works'
run yum install -y bat-client-57 > "$W/finale" 2>&1
rc=$?
grep -E '^(Install +[0-9]|Complete!)' "$W/finale" | sed 's/^/    /'
check_str "yum install bat-client-57 succeeds (exit status)" "$rc" "0"
check_str "his 'Install 1 Package (+1 Dependent package)': client + shared-57" \
    "$(installed_ok bat-client-57 bat-shared-57)" "yes"
last_txn > "$W/txn2"
check_str "and it altered exactly those two packages, nothing else" \
    "$(grep -Ec '    Install bat-(client|shared)-57' "$W/txn2")-of-$(grep -Ec '    (Install|Removed|Upgrade|Erase) ' "$W/txn2")" "2-of-2"
bat_state > "$W/state-road1"

# ─────────────────────────────────────────────────────────────────────────────
p '5. ROAD 2  —  what 2018 taught became a verb: dnf swap'
"$HERE/bin/reset-hell.sh" | sed 's/^/    /'
check_str "hell restored for road 2 (bystanders back, 5.7 stack gone)" \
    "$(installed_ok bat-shared-56 "${BYSTANDERS[@]}")/$(installed_ok bat-shared-compat-57)" "yes/no"
run dnf swap -y bat-shared-56 bat-shared-compat-57 > "$W/swap2" 2>&1
rc=$?
last_txn > "$W/txn3"
grep -E '    (Install|Removed) ' "$W/txn3" | sed 's/^/    history: /'
check_str "dnf swap does the same exchange in one line (exit status)" "$rc" "0"
check_str "same shape: one transaction, Install + Removed, 6 survivors" \
    "$(grep -Ec '    (Install bat-shared-compat-57|Removed bat-shared-56)' "$W/txn3")/$(installed_ok "${BYSTANDERS[@]}")" "2/yes"

# ─────────────────────────────────────────────────────────────────────────────
p '6. ROAD 3  —  the hint from section 1: dnf install --allowerasing'
"$HERE/bin/reset-hell.sh" | sed 's/^/    /'
check_str "hell restored for road 3" \
    "$(installed_ok bat-shared-56 "${BYSTANDERS[@]}")/$(installed_ok bat-shared-compat-57)" "yes/no"
# One command, no shell, no swap: let the depsolver choose what to erase.
# The check that matters: it erased ONLY the package we would have chosen.
run dnf install -y --allowerasing bat-client-57 > "$W/ae" 2>&1
rc=$?
sed -n '/^Installing:/,/^Transaction Summary/p' "$W/ae" | grep -v '^ *$' | sed 's/^/    /'
check_str "the original install succeeds in ONE command (exit status)" "$rc" "0"
last_txn > "$W/txn4"
check_str "the depsolver erased exactly one package, and it is bat-shared-56" \
    "$(grep -Ec '    (Removed|Erase) ' "$W/txn4")/$(grep -Ec '    (Removed|Erase) bat-shared-56' "$W/txn4")" "1/1"
check_str "full 5.7 stack in, all 6 bystanders still standing" \
    "$(installed_ok bat-client-57 bat-shared-57 bat-shared-compat-57 "${BYSTANDERS[@]}")" "yes"
bat_state > "$W/state-road3"

# ─────────────────────────────────────────────────────────────────────────────
p '7. THE ROADS AGREE  —  three escapes, byte-identical end state'
CHECKS=$((CHECKS + 1))
if cmp -s "$W/state-road1" "$W/state-road3"; then
    sed 's/^/    /' "$W/state-road1"
    printf '   [ok]  %s\n' "yum shell + install  ==  dnf install --allowerasing (package for package)"
else
    FAILED=$((FAILED + 1))
    printf '   [BAD] %s\n' "REGRESSION: the three roads no longer converge on the same installed set"
    diff "$W/state-road1" "$W/state-road3" | sed 's/^/          /'
fi

# ─────────────────────────────────────────────────────────────────────────────
echo
if [ "$FAILED" -eq 0 ]; then
    echo "PASS: all $CHECKS checks hold (yum shell == dnf swap == --allowerasing; 6 bystanders, 0 harmed)"
    exit 0
else
    echo "FAIL: $FAILED of $CHECKS checks failed"
    exit 1
fi

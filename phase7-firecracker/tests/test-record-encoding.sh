#!/usr/bin/env bash
# REGRESSION (REVIEW-phase7.md P7-6, plus the two §3 reader items).
#
# P7-6 — a spec is flattened to `k=v;k=v;…` and split back apart on ';', so a ';' inside a
# VALUE is not a quoting nuisance, it is a second key. Measured on the real driver:
#
#     append = "quiet;mmds=true"      -> MMDS switched on. The operator never wrote it.
#     append = "quiet;name=HIJACKED"  -> the instance name changed.
#
# The `KNOWN_KEYS` gate could not see either, because they are not keys in the FILE — it
# validates what the parser reads, and this arrives after. So the parser whose stated
# purpose is *"refuses anything it does not understand rather than ignoring it"* could be
# handed keys it never looked at, through any value, from either entry point.
#
# §3a — the provenance table joined its three columns with '|' and split them with '|', so
# `append = "mc_name=a|b"` — an ordinary boot arg, and micro-cloud's actual spelling —
# rendered as field `boot_args: mc_name=a`, why `b|your append…`. The table whose entire
# job is to report what the tool did to your value misreported the value.
#
# §3b — an inline comment is legal TOML and landed inside the value: `name = "t1"  # api`
# was read as the name `t1"   # api`, so the tool refused a valid spec and complained about
# the NAME. Fail-closed for `name` (the regex catches it) and silent for `append`.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")   # NOT a second EXIT trap — see lib.sh
export LAB_STATE_DIR="$tmp/state"
# Sections 4 and the control below need a spec that passes EVERY gate, because the
# provenance table and the generated config only exist for one that does.
fc_fixtures

spec() {  # spec <file> <extra lines…>
    {   printf '[[microvm]]\nname = "t1"\n'
        printf 'kernel = "/nonexistent/vmlinux"\nrootfs = "/nonexistent/rootfs.ext4"\n'
        local l; for l in "$@"; do printf '%s\n' "$l"; done
    } > "$1"
}

# ── 1. P7-6: a ';' in a value cannot become a key ─────────────────────────────────────
# `name` is placed AFTER the injecting key on purpose. `field` takes the FIRST match, so
# with `append` first the injected name wins — the old behaviour was order-dependent,
# which is worse than uniformly wrong.
{   printf '[[microvm]]\n'
    printf 'append = "quiet;name=HIJACKED"\n'
    printf 'name = "t1"\nkernel = "/nonexistent/vmlinux"\nrootfs = "/nonexistent/rootfs.ext4"\n'
} > "$tmp/hijack.toml"
run_fc "$tmp/h.out" preflight --config "$tmp/hijack.toml" && rc=0 || rc=$?
(( rc != 0 )) || fail "REGRESSION: a value containing ';' was accepted (P7-6)"
# ORDER MATTERS HERE. The sharpest assertion goes first, because with the guard removed the
# run DOES exit non-zero — the injected name fails the name regex — so a message-shaped
# assertion placed first reports "refused but not explained" about a run whose real defect
# is that the injection worked and the tool then blamed the operator's name.
grep -qE '^  (ok|FAIL) +name' "$tmp/h.out" \
    && fail "REGRESSION: the name gate RAN — the ';' became a second key and the tool is now reporting on a name the spec never contained: $(grep -E '^  (ok|FAIL) +name' "$tmp/h.out") (P7-6)"
grep -qE '^  (ok|FAIL|UNKNOWN) ' "$tmp/h.out" \
    && fail "REGRESSION: gates ran after the record-separator refusal — a refusal that refuses nothing"
grep -qi 'record separator' "$tmp/h.out" \
    || fail "the ';' was refused but not explained; the operator cannot tell this from a typo. Got: $(cat "$tmp/h.out")"
note "P7-6: a ';' in a value is refused by name, before any gate runs"

# The other injectable key, to show it is the separator and not the word 'name'.
spec "$tmp/mmds.toml" 'append = "quiet;mmds=true"'
run_fc "$tmp/m.out" preflight --config "$tmp/mmds.toml" && rc=0 || rc=$?
(( rc != 0 )) || fail "REGRESSION: 'append = \"quiet;mmds=true\"' was accepted — it switches on a device the operator never asked for (P7-6)"
note "P7-6: ...and the same for a value that would have switched MMDS on"

# ── 2. P7-6 at the OTHER entry point ─────────────────────────────────────────────────
# `main` builds its own record from argv. A guard applied only in the awk parser leaves
# this open, and this is the path micro-cloud actually uses.
run_fc "$tmp/cli.out" preflight --name t1 --kernel /nonexistent/vmlinux \
    --rootfs /nonexistent/rootfs.ext4 --append 'quiet;mmds=true' && rc=0 || rc=$?
(( rc != 0 )) || fail "REGRESSION: --append smuggled a second key past the record encoding — the guard is on the config path only (P7-6)"
grep -qi 'record separator' "$tmp/cli.out" || fail "the CLI refusal did not name the reason; got: $(cat "$tmp/cli.out")"
note "P7-6: the CLI path refuses it too, with the same message"

# ── 3. CONTROL: ordinary values with punctuation are NOT refused ─────────────────────
# A guard that rejected anything unusual would pass every assertion above. Kernel command
# lines are full of '=', ',', ':', '/', '.', and '|' is legal in one.
ORD='mc_name=t1 console=ttyS0,115200n8 foo=a:b/c.d|e'
run_fc "$tmp/ok.out" create --dry-run --name t1 --kernel "$FC_K" --rootfs "$FC_R" --append "$ORD" \
    || { cat "$tmp/ok.out" >&2; fail "control: an ordinary boot-arg string was refused — the separator guard is over-firing"; }
grep -q "boot_args\": \".*${ORD}\"" "$tmp/ok.out" \
    || fail "control: the ordinary append did not reach boot_args intact; the config said: $(grep boot_args "$tmp/ok.out")"
note "control: an ordinary kernel command line (with = , : / . and |) passes through untouched"

# ── 4. §3a: the provenance table reports the value it is reporting on ─────────────────
PIPEVAL='mc_name=t1|second'
run_fc "$tmp/prov.out" create --dry-run --name t1 --kernel "$FC_K" --rootfs "$FC_R" --append "$PIPEVAL" \
    || { cat "$tmp/prov.out" >&2; fail "create --dry-run refused a spec whose append contains a '|'"; }
row="$(grep -E '^  YOURS +boot_args: ' "$tmp/prov.out" | head -1)"
[[ -n "$row" ]] || fail "no YOURS row for the append at all; provenance table was: $(sed -n '/WHERE FROM/,$p' "$tmp/prov.out")"
[[ "$row" == *"$PIPEVAL"* ]] \
    || fail "REGRESSION: the provenance table split the value on '|' — it reports [$row] for an append of [$PIPEVAL] (§3a)"
[[ "$row" == *"your append, passed through verbatim"* ]] \
    || fail "REGRESSION: the WHY column lost its text to the value's '|' — got [$row] (§3a)"
note "§3a: a '|' in a value no longer splits the provenance table's columns"

# ── 5. §3b: an inline comment is a comment ───────────────────────────────────────────
{   printf '[[microvm]]\n'
    printf 'name = "t1"   # the api node\n'
    printf 'kernel = "/nonexistent/vmlinux"  # built by slice 1\n'
    printf 'rootfs = "/nonexistent/rootfs.ext4"\n'
    printf 'memory = 512M   # enough for the workload\n'
} > "$tmp/cmt.toml"
run_fc "$tmp/c.out" preflight --config "$tmp/cmt.toml" || true
grep -qE "^  ok +name 't1' is a usable instance name\$" "$tmp/c.out" \
    || fail "REGRESSION: an inline TOML comment landed inside the value — the tool refused a valid spec and blamed the name (§3b). Gate said: $(grep -E '^  (ok|FAIL) +name' "$tmp/c.out")"
grep -qE "^  ok +memory 512 MiB\$" "$tmp/c.out" \
    || fail "REGRESSION: an inline comment after an UNQUOTED value corrupted it; the memory gate said: $(grep -E '^  (ok|FAIL) +memory' "$tmp/c.out")"
grep -q 'built by slice 1' "$tmp/c.out" \
    && fail "REGRESSION: an inline comment is still part of the kernel path (§3b)"
note "§3b: inline comments after quoted and unquoted values are comments"

# ...and a '#' INSIDE a quoted value is data, not a comment. The naive fix (strip from the
# first '#') breaks this, which is why the parser tracks the quote.
{   printf '[[microvm]]\nname = "t1"\n'
    printf 'kernel = "%s"\nrootfs = "%s"\n' "$FC_K" "$FC_R"
    printf 'append = "tag=#1 build"   # and a real comment after it\n'
} > "$tmp/hash.toml"
run_fc "$tmp/hh.out" create --dry-run --config "$tmp/hash.toml" \
    || { cat "$tmp/hh.out" >&2; fail "control: create refused a spec whose append contains a '#'"; }
grep -q 'tag=#1 build' "$tmp/hh.out" \
    || fail "control: a '#' inside a QUOTED value was stripped as a comment — the comment fix over-fires (§3b). boot_args: $(grep boot_args "$tmp/hh.out")"
grep -q 'and a real comment after it' "$tmp/hh.out" \
    && fail "control: the comment AFTER the closing quote was kept as part of the value (§3b)"
note "control: a '#' inside a quoted value survives, and the comment after the closing quote does not"

pass "the record encoding cannot be used to smuggle a key from either entry point, the provenance table survives a '|', and inline comments are comments (P7-6, §3)"

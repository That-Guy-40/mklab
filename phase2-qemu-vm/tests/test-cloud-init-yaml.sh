#!/usr/bin/env bash
# The generated cloud-config must PARSE the way cloud-init will read it.
#
# WHY THIS EXISTS. `runcmd` entries were written as BARE YAML scalars:
#
#     runcmd:
#       - sh -c 'echo "addr: $(ip -4 -o addr show)" > /dev/console'
#
# A bare entry is a PLAIN scalar, and in a plain scalar `: ` is the key/value separator. So
# that line parses as a MAPPING, not a string. cc_runcmd receives a dict where it wants a
# command, the module fails, cloud-config.service fails, and NOT ONE runcmd runs.
#
# Measured 2026-08-06 on a Debian 12 / cloud-init 22.4.2 guest: the VM booted perfectly to a
# login prompt in 3.5s and silently executed none of the five commands it had been given.
# From the caller's side there is no error — just a machine that ignored its own config. A
# colon-space is utterly ordinary in shell (`echo "x: $y"`, `sed 's/a: b/'`, `awk -F': '`),
# so the trap was laid for the common case.
#
# `chpasswd: {list: |...}` had the same flavour of problem: deprecated since cloud-init 22.3,
# it makes the WHOLE document schema-invalid ("Use of a multiline string for this field is
# DEPRECATED and will result in an error in a future version").
#
# WHAT THIS ASSERTS, AND WHY IT IS NOT A GREP. It parses the generated user-data with a real
# YAML parser and checks the TYPES cloud-init will actually see. Grepping for `- sh -c` would
# have passed happily on the broken output — the bytes looked perfect; only the parse was
# wrong. Assert the outcome (what the config MEANS), not the mechanism (what it looks like).
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq

python3 -c 'import yaml' 2>/dev/null || skip "python3 yaml module not available — cannot parse the generated cloud-config"

tmp="$(mktemp -d)"
_verdict_printed=0
fail() { _verdict_printed=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
skip() { _verdict_printed=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
_on_exit() {
    local rc=$?
    rm -rf "$tmp"
    if (( rc != 0 && rc != 77 )) && (( _verdict_printed == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

export LAB_STATE_DIR="$tmp/state" LAB_CACHE_DIR="$tmp/cache"

# Call the SEED WRITER directly rather than driving `create`. Two reasons, both practical:
# `create` needs an ISO maker and a backend-specific path (the kernel+initrd seed does not
# carry runcmd at all), and the thing under test is the emitter, not the plumbing around it.
# make_seed_iso writes user-data and then packs it, so intercepting the file it packs tests
# exactly the bytes cloud-init will read.
#
# $LAB_VM is a dynamic source path; the seed writer is invoked through the sourced file.
# shellcheck disable=SC1090
source "$LAB_VM"

# The runcmd shapes that broke it: a colon-space, nested quotes with a backslash, a bare
# colon, and one plain command as the control.
# A QUOTED heredoc: nothing here is expanded or unescaped by bash, so the JSON reaches jq
# exactly as written. (The first attempt wrapped this in single quotes and tried to escape
# the inner ones — which bash cannot do inside a single-quoted string at all.)
RUNCMD_JSON="$(cat <<'JSON'
[
  "sh -c 'echo PLAIN > /dev/console'",
  "sh -c 'echo \"  addr  : $(hostname)\" > /dev/console'",
  "sh -c 'awk -F\": \" \"{print \\$2}\" /etc/os-release > /dev/console'",
  "sh -c 'echo done: yes > /dev/console'"
]
JSON
)"
jq -e . >/dev/null 2>&1 <<<"$RUNCMD_JSON" || fail "the test's own runcmd fixture is not valid JSON"

ud="$tmp/user-data"
# make_seed_iso builds user-data in its own scratch dir and packs it; run it and keep the
# packed copy. If no ISO maker exists we cannot get the file back, which is an environment
# gap rather than a defect — say so.
seed="$tmp/seed.iso"
if ! make_seed_iso yamlcheck "$seed" "" debian '[]' "$RUNCMD_JSON" >"$tmp/seed.log" 2>&1; then
    grep -qi 'iso' "$tmp/seed.log" && skip "no ISO maker on this host — cannot pack a seed to inspect ($(head -1 "$tmp/seed.log"))"
    cat "$tmp/seed.log" >&2
    fail "make_seed_iso failed — see above"
fi
[[ -r "$seed" ]] || fail "make_seed_iso reported success but wrote no $seed"

if command -v xorriso >/dev/null 2>&1; then
    xorriso -osirrox on -indev "$seed" -extract /user-data "$ud" >/dev/null 2>&1 || true
fi
if [[ ! -s "$ud" ]] && command -v 7z >/dev/null 2>&1; then
    7z x -so "$seed" user-data > "$ud" 2>/dev/null || true
fi
[[ -s "$ud" ]] || skip "cannot extract user-data from the seed ISO on this host (need xorriso or 7z)"

# ── the parse, and the types cloud-init will see ────────────────────────────
out="$(python3 - "$ud" <<'PY'
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1]).read())
except Exception as e:
    print("PARSE_ERROR", type(e).__name__); sys.exit(0)
rc = d.get("runcmd")
if not isinstance(rc, list):
    print("RUNCMD_NOT_A_LIST", type(rc).__name__); sys.exit(0)
bad = [(i, type(e).__name__) for i, e in enumerate(rc) if not isinstance(e, str)]
if bad:
    print("NON_STRING_ENTRIES", ";".join(f"{i}:{t}" for i, t in bad)); sys.exit(0)
cp = d.get("chpasswd") or {}
print("OK", len(rc), "chpasswd_list" if "list" in cp else "chpasswd_users")
PY
)" || fail "the YAML check itself failed to run"

case "$out" in
    PARSE_ERROR*)
        fail "REGRESSION: the generated cloud-config is not valid YAML ($out) — cloud-init would refuse the whole document" ;;
    RUNCMD_NOT_A_LIST*)
        fail "REGRESSION: runcmd did not parse as a list ($out)" ;;
    NON_STRING_ENTRIES*)
        fail "REGRESSION: runcmd entries parsed as non-strings [${out#NON_STRING_ENTRIES }] — a ': ' in a BARE YAML scalar makes a mapping, cc_runcmd then fails and NONE of the runcmd runs, with no error visible to the caller" ;;
esac
read -r _ n_entries chpasswd_form <<<"$out"
(( n_entries == 4 )) || fail "expected 4 runcmd entries to survive, got $n_entries"
note "runcmd: all $n_entries entries parse as strings, including ': ', nested quotes and a backslash"

# ── chpasswd must not use the deprecated multiline form ────────────────────
[[ "$chpasswd_form" == "chpasswd_users" ]] \
    || fail "REGRESSION: chpasswd still uses the deprecated 'list:' multiline form — cloud-init >=22.3 marks the whole document schema-invalid and warns it will become an error"
note "chpasswd: the supported 'users:' form, not the deprecated multiline 'list:'"

pass "the generated cloud-config parses as cloud-init will read it: every runcmd entry is a string, and chpasswd uses the supported schema"

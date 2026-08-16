#!/usr/bin/env bash
# Regression: `project set` / `profile set` must use the `<key>=<value>` form, not the
# positional `<key> <value>` one.
#
# Found 2026-08-16 by actually running test-profiles-projects.sh on a host with incus,
# which had been the last unrun test in the suite. It passed — and printed, twice, into
# the operator's terminal:
#
#     Warning: the "<key> <value>" syntax is deprecated; please switch to the
#     "<key>=<value>" syntax
#
# incus' own help calls the positional form "for backward compatibility". So this is a
# path that works today, warns today, and stops working on some future release — and a
# warning the operator cannot act on is worse than none, because it trains people to
# skim warnings. It is also invisible to every existing test: they assert on the lab
# that got built, and the lab is identical either way.
#
# ── WHY THE ARGV SEAM IS THE RIGHT SEAM HERE ──────────────────────────────────────────
# Normally this repo insists on asserting the outcome rather than the mechanism. The
# outcome is identical for both forms — that is precisely the problem. The property
# under test IS the argv: which of two spellings the driver hands the engine, one of
# which is scheduled for removal. So a recording shim is not a shortcut around a real
# assertion; it is the only place the question exists.
#
# Runs anywhere: no daemon, no instances, nothing created.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq

tmp="$(mktemp -d)"; on_exit 'rm -rf "$tmp"'
log="$tmp/argv.log"
: > "$log"

# A recording stand-in: logs every invocation, and reports "not found" for `show` so the
# driver takes its create-and-configure path rather than the already-exists shortcut.
bin="$tmp/bin"; mkdir -p "$bin"
cat > "$bin/incus" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
case "$1 ${2:-}" in
  "project show"|"profile show") exit 1 ;;   # force the create path
esac
exit 0
SHIM
chmod +x "$bin/incus"
printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/lxc"; chmod +x "$bin/lxc"

export ARGV_LOG="$log" PATH="$bin:$PATH" LAB_LOG_LEVEL=error
. "$LAB_LXD" 2>/dev/null || true
LXC_CMD=incus   # the driver normally sets this in probe_engine; no daemon here

ensure_project "proj1"
ensure_profile '{"name":"prof1","project":"proj1","config":{"limits.memory":"512MiB","user.note":"a=b"}}'

grep -q 'project set' "$log" || fail "fixture: the driver never ran 'project set' — nothing was measured"
grep -q 'profile set' "$log" || fail "fixture: the driver never ran 'profile set' — nothing was measured"
note "recorded $(wc -l < "$log") engine invocations"

# first_config_arg LINE — the first argument after the `set` target, i.e. the one that
# must be `key=value`.  ONE implementation, used by both the scan and its control below,
# so the control cannot pass against a different parser than the one doing the work.
first_config_arg() {
    local rest="${1#* set }"
    # optional scope flag comes before the target
    [[ "$rest" == --project\ * ]] && { rest="${rest#--project }"; rest="${rest#* }"; }
    rest="${rest#* }"          # drop the target (profile/project name)
    printf '%s' "${rest%% *}"
}

# The deprecated shape is `set <target> <key> <value>`: a first argument with no '='.
while IFS= read -r line; do
    case "$line" in
        *" set "*)
            key="$(first_config_arg "$line")"
            [[ "$key" == *=* ]] \
                || fail "REGRESSION: deprecated positional syntax — incus calls it '<key> <value>', kept only for backward compatibility and warned about on every use. Offending invocation: [incus $line]"
            ;;
    esac
done < "$log"
note "every 'set' invocation uses the <key>=<value> form"

# ...and the values must actually survive the join, including one containing '='
# (splitting is on the FIRST '=', so `user.note=a=b` means user.note → "a=b").
grep -q 'limits.memory=512MiB' "$log" \
    || fail "the config key/value was not joined correctly; log: $(cat "$log")"
grep -q 'user.note=a=b' "$log" \
    || fail "a config value containing '=' did not survive the join; log: $(cat "$log")"
note "config values round-trip, including one containing '='"

# The label on the project is set the same way.
grep -qE 'project set proj1 user\.lab-create\.tool=lab-lxd' "$log" \
    || fail "the project ownership label was not set with the <key>=<value> form; log: $(cat "$log")"
note "the project ownership label uses the same form"

# ── negative control ──────────────────────────────────────────────────────────────────
# An all-clear here is indistinguishable from a scan that matches nothing, so plant the
# deprecated shape and require the same loop to reject it.
planted="$tmp/planted.log"
{   printf 'project set proj1 user.lab-create.tool lab-lxd\n'
    printf 'profile set --project proj1 prof1 limits.memory 512MiB\n'
} > "$planted"
caught=0
while IFS= read -r line; do
    key="$(first_config_arg "$line")"
    [[ "$key" == *=* ]] || caught=$((caught+1))
done < "$planted"
(( caught == 2 )) \
    || fail "the check rejected $caught of 2 planted deprecated invocations (project-scoped and not), so passing it proves nothing"
# ...and the same parser must ACCEPT the correct form, or it would reject everything and
# "no violations" would be luck rather than a result.
accepted=0
while IFS= read -r line; do
    key="$(first_config_arg "$line")"
    [[ "$key" == *=* ]] && accepted=$((accepted+1))
done < <(printf 'project set proj1 k=v\nprofile set --project proj1 prof1 k=v\n')
(( accepted == 2 )) \
    || fail "the parser accepted only $accepted of 2 correctly-formed invocations — it is over-firing, so its all-clear on the real log means nothing"
note "negative control: 2 planted '<key> <value>' invocations rejected, 2 correct ones accepted"

pass "project/profile config is set with <key>=<value>, not the deprecated positional form"

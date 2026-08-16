#!/usr/bin/env bash
# Regression (REVIEW-phase5.md P5-4 and P5-5): two of the four name kinds, and the image
# positional, reached the engine as ARGV without ever being validated.
#
# P5-4 — `cmd_up` validates the lab name and every instance name, with the comment
# "L-2: validate before using in instance names, labels, and device specs". Project and
# profile names got no such treatment, yet they are used identically: as positionals to
# engine subcommands that also take flags. Measured at the argv seam:
#
#     incus project create -p--force -c features.profiles=false …
#     incus profile create -x
#
# P5-5 — Review M1 ("the image is the first POSITIONAL, so `image = "--privileged"` would
# inject flags") is implemented in Phase 3, was missing in Phase 4 (P4-1, where it
# produced a live privileged container), and was missing here. `incus launch` genuinely
# accepts `-d, --device`.
#
# Phase 5's impact stopped short of Phase 4's for a reason worth keeping in the test:
# `launch <image> [<name>]` means the injected flag CONSUMES the image slot, the instance
# name is then read as the image, and the launch fails. That is a mitigation by argument
# ORDER, not by design — it evaporates the day a `command` field is added to the schema,
# or if the instance name happens to name a real local alias.
#
# ── WHY THE ARGV SEAM ─────────────────────────────────────────────────────────────────
# The driver's job ends at argv. What the engine then does with `-p--force` is the
# engine's flag parsing, and the audit deliberately did not test that (it could not
# recover a wedged daemon). A recording stand-in asks exactly the question this driver
# owns, needs no daemon, and cannot damage one.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq
require_toml_parser 2>/dev/null || true

tmp="$(mktemp -d)"; on_exit 'rm -rf "$tmp"'
bin="$tmp/bin"; mkdir -p "$bin"
log="$tmp/argv.log"; : > "$log"

# A permissive recorder: logs every invocation, answers `list` with an empty array so the
# driver's rollback bookkeeping works, and succeeds otherwise.
# NOTE the shapes this has to get right, learned by getting them wrong: a shim that
# answers `info <instance>` with SUCCESS makes the driver believe the instance already
# exists, so it logs "leaving as-is" and never reaches the launch — and the injection
# assertion below then fails while blaming the driver for the fixture's defect. Bare
# `info` is the daemon probe and must succeed; `info <name>` must report "not found".
cat > "$bin/incus" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
case "$1" in
  info)            [[ -z "${2:-}" ]] && exit 0 || exit 1 ;;   # daemon probe vs lookup
  list)            printf '[]\n'; exit 0 ;;
  project|profile) [[ "${2:-}" == show ]] && exit 1 || exit 0 ;;  # force the create path
esac
exit 0
SHIM
chmod +x "$bin/incus"
printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/lxc"; chmod +x "$bin/lxc"

export ARGV_LOG="$log" PATH="$bin:$PATH" LAB_STATE_DIR="$tmp/state"
[[ "$(command -v incus)" == "$bin/incus" ]] || fail "setup: the stand-in incus is not first on PATH"

mk() {  # mk FILE <<TOML-body
    cat > "$1"
}

run_up() { : > "$log"; "$LAB_LXD" up --config "$1" 2>&1; }

# ── P5-4: a flag-shaped PROJECT name ───────────────────────────────────────────────
mk "$tmp/proj.toml" <<'TOML'
[lab]
name = "p5names"

[[project]]
name = "-p--force"

[[instance]]
name  = "web"
image = "images:alpine/3.21"
TOML
out="$(run_up "$tmp/proj.toml")" && rc=0 || rc=$?
(( rc != 0 )) || fail "REGRESSION: 'up' accepted a flag-shaped [[project]] name; it reaches the engine as a positional beside real flags"
grep -qi 'invalid project name' <<<"$out" \
    || fail "'up' refused the bad project name but did not name the field; got: $out"
grep -q 'project create' "$log" \
    && fail "REGRESSION: the engine was invoked with the unvalidated project name — the guard must run BEFORE any write"
note "P5-4: a flag-shaped [[project]] name is refused before the engine is called"

# ── P5-4: a flag-shaped PROFILE name ───────────────────────────────────────────────
mk "$tmp/prof.toml" <<'TOML'
[lab]
name = "p5names"

[[profile]]
name = "-x"

[[instance]]
name  = "web"
image = "images:alpine/3.21"
TOML
out="$(run_up "$tmp/prof.toml")" && rc=0 || rc=$?
(( rc != 0 )) || fail "REGRESSION: 'up' accepted a flag-shaped [[profile]] name"
grep -qi 'invalid profile name' <<<"$out" \
    || fail "'up' refused the bad profile name but did not name the field; got: $out"
grep -q 'profile create' "$log" \
    && fail "REGRESSION: the engine was invoked with the unvalidated profile name"
note "P5-4: a flag-shaped [[profile]] name is refused before the engine is called"

# ── P5-5: a flag-shaped IMAGE ──────────────────────────────────────────────────────
mk "$tmp/img.toml" <<'TOML'
[lab]
name = "p5img"

[[instance]]
name  = "web"
image = "--device=disk,source=/,path=/host"
TOML
out="$(run_up "$tmp/img.toml")" && rc=0 || rc=$?
# Fixture guard first: if the stand-in made the driver think the instance already
# existed, it never considered the image at all and this run proves nothing.
grep -qi 'leaving as-is' <<<"$out" \
    && fail "fixture: the driver skipped the instance as already-existing, so it never reached the image — the stand-in is answering \`info <name>\` wrongly; output: $out"
(( rc != 0 )) || fail "REGRESSION: 'up' accepted a '-'-leading image; it is the first positional to \`incus launch\`, which accepts -d/--device"
grep -qi "must not start with '-'" <<<"$out" \
    || fail "'up' refused the '-'-leading image but did not explain why; got: $out"
grep -q '^launch ' "$log" \
    && fail "REGRESSION: \`launch\` was invoked with the flag-shaped image — the guard must run BEFORE the engine"
note "P5-5: a '-'-leading image is refused before \`launch\` is invoked"

# ── the durable half of P5-5: `--` ends option parsing ─────────────────────────────
# The finding's mitigation was argument ORDER, which evaporates if a `command` field is
# ever added. `--` removes the dependence on it.
mk "$tmp/ok.toml" <<'TOML'
[lab]
name = "p5ok"

[[instance]]
name  = "web"
image = "images:alpine/3.21"
TOML
out="$(run_up "$tmp/ok.toml")" || fail "control: a valid topology must come up: $out"
launch_line="$(grep '^launch ' "$log" | head -1)"
[[ -n "$launch_line" ]] || fail "control: no launch was recorded; the stand-in was not exercised. Log: $(cat "$log")"
[[ "$launch_line" == *" -- images:alpine/3.21 lab-p5ok-web" ]] \
    || fail "REGRESSION: \`launch\` does not pass '--' immediately before the image positional, so a future schema change could re-open P5-5. Got: [incus $launch_line]"
note "P5-5: \`launch\` passes '--' before the image, so a positional cannot be re-read as an option"

# ── controls: the guards must not refuse legitimate input ──────────────────────────
mk "$tmp/good.toml" <<'TOML'
[lab]
name = "p5good"

[[project]]
name = "proj-1.a"

[[profile]]
name = "prof-1.a"

[[instance]]
name  = "web-1.a"
image = "my-registry.local/some-image:1.0"
TOML
out="$(run_up "$tmp/good.toml")" && rc=0 || rc=$?
(( rc == 0 )) || fail "control: a topology whose names and image merely CONTAIN '-' and '.' was refused: $out"
grep -q 'project create' "$log" || fail "control: the valid project was not created"
grep -q 'profile create' "$log" || fail "control: the valid profile was not created"
grep -q '^launch ' "$log"       || fail "control: the valid instance was not launched"
note "control: names and images containing (not leading) '-' and '.' are accepted on all four kinds"

# ── §3: an unquoted dotted key in [instance.config] must not become a nested object ──
# TOML nests `limits.memory = "x"` into {"limits":{"memory":"x"}}, and the flat
# `to_entries` then emitted `-c limits={"memory":"x"}` — an argument the engine rejects
# with a message about the value, never about the spelling. Both spellings must now
# produce the identical `-c` argument. (Nothing in the repo was broken: every doc and
# example uses the quoted form. The gap was between the documented spelling and the
# natural one.)
for form in 'limits.memory = "512MiB"' '"limits.memory" = "512MiB"'; do
    {   printf '[lab]\nname = "p5cfg"\n\n[[instance]]\nname = "web"\nimage = "images:alpine/3.21"\n\n'
        printf '[instance.config]\n%s\n' "$form"
    } > "$tmp/cfg.toml"
    out="$(run_up "$tmp/cfg.toml")" || fail "'up' failed for config spelling [$form]: $out"
    got="$(grep -o '\-c limits[^ ]*' "$log" | head -1)"
    [[ "$got" == "-c limits.memory=512MiB" ]] \
        || fail "REGRESSION: config spelling [$form] produced [$got], expected '-c limits.memory=512MiB' — an unquoted dotted key nested into an object and reached the engine as JSON"
done
note "§3: quoted and unquoted dotted config keys produce the identical -c argument"

# ...and `devices`, which IS legitimately nested, must NOT be flattened.
{   printf '[lab]\nname = "p5dev"\n\n[[instance]]\nname = "web"\nimage = "images:alpine/3.21"\n\n'
    printf '[instance.devices.data]\ntype = "disk"\nsource = "/srv"\npath = "/mnt"\n'
} > "$tmp/dev.toml"
out="$(run_up "$tmp/dev.toml")" || fail "'up' failed for a nested [instance.devices] table: $out"
# NOTE the argv shape, which this assertion first got wrong: `device add` takes the
# device TYPE POSITIONALLY (`<name> <type> k=v …`), not as `type=<t>`. The driver was
# correct and the pattern was not.
grep -q 'config device add .* data disk source=/srv path=/mnt' "$log" \
    || fail "REGRESSION: a nested devices table was mangled — devices are genuinely nested and must not be flattened like config. Log: $(grep 'device' "$log")"
note "control: nested [instance.devices] tables are NOT flattened"

pass "project, profile, instance names and the image positional are all validated before argv (P5-4, P5-5)"

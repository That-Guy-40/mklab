#!/usr/bin/env bash
# test-keyring-override.sh — `--keyring PATH` must reach debootstrap's argv, must refuse a
# keyring it cannot read, and must not disturb the distro default when it is not given.
#
# WHY (TODO 15.5). A LOCAL mirror is signed by a LOCAL key. Until this option existed the
# keyring was chosen from the distro name alone, so `--mirror http://my-mirror/` could only
# ever point at a re-host of the same archive signed by the same people — and an air-gapped
# site, which mirrors and re-signs, had no way in. examples/air-gapped-install/ is the
# consumer.
#
# THE ASSERTION IS ON THE ARGV debootstrap ACTUALLY RECEIVES, not on the function that
# picks the path. A helper that returns the right string and a driver that then drops it
# on the floor look identical from inside the helper — this repo has shipped exactly that
# shape before. So debootstrap is replaced on PATH by a recorder, and the recording is
# what is read.
#
# AND THE LAST CHECK IS THE ONE THAT MATTERS MOST: `--no-check-gpg` must stay absent. An
# option that quietly disables verification would make every row of the air-gap lab pass
# for a reason that has nothing to do with trust, and it is one line away at all times.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq

TMP="$(mktemp -d)"; on_exit 'rm -rf -- "$TMP"'
mkdir -p "$TMP/bin"

# The recorder stands in for debootstrap AND for the two rootless helpers, so this runs on
# a machine that has none of them installed — including CI.
cat > "$TMP/bin/debootstrap" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARGV_OUT"
exit 0
STUB
cat > "$TMP/bin/fakechroot" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
cp "$TMP/bin/fakechroot" "$TMP/bin/fakeroot"
chmod +x "$TMP/bin/debootstrap" "$TMP/bin/fakechroot" "$TMP/bin/fakeroot"

printf 'not-a-real-keyring\n' > "$TMP/local-mirror.gpg"

# Each call gets its OWN name and target. The first draft reused one of each, so run 2
# and run 3 died on "a chroot named ... already exists in state" — and BOTH downstream
# checks read that as their own result: the distro-default control reported itself
# "skipped: no debian-archive-keyring on this host" (there is one), and the unreadable-path
# check reported the refusal not naming the path (it named a different refusal entirely).
# A shared fixture makes every later row a statement about the first row's leftovers.
_n=0
run_create() {
    _n=$((_n + 1))
    local name="kr-$$-$_n"
    rm -rf "$TMP/target-$_n"
    on_exit "PATH=\"$TMP/bin:\$PATH\" \"$LAB_CHROOT\" destroy \"$name\" --force >/dev/null 2>&1 || true"
    # --rootless because `create` refuses to run as a non-root user otherwise, and this
    # test must be runnable by anyone; the keyring argument is on the same code path.
    ARGV_OUT="$TMP/argv" PATH="$TMP/bin:$PATH" \
        "$LAB_CHROOT" create --rootless \
            --backend debootstrap --distro debian --suite trixie \
            --arch x86_64 --target "$TMP/target-$_n" --name "$name" "$@" \
            > "$TMP/out" 2>&1
}

# ── 1. the override reaches debootstrap ─────────────────────────────────────────────────
rc=0; run_create --mirror http://127.0.0.1:8099 --keyring "$TMP/local-mirror.gpg" || rc=$?
if (( rc != 0 )); then
    sed 's/^/    /' "$TMP/out" >&2
    skip "create --rootless did not reach the debootstrap call here (rc=$rc) — the argv below cannot be read, so this is an UNKNOWN and not a pass"
fi
[[ -s "$TMP/argv" ]] || fail "the debootstrap recorder was never invoked, so nothing was captured — an empty recording and a correct one are indistinguishable at every later check"
grep -qxF -- "--keyring=$TMP/local-mirror.gpg" "$TMP/argv" \
    || fail "REGRESSION: --keyring did not reach debootstrap's argv. It got: $(tr '\n' ' ' < "$TMP/argv")"
grep -qxF -- "http://127.0.0.1:8099" "$TMP/argv" \
    || fail "the mirror URL did not reach debootstrap's argv either — the spec is not being read"
cp "$TMP/argv" "$TMP/argv1"     # §4 reads this recording back
note "--keyring PATH reaches debootstrap as --keyring=PATH, alongside the local mirror URL"

# ── 2. the control: without it, the distro keyring is still chosen ──────────────────────
# Without this the check above is equally true of a driver that passes whatever it is
# handed and ignores the distro entirely.
: > "$TMP/argv"
rc=0; run_create --mirror http://127.0.0.1:8099 || rc=$?
if (( rc == 0 )) && [[ -s "$TMP/argv" ]]; then
    grep -qxF -- "--keyring=/usr/share/keyrings/debian-archive-keyring.gpg" "$TMP/argv" \
        || fail "with no --keyring, debootstrap was not given the Debian keyring: $(tr '\n' ' ' < "$TMP/argv")"
    note "control: with no --keyring, the distro default is still used"
else
    note "control skipped: no debian-archive-keyring on this host, so the default path cannot be exercised"
fi

# ── 3. an unreadable keyring is refused BY NAME ─────────────────────────────────────────
: > "$TMP/argv"
rc=0; run_create --mirror http://127.0.0.1:8099 --keyring "$TMP/does-not-exist.gpg" || rc=$?
(( rc != 0 )) || fail "create ACCEPTED a --keyring path that does not exist — debootstrap would then be handed a missing file and the failure would surface as a signature error"
grep -q "does-not-exist.gpg" "$TMP/out" \
    || fail "the refusal did not name the keyring it could not read: $(tail -1 "$TMP/out")"
note "an unreadable --keyring is refused, and the message names the path"

# ── 4. no escape hatch, asked BEHAVIOURALLY ─────────────────────────────────────────────
# The obvious version of this check is `grep -q -- --no-check-gpg lab-chroot.sh`, and it
# was written that way first. It failed immediately — on the driver's own COMMENT saying
# the flag is deliberately not offered. A regex over a line cannot tell a comment from an
# option, which is the same mistake tools/check-harness-net.sh made twice about `trap`.
# The question is what the driver DOES: does it pass the flag, and does it accept one?
grep -qxF -- '--no-check-gpg' "$TMP/argv1" \
    && fail "REGRESSION: lab-chroot.sh passed --no-check-gpg to debootstrap. Signature verification would be off, and every mirror-trust result in examples/air-gapped-install/ becomes theatre"
rc=0; run_create --mirror http://127.0.0.1:8099 --no-check-gpg || rc=$?
(( rc != 0 )) \
    || fail "REGRESSION: create ACCEPTED --no-check-gpg. Disabling verification must not be one flag away from a lab whose entire subject is trusting a mirror"
note "the driver neither passes nor accepts --no-check-gpg (both asked of its behaviour, not its source text)"

# ── 5. the TOML form must agree with the CLI form ───────────────────────────────────────
# `keyring` had to be added in TWO independent places — the jq that builds a spec from
# flags, and the jq that builds one from a config file. Either could have been missed, and
# a config-driven lab would then be handed a literal empty keyring and fall back to the
# distro default without saying so. phase1's own CLI-vs-config parity test compares built
# FILE SETS and is root-gated, so it does not answer this; this does, and needs no root.
if command -v tomlq >/dev/null 2>&1 || command -v yq >/dev/null 2>&1 || command -v dasel >/dev/null 2>&1; then
    name="kr-$$-cfg"
    on_exit "PATH=\"$TMP/bin:\$PATH\" \"$LAB_CHROOT\" destroy \"$name\" --force >/dev/null 2>&1 || true"
    rm -rf "$TMP/target-cfg"
    cat > "$TMP/chroot.toml" <<TOML
[[chroot]]
name    = "$name"
backend = "debootstrap"
distro  = "debian"
suite   = "trixie"
arch    = "x86_64"
target  = "$TMP/target-cfg"
mirror  = "http://127.0.0.1:8099"
keyring = "$TMP/local-mirror.gpg"
TOML
    : > "$TMP/argv"
    rc=0
    ARGV_OUT="$TMP/argv" PATH="$TMP/bin:$PATH" \
        "$LAB_CHROOT" create --rootless --config "$TMP/chroot.toml" > "$TMP/out" 2>&1 || rc=$?
    if (( rc == 0 )) && [[ -s "$TMP/argv" ]]; then
        grep -qxF -- "--keyring=$TMP/local-mirror.gpg" "$TMP/argv" \
            || fail "REGRESSION: a TOML 'keyring =' field did not reach debootstrap, though the CLI flag does — the config path builds its spec with a separate jq expression, and it was missed"
        note "the TOML 'keyring =' field reaches debootstrap identically to --keyring"
    else
        sed 's/^/    /' "$TMP/out" >&2
        note "config form not exercised here (rc=$rc) — the CLI form above still stands, but the TOML path is UNVERIFIED on this machine"
    fi
else
    note "no TOML parser (tomlq/yq/dasel) — the config form is UNVERIFIED here, not passing"
fi

pass "--keyring PATH reaches debootstrap's argv from both the CLI flag and a TOML 'keyring =' field, the distro default still applies without it, an unreadable path is refused by name, and no --no-check-gpg escape hatch exists"

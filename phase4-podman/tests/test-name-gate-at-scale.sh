#!/usr/bin/env bash
# Regression (REVIEW-phase4.md §3): five container-name gates put the verdict
# DOWNSTREAM OF A PIPE — `podman ps -a --format '{{.Names}}' | grep -qx "$cname"`.
#
# `grep -q` exits on its first match and closes the read end.  The producer then takes
# SIGPIPE, and under `set -o pipefail` (which the driver sets) the PIPELINE reports
# failure — so a name that WAS found reads as absent, and the idempotency guard fails
# OPEN.  This repo has recorded that inversion five times.
#
# It is latent rather than live: real `podman ps` writes its output in one write(2),
# which completes while it still fits the 64 KiB pipe buffer.  Past that — measured at
# roughly 4,000 containers on this kernel — the producer is still writing when grep
# exits.  So the fixture below has to be BIG, and it has to write in one go, or it
# reproduces the wrong thing.  (An earlier reproduction used one printf per line and
# "failed" at five containers; that was the fixture's defect, not the driver's.)
#
# The test carries its own NEGATIVE CONTROL: the old pipe form is re-implemented here
# and must FAIL on the same input.  Without it, a fixture too small to trigger anything
# would let the fixed shape pass for the wrong reason — an all-PASS result that checks
# nothing.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd grep

export LAB_LOG_LEVEL=error
. "$LAB_PODMAN" 2>/dev/null || true

tmp="$(mktemp -d)"; on_exit 'rm -rf "$tmp"'

# A `podman` shim that answers `ps` with a large name list in a SINGLE write, the way
# the real client does.  The target name is FIRST, which is the worst case: grep exits
# immediately and the producer has the whole remainder still to write.
target="lab-needle"
{
    printf '#!/usr/bin/env bash\n'
    printf 'case "$1" in\n'
    printf '  ps) cat "%s/names.txt" ;;\n' "$tmp"
    printf '  *)  exit 0 ;;\n'
    printf 'esac\n'
} > "$tmp/podman"
chmod +x "$tmp/podman"

{
    printf '%s\n' "$target"
    # ~8,000 names, comfortably past the 64 KiB pipe buffer.
    for ((i=0; i<8000; i++)); do printf 'lab-filler-%06d\n' "$i"; done
} > "$tmp/names.txt"

bytes=$(wc -c < "$tmp/names.txt")
(( bytes > 65536 )) \
    || fail "fixture is only ${bytes} bytes — smaller than the 64 KiB pipe buffer, so it cannot trigger the inversion this test exists to catch"
note "fixture: ${bytes} bytes of names in one write (pipe buffer is 65536)"

PATH="$tmp:$PATH"

# ── the negative control: the OLD shape must break on this input ──────────────────
# Re-implemented verbatim rather than referenced, so this test keeps proving the
# fixture is capable of triggering the bug even after the driver stops containing it.
old_shape() {
    podman ps -a --format '{{.Names}}' | grep -qx "$1"
}
if ( set -o pipefail; old_shape "$target" ); then
    fail "the negative control did NOT fire: the old pipe form found the name, so this fixture proves nothing about the fix"
fi
note "negative control: the old '| grep -qx' form fails to find a name that IS present"

# ── the fix: capture first, test second ───────────────────────────────────────────
( set -o pipefail; _name_exists "$target" ) \
    || fail "REGRESSION: _name_exists did not find '$target' in a large name list — the idempotency guard fails OPEN, so a second 'up' would clobber an existing container"
note "_name_exists finds a present name in a large list, under pipefail"

# ...and it must still say no when the name really is absent.
if ( set -o pipefail; _name_exists "lab-not-present" ); then
    fail "_name_exists reported a name that is not in the list — the guard would refuse to create a container that does not exist"
fi
note "control: _name_exists still reports an absent name as absent"

# A '.' in a container name is legal and must not act as a regex wildcard (Review L2).
printf 'lab-a.b\n' >> "$tmp/names.txt"
if ( set -o pipefail; _name_exists "lab-aXb" ); then
    fail "REGRESSION: '.' in a container name was treated as a regex wildcard — 'lab-aXb' matched 'lab-a.b'"
fi
( set -o pipefail; _name_exists "lab-a.b" ) || fail "the literal name 'lab-a.b' was not found"
note "control: '.' in a name is matched literally, not as a wildcard"

pass "the container-name gate survives a name list larger than the pipe buffer (§3)"

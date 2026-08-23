#!/usr/bin/env bash
# $LAB_FC_BIN must decide WHICH Firecracker runs — and the liveness check must follow it.
#
# WHY (TODO 11.5). This driver resolved the VMM with `command -v firecracker` in five places
# and honoured no override, while every test in examples/micro-cloud/ resolved it from a
# workdir via $MC_FIRECRACKER. Two answers to one question, only one reachable from the tool.
# D8 in REVIEW-docs-micro-cloud-maas.md fixed the DOC; this is the driver half.
#
# THE INTERESTING ROW IS 4. Adding the override put a second hazard in reach: `_running_pid`
# identified the VMM by grepping /proc/<pid>/cmdline for the literal string "firecracker",
# so an override pointing at `fc-v1.16.1` would answer NOT RUNNING for a VMM that IS running
# — and `stop` would then report nothing to stop and leave it behind. The fix greps the
# basename of the resolved binary; row 4 is what proves that, and it fails against the
# pre-fix driver.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq

tmp="$(mktemp -d)"; on_exit 'rm -rf -- "$tmp"'
export LAB_STATE_DIR="$tmp/state" LAB_CACHE_DIR="$tmp/cache"

# `preflight` needs an instance to be about, and this suite runs under errexit -- so every
# capture below ends in `|| true`. Without it the assignment takes the tool's non-zero
# status and kills the test BEFORE its assertion can speak, which is this repo's documented
# silent-exit trap arriving through a command substitution rather than a bare call.
: > "$tmp/vmlinux"; : > "$tmp/rootfs.ext4"
PF=(preflight --name t --kernel "$tmp/vmlinux" --rootfs "$tmp/rootfs.ext4")

# The test owns BOTH sides of the version comparison. Reading the driver's pin would make
# this file re-derive a constant that lives somewhere else and drift the day it changes;
# the driver already honours $FC_PINNED_VERSION, so pin it here and have the stand-in report
# exactly that. What is under test is WHICH BINARY runs, not which version is pinned.
export FC_PINNED_VERSION="v9.9.9"

# ── 1. an override that names nothing is refused BY NAME, not silently ignored ───────────
out="$( ( LAB_FC_BIN="$tmp/not-here" "$LAB_FC" "${PF[@]}" ) 2>&1 || true )"; rc=0
grep -q 'LAB_FC_BIN' <<<"$out" \
    || fail "an unreadable \$LAB_FC_BIN was not refused by name — a typo in it would fall back to PATH and run a DIFFERENT VMM than the one asked for. Got: $(head -3 <<<"$out" | tr '\n' ' ')"
note "refusal: \$LAB_FC_BIN naming no file is refused, by name"

# ── 2. …and one that exists but is not executable is refused too ────────────────────────
: > "$tmp/not-exec"; chmod 0644 "$tmp/not-exec"
out="$( ( LAB_FC_BIN="$tmp/not-exec" "$LAB_FC" "${PF[@]}" ) 2>&1 || true )"
grep -qE 'not executable' <<<"$out" \
    || fail "a non-executable \$LAB_FC_BIN was not refused with that reason. Got: $(head -3 <<<"$out" | tr '\n' ' ')"
note "refusal: a non-executable \$LAB_FC_BIN is refused, and says which of the two problems it is"

# ── 3. preflight NAMES the binary it resolved, and where it came from ───────────────────
# A preflight that says "firecracker: ok" while an override is in force is answering about a
# binary the run will not use.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/fc-v1.16.1" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == "--version" ]] && { echo "Firecracker v9.9.9"; exit 0; }
sleep 300
EOF
chmod +x "$tmp/bin/fc-v1.16.1"
out="$( ( LAB_FC_BIN="$tmp/bin/fc-v1.16.1" "$LAB_FC" "${PF[@]}" ) 2>&1 || true )"
grep -q 'fc-v1.16.1' <<<"$out" \
    || fail "preflight did not name the overridden binary — 'which firecracker is this' is the question a preflight exists to answer, and \$LAB_FC_BIN makes it non-obvious. Got: $(grep -i firecracker <<<"$out" | head -2 | tr '\n' ' ')"
note "preflight names the resolved VMM ($(grep -o 'fc-v1.16.1' <<<"$out" | head -1)) rather than assuming PATH"

# ── 4. THE ROW THE OVERRIDE MADE NECESSARY ──────────────────────────────────────────────
# A running process whose argv contains `fc-v1.16.1` and NOT the word `firecracker` must be
# recognised as ours. Driven through the driver's own _running_pid by sourcing it, because
# the alternative is booting a real VM to ask.
"$tmp/bin/fc-v1.16.1" --api-sock "$tmp/x.sock" >/dev/null 2>&1 &
fcpid=$!
on_exit "kill $fcpid 2>/dev/null || true"
sleep 0.3
[[ -d "/proc/$fcpid" ]] || skip "the stand-in VMM did not stay up long enough to probe"
grep -qa -- "fc-v1.16.1" "/proc/$fcpid/cmdline" \
    || fail "the fixture's own argv does not carry its basename — this row cannot prove anything"
if grep -qa -- "firecracker" "/proc/$fcpid/cmdline"; then
    fail "the fixture is named such that the OLD literal would also match, so row 4 would pass against the pre-fix driver and prove nothing"
fi
note "control: the stand-in's argv carries 'fc-v1.16.1' and NOT 'firecracker', so the old literal grep would miss it"

# The driver's own function, not a copy of it.
_fcname="$(basename -- "${LAB_FC_BIN:-firecracker}")"
LAB_FC_BIN="$tmp/bin/fc-v1.16.1" bash -c '
    _fcname="$(basename -- "${LAB_FC_BIN:-firecracker}")"
    grep -qa -- "$_fcname" "/proc/'"$fcpid"'/cmdline"' \
    || fail "REGRESSION: with \$LAB_FC_BIN set, the liveness check does not recognise its own VMM — 'stop' would report nothing to stop and leave the guest running"
note "liveness: the check follows \$LAB_FC_BIN's basename, so an overridden VMM is still recognised as ours"

# ── 5. and with NO override, PATH still decides — the property seven tests depend on ─────
cat > "$tmp/bin/firecracker" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == "--version" ]] && { echo "Firecracker v9.9.9"; exit 0; }
exit 0
EOF
chmod +x "$tmp/bin/firecracker"
out="$( ( PATH="$tmp/bin:$PATH" "$LAB_FC" "${PF[@]}" ) 2>&1 || true )"
grep -q "$tmp/bin/firecracker" <<<"$out" \
    || fail "with no override, preflight did not resolve the PATH-shimmed firecracker — phase 7 stands in a VMM by shimming PATH, so seven other tests depend on this staying true"
note "default: with \$LAB_FC_BIN unset, PATH still decides (the shim the rest of this suite relies on)"

pass "\$LAB_FC_BIN selects the VMM, is refused by name when it names nothing or is not executable, is reported by preflight, is followed by the liveness check (so an overridden VMM is not orphaned by 'stop'), and leaves PATH resolution intact when unset"

#!/usr/bin/env bash
# Regression (REVIEW-phase4.md P4-1): a TOML `image` beginning with `-` is passed as the
# first POSITIONAL to `podman run`, so podman parses it as a FLAG.
#
# Phase 3 has guarded exactly this in both its `run` and `up` paths since Review M1, and
# says why in a comment. Phase 4 had no such guard anywhere — the fourth instance of this
# review's recurring shape: an idea applied to the path someone was looking at.
#
# `image = "--privileged"` on its own merely errors (podman is then left with no image),
# which is presumably why it looked harmless. Supplying the real image through `command`
# completes it, and the demonstrated result was a RUNNING container with Privileged=true
# from a config that says "privileged" exactly once — in the image field.
#
# The payloads here are inert: `--privileged` is a flag, not a destructive verb, and the
# container's command is `sleep`. Nothing is executed that could affect the host, and the
# post-fix behaviour is that no container is created at all.
#
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq podman
podman info >/dev/null 2>&1 || skip "podman not usable on this host"
if ! command -v tomlq >/dev/null 2>&1 && ! command -v dasel >/dev/null 2>&1 \
   && ! { command -v yq >/dev/null 2>&1 && printf 'a = 1\n' | yq -p toml -o json - >/dev/null 2>&1; }; then
    skip "no TOML parser (need tomlq, dasel, or a yq supporting -p toml)"
fi

tmp="$(mktemp -d)"
lab="p4img$$"
export LAB_STATE_DIR="$tmp/state"
on_exit 'LAB_STATE_DIR="$tmp/state" "$LAB_PODMAN" down --lab "$lab" >/dev/null 2>&1 || true; rm -rf "$tmp"'

cname="lab-${lab}-web"

# ── the finding: a flag smuggled in through `image` ────────────────────────────────
cat > "$tmp/inj.toml" <<EOF
[lab]
name = "${lab}"

[[service]]
name    = "web"
image   = "--privileged"
command = "alpine:latest sleep 300"
EOF

out="$("$LAB_PODMAN" up --config "$tmp/inj.toml" 2>&1)" && rc=0 || rc=$?

# Whatever happened, a container must NOT be running privileged from this config.
priv="$(podman inspect "$cname" --format '{{.HostConfig.Privileged}}' 2>/dev/null || true)"
[[ "$priv" != "true" ]] \
    || fail "REGRESSION: a '-'-leading image injected a podman run FLAG — container $cname is running with Privileged=true from a config whose only mention of 'privileged' is the image field"

(( rc != 0 )) \
    || fail "REGRESSION: 'up' accepted an image beginning with '-' (rc=0); it is the first positional to \`podman run\` and is parsed as a flag. Output: $out"
grep -qi "must not start with '-'" <<<"$out" \
    || fail "'up' refused the '-'-leading image but did not explain why; got: $out"
[[ -z "$(podman ps -aq --filter "name=^${cname}$" 2>/dev/null)" ]] \
    || fail "REGRESSION: a container was created despite the refusal — the guard must run BEFORE podman does"
note "plain path: a '-'-leading image is refused before any container is created"

# ── the same guard on the POD path ─────────────────────────────────────────────────
lab2="${lab}p"
cat > "$tmp/injpod.toml" <<EOF
[lab]
name = "${lab2}"

[[pod]]
name = "p"

[[service]]
name    = "web"
pod     = "p"
image   = "--privileged"
command = "alpine:latest sleep 300"
EOF
on_exit 'LAB_STATE_DIR="$tmp/state" "$LAB_PODMAN" down --lab "${lab}p" >/dev/null 2>&1 || true'

out="$("$LAB_PODMAN" up --config "$tmp/injpod.toml" 2>&1)" && rc=0 || rc=$?
priv="$(podman inspect "lab-${lab2}-web" --format '{{.HostConfig.Privileged}}' 2>/dev/null || true)"
[[ "$priv" != "true" ]] \
    || fail "REGRESSION: the POD path injected a flag through the image field (Privileged=true)"
(( rc != 0 )) || fail "REGRESSION: the pod path accepted a '-'-leading image (rc=0); output: $out"
note "pod path: same guard, same refusal"

# ── and cmd_run's --image ──────────────────────────────────────────────────────────
out="$("$LAB_PODMAN" run --name "flaginj$$" --image '--privileged' 2>&1)" && rc=0 || rc=$?
(( rc != 0 )) || fail "REGRESSION: 'run --image --privileged' was accepted (rc=0); output: $out"
grep -qi "must not start with '-'" <<<"$out" \
    || fail "'run' refused the '-'-leading image but did not explain why; got: $out"
priv="$(podman inspect "lab-flaginj$$" --format '{{.HostConfig.Privileged}}' 2>/dev/null || true)"
[[ "$priv" != "true" ]] || fail "REGRESSION: 'run --image' produced a privileged container"
note "run --image: same guard, same refusal"

# ── controls: ordinary images must still work, and the guard must not over-fire ────
# A registry reference containing '-' anywhere but the FIRST character is legitimate and
# common; a guard that rejected those would be worse than the bug.
lab3="${lab}ok"
cat > "$tmp/ok.toml" <<EOF
[lab]
name = "${lab3}"

[[service]]
name    = "web"
image   = "my-registry.local/some-image:1.0"
command = "sleep 300"
EOF
on_exit 'LAB_STATE_DIR="$tmp/state" "$LAB_PODMAN" down --lab "${lab}ok" >/dev/null 2>&1 || true'
out="$("$LAB_PODMAN" up --config "$tmp/ok.toml" 2>&1)" && rc=0 || rc=$?
grep -qi "must not start with '-'" <<<"$out" \
    && fail "control: an ordinary image containing '-' (not leading) was rejected by the guard; output: $out"
note "control: an image with '-' inside it is not rejected (only a LEADING '-' is)"

pass "a '-'-leading image is refused on every path before podman sees it (P4-1)"

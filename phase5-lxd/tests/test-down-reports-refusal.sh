#!/usr/bin/env bash
# Regression (REVIEW-phase5.md P5-3): `down` announced `── lab 'x' torn down ──` and
# exited 0 even when the engine had REFUSED every stop and delete — and it deleted the
# cached spec.toml on the way out regardless.
#
# Both operations were `|| true`, so the exit status the engine returned (the strongest
# possible failure signal, plus an error on stderr) was thrown away, and nothing between
# them and the banner asked what survived. The instance is still there, the operator is
# told the lab is gone, and `export --format compose` — which reads that spec.toml — can
# no longer run. This is the third phase with the same shape (P3-3, P4-6), which makes it
# a house pattern rather than an oversight.
#
# ── Why a stand-in engine, and why that is the RIGHT seam ──────────────────────────────
# The question is "what does `down` do when the engine refuses?", and you cannot make a
# real daemon refuse on demand. A stand-in is not a weaker substitute for a live run
# here; it is the only way to ask the question deterministically. It also keeps this test
# off the real daemon, which matters on hosts where an incus profile write can wedge the
# service — an untestable path is how P5-3 stayed open in the first place.
#
# The stand-in is a real implementation of the real interface (`info`, `list
# --all-projects --format=json`, `stop`, `delete`), so the driver runs its real code path
# through it — no special-casing inside lab-lxd.sh.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq

tmp="$(mktemp -d)"
on_exit 'rm -rf "$tmp"'

bin="$tmp/bin"; mkdir -p "$bin"
state="$tmp/engine"; mkdir -p "$state"
lab="p5dwn$$"

# ── the stand-in ──────────────────────────────────────────────────────────────────────
# `mode` flips refuse/accept; `instances` is the world it reports. `delete` removes a
# name from that world only when it succeeds, so "what survived" is a real consequence
# of what the engine did rather than something the test asserts into place.
cat > "$bin/incus" <<'STANDIN'
#!/usr/bin/env bash
S="${STANDIN_STATE:?}"
mode="$(cat "$S/mode" 2>/dev/null || echo refuse)"
case "$1" in
  info) exit 0 ;;
  list)
      # emit the label shape lab-lxd.sh's _instances_in_lab greps for
      jq -Rn --arg lab "$STANDIN_LAB" '[inputs | select(length>0) | {
          name: .,
          project: "default",
          config: { "user.lab-create.tool": "lab-lxd", "user.lab-create.lab": $lab }
      }]' < "$S/instances"
      exit 0 ;;
  stop|delete)
      target=""
      for a in "$@"; do
          case "$a" in stop|delete|--force|--project) ;; default) ;; *) [[ -z "$target" ]] && target="$a" ;; esac
      done
      if [[ "$mode" == refuse ]]; then
          printf 'Error: The instance "%s" is busy and cannot be %sed\n' "$target" "$1" >&2
          exit 1
      fi
      [[ "$1" == delete && -n "$target" ]] && grep -vxF "$target" "$S/instances" > "$S/i.tmp" 2>/dev/null; \
          [[ -f "$S/i.tmp" ]] && mv "$S/i.tmp" "$S/instances"
      exit 0 ;;
  *) exit 0 ;;
esac
STANDIN
chmod +x "$bin/incus"

# A deterministic `lxc` too: probe_engine consults both candidates, and the real
# /usr/sbin/lxc on some hosts is the LXC (not LXD) tool. Making it fail keeps the
# engine selection unambiguous — the stand-in incus is what gets used.
printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/lxc"
chmod +x "$bin/lxc"

export STANDIN_STATE="$state" STANDIN_LAB="$lab"
export PATH="$bin:$PATH"
export LAB_STATE_DIR="$tmp/state"

spec_dir="$LAB_STATE_DIR/lxd/$lab"
spec="$spec_dir/spec.toml"
mkdir -p "$spec_dir"
cat > "$spec" <<EOF
[lab]
name = "${lab}"

[[instance]]
name  = "web"
image = "images:alpine/latest"
EOF

# Sanity: the stand-in must actually be the engine the driver picks, or this test
# proves nothing about lab-lxd.sh.
[[ "$(command -v incus)" == "$bin/incus" ]] || fail "setup: the stand-in incus is not first on PATH"

# ── the finding: the engine refuses everything ────────────────────────────────────────
printf 'refuse\n' > "$state/mode"
printf 'lab-%s-web\n' "$lab" > "$state/instances"

out="$("$LAB_LXD" down --lab "$lab" 2>&1)" && rc=0 || rc=$?

# Guard the fixture before trusting the verdict: `down` exits 0 both when the engine
# refuses (the bug) and when it simply found nothing to do (a stand-in that was never
# consulted). Those are opposite facts with the same rc, so prove the driver actually
# reached the instance before reading anything into the exit status.
grep -q "stop+delete lab-${lab}-web" <<<"$out" \
    || fail "fixture: the driver never attempted the instance — the stand-in was not consulted, so this run says nothing about 'down'; output: $out"

(( rc != 0 )) \
    || fail "REGRESSION: 'down' exited 0 after the engine refused every stop and delete — a false success outranks an honest failure"
grep -q "PARTIALLY torn down" <<<"$out" \
    || fail "REGRESSION: 'down' did not report a partial teardown; got: $out"
grep -q "lab-${lab}-web" <<<"$out" \
    || fail "REGRESSION: 'down' did not NAME the instance that survived; got: $out"
grep -qE "── lab '$lab' torn down ──" <<<"$out" \
    && fail "REGRESSION: 'down' still printed the success banner after the engine refused everything"
note "'down' surfaces the engine's refusal instead of reporting success"

[[ -r "$spec" ]] \
    || fail "REGRESSION: 'down' deleted the cached spec.toml while the instance was still running — the record was discarded while its subject lives, so the lab can no longer be exported"
note "the cached spec survives a refused teardown"

# ── recovery: the engine starts cooperating and the same command completes ────────────
printf 'accept\n' > "$state/mode"
out="$("$LAB_LXD" down --lab "$lab" 2>&1)" && rc=0 || rc=$?
(( rc == 0 )) || fail "once the engine accepts, 'down' should succeed; rc=$rc, output: $out"
grep -q "torn down" <<<"$out" || fail "recovery run did not report success; got: $out"
[[ ! -e "$spec_dir" ]] \
    || fail "the state dir survived a teardown that finally succeeded — the record must go when its subject does"
note "recovery: with the engine cooperating, 'down' completes and only then clears the record"

# ── control: an empty lab is a clean teardown, not a partial one ──────────────────────
# Without this, "reports a partial teardown" could be true of every run — a check that
# always fires proves as little as one that never does.
lab2="${lab}b"
export STANDIN_LAB="$lab2"
: > "$state/instances"
mkdir -p "$LAB_STATE_DIR/lxd/$lab2"; printf '[lab]\nname = "%s"\n' "$lab2" > "$LAB_STATE_DIR/lxd/$lab2/spec.toml"
out="$("$LAB_LXD" down --lab "$lab2" 2>&1)" && rc=0 || rc=$?
(( rc == 0 )) || fail "control: a lab with no instances must tear down cleanly; rc=$rc, output: $out"
grep -q "torn down" <<<"$out" || fail "control: an empty lab did not report success; got: $out"
grep -q "PARTIALLY" <<<"$out" && fail "control: an empty lab was reported as a partial teardown"
[[ ! -e "$LAB_STATE_DIR/lxd/$lab2" ]] || fail "control: the state dir of an empty lab was not cleared"
note "control: a lab with nothing left tears down cleanly and clears its record"

pass "'down' surfaces a refused teardown and keeps the spec while the instance lives (P5-3)"

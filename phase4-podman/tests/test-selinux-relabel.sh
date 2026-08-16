#!/usr/bin/env bash
# Closes one of REVIEW-phase4.md §3b's two UNKNOWNs.
#
# The audit recorded: "SELinux-enforcing behaviour (check_selinux_label, the `:z` suffix
# logic) was not exercised — this host is not enforcing, so check_selinux_label returns
# empty and every relabel branch was dead during this audit."
#
# The host is still not enforcing, and that is not going to change. But "we cannot run
# this here" was doing more work than it deserved: `check_selinux_label` decides purely
# on what `getenforce` PRINTS, so the enforcing branch is reachable with a stub on PATH.
# That is not a weaker substitute for a Fedora box — the property under test is the
# driver's suffix logic, and this drives exactly that, through the real emitters.
#
# What it still does NOT prove is that ':z' makes a bind mount work under a real policy;
# that needs an enforcing host and remains UNKNOWN. Recorded so the two are not confused.
#
# Review M3 is the decision being guarded: default to ':z' (SHARED relabel), never ':Z'
# (PRIVATE, per-container MCS category), because ':Z' recursively relabels the host tree
# with a category the host itself can no longer access — pointing it at /home or /usr
# locks the host out of its own files.
#
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq
require_toml_parser
command -v podman >/dev/null 2>&1 || skip "podman not installed (generate requires the quadlet version check)"

tmp="$(mktemp -d)"; on_exit 'rm -rf "$tmp"'
bin="$tmp/bin"; mkdir -p "$bin"
export LAB_STATE_DIR="$tmp/state"
export XDG_CONFIG_HOME="$tmp/xdg"
qdir="$tmp/xdg/containers/systemd"
mkdir -p "$LAB_STATE_DIR" "$qdir"
[[ "$qdir" == "$tmp"/* ]] || fail "refusing to run: quadlet dir is not in the scratch tree"

cat > "$tmp/lab.toml" <<'TOML'
[lab]
name = "selab"

[[service]]
name    = "web"
image   = "alpine:latest"
volumes = ["/data:/data", "/priv:/priv:Z", "/shared:/shared:z", "/ovl:/ovl:O"]
TOML

unit="$qdir/lab-selab-web.container"

# ── control: not enforcing (this host, unstubbed) — no suffix is added ─────────────
"$LAB_PODMAN" generate --config "$tmp/lab.toml" >/dev/null 2>&1 \
    || fail "setup: 'generate' failed on the non-enforcing path"
mapfile -t vols < <(grep '^Volume=' "$unit" | sed 's/^Volume=//')
(( ${#vols[@]} == 4 )) || fail "expected 4 Volume= lines, got ${#vols[@]}: ${vols[*]}"
[[ "${vols[0]}" == "/data:/data" ]] \
    || fail "control: a plain bind mount gained a relabel suffix on a NON-enforcing host: ${vols[0]}"
note "control: not enforcing → no relabel suffix is added"

# ── the branch that was dead: SELinux reports Enforcing ────────────────────────────
printf '#!/usr/bin/env bash\nprintf "Enforcing\\n"\n' > "$bin/getenforce"
chmod +x "$bin/getenforce"
PATH="$bin:$PATH" "$LAB_PODMAN" generate --config "$tmp/lab.toml" >"$tmp/out.txt" 2>&1 \
    || fail "'generate' failed with SELinux reporting Enforcing: $(cat "$tmp/out.txt")"

mapfile -t vols < <(grep '^Volume=' "$unit" | sed 's/^Volume=//')
(( ${#vols[@]} == 4 )) || fail "expected 4 Volume= lines, got ${#vols[@]}: ${vols[*]}"

[[ "${vols[0]}" == "/data:/data:z" ]] \
    || fail "REGRESSION: an unsuffixed bind mount did not get the ':z' relabel under Enforcing; got '${vols[0]}'"
[[ "${vols[0]}" != *":Z" ]] \
    || fail "REGRESSION (Review M3): the default relabel is ':Z' (PRIVATE) — it recursively relabels the host tree with a category the host cannot access. It must be ':z' (shared)."
note "enforcing → a plain bind mount gets ':z' (shared), never ':Z'"

# An explicit suffix is the user's decision and must be honoured, not doubled.
[[ "${vols[1]}" == "/priv:/priv:Z" ]] || fail "an explicit ':Z' was not honoured verbatim; got '${vols[1]}'"
[[ "${vols[2]}" == "/shared:/shared:z" ]] || fail "an explicit ':z' was altered; got '${vols[2]}'"
[[ "${vols[3]}" == "/ovl:/ovl:O" ]] || fail "an explicit ':O' was altered; got '${vols[3]}'"
for v in "${vols[@]}"; do
    [[ "$v" != *:z:z && "$v" != *:Z:z && "$v" != *:O:z ]] \
        || fail "REGRESSION: a relabel suffix was appended to a mount that already had one: '$v'"
done
note "enforcing → explicit ':Z' / ':z' / ':O' are honoured verbatim, never doubled"

# The relabel is not silent: it rewrites what the user asked for, so it must say so.
grep -qi 'selinux' "$tmp/out.txt" \
    || fail "the driver relabeled a mount without telling the operator; output: $(cat "$tmp/out.txt")"
note "the relabel is announced, not silent"

# ── and the discriminator itself ───────────────────────────────────────────────────
# Permissive must behave like Disabled — only "Enforcing" enables the suffix.
export LAB_LOG_LEVEL=error
. "$LAB_PODMAN" 2>/dev/null || true
for mode in Permissive Disabled; do
    printf '#!/usr/bin/env bash\nprintf "%s\\n"\n' "$mode" > "$bin/getenforce"
    got="$(PATH="$bin:$PATH" check_selinux_label)"
    [[ -z "$got" ]] || fail "check_selinux_label returned '$got' for getenforce=$mode; only Enforcing may enable relabeling"
done
printf '#!/usr/bin/env bash\nprintf "Enforcing\\n"\n' > "$bin/getenforce"
[[ "$(PATH="$bin:$PATH" check_selinux_label)" == "z" ]] \
    || fail "check_selinux_label did not return 'z' for getenforce=Enforcing"
note "check_selinux_label: Enforcing → 'z'; Permissive and Disabled → empty"

pass "the SELinux relabel path is exercised: ':z' by default, explicit suffixes honoured (§3b)"

#!/usr/bin/env bash
# test-spec-placeholders.sh — lab-vm.sh must expand @LAB_DIR@ / @REPO@ / @NETBOOT@ when it
# parses a spec, so a tracked spec never has to name one machine's filesystem.
#
# WHY (TODO 15.10). TOML has no shell expansion, so specs needing an absolute path wrote
# one in — and it was wrong twice before anything looked. One named /home/user/mklab/…,
# nobody's home directory on any machine, from the day it was written (15.7); nineteen more
# named this checkout, which is false everywhere else, as CI demonstrated the same day on a
# lab built with a checker instead of a placeholder. A value that is false on every machine
# but one is not rescued by checking it.
#
# WHAT IS ASSERTED IS THE OUTCOME — the JSON the rest of the driver reads — not that the
# substitution function exists. And the negative control matters as much: a spec with NO
# placeholder must come through byte-identical, or "expansion works" would be equally true
# of a driver that rewrites paths it was never asked to touch.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
set +e                # the checks below capture values explicitly

require_cmd jq
# One TOML parser must exist for toml_to_json to do anything at all; without one the
# driver dies by name and this test would be asserting nothing.
command -v tomlq >/dev/null 2>&1 || command -v yq >/dev/null 2>&1 || command -v dasel >/dev/null 2>&1 \
    || skip "no TOML parser (tomlq/yq/dasel) — toml_to_json cannot run, so expansion cannot be observed"

TMP="$(mktemp -d)"; on_exit 'rm -rf -- "$TMP"'
REPO_ROOT="$(cd -- "$TEST_DIR/../.." && pwd)"

# shellcheck disable=SC1090,SC2034
source "$LAB_VM" >/dev/null 2>&1 || true   # sourcing defines toml_to_json; argv is not run

cat > "$TMP/spec.toml" <<'SPEC'
[[vm]]
name    = "ph"
backend = "kernel+initrd"
arch    = "x86_64"
kernel  = "@LAB_DIR@/k"
initrd  = "@REPO@/micro-linux/out/x86_64/initramfs.cpio.gz"
pxe_dir = "@NETBOOT@"
SPEC

json="$(LAB_NETBOOT_DIR="$TMP/nb" toml_to_json "$TMP/spec.toml" 2>/dev/null)"
[[ -n "$json" ]] || fail "toml_to_json produced nothing for a well-formed spec — the parser or the expansion broke"

got_kernel="$(jq -r '.vm[0].kernel'  <<<"$json")"
got_initrd="$(jq -r '.vm[0].initrd'  <<<"$json")"
got_pxe="$(   jq -r '.vm[0].pxe_dir' <<<"$json")"

[[ "$got_kernel" == "$TMP/k" ]] \
    || fail "@LAB_DIR@ did not expand to the spec's OWN directory: want '$TMP/k', got '$got_kernel'"
[[ "$got_initrd" == "$REPO_ROOT/micro-linux/out/x86_64/initramfs.cpio.gz" ]] \
    || fail "@REPO@ did not expand to the repo root: want '$REPO_ROOT/micro-linux/…', got '$got_initrd'"
[[ "$got_pxe" == "$TMP/nb" ]] \
    || fail "@NETBOOT@ did not honour \$LAB_NETBOOT_DIR: want '$TMP/nb', got '$got_pxe'. A spec that cannot follow the env override carries a second copy of where the netboot dir lives"
note "all three placeholders expand: @LAB_DIR@ → the spec's directory, @REPO@ → the repo, @NETBOOT@ → \$LAB_NETBOOT_DIR"

# @NETBOOT@ must fall back to ~/netboot when the variable is unset — that is the default
# every existing spec relied on when it wrote /home/<someone>/netboot by hand.
got_default="$(env -u LAB_NETBOOT_DIR bash -c "source '$LAB_VM' >/dev/null 2>&1; toml_to_json '$TMP/spec.toml'" 2>/dev/null | jq -r '.vm[0].pxe_dir')"
[[ "$got_default" == "$HOME/netboot" ]] \
    || fail "with \$LAB_NETBOOT_DIR unset, @NETBOOT@ must fall back to ~/netboot; got '$got_default'"
note "unset \$LAB_NETBOOT_DIR falls back to ~/netboot"

# ── THE NEGATIVE CONTROL: a spec with no placeholder must be untouched ──────────────────
# Without this, "expansion works" is equally true of a driver that rewrites paths nobody
# asked it to touch — and a path silently rewritten is worse than one that is wrong.
cat > "$TMP/plain.toml" <<'PLAIN'
[[vm]]
name    = "plain"
backend = "kernel+initrd"
arch    = "x86_64"
kernel  = "/var/lib/lab-create/cache/vmlinuz"
initrd  = "/var/lib/lab-create/cache/initramfs.gz"
PLAIN
plain="$(toml_to_json "$TMP/plain.toml" 2>/dev/null)"
[[ "$(jq -r '.vm[0].kernel' <<<"$plain")" == "/var/lib/lab-create/cache/vmlinuz" ]] \
    || fail "a spec with NO placeholder came back changed — the expansion is rewriting paths it was not asked to touch"
note "control: a spec with no placeholder is passed through unchanged"

# ── and the awk replacement must be literal ─────────────────────────────────────────────
# In awk's gsub an unescaped `&` in the REPLACEMENT expands to the matched text, and a
# backslash escapes — so a checkout path containing either would splice itself into the
# output. This repo has been bitten by exactly that (a `2>&1` in a replacement spliced the
# match back into itself), so it is measured rather than assumed.
odd="$TMP/a&b"; mkdir -p "$odd"
cp "$TMP/spec.toml" "$odd/spec.toml"
odd_json="$(LAB_NETBOOT_DIR="$TMP/nb" toml_to_json "$odd/spec.toml" 2>/dev/null)"
[[ "$(jq -r '.vm[0].kernel' <<<"$odd_json")" == "$odd/k" ]] \
    || fail "a directory containing '&' was mangled by the substitution: want '$odd/k', got '$(jq -r '.vm[0].kernel' <<<"$odd_json")' — the awk replacement is not being escaped"
note "control: a directory containing '&' survives the substitution intact"

pass "lab-vm.sh expands @LAB_DIR@, @REPO@ and @NETBOOT@ (honouring \$LAB_NETBOOT_DIR, falling back to ~/netboot) into the JSON the driver reads, leaves a spec with no placeholder byte-identical, and survives a path containing the one character awk's gsub replacement treats specially"

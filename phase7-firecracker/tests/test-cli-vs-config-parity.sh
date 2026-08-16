#!/usr/bin/env bash
# REGRESSION (REVIEW-phase7.md §3): the two entry points did not describe the same schema,
# and the tool's own tripwire is aimed at exactly this.
#
#   lab-fc.sh's header:  "a config key that is silently dropped is a field that
#                         appears to work and does nothing"
#
# Measured:
#   * `--lab MY-OWN-LAB` was parsed into a variable and thrown away by `: "$force" "$lab"`.
#     The manifest said `lab = "micro-cloud"` — the DEFAULT — and nothing said otherwise.
#   * `--mac` and `--netmask` were `KNOWN_KEYS` with no flag at all, so a spec expressible
#     in TOML could not be expressed on the command line.
#   * `--force` was in USAGE for `stop` and `destroy`, recommended by `stop`'s own failure
#     message, passed by micro-cloud's cleanup — and discarded. (Its behaviour is asserted
#     in test-lifecycle-asserts-the-outcome.sh; here we only care that it is not dropped.)
#
# ── THE LIST IS DERIVED, NOT TYPED ────────────────────────────────────────────────────
# `KNOWN_KEYS` is read out of the driver, so a key added later WITHOUT a flag fails this
# test instead of being noticed by someone. A hand-copied list here would be a second
# source of truth that goes stale silently — which is the defect being fixed, one level up.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")   # NOT a second EXIT trap — see lib.sh
fc_fixtures
export LAB_STATE_DIR="$tmp/state"

keys="$(sed -n 's/^readonly KNOWN_KEYS="\(.*\)"$/\1/p' "$LAB_FC")"
[[ -n "$keys" ]] || fail "could not read KNOWN_KEYS out of $LAB_FC — this test cannot derive its subject"
note "KNOWN_KEYS as the driver defines them: $keys"

# ── 1. every schema key has a flag ────────────────────────────────────────────────────
# `ip` is spelled `--ip`; everything else is `--<key>`. An unknown flag is a hard `die`, so
# the probe is simply "does the parser accept it?" — nothing needs to be valid past that.
missing=()
for k in $keys; do
    case "$k" in
        mmds) probe=(--mmds) ;;                 # boolean, takes no argument
        *)    probe=("--$k" X) ;;
    esac
    run_fc "$tmp/f.out" preflight "${probe[@]}" --name t1 \
        --kernel /nonexistent/vmlinux --rootfs /nonexistent/rootfs.ext4 || true
    grep -q "unknown flag: --$k" "$tmp/f.out" && missing+=("$k")
done
(( ${#missing[@]} == 0 )) \
    || fail "REGRESSION: [[microvm]] key(s) with no CLI flag: ${missing[*]} — a spec expressible in the config cannot be expressed on the command line (§3)"
note "all $(printf '%s\n' $keys | wc -l) schema keys are reachable from the CLI"

# ── 2. and every flag REACHES THE RECORD ──────────────────────────────────────────────
# Being parsed is not being used: `--lab` was parsed for months. The manifest is the
# observable, so this creates for real and reads what was written.
n="p7par$$"
run_fc "$tmp/c.out" create --name "$n" --kernel "$FC_K" --rootfs "$FC_R" \
    --lab MY-OWN-LAB --memory 128M --vcpus 2 \
    || { cat "$tmp/c.out" >&2; fail "create refused a spec built from this test's own fixtures"; }
man="$LAB_STATE_DIR/fc/$n/manifest.toml"
[[ -r "$man" ]] || fail "create reported success but wrote no manifest"

got="$(sed -n 's/^lab = "\(.*\)"$/\1/p' "$man")"
[[ "$got" == "MY-OWN-LAB" ]] \
    || fail "REGRESSION: --lab MY-OWN-LAB was accepted and discarded; the manifest says lab = \"$got\" (§3)"
note "--lab reaches the manifest instead of being silently replaced by the default"

# The value that came from the flag has to be distinguishable from the default, or this
# assertion could pass on a tool that ignores the flag and happens to default to the same
# thing. Prove the default is different.
n2="${n}b"
run_fc "$tmp/c2.out" create --name "$n2" --kernel "$FC_K" --rootfs "$FC_R" || fail "create (no --lab) failed"
def="$(sed -n 's/^lab = "\(.*\)"$/\1/p' "$LAB_STATE_DIR/fc/$n2/manifest.toml")"
[[ "$def" != "MY-OWN-LAB" ]] \
    || fail "control: the DEFAULT lab is also 'MY-OWN-LAB', so the assertion above cannot tell a threaded flag from a dropped one"
note "control: the default is '$def', so the row above is evidence and not a coincidence"

# --memory and --vcpus, which were threaded, still are — a rewrite of the record builder is
# exactly the kind of change that would drop one.
run_fc "$tmp/i.out" inspect "$n" || fail "inspect failed"
grep -q '"mem_size_mib": 128' "$LAB_STATE_DIR/fc/$n/config.json" \
    || fail "--memory 128M did not reach the generated config: $(grep mem_size "$LAB_STATE_DIR/fc/$n/config.json")"
grep -q '"vcpu_count": 2' "$LAB_STATE_DIR/fc/$n/config.json" \
    || fail "--vcpus 2 did not reach the generated config: $(grep vcpu "$LAB_STATE_DIR/fc/$n/config.json")"
note "--memory and --vcpus still reach the generated config"

# ── 3. the same spec, written both ways, produces the same config ────────────────────
# The strongest form of the parity question, and the one Phase 1 asks: not "is each flag
# handled" but "do the two entry points describe the same machine".
{   printf '[[microvm]]\nname = "%s"\n' "${n}c"
    printf 'kernel = "%s"\nrootfs = "%s"\n' "$FC_K" "$FC_R"
    printf 'memory = "128M"\nvcpus = 2\nappend = "mc_name=x"\nlab = "MY-OWN-LAB"\n'
} > "$tmp/same.toml"
run_fc "$tmp/tomlgen.out" create --dry-run --config "$tmp/same.toml" \
    || { cat "$tmp/tomlgen.out" >&2; fail "create --dry-run refused the TOML spelling"; }
run_fc "$tmp/cligen.out" create --dry-run --name "${n}c" --kernel "$FC_K" --rootfs "$FC_R" \
    --memory 128M --vcpus 2 --append 'mc_name=x' --lab MY-OWN-LAB \
    || { cat "$tmp/cligen.out" >&2; fail "create --dry-run refused the CLI spelling of the same spec"; }
sed -n '/^{/,/^}/p' "$tmp/tomlgen.out" > "$tmp/a.json"
sed -n '/^{/,/^}/p' "$tmp/cligen.out" > "$tmp/b.json"
[[ -s "$tmp/a.json" ]] || fail "the TOML run produced no config block"
if ! diff -q "$tmp/a.json" "$tmp/b.json" >/dev/null; then
    diff "$tmp/a.json" "$tmp/b.json" >&2 || true
    fail "REGRESSION: the same spec written as TOML and as flags generates DIFFERENT configs — the two entry points do not describe one schema (§3)"
fi
note "one spec, two spellings, byte-identical config.json"

# ...and the provenance tables must agree too, since that is the tool's actual product.
grep -E '^  (YOURS|DEFAULT|DERIVED|APPENDED|REFUSED) ' "$tmp/tomlgen.out" > "$tmp/a.prov"
grep -E '^  (YOURS|DEFAULT|DERIVED|APPENDED|REFUSED) ' "$tmp/cligen.out" > "$tmp/b.prov"
[[ -s "$tmp/a.prov" ]] || fail "the TOML run printed no provenance rows"
diff -q "$tmp/a.prov" "$tmp/b.prov" >/dev/null \
    || { diff "$tmp/a.prov" "$tmp/b.prov" >&2 || true; fail "REGRESSION: the provenance tables differ between the two spellings — one of them is reporting a field as YOURS that the other calls DEFAULT"; }
note "$(wc -l < "$tmp/a.prov") provenance rows, byte-identical between the two spellings"

run_fc "$tmp/x1.out" destroy "$n"  || fail "cleanup: destroy $n failed"
run_fc "$tmp/x2.out" destroy "$n2" || fail "cleanup: destroy $n2 failed"

pass "every [[microvm]] key has a flag, every flag reaches the record, and one spec written both ways generates the identical config and provenance (§3)"

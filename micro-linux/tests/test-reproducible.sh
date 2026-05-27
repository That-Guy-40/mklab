#!/usr/bin/env bash
# Reproducible builds (plan §8 / REPRODUCIBLE.md): the determinism knobs must be
# pinned in versions.env AND wired into the build, so two clean builds yield
# byte-identical artifacts.  Network-free static checks; a functional check runs
# only if a built kernel is already present.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
source "$MLBUILD"

# (1) versions.env pins the determinism inputs.
# shellcheck source=/dev/null
source "$TEST_DIR/../versions.env"
[[ "${SOURCE_DATE_EPOCH:-}" =~ ^[0-9]+$ ]] || fail "versions.env does not pin a numeric SOURCE_DATE_EPOCH"
[[ -n "${KBUILD_BUILD_USER:-}" ]] || fail "versions.env does not pin KBUILD_BUILD_USER"
[[ -n "${KBUILD_BUILD_HOST:-}" ]] || fail "versions.env does not pin KBUILD_BUILD_HOST"
note "versions.env pins SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH, USER=$KBUILD_BUILD_USER, HOST=$KBUILD_BUILD_HOST"

# (2) export_repro_env derives + exports KBUILD_BUILD_TIMESTAMP from the epoch.
export_repro_env
[[ -n "${KBUILD_BUILD_TIMESTAMP:-}" ]] || fail "export_repro_env did not set KBUILD_BUILD_TIMESTAMP"
note "export_repro_env → KBUILD_BUILD_TIMESTAMP='$KBUILD_BUILD_TIMESTAMP'"

# (3) the build wires it: both inner entrypoints export the env, and the cpio
#     packer pins entry mtimes with -t (else gen_init_cpio stamps time(NULL)).
for fn in inner_build inner_pack; do
    body="$(sed -n "/^${fn}()/,/^}/p" "$MLBUILD")"
    grep -q 'export_repro_env' <<<"$body" || fail "$fn() does not call export_repro_env"
done
grep -qF -- '-t "${SOURCE_DATE_EPOCH' "$MLBUILD" \
    || fail "pack does not pin gen_init_cpio mtimes with -t SOURCE_DATE_EPOCH (cpio would float)"
note "inner_build/inner_pack export the env; gen_init_cpio is pinned with -t"

# (4) functional: a built kernel must embed the pinned identity (skip if absent).
k="$TEST_DIR/../out/x86_64/kernel"
if [[ -f "$k" ]] && have file; then
    file "$k" | grep -qF "($KBUILD_BUILD_USER@$KBUILD_BUILD_HOST)" \
        || fail "built x86_64 kernel lacks the pinned ($KBUILD_BUILD_USER@$KBUILD_BUILD_HOST) build identity"
    note "built x86_64 kernel embeds ($KBUILD_BUILD_USER@$KBUILD_BUILD_HOST)"
else
    note "no built kernel present — functional identity check skipped (static checks passed)"
fi

pass "reproducible-build determinism is pinned + wired"

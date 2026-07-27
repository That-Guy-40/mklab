#!/usr/bin/env bash
# test-be-logic.sh — verify be.sh emits the CORRECT ZFS/ZFSBootMenu command
# plan, with no real pool.  be.sh routes every side effect through $ZFS/$ZPOOL
# and BE_DRYRUN=1 prints the plan instead of running it, so the boot-environment
# *logic* is checkable on a host with no ZFS.  (The *effects* run under KVM per
# RUNBOOK-boot-environments.md.)  This is the host-safe half of the lab.
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
arm_exit_trap

BE="$LAB_DIR/be.sh"
[[ -x "$BE" ]] || fail "be.sh not found or not executable at $BE"

# Deterministic, pool-free environment for the plan.
export BE_DRYRUN=1 ZBM_POOL=rpool BE_SNAPSHOT_TAG=preupgrade BE_ACTIVE=default

# Grab a command's dry-run plan (stdout only; notes go to stderr).
plan() { "$BE" "$@" 2>/dev/null; }
have() { grep -Fq -- "$2" <<<"$1"; }

# 1. create — must snapshot the source BE, then clone with the two properties
#    that make a ZFS dataset a bootable, non-auto-mounting boot environment.
out="$(plan create -e default testupgrade)"
have "$out" 'zfs snapshot rpool/ROOT/default@preupgrade' \
    || fail "REGRESSION: create did not snapshot the source BE before cloning"
have "$out" 'canmount=noauto' \
    || fail "REGRESSION: cloned BE missing canmount=noauto (would auto-mount and fight the booted root)"
have "$out" 'mountpoint=/' \
    || fail "REGRESSION: cloned BE missing mountpoint=/ (would not mount as the root filesystem)"
if ! { have "$out" 'zfs clone' && have "$out" 'rpool/ROOT/testupgrade'; }; then
    fail "REGRESSION: create did not clone into rpool/ROOT/testupgrade"
fi
note "create: snapshot + clone -o canmount=noauto -o mountpoint=/  ✓"

# 2. create with no -e must default the source to the active BE.
out="$(plan create fromactive)"
have "$out" 'zfs snapshot rpool/ROOT/default@preupgrade' \
    || fail "create without -e did not default the source to the active BE (default)"
note "create (no -e): sources the active BE  ✓"

# 3. activate — the whole 'bectl activate' mechanism is one pool property.
out="$(plan activate testupgrade)"
have "$out" 'zpool set bootfs=rpool/ROOT/testupgrade rpool' \
    || fail "REGRESSION: activate did not set the pool bootfs to the new BE"
note "activate: zpool set bootfs=...  ✓"

# 4. cmdline — per-BE kernel command line via the ZBM property.
out="$(plan cmdline testupgrade 'quiet loglevel=4 rw')"
have "$out" 'org.zfsbootmenu:commandline=' \
    || fail "REGRESSION: cmdline did not set org.zfsbootmenu:commandline"
have "$out" 'rpool/ROOT/testupgrade' \
    || fail "cmdline set the property on the wrong dataset"
note "cmdline: org.zfsbootmenu:commandline=...  ✓"

# 5. snapshot + rollback — the recover-in-place path.
out="$(plan snapshot default known-good)"
have "$out" 'zfs snapshot rpool/ROOT/default@known-good' \
    || fail "snapshot did not create rpool/ROOT/default@known-good"
out="$(plan rollback default known-good)"
have "$out" 'zfs rollback rpool/ROOT/default@known-good' \
    || fail "rollback did not roll rpool/ROOT/default back to @known-good"
note "snapshot + rollback  ✓"

# 6. rename maps into the BE container.
out="$(plan rename old new)"
have "$out" 'zfs rename rpool/ROOT/old rpool/ROOT/new' \
    || fail "rename did not map OLD/NEW under the BE container rpool/ROOT"
note "rename  ✓"

# 7. Guardrails: missing NAME must be refused (a die, contained in a subshell so
#    its exit can't blow past this test — the CLAUDE.md silent-exit trap).
if ( "$BE" create 2>/dev/null ); then
    fail "create with no NAME should have been rejected but succeeded"
fi
note "guardrail: create with no NAME is rejected  ✓"

pass "be.sh emits the correct ZFS + ZFSBootMenu boot-environment command plan"

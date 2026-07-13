#!/usr/bin/env bash
#
# be.sh — FreeBSD-style boot environments for Linux, over ZFS + ZFSBootMenu.
#
# This is the Linux answer to FreeBSD's bectl(8)/beadm.  A "boot environment"
# (BE) is a bootable ZFS filesystem holding one coupled snapshot of the OS:
# kernel, /usr, /etc, everything critical to boot.  Because BEs are ZFS clones
# they are copy-on-write — creating one is instant and near-free, and you can
# reboot into any of them and pick it from the ZFSBootMenu menu.
#
# The layout this tool assumes (the ZFSBootMenu convention):
#
#     <pool>/ROOT                 canmount=off  mountpoint=/    (the BE container)
#     <pool>/ROOT/<name>          canmount=noauto mountpoint=/  (one boot environment)
#
# Only one BE mounts as / at a time (canmount=noauto → nothing auto-mounts;
# the booted BE is mounted by the initramfs).  Persistent data (/home, …) lives
# in SEPARATE datasets outside <pool>/ROOT so it survives across BEs.
#
# ZFSBootMenu picks what to boot from two properties:
#   * the pool's `bootfs` property  → the default BE
#   * `org.zfsbootmenu:commandline` → that BE's kernel command line
# See ../zfsbootmenu-boot-environments/RUNBOOK-boot-environments.md for the why.
#
# ── Testability ──────────────────────────────────────────────────────────────
# Every side effect goes through the `zfs`/`zpool` commands named by $ZFS/$ZPOOL
# (default `zfs`/`zpool`).  With BE_DRYRUN=1 nothing runs — each command is
# printed with a leading "+ " so the exact plan can be inspected (and asserted
# by tests/test-be-logic.sh, which needs no real pool).  This is how the BE
# *logic* is verified on a host with no ZFS; the *effects* are exercised under
# KVM per the RUNBOOK.
#
# Usage:
#   be.sh [--pool POOL] [--dry-run] <command> [args]
#
#   list                       List boot environments (active one marked '*').
#   create [-e SRC] NAME       Clone a new BE NAME from a snapshot of SRC
#                              (SRC defaults to the active BE).
#   activate NAME              Make NAME the default BE (sets pool bootfs).
#   destroy NAME               Destroy BE NAME (refuses the active one).
#   rename OLD NEW             Rename BE OLD to NEW.
#   snapshot NAME [TAG]        Snapshot BE NAME (TAG defaults to a timestamp).
#   rollback NAME TAG          Roll BE NAME back to snapshot @TAG (destructive).
#   cmdline NAME "ARGS"        Set NAME's kernel command line (org.zfsbootmenu:).
#
# Env knobs:
#   ZBM_POOL       Pool name.  Default: the pool owning the current `bootfs`.
#   ZBM_ROOT       BE container dataset.  Default: $ZBM_POOL/ROOT.
#   BE_SNAPSHOT_TAG  Snapshot tag for `create`/`snapshot`.  Default: timestamp.
#   BE_DRYRUN=1    Print commands instead of running them.
#   ZFS / ZPOOL    Override the zfs/zpool binaries (for stubbing in tests).
#
set -euo pipefail

ZFS="${ZFS:-zfs}"
ZPOOL="${ZPOOL:-zpool}"
PROG="${0##*/}"

die()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }
note() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# run — the single choke point for every state change.  In dry-run it echoes a
# copy-pasteable command line (leading "+ ") to stdout; otherwise it execs.
run() {
    if [[ "${BE_DRYRUN:-0}" == 1 ]]; then
        printf '+'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# Resolve the pool.  Explicit $ZBM_POOL wins; otherwise ask ZFS which pool owns
# the active bootfs (skipped in dry-run so tests need no pool).
resolve_pool() {
    if [[ -n "${ZBM_POOL:-}" ]]; then
        printf '%s' "$ZBM_POOL"; return
    fi
    if [[ "${BE_DRYRUN:-0}" == 1 ]]; then
        die "no pool: set ZBM_POOL (or run against a real pool without --dry-run)"
    fi
    local bootfs
    bootfs="$("$ZPOOL" list -H -o bootfs 2>/dev/null | grep -v '^-\?$' | head -n1)" \
        || die "could not read any pool's bootfs property"
    [[ -n "$bootfs" && "$bootfs" != "-" ]] \
        || die "no pool has a bootfs set; pass --pool or set ZBM_POOL"
    printf '%s' "${bootfs%%/*}"
}

# The BE container dataset ($pool/ROOT unless ZBM_ROOT overrides).
root_ds() {
    if [[ -n "${ZBM_ROOT:-}" ]]; then printf '%s' "$ZBM_ROOT"; return; fi
    printf '%s/ROOT' "$(resolve_pool)"
}

snap_tag() { printf '%s' "${BE_SNAPSHOT_TAG:-$(date +%Y%m%d-%H%M%S)}"; }

cmd_list() {
    local root; root="$(root_ds)"
    local pool; pool="${root%%/*}"
    note "boot environments under $root  ('*' = default/bootfs)"
    local active=""
    if [[ "${BE_DRYRUN:-0}" != 1 ]]; then
        active="$("$ZPOOL" get -H -o value bootfs "$pool" 2>/dev/null || true)"
    fi
    # name / used / creation / kernel cmdline — the BE-relevant columns.
    run "$ZFS" list -H -o name,used,creation,org.zfsbootmenu:commandline \
        -r "$root"
    [[ -n "$active" ]] && note "default (bootfs): $active"
    return 0
}

cmd_create() {
    local src=""
    while [[ "${1:-}" == -* ]]; do
        case "$1" in
            -e) src="$2"; shift 2 ;;
            *)  die "create: unknown flag $1" ;;
        esac
    done
    local name="${1:-}"; [[ -n "$name" ]] || die "create: NAME required"
    local root; root="$(root_ds)"
    local pool; pool="${root%%/*}"

    # Default source = the active BE (whatever bootfs points at).
    if [[ -z "$src" ]]; then
        if [[ "${BE_DRYRUN:-0}" == 1 ]]; then
            src="${BE_ACTIVE:-default}"     # deterministic for tests
        else
            local bootfs
            bootfs="$("$ZPOOL" get -H -o value bootfs "$pool")"
            [[ "$bootfs" == "$root/"* ]] || die "active bootfs ($bootfs) is not under $root"
            src="${bootfs#"$root"/}"
        fi
    fi

    local src_ds="$root/$src"
    local new_ds="$root/$name"
    local tag; tag="$(snap_tag)"

    note "cloning new BE '$name' from a snapshot of '$src'"
    run "$ZFS" snapshot "${src_ds}@${tag}"
    # canmount=noauto so it never auto-mounts; mountpoint=/ so it IS a root FS
    # when the initramfs mounts it.  Inheriting these from ROOT also works, but
    # setting them explicitly keeps a clone standalone and self-documenting.
    run "$ZFS" clone -o canmount=noauto -o mountpoint=/ \
        "${src_ds}@${tag}" "$new_ds"
    note "created $new_ds — activate it with:  $PROG activate $name"
}

cmd_activate() {
    local name="${1:-}"; [[ -n "$name" ]] || die "activate: NAME required"
    local root; root="$(root_ds)"
    local pool; pool="${root%%/*}"
    note "setting default boot environment to '$name'"
    # ZFSBootMenu boots the pool's bootfs by default — this is the whole
    # 'bectl activate' mechanism.
    run "$ZPOOL" set "bootfs=$root/$name" "$pool"
}

cmd_destroy() {
    local name="${1:-}"; [[ -n "$name" ]] || die "destroy: NAME required"
    local root; root="$(root_ds)"
    local pool; pool="${root%%/*}"
    if [[ "${BE_DRYRUN:-0}" != 1 ]]; then
        local bootfs
        bootfs="$("$ZPOOL" get -H -o value bootfs "$pool")"
        [[ "$bootfs" == "$root/$name" ]] \
            && die "refusing to destroy the active BE '$name' (activate another first)"
    fi
    note "destroying boot environment '$name'"
    run "$ZFS" destroy -r "$root/$name"
}

cmd_rename() {
    local old="${1:-}" new="${2:-}"
    [[ -n "$old" && -n "$new" ]] || die "rename: OLD NEW required"
    local root; root="$(root_ds)"
    run "$ZFS" rename "$root/$old" "$root/$new"
}

cmd_snapshot() {
    local name="${1:-}"; [[ -n "$name" ]] || die "snapshot: NAME required"
    local tag="${2:-$(snap_tag)}"
    local root; root="$(root_ds)"
    note "snapshotting '$name' as @$tag"
    run "$ZFS" snapshot "$root/$name@$tag"
}

cmd_rollback() {
    local name="${1:-}" tag="${2:-}"
    [[ -n "$name" && -n "$tag" ]] || die "rollback: NAME TAG required"
    local root; root="$(root_ds)"
    note "rolling '$name' back to @$tag (discards changes since the snapshot)"
    run "$ZFS" rollback "$root/$name@$tag"
}

cmd_cmdline() {
    local name="${1:-}" args="${2:-}"
    [[ -n "$name" ]] || die "cmdline: NAME required"
    local root; root="$(root_ds)"
    # Do NOT include root= in ARGS: ZFSBootMenu injects root=zfs:<this BE>.  A
    # hard-coded root= here (or inherited into a clone) would boot the wrong
    # dataset.  This sets a per-BE OVERRIDE; the shared default lives on the
    # rpool/ROOT container (see RUNBOOK-boot-environments.md).
    note "setting kernel command line for '$name' (ZBM adds root= itself)"
    run "$ZFS" set "org.zfsbootmenu:commandline=$args" "$root/$name"
}

main() {
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --pool)    ZBM_POOL="$2"; shift 2 ;;
            --dry-run) BE_DRYRUN=1; shift ;;
            --help|-h) sed -n '2,45p' "$0"; exit 0 ;;
            --) shift; break ;;
            *)  die "unknown option $1" ;;
        esac
    done
    local cmd="${1:-}"; [[ -n "$cmd" ]] || { sed -n '2,45p' "$0"; exit 1; }
    shift
    case "$cmd" in
        list)     cmd_list "$@" ;;
        create)   cmd_create "$@" ;;
        activate) cmd_activate "$@" ;;
        destroy)  cmd_destroy "$@" ;;
        rename)   cmd_rename "$@" ;;
        snapshot) cmd_snapshot "$@" ;;
        rollback) cmd_rollback "$@" ;;
        cmdline)  cmd_cmdline "$@" ;;
        *)        die "unknown command '$cmd' (try --help)" ;;
    esac
}

main "$@"

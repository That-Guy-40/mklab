#!/usr/bin/env bash
# Unit test: build_nspawn_args maps the nspawn network/bind_ro/capabilities keys
# to the right systemd-nspawn flags, and the manifest round-trips JSON arrays.
# Network-free, no root — sources the script (via its guard) and inspects the
# NSPAWN_ARGS array; never invokes systemd-nspawn.
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq

export LAB_STATE_DIR; LAB_STATE_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$LAB_STATE_DIR'" EXIT
# shellcheck disable=SC1090
source "$LAB_CHROOT"

joined() { printf '%s' "${NSPAWN_ARGS[*]}"; }
has() { grep -Fq -- "$2" <<<"$1"; }

# veth + two read-only binds + two capabilities
build_nspawn_args /srv/x true veth '["/etc/hosts","/data"]' '["CAP_NET_ADMIN","CAP_SYS_PTRACE"]'
a="$(joined)"
has "$a" '-D /srv/x'        || fail "missing -D target: $a"
has "$a" '-b'               || fail "boot=true should add -b: $a"
has "$a" '--network-veth'   || fail "network=veth → --network-veth: $a"
has "$a" '--bind-ro=/etc/hosts' || fail "bind_ro[0] not applied: $a"
has "$a" '--bind-ro=/data'  || fail "bind_ro[1] not applied: $a"
has "$a" '--capability=CAP_NET_ADMIN,CAP_SYS_PTRACE' || fail "capabilities not joined: $a"
note "veth + binds + caps → $a"

# host network (default): just -D target, no --network/--bind/--capability
build_nspawn_args /srv/y false "" '[]' '[]'; a="$(joined)"
[[ "$a" == "-D /srv/y" ]] || fail "host net should be just '-D target', got: $a"
note "host net → $a"

# private and bridge mappings
build_nspawn_args /srv/z false none '[]' '[]'
has "$(joined)" '--private-network' || fail "network=none → --private-network"
build_nspawn_args /srv/b false br0 '[]' '[]'
has "$(joined)" '--network-bridge=br0' || fail "unknown net string → --network-bridge=<name>"
note "private + bridge mappings OK"

# Manifest round-trip: append_manifest_raw stores a JSON array that
# read_manifest_field returns verbatim and jq can parse back (incl. a space).
mkdir -p "$LAB_CHROOT_STATE_DIR"
mname="rt$$"; : > "$(manifest_path "$mname")"
append_manifest_raw "$mname" nspawn_bind_ro '["/a","/b c"]'
got="$(read_manifest_field "$mname" nspawn_bind_ro)"
[[ "$(jq -r '.[1]' <<<"$got")" == "/b c" ]] \
    || fail "manifest JSON-array round-trip failed: '$got'"
note "manifest round-trips JSON arrays: $got"

pass "build_nspawn_args + manifest round-trip OK"

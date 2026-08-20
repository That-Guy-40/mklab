#!/usr/bin/env bash
# The `vsock` key: a first-class device in the spec, not something a caller hand-writes.
#
# WHY IT IS A KEY AND NOT A NOTE IN A README. Before this, the only way to give a microVM a
# vsock was to write config.json yourself and launch Firecracker directly — which slice 5c's
# own test does, and which means the DRIVER had never emitted the device. A channel the lab
# documents but the driver cannot configure is a channel every consumer has to re-implement,
# and each of them gets to rediscover the 108-byte sockaddr_un cap on their own.
#
# Everything here runs `create --dry-run` and parses stdout. Nothing boots, so it runs in CI.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd python3
tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")   # NOT a second EXIT trap — see lib.sh
fc_fixtures; K="$FC_K"; R="$FC_R"

cfg_of() {  # cfg_of <outfile> -> the JSON object on stdout
    sed -n '/^{/,/^}/p' "$1"
}

# ── 1. the device is emitted, and the config is still JSON ──────────────────────────────
run_fc "$tmp/v.out" create --dry-run --name vk1 --kernel "$K" --rootfs "$R" --vsock \
    || { cat "$tmp/v.out" >&2; fail "create --dry-run refused a spec whose only addition is --vsock"; }
cfg_of "$tmp/v.out" > "$tmp/v.json"
python3 - "$tmp/v.json" <<'PY' || fail "the config generated with --vsock is not valid JSON, or its vsock object is malformed"
import json,sys
c=json.load(open(sys.argv[1]))
v=c.get("vsock")
assert v is not None, "no 'vsock' object in the generated config"
assert isinstance(v.get("guest_cid"), int), f"guest_cid is not an integer: {v.get('guest_cid')!r}"
assert isinstance(v.get("uds_path"), str) and v["uds_path"], "uds_path missing or empty"
assert v["guest_cid"] >= 3, f"guest_cid {v['guest_cid']} is in the kernel's reserved range (0,1,2)"
assert len(v["uds_path"]) <= 100, (
    f"uds_path is {len(v['uds_path'])} bytes; sockaddr_un.sun_path is 108 INCLUDING the NUL, "
    "and going over it produces an error that reads like a vsock fault")
PY
note "--vsock emits a vsock device with an integer guest_cid and a uds_path inside the 108-byte cap"

# ── 2. THE CONTROL FOR §1: without the flag there is no device at all ───────────────────
# Without this, §1 would pass just as happily against a driver that emitted a vsock object
# unconditionally — and "the flag works" would be indistinguishable from "the flag is ignored".
run_fc "$tmp/n.out" create --dry-run --name vk1 --kernel "$K" --rootfs "$R" \
    || { cat "$tmp/n.out" >&2; fail "create --dry-run refused the same spec WITHOUT --vsock"; }
grep -q '"vsock"' "$tmp/n.out" \
    && fail "a config generated WITHOUT --vsock still carries a vsock device — §1 proves nothing, since the object appears either way"
note "control: without --vsock there is no vsock object, so §1 is measuring the flag"

# ── 3. the CID is derived from the NAME, and the tool will tell you what it derives ─────
# Same rule as the MAC: a number written into a file can outlive its subject; one computed
# from the name cannot. `vsock-cid <name>` exists so a spec and the driver can be compared
# without booting anything.
c1="$("$LAB_FC" vsock-cid vk1)"; c2="$("$LAB_FC" vsock-cid vk2)"; c1b="$("$LAB_FC" vsock-cid vk1)"
[[ "$c1" == "$c1b" ]] || fail "vsock-cid is not deterministic: 'vk1' derived $c1 then $c1b"
[[ "$c1" != "$c2" ]]  || fail "vsock-cid derived the SAME cid $c1 for 'vk1' and 'vk2' — two guests of one lab would report one number, and the field that tells them apart would not"
emitted="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["vsock"]["guest_cid"])' "$tmp/v.json")"
[[ "$emitted" == "$c1" ]] \
    || fail "the config says guest_cid=$emitted but 'vsock-cid vk1' says $c1 — the read-only verb and the generator disagree, so the verb cannot be used to check a spec"
note "guest_cid is derived from the name, deterministic, distinct per name ($c1 vs $c2), and the read-only verb agrees with the generator"

# ── 4. reserved and malformed CIDs are refused BY NAME ──────────────────────────────────
# 0, 1 and 2 are the kernel's (hypervisor, local, host). Accepting one would not fail here —
# it would fail inside Firecracker, at boot, in a message about the device.
for bad in 0 1 2 abc 4294967295 -1 ""; do
    if run_fc "$tmp/b.out" create --dry-run --name vk1 --kernel "$K" --rootfs "$R" --vsock --vsock-cid "$bad"; then
        grep -q '"guest_cid": '"${bad:-x}"'\b' "$tmp/b.out" \
            && fail "--vsock-cid '$bad' was ACCEPTED and written into the config; 0/1/2 are reserved by the kernel and the rest are not numbers"
    fi
done
note "reserved (0,1,2), non-numeric and out-of-range CIDs are all refused"

# ── 5. an explicit CID is honoured ──────────────────────────────────────────────────────
run_fc "$tmp/e.out" create --dry-run --name vk1 --kernel "$K" --rootfs "$R" --vsock --vsock-cid 7 \
    || { cat "$tmp/e.out" >&2; fail "create --dry-run refused a valid explicit --vsock-cid 7"; }
python3 -c 'import json,sys;v=json.load(open(sys.argv[1]))["vsock"];assert v["guest_cid"]==7,v' \
    <(cfg_of "$tmp/e.out") \
    || fail "--vsock-cid 7 was accepted but the config does not say guest_cid=7"
note "an explicit --vsock-cid overrides the derivation"

# ── 6. vsock does NOT require a tap, and that is the whole point ────────────────────────
# `mmds = true` without a tap is refused, because MMDS is reached over a NIC. vsock is the
# channel that is NOT the fabric: a guest with no NIC at all still answers on it, which is
# how slice 5c could assert br-mc0's ABSENCE while probing a guest. If this ever starts
# demanding a tap, that property is gone and the slice's finding with it.
grep -q '"network-interfaces"' "$tmp/v.json" \
    && fail "the --vsock config (given no tap) somehow carries a network interface"
note "vsock needs no tap — unlike mmds, which is refused without one"

pass "the vsock key emits a valid device with a name-derived guest_cid and a capped uds_path, refuses reserved and malformed CIDs, honours an explicit one, needs no tap, and is absent unless asked for"

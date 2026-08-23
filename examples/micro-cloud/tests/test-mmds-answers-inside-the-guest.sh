#!/usr/bin/env bash
# MANUAL_TESTING row 4's other half: does a guest read ITS OWN instance-id from MMDS?
#
# THE ROW WAS HALF-OBSERVED FOR WEEKS, and the missing half was never "run it again". Two
# things were absent, and neither was privilege:
#
#   1. `mmds = true` put `mmds-config` in the config and stopped. The DEVICE existed and the
#      STORE was empty, so a guest that asked got 404 -- which reads as "metadata is broken"
#      rather than "nobody wrote any". `lab-fc.sh start` now seeds it.
#   2. Nothing could ask from inside. That is what slice 5c's channel is for.
#
# IT NEEDS A TAP, AND A TAP DOES NOT NEED ROOT. MMDS is answered by the VMM on the guest's
# NIC and the packets never leave it, so the tap can be created inside an unprivileged user
# netns -- no fabric, no bridge, no sudo. That is why this runs in CI-shaped conditions
# rather than waiting for the privileged run, which is where it sat.
#
# DRIVE THE CLIENT THE MACHINE ACTUALLY HAS. MMDS v2 requires a PUT to get a token, and the
# guest's busybox `wget` cannot PUT -- so the handshake is spoken over `nc`, which the guest
# does have. `strings api1.ext4 | grep -x nc` says it does NOT; the guest's own
# `busybox --list` says it does. The image was asked rather than inferred, and the proxy was
# wrong.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

need python3
S3="${MC_STATE_DIR:-$HOME/.local/state/lab-create/micro-cloud-s3}"
FC_BIN="${MC_FIRECRACKER:-$S3/firecracker}"
# ONE ANSWER TO "WHERE IS THE VMM". This file resolves the binary itself (it launches
# Firecracker directly) AND shells out to lab-fc.sh, which used to resolve it from PATH --
# the D8 seam: two tools, two answers, and nothing making them agree. Since 2026-08-23 the
# driver takes $LAB_FC_BIN, so exporting it here means both halves run the SAME binary
# rather than the same version by luck. TODO §11.5.
export LAB_FC_BIN="$FC_BIN"
KERNEL="${MC_KERNEL:-$S3/vmlinux}"
BASE="${MC_ROOTFS:-$S3/api1.ext4}"
LAB_FC="$REPO_DIR/phase7-firecracker/lab-fc.sh"

[[ -x "$FC_BIN" ]]   || skip "no firecracker binary at $FC_BIN (set MC_FIRECRACKER)"
[[ -r "$KERNEL" ]]   || skip "no guest kernel at $KERNEL (set MC_KERNEL)"
[[ -r "$BASE" ]]     || skip "no slice-3 rootfs at $BASE (set MC_ROOTFS)"
have curl            || skip "curl is absent, and it is how lab-fc.sh PUTs to the Firecracker API to seed the MMDS store"
[[ -r /dev/kvm && -w /dev/kvm ]] || skip "/dev/kvm is not read-write for this user"
[[ -r /dev/vhost-vsock && -w /dev/vhost-vsock ]] || skip "/dev/vhost-vsock is not read-write for this user — the probe has no way into the guest"
unshare -rn --map-auto true 2>/dev/null || skip "unprivileged user+network namespaces are unavailable, so no tap can be made without root"

WORK="$(mktemp -d)"; on_exit 'rm -rf -- "$WORK"'
NAME="mm$$"
TAP="mmt$$"; TAP="${TAP:0:14}"          # IFNAMSIZ is 16 including the NUL

bash "$LAB_DIR/make-vsock-rootfs.sh" --in "$BASE" --out "$WORK/g.ext4" --port 1234 \
    >"$WORK/mk.log" 2>&1 || fail "make-vsock-rootfs.sh failed, so no guest can answer: $(tail -1 "$WORK/mk.log")"

# The guts run inside the namespace and emit KEY=VALUE lines; every assertion is made out
# here, so lib.sh's verdict discipline is untouched by the re-exec.
cat > "$WORK/inner.sh" <<INNER
set -u
export PATH="$S3:\$PATH"
export LAB_STATE_DIR="\${LAB_STATE_DIR:-\$HOME/.local/state/lab-create}"
ip tuntap add dev "$TAP" mode tap || { echo "INNER_ERR=tap-create"; exit 1; }
ip link set "$TAP" up
"$LAB_FC" destroy "$NAME" --force >/dev/null 2>&1
"$LAB_FC" create --name "$NAME" --kernel "$KERNEL" --rootfs "$WORK/g.ext4" \
    --tap "$TAP" --mac 06:00:ac:47:f1:f7 --mmds --vsock >"$WORK/create.log" 2>&1 \
    || { echo "INNER_ERR=create"; exit 1; }
"$LAB_FC" start "$NAME" >"$WORK/start.log" 2>&1 || { echo "INNER_ERR=start"; exit 1; }
UDS="\$("$LAB_FC" inspect "$NAME" | sed -n 's/^vsock_uds = "\(.*\)"\$/\1/p')"
echo "SEEDED=\$(grep -c 'mmds seeded' "$WORK/start.log" || true)"
sleep 8
g() { python3 "$LAB_DIR/vsock-probe.py" --engine firecracker --uds "\$UDS" --port 1234 \
        --exec "\$1" --retries 15 --timeout 20 2>&1; }
# A ROUTE IS NOT ENOUGH: with no address the guest cannot build the packet and nc blocks.
g 'ip link set eth0 up; ip addr add 169.254.0.2/16 dev eth0 >/dev/null 2>&1; ip route add 169.254.169.254 dev eth0 >/dev/null 2>&1; true' >/dev/null
echo "GUEST_ADDR=\$(g 'ip -4 -o addr show eth0 | awk "{print \\\$4}"' | tr -d '\r\n ')"
TOK="\$(g 'printf "PUT /latest/api/token HTTP/1.0\r\nX-metadata-token-ttl-seconds: 60\r\n\r\n" | nc -w 3 169.254.169.254 80 | tail -1' | tr -d '\r\n ')"
echo "TOKEN_LEN=\${#TOK}"
echo "INSTANCE_ID=\$(g "printf 'GET /latest/meta-data/instance-id HTTP/1.0\r\nX-metadata-token: \$TOK\r\n\r\n' | nc -w 3 169.254.169.254 80 | tail -1" | tr -d '\r\n ')"
echo "NOTOKEN=\$(g 'printf "GET /latest/meta-data/instance-id HTTP/1.0\r\n\r\n" | nc -w 3 169.254.169.254 80 | head -1' | tr -d '\r\n ')"
"$LAB_FC" stop "$NAME" --force >/dev/null 2>&1
"$LAB_FC" destroy "$NAME" --force >/dev/null 2>&1
INNER

timeout 400 unshare -rn --map-auto bash "$WORK/inner.sh" >"$WORK/out" 2>"$WORK/err" || true
grep -q '^INNER_ERR=' "$WORK/out" \
    && fail "the guest could not be brought up inside the namespace ($(grep '^INNER_ERR=' "$WORK/out")); create/start logs are in $WORK"
val() { sed -n "s/^$1=//p" "$WORK/out" | head -1; }

[[ "$(val SEEDED)" == 1 ]] \
    || fail "REGRESSION: 'lab-fc.sh start' did not report seeding the MMDS store, so the device is enabled and EMPTY — a guest asking would get 404, which reads as breakage rather than emptiness"
note "the driver seeded the MMDS store at start"

[[ "$(val GUEST_ADDR)" == 169.254.0.2/16 ]] \
    || fail "the guest's eth0 has no usable address (got '$(val GUEST_ADDR)') — with none it cannot build a packet to 169.254.169.254 at all, and the read below would be measuring the wrong failure"

(( $(val TOKEN_LEN) > 0 )) \
    || fail "the guest got no MMDS token. MMDS v2 requires a PUT to /latest/api/token, and busybox wget cannot PUT — if this is empty, check that the guest still has 'nc' (ask it with busybox --list; strings(1) says it does not, and strings is wrong)"
note "the guest obtained a V2 token by PUT, $(val TOKEN_LEN) bytes"

[[ "$(val INSTANCE_ID)" == "$NAME" ]] \
    || fail "REGRESSION: the guest read instance-id='$(val INSTANCE_ID)' but it is instance '$NAME'. Either the store was seeded from a stale value, or the seam answered for a different instance — the class that has bitten this repo before"
note "instance-id read INSIDE the guest is its OWN: $(val INSTANCE_ID)"

# THE CONTROL, AND IT IS THE POINT OF V2. V1 answers any GET, unauthenticated; a test that
# only proved "the guest can read metadata" would pass identically against V1 and the
# mmds-config version field would be decoration.
[[ "$(val NOTOKEN)" == *401* ]] \
    || fail "control: the same GET WITHOUT a token returned '$(val NOTOKEN)' rather than 401 — if an untokened GET is answered, this is MMDS V1 behaviour and the V2 in the config is not what the guest is talking to"
note "control: the same GET with no token is refused 401, so this is V2 and not V1"

pass "MMDS answers INSIDE the guest: the driver seeded the store, the guest completed the v2 PUT-for-a-token handshake with the client it actually has (nc, not wget — wget cannot PUT), read instance-id='$(val INSTANCE_ID)' matching its own name, and the same GET without a token was refused 401"

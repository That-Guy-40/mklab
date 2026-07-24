#!/usr/bin/env bash
# demo-anycast.sh — PROVE the health-gated anycast announce (mechanic ② of the
# RAM-resident infra family). A gated node (Knot DNS + ExaBGP) advertises the
# anycast VIP 10.89.7.100/32 to a bird2 collector ONLY while DNS answers; take
# DNS down and the collector loses the route; bring it back and the route
# returns. This is the whole point of anycast: a node attracts traffic for the
# service address only while it can actually serve it.
#
# Self-contained (podman only; no root, no QEMU). Builds the image on first run.
# One verdict (house rule): PASS requires present-while-healthy,
# absent-while-down, present-again-after-recovery.
#
# HONEST SCOPE: this proves the announce/withdraw MECHANISM observed at a real
# BGP peer — NOT global anycast routing (one IP live from many sites, clients
# steered to the nearest), which needs real multi-site BGP infrastructure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMG=anycast-dns-ram
NET=anycast-net
CONF="$HERE/conf"
NODE=anycast-node
COLL=anycast-collector
VIP='10.89.7.100/32'

skip() { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }

cleanup() {
    podman rm -f "$NODE" "$COLL" >/dev/null 2>&1 || true   # lifecycle verb, by name
    podman network rm "$NET"    >/dev/null 2>&1 || true
}
# Safety net: no silent exit (house rule). Any non-verdict exit prints one.
trap 'rc=$?; cleanup; [[ $rc == 0 || $rc == 77 || $rc == 1 ]] || \
      printf "FAIL: demo exited early (rc=%s)\n" "$rc" >&2' EXIT

command -v podman >/dev/null 2>&1 || skip "podman not available"

# Build the image if it is not present yet.
if ! podman image exists "$IMG" 2>/dev/null; then
    note "building image $IMG (first run)"
    podman build -t "$IMG" -f "$HERE/Containerfile" "$HERE" >/dev/null 2>&1 \
        || fail "podman build failed for $IMG"
fi

cleanup   # clean slate
podman network create --subnet 10.89.7.0/24 "$NET" >/dev/null \
    || fail "could not create podman network $NET"
podman run -d --name "$COLL" --network "$NET" --ip 10.89.7.20 \
    -v "$CONF:/etc/anycast:ro" "$IMG" sleep infinity >/dev/null \
    || fail "collector container failed to start"
podman run -d --name "$NODE" --network "$NET" --ip 10.89.7.10 \
    --tmpfs /var/lib/knot \
    -v "$CONF:/etc/anycast:ro" "$IMG" sleep infinity >/dev/null \
    || fail "node container failed to start"

# bird2 collector (passive looking-glass)
podman exec "$COLL" sh -c 'mkdir -p /run/bird && bird -c /etc/anycast/bird.conf' \
    || fail "bird2 collector did not start"

# knotd: binds :53 then drops CAP_DAC_OVERRIDE, so its tmpfs rundir must be
# world-writable for the pidfile (a rootless-container-ism; real deploys get
# /run/knot from systemd-tmpfiles).
start_knot() { podman exec "$NODE" sh -c 'chmod 0777 /var/lib/knot && knotd -c /etc/anycast/knot.conf -d'; }
start_knot || fail "knotd did not start"
sleep 2
( podman exec "$NODE" dig +short @127.0.0.1 example.lab SOA | grep -q . ) \
    || fail "knotd is not answering the zone"
note "node DNS serving example.lab"

# ExaBGP refuses to run as root unless told; inside a container root is fine.
podman exec -d "$NODE" sh -c 'env exabgp.daemon.user=root exabgp /etc/anycast/exabgp.conf > /tmp/exabgp.log 2>&1'

routes() { podman exec "$COLL" birdc show route 2>/dev/null | grep -c "$VIP"; }

# phase 1 — healthy: route should appear
h1=0; for _ in $(seq 1 15); do sleep 2; h1=$(routes); [[ "$h1" -ge 1 ]] && break; done
[[ "$h1" -ge 1 ]] || fail "REGRESSION: healthy node did NOT announce $VIP to the collector"
note "healthy: collector sees $VIP (announced)"

# phase 2 — unhealthy: knotc stop, route should withdraw
podman exec "$NODE" knotc -c /etc/anycast/knot.conf stop >/dev/null 2>&1 || true
h2=1; for _ in $(seq 1 8); do sleep 2; h2=$(routes); [[ "$h2" -eq 0 ]] && break; done
[[ "$h2" -eq 0 ]] || fail "REGRESSION: DNS is down but the collector still sees $VIP (route not withdrawn)"
note "unhealthy: collector no longer sees $VIP (withdrawn)"

# phase 3 — recover: route should return
start_knot || fail "knotd did not restart"
h3=0; for _ in $(seq 1 10); do sleep 2; h3=$(routes); [[ "$h3" -ge 1 ]] && break; done
[[ "$h3" -ge 1 ]] || fail "recovered node did not re-announce $VIP"
note "recovered: collector sees $VIP again (re-announced)"

pass "health-gated anycast: $VIP announced while healthy, withdrawn on DNS failure, re-announced on recovery"

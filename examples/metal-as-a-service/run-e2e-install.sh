#!/usr/bin/env bash
# run-e2e-install.sh — the INSTALL-driver live path (DEFERRED item 2): PXE-boot the
# Anaconda installer through the fleet's netboot chain, let the kickstart write the
# node's disk, wait for the node to power ITSELF off (the completion signal), switch
# it to boot-from-disk, and gate `active` on the INSTALLED OS's serial login.
#
# SEPARATE from run-e2e.sh on purpose: that is the fast reconcile-loop run (~2 min)
# and a ~20–30 minute install inside it would stop anyone from running it. This
# script assumes the fleet is ALREADY UP — run run-e2e.sh (or
# FLEET_NIC_ROM=1 ./create-fleet.sh up — NEVER bare: without the var the fleet
# comes up without its verifying ROMs, silently)
# first — and needs no sudo itself: the privileged pieces (PXE net, chain, domains)
# were done by whatever brought the fleet up.
#
# Knobs:
#   E2E_NODE=node1             the subject node
#   E2E_IMAGE=almalinux9       must be declared in install-catalog.toml
#   E2E_FETCH_STAGE2=1         fetch the Anaconda stage2 (~0.8 GB) if it is missing
#   MAAS_INSTALL_TIMEOUT=2400  how long the installer may take (it ends in poweroff)
#   MAAS_HEALTH_TIMEOUT=240    how long the installed OS may take to reach login:
#
# The usual F2 pair applies: MAAS_IPXE_TRUSTS_CA=1 when the fleet carries the
# verifying ROM (see build-verifying-rom.sh), E2E_NO_IMGVERIFY=1 to keep the
# payload signed but drop only the in-firmware check.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MAAS="$HERE/maas-lab.sh"
NODE="${E2E_NODE:-node1}"
IMAGE="${E2E_IMAGE:-almalinux9}"
NETBOOT_DIR="${MAAS_NETBOOT_DIR:-$HOME/netboot}"
PORT="${MAAS_NETBOOT_PORT:-8181}"
export MAAS_IMAGES_DIR="${MAAS_IMAGES_DIR:-$("$MAAS" _images-dir)}"
[[ -n "$MAAS_IMAGES_DIR" ]] || { echo "run-e2e-install: maas-lab.sh _images-dir returned nothing" >&2; exit 1; }
# The drivers read registry context from the env maas-lab.sh normally exports for
# them; this script also calls a driver DIRECTLY (stage/verify), so it must export
# the same context itself. The first live run died right here without it.
export MAAS_STATE="${MAAS_STATE:-$("$MAAS" _state-root)}"
export MAAS_INSTALL_TIMEOUT="${MAAS_INSTALL_TIMEOUT:-2400}"
export MAAS_HEALTH_TIMEOUT="${MAAS_HEALTH_TIMEOUT:-240}"

die()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '   %s\n' "$*" >&2; }
step() { printf '\n== %s ==\n' "$*" >&2; }

# ── preflight — every check here is a failure that would otherwise surface as a
# silent multi-minute timeout deep inside the install ─────────────────────────
step "preflight"

( "$MAAS" show "$NODE" ) >/dev/null 2>&1 \
    || die "node '$NODE' is not enrolled — bring the fleet up first: FLEET_NIC_ROM=1 MAAS_IPXE_TRUSTS_CA=1 ./run-e2e.sh (or FLEET_NIC_ROM=1 ./create-fleet.sh up — never bare, or the ROMs drop)"
( "$MAAS" power "$NODE" status ) >/dev/null 2>&1 \
    || die "the BMC for '$NODE' is not answering — is vbmcd up? (FLEET_NIC_ROM=1 ./create-fleet.sh up)"
info "fleet: '$NODE' enrolled, BMC answers"

grep -q 'netboot-chain.sh' /var/lib/libvirt/tftp-vbmc/boot.ipxe 2>/dev/null \
    || die "the PXE network's boot.ipxe is not the per-node CHAIN — the per-node script this
run writes would never be fetched. Install it: ./netboot-chain.sh install (sudo)"
info "netboot chain: installed"

GW="$(virsh -c qemu:///system net-dumpxml vbmc-pxe 2>/dev/null \
      | sed -nE "s/.*<ip address='([^']+)'.*/\1/p" | head -1)"
[[ -n "$GW" ]] || die "could not read the vbmc-pxe gateway address (is the network defined?)"
curl -fsS --max-time 5 -o /dev/null "http://$GW:$PORT/vmlinuz" \
    || die "the payload server is not serving $NETBOOT_DIR on http://$GW:$PORT/ — start it:
( cd ../virtualbmc-ipmi-lab && ./setup-pxe-net.sh )   # sudo"
info "payload server: http://$GW:$PORT/ serves the docroot"

# MAAS_IPXE_TRUSTS_CA=1 promises the NODE will verify — which only its NIC ROM can
# do. That attachment does not survive any create-fleet run made without
# FLEET_NIC_ROM (it now defaults ON when the ROM is installed — this fleet lost
# its ROMs to the old opt-in default three times, twice via this repo's own
# printed instructions). A stock ROM meets `imgverify` as an
# unknown command and cannot speak on the serial console, so without this check
# the failure surfaces as the deploy burning its FULL timeout in silence.
if [[ "${MAAS_IPXE_TRUSTS_CA:-0}" == 1 ]] && command -v virsh >/dev/null; then
    dom="$("$MAAS" show "$NODE" 2>/dev/null | awk '$1=="domain"{print $2; exit}')"
    virsh -c qemu:///system dumpxml --inactive "${dom:-$NODE}" 2>/dev/null | grep -q '<rom file=' \
        || die "MAAS_IPXE_TRUSTS_CA=1, but domain '${dom:-$NODE}' carries NO <rom file=> — its stock
ROM cannot honour imgverify and cannot even speak on the serial console, so the
deploy would sit silent until the full install timeout. The fleet was re-created
with the ROM dropped (FLEET_NIC_ROM=0, or an uninstalled ROM). Fix:
    FLEET_NIC_ROM=1 ./create-fleet.sh up
then re-run this script."
    info "verifying ROM: attached to '${dom:-$NODE}'"
fi

( "$HERE/drivers/verify-lib.sh" check-keys --dir "$MAAS_IMAGES_DIR/trust" ) >/dev/null 2>&1 || {
    [[ "${MAAS_IPXE_TRUSTS_CA:-0}" == 1 ]] \
        && die "the signing leaf is one verifying firmware refuses, and MAAS_IPXE_TRUSTS_CA=1
says the node will check. Re-mint first — see run-e2e.sh's preflight for the commands."
    info "NOTE: signing leaf lacks digitalSignature; fine only because the firmware is not checking"
}

# The Anaconda STAGE2. inst.stage2= points at the docroot, and the checksum gate is
# not pedantry: a stale or truncated install.img is the classic silent killer here —
# HTTP 200, installer boots, then dies minutes in with an unrelated-looking error.
# (And never resume-download it: `curl -C -` onto a stale leftover shadows the
# corruption forever — the exact trap this repo has already paid for once.)
S2="$NETBOOT_DIR/images/install.img"
want="$(sed -nE 's/^images\/install\.img = sha256:([0-9a-f]+).*/\1/p' "$NETBOOT_DIR/.treeinfo" | head -1)"
[[ -n "$want" ]] || die "no sha256 for images/install.img in $NETBOOT_DIR/.treeinfo — the netboot tree is incomplete"
if [[ ! -f "$S2" ]]; then
    if [[ "${E2E_FETCH_STAGE2:-0}" == 1 ]]; then
        url="https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/images/install.img"
        info "stage2 missing — fetching $url (~0.8 GB, fresh, no resume)…"
        mkdir -p "$NETBOOT_DIR/images"
        tmp="$(mktemp "$NETBOOT_DIR/images/.install.img.XXXXXX")"
        curl -fL --progress-bar -o "$tmp" "$url" || { rm -f "$tmp"; die "stage2 download failed"; }
        got="$(sha256sum "$tmp" | awk '{print $1}')"
        [[ "$got" == "$want" ]] || { rm -f "$tmp"; die "downloaded stage2 sha256 mismatch (.treeinfo wants $want, got $got) —
the local .treeinfo and the mirror disagree; re-sync the whole netboot tree, do not mix generations"; }
        # mktemp creates 0600 and mv preserves it — the web server (another user)
        # then serves 403 and dracut retry-loops on "failed to fetch stage2".
        # Found live: the sha said perfect, the perms said nobody may look.
        chmod 0644 "$tmp"
        mv -f "$tmp" "$S2"
    else
        die "the Anaconda stage2 is missing: $S2 (reclaimed in a disk cleanup).
Re-fetch it, sha-checked against .treeinfo:  E2E_FETCH_STAGE2=1 $0"
    fi
fi
got="$(sha256sum "$S2" | awk '{print $1}')"
[[ "$got" == "$want" ]] \
    || die "stage2 sha256 MISMATCH: .treeinfo wants $want, $S2 has $got.
This is the silent killer: Anaconda will boot and then fail minutes in. Delete it and
re-fetch fresh (E2E_FETCH_STAGE2=1) — never resume onto it"
info "stage2: $S2 matches .treeinfo ($got)"

step "stage + sign '$IMAGE' (host-side F2)"
"$HERE/drivers/install.sh" stage "$IMAGE" || die "staging '$IMAGE' failed"
( "$HERE/drivers/install.sh" verify "$IMAGE" ) \
    || die "the staged '$IMAGE' does not pass the host-side F2 gate"
info "staged + verified against $MAAS_IMAGES_DIR/trust"

# The firmware must be able to honour the script this deploy writes — same gate,
# same reasoning, as run-e2e.sh's phase 8.
if [[ -f "$MAAS_IMAGES_DIR/$IMAGE/kernel.sig" \
      && "${MAAS_IPXE_TRUSTS_CA:-0}" != 1 && "${MAAS_NO_IMGVERIFY:-0}" != 1 ]]; then
    [[ "${E2E_NO_IMGVERIFY:-0}" == 1 ]] && export MAAS_NO_IMGVERIFY=1
    [[ "${MAAS_NO_IMGVERIFY:-0}" == 1 ]] \
        || die "'$IMAGE' is signed, so the boot script will carry \`imgverify\` — and nothing here
has established this fleet's firmware can honour it. Either the fleet carries the
verifying ROM (then: MAAS_IPXE_TRUSTS_CA=1 $0) or skip only the in-firmware half
(E2E_NO_IMGVERIFY=1 $0). Refusing to boot into a silence that looks like a dead payload."
fi

# ── the run ──────────────────────────────────────────────────────────────────
step "deploy: netboot Anaconda -> kickstart -> poweroff -> disk boot -> login"

CON="$("$MAAS" show "$NODE" 2>/dev/null | awk '$1=="console"{print $2; exit}')"
[[ -n "$CON" && -f "$CON" ]] || die "no console log recorded for '$NODE' — the health gate would be blind"
# Rotate the console BEFORE deploying. It is append-only across boots, and the
# health gate greps the whole file for 'login:' — which the PREVIOUS payload (the
# RAM image's getty) already printed. Without this line the gate passes instantly
# on stale bytes and the run proves nothing: the cheap check standing in for the
# real one, verbatim.
cp -f "$CON" "$HERE/e2e-install-console.prev.log" 2>/dev/null || true
: > "$CON" || die "cannot truncate $CON"
info "console rotated (previous boot's log kept at e2e-install-console.prev.log)"

# A deploy begins from REST (as on real metal — Ironic powers a node down before
# provisioning). '$NODE' may still be running its RAM payload; the driver's
# 'power on' would then be a no-op on a live machine and nothing would ever PXE.
( "$MAAS" power "$NODE" off ) >/dev/null 2>&1 || true
info "'$NODE' powered off; deploying (installer may take ~$((MAAS_INSTALL_TIMEOUT/60)) min)…"

"$MAAS" deploy "$NODE" --driver install --image "$IMAGE" \
    || die "deploy did not reach active — state: $( ( "$MAAS" state "$NODE" ) 2>/dev/null ). Console tail:
$(tail -5 "$CON" 2>/dev/null)"

step "verdict"
st="$( ( "$MAAS" state "$NODE" ) 2>/dev/null )"
[[ "$st" == active ]] || die "deploy returned success but '$NODE' is in '$st'"
grep -qE 'AlmaLinux|login:' "$CON" \
    || die "'$NODE' is active but its console shows neither an AlmaLinux banner nor a login prompt — the gate passed on something else"
info "installed OS on console: $(grep -E 'AlmaLinux' "$CON" | head -1 | tr -d '\r')"
printf 'PASS: %s reached active through the INSTALL driver — Anaconda netbooted via the chain, the kickstart wrote the disk, the node powered itself off, and the INSTALLED OS reached login on its own disk\n' "$NODE"

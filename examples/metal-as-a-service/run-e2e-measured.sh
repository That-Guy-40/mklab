#!/usr/bin/env bash
# run-e2e-measured.sh — the IMAGE+MEASURED live path: lay a measured golden image
# onto a node, have the node attest to what it actually booted, and let the
# control plane decide whether that is allowed to be `active`.
#
# WHAT THIS PROVES, AND WHAT IT CANNOT. The PCRs are real: a TPM 2.0 device
# extended them, the firmware measured the UKI it loaded, and the node signed the
# quote itself before the control plane believed a digit of it. The gate's refusal
# path is real too — §4 below tampers with the policy and requires the deploy to
# fail. What is NOT real is the anchor: swtpm's state is readable by anything that
# can read the host, and the attestation key is baked into the image rather than
# generated inside the TPM and certified through an endorsement key. So this run
# proves the MECHANISM and the REFUSAL, never the integrity of a machine. Say it
# that way in any write-up; see drivers/image-measured.sh's header.
#
# THE NODE MUST BE UEFI + TPM. A TPM on a BIOS domain measures the boot sector and
# the partition table and nothing in the filesystem — two completely different
# kernels measure identically, so the gate would pass anything. create-fleet.sh's
# FLEET_TPM sets both, and lib/tpm_xml.py refuses to set one without the other.
#
# Name the NODE, not the fleet: FLEET_TPM=1 switches every domain to UEFI, and a node
# whose disk was installed under BIOS cannot boot it afterwards — which is exactly
# what happened to node1 and node2 on the first attempt at this run.
#
#   ./build-verifying-rom.sh install-efi     # the VERIFYING ipxe.efi into the TFTP root
#   ./netboot-chain.sh install-uefi          # offer it to UEFI clients only
#   FLEET_TPM=node3 ./create-fleet.sh up     # one node that can measure
#   ./run-e2e-measured.sh                    # this script
#
# Knobs: E2E_NODE (default node3 — its disk is DESTROYED), E2E_IMAGE, E2E_FORCE=1.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MAAS="$HERE/maas-lab.sh"
NODE="${E2E_NODE:-node3}"
IMAGE="${E2E_IMAGE:-golden-measured}"
NETBOOT_DIR="${MAAS_NETBOOT_DIR:-$HOME/netboot}"
PORT="${MAAS_NETBOOT_PORT:-8181}"
MDPORT="${MAAS_MD_PORT:-8282}"
export MAAS_IMAGES_DIR="${MAAS_IMAGES_DIR:-$("$MAAS" _images-dir)}"
export MAAS_STATE="${MAAS_STATE:-$("$MAAS" _state-root)}"
export MAAS_HEALTH_TIMEOUT="${MAAS_HEALTH_TIMEOUT:-240}"

die()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '   %s\n' "$*" >&2; }
step() { printf '\n== %s ==\n' "$*" >&2; }
# shellcheck source=lib/e2e-common.sh
source "$HERE/lib/e2e-common.sh"

SINK_PID=""
cleanup() { [[ -n "$SINK_PID" ]] && kill "$SINK_PID" 2>/dev/null; }
trap cleanup EXIT

step "preflight"
( "$MAAS" show "$NODE" ) >/dev/null 2>&1 \
    || die "node '$NODE' is not enrolled — FLEET_TPM=$NODE ./create-fleet.sh up"
( "$MAAS" power "$NODE" status ) >/dev/null 2>&1 \
    || die "the BMC for '$NODE' is not answering — is vbmcd up?"

# The domain must be able to measure, and the failure mode of getting this wrong
# is a gate that passes rather than one that errors — so it is checked here, hard.
dom="$("$MAAS" show "$NODE" 2>/dev/null | awk '$1=="domain"{print $2; exit}')"
xml="$(virsh -c qemu:///system dumpxml --inactive "${dom:-$NODE}" 2>/dev/null)"
grep -q '<tpm' <<<"$xml" \
    || die "domain '${dom:-$NODE}' has NO <tpm> device — it cannot measure anything.
    FLEET_TPM=$NODE ./create-fleet.sh up"
grep -q "loader.*pflash\|<loader" <<<"$xml" \
    || die "domain '${dom:-$NODE}' has a TPM but is NOT UEFI. On a BIOS domain the firmware
measures the boot sector and the partition table and nothing in the filesystem, so a
PCR policy blesses ANY payload — the gate would pass and mean nothing. Re-create the
fleet with FLEET_TPM=$NODE (lib/tpm_xml.py sets both, deliberately)."
info "domain '${dom:-$NODE}': TPM 2.0 + UEFI — it can measure the payload it boots"

# ...and it must be able to NETBOOT, which UEFI makes a separate question. OVMF's
# NetworkPkg gives it the PXE stack, but the driver for the card comes from the card's
# UEFI option ROM — and this lab attaches a LEGACY-only verifying ROM. A UEFI domain
# carrying that ROM finds no network device, builds no boot option, and drops to the
# EFI internal shell ("map: No mapping found") with no PXE attempt and no error. It
# cost a live run on 2026-07-29. A measured node therefore uses virtio (OVMF drives it
# natively) with no option ROM at all; lib/tpm_xml.py sets that, and this checks it.
if grep -q '<rom file=' <<<"$xml"; then
    die "domain '${dom:-$NODE}' is UEFI but its NIC carries a legacy option ROM. That ROM
REPLACES the only UEFI network driver OVMF would have had, so the firmware finds no NIC,
never attempts PXE, and stops at the EFI shell — this run would time out against a
console showing a firmware prompt. Re-create the node:
  FLEET_TPM=$NODE ./create-fleet.sh up"
fi
if ! grep -q "type='virtio'" <<<"$(sed -n '/<interface/,/<\/interface>/p' <<<"$xml")"; then
    die "domain '${dom:-$NODE}' is UEFI but its NIC is not virtio. OVMF has no built-in
driver for it, so with the option ROM disabled there is nothing to netboot with.
  FLEET_TPM=$NODE ./create-fleet.sh up"
fi
info "NIC: virtio with no option ROM — OVMF drives it and fetches the verifying ipxe.efi"

# The node must be in a state `deploy` accepts, and this is checked HERE — before the
# UKI build, the staging and the sink — because the alternative is finding out several
# minutes in. An interrupted earlier run leaves the node in `deploying`, which is
# exactly how this failed on 2026-07-29.
make_deployable "$NODE"

GW="$(virsh -c qemu:///system net-dumpxml vbmc-pxe 2>/dev/null \
      | sed -nE "s/.*<ip address='([^']+)'.*/\1/p" | head -1)"
[[ -n "$GW" ]] || die "could not read the vbmc-pxe gateway address"
curl -fsS --max-time 5 -o /dev/null "http://$GW:$PORT/maas/deployer/vmlinuz" \
    || die "the deployer ramdisk is not served — see run-e2e-image.sh's preflight"
grep -q 'netboot-chain.sh' /var/lib/libvirt/tftp-vbmc/boot.ipxe 2>/dev/null \
    || die "the PXE network's boot.ipxe is not the per-node chain (./netboot-chain.sh install)"

# THE UEFI NETBOOT PATH, checked in three parts because each failure alone is a
# silent timeout with an empty console. The network hands every client `boot.ipxe`
# — an iPXE *script*, which works only because a BIOS node's option ROM chainloads
# it. This node is UEFI (it has to be, or it measures nothing), so its firmware
# would TFTP that script and try to execute it as a PE binary.
#
# netboot-chain.sh install-uefi is what fixes it: arch-conditional DHCP through
# libvirt's dnsmasq: namespace, plus the binary in the TFTP root.
EFI_BIN=/var/lib/libvirt/tftp-vbmc/ipxe.efi
if ! sudo -n test -f "$EFI_BIN" 2>/dev/null && [[ ! -f "$EFI_BIN" ]]; then
    die "this node is UEFI, but the TFTP root has no ipxe.efi — a UEFI firmware cannot
execute an iPXE script as a boot binary, so the deployer would never load and this run
would time out against an empty console. Install it:
  ./build-verifying-rom.sh install-efi && ./netboot-chain.sh install-uefi"
fi

# ...and it must be the VERIFYING binary. This is the trap this lab's own notes fell
# into: DEFERRED.md said to copy ~/netboot/ipxe.efi, which is the RAM-infra lab's
# generic build with no IMAGE_TRUST_CMD and no fleet CA. Everything downstream would
# go green while the firmware half of F2 was switched off on the ONE node whose whole
# purpose is proving a machine refuses what the fleet did not sign. Nothing but this
# check can see the difference.
if [[ -r "$EFI_BIN" ]] && ! ( "$HERE/build-verifying-rom.sh" check-efi "$EFI_BIN" ) >/dev/null 2>&1; then
    die "$EFI_BIN does not enforce F2 (no imgverify, or not this fleet's CA). The node
would boot, deploy and attest with NO firmware-side signature verification, and this
run would pass. Reinstall the verifying build:
  ./build-verifying-rom.sh install-efi
  ( ./build-verifying-rom.sh check-efi $EFI_BIN   shows exactly what is missing )"
fi

# ...and the network must actually OFFER it. A binary sitting in the TFTP root that
# nothing is ever told to fetch is the same empty console as no binary at all.
missing_opts=()
while read -r opt; do
    virsh -c qemu:///system net-dumpxml vbmc-pxe 2>/dev/null | grep -qF "$opt" || missing_opts+=("$opt")
done < <(python3 "$HERE/lib/dnsmasq_arch_xml.py" --emit-options)
if [[ ${#missing_opts[@]} -gt 0 ]]; then
    die "the vbmc-pxe network is not configured to offer ipxe.efi to UEFI clients
(${#missing_opts[@]} dnsmasq option(s) missing, e.g. ${missing_opts[0]}).
The node would be handed boot.ipxe and stop. Fix:
  ./netboot-chain.sh install-uefi     (sudo; restarts the network, fleet must be down)"
fi
info "UEFI netboot path: verifying ipxe.efi served, and offered to UEFI clients only"

step "build + stage the measured golden image"
# The image carries the sink URL in its UKI — and therefore in its measurement.
RAW="${MAAS_ARTIFACTS:-$HOME/.cache/lab-create/maas}/golden-measured.raw"
"$HERE/build-golden-measured.sh" --out "$RAW" --md-url "http://$GW:$MDPORT" >/dev/null \
    || die "could not build the measured golden image"
info "built $RAW (UEFI ESP + UKI, sink http://$GW:$MDPORT)"
"$HERE/drivers/image.sh" stage "$IMAGE" --from "$RAW" >/dev/null 2>&1 \
    || die "staging '$IMAGE' failed"
( "$HERE/drivers/image.sh" verify "$IMAGE" ) || die "the staged image fails the host-side F2 gate"
info "staged + signed (host-side F2 passes)"

step "start the attestation sink (:$MDPORT)"
# The same service the introspection probe reports to; the quote endpoints are
# keyed by MAC because a measured golden image is generic (see lib/metadata.py).
"$HERE/metadata-serve.sh" --port "$MDPORT" --host "$GW" >/dev/null 2>&1 &
SINK_PID=$!
sleep 1
kill -0 "$SINK_PID" 2>/dev/null || die "the metadata service did not start on $GW:$MDPORT"
info "sink up as PID $SINK_PID (reaped when this exits)"

CON="$("$MAAS" show "$NODE" 2>/dev/null | awk '$1=="console"{print $2; exit}')"
[[ -n "$CON" && -r "$CON" ]] || die "no readable console for '$NODE' (see run-e2e-install.sh's note on virtlogd)"
cp -f "$CON" "$HERE/e2e-measured-console.prev.log" 2>/dev/null || true
: > "$CON" || die "cannot truncate $CON"
rm -f "$MAAS_STATE/$NODE/quote.json" "$MAAS_STATE/$NODE/quote.json.sig"
info "console rotated; any previous quote cleared (a stale one would attest for this run)"

st="$( ( "$MAAS" state "$NODE" ) 2>/dev/null )"
case "$st" in
    active)     ( "$MAAS" release "$NODE" --wiped ) >/dev/null 2>&1 || true ;;
    error)      ( "$MAAS" retry "$NODE" ) >/dev/null 2>&1; ( "$MAAS" provide "$NODE" ) >/dev/null 2>&1 || true ;;
    manageable) ( "$MAAS" provide "$NODE" ) >/dev/null 2>&1 || true ;;
esac
( "$MAAS" power "$NODE" off ) >/dev/null 2>&1 || true

# ── the refusal that comes FIRST, before any hardware ───────────────────────
step "deploy #0 — image+measured must refuse an image with no PCR policy"
# The driver refuses at VERIFY, before the node is touched at all: an image with
# nothing to attest against would otherwise sail through the gate it is named for.
# (The first version of this script assumed the refusal came AFTER a boot and then
# waited for a quote from a node that had never been powered on. The refusal being
# early is correct; the script was wrong.)
if "$MAAS" deploy "$NODE" --driver image+measured --image "$IMAGE" >/dev/null 2>&1; then
    die "REGRESSION: a measured deploy SUCCEEDED for an image with no PCR policy. An image
with nothing to attest against must be refused, or the driver's name is a lie."
fi
[[ ! -f "$MAAS_STATE/$NODE/quote.json" ]] \
    || die "the refusal happened but the node still attested — verify must gate BEFORE any boot"
info "refused at verify, before the node was touched: no pcrs.expected for '$IMAGE'"

# ── the enrollment boot: lay the image down with the PLAIN image driver ──────
step "deploy #1 — enrollment boot (plain 'image' driver) to learn what this image measures"
# Nobody can predict a firmware's measurements, so the policy has to come from a
# real boot of this exact image. That boot cannot be a MEASURED deploy — the gate
# would refuse it for having no policy, which is the point of deploy #0. So the
# enrollment boot uses the plain `image` driver: identical lay-down, identical
# payload, no attestation gate. This is exactly how it works in life: image a
# golden machine, observe what it measures, pin that, then enforce.
st="$( ( "$MAAS" state "$NODE" ) 2>/dev/null )"
[[ "$st" == error ]] && { ( "$MAAS" retry "$NODE" ) >/dev/null 2>&1; ( "$MAAS" provide "$NODE" ) >/dev/null 2>&1; }
"$MAAS" deploy "$NODE" --driver image --image "$IMAGE" \
    || die "the enrollment boot failed — the node could not even lay down and boot the measured
image without the attestation gate. State: $( ( "$MAAS" state "$NODE" ) 2>/dev/null ). Console tail:
$(tail -8 "$CON" 2>/dev/null | tr -d '\r')"
info "the node booted the measured image (plain image driver, no gate)"

for i in $(seq 1 60); do
    [[ -f "$MAAS_STATE/$NODE/quote.json" ]] && break
    sleep 2
done
[[ -f "$MAAS_STATE/$NODE/quote.json" ]] \
    || die "the node never delivered a quote to the sink. Console tail:
$(tail -8 "$CON" 2>/dev/null | tr -d '\r')"
info "the node delivered a signed quote: $(wc -l < "$MAAS_STATE/$NODE/quote.json") PCRs"
"$HERE/drivers/image-measured.sh" capture-policy "$IMAGE" "$NODE" \
    || die "could not capture the PCR policy from that boot"

# ── second deploy: the gate must now PASS ───────────────────────────────────
step "deploy #2 — the same image must now attest and activate"
rm -f "$MAAS_STATE/$NODE/quote.json" "$MAAS_STATE/$NODE/quote.json.sig"
st="$( ( "$MAAS" state "$NODE" ) 2>/dev/null )"
[[ "$st" == error ]] && { ( "$MAAS" retry "$NODE" ) >/dev/null 2>&1; ( "$MAAS" provide "$NODE" ) >/dev/null 2>&1; }
"$MAAS" deploy "$NODE" --driver image+measured --image "$IMAGE" \
    || die "the measured deploy failed even with a policy captured from this very image.
State: $( ( "$MAAS" state "$NODE" ) 2>/dev/null ). Console tail:
$(tail -8 "$CON" 2>/dev/null | tr -d '\r')"
[[ "$( ( "$MAAS" state "$NODE" ) 2>/dev/null )" == active ]] \
    || die "deploy returned success but '$NODE' is not active"
info "attested and active on '$IMAGE'"

# ── the refusal, on purpose ─────────────────────────────────────────────────
step "deploy #3 — a policy the node cannot satisfy MUST be refused"
# Zero criticals is also what a gate that never refuses anything reports. So bend
# one digit of the expected PCR4 and require the deploy to fail: this is the whole
# reason the driver exists, and the only way to know it is not decoration.
POL="$MAAS_IMAGES_DIR/$IMAGE/pcrs.expected"
cp -f "$POL" "$POL.real"
sed -i 's/^4:\(.\)/4:0/' "$POL"
rm -f "$MAAS_STATE/$NODE/quote.json" "$MAAS_STATE/$NODE/quote.json.sig"
( "$MAAS" release "$NODE" --wiped ) >/dev/null 2>&1 || true
if "$MAAS" deploy "$NODE" --driver image+measured --image "$IMAGE" >/dev/null 2>&1; then
    cp -f "$POL.real" "$POL"
    die "REGRESSION: the node ACTIVATED against a PCR policy it does not match. The
attestation gate is decoration — it would activate a node running anything at all."
fi
cp -f "$POL.real" "$POL"; rm -f "$POL.real"
info "refused, correctly: the measured PCR4 did not match the policy"

step "verdict"
grep -qa 'MAAS-ATTEST: measured .* PCRs from a real TPM' "$CON" \
    || die "the console carries no evidence the node ever measured anything"
info "console: $(grep -a 'MAAS-ATTEST: PCR4' "$CON" | tail -1 | tr -d '\r')"
printf 'PASS: %s attested to a real TPM measurement of the image it booted, activated only against a policy captured from that measurement, and was REFUSED when the policy no longer matched. swtpm is plumbing, not a trust anchor: this proves the mechanism and the refusal, not the integrity of a machine.\n' "$NODE"

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
# FLEET_TPM=1 sets both, and lib/tpm_xml.py refuses to set one without the other.
#
#   FLEET_TPM=1 ./create-fleet.sh up        # a fleet whose nodes can measure
#   ./run-e2e-measured.sh                   # this script
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

SINK_PID=""
cleanup() { [[ -n "$SINK_PID" ]] && kill "$SINK_PID" 2>/dev/null; }
trap cleanup EXIT

step "preflight"
( "$MAAS" show "$NODE" ) >/dev/null 2>&1 \
    || die "node '$NODE' is not enrolled — FLEET_TPM=1 ./create-fleet.sh up"
( "$MAAS" power "$NODE" status ) >/dev/null 2>&1 \
    || die "the BMC for '$NODE' is not answering — is vbmcd up?"

# The domain must be able to measure, and the failure mode of getting this wrong
# is a gate that passes rather than one that errors — so it is checked here, hard.
dom="$("$MAAS" show "$NODE" 2>/dev/null | awk '$1=="domain"{print $2; exit}')"
xml="$(virsh -c qemu:///system dumpxml --inactive "${dom:-$NODE}" 2>/dev/null)"
grep -q '<tpm' <<<"$xml" \
    || die "domain '${dom:-$NODE}' has NO <tpm> device — it cannot measure anything.
    FLEET_TPM=1 ./create-fleet.sh up"
grep -q "loader.*pflash\|<loader" <<<"$xml" \
    || die "domain '${dom:-$NODE}' has a TPM but is NOT UEFI. On a BIOS domain the firmware
measures the boot sector and the partition table and nothing in the filesystem, so a
PCR policy blesses ANY payload — the gate would pass and mean nothing. Re-create the
fleet with FLEET_TPM=1 (lib/tpm_xml.py sets both, deliberately)."
info "domain '${dom:-$NODE}': TPM 2.0 + UEFI — it can measure the payload it boots"

GW="$(virsh -c qemu:///system net-dumpxml vbmc-pxe 2>/dev/null \
      | sed -nE "s/.*<ip address='([^']+)'.*/\1/p" | head -1)"
[[ -n "$GW" ]] || die "could not read the vbmc-pxe gateway address"
curl -fsS --max-time 5 -o /dev/null "http://$GW:$PORT/maas/deployer/vmlinuz" \
    || die "the deployer ramdisk is not served — see run-e2e-image.sh's preflight"
grep -q 'netboot-chain.sh' /var/lib/libvirt/tftp-vbmc/boot.ipxe 2>/dev/null \
    || die "the PXE network's boot.ipxe is not the per-node chain (./netboot-chain.sh install)"

# THE UEFI NETBOOT GAP, checked here because it would otherwise be a silent
# timeout. The network hands every client `boot.ipxe` — an iPXE *script*, which
# only works because a BIOS node's iPXE option ROM chainloads it. This node is
# UEFI (it has to be, or it measures nothing), and its firmware would TFTP that
# script and try to execute it as a UEFI binary. The deployer would never load.
#
# The fix is arch-conditional DHCP: serve `ipxe.efi` to UEFI clients (option 93
# = client arch 7/9) and keep `boot.ipxe` for BIOS. libvirt passes that through
# to dnsmasq via the dnsmasq: namespace on the network XML:
#
#   <network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
#     <dnsmasq:options>
#       <dnsmasq:option value='dhcp-match=set:efi64,option:client-arch,7'/>
#       <dnsmasq:option value='dhcp-boot=tag:efi64,ipxe.efi'/>
#     </dnsmasq:options>
#
# plus ipxe.efi in the TFTP root. Until that lands this run cannot netboot its
# deployer, so it says so now instead of timing out twice.
if ! sudo -n test -f /var/lib/libvirt/tftp-vbmc/ipxe.efi 2>/dev/null \
   && [[ ! -f /var/lib/libvirt/tftp-vbmc/ipxe.efi ]]; then
    die "this node is UEFI, but the PXE network serves only 'boot.ipxe' (an iPXE SCRIPT)
and the TFTP root has no ipxe.efi. A UEFI firmware cannot execute a script as a boot
binary, so the deployer would never load and this run would time out with an empty
console. Install a UEFI netboot path first — see the comment above this check in
$0 for the exact dnsmasq passthrough, and copy ~/netboot/ipxe.efi into
/var/lib/libvirt/tftp-vbmc/."
fi

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

# ── the enrolment boot: lay the image down with the PLAIN image driver ──────
step "deploy #1 — enrolment boot (plain 'image' driver) to learn what this image measures"
# Nobody can predict a firmware's measurements, so the policy has to come from a
# real boot of this exact image. That boot cannot be a MEASURED deploy — the gate
# would refuse it for having no policy, which is the point of deploy #0. So the
# enrolment boot uses the plain `image` driver: identical lay-down, identical
# payload, no attestation gate. This is exactly how it works in life: image a
# golden machine, observe what it measures, pin that, then enforce.
st="$( ( "$MAAS" state "$NODE" ) 2>/dev/null )"
[[ "$st" == error ]] && { ( "$MAAS" retry "$NODE" ) >/dev/null 2>&1; ( "$MAAS" provide "$NODE" ) >/dev/null 2>&1; }
"$MAAS" deploy "$NODE" --driver image --image "$IMAGE" \
    || die "the enrolment boot failed — the node could not even lay down and boot the measured
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

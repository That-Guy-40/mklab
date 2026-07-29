#!/usr/bin/env bash
# image-measured.sh — `image`, plus an ATTESTATION gate before activation.
#
# The whole-disk lay-down is identical to ../drivers/image.sh (it delegates), so the
# only thing this driver adds is the last question: *did the machine that came up
# measure into the state we expected?* A node reaches `active` only if it produces a
# PCR quote that (a) verifies against the trusted attestation key and (b) matches the
# expected PCR policy for the image it was given. Anything else fails the gate, and the
# §4b machinery does the rest — roll back to the previous good image, or `error`.
#
# ─────────────────────────────────────────────────────────────────────────────────
# HONEST FRAMING, AND IT IS LOAD-BEARING. In this lab the TPM is **swtpm under QEMU**.
# That is faithful *plumbing* and it is NOT A TRUST ANCHOR: anything that can read the
# emulator's userspace can forge the PCR state and the AK, so a passing attestation
# here proves the MECHANISM and the REFUSAL PATH, not the integrity of a machine. On
# real hardware the anchor is a discrete TPM whose endorsement key is certified by the
# manufacturer, and the verifier must pin *that* chain. The sibling lab states the same
# caveat about its own spikes — see ../systemd261-nixos-measured-boot/README.md, whose
# spikes D/G are where the measured-boot and sealed-LUKS mechanics were proven.
# ─────────────────────────────────────────────────────────────────────────────────
#
# What the node must produce (delivered like any other fact — see metadata-serve.sh):
#   $MAAS_STATE/<node>/quote.json      PCR lines, "<index>:<hex-digest>", one per line
#   $MAAS_STATE/<node>/quote.json.sig  a detached CMS signature over it, by the AK
# What the image must declare:
#   $MAAS_IMAGES_DIR/<image>/pcrs.expected   the policy, same "<index>:<hex>" form
#
# Verbs: describe | stage | verify | deploy | health  (stage/deploy delegate to image.sh)
#        + capture-policy <image> <node> — write pcrs.expected from a measured boot
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_DRV="$HERE/image.sh"

verb="${1:-}"; shift || true
nd() { printf '%s/%s\n' "${MAAS_STATE:?image-measured: MAAS_STATE not set}" "$1"; }
die() { echo "image-measured: $*" >&2; exit 1; }

case "$verb" in

describe)
    echo "image+measured: as 'image', but the node only reaches active if it attests to the expected PCR state. swtpm here is faithful plumbing, NOT a trust anchor"
    ;;

stage|deploy)
    exec "$IMAGE_DRV" "$verb" "$@" ;;

# capture-policy <image> <node> — turn the quote a node just produced into that
# image's pcrs.expected. THE POLICY MUST COME FROM A MEASURED BOOT, not from a
# human's idea of what the PCRs ought to be: nobody can predict a firmware's
# measurements, and a policy written by hand is a policy that never matches.
#
# This is trust-on-first-use, and it is only honest if said out loud: the first
# boot DEFINES the expected state, so it must be a boot you have reason to trust
# (a freshly built image, on a node you just provisioned, before it serves
# anything). Every later boot is then compared against it, which is where the
# gate earns its keep — a node that measures differently afterwards is refused.
#
# Only the indices that are STABLE and payload-bearing go into the policy. PCR4
# is the firmware's measurement of the binary it loaded (the UKI = the payload);
# PCR7 is the secure-boot policy state. The rest are recorded in the quote and
# deliberately not pinned: several move with unrelated platform detail, and a
# policy that fails for reasons nobody can act on gets disabled, which is worse
# than a narrow one that holds.
capture-policy)
    image="${1:?image-measured capture-policy <image> <node>}"; node="${2:?}"
    q="$(nd "$node")/quote.json"
    pol="${MAAS_IMAGES_DIR:?}/$image/pcrs.expected"
    [[ -f "$q" ]] || die "no quote at $q — the node has not attested yet. Deploy it once
(the gate will refuse activation, which is correct) and capture the policy from that boot."
    [[ -d "${MAAS_IMAGES_DIR}/$image" ]] || die "'$image' is not staged"
    : > "$pol"
    {
        printf '# pcrs.expected for %s — CAPTURED from a measured boot of %s
' "$image" "$node"
        printf '# Trust-on-first-use: this boot DEFINED the expected state. It is only
'
        printf '# meaningful if that boot was trustworthy (freshly built image, node just
'
        printf '# provisioned, serving nothing yet).
'
        printf '# PCR4 = the firmware measurement of the loaded binary (the UKI IS the
'
        printf '#        payload, so this is what a swapped kernel changes)
'
        printf '# PCR7 = secure-boot policy state
'
    } >> "$pol"
    for idx in 4 7; do
        line="$(grep -E "^${idx}:" "$q" | head -1)"
        [[ -n "$line" ]] || die "the quote from '$node' has no PCR $idx — refusing to write a
policy with a hole in it: an index the node never reports would fail every future check."
        printf '%s
' "$line" >> "$pol"
    done
    printf 'image-measured: captured %s from %s'"'"'s quote:
' "$pol" "$node" >&2
    grep -vE '^#' "$pol" | sed 's/^/  /' >&2
    ;;

verify)
    # F2 as usual, PLUS: an image with no expected-PCR policy cannot be attested, and
    # silently skipping the gate would be the worst possible failure — the node would
    # activate unmeasured while the driver's name promised otherwise.
    image="${1:?image-measured verify <image>}"
    pol="${MAAS_IMAGES_DIR:?}/$image/pcrs.expected"
    [[ -f "$pol" ]] \
        || die "'$image' declares no expected PCR policy ($pol). Refusing: this driver's
whole purpose is the attestation gate, and an image with nothing to attest AGAINST would
sail through it. Write the expected PCRs, or deploy it with --driver image instead."
    exec "$IMAGE_DRV" verify "$image"
    ;;

health)
    node="${1:?image-measured health <node> <image>}"; image="${2:?}"
    # 1. the image must first be up at all — same gate as the plain image driver.
    "$IMAGE_DRV" health "$node" "$image" || exit 1

    # 2. …and then attest.
    q="$(nd "$node")/quote.json"; sig="$q.sig"
    pol="${MAAS_IMAGES_DIR:?}/$image/pcrs.expected"
    ca="${MAAS_IMAGES_DIR}/trust/ca.crt"
    [[ -f "$q" ]] \
        || { echo "image-measured: '$node' booted but produced NO attestation quote ($q) — refusing to activate an unmeasured node" >&2; exit 1; }
    [[ -f "$sig" ]] \
        || { echo "image-measured: '$node' produced a quote with no signature ($sig) — an unsigned quote is a claim, not evidence" >&2; exit 1; }
    if ! "$HERE/verify-lib.sh" verify "$q" --sig "$sig" --ca "$ca" >/dev/null 2>&1; then
        echo "image-measured: the quote from '$node' does NOT verify against the trusted attestation key — treating it as forged" >&2
        exit 1
    fi

    # 3. compare the measured PCRs against the policy, naming the first divergence.
    # A quote that verifies but measures something else is the interesting case: the
    # machine is honest and is running something you did not expect.
    local_fail=0
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        idx="${line%%:*}"; want="${line#*:}"
        got="$(grep -E "^${idx}:" "$q" | head -1 | cut -d: -f2-)"
        if [[ -z "$got" ]]; then
            echo "image-measured: the quote from '$node' does not contain PCR $idx, which the policy requires" >&2
            local_fail=1
        elif [[ "$got" != "$want" ]]; then
            echo "image-measured: PCR $idx MISMATCH on '$node' — expected ${want:0:16}…, measured ${got:0:16}…. The node is telling the truth about running something other than '$image'" >&2
            local_fail=1
        fi
    done < "$pol"
    [[ $local_fail -eq 0 ]] || exit 1

    echo "image-measured: '$node' attested to the expected PCR state for '$image' (swtpm: mechanism proven, not a trust anchor)" >&2
    exit 0
    ;;

*) echo "image-measured: unknown verb '$verb' (describe|stage|verify|deploy|health|capture-policy)" >&2; exit 2 ;;
esac

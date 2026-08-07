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
    # The ownership question, in two halves — this driver owns an image only if BOTH
    # hold. Until 2026-08-06 it answered "yes" to every name, so `gate()`'s first check
    # could not refuse anything.
    #
    #   1. it is a whole-disk image  — delegated to image.sh, which stage/deploy also
    #      delegate to, so there is one definition of that half and not two.
    #   2. it has an expected-PCR policy — because THIS driver's whole purpose is the
    #      attestation gate, and an image with nothing to attest against sails through
    #      it. `verify` already refuses that, but `deploy --no-verify` skips verify
    #      entirely; describe is then the only gate standing between the operator and a
    #      destructive write. Refuse BEFORE the irreversible step, not after.
    #
    # This does not break trust-on-first-use: the enrollment boot that DEFINES a policy
    # is deployed with `--driver image` (run-e2e-measured.sh deploy #1), and deploy #0
    # exists precisely to assert that a measured deploy without a policy is refused.
    if [[ -n "${1:-}" ]]; then
        img="$1"
        "$IMAGE_DRV" describe "$img" || exit 1
        pol="${MAAS_IMAGES_DIR:?}/$img/pcrs.expected"
        [[ -f "$pol" ]] \
            || die "'$img' declares no expected PCR policy — capture one, or deploy it with --driver image.
Refusing to claim it: this driver's whole purpose is the attestation gate, and an image
with nothing to attest AGAINST would sail through it ($pol).
Capture one from a measured boot of THIS build:
  drivers/image-measured.sh capture-policy $img <node>
or deploy it with --driver image instead."
        printf '  measured = %s PCR index(es) must match on every boot: %s\n' \
            "$(grep -cE '^[0-9]+:' "$pol")" \
            "$(grep -oE '^[0-9]+' "$pol" | tr '\n' ' ' | sed 's/ $//')"
        pol_sha="$(sed -n 's/^# image-sha256: //p' "$pol" | head -1)"
        [[ -n "$pol_sha" ]] \
            && printf '  policy captured from build %s\n' "${pol_sha:0:16}…"
        exit 0
    fi
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
    # WHICH BUILD this policy describes. PCR4 is the firmware's measurement of the UKI,
    # and the UKI is not byte-reproducible (ukify bakes in timestamps), so EVERY rebuild
    # of the golden image changes it. A policy is therefore a fact about one build, not
    # about an image name — and without recording that, a policy captured from build N
    # is silently enforced against build N+1.
    img_sha=""
    [[ -f "${MAAS_IMAGES_DIR}/$image/disk.raw" ]] && command -v sha256sum >/dev/null \
        && img_sha="$(sha256sum "${MAAS_IMAGES_DIR}/$image/disk.raw" | cut -d' ' -f1)"
    : > "$pol"
    {
        [[ -n "$img_sha" ]] && printf '# image-sha256: %s\n' "$img_sha"
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

    # ...and the policy must describe THIS BUILD of the image.
    #
    # FOUND LIVE 2026-07-29, and it is the third sidecar tonight to outlive what it
    # described. PCR4 is the firmware's measurement of the UKI, which is not
    # byte-reproducible, so every rebuild changes it. A pcrs.expected left over from a
    # previous run therefore does not merely go stale — it becomes WRONG, and because it
    # exists at all, `verify` passed and the deploy went ahead: the node was wiped,
    # re-imaged and booted, and only then refused on the PCR mismatch. The refusal
    # arrived after the destructive write instead of before the node was touched.
    #
    # Refusing here restores the ordering the gate promises.
    pol_sha="$(sed -n 's/^# image-sha256: //p' "$pol" | head -1)"
    if [[ -n "$pol_sha" ]] && command -v sha256sum >/dev/null && [[ -f "${MAAS_IMAGES_DIR}/$image/disk.raw" ]]; then
        cur_sha="$(sha256sum "${MAAS_IMAGES_DIR}/$image/disk.raw" | cut -d' ' -f1)"
        [[ "$pol_sha" == "$cur_sha" ]] \
            || die "'$image' has a PCR policy captured from a DIFFERENT build.
  policy describes: ${pol_sha:0:16}…
  staged image is:  ${cur_sha:0:16}…
The UKI is not byte-reproducible, so a rebuild moves PCR4 and this policy can only
refuse. Re-capture it from a boot of THIS build:
  drivers/image-measured.sh capture-policy $image <node>
(or delete $pol to start the trust-on-first-use cycle again)."
    fi
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
    #
    # THE POLICY MUST EXIST, AND IT MUST ACTUALLY COMPARE SOMETHING. Reproduced live
    # 2026-08-06: with no pcrs.expected on disk, `done < "$pol"` failed to open the
    # file, the loop body never ran, local_fail stayed 0, and this driver printed
    # "'nX' attested to the expected PCR state" and exited 0. The only trace was a bash
    # redirect error in the middle of the output. That is a false success in the one
    # gate this driver exists to provide — the LIED rung — and `verify` only hid it
    # because `deploy --no-verify` skips verify entirely.
    #
    # Counting what was compared, rather than only checking the file exists, is the
    # difference between asserting the mechanism and asserting the outcome: an empty
    # policy, or one that is all comments, also compares nothing while existing.
    [[ -f "$pol" ]] \
        || { echo "image-measured: '$image' has no expected-PCR policy ($pol) — refusing to call '$node' attested when there is nothing to attest against" >&2; exit 1; }
    local_fail=0 compared=0
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        idx="${line%%:*}"; want="${line#*:}"
        compared=$((compared + 1))
        got="$(grep -E "^${idx}:" "$q" | head -1 | cut -d: -f2-)"
        if [[ -z "$got" ]]; then
            echo "image-measured: the quote from '$node' does not contain PCR $idx, which the policy requires" >&2
            local_fail=1
        elif [[ "$got" != "$want" ]]; then
            echo "image-measured: PCR $idx MISMATCH on '$node' — expected ${want:0:16}…, measured ${got:0:16}…. The node is telling the truth about running something other than '$image'" >&2
            local_fail=1
        fi
    done < "$pol"
    (( compared > 0 )) \
        || { echo "image-measured: '$image' has an expected-PCR policy that names NO PCR index ($pol) — nothing was compared, so '$node' is not attested" >&2; exit 1; }
    [[ $local_fail -eq 0 ]] || exit 1

    echo "image-measured: '$node' attested to the expected PCR state for '$image' (swtpm: mechanism proven, not a trust anchor)" >&2
    exit 0
    ;;

*) echo "image-measured: unknown verb '$verb' (describe|stage|verify|deploy|health|capture-policy)" >&2; exit 2 ;;
esac

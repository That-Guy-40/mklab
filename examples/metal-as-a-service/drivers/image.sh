#!/usr/bin/env bash
# image.sh — the `image` deploy driver: lay a GOLDEN WHOLE-DISK image onto the node.
#
# A deployer ramdisk netboots, `dd`s a raw whole-disk image over the node's disk,
# registers a UEFI boot entry, and the node then boots what was written. Routes to
# the proven mechanism in ../nixos-ipxe-deploy/ (its "Tier B — image lay-down":
# modules/deployer.nix + stage-deploy.sh --tier-b); this driver does not reimplement
# it, it stages the payload, points the node at it, and gates activation.
#
# WHERE IT SITS BETWEEN ITS TWO SIBLINGS — the three drivers differ in exactly the
# ways the underlying mechanisms differ, and each difference is asserted:
#
#                     install            ramdisk              image
#   completion    node powers itself   (never — a RAM      a console marker from
#   signal        off (installer end)   service stays up)   the deployer ramdisk
#   ends with     bootdev disk         NOTHING (netboots   bootdev disk (the node
#                                       every boot)         now owns its disk)
#   persistence   full                 none                full, and DESTRUCTIVE
#
# The last cell is the one with teeth. `install` writes a filesystem; `image`
# OVERWRITES THE WHOLE DISK, including whatever a previous tenant left. That is why
# `deploy` is only reachable from `available` (post-`cleaning`) and `active` — the
# state machine already enforces it, and this driver records `persistence=full` so
# `release` cannot treat the node as if nothing was written.
#
# Verbs: describe | stage | verify | deploy | health   (`stage` is an operator verb,
# outside the 4-verb dispatch contract, exactly as in ramdisk.sh)
#
# Context from maas-lab.sh: MAAS_BMC, MAAS_REG_BMC, MAAS_STATE, MAAS_IMAGES_DIR,
# MAAS_HEALTH_TIMEOUT. Knobs: MAAS_POLL_INTERVAL, MAAS_POWERON_TIMEOUT,
# MAAS_WRITE_TIMEOUT (how long a whole-disk write may take — default 20x the health
# timeout; dd'ing a few GB is slower than a boot), MAAS_NETBOOT_DIR.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NETBOOT_DIR="${MAAS_NETBOOT_DIR:-$HOME/netboot}"
POLL="${MAAS_POLL_INTERVAL:-5}"

# The deployer ramdisk announces the write is done. Keep this in step with the
# `image` profile in ../milestones.toml (§5c: the terminal milestone and the health
# gate are two consumers of one declaration).
WRITE_DONE_RE="${MAAS_IMAGE_WRITE_MARKER:-(bytes .* copied|Image written|Deploy complete)}"
UP_RE="${MAAS_IMAGE_UP_MARKER:-login:}"

verb="${1:-}"; shift || true

nd() { printf '%s/%s\n' "${MAAS_STATE:?image driver: MAAS_STATE not set (run via maas-lab.sh)}" "$1"; }
node_field() { local f; f="$(nd "$1")/$2"; [[ -f "$f" ]] && cat "$f" || printf '%s' "${3:-}"; }
bmc() { BMC_REGISTRY="${MAAS_REG_BMC:-}" "${MAAS_BMC:?}" "$@"; }
die() { echo "image: $*" >&2; exit 1; }
console_of() {
    local c; c="$(node_field "$1" console "")"
    [[ -n "$c" ]] || c="$(nd "$1")/console.log"
    printf '%s' "$c"
}

# await_power / await_console — the node is reached ONLY through the BMC and its
# console. Never the hypervisor (see install.sh's header for why that matters).
_step() { local s="${POLL%%.*}"; [[ -z "$s" || "$s" -eq 0 ]] && s=1; printf '%s' "$s"; }
await_power() {
    local node="$1" want="$2" to="$3" what="$4" waited=0 st; local step; step="$(_step)"
    while [[ $waited -lt $to ]]; do
        st="$(bmc "$node" power status 2>/dev/null || printf 'unknown')"
        [[ "$st" == *"is $want"* ]] && return 0
        sleep "$POLL"; waited=$(( waited + step ))
    done
    echo "image: timed out after ${to}s waiting for $what (chassis power != $want; last: ${st:-<no answer>})" >&2
    return 1
}
# console_mark <node> — remember how long the console is NOW, so everything waited for
# afterwards has to be NEW output.
#
# A libvirt console log is APPEND-ONLY across boots, and this driver's health gate is a
# grep for a login banner. Without a mark, a second deploy matches the FIRST deploy's
# banner instantly: the gate reports the node up while it is still powering on.
#
# Found live 2026-07-29, in the measured run's deploy #2:
#
#     image: awaiting /login:/ on .../node3.log (timeout 240s)…
#     image: 'node3' booted 'golden-measured' to a login (active)     <- 1 second
#     image-measured: 'node3' booted but produced NO attestation quote
#
# One second against a 240s timeout. The node had not booted; the console still held
# deploy #1's `measured-node login: (attested)`. This is not only a harness problem —
# any two consecutive deploys of this driver on one node hit it, and the second would
# report `active` for a machine that never came up. That is the LIED rung.
#
# The repo had already paid for this once: run-e2e-install.sh rotates the console for
# exactly this reason. Rotating is the harness's workaround; this is the fix.
console_mark() {
    local node="$1" con; con="$(console_of "$node")"
    local n=0; [[ -f "$con" ]] && n="$(stat -c%s "$con" 2>/dev/null || printf 0)"
    printf '%s' "$n" > "$(nd "$node")/console_mark" 2>/dev/null || true
}
await_console() {
    local node="$1" re="$2" to="$3" what="$4" waited=0 con; local step; step="$(_step)"
    con="$(console_of "$node")"
    # Only output written since the mark counts. No mark (an older node record, or a
    # verb that never set one) means start at 0 — the previous behaviour, so nothing
    # regresses for callers that do not mark.
    local mark=0
    [[ -f "$(nd "$node")/console_mark" ]] && mark="$(cat "$(nd "$node")/console_mark" 2>/dev/null || printf 0)"
    [[ "$mark" =~ ^[0-9]+$ ]] || mark=0
    while [[ $waited -lt $to ]]; do
        if [[ -f "$con" ]]; then
            # If the file SHRANK below the mark it was rotated (virtlogd does this at
            # 2 MiB); the mark is meaningless then, so fall back to the whole file.
            local sz; sz="$(stat -c%s "$con" 2>/dev/null || printf 0)"
            if [[ "$sz" -lt "$mark" ]]; then mark=0; fi
            tail -c "+$((mark + 1))" "$con" 2>/dev/null | grep -qE -- "$re" && return 0
        fi
        sleep "$POLL"; waited=$(( waited + step ))
    done
    echo "image: timed out after ${to}s waiting for $what (/$re/ never appeared on $con after byte $mark)" >&2
    return 1
}

case "$verb" in

describe)
    # WITHOUT an argument this is "what does this driver do?".
    #
    # WITH one it is the contract's OWNERSHIP question — "is this image yours?" — which
    # the control plane asks before anything destructive happens (`gate()` in
    # maas-lab.sh: describe -> verify -> deploy -> health). This driver answered "yes"
    # to every name until 2026-08-06, which made that gate a formality: a gate that
    # cannot refuse cannot protect. `install.sh` had the same hole and it cost a live
    # node — an A/B rollback handed it a RAM payload, which it netbooted and then waited
    # 30 minutes for an installer that was never there.
    #
    # This driver's payload is `disk.raw` and nothing else: it dd's a whole disk onto the
    # node. A kernel+initrd+cmdline is the RAM payload `ramdisk.sh stage` writes; a
    # kernel+initrd+ks.cfg is `install.sh`'s. Both are correctly signed images belonging
    # to somebody else, which is exactly why F2 cannot catch this.
    if [[ -n "${1:-}" ]]; then
        img="$1"; dir="${MAAS_IMAGES_DIR:?describe: MAAS_IMAGES_DIR not set}/$img"
        [[ -d "$dir" ]] \
            || die "no image '$img' in $MAAS_IMAGES_DIR — nothing is staged under that name.
Stage one with:  drivers/image.sh stage $img --from <whole-disk.raw>"
        if [[ ! -f "$dir/disk.raw" ]]; then
            # Name what it IS wherever that is knowable: "not mine, and here is whose"
            # beats "not mine", because the operator's next question is always "then
            # whose?". These two shapes are the ones this lab actually stages.
            if [[ -f "$dir/kernel" && -f "$dir/initrd" && -f "$dir/cmdline" ]]; then
                # The FIRST line carries the action, because that is the line the
                # control plane forwards to the operator (gate() in maas-lab.sh).
                die "'$img' is a RAM payload, not a whole-disk image — deploy it with --driver ramdisk.
It is kernel+initrd+cmdline, the shape 'ramdisk.sh stage' writes. This driver dd's
disk.raw onto the node's disk and would have nothing to write."
            fi
            if [[ -f "$dir/kernel" && -f "$dir/initrd" && -f "$dir/ks.cfg" ]]; then
                die "'$img' is an installer payload, not a whole-disk image — deploy it with --driver install.
It is kernel+initrd+ks.cfg, the shape 'install.sh stage' writes."
            fi
            die "'$img' has no disk.raw — it is not a whole-disk image this driver can lay down.
Contents: $(ls -A "$dir" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
        fi
        printf 'image/%s: whole-disk image, %s\n' "$img" "$(du -h "$dir/disk.raw" 2>/dev/null | cut -f1)"
        printf "  deploy = a deployer ramdisk dd's disk.raw onto the node, then it boots from disk\n"
        printf "  active = the node's own console says it booted\n"
        [[ -f "$dir/disk.raw.sha256" ]] \
            && printf '  sha256 = %s\n' "$(cut -d' ' -f1 < "$dir/disk.raw.sha256")"
        [[ -f "$dir/disk.raw.sig" ]] \
            && printf '  signed = yes (F2 verification will check it)\n'
        exit 0
    fi
    echo "image: a deployer ramdisk dd's a golden whole-disk image onto the node, then it boots from disk; active = the deployed image's login. DESTRUCTIVE: the whole disk is overwritten"
    ;;

# stage <name> --from <raw> — copy a whole-disk raw into the signed image store and
# sign it. Separate from deploy because staging touches no hardware and is what you
# re-run after rebuilding the golden image.
stage)
    image="${1:?image stage <name> --from <whole-disk.raw>}"; shift
    src=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from) src="$2"; shift 2 ;;
            *) die "stage: unknown option '$1'" ;;
        esac
    done
    [[ -n "$src" ]] || die "stage: --from <whole-disk.raw> is required"
    [[ -f "$src" ]] || die "stage: no such image: $src
This driver does not build golden images. ../nixos-ipxe-deploy/ does (Tier B):
    examples/nixos-ipxe-deploy/stage-deploy.sh --tier-b
or point --from at any UEFI-bootable whole-disk raw."
    : "${MAAS_IMAGES_DIR:?stage: MAAS_IMAGES_DIR not set}"
    dir="$MAAS_IMAGES_DIR/$image"; mkdir -p "$dir"
    cp -f "$src" "$dir/disk.raw" || die "could not stage the image"
    # Whoever writes disk.raw owns its digest. Re-staging used to overwrite the image
    # and re-sign it while leaving a PREVIOUS build's disk.raw.sha256 in place, so the
    # control plane then published a digest describing an image it no longer had — and
    # the node dutifully reported a mismatch it had not caused (live, 2026-07-29).
    # `deploy` recomputes from the bytes regardless; this keeps the file from ever
    # being wrong in the first place.
    if command -v sha256sum >/dev/null; then
        sha256sum "$dir/disk.raw" | cut -d' ' -f1 \
            | { read -r h; printf '%s  disk.raw\n' "$h" > "$dir/disk.raw.sha256"; } \
            || die "could not record the staged image's sha256"
    else
        # No sha256sum: remove a sidecar rather than leave a stale one behind. An
        # absent digest is a missing fact; a stale one is a false fact.
        rm -f "$dir/disk.raw.sha256"
    fi
    if [[ -d "$MAAS_IMAGES_DIR/trust" ]]; then
        "$HERE/verify-lib.sh" sign "$dir/disk.raw" --keydir "$MAAS_IMAGES_DIR/trust" >/dev/null \
            || die "signing the image failed"
        echo "image: staged + SIGNED '$image' ($(du -h "$dir/disk.raw" | cut -f1)) into $dir" >&2
    else
        echo "image: staged '$image' into $dir — NOT SIGNED (no $MAAS_IMAGES_DIR/trust)." >&2
        echo "image: run 'drivers/verify-lib.sh gen-keys --dir $MAAS_IMAGES_DIR/trust' and re-stage, or deploy --no-verify." >&2
    fi
    ;;

verify)
    image="${1:?image verify <image>}"
    dir="${MAAS_IMAGES_DIR:?}/$image"
    [[ -d "$dir" ]] || die "'$image' is not staged (run: drivers/image.sh stage $image --from <raw>)"
    exec "$HERE/verify-lib.sh" verify-dir "$dir" --ca "${MAAS_IMAGES_DIR}/trust/ca.crt"
    ;;

deploy)
    node="${1:?image deploy <node> <image> <slot>}"; image="${2:?}"; slot="${3:-current}"
    dir="${MAAS_IMAGES_DIR:?}/$image"
    [[ -f "$dir/disk.raw" ]] || die "'$image' is not staged (run: drivers/image.sh stage $image --from <raw>)"
    # The digest the deployer re-reads from the disk after writing. Computed from
    # the staged copy (the one F2 verified host-side), so what the node checks is
    # what the control plane blessed.
    #
    # ALWAYS FROM THE BYTES, NEVER FROM THE SIDECAR. This used to read
    # disk.raw.sha256 when it existed and only compute one otherwise — a cache with
    # no invalidation. Re-staging an image overwrites disk.raw and re-signs it but
    # left that file untouched, so the control plane published the PREVIOUS build's
    # digest for the CURRENT image.
    #
    # Found live 2026-07-29, and the way it surfaced is the point: the node wrote
    # the disk perfectly, read it back, and reported a mismatch — because the value
    # it had been told to expect was three builds old. The deployer's read-back
    # check was added to catch a bad WRITE and instead caught the control plane
    # lying about what it had published. Had the sidecar been trusted one step
    # further, this fleet would have been shipping "verified" deploys whose digest
    # described a different image.
    #
    # sha256 over a couple of hundred MB is well under a second against a deploy
    # measured in minutes, so the cache was never worth the risk it carried.
    raw_sha=""
    if command -v sha256sum >/dev/null; then
        raw_sha="$(sha256sum "$dir/disk.raw" | cut -d" " -f1)"
        if [[ -f "$dir/disk.raw.sha256" ]] \
           && [[ "$(cut -d' ' -f1 < "$dir/disk.raw.sha256")" != "$raw_sha" ]]; then
            # Say it out loud: a stale sidecar means something re-staged this image
            # without refreshing it, and silence here is how that stayed hidden.
            printf 'image: NOTE %s/disk.raw.sha256 was STALE (recorded %s, actual %s) — refreshing it.\n' \
                "$dir" "$(cut -d' ' -f1 < "$dir/disk.raw.sha256" | cut -c1-16)…" "${raw_sha:0:16}…" >&2
        fi
        printf '%s  disk.raw\n' "$raw_sha" > "$dir/disk.raw.sha256" 2>/dev/null || true
    fi
    # The EXACT byte count, handed to the deployer rather than inferred there.
    # The ramdisk used to parse it out of dd's status line, which works with GNU
    # dd and not with busybox's (`0+3201 records out`, no byte total) — so on a
    # real deployer ramdisk the read-back check silently downgraded itself to a
    # warning: the one gate that proves what LANDED, skipped, on the run it was
    # written for. The control plane knows this number exactly; it should say it.
    raw_bytes="$(stat -c%s "$dir/disk.raw" 2>/dev/null || echo 0)"

    # Publish the raw + the per-node deployer script the ramdisk fetches.
    mkdir -p "$NETBOOT_DIR/maas/$image" "$NETBOOT_DIR/maas"
    cp -f "$dir/disk.raw" "$NETBOOT_DIR/maas/$image/disk.raw" 2>/dev/null \
        || die "could not publish the image to the PXE docroot ($NETBOOT_DIR/maas/$image)"
    cp -f "$dir/disk.raw.sig" "$NETBOOT_DIR/maas/$image/" 2>/dev/null || true
    script="$NETBOOT_DIR/maas/$node.ipxe"
    base="http://\${next-server}:8181/maas/$image"
    {
        printf '#!ipxe\n'
        printf '# generated by maas-lab.sh image driver for node %s (slot=%s)\n' "$node" "$slot"
        printf '# the deployer ramdisk writes %s over the node disk, then reports on the console\n' "$image"
        # ip=dhcp is NOT optional: the deployer fetches the image ITSELF, so the
        # kernel must bring eth0 up before the ramdisk's udhcpc can do anything.
        # Every other netbooted payload here carries it (the probe at
        # maas-lab.sh:269, the install catalog's cmdline); this one did not, and
        # the deployer hung on a down interface with no output at all.
        printf 'kernel http://${next-server}:8181/maas/deployer/vmlinuz console=ttyS0 ip=dhcp maas.node=%s maas.image=%s maas.url=%s/disk.raw%s%s\n' \
            "$node" "$image" "$base" "${raw_sha:+ maas.sha256=$raw_sha}" \
            "${raw_bytes:+ maas.bytes=$raw_bytes}"
        printf 'initrd http://${next-server}:8181/maas/deployer/initrd\n'
        # THE TWO HALVES, AND WHICH IS WHICH. iPXE can only verify what IT
        # fetched, and it names an image by its URI basename — so these verify
        # `vmlinuz` and `initrd`, the deployer ramdisk itself. This line used to
        # read `imgverify disk <sig>`: there is no image called `disk` in iPXE's
        # list, because the RAMDISK fetches the raw with wget, not the firmware.
        # The firmware would have refused an unknown image and booted nothing.
        if [[ "${MAAS_NO_IMGVERIFY:-0}" != 1 ]]; then
            [[ -f "$NETBOOT_DIR/maas/deployer/vmlinuz.sig" ]] \
                && printf 'imgverify vmlinuz http://${next-server}:8181/maas/deployer/vmlinuz.sig\n'
            [[ -f "$NETBOOT_DIR/maas/deployer/initrd.sig" ]] \
                && printf 'imgverify initrd http://${next-server}:8181/maas/deployer/initrd.sig\n'
        fi
        # The golden raw is verified by the DEPLOYER, on the node, after the
        # write: maas.sha256= above, checked by reading the disk back. That is
        # the honest place for it — the firmware never sees those bytes, and a
        # host-side CMS signature says nothing about what actually landed.
        printf 'boot\n'
    } > "$script" || die "could not write the node's iPXE script at $script"
    echo "image: wrote $script (golden image '$image' -> whole disk; DESTRUCTIVE)" >&2

    # Mark the console BEFORE anything is powered on, so both gates below (the write
    # marker and, later, the login) can only be satisfied by output from THIS deploy.
    console_mark "$node"
    bmc "$node" bootdev pxe || die "bootdev pxe failed"
    # POWER IT OFF FIRST, or `bootdev pxe` never takes effect.
    #
    # FOUND LIVE 2026-07-29, on the first deploy that ever got this far. `bootdev` only
    # applies at the NEXT boot, and a node that is already running ignores `power on`:
    #
    #   Set Boot Device to pxe
    #   Chassis Power Control: Up/On          <- no-op, it was already on
    #   image: awaiting /… copied/ … (timeout 4800s)
    #
    # A node that just finished a successful deploy is left powered on and `active`, so
    # EVERY second deploy on the same node stalled here: the deployer ramdisk never
    # booted, the write marker never appeared, and the node sat happily running its
    # PREVIOUS image while the control plane waited 80 minutes for a disk write.
    #
    # This is the fault the stale-console bug was hiding. Before console_mark, the health
    # gate matched the earlier deploy's login banner and reported `active` in one second
    # — the node had not rebooted then either; the liar simply covered for it. Fixing the
    # gate did not make the node boot, it made the silence visible.
    #
    # The disk boot below has always done off+on for exactly this reason. So does this.
    if [[ "$(bmc "$node" power status 2>/dev/null || printf unknown)" == *"is on"* ]]; then
        echo "image: '$node' is already running (a previous deploy left it up) — powering it off so 'bootdev pxe' can take effect" >&2
        bmc "$node" power off || die "power off before the deployer boot failed"
        await_power "$node" off "${MAAS_POWERON_TIMEOUT:-60}" "'$node' to power off before the deployer boot" \
            || exit 1
    fi
    bmc "$node" power on    || die "power on failed"
    await_power "$node" on "${MAAS_POWERON_TIMEOUT:-60}" "'$node' to power on for the image lay-down" \
        || exit 1
    # Unlike `install` there is no self-poweroff to wait for: the deployer ramdisk
    # writes and reboots. The write completing is reported on the CONSOLE, which is
    # also what `watch` renders as the image profile's "writing image" milestone.
    await_console "$node" "$WRITE_DONE_RE" \
        "${MAAS_WRITE_TIMEOUT:-$(( ${MAAS_HEALTH_TIMEOUT:-120} * 20 ))}" \
        "the deployer to finish writing '$image' to disk" || exit 1
    echo "image: '$image' written; pointing '$node' at its own disk" >&2
    # The node now owns its disk — unlike a ramdisk node, it must boot from it.
    bmc "$node" bootdev disk || die "bootdev disk failed"
    # off + on, NOT `power cycle`. This lab's own BMC backend (vbmcd) answers
    # `chassis power cycle` with "Invalid data field in request" — it implements
    # on/off/status/reset and not cycle. The mock implemented cycle happily, so
    # the green suite proved a capability the real seam does not have, and this
    # driver would have died at its LAST step, after the destructive write.
    # (MOCK_BMC_NO_CYCLE=1 reproduces the real BMC's refusal headlessly.)
    bmc "$node" power off   || die "power off before the disk boot failed"
    # Re-mark: the health gate that follows greps for a login banner, and the deployer
    # ramdisk has just been talking on this same console. Only the DEPLOYED image's
    # output should be able to satisfy it.
    console_mark "$node"
    bmc "$node" power on    || die "power on into the deployed image failed"
    printf 'full\n' > "$(nd "$node")/persistence" 2>/dev/null || true
    ;;

health)
    node="${1:?image health <node> <image>}"; image="${2:?}"
    to="${MAAS_HEALTH_TIMEOUT:-120}"
    echo "image: awaiting /$UP_RE/ on $(console_of "$node") (timeout ${to}s)…" >&2
    if await_console "$node" "$UP_RE" "$to" "the deployed image to reach a login"; then
        echo "image: '$node' booted '$image' to a login (active)" >&2
        exit 0
    fi
    exit 1
    ;;

*) echo "image: unknown verb '$verb' (describe|stage|verify|deploy|health)" >&2; exit 2 ;;
esac

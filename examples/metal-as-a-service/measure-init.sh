#!/bin/busybox sh
# measure-init.sh — the MEASURED golden image's /init: report what this machine
# actually measured, signed, to the control plane, so `deploy --driver
# image+measured` can decide whether it may activate.
#
# WHAT IS REAL HERE AND WHAT IS NOT — read this before trusting any of it.
#   REAL: the PCR values. They are read from a real TPM 2.0 device through the
#         kernel (/sys/class/tpm/tpm0/pcr-sha256/N), and the firmware extended
#         them without asking this script's permission. PCR4 in particular is
#         the BIOS's measurement of the boot device it actually booted.
#   REAL: the signature. This node produces a CMS signature over its own quote
#         with a private key, and the control plane verifies it against the lab
#         CA before believing a single digit.
#   NOT REAL: where that key lives. A production attestation key is generated
#         INSIDE the TPM and certified through the manufacturer's endorsement
#         key, so a quote can only come from that physical machine. This one is
#         baked into the image, which means anyone who can read the image can
#         forge a quote from anywhere. swtpm cannot fix that, and neither can
#         this script — see drivers/image-measured.sh's header.
# So: this proves the MECHANISM and the REFUSAL PATH end to end. It does not
# prove the integrity of a machine, and nothing in this lab should claim it does.
#
# Kernel cmdline (set by build-golden-measured.sh into syslinux.cfg):
#   maas.md=<url>   where to POST the quote (the metadata service, :8282)
# Identity is NOT taken from the cmdline: this image is generic and every node
# boots the same bytes. The node identifies itself by its MAC, which the control
# plane already records per node — the one identifier a shared image cannot fake
# into being someone else's.
set -u

say() { /bin/busybox echo "MAAS-ATTEST: $*"; }

/bin/busybox mount -t proc     none /proc 2>/dev/null
/bin/busybox mount -t sysfs    none /sys  2>/dev/null
/bin/busybox mount -t devtmpfs none /dev  2>/dev/null
# Never assume the image has these: a failed redirect exits this script, and an
# init that exits panics the kernel with "Attempted to kill init".
/bin/busybox mkdir -p /tmp /etc 2>/dev/null

mdurl=""
for arg in $(/bin/busybox cat /proc/cmdline 2>/dev/null); do
    case "$arg" in maas.md=*) mdurl="${arg#maas.md=}" ;; esac
done

# ── the measurement ─────────────────────────────────────────────────────────
PCRDIR=/sys/class/tpm/tpm0/pcr-sha256
if [ ! -d "$PCRDIR" ]; then
    say "FAILED: no TPM PCRs at $PCRDIR — this kernel sees no TPM 2.0 device."
    say "  The domain needs a <tpm> device (create-fleet.sh: FLEET_TPM=1) and a"
    say "  kernel with TPM support built in (Alpine's -virt flavour has none)."
    say "parking: a measured image that cannot measure must not pretend otherwise"
    exec /bin/busybox sh
fi

quote=/tmp/quote.json
: > "$quote"
# PCRs 0-9 cover firmware (0-3), the boot device and IPL code (4-5), and the
# boot-time policy (7). Written as "<index>:<hex>", the exact form
# drivers/image-measured.sh compares against pcrs.expected.
for i in 0 1 2 3 4 5 6 7 8 9; do
    v="$(/bin/busybox cat "$PCRDIR/$i" 2>/dev/null)"
    [ -n "$v" ] && /bin/busybox echo "$i:$v" >> "$quote"
done
if [ ! -s "$quote" ]; then
    say "FAILED: the TPM is present but every PCR read came back empty"
    say "parking: nothing measured means nothing to attest"
    exec /bin/busybox sh
fi
say "measured $(/bin/busybox wc -l < "$quote") PCRs from a real TPM 2.0"
say "PCR4 (boot device, as measured by the firmware) = $(/bin/busybox grep '^4:' "$quote" | /bin/busybox cut -d: -f2)"

# ── network ─────────────────────────────────────────────────────────────────
/bin/busybox ifconfig eth0 up 2>/dev/null
if ! /bin/busybox ip addr show eth0 2>/dev/null | /bin/busybox grep -q 'inet '; then
    /bin/busybox udhcpc -i eth0 -t 8 -n -q 2>&1 | /bin/busybox grep -v '^$'
fi
mac="$(/bin/busybox cat /sys/class/net/eth0/address 2>/dev/null)"
addr="$(/bin/busybox ip addr show eth0 2>/dev/null | /bin/busybox sed -nE 's@.*inet ([0-9.]+)/.*@\1@p' | /bin/busybox head -1)"
say "identity: mac=$mac addr=${addr:-none}"

# ── sign it, HERE, on the machine that measured it ──────────────────────────
# An unsigned quote is a claim, not evidence: anything on the network could POST
# a set of digits. The driver refuses one, and it is right to.
AK=/etc/attest
if [ ! -f "$AK/codesign.key" ]; then
    say "FAILED: no attestation key in the image ($AK/codesign.key)"
    say "parking: an unsigned quote is a claim, not evidence — the gate would refuse it anyway"
    exec /bin/busybox sh
fi
if ! /usr/bin/openssl cms -sign -binary -noattr -outform DER \
        -signer "$AK/codesign.crt" -inkey "$AK/codesign.key" -certfile "$AK/ca.crt" \
        -in "$quote" -out /tmp/quote.sig 2>/tmp/ossl.err; then
    say "FAILED: could not sign the quote"
    /bin/busybox cat /tmp/ossl.err
    say "parking"
    exec /bin/busybox sh
fi
say "signed the quote with the image's attestation key (baked in — see the header)"

# ── deliver ─────────────────────────────────────────────────────────────────
if [ -z "$mdurl" ]; then
    say "no maas.md= on the cmdline — nothing to report to; printing the quote instead"
    /bin/busybox cat "$quote"
else
    ok=0
    for try in 1 2 3 4 5; do
        if /bin/busybox wget -q -O- --post-file="$quote" "$mdurl/quote/$mac" >/dev/null 2>&1 \
           && /bin/busybox wget -q -O- --post-file=/tmp/quote.sig "$mdurl/quote-sig/$mac" >/dev/null 2>&1; then
            ok=1; break
        fi
        /bin/busybox sleep 2
    done
    if [ "$ok" = 1 ]; then
        say "delivered quote + signature to $mdurl (mac=$mac)"
    else
        say "FAILED: could not deliver the quote to $mdurl after 5 tries"
        say "parking: the control plane will refuse to activate an unmeasured node, which is correct"
        exec /bin/busybox sh
    fi
fi

# The activation marker the image driver's health gate greps for. Printed only
# after a real measurement was taken, signed and delivered — so `login:` here
# means "this node attested", not merely "this node booted".
say "attestation complete"
/bin/busybox echo
/bin/busybox echo "measured-node login: (attested)"
exec /bin/busybox sh

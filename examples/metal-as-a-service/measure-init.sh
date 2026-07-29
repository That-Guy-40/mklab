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
# No module loading here: the image's kernel (micro-linux, see
# build-golden-measured.sh) has VIRTIO_NET and E1000 built in, alongside the TPM.
# This initramfs is busybox and loads nothing by itself, so a kernel whose NIC
# drivers were MODULAR left the node with no interface at all — live on 2026-07-29
# this image measured 10 real PCRs, signed the quote, and then had nowhere to send
# it (`udhcpc: SIOCGIFINDEX: No such device`, `mac=`), which reads like a delivery
# problem and is actually a missing driver. The insmod bridge that worked around it
# is gone with the kernel that needed it; the DIAGNOSIS below is what survives, and
# is what makes the same fault legible in one line if it ever returns.
/bin/busybox ifconfig eth0 up 2>/dev/null
# Diagnose the interface's ABSENCE distinctly from its failure to get a lease. These
# are different faults with different fixes, and collapsing them cost a live run.
if [ ! -e /sys/class/net/eth0 ]; then
    say "FAILED: this machine has NO network interface (no /sys/class/net/eth0)."
    say "  The kernel has no built-in driver for this NIC. Nothing measured here can"
    say "  be reported, so nothing will be."
    say "  Fix: kernel $(/bin/busybox uname -r) needs VIRTIO_NET/E1000 built in (=y, not"
    say "  =m — an initramfs loads no modules). See micro-linux/mlbuild.sh."
    say "parking: a node that cannot report its measurement must not look attested"
    exec /bin/busybox sh
fi
if ! /bin/busybox ip addr show eth0 2>/dev/null | /bin/busybox grep -q 'inet '; then
    # -s explicitly: the compiled-in script path differs between busyboxes (Ubuntu
    # says /etc/udhcpc, micro-linux says /usr/share/udhcpc), and a missing script
    # means udhcpc takes the lease and applies NOTHING, with no error.
    /bin/busybox udhcpc -i eth0 -t 8 -n -q -s /usr/share/udhcpc/default.script 2>&1 \
        | /bin/busybox grep -v '^$'
fi
mac="$(/bin/busybox cat /sys/class/net/eth0/address 2>/dev/null)"
addr="$(/bin/busybox ip addr show eth0 2>/dev/null | /bin/busybox sed -nE 's@.*inet ([0-9.]+)/.*@\1@p' | /bin/busybox head -1)"
say "identity: mac=$mac addr=${addr:-none}"
# A lease obtained but not APPLIED is its own distinct fault, and it looks like
# success: udhcpc prints "lease of X obtained" and exits 0 whether or not its script
# ran. Live on 2026-07-29 the console said exactly that and the interface had no
# address, because the script sat at a path this busybox does not consult. Name it.
if [ -z "$addr" ]; then
    say "FAILED: eth0 has no IPv4 address."
    say "  If a lease WAS obtained above, udhcpc's script did not apply it — udhcpc"
    say "  configures nothing itself, so a missing/unfound default.script takes the"
    say "  lease and silently drops it. Check /usr/share/udhcpc/ and /etc/udhcpc/."
    say "parking: a node that cannot reach the control plane cannot report its measurement"
    exec /bin/busybox sh
fi
# The node identifies itself by MAC; without one the sink has nothing to key on, so
# refuse here rather than POST to /quote/ and have the control plane puzzle over it.
if [ -z "$mac" ]; then
    say "FAILED: eth0 exists but has no MAC address — the control plane keys a quote by MAC."
    say "parking: an unidentifiable quote is not evidence about any particular machine"
    exec /bin/busybox sh
fi

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
    # BASE64 THE SIGNATURE. `busybox wget --post-file` treats the file as a C string:
    # it sends Content-Length = strlen(), so a DER signature is cut at its first 0x00.
    #
    # FOUND LIVE 2026-07-29, on the first deploy whose signature was ever actually
    # verified. Measured with this same busybox 1.36.1:
    #
    #     --post-file <2117-byte DER>     -> Content-Length: 107   (first NUL at 107)
    #     --post-file <base64 of it>      -> Content-Length: 2869  (intact)
    #
    # Nothing errored. The node printed "delivered quote + signature", the sink stored
    # 107 bytes, and the gate then reported the quote as FORGED — because a truncated
    # signature is indistinguishable from a bad one. The transport broke and the node
    # took the blame. There is no curl in this initramfs, so the wire format is base64
    # and lib/metadata.py decodes it at /quote-sig-b64/.
    if ! /usr/bin/openssl base64 -in /tmp/quote.sig -out /tmp/quote.sig.b64 2>/dev/null; then
        say "FAILED: could not base64 the signature for transport"
        say "parking: an unsigned quote is a claim, not evidence — the gate would refuse it"
        exec /bin/busybox sh
    fi
    ok=0
    for try in 1 2 3 4 5; do
        if /bin/busybox wget -q -O- --post-file="$quote" "$mdurl/quote/$mac" >/dev/null 2>&1 \
           && /bin/busybox wget -q -O- --post-file=/tmp/quote.sig.b64 "$mdurl/quote-sig-b64/$mac" >/dev/null 2>&1; then
            ok=1; break
        fi
        /bin/busybox sleep 2
    done
    if [ "$ok" = 1 ]; then
        say "delivered quote + signature to $mdurl (mac=$mac, sig base64 — busybox wget truncates binary)"
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

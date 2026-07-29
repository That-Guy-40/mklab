#!/usr/bin/env bash
# Verdict: `image+measured` refuses to activate a node that cannot prove what it booted.
#
# The lay-down is the plain `image` driver's, so what is under test here is only the
# last question: did the machine that came up measure into the state we expected? Four
# ways that can go wrong, and all four must refuse:
#
#   no quote          it booted and said nothing        → an unmeasured node
#   unsigned quote    a claim, not evidence
#   forged quote      signed by something we do not trust
#   PCR mismatch      signed, trusted, and measuring something ELSE — the interesting
#                     case, because the node is being honest and is still not what we
#                     asked for
#
# Plus the one that would be worst of all: an image with NO expected-PCR policy must be
# refused at `verify`, not silently sail through a gate that has nothing to compare to.
#
# HONEST FRAMING (restated because it is load-bearing): the "TPM" in this lab is swtpm
# under QEMU. This test proves the MECHANISM and the REFUSAL PATH with real OpenSSL CMS
# signatures over real PCR values — it does not prove the integrity of any machine, and
# on real hardware the anchor must be a discrete TPM whose EK is certified by the
# manufacturer. See ../../systemd261-nixos-measured-boot/README.md for the same caveat.
#
# SAFETY: nothing boots, no disk is written, no TPM is touched. The quotes are text
# files signed with the lab's snakeoil CA.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need openssl
trap 'cleanup_sandboxes' EXIT
maas_env
maas_env_drivers
export MAAS_DRIVER_DIR="$LAB_DIR/drivers"        # the REAL image-measured.sh
export MAAS_POLL_INTERVAL=0 MAAS_POWERON_TIMEOUT=5 MAAS_WRITE_TIMEOUT=5 MAAS_HEALTH_TIMEOUT=3
export MOCK_BMC_POWER_DIR="$SANDBOX/power"
export MAAS_NETBOOT_DIR="$SANDBOX/netboot"
DRV="$LAB_DIR/drivers/image-measured.sh"
VL="$LAB_DIR/drivers/verify-lib.sh"

GOLD="$SANDBOX/golden.raw"; printf 'GOLDEN-MEASURED-IMAGE\n' > "$GOLD"
( "$DRV" stage sealed --from "$GOLD" ) >/dev/null 2>&1 || fail "staging via image-measured failed"

# the expected measurement for this image
POL="$MAAS_IMAGES_DIR/sealed/pcrs.expected"
printf '7:aaaa1111bbbb2222cccc3333dddd4444\n11:0f0f0f0f1e1e1e1e2d2d2d2d3c3c3c3c\n' > "$POL"

prep() {
    ( "$MAAS" enroll "$1" --bmc-port "$2" ) >/dev/null 2>&1 || fail "enroll $1"
    ( "$MAAS" manage "$1" )  >/dev/null 2>&1 || fail "manage $1"
    ( "$MAAS" provide "$1" ) >/dev/null 2>&1 || fail "provide $1"
    # the console the plain image gate reads: write completed, then a login
    printf 'Deploying image sealed\n1048576 bytes (1.0 MB) copied\n%s login: \n' "$1" \
        > "$MAAS_STATE/$1/console.log"
}
# quote <node> <pcr-file> [sign:0|1]
quote() {
    local n="$1" src="$2" sign="${3:-1}"
    cp "$src" "$MAAS_STATE/$n/quote.json"
    rm -f "$MAAS_STATE/$n/quote.json.sig"
    [[ "$sign" == 1 ]] && "$VL" sign "$MAAS_STATE/$n/quote.json" \
        --keydir "$MAAS_IMAGES_DIR/trust" >/dev/null 2>&1
    return 0
}

# ── 1. an image with no PCR policy is refused at VERIFY ─────────────────────
( "$DRV" stage unsealed --from "$GOLD" ) >/dev/null 2>&1 || fail "staging 'unsealed' failed"
out="$( ( "$DRV" verify unsealed ) 2>&1 )" \
    && fail "REGRESSION: an image with NO expected-PCR policy passed verify. This driver's whole purpose is the attestation gate; an image with nothing to attest against would sail straight through it while the driver's name promised otherwise"
grep -Fq 'no expected PCR policy' <<<"$out" || fail "the refusal did not name the missing policy (got: ${out//$'\n'/ })"
note "an image with no expected-PCR policy is refused at verify, not silently unmeasured  ✓"

# ── 2. the happy path: a signed, matching quote reaches active ──────────────
prep n1 6250
quote n1 "$POL"
( "$MAAS" deploy n1 --driver image-measured --image sealed ) >/dev/null 2>&1 \
    || fail "a node with a valid, matching attestation did not reach active"
assert_state n1 active
note "signed quote matching the policy -> active  ✓"

# ── 3. no quote at all -> refused ───────────────────────────────────────────
prep n2 6251
rm -f "$MAAS_STATE/n2/quote.json" "$MAAS_STATE/n2/quote.json.sig"
( "$MAAS" deploy n2 --driver image-measured --image sealed ) >/dev/null 2>&1 \
    && fail "REGRESSION: a node that produced NO attestation quote was activated — the gate is not running"
assert_state n2 error
note "booted but attested nothing -> refused (an unmeasured node never activates)  ✓"

# ── 4. an UNSIGNED quote is a claim, not evidence ───────────────────────────
prep n3 6252
quote n3 "$POL" 0                      # correct PCRs, no signature
( "$MAAS" deploy n3 --driver image-measured --image sealed ) >/dev/null 2>&1 \
    && fail "REGRESSION: an UNSIGNED quote was accepted. Anything on the wire can assert the right PCR values; only a signature makes it evidence"
assert_state n3 error
note "unsigned quote refused, even with the right PCR values  ✓"

# ── 5. a FORGED quote — signed, but not by anything we trust ────────────────
prep n4 6253
FAKE="$SANDBOX/fake-ca"; mkdir -p "$FAKE"
"$VL" gen-keys --dir "$FAKE" >/dev/null 2>&1 || skip "could not build a second CA"
cp "$POL" "$MAAS_STATE/n4/quote.json"
"$VL" sign "$MAAS_STATE/n4/quote.json" --keydir "$FAKE" >/dev/null 2>&1 \
    || fail "signing with the untrusted CA failed"
( "$MAAS" deploy n4 --driver image-measured --image sealed ) >/dev/null 2>&1 \
    && fail "REGRESSION: a quote signed by an UNTRUSTED key was accepted — the attestation key is not being pinned to the trust root"
assert_state n4 error
note "quote signed by an untrusted key refused (the AK is pinned to the trust root)  ✓"

# ── 6. the interesting one: honest node, WRONG measurement ─────────────────
prep n5 6254
printf '7:aaaa1111bbbb2222cccc3333dddd4444\n11:ffffffffffffffffffffffffffffffff\n' \
    > "$SANDBOX/other.pcrs"
quote n5 "$SANDBOX/other.pcrs"
out="$( ( "$MAAS" deploy n5 --driver image-measured --image sealed ) 2>&1 )" \
    && fail "REGRESSION: a node whose PCRs do not match the policy was activated. It signed a truthful quote saying it booted something else, and the gate believed the signature instead of reading it"
grep -Fq 'PCR 11 MISMATCH' <<<"$out" \
    || fail "the mismatch was refused but the message does not name WHICH PCR diverged (got: ${out//$'\n'/ })"
assert_state n5 error
note "valid signature, wrong PCR 11 -> refused, naming the divergent register  ✓"

# ── 7. …and a policy PCR the quote omits entirely ───────────────────────────
prep n6 6255
printf '7:aaaa1111bbbb2222cccc3333dddd4444\n' > "$SANDBOX/partial.pcrs"   # no PCR 11
quote n6 "$SANDBOX/partial.pcrs"
out="$( ( "$MAAS" deploy n6 --driver image-measured --image sealed ) 2>&1 )" \
    && fail "REGRESSION: a quote that simply OMITS a required PCR was accepted — silence is not a measurement"
grep -Fq 'does not contain PCR 11' <<<"$out" \
    || fail "the missing-PCR refusal does not name the register (got: ${out//$'\n'/ })"
assert_state n6 error
note "a quote that omits a required PCR is refused — silence is not a measurement  ✓"

# ── the DELIVERY PATH: how a quote reaches the registry at all ──────────────
# Until this landed, nothing in the lab wrote quote.json: the driver's gate was
# real and unfeedable, so every "measured" deploy would have failed for want of a
# quote nobody could deliver. The sink is keyed by MAC, not node name, because a
# measured golden image is GENERIC — every node boots the same bytes, so identity
# must come from the machine rather than from something the payload could claim.
SINKST="$SANDBOX/sink-state"; mkdir -p "$SINKST/nodeS"
printf '52:54:00:ab:cd:ef\n' > "$SINKST/nodeS/mac"
PORT=18311
python3 "$LAB_DIR/lib/metadata.py" serve --state "$SINKST" --port "$PORT" --host 127.0.0.1 >/dev/null 2>&1 &
SINK=$!
sleep 1
kill -0 "$SINK" 2>/dev/null || fail "the metadata service did not start for the sink test"

printf '4:AAAA\n7:BBBB\n' > "$SANDBOX/q.json"
printf '\x30\x82BINARY\x00DER' > "$SANDBOX/q.sig"
curl -sS --data-binary "@$SANDBOX/q.json" "http://127.0.0.1:$PORT/quote/52:54:00:AB:CD:EF" >/dev/null \
    || { kill "$SINK" 2>/dev/null; fail "the sink rejected a quote from a MAC it knows (uppercase — MAC matching must be case-insensitive)"; }
curl -sS --data-binary "@$SANDBOX/q.sig" "http://127.0.0.1:$PORT/quote-sig/52:54:00:ab:cd:ef" >/dev/null \
    || { kill "$SINK" 2>/dev/null; fail "the sink rejected the detached signature"; }
code_unknown="$(curl -sS -o /dev/null -w '%{http_code}' --data-binary "@$SANDBOX/q.json" "http://127.0.0.1:$PORT/quote/aa:bb:cc:dd:ee:ff")"
code_trav="$(curl -sS -o /dev/null -w '%{http_code}' --data-binary "@$SANDBOX/q.json" "http://127.0.0.1:$PORT/quote/..%2f..%2fetc")"
kill "$SINK" 2>/dev/null                     # by PID: never by pattern
[[ -f "$SINKST/nodeS/quote.json" ]] || fail "the sink accepted a quote but wrote no quote.json"
cmp -s "$SANDBOX/q.sig" "$SINKST/nodeS/quote.json.sig" \
    || fail "REGRESSION: the stored signature is not byte-identical to what was POSTed. A CMS signature is DER, not text — one mangled byte and every quote fails to verify for a reason nobody will find"
[[ "$code_unknown" == 404 ]] \
    || fail "REGRESSION: a quote from a MAC no enrolled node owns was accepted ($code_unknown). The registry is the only authority on which machine is which; anything else lets a stranger attest as a node"
[[ "$code_trav" == 400 ]] \
    || fail "REGRESSION: a path-traversal MAC was not rejected ($code_trav) — the sink writes files under the state dir by that name"
note "the sink records quotes keyed by MAC (case-insensitive, binary-safe), and refuses an unknown MAC and a traversal  ✓"

# ── capture-policy: the policy must come FROM a measured boot ───────────────
# Nobody can predict a firmware's measurements, so a hand-written pcrs.expected is
# a policy that never matches. capture-policy turns a real quote into one — which
# is trust-on-first-use, and only honest because the driver says so out loud.
CPIMG="$MAAS_IMAGES_DIR/cap-img"; mkdir -p "$CPIMG"
mkdir -p "$MAAS_STATE/capnode"
printf '0:1111\n4:CAFEBABE\n7:D00DFEED\n' > "$MAAS_STATE/capnode/quote.json"
( "$LAB_DIR/drivers/image-measured.sh" capture-policy cap-img capnode ) >/dev/null 2>&1 \
    || fail "capture-policy failed on a quote that contains both required PCRs"
grep -q '^4:CAFEBABE$' "$CPIMG/pcrs.expected" \
    || fail "capture-policy did not record PCR4 — the register that actually tracks the payload"
grep -q '^7:D00DFEED$' "$CPIMG/pcrs.expected" || fail "capture-policy did not record PCR7"
grep -q '^0:' "$CPIMG/pcrs.expected" \
    && fail "capture-policy pinned PCR0 as well. Only stable, payload-bearing registers belong in a policy: one that fails for reasons nobody can act on gets disabled, which is worse than a narrow one that holds"
printf '0:1111\n7:D00DFEED\n' > "$MAAS_STATE/capnode/quote.json"     # no PCR4
( "$LAB_DIR/drivers/image-measured.sh" capture-policy cap-img capnode ) >/dev/null 2>&1 \
    && fail "REGRESSION: capture-policy wrote a policy from a quote missing PCR4 — a policy with a hole in it fails every future check, for a register the node never reports"
note "capture-policy pins PCR4+PCR7 from a real quote, and refuses a quote that lacks one  ✓"

pass "image+measured activates only on a signed, trusted, matching attestation: no quote / unsigned / forged / mismatched / incomplete are each refused by name (mechanism proven on swtpm, which is NOT a trust anchor)"

#!/usr/bin/env bash
# registry-lab.sh — a rootless OCI registry with real TLS, anchored to the SHARED lab root
# CA, and a push/pull round trip that proves the bytes survived.
#
# WHY THIS LAB EXISTS (TODO 15.6). `push` was a verb in exactly one driver
# (phase3-docker/lab-docker.sh) and there was nowhere to push TO: `registry:2` appeared in
# ZERO files repo-wide. A verb whose destination does not exist is a verb nobody has ever
# watched work. And the repo had a firm opinion about signed BOOT artifacts (netboot's
# imgverify chain, examples/lab-ca) and none at all about container ones.
#
# WHAT IT IS NOT. Not a production registry: no authentication, loopback-only, delete
# disabled. The subject is the TLS chain and the round trip, and saying so is the point —
# an unauthenticated registry reachable from the LAN is a write-anything artifact store.
#
# THE CONTROL IS THE WHOLE VALUE. "podman push succeeded" proves nothing about TLS: the
# usual way to make a lab registry work is `--tls-verify=false`, which is indistinguishable
# from a working chain right up until it matters. So `demo` pushes TWICE — once with the
# CA and once without — and requires the second to FAIL with an x509 error. Measured
# 2026-08-30: without the CA, `pinging container registry localhost:5000: tls: failed to
# verify certificate: x509: certificate signed by unknown authority`.
#
# IT USES --cert-dir, NOT ~/.config/containers/certs.d. Installing the CA into podman's
# global trust would make every later run pass for a reason that has nothing to do with
# this lab, on a machine that never asked for it. The flag keeps the trust decision inside
# the command being demonstrated.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Overridable so a test can copy this lab elsewhere and still reach the real driver;
# without that the resolved-path check below silently degrades to a warning, which is
# how a control stops controlling anything.
REPO="${REPO:-$(cd -- "$HERE/../.." && pwd)}"
LAB_CA="$REPO/examples/lab-ca"
SPEC="$HERE/local-registry.toml"            # portable: @LAB_DIR@, resolved by the driver
STATE="$HERE/state"
CERTS="$STATE/certs"
DATA="$STATE/data"
CERTDIR="$STATE/certdir"        # a podman --cert-dir: holds ca.crt and nothing else
CN="${REGISTRY_CN:-registry.lab}"
HOSTPORT="${REGISTRY_HOSTPORT:-localhost:5000}"
IMAGE_REF="$HOSTPORT/lab-hello:v1"

log()  { printf '[registry-lab] %s\n' "$*" >&2; }
die()  { printf '[registry-lab] ERROR: %s\n' "$*" >&2; exit 1; }

# STDOUT, not stderr: `--help` is the tool answering a question, and every other driver
# here prints it that way. tools/check-usage-is-data.sh reads anything on stderr during
# `--help` as evidence that the help text EXECUTED something, which is the defect it
# exists for — so writing help to stderr makes a correct tool indistinguishable from one
# whose heredoc is running commands. The error path below still uses stderr.
usage() {
    cat <<USAGE
Usage: registry-lab.sh <verb>

  certs     issue a TLS server leaf from the SHARED lab root CA and stage it
  up        start the registry (via phase4-podman/lab-podman.sh)
  demo      push an image, pull it back, compare digests — and prove TLS is
            really being verified by pushing once WITHOUT the CA
  status    is it listening, and does its certificate chain to the shared root
  down      stop and remove the container
  paths     print the absolute volume lines this checkout needs
  spec-check  check the TRACKED spec stayed portable (@LAB_DIR@, no absolute
            host path) — the driver resolves it at parse time

The registry is loopback-only and unauthenticated on purpose; see the header.
USAGE
}

need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# ── THE DRIVER EXPANDS THE PLACEHOLDER NOW (TODO 15.11) ─────────────────────────────────
# podman needs absolute host paths for a bind mount, so this lab's spec used to carry one —
# and this driver rendered @LAB_DIR@ into a gitignored copy because phase 4 could not.
#
# It can, since 15.11: all four phase drivers carry a byte-identical _expand_spec_paths and
# resolve @LAB_DIR@ / @REPO@ / @NETBOOT@ / @HOME@ when they parse a spec. So the rendering
# step is gone — one mechanism, in the driver, rather than a private one per lab. The spec
# is handed to lab-podman.sh exactly as it is tracked.
want_paths() { printf '%s\n%s\n' "$CERTS:/certs:ro,Z" "$DATA:/var/lib/registry:Z"; }
spec_check() {
    [[ -r "$SPEC" ]] || die "no spec at $SPEC"
    grep -qF '@LAB_DIR@' "$SPEC" \
        || die "the spec has no @LAB_DIR@ placeholder left in it.
  Someone has substituted a real path into the TRACKED file, which makes it true on one
  machine and false on every other — the defect the placeholder exists to prevent."
    if grep -nE '"(/[A-Za-z0-9._-]+)+/state/' "$SPEC" >&2; then
        die "the TRACKED spec contains an absolute host path. That is the 15.7 shape: true on
  one machine, false on every other, and unrescuable by any amount of checking."
    fi
    # …and it must resolve to THIS lab's directories. Dropping `render` also dropped this
    # comparison, and the lab's own control caught it within the minute: without it a
    # volume line could drift from what the driver mounts and nothing would say so. Ask
    # the phase-4 parser, which is the thing that will actually do it.
    local json missing=0 w
    json="$(bash -c 'source "$1" >/dev/null 2>&1; toml_to_json "$2"' _ \
              "$REPO/phase4-podman/lab-podman.sh" "$SPEC" 2>/dev/null)"
    if [[ -z "$json" ]]; then
        # NOT a silent pass. Either the driver is unreachable or no TOML parser is
        # installed; both mean the resolved paths are an UNKNOWN, and an unchecked thing
        # must not read as a checked one.
        die "cannot ask $REPO/phase4-podman/lab-podman.sh what this spec resolves to — the
  driver is missing, or no TOML parser (tomlq/yq/dasel) is installed. The volume paths were
  NOT checked, which is not the same as their being right."
    fi
    while IFS= read -r w; do
        grep -qF -- "$w" <<<"$json" || { printf '  MISSING from what the driver resolves:\n    %s\n' "$w" >&2; missing=1; }
    done < <(want_paths)
    (( missing == 0 )) \
        || die "the phase-4 driver does not resolve this spec to the volume lines this lab needs.
  Either @LAB_DIR@ is not being expanded, or the spec and want_paths() have drifted apart,
  and the container would mount something other than this lab's state directory."
    log "spec is portable, and the driver resolves it to ${CERTS#"$REPO"/} and ${DATA#"$REPO"/}"
}

cmd_certs() {
    need openssl
    [[ -x "$LAB_CA/issue-server-cert.sh" ]] || die "the shared lab CA is missing at $LAB_CA"
    [[ -r "$LAB_CA/lab-ca.crt" ]] \
        || die "no shared root CA yet — run examples/lab-ca/make-ca.sh first (once, ever)"
    mkdir -p "$CERTS" "$DATA" "$CERTDIR"
    log "issuing a TLS leaf for $CN from the SHARED root ($LAB_CA/lab-ca.crt)"
    ( cd "$LAB_CA" && ./issue-server-cert.sh "$CN" DNS:localhost IP:127.0.0.1 ) >&2 \
        || die "issue-server-cert.sh failed"
    local ks="${LAB_CA_KEYDIR:-$LAB_CA/private}/certs"
    cp "$ks/$CN-fullchain.crt" "$CERTS/tls.crt" || die "no fullchain for $CN in $ks"
    cp "$ks/$CN.key"           "$CERTS/tls.key" || die "no key for $CN in $ks"
    # The container runs as a different uid in a rootless userns and only reads these.
    chmod 644 "$CERTS/tls.key"
    # The client half: a --cert-dir holding ONLY the root. Not podman's global trust store,
    # for the reason in the header.
    cp "$LAB_CA/lab-ca.crt" "$CERTDIR/ca.crt"
    log "staged: $CERTS/tls.{crt,key} and $CERTDIR/ca.crt"
    log "the anchor is $(openssl x509 -in "$LAB_CA/lab-ca.crt" -noout -fingerprint -sha256 | sed 's/^.*=//')"
}

cmd_up() {
    need podman
    spec_check
    [[ -r "$CERTS/tls.crt" && -r "$CERTS/tls.key" ]] \
        || die "no TLS material staged — run: $0 certs"
    # Refuse before starting rather than after: a port already in use gives podman's error,
    # which names a socket and not the thing holding it.
    if ss -lnt 2>/dev/null | grep -qE "127\\.0\\.0\\.1:${HOSTPORT##*:}[[:space:]]"; then
        die "127.0.0.1:${HOSTPORT##*:} is already in use — $(ss -lntp 2>/dev/null | grep -E "127\\.0\\.0\\.1:${HOSTPORT##*:}[[:space:]]" | head -1)"
    fi
    log "starting via the phase-4 driver (no one-off podman run)"
    "$REPO/phase4-podman/lab-podman.sh" up --config "$SPEC" >&2 || die "lab-podman.sh up failed"
    cmd_status
}

cmd_status() {
    need curl
    local out code
    code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$LAB_CA/lab-ca.crt" \
             "https://$HOSTPORT/v2/" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
        log "https://$HOSTPORT/v2/ answers 200, verified against the SHARED root"
        out="$(curl -s --cacert "$LAB_CA/lab-ca.crt" "https://$HOSTPORT/v2/_catalog" 2>/dev/null || true)"
        log "catalog: ${out:-<none>}"
        return 0
    fi
    log "https://$HOSTPORT/v2/ did not answer 200 with the shared root (got '${code:-none}')"
    return 1
}

cmd_demo() {
    need podman; need curl
    [[ -r "$CERTDIR/ca.crt" ]] || die "no client CA staged — run: $0 certs"
    cmd_status >/dev/null || die "the registry is not answering — run: $0 up"

    local work; work="$(mktemp -d)"
    trap 'rm -rf -- "$work"' RETURN
    printf 'FROM scratch\nCOPY hello.txt /hello.txt\n' > "$work/Containerfile"
    printf 'lab-registry round-trip %s\n' "$(date -u +%FT%TZ)" > "$work/hello.txt"
    log "building a scratch image (no network, no base layer)"
    podman build -q -t "$IMAGE_REF" -f "$work/Containerfile" "$work" >/dev/null 2>&1 \
        || die "could not build the demo image"

    # ── THE CONTROL, FIRST. If this succeeds, everything below is meaningless: it would
    # mean the client is not verifying anything and the CA is decoration.
    log "CONTROL: pushing with NO CA — this must be refused"
    local out
    out="$(podman push --cert-dir /nonexistent-certs "$IMAGE_REF" 2>&1)" && {
        die "CONTROL DID NOT FIRE: the push SUCCEEDED with no CA. TLS is not being verified,
  so a working chain and a --tls-verify=false lab are indistinguishable here."
    }
    grep -q 'x509' <<<"$out" \
        || die "the CA-less push failed, but not with a certificate error — so this proves
  nothing about the chain. Output: $(tail -1 <<<"$out")"
    log "  refused: $(grep -o 'x509:.*' <<<"$out" | head -1)"

    log "pushing WITH the shared root"
    podman push --cert-dir "$CERTDIR" "$IMAGE_REF" >/dev/null 2>&1 \
        || die "push failed even with the CA staged"

    # ── the round trip, asserted on the DIGEST rather than on the tag. A tag is a mutable
    # pointer; "the tag came back" is true of a registry that returned something else.
    local pushed
    pushed="$(curl -s --cacert "$LAB_CA/lab-ca.crt" -D- -o /dev/null \
                -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
                "https://$HOSTPORT/v2/lab-hello/manifests/v1" 2>/dev/null \
              | grep -i '^docker-content-digest' | tr -d '\r' | awk '{print $2}')"
    [[ -n "$pushed" ]] || die "the registry did not report a manifest digest for lab-hello:v1"
    podman rmi -f "$IMAGE_REF" >/dev/null 2>&1
    podman pull -q --cert-dir "$CERTDIR" "$IMAGE_REF" >/dev/null 2>&1 \
        || die "could not pull the image back"
    local back
    back="$(podman image inspect "$IMAGE_REF" --format '{{index .RepoDigests 0}}' 2>/dev/null)"
    [[ "$back" == *"$pushed"* ]] \
        || die "ROUND TRIP FAILED: pushed $pushed, got back '$back'"
    log "round trip: $pushed — identical going in and coming out"
    log "OK: TLS chains to the shared root, an untrusted client is refused, and the digest survives"
}

cmd_down() {
    need podman
    "$REPO/phase4-podman/lab-podman.sh" down --config "$SPEC" >&2 || true
    log "down"
}

case "${1:-}" in
    certs)      cmd_certs ;;
    up)         cmd_up ;;
    demo)       cmd_demo ;;
    status)     cmd_status ;;
    down)       cmd_down ;;
    paths)      want_paths ;;
    spec-check) spec_check ;;
    -h|--help|help) usage; exit 0 ;;
    "")         usage >&2; exit 1 ;;
    *)          printf '[registry-lab] unknown verb: %s\n' "$1" >&2; usage >&2; exit 1 ;;
esac

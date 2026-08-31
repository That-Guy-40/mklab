#!/usr/bin/env bash
# airgap.sh — build a small SIGNED Debian mirror, then install from it inside a network
# namespace that has no route anywhere. The install is the point; the air gap is what
# makes the install mean something.
#
# WHY THIS LAB EXISTS (TODO 15.5). examples/package-mirror-ram/ serves a Debian mirror
# tree, and until now nothing in this repo installed from it — the four zero-touch install
# labs all point at deb.debian.org. A mirror with no consumer is a producer nobody has
# checked. This lab is the consumer.
#
# WHAT "AIR-GAPPED" HAS TO MEAN HERE. The cheap check is "the config names a local
# mirror" — and it is a liar, because a machine that can still reach deb.debian.org will
# happily fall back to it, or was never using the local mirror in the first place, and
# both look identical from the outside. So the install runs inside `unshare -rn`: a fresh
# network namespace whose only interface is loopback. There is no route to anywhere. The
# HTTP server holding the mirror is started INSIDE that namespace, on 127.0.0.1.
#
#   `controls` is the deliverable, not `install`. Four rows, and three of them must fail:
#     C1  the same command, in the same namespace, aimed at deb.debian.org  -> must FAIL
#         (otherwise the namespace is not isolated and "it installed offline" proves nothing)
#     C2  the local mirror, verified against DEBIAN's keyring instead of ours -> must FAIL
#         (otherwise the signature check is off, and a mirror anyone can rewrite is trusted)
#     C3  one .deb corrupted in the tree                                    -> must FAIL
#         (otherwise the per-package hashes are decorative)
#     C4  the same install again, tree repaired                             -> must PASS
#         (otherwise C3's failure was leftover state, not the corruption)
#
# THE TREE IS THE SAME TREE package-mirror-ram SERVES. Its nginx has `root /srv/mirror;`,
# so the mirror URL is the server root with no path prefix and `dists/` + `pool/` sit
# directly beneath it. `state/mirror/` here has exactly that layout, which is what makes
# this an actual consumer-side proof of that lab rather than a lab that merely mentions it.
#
# WHAT IS *NOT* PROVEN, said plainly. `debootstrap --foreign` stops after downloading and
# unpacking; the second stage (`dpkg --configure`) needs real root, which this rootless
# run does not have. That stage does no network I/O at all, so the mirror-consuming half
# of the install is the half covered here — but it is a half, and MANUAL_TESTING.md
# carries the rooted full install and the d-i/preseed variant that finish the job.
set -euo pipefail

LAB_PROG="$(basename -- "$0")"
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${AIRGAP_STATE_DIR:-$LAB_DIR/state}"
MIRROR_DIR="$STATE_DIR/mirror"
KEYRING="$STATE_DIR/mirror-key.gpg"
STAMP="$STATE_DIR/mirror.stamp"
GNUPG_DIR="$STATE_DIR/gnupg"

SUITE="${AIRGAP_SUITE:-trixie}"
ARCH="${AIRGAP_ARCH:-amd64}"
UPSTREAM="${AIRGAP_UPSTREAM:-http://deb.debian.org/debian}"
PORT="${AIRGAP_PORT:-8099}"
BIND="${AIRGAP_BIND:-127.0.0.1}"
DEBIAN_KEYRING="${AIRGAP_DEBIAN_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}"

log()  { printf '  %s\n' "$*" >&2; }
die()  { printf '%s: %s\n' "$LAB_PROG" "$*" >&2; exit 1; }
need() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"; done; }

usage() {
    cat <<EOF
$LAB_PROG — install Debian from a local signed mirror with no route to the internet

USAGE
  $LAB_PROG mirror [--refresh]   build the partial signed mirror under state/ (needs upstream)
  $LAB_PROG install              bootstrap from it inside a loopback-only netns
  $LAB_PROG controls             the four rows: three that must FAIL, one that must PASS
  $LAB_PROG serve [--bind ADDR]  serve the tree on a real address, for the author-run d-i half
  $LAB_PROG status               what exists, and what it is bound to
  $LAB_PROG paths                print the resolved paths this run would use
  $LAB_PROG clean                remove state/ (mirror, key, bootstrapped trees)
  $LAB_PROG help

ENVIRONMENT
  AIRGAP_SUITE      Debian suite            (default: $SUITE)
  AIRGAP_ARCH       Debian architecture     (default: $ARCH)
  AIRGAP_UPSTREAM   mirror to build FROM    (default: $UPSTREAM)
  AIRGAP_PORT       loopback port in the ns (default: $PORT)
  AIRGAP_STATE_DIR  where state lives       (default: <lab>/state)

The mirror build is the only step that touches the network. Everything after it runs
with no route: the port above is bound inside the namespace, so it cannot collide with
anything on the host and nothing on the host can reach it.
EOF
}

# ─── mirror ─────────────────────────────────────────────────────────────────────────────

mirror_identity() { printf '%s %s %s\n' "$SUITE" "$ARCH" "$UPSTREAM"; }

# The mirror is a CACHE, so it is bound to its subject and a mismatch is refused BY NAME
# rather than quietly served: the stamp carries the suite, the arch, the upstream it was
# built from and the sha256 of the upstream InRelease it was built against. Change any of
# those and the tree on disk is describing something that is no longer true.
mirror_is_current() {
    [[ -r "$STAMP" && -r "$KEYRING" && -d "$MIRROR_DIR/dists/$SUITE" ]] || return 1
    local want got
    want="$(mirror_identity)"
    got="$(head -1 "$STAMP")"
    [[ "$want" == "$got" ]] || return 1
    return 0
}

cmd_mirror() {
    local refresh=""
    [[ "${1:-}" == "--refresh" ]] && refresh=1
    need debootstrap curl gpg gpgv python3 xz

    if [[ -z "$refresh" ]] && mirror_is_current; then
        log "mirror already built for $(mirror_identity) — pass --refresh to rebuild"
        return 0
    fi

    [[ -r "$DEBIAN_KEYRING" ]] \
        || die "missing $DEBIAN_KEYRING — the upstream fetch is verified against Debian's own keyring, so this is not optional. Install the debian-archive-keyring package."

    mkdir -p "$STATE_DIR"
    rm -rf "$MIRROR_DIR"; mkdir -p "$MIRROR_DIR"

    # 1. the CLOSURE is derived, not written down. debootstrap itself is asked which
    #    packages a minbase install of this suite needs; a hand-kept list would be a
    #    cached fact about someone else's archive.
    log "asking debootstrap for the $SUITE/$ARCH minbase closure (this fetches the upstream index)"
    local pkgs tmpd
    tmpd="$(mktemp -d)"
    pkgs="$(debootstrap --print-debs --variant=minbase --arch="$ARCH" "$SUITE" "$tmpd/x" "$UPSTREAM" 2>/dev/null)" \
        || { rm -rf "$tmpd"; die "debootstrap --print-debs failed against $UPSTREAM (no network, or an unknown suite)"; }
    rm -rf "$tmpd"
    [[ -n "$pkgs" ]] || die "debootstrap --print-debs returned an EMPTY closure — an empty mirror would build cleanly and install nothing"

    # 2. fetch the upstream index THROUGH a verified chain: InRelease is checked with
    #    Debian's keyring, the Packages hash comes out of that verified file, and every
    #    .deb is checked against a hash out of Packages. Nothing here is trusted because
    #    it arrived over the wire.
    log "fetching + verifying the upstream index, then $(printf '%s' "$pkgs" | wc -w) packages"
    local upstream_sha
    upstream_sha="$(AIRGAP_PKGS="$pkgs" python3 - "$UPSTREAM" "$MIRROR_DIR" "$SUITE" "$ARCH" "$DEBIAN_KEYRING" <<'PY'
import email.utils, hashlib, lzma, os, subprocess, sys, tempfile, urllib.error, urllib.request

upstream, mirror, suite, arch, keyring = sys.argv[1:6]
want = set(os.environ["AIRGAP_PKGS"].split())

def get(url):
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            return r.read()
    except (urllib.error.URLError, OSError) as e:
        sys.exit("fetch failed: %s (%s)" % (url, e))

def sha256(b): return hashlib.sha256(b).hexdigest()

inrelease = get("%s/dists/%s/InRelease" % (upstream, suite))
with tempfile.NamedTemporaryFile(suffix=".InRelease", delete=False) as f:
    f.write(inrelease); tmp = f.name

# GPGV'S EXIT STATUS IS THE WRONG QUESTION, and this is the one place in this repo where
# "parse the output" beats "read rc" -- so it is worth being exact about why.
#
# A Debian InRelease carries SEVERAL signatures (trixie's has three). gpgv exits non-zero
# when it could not check EVERY one of them, which is not what an installer is asking: the
# question is "is there at least one good signature from a key I trust?" Measured here on
# 2026-08-30 -- this host's debian-archive-keyring stops at bookworm, so trixie's InRelease
# gives one GOODSIG (the 12/bookworm archive key, still signing trixie) and two NO_PUBKEY,
# and gpgv exits 2 while the file is perfectly trustworthy.
#
# debootstrap says so in its own source, at read_gpg_status() in
# /usr/share/debootstrap/functions: "Don't worry about the exit status from gpgv; parsing
# the output will take care of that." Its rule is VALIDSIG wins, then BADSIG, then
# NO_PUBKEY. This is not a grep over human prose -- --status-fd is gpg's machine-readable
# interface, designed for exactly this -- and the rule below is debootstrap's, so the
# mirror builder accepts precisely what the installer that consumes it will accept.
out = subprocess.run(["gpgv", "--status-fd", "1", "--keyring", keyring,
                      "--ignore-time-conflict", tmp],
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.decode("utf-8", "replace")
os.unlink(tmp)
status = {}
for line in out.splitlines():
    p = line.split()
    if len(p) >= 3 and p[0] == "[GNUPG:]" and p[1] in ("VALIDSIG", "BADSIG", "NO_PUBKEY"):
        status[p[1]] = p[2]
if "VALIDSIG" not in status:
    sys.exit("upstream InRelease has NO signature this host can verify against %s "
             "(BADSIG=%s NO_PUBKEY=%s) — refusing to build a mirror from bytes of "
             "unknown origin. A newer debian-archive-keyring may be needed."
             % (keyring, status.get("BADSIG", "-"), status.get("NO_PUBKEY", "-")))

# the Packages entry is read out of the file we just VERIFIED, not guessed from a path
rel = inrelease.decode("utf-8", "replace")
idx_path = "main/binary-%s/Packages.xz" % arch
idx_sha = idx_size = None
in_sha = False
for line in rel.splitlines():
    if line.startswith("SHA256:"): in_sha = True; continue
    if in_sha and line[:1] not in (" ", "\t"): in_sha = False
    if in_sha:
        parts = line.split()
        if len(parts) == 3 and parts[2] == idx_path:
            idx_sha, idx_size = parts[0], int(parts[1]); break
if idx_sha is None:
    sys.exit("the verified InRelease does not list %s — wrong arch or component" % idx_path)

raw = get("%s/dists/%s/%s" % (upstream, suite, idx_path))
if len(raw) != idx_size or sha256(raw) != idx_sha:
    sys.exit("the upstream %s does not match the hash in the signed InRelease" % idx_path)
full = lzma.decompress(raw).decode("utf-8", "replace")

kept, missing = [], set(want)
for stanza in full.split("\n\n"):
    d = {}
    for line in stanza.splitlines():
        if line[:1] not in (" ", "\t") and ":" in line:
            k, v = line.split(":", 1); d[k] = v.strip()
    if d.get("Package") in want:
        kept.append(stanza.strip() + "\n")
        missing.discard(d["Package"])
if missing:
    sys.exit("the upstream index is missing %d closure package(s): %s"
             % (len(missing), " ".join(sorted(missing))))

for stanza in kept:
    d = dict(l.split(":", 1) for l in stanza.splitlines()
             if l[:1] not in (" ", "\t") and ":" in l)
    d = {k: v.strip() for k, v in d.items()}
    dst = os.path.join(mirror, d["Filename"])
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    blob = get("%s/%s" % (upstream, d["Filename"]))
    if sha256(blob) != d["SHA256"]:
        sys.exit("%s does not match the hash in the verified index" % d["Filename"])
    with open(dst, "wb") as f:
        f.write(blob)

# 3. write OUR index and OUR Release. This is a real mirror of a real subset, not a
#    rewrite: every stanza is upstream's, so the hashes still describe the bytes.
d = os.path.join(mirror, "dists", suite, "main", "binary-%s" % arch)
os.makedirs(d, exist_ok=True)
packages = "\n".join(kept).encode()
open(os.path.join(d, "Packages"), "wb").write(packages)
import gzip
with gzip.GzipFile(os.path.join(d, "Packages.gz"), "wb", mtime=0) as g:
    g.write(packages)

rel = ["Origin: air-gapped-install lab", "Label: air-gapped-install lab",
       "Suite: %s" % suite, "Codename: %s" % suite,
       "Architectures: %s" % arch, "Components: main",
       "Date: %s" % email.utils.formatdate(usegmt=True),
       "Description: partial %s mirror -- the minbase closure only (%d packages)" % (suite, len(kept))]
files = ["main/binary-%s/Packages" % arch, "main/binary-%s/Packages.gz" % arch]
for algo, fn in (("MD5Sum", hashlib.md5), ("SHA256", hashlib.sha256)):
    rel.append("%s:" % algo)
    for f in files:
        b = open(os.path.join(mirror, "dists", suite, f), "rb").read()
        rel.append(" %s %d %s" % (fn(b).hexdigest(), len(b), f))
open(os.path.join(mirror, "dists", suite, "Release"), "w").write("\n".join(rel) + "\n")
print(sha256(inrelease))
PY
)" || die "building the mirror from $UPSTREAM failed — nothing was signed, so no stamp is written and the tree stays absent rather than half-built"
    [[ -n "$upstream_sha" ]] || die "the mirror builder printed no upstream identity — refusing to stamp a tree whose provenance is unknown"

    # 4. sign it with a key that belongs to this lab. A mirror an installer will trust
    #    has to be signed by something the installer was told to trust; --no-check-gpg
    #    would make every row below pass for a reason that has nothing to do with trust.
    log "signing the mirror with a throwaway lab key"
    rm -rf "$GNUPG_DIR"; mkdir -p "$GNUPG_DIR"; chmod 700 "$GNUPG_DIR"
    GNUPGHOME="$GNUPG_DIR" gpg --batch --quiet --passphrase '' \
        --quick-gen-key "air-gapped-install lab mirror <lab@example.invalid>" default default never
    local rel="$MIRROR_DIR/dists/$SUITE/Release"
    GNUPGHOME="$GNUPG_DIR" gpg --batch --quiet --yes --clearsign     -o "$rel.tmp"      "$rel"
    mv "$rel.tmp" "$MIRROR_DIR/dists/$SUITE/InRelease"
    GNUPGHOME="$GNUPG_DIR" gpg --batch --quiet --yes --detach-sign --armor -o "$MIRROR_DIR/dists/$SUITE/Release.gpg" "$rel"
    GNUPGHOME="$GNUPG_DIR" gpg --batch --quiet --export > "$KEYRING"
    [[ -s "$KEYRING" ]] || die "the exported keyring is EMPTY — every verification below would then be vacuous"

    # Line 1 is the IDENTITY and is compared on every later run. Line 2 is the PROVENANCE:
    # the sha256 of the upstream InRelease this tree was cut from. It is recorded, not
    # compared, on purpose — comparing it would mean re-fetching upstream before every
    # install, and an install that needs the network to check it does not need the network
    # is not an air-gapped install. `status` prints it so a human can tell how old the
    # tree is; `mirror --refresh` is how it moves.
    { mirror_identity; printf 'upstream-inrelease-sha256 %s\n' "$upstream_sha"; } > "$STAMP"
    local n
    n="$(find "$MIRROR_DIR" -name '*.deb' | wc -l)"
    log "mirror built: $n packages, $(du -sh "$MIRROR_DIR" | cut -f1), signed, at $MIRROR_DIR"
    log "layout is package-mirror-ram's: dists/ and pool/ at the root, as its nginx 'root /srv/mirror;' serves them"
}

# ─── the namespace ──────────────────────────────────────────────────────────────────────

require_mirror() {
    mirror_is_current || die "no mirror for $(mirror_identity) under $STATE_DIR — run: $LAB_PROG mirror"
}

# unshare needs a subuid/subgid range to map: without --map-auto only the caller's own uid
# exists in the namespace, and tar aborts partway through unpacking the base system on the
# first file owned by anyone else. That failure looks like a broken mirror, so it is
# checked by name here instead.
check_userns() {
    need unshare ip python3 debootstrap
    local me; me="$(id -un)"
    if ! grep -q "^${me}:" /etc/subuid 2>/dev/null || ! grep -q "^${me}:" /etc/subgid 2>/dev/null; then
        die "no /etc/subuid + /etc/subgid range for '$me' — unshare --map-auto cannot map the ids debootstrap unpacks, and the failure would look like a corrupt mirror"
    fi
}

# Kill BY THE RECORDED PID, never by pattern: this server's cmdline carries the mirror
# path, and so would anything else this lab is running. `_EXIT_RC` is captured and
# restored so a teardown can never overwrite the status that triggered it.
_SERVER_PID=""
_reap_server() {
    local rc=$?
    [[ -n "$_SERVER_PID" ]] && kill "$_SERVER_PID" 2>/dev/null
    return "$rc"
}

# Runs INSIDE the namespace. Not in the usage text on purpose: it is the other half of
# `install`/`controls`, not something to invoke.
cmd__inside() {
    local mode="$1"
    ip link set lo up 2>/dev/null || true
    python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$MIRROR_DIR" >/dev/null 2>&1 &
    _SERVER_PID=$!
    # The reaping goes in a trap, not after each call. Every failure path below exits
    # through `die` — which is `exit`, not `return` — so a `kill` written after the call
    # never runs. Inside the namespace that is invisible (the server dies with the
    # namespace); run WITHOUT one, which is exactly what the air-gap meta-control does,
    # and it orphaned a server holding port $PORT until the next run skipped on it.
    #
    # _SERVER_PID IS GLOBAL, and that is not a style choice. The first version of this
    # trap named a `local srv`, which is out of scope by the time an EXIT trap runs —
    # under `set -u` the trap then died on "srv: unbound variable", which (a) left the
    # server running anyway and (b) turned a SUCCESSFUL install into rc=1, because a trap
    # that fails supplies the exit status. The install log showed a complete base system
    # while the driver reported failure: a liar in the honest direction, but a liar.
    trap _reap_server EXIT

    local ready=""
    for _ in $(seq 1 100); do
        if curl -sf "http://127.0.0.1:$PORT/dists/$SUITE/InRelease" -o /dev/null 2>/dev/null; then ready=1; break; fi
        sleep 0.1
    done
    [[ -n "$ready" ]] || die "the in-namespace mirror server never came up on 127.0.0.1:$PORT"

    local local_url="http://127.0.0.1:$PORT"
    local rc=0
    _probe_airgap
    case "$mode" in
        install)  _bootstrap "$local_url" "$KEYRING" "$STATE_DIR/rootfs" "$STATE_DIR/install.log"; rc=$? ;;
        controls) _controls "$local_url"; rc=$? ;;
        *)        die "unknown inside mode: $mode" ;;
    esac
    return "$rc"
}

# THE PRECONDITION EVERY OTHER ROW LEANS ON, and it is checked directly rather than
# inferred from an installer's refusal.
#
# WHY IT EXISTS (measured 2026-08-30, and it is the reason this file has a C0 at all).
# The first draft proved the air gap the tempting way: "point debootstrap at upstream and
# watch it fail." Run outside the namespace as a control, that row STILL printed
#   C1 upstream, from inside the ns    failed as required (rc=1)
# — because a non-root debootstrap refuses before it ever opens a socket
# ("E: debootstrap can only run as root"). The row was reporting a refusal that had
# nothing to do with the network, in the exact scenario the row exists to catch: a
# namespace that was never isolated. A more capable tool is not a stand-in for the seam;
# neither is a less capable one, and an assertion on the exit status could not tell the
# two failures apart.
#
# So the reachability question is asked of curl, whose network-class exit codes ARE the
# answer: 6 could not resolve, 7 could not connect, 28 timed out, 35 TLS. Anything else —
# including SUCCESS — means the run below would prove nothing, and it stops here.
_probe_airgap() {
    local rc=0
    curl -sf --max-time 5 "http://127.0.0.1:$PORT/dists/$SUITE/InRelease" -o /dev/null || rc=$?
    (( rc == 0 )) || die "the local mirror is NOT reachable inside the namespace (curl rc=$rc) — every row below would fail for that reason instead of the one it claims"

    rc=0
    curl -sf --max-time 8 "$UPSTREAM/dists/$SUITE/InRelease" -o /dev/null || rc=$?
    if (( rc == 0 )); then
        die "THE AIR GAP IS OPEN: $UPSTREAM answered from inside the namespace. Nothing below would be evidence of an offline install — refusing to print a result that would be read as one."
    fi
    case "$rc" in
        6|7|28|35) return 0 ;;
        *) die "upstream failed with curl rc=$rc, which is not a network-class refusal (6/7/28/35) — the reason it failed is unknown, so it cannot stand in for 'unreachable'" ;;
    esac
}

# One bootstrap. Returns debootstrap's status; the log is kept, because "it failed" with
# no reason on disk is the same as no result at all.
_bootstrap() {
    local url="$1" keyring="$2" target="$3" logf="$4" rc=0
    rm -rf "$target"
    debootstrap --foreign --variant=minbase --arch="$ARCH" --keyring="$keyring" \
        "$SUITE" "$target" "$url" > "$logf" 2>&1 || rc=$?
    return "$rc"
}

_controls() {
    local url="$1" rc bad=0 deb keep
    local t="$STATE_DIR/control-rootfs"

    printf '\n  %-34s %s\n' "row" "outcome"
    printf '  %s\n' "------------------------------------------------------------------"
    printf '  %-34s upstream is unreachable, mirror is (checked in _probe_airgap)\n' "C0 the air gap itself"

    # C1 asserts the REASON, not the status. `rc != 0` is satisfied by "debootstrap can
    # only run as root", which is what this row printed for a whole draft while proving
    # nothing — see the note on _probe_airgap. The message is the only place the
    # distinction exists, so the message is what is read; the exit status is checked too,
    # and neither stands in for the other.
    rc=0; _bootstrap "$UPSTREAM" "$KEYRING" "$t" "$STATE_DIR/c1.log" || rc=$?
    if (( rc == 0 )); then
        printf '  %-34s SUCCEEDED — and must not have\n' "C1 upstream, from inside the ns"
        bad=$((bad+1))
    elif ! grep -q 'Failed getting release file\|Couldn.t download\|Invalid Release' "$STATE_DIR/c1.log"; then
        printf '  %-34s failed, but NOT on the network: %s\n' "C1 upstream, from inside the ns" \
            "$(tail -1 "$STATE_DIR/c1.log" | cut -c1-60)"
        bad=$((bad+1))
    else
        printf '  %-34s refused on the network as required (rc=%d)\n' "C1 upstream, from inside the ns" "$rc"
        log "C1 said: $(tail -1 "$STATE_DIR/c1.log" | cut -c1-100)"
    fi

    # Same rule as C1: the reason is the assertion. A C2 that failed because the mirror
    # was unreachable would look identical here, and would say nothing about signatures.
    rc=0; _bootstrap "$url" "$DEBIAN_KEYRING" "$t" "$STATE_DIR/c2.log" || rc=$?
    if (( rc == 0 )); then
        printf '  %-34s SUCCEEDED — and must not have\n' "C2 our mirror, Debian's keyring"
        bad=$((bad+1))
    elif ! grep -q 'unknown key\|Invalid Release signature' "$STATE_DIR/c2.log"; then
        printf '  %-34s failed, but NOT on the signature: %s\n' "C2 our mirror, Debian's keyring" \
            "$(tail -1 "$STATE_DIR/c2.log" | cut -c1-60)"
        bad=$((bad+1))
    else
        printf '  %-34s refused the signature as required (rc=%d)\n' "C2 our mirror, Debian's keyring" "$rc"
    fi

    deb="$(find "$MIRROR_DIR/pool" -name 'bash_*.deb' | head -1)"
    [[ -n "$deb" ]] || die "no bash .deb in the mirror to corrupt — C3 would silently test nothing"
    keep="$STATE_DIR/.c3-original.deb"
    cp "$deb" "$keep"
    printf 'CORRUPTED-BY-C3' | dd of="$deb" bs=1 seek=200 conv=notrunc status=none
    rc=0; _bootstrap "$url" "$KEYRING" "$t" "$STATE_DIR/c3.log" || rc=$?
    cp "$keep" "$deb"; rm -f "$keep"
    if (( rc == 0 )); then
        printf '  %-34s SUCCEEDED — and must not have\n' "C3 a corrupted .deb in the tree"
        bad=$((bad+1))
    elif ! grep -q "Couldn.t download packages: bash" "$STATE_DIR/c3.log"; then
        printf '  %-34s failed, but NOT on the corrupted package: %s\n' "C3 a corrupted .deb in the tree" \
            "$(tail -1 "$STATE_DIR/c3.log" | cut -c1-60)"
        bad=$((bad+1))
    else
        printf '  %-34s refused the bad hash as required (rc=%d)\n' "C3 a corrupted .deb in the tree" "$rc"
    fi

    rc=0; _bootstrap "$url" "$KEYRING" "$t" "$STATE_DIR/c4.log" || rc=$?
    if (( rc == 0 )); then
        printf '  %-34s passed, as it must\n' "C4 repaired tree (positive)"
    else
        printf '  %-34s FAILED — so C3 proved leftover state, not the corruption\n' "C4 repaired tree (positive)"
        bad=$((bad+1))
    fi
    rm -rf "$t"

    printf '\n'
    if (( bad != 0 )); then
        log "$bad of the 4 graded control rows behaved wrongly — see $STATE_DIR/c*.log"
        return 1
    fi
    log "5 rows behaved: the air gap itself, three refusals each on its OWN reason, and one success"
    return 0
}

cmd_install() {
    require_mirror; check_userns
    log "bootstrapping $SUITE/$ARCH inside a namespace whose only interface is loopback"
    unshare -rmn --map-auto "$0" __inside install \
        || { log "the install log is at $STATE_DIR/install.log"; die "the air-gapped install FAILED — the mirror did not serve a complete $SUITE base system"; }
    local n
    n="$(find "$STATE_DIR/rootfs/var/cache/apt/archives" -name '*.deb' 2>/dev/null | wc -l)"
    [[ -x "$STATE_DIR/rootfs/bin/bash" && -x "$STATE_DIR/rootfs/usr/bin/dpkg" ]] \
        || die "debootstrap exited 0 but the tree has no /bin/bash and no /usr/bin/dpkg — an empty success"
    log "installed: $n packages unpacked into $STATE_DIR/rootfs, Debian $(cat "$STATE_DIR/rootfs/etc/debian_version" 2>/dev/null)"
    log "the second stage (dpkg --configure) needs real root and does NO network I/O — see MANUAL_TESTING.md"
}

cmd_controls() {
    require_mirror; check_userns
    unshare -rmn --map-auto "$0" __inside controls
}

# ─── the rest ───────────────────────────────────────────────────────────────────────────

cmd_serve() {
    local bind="$BIND"
    while (( $# )); do
        case "$1" in
            --bind) bind="${2:?--bind needs an address}"; shift 2 ;;
            *) die "unknown option for serve: $1" ;;
        esac
    done
    require_mirror; need python3
    log "serving $MIRROR_DIR on http://$bind:$PORT/ — this is a REAL host port, unlike the namespace runs"
    log "point a preseed at it with:  d-i mirror/http/hostname string $bind"
    exec python3 -m http.server "$PORT" --bind "$bind" --directory "$MIRROR_DIR"
}

cmd_status() {
    printf 'suite/arch      %s/%s\n' "$SUITE" "$ARCH"
    printf 'upstream        %s\n' "$UPSTREAM"
    printf 'state           %s\n' "$STATE_DIR"
    if mirror_is_current; then
        printf 'mirror          built for "%s" — %s packages, %s\n' \
            "$(head -1 "$STAMP")" "$(find "$MIRROR_DIR" -name '*.deb' | wc -l)" "$(du -sh "$MIRROR_DIR" | cut -f1)"
        printf 'provenance      %s\n' "$(sed -n '2p' "$STAMP")"
    elif [[ -d "$MIRROR_DIR" ]]; then
        printf 'mirror          PRESENT BUT STALE — built for "%s", asked for "%s"\n' \
            "$(head -1 "$STAMP" 2>/dev/null || echo unknown)" "$(mirror_identity)"
    else
        printf 'mirror          absent — run: %s mirror\n' "$LAB_PROG"
    fi
    printf 'keyring         %s\n' "$([[ -s "$KEYRING" ]] && echo "$KEYRING" || echo 'absent')"
    printf 'rootfs          %s\n' "$([[ -d "$STATE_DIR/rootfs" ]] && du -sh "$STATE_DIR/rootfs" | cut -f1 || echo 'absent')"
}

cmd_paths() {
    printf 'lab      %s\n' "$LAB_DIR"
    printf 'state    %s\n' "$STATE_DIR"
    printf 'mirror   %s\n' "$MIRROR_DIR"
    printf 'keyring  %s\n' "$KEYRING"
    printf 'url      http://127.0.0.1:%s (inside the namespace only)\n' "$PORT"
}

cmd_clean() {
    [[ -d "$STATE_DIR" ]] || { log "nothing to clean"; return 0; }
    log "removing $STATE_DIR"
    rm -rf "$STATE_DIR"
}

main() {
    local verb="${1:-help}"; shift || true
    case "$verb" in
        mirror)   cmd_mirror   "$@" ;;
        install)  cmd_install  "$@" ;;
        controls) cmd_controls "$@" ;;
        serve)    cmd_serve    "$@" ;;
        status)   cmd_status   "$@" ;;
        paths)    cmd_paths    "$@" ;;
        clean)    cmd_clean    "$@" ;;
        __inside) cmd__inside  "$@" ;;
        help|-h|--help) usage ;;
        *) usage >&2; die "unknown verb: $verb" ;;
    esac
}

main "$@"

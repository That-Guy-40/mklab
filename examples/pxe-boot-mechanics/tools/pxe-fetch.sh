#!/usr/bin/env bash
# =============================================================================
# pxe-fetch.sh — client-side PXE artifact fetch probe (HTTP/HTTPS + TFTP)
#
# A small, dependency-light companion to the pxe-boot-mechanics labs.  It does
# *by hand*, from a client vantage point, the exact transfers a PXE-booting VM
# does for you invisibly:
#
#     firmware --TFTP--> ipxe.efi          (the bootfile DHCP option 67 names)
#     iPXE     --HTTP--> kernel + initrd   (what boot.ipxe's `kernel`/`initrd` fetch)
#
# Seeing those fetches succeed/fail on their own — with status lines, headers,
# sizes and (for HTTPS) the TLS handshake — is the fastest way to understand
# where a netboot actually breaks.  This is a *probe*, not the boot itself:
# QEMU's firmware still does the real PXE boot; this just lets you reproduce
# and record the individual steps.
#
# ── WHERE TO RUN IT (important) ──────────────────────────────────────────────
#   Run it on the HOST, not on the artifact server.  From the host:
#     * HTTP/HTTPS  → nginx is published on  localhost:8181  (TLS: localhost:8443).
#                     `10.0.2.2` is the QEMU slirp gateway — only meaningful
#                     *inside* a slirp VM, NOT reachable from the host.
#     * TFTP        → reachable only against the dnsmasq ProxyDHCP+TFTP container
#                     (`netboot/setup-dhcp-tftp.sh`, host :69).  QEMU slirp's
#                     built-in TFTP is internal to the VM's NAT and cannot be
#                     probed from outside the VM.
#
# Usage:
#   pxe-fetch.sh [probe]            [--server URL] [--tls] [PATH...]
#   pxe-fetch.sh http              [--server URL] [--tls] [--save DIR] [PATH...]
#   pxe-fetch.sh from-ipxe FILE    [--server URL] [--tls] [--save DIR]
#   pxe-fetch.sh tftp [FILE...]    [--host HOST] [--port N] [--save DIR]
#   pxe-fetch.sh --record OUT  <any subcommand...>     # record + replay the run
#
# Options:
#   --server URL   HTTP(S) base seen from the host (default: http://localhost:8181)
#   --tls          shorthand: server → https://localhost:8443 and curl -k (self-signed)
#   -k|--insecure  pass curl -k (don't verify the TLS cert; snakeoil/self-signed)
#   --host HOST    TFTP server host           (default: localhost = dnsmasq container)
#   --port N       TFTP server port           (default: 69)
#   --save DIR     write fetched files into DIR (default: discard to /dev/null)
#   --record OUT   record the whole session (asciinema if present, else script(1)
#                  typescript with timing → replay with scriptreplay)
#   -h|--help      this help
#
# Modes:
#   probe       HEAD a set of common artifacts and report 200/404 + size. Default
#               when no subcommand is given. Answers "what is actually served?".
#   http        GET kernel+initrd over HTTP(S): synthesized request + real
#               response headers + byte count. PATH args override the defaults
#               (/kernel /initrd.gz); pass your own to match the lab you built.
#   from-ipxe   Parse a real boot.ipxe, rewrite its host:port to --server, and
#               replay the EXACT `kernel`/`initrd` GETs it contains. Authoritative
#               — always matches whatever lab last wrote boot.ipxe.
#   tftp        Fetch files via `curl tftp://HOST/FILE` (default: ipxe.efi).
#
# Requires: bash 4+, curl (with tftp support for the tftp mode — `curl -V | grep tftp`).
# Optional: asciinema or util-linux script(1) for --record.
# =============================================================================
set -euo pipefail

PROG="pxe-fetch"

# ── defaults ─────────────────────────────────────────────────────────────────
SERVER="http://localhost:8181"
INSECURE=0
TFTP_HOST="localhost"
TFTP_PORT=69
SAVE_DIR=""
RECORD=""
UA="pxe-fetch/1.0 (PXE artifact probe)"
# Artifacts probe checks by default — covers the minimal-netboot and the
# distro-install (Rocky/Alma) naming both, plus the boot chain files.
PROBE_PATHS=( /kernel /initrd.gz /vmlinuz /initrd.img /ipxe.efi /boot.ipxe )

# ── tiny logging ──────────────────────────────────────────────────────────────
c_blue=$'\e[34m'; c_grn=$'\e[32m'; c_red=$'\e[31m'; c_dim=$'\e[2m'; c_off=$'\e[0m'
info()  { printf '%s[%s]%s %s\n'      "$c_blue" "$PROG" "$c_off" "$*"; }
ok()    { printf '%s[%s]%s %s\n'      "$c_grn"  "$PROG" "$c_off" "$*"; }
warn()  { printf '%s[%s]%s %s\n'      "$c_red"  "$PROG" "$c_off" "$*" >&2; }
die()   { warn "$*"; exit 1; }

usage() { sed -n '2,/^# ===/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; exit "${1:-0}"; }

# ── argument parsing ──────────────────────────────────────────────────────────
MODE=""
declare -a REST=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        probe|http|from-ipxe|tftp) [[ -z "$MODE" ]] && MODE="$1" || REST+=("$1"); shift ;;
        --server)   SERVER="${2:?--server needs a URL}"; shift 2 ;;
        --tls)      SERVER="https://localhost:8443"; INSECURE=1; shift ;;
        -k|--insecure) INSECURE=1; shift ;;
        --host)     TFTP_HOST="${2:?--host needs a value}"; shift 2 ;;
        --port)     TFTP_PORT="${2:?--port needs a value}"; shift 2 ;;
        --save)     SAVE_DIR="${2:?--save needs a dir}"; shift 2 ;;
        --record)   RECORD="${2:?--record needs a file}"; shift 2 ;;
        -h|--help)  usage 0 ;;
        --)         shift; REST+=("$@"); break ;;
        -*)         die "unknown option: $1 (try --help)" ;;
        *)          REST+=("$1"); shift ;;
    esac
done
MODE="${MODE:-probe}"

# curl insecure flag as an array (clean word-splitting; -k only when requested).
declare -a KOPT=(); [[ $INSECURE -eq 1 ]] && KOPT=(-k)

# ── --record: re-exec the whole run under a recorder, then exit ───────────────
if [[ -n "$RECORD" && -z "${_PXE_FETCH_RECORDING:-}" ]]; then
    # Rebuild the command line without --record so the inner run is plain.
    declare -a inner=("$0")
    [[ "$MODE" != "probe" ]] && inner+=("$MODE")
    inner+=("--server" "$SERVER")
    [[ $INSECURE -eq 1 ]] && inner+=("-k")
    inner+=("--host" "$TFTP_HOST" "--port" "$TFTP_PORT")
    [[ -n "$SAVE_DIR" ]] && inner+=("--save" "$SAVE_DIR")
    [[ ${#REST[@]} -gt 0 ]] && inner+=("${REST[@]}")
    export _PXE_FETCH_RECORDING=1
    cmdstr="$(printf '%q ' "${inner[@]}")"
    if command -v asciinema >/dev/null 2>&1; then
        info "recording with asciinema → $RECORD   (replay: asciinema play $RECORD)"
        exec asciinema rec --command "$cmdstr" "$RECORD"
    elif command -v script >/dev/null 2>&1; then
        if script --help 2>&1 | grep -q -- '--log-timing'; then
            info "recording with script(1) → $RECORD (+ $RECORD.timing)"
            info "replay: scriptreplay --log-out $RECORD --log-timing $RECORD.timing"
            exec script -q --log-out "$RECORD" --log-timing "$RECORD.timing" -c "$cmdstr"
        else
            info "recording with script(1) → $RECORD  (no timing; replay: cat $RECORD)"
            exec script -q -c "$cmdstr" "$RECORD"
        fi
    else
        die "--record needs asciinema or script(1); neither found"
    fi
fi

# ── helpers ───────────────────────────────────────────────────────────────────

# dest_for PATH → where to write a downloaded body (a file under SAVE_DIR, else
# /dev/null so big initrds aren't kept).
dest_for() {
    if [[ -n "$SAVE_DIR" ]]; then mkdir -p "$SAVE_DIR"; printf '%s/%s' "$SAVE_DIR" "$(basename "$1")"
    else printf '/dev/null'; fi
}

# http_get URL — synthesize+show the request, fetch, show real response headers.
http_get() {
    local url="$1" host path dest hdr code rc=0
    host="${url#*://}"; host="${host%%/*}"
    path="/${url#*://*/}"
    dest="$(dest_for "$url")"
    hdr="$(mktemp)"

    printf '%s── GET %s%s\n' "$c_blue" "$url" "$c_off"
    printf '%s  request (what your client puts on the wire):%s\n' "$c_dim" "$c_off"
    printf '      GET %s HTTP/1.1\n      Host: %s\n      User-Agent: %s\n      Connection: close\n\n' \
           "$path" "$host" "$UA"

    code="$(curl -sS "${KOPT[@]}" -A "$UA" -H 'Connection: close' \
                 -D "$hdr" -o "$dest" -w '%{http_code}' "$url")" || rc=$?
    if [[ $rc -ne 0 ]]; then
        warn "  curl failed (exit $rc) — server down? wrong port? (host sees nginx on localhost:8181, not 10.0.2.2)"
        rm -f "$hdr"; return 1
    fi
    printf '%s  response:%s\n' "$c_dim" "$c_off"
    sed 's/^/      /' "$hdr"
    local bytes="?"; [[ "$dest" != /dev/null ]] && bytes="$(stat -c %s "$dest" 2>/dev/null || echo '?')"
    if [[ "$code" =~ ^2 ]]; then
        ok "  $code  ($([[ "$dest" != /dev/null ]] && echo "saved $bytes bytes → $dest" || echo 'body discarded'))"
    else
        warn "  $code  — artifact not served at that path"
    fi
    rm -f "$hdr"
    echo
}

# ── modes ──────────────────────────────────────────────────────────────────────

do_probe() {
    local -a paths=("${REST[@]}"); [[ ${#paths[@]} -eq 0 ]] && paths=("${PROBE_PATHS[@]}")
    info "probing $SERVER  (HEAD; what is actually served?)"
    [[ "$SERVER" == https* && $INSECURE -eq 1 ]] && info "  (TLS cert verification OFF — snakeoil/self-signed)"
    local p code len rc
    printf '  %-14s %-6s %s\n' "PATH" "STATUS" "SIZE"
    for p in "${paths[@]}"; do
        [[ "$p" != /* ]] && p="/$p"
        rc=0
        # -I = HEAD; capture status + content-length
        read -r code len < <(curl -sS "${KOPT[@]}" -A "$UA" -I "$SERVER$p" 2>/dev/null \
            | awk 'tolower($1) ~ /^http/ {c=$2} tolower($1) ~ /^content-length:/ {l=$2} END{printf "%s %s", (c?c:"---"), (l?l:"-")}') || rc=$?
        if [[ "$code" =~ ^2 ]]; then printf '  %-14s %s%-6s%s %s\n' "$p" "$c_grn" "$code" "$c_off" "$len"
        else                         printf '  %-14s %s%-6s%s %s\n' "$p" "$c_dim" "$code" "$c_off" "$len"; fi
    done
    echo
    info "tip: 'from-ipxe ~/netboot/boot.ipxe' replays the exact GETs your iPXE will do."
}

do_http() {
    local -a paths=("${REST[@]}"); [[ ${#paths[@]} -eq 0 ]] && paths=( /kernel /initrd.gz )
    info "HTTP fetch from $SERVER"
    local p
    for p in "${paths[@]}"; do [[ "$p" != /* ]] && p="/$p"; http_get "$SERVER$p" || true; done
}

do_from_ipxe() {
    local f="${REST[0]:-}"
    [[ -n "$f" ]] || die "from-ipxe needs a boot.ipxe path"
    [[ -r "$f" ]] || die "cannot read: $f"
    info "replaying the kernel/initrd GETs in $f (host rewritten → $SERVER)"
    # Pull the URL token (field 2) from the kernel / initrd / imgfetch lines,
    # strip scheme+authority, and re-anchor on --server. The kernel cmdline args
    # after the URL are NOT fetched, so we drop them.
    local line kw url path
    while read -r line; do
        kw="$(awk '{print $1}' <<<"$line")"
        case "$kw" in kernel|initrd|imgfetch|module) ;; *) continue ;; esac
        url="$(awk '{print $2}' <<<"$line")"
        [[ "$url" == *://* ]] || continue
        path="/${url#*://*/}"
        info "  $kw → $url"
        http_get "${SERVER}${path}" || true
    done < <(grep -E '^[[:space:]]*(kernel|initrd|imgfetch|module)[[:space:]]' "$f")
}

do_tftp() {
    command -v curl >/dev/null || die "curl required"
    curl -V | grep -qi tftp || die "this curl lacks tftp:// support (curl -V | grep tftp)"
    local -a files=("${REST[@]}"); [[ ${#files[@]} -eq 0 ]] && files=( ipxe.efi )
    info "TFTP fetch from tftp://$TFTP_HOST:$TFTP_PORT  (binary/octet)"
    info "  reminder: only the dnsmasq ProxyDHCP+TFTP server is reachable here;"
    info "  QEMU slirp's TFTP is internal to the VM and can't be probed from the host."
    local fn dest rc
    for fn in "${files[@]}"; do
        dest="$(dest_for "$fn")"; rc=0
        printf '%s── tftp GET %s%s\n' "$c_blue" "$fn" "$c_off"
        # TFTP is UDP: a dead server never "refuses", so without a timeout curl
        # blocks indefinitely. --connect-timeout/-m make it fail fast.
        curl -sS --connect-timeout 5 -m 30 \
             -o "$dest" -w '      transfer: %{size_download} bytes in %{time_total}s\n' \
             "tftp://$TFTP_HOST:$TFTP_PORT/$fn" || rc=$?
        if [[ $rc -eq 0 ]]; then
            ok "  fetched $fn ($([[ "$dest" != /dev/null ]] && echo "→ $dest" || echo 'discarded'))"
        else
            warn "  tftp fetch failed (exit $rc) — is the dnsmasq TFTP container up on :$TFTP_PORT? (ss -ulnp | grep :$TFTP_PORT)"
        fi
        echo
    done
}

case "$MODE" in
    probe)     do_probe ;;
    http)      do_http ;;
    from-ipxe) do_from_ipxe ;;
    tftp)      do_tftp ;;
    *)         die "unknown mode: $MODE" ;;
esac

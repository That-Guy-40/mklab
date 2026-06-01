#!/usr/bin/env bash
# =============================================================================
# socwrap.sh — socat-Based Interactive Terminal Wrapper
# Phase 7: Session Recording & Replay (asciicast v2)
#
# Author  : That-Guy / Positively Pedestrian Labs
# Version : 7.0.0-phase7
# Requires: bash 4+, socat, getopt (util-linux), awk
# Optional: jq (JSON config/macros — awk fallback if missing), perl (IAC/ANSI),
#           xxd (hex), aha (HTML logs), ssh, man/nroff (--man option)
#
# Architecture: bash read -e provides readline; socat is I/O bridge only.
# socat readline support is NOT required.
#
# Usage:
#   socwrap.sh [OPTIONS] -- COMMAND [ARGS...]          # EXEC mode
#   socwrap.sh [OPTIONS] -t HOST PORT                  # TCP mode
#   socwrap.sh [OPTIONS] -u HOST PORT                  # UDP mode
#   socwrap.sh [OPTIONS] -U /path/to/socket            # Unix socket mode
#   socwrap.sh [OPTIONS] -s USER@HOST                  # SSH passthrough
#   socwrap.sh [OPTIONS] -T HOST PORT                  # Telnet mode
#   socwrap.sh [OPTIONS] -c CHROOTDIR [SHELL]          # Chroot mode
#   socwrap.sh --profile NAME                       # Load named profile
#   socwrap.sh --list-profiles                       # List configured profiles
#   socwrap.sh --init-config                         # Create example config
#   socwrap.sh --validate-config                     # Check config syntax
#   socwrap.sh --detect
#   socwrap.sh --list-filters
#   socwrap.sh --list-plugins                     # Show loaded plugins
#   socwrap.sh --macros -t HOST PORT              # Enable macro engine
#   socwrap.sh --macro-file FILE                  # Load macros from file
#   socwrap.sh --list-macros                      # List available macros
#   socwrap.sh --record FILE -- COMMAND           # Record session to .cast
#   socwrap.sh --record FILE --record-input -t H P # Record with input events
#   socwrap.sh --replay FILE                      # Replay a recorded session
#   socwrap.sh --replay FILE --replay-speed 2     # Replay at 2x speed
#   socwrap.sh --man                              # Man-page formatted help
#   socwrap.sh --help
# =============================================================================

# --- STRICT MODE -------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

# --- VERSION -----------------------------------------------------------------
readonly SOCWRAP_VERSION="7.0.0-phase7"
readonly SOCWRAP_NAME="socwrap"

# --- DEFAULTS ----------------------------------------------------------------
readonly DEFAULT_HISTFILE="${HOME}/.socwrap_history"
readonly DEFAULT_HISTSIZE=500
readonly DEFAULT_PROMPT="socwrap> "
readonly DEFAULT_SHELL="/bin/sh"
readonly DEFAULT_CONNECT_TIMEOUT=10

# =============================================================================
# SECTION: Runtime State
# =============================================================================

# Inherited / overridable from environment
OPT_HISTFILE="${SOCWRAP_HISTFILE:-$DEFAULT_HISTFILE}"
OPT_HISTSIZE="${SOCWRAP_HISTSIZE:-$DEFAULT_HISTSIZE}"
OPT_PROMPT="${SOCWRAP_PROMPT:-$DEFAULT_PROMPT}"

# Mode — set by mode flags; one of:
#   exec | tcp | udp | unix | ssh | telnet | chroot
OPT_MODE="exec"

# Network target (tcp/udp/telnet modes)
OPT_HOST=""
OPT_PORT=""

# Unix socket path (unix mode)
OPT_UNIX_SOCK=""

# SSH target and extra options (ssh mode)
OPT_SSH_TARGET=""
OPT_SSH_OPTS=""

# Chroot directory and optional shell (chroot mode)
OPT_CHROOT_DIR=""
OPT_CHROOT_SHELL="$DEFAULT_SHELL"

# Telnet IAC scrubbing: 0=off, 1=on (auto-selects perl or sed)
OPT_IAC_SCRUB=1

# CRLF line-ending translation for TCP/UDP connections
OPT_CRLF=0

# TLS for TCP connections
OPT_TLS=0
OPT_TLS_VERIFY=1    # 1=verify cert, 0=skip (self-signed)

# Connection timeout (seconds) for network modes
OPT_TIMEOUT=$DEFAULT_CONNECT_TIMEOUT

# PTY, logging, misc
OPT_NO_PTY=0
OPT_LOG=""
OPT_LOG_FORMAT="text"       # text | tsv | html
OPT_LOG_TIMESTAMP=0         # 1=prepend timestamps in log
OPT_VERBOSE=0
OPT_DETECT_ONLY=0
OPT_DRY_RUN=0
OPT_LIST_FILTERS=0
OPT_MAN=0

# Filter pipeline arrays (accumulating, order-preserving)
declare -a OPT_PRE_FILTERS=()
declare -a OPT_POST_FILTERS=()

# Saved terminal state — restored on any exit
SAVED_STTY=""

# Assembled socat command (array — safe from word splitting)
declare -a SOCAT_CMD=()

# Wrapped command/args for EXEC and CHROOT modes
declare -a WRAP_TARGET=()

# Session start time for log footer duration
SESSION_START_TIME=""

# --- Phase 4: Config & Profile State ----------------------------------------

# Config / profile options
OPT_PROFILE=""              # --profile NAME
OPT_RC=""                   # --rc FILE (explicit config path override)
OPT_NO_CONFIG=0             # --no-config (skip config file loading)
OPT_LIST_PROFILES=0         # --list-profiles (list and exit)
OPT_INIT_CONFIG=0           # --init-config (create example config and exit)
OPT_VALIDATE_CONFIG=0       # --validate-config (check config and exit)

# Resolved config file path (set in main, used by config functions)
_RESOLVED_CONFIG=""

# CLI precedence markers — set to 1 when a value is explicitly provided
# on the command line.  Config/profile values never overwrite CLI values.
_CLI_MODE=0
_CLI_HOST=0
_CLI_PORT=0
_CLI_UNIX_SOCK=0
_CLI_SSH_TARGET=0
_CLI_SSH_OPTS=0
_CLI_CHROOT_DIR=0
_CLI_HISTFILE=0
_CLI_PROMPT=0
_CLI_TIMEOUT=0
_CLI_NO_PTY=0
_CLI_CRLF=0
_CLI_TLS=0
_CLI_TLS_VERIFY=0
_CLI_IAC_SCRUB=0
_CLI_LOG=0
_CLI_LOG_FORMAT=0
_CLI_LOG_TIMESTAMP=0
_CLI_PRE_FILTERS=0
_CLI_POST_FILTERS=0

# --- Phase 6: Plugin & Macro State ------------------------------------------

# Plugin system
OPT_NO_PLUGINS=0            # --no-plugins (skip ~/.socwrap.d/ loading)
OPT_LIST_PLUGINS=0          # --list-plugins (list and exit)
PLUGIN_DIR="${SOCWRAP_PLUGIN_DIR:-${HOME}/.socwrap.d}"

# Plugin registry: parallel arrays populated by socwrap_register_filter()
declare -a _PLUGIN_FILTER_NAMES=()    # filter names (without @)
declare -a _PLUGIN_FILTER_DESCS=()    # descriptions
declare -a _PLUGIN_FILTER_DIRS=()     # direction: pre, post, both
declare -a _PLUGIN_FILTER_CMDS=()     # shell commands
declare -a _LOADED_PLUGINS=()         # names of successfully loaded plugin files
declare -a _LOADED_PLUGIN_FILTERS=()  # per-plugin filter count (parallel with _LOADED_PLUGINS)

# Macro engine
OPT_MACROS=0                # --macros (enable macro engine)
OPT_MACRO_FILE=""           # --macro-file FILE (external macro definitions)
OPT_LIST_MACROS=0           # --list-macros (list and exit)

# Macro storage: associative arrays populated during config/file loading
# Keys are macro names; values are type|description|payload
declare -A _MACROS=()
# Template variables: set by //set, used in {{VAR}} expansion
declare -A _MACRO_VARS=()

# --- Phase 6a: Session Persistence State ------------------------------------
OPT_SAVE_STATE=""           # --save-state FILE (save session state on exit)
OPT_LOAD_STATE=""           # --load-state FILE (restore session state at startup)

# --- Phase 7: Session Recording & Replay ------------------------------------
OPT_RECORD=""               # --record FILE (record session to asciicast v2 file)
OPT_RECORD_INPUT=0          # --record-input (also record input events, off by default)
OPT_REPLAY=""               # --replay FILE (replay a recorded .cast file)
OPT_REPLAY_SPEED="1"        # --replay-speed N (playback speed multiplier)
_RECORD_START=""            # EPOCHREALTIME at recording start (internal)

# =============================================================================
# SECTION: Utility / Logging
# =============================================================================

err() {
    printf '[%s] ERROR: %s\n' "$SOCWRAP_NAME" "$*" >&2
}

warn() {
    printf '[%s] WARN:  %s\n' "$SOCWRAP_NAME" "$*" >&2
}

info() {
    printf '[%s] INFO:  %s\n' "$SOCWRAP_NAME" "$*" >&2
}

# Only prints when --verbose is active
debug() {
    if [[ "$OPT_VERBOSE" -eq 1 ]]; then
        printf '[%s] DEBUG: %s\n' "$SOCWRAP_NAME" "$*" >&2
    fi
}

# Die with a message and nonzero exit
die() {
    err "$*"
    exit 1
}

# =============================================================================
# SECTION: Cleanup & Signal Handling
# =============================================================================

cleanup() {
    local rc=$?

    debug "cleanup() called with exit code $rc"

    # Restore terminal state — socat with pty can leave it raw
    if [[ -n "$SAVED_STTY" ]]; then
        stty "$SAVED_STTY" 2>/dev/null || stty sane 2>/dev/null || true
        debug "Terminal state restored"
    else
        stty sane 2>/dev/null || true
    fi

    exit $rc
}

trap cleanup EXIT
trap 'exit 130' INT   # Ctrl-C → 128+2
trap 'exit 143' TERM  # kill   → 128+15
trap 'exit 129' HUP

# =============================================================================
# SECTION: Environment Detection
# =============================================================================

# Check that socat is in PATH
_check_socat_available() {
    command -v socat >/dev/null 2>&1
}

# Extract socat version string
_socat_version() {
    socat -V 2>&1 | awk '/socat version/{print $3; exit}'
}

# Return 0 if socat was compiled with readline support, 1 otherwise
_socat_has_readline() {
    socat -V 2>&1 | grep -qi readline
}

# Return 0 if socat was compiled with PTY support
_socat_has_pty() {
    socat -V 2>&1 | grep -qiE 'WITH_PTY|openpty'
}

# Return 0 if socat was compiled with OpenSSL support
_socat_has_openssl() {
    socat -V 2>&1 | grep -qiE 'WITH_OPENSSL|openssl'
}

# Return 0 if jq is available
_has_jq() {
    command -v jq >/dev/null 2>&1
}

# Return 0 if rlwrap is available (for reference / fallback suggestion)
_has_rlwrap() {
    command -v rlwrap >/dev/null 2>&1
}

_has_perl() {
    command -v perl >/dev/null 2>&1
}

_has_xxd() {
    command -v xxd >/dev/null 2>&1
}

_has_ssh() {
    command -v ssh >/dev/null 2>&1
}

_has_aha() {
    command -v aha >/dev/null 2>&1
}

_has_stdbuf() {
    command -v stdbuf >/dev/null 2>&1
}

_has_man() {
    command -v man >/dev/null 2>&1
}

_has_nroff() {
    command -v nroff >/dev/null 2>&1
}

# Return bash version as a comparable integer (e.g. bash 5.1 → 501)
_bash_version_int() {
    printf '%d%02d' "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"
}

#
# detect_env()
#
# Runs a full capability check and emits a structured report.
# With jq: emits JSON to stdout.
# Without jq: emits key=value pairs to stdout.
#
detect_env() {
    local socat_avail=false
    local socat_ver="(not found)"
    local socat_readline=false
    local socat_pty=false
    local socat_openssl=false
    local rlwrap_avail=false
    local jq_avail=false
    local perl_avail=false
    local xxd_avail=false
    local ssh_avail=false
    local aha_avail=false
    local stdbuf_avail=false
    local bash_ver="${BASH_VERSION}"
    local bash_ok=false

    # socat
    if _check_socat_available; then
        socat_avail=true
        socat_ver=$(_socat_version)
        if _socat_has_readline; then socat_readline=true; fi
        if _socat_has_pty; then socat_pty=true; fi
        if _socat_has_openssl; then socat_openssl=true; fi
    fi

    # optional tools
    if _has_rlwrap; then rlwrap_avail=true; fi
    if _has_jq; then jq_avail=true; fi
    if _has_perl; then perl_avail=true; fi
    if _has_xxd; then xxd_avail=true; fi
    if _has_ssh; then ssh_avail=true; fi
    if _has_aha; then aha_avail=true; fi
    if _has_stdbuf; then stdbuf_avail=true; fi

    # bash version check (need 4+)
    if [[ $(_bash_version_int) -ge 400 ]]; then bash_ok=true; fi

    if _has_jq; then
        jq -n \
            --arg  socwrap_ver    "$SOCWRAP_VERSION"  \
            --arg  bash_ver       "$bash_ver"         \
            --argjson bash_ok     "$bash_ok"          \
            --arg  socat_ver      "$socat_ver"        \
            --argjson socat_avail    "$socat_avail"   \
            --argjson socat_readline "$socat_readline" \
            --argjson socat_pty      "$socat_pty"     \
            --argjson socat_openssl  "$socat_openssl" \
            --argjson rlwrap_avail   "$rlwrap_avail"  \
            --argjson jq_avail       "$jq_avail"      \
            --argjson perl_avail     "$perl_avail"    \
            --argjson xxd_avail      "$xxd_avail"     \
            --argjson ssh_avail      "$ssh_avail"     \
            --argjson aha_avail      "$aha_avail"     \
            --argjson stdbuf_avail   "$stdbuf_avail"  \
            '{
                socwrap_version: $socwrap_ver,
                bash: { version: $bash_ver, meets_minimum: $bash_ok },
                socat: {
                    available:        $socat_avail,
                    version:          $socat_ver,
                    readline_support: $socat_readline,
                    pty_support:      $socat_pty,
                    tls_support:      $socat_openssl
                },
                optional_tools: {
                    rlwrap:  $rlwrap_avail,
                    jq:      $jq_avail,
                    perl:    $perl_avail,
                    xxd:     $xxd_avail,
                    ssh:     $ssh_avail,
                    aha:     $aha_avail,
                    stdbuf:  $stdbuf_avail
                },
                modes_available: {
                    exec:    true,
                    tcp:     $socat_avail,
                    udp:     $socat_avail,
                    unix:    $socat_avail,
                    ssh:     ($socat_avail and $ssh_avail),
                    telnet:  $socat_avail,
                    chroot:  $socat_avail,
                    tls_tcp: ($socat_avail and $socat_openssl)
                },
                filter_support: {
                    ansi_strip:  ($perl_avail or true),
                    iac_strip:   $perl_avail,
                    hex_dump:    $xxd_avail,
                    json_pp:     $jq_avail,
                    html_log:    $aha_avail
                },
                ready: ($socat_avail and $bash_ok)
            }'
    else
        # Plain key=value fallback
        cat <<EOF
socwrap_version=$SOCWRAP_VERSION
bash_version=$bash_ver
bash_ok=$bash_ok
socat_available=$socat_avail
socat_version=$socat_ver
socat_readline_support=$socat_readline
socat_pty_support=$socat_pty
socat_tls_support=$socat_openssl
rlwrap_available=$rlwrap_avail
jq_available=$jq_avail
perl_available=$perl_avail
xxd_available=$xxd_avail
ssh_available=$ssh_avail
aha_available=$aha_avail
stdbuf_available=$stdbuf_avail
EOF
    fi
}

#
# preflight()
#
# Called before any socat invocation.
# Exits with an error if hard requirements are not met.
#
preflight() {
    debug "Running preflight checks for mode: $OPT_MODE"

    # bash version
    if [[ $(_bash_version_int) -lt 400 ]]; then
        die "bash 4.0 or later is required (running $BASH_VERSION)"
    fi

    # socat presence (used for I/O bridging; readline support not required)
    _check_socat_available || die "socat not found in PATH — please install socat"

    # Mode-specific preflight
    case "$OPT_MODE" in
        tcp|telnet)
            [[ -n "$OPT_HOST" ]] || die "Mode '$OPT_MODE' requires a host"
            [[ -n "$OPT_PORT" ]] || die "Mode '$OPT_MODE' requires a port"
            [[ "$OPT_PORT" =~ ^[0-9]+$ ]] || die "Port must be numeric, got: $OPT_PORT"
            [[ "$OPT_PORT" -ge 1 && "$OPT_PORT" -le 65535 ]] \
                || die "Port out of range (1-65535): $OPT_PORT"
            if [[ "$OPT_TLS" -eq 1 ]] && ! _socat_has_openssl; then
                die "TLS mode requires socat compiled with OpenSSL support"
            fi
            ;;
        udp)
            [[ -n "$OPT_HOST" ]] || die "UDP mode requires a host (-u HOST PORT)"
            [[ -n "$OPT_PORT" ]] || die "UDP mode requires a port (-u HOST PORT)"
            [[ "$OPT_PORT" =~ ^[0-9]+$ ]] || die "Port must be numeric"
            ;;
        unix)
            [[ -n "$OPT_UNIX_SOCK" ]] || die "Unix mode requires a socket path (-U PATH)"
            [[ -S "$OPT_UNIX_SOCK" ]] \
                || warn "Unix socket does not exist yet: $OPT_UNIX_SOCK"
            ;;
        ssh)
            [[ -n "$OPT_SSH_TARGET" ]] || die "SSH mode requires a target (-s USER@HOST)"
            _has_ssh || die "SSH mode requires ssh in PATH"
            if [[ ${#OPT_PRE_FILTERS[@]} -gt 0 ]]; then
                warn "Pre-filters with SSH mode: remote shell loses full TTY semantics (no job control, no remote PS1)"
            fi
            ;;
        chroot)
            [[ -n "$OPT_CHROOT_DIR" ]] || die "Chroot mode requires a directory"
            [[ -d "$OPT_CHROOT_DIR" ]] || die "Chroot directory not found: $OPT_CHROOT_DIR"
            [[ "$EUID" -eq 0 ]] || warn "Chroot mode typically requires root privileges"
            ;;
        exec)
            [[ ${#WRAP_TARGET[@]} -gt 0 ]] \
                || die "No command specified. Use: socwrap.sh [OPTIONS] -- COMMAND [ARGS...]"
            ;;
    esac

    # Log format: HTML requires aha
    if [[ "$OPT_LOG_FORMAT" == "html" ]] && ! _has_aha; then
        warn "aha not found — falling back to text log format"
        OPT_LOG_FORMAT="text"
    fi

    debug "Preflight passed"
}

# =============================================================================
# SECTION: Config File Resolution (Phase 4)
# =============================================================================

#
# _resolve_config_path()
#
# Returns the config file path based on precedence:
#   1. --rc FILE  (highest)
#   2. $SOCWRAP_RC env var
#   3. ~/.socwraprc (default)
#
_resolve_config_path() {
    if [[ -n "$OPT_RC" ]]; then
        printf '%s' "$OPT_RC"
    elif [[ -n "${SOCWRAP_RC:-}" ]]; then
        printf '%s' "$SOCWRAP_RC"
    else
        printf '%s' "${HOME}/.socwraprc"
    fi
}

# Return 0 if the resolved config file exists and is readable
_config_file_exists() {
    [[ -f "$_RESOLVED_CONFIG" && -r "$_RESOLVED_CONFIG" ]]
}

# Require jq for config operations — die with clear message if missing
_require_jq_for_config() {
    if ! _has_jq; then
        die "Config features require jq — install jq or use --no-config"
    fi
}

#
# _expand_config_path()
#
# Expand ~ to $HOME and shell command substitutions in path strings.
# SECURITY NOTE: This uses eval for $(cmd) expansion.  Only use with
# trusted config files — documented in Known Limitations.
#
_expand_config_path() {
    local val="$1"
    # Step 1: Tilde expansion
    val="${val/#\~/$HOME}"
    # Step 2: Shell command substitution (e.g. $(date +%Y%m%d))
    # shellcheck disable=SC2016
    if [[ "$val" == *'$('* ]] || [[ "$val" == *'`'* ]]; then
        debug "Expanding shell substitution in config path: $val"
        val=$(eval "printf '%s' \"$val\"" 2>/dev/null) || true
    fi
    printf '%s' "$val"
}

# =============================================================================
# SECTION: Config Parser (Phase 4 base, Phase 5 jq/awk dual-mode)
# =============================================================================

# --- Parser selection -------------------------------------------------------
# Set once in main() after config path is resolved.  1=jq, 0=awk fallback.
_USE_JQ=1

_init_config_parser() {
    if _has_jq; then
        _USE_JQ=1
    else
        _USE_JQ=0
        warn "jq not found — using limited awk config parser"
    fi
}

# --- Low-level jq extraction helpers ----------------------------------------

_config_str_jq() {
    local jq_path="$1"
    jq -r "(${jq_path}) // empty" "$_RESOLVED_CONFIG" 2>/dev/null || true
}

_config_bool_jq() {
    local jq_path="$1"
    local raw
    raw=$(jq "(${jq_path}) // null" "$_RESOLVED_CONFIG" 2>/dev/null) || true
    case "$raw" in
        true)  printf '1' ;;
        false) printf '0' ;;
        *)     ;;  # output nothing — key absent or null
    esac
}

_config_int_jq() {
    local jq_path="$1"
    local val
    val=$(jq -r "(${jq_path}) // empty | tostring" "$_RESOLVED_CONFIG" 2>/dev/null) || true
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        printf '%s' "$val"
    fi
}

_config_array_jq() {
    local jq_path="$1"
    jq -r "(${jq_path}) // null | if type == \"array\" then .[] else empty end" \
        "$_RESOLVED_CONFIG" 2>/dev/null || true
}

_config_has_jq() {
    local jq_path="$1"
    jq -e "(${jq_path}) // empty" "$_RESOLVED_CONFIG" > /dev/null 2>&1
}

# --- Low-level awk extraction helpers (Phase 5 fallback) --------------------
#
# These parse the limited JSON structure used by socwrap's config file.
# They handle the flat "global" block and the per-profile blocks.
# They do NOT handle arbitrary nested JSON — only the fields socwrap uses.
#
# The jq_path argument uses the same jq syntax as the jq helpers; the awk
# functions parse the path to determine section and key.

# _awk_parse_jqpath JQ_PATH — converts a jq path into colon-separated parts
# E.g. '.global.prompt' → 'global:prompt'
#      '.profiles["myhost"].port' → 'profiles:myhost:port'
#      '.global["no-pty"]' → 'global:no-pty'
_awk_parse_jqpath() {
    local path="$1"
    path="${path#.}"
    while [[ "$path" == *'["'* ]]; do
        local before="${path%%\[\"*}"
        local rest="${path#*\[\"}"
        local key="${rest%%\"]*}"
        local after="${rest#*\]}"
        path="${before}.${key}${after}"
    done
    printf '%s' "$path" | tr '.' ':'
}

# _awk_extract JQ_PATH — extract a value from JSON config using awk
# Supports paths up to 3 levels deep (e.g. .profiles["name"].key).
# Handles string, number, boolean, null, and string array values.
_awk_extract() {
    local jq_path="$1"
    local file="$_RESOLVED_CONFIG"
    local pathstr
    pathstr=$(_awk_parse_jqpath "$jq_path")

    awk -v pathstr="$pathstr" -f /dev/stdin "$file" <<'AWKEOF'
BEGIN {
    nparts = split(pathstr, parts, ":")
    if (nparts < 1) exit 1
    target_key = parts[nparts]
    depth = 0; in_target = 0; match_depth = 0; found_value = 0
}
{
    line = $0
    while (length(line) > 0) {
        if (match(line, /^[ \t\r\n]+/)) { line = substr(line, RLENGTH + 1); continue }
        c1 = substr(line, 1, 1)
        if (c1 == "{") { depth++; line = substr(line, 2); continue }
        if (c1 == "}") {
            if (in_target == 2 && depth == match_depth) {
                in_target = 1; match_depth = 2
            } else if (in_target == 1 && depth == match_depth) {
                in_target = 0
            }
            depth--; line = substr(line, 2); continue
        }
        if (c1 == ",") { line = substr(line, 2); continue }

        # Match "key" :  (key-value pair)
        if (match(line, /^"[^"]*"[ \t]*:/)) {
            kv = substr(line, 1, RLENGTH)
            line = substr(line, RLENGTH + 1)
            sub(/^[ \t]+/, "", line)
            # Extract key name
            sub(/^"/, "", kv); sub(/"[ \t]*:$/, "", kv)
            key = kv

            found = 0
            if (nparts == 1 && key == target_key) {
                found = 1
            } else if (nparts >= 2) {
                if (key == parts[1] && depth == 1 && in_target == 0) {
                    in_target = 1; match_depth = depth + 1
                } else if (in_target == 1 && nparts >= 3 && key == parts[2] && depth == 2) {
                    in_target = 2; match_depth = depth + 1
                }
                if (in_target == (nparts - 1) && key == target_key && depth == nparts) {
                    found = 1
                }
            }

            if (found) {
                if (match(line, /^"[^"]*"/)) {
                    print substr(line, 2, RLENGTH - 2); found_value = 1; exit 0
                } else if (match(line, /^-?[0-9]+/)) {
                    print substr(line, RSTART, RLENGTH); found_value = 1; exit 0
                } else if (match(line, /^(true|false|null)/)) {
                    print substr(line, RSTART, RLENGTH); found_value = 1; exit 0
                } else if (substr(line, 1, 1) == "[") {
                    line = substr(line, 2)
                    while (1) {
                        sub(/^[ \t\r\n,]+/, "", line)
                        if (substr(line, 1, 1) == "]") break
                        if (match(line, /^"[^"]*"/)) {
                            print substr(line, 2, RLENGTH - 2)
                            line = substr(line, RLENGTH + 1)
                        } else { break }
                    }
                    found_value = 1; exit 0
                }
            }
            continue
        }
        # Skip quoted strings and other tokens
        if (match(line, /^"[^"]*"/)) { line = substr(line, RLENGTH + 1); continue }
        if (match(line, /^[^ \t,}\]"[]+/)) { line = substr(line, RLENGTH + 1); continue }
        # Handle [ and ] outside key-value context
        if (c1 == "[" || c1 == "]") { line = substr(line, 2); continue }
        line = substr(line, 2)
    }
}
END { if (!found_value) exit 1 }
AWKEOF
}

_config_str_awk() {
    local jq_path="$1"
    local val
    val=$(_awk_extract "$jq_path") || true
    # Filter out JSON literals that aren't strings
    case "$val" in
        true|false|null) val="" ;;
    esac
    printf '%s' "$val"
}

_config_bool_awk() {
    local jq_path="$1"
    local val
    val=$(_awk_extract "$jq_path") || true
    case "$val" in
        true)  printf '1' ;;
        false) printf '0' ;;
        *)     ;;  # output nothing
    esac
}

_config_int_awk() {
    local jq_path="$1"
    local val
    val=$(_awk_extract "$jq_path") || true
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        printf '%s' "$val"
    fi
}

_config_array_awk() {
    local jq_path="$1"
    _awk_extract "$jq_path" || true
}

_config_has_awk() {
    local jq_path="$1"
    # Try leaf value first
    if _awk_extract "$jq_path" > /dev/null 2>&1; then
        return 0
    fi
    # Check for object/array key existence (value starts with { or [)
    local file="$_RESOLVED_CONFIG"
    local pathstr
    pathstr=$(_awk_parse_jqpath "$jq_path")
    awk -v pathstr="$pathstr" -f /dev/stdin "$file" <<'AWKEOF'
BEGIN {
    nparts = split(pathstr, parts, ":")
    if (nparts < 1) exit 1
    target_key = parts[nparts]
    depth = 0; in_target = 0; match_depth = 0; found_key = 0
}
{
    line = $0
    while (length(line) > 0) {
        if (match(line, /^[ \t\r\n]+/)) { line = substr(line, RLENGTH + 1); continue }
        c1 = substr(line, 1, 1)
        if (c1 == "{") { depth++; line = substr(line, 2); continue }
        if (c1 == "}") {
            if (in_target == 2 && depth == match_depth) { in_target = 1; match_depth = 2 }
            else if (in_target == 1 && depth == match_depth) { in_target = 0 }
            depth--; line = substr(line, 2); continue
        }
        if (c1 == ",") { line = substr(line, 2); continue }
        if (match(line, /^"[^"]*"[ \t]*:/)) {
            kv = substr(line, 1, RLENGTH); line = substr(line, RLENGTH + 1)
            sub(/^[ \t]+/, "", line); sub(/^"/, "", kv); sub(/"[ \t]*:$/, "", kv)
            key = kv
            if (nparts == 1 && key == target_key) { found_key = 1; exit 0 }
            else if (nparts >= 2) {
                if (key == parts[1] && depth == 1 && in_target == 0) { in_target = 1; match_depth = depth + 1 }
                else if (in_target == 1 && nparts >= 3 && key == parts[2] && depth == 2) { in_target = 2; match_depth = depth + 1 }
                if (in_target == (nparts - 1) && key == target_key && depth == nparts) { found_key = 1; exit 0 }
            }
            continue
        }
        if (match(line, /^"[^"]*"/)) { line = substr(line, RLENGTH + 1); continue }
        if (match(line, /^[^ \t,}\]"[]+/)) { line = substr(line, RLENGTH + 1); continue }
        if (c1 == "[" || c1 == "]") { line = substr(line, 2); continue }
        line = substr(line, 2)
    }
}
END { if (!found_key) exit 1 }
AWKEOF
}

# --- Dispatch wrappers (select jq or awk based on _USE_JQ) -----------------

_config_str() {
    if [[ $_USE_JQ -eq 1 ]]; then
        _config_str_jq "$@"
    else
        _config_str_awk "$@"
    fi
}

_config_bool() {
    if [[ $_USE_JQ -eq 1 ]]; then
        _config_bool_jq "$@"
    else
        _config_bool_awk "$@"
    fi
}

_config_int() {
    if [[ $_USE_JQ -eq 1 ]]; then
        _config_int_jq "$@"
    else
        _config_int_awk "$@"
    fi
}

_config_array() {
    if [[ $_USE_JQ -eq 1 ]]; then
        _config_array_jq "$@"
    else
        _config_array_awk "$@"
    fi
}

_config_has() {
    if [[ $_USE_JQ -eq 1 ]]; then
        _config_has_jq "$@"
    else
        _config_has_awk "$@"
    fi
}

# _list_profile_names — outputs one profile name per line
_list_profile_names() {
    if [[ $_USE_JQ -eq 1 ]]; then
        jq -r '.profiles // {} | keys[]' "$_RESOLVED_CONFIG" 2>/dev/null || true
    else
        # awk fallback: find keys inside the "profiles" object
        awk '
        BEGIN { in_profiles=0; depth=0; prof_depth=0 }
        {
            line = $0
            while (length(line) > 0) {
                if (match(line, /^[ \t\r\n]+/)) {
                    line = substr(line, RLENGTH + 1); continue
                }
                if (substr(line, 1, 1) == "{") {
                    depth++; line = substr(line, 2); continue
                }
                if (substr(line, 1, 1) == "}") {
                    if (in_profiles && depth == prof_depth) in_profiles=0
                    depth--; line = substr(line, 2); continue
                }
                if (substr(line, 1, 1) == "[") {
                    depth++; line = substr(line, 2); continue
                }
                if (substr(line, 1, 1) == "]") {
                    depth--; line = substr(line, 2); continue
                }
                if (substr(line, 1, 1) == ",") {
                    line = substr(line, 2); continue
                }
                if (match(line, /^"([^"]*)"[ \t]*:/, arr)) {
                    key = arr[1]
                    line = substr(line, RLENGTH + 1)
                    sub(/^[ \t]+/, "", line)
                    if (key == "profiles" && !in_profiles) {
                        in_profiles = 1
                        prof_depth = depth + 1
                    } else if (in_profiles && depth == prof_depth) {
                        print key
                    }
                    continue
                }
                if (match(line, /^"[^"]*"/)) {
                    line = substr(line, RLENGTH + 1); continue
                }
                if (match(line, /^[^ \t,}\]]+/)) {
                    line = substr(line, RLENGTH + 1); continue
                }
                line = substr(line, 2)
            }
        }' "$_RESOLVED_CONFIG" 2>/dev/null || true
    fi
}

# --- High-level config loading functions ------------------------------------

#
# load_global_config()
#
# Reads the "global" block from the config file and applies values to
# OPT_* variables, but only for fields NOT explicitly set on the CLI.
#
load_global_config() {
    _config_has '.global' || return 0

    local val

    if [[ $_CLI_HISTFILE -eq 0 ]]; then
        val=$(_config_str '.global.history')
        [[ -n "$val" ]] && OPT_HISTFILE=$(_expand_config_path "$val")
    fi
    if [[ $_CLI_PROMPT -eq 0 ]]; then
        val=$(_config_str '.global.prompt')
        [[ -n "$val" ]] && OPT_PROMPT="$val"
    fi
    if [[ $_CLI_TIMEOUT -eq 0 ]]; then
        val=$(_config_int '.global.timeout')
        [[ -n "$val" ]] && OPT_TIMEOUT="$val"
    fi
    if [[ $_CLI_NO_PTY -eq 0 ]]; then
        val=$(_config_bool '.global["no-pty"]')
        [[ -n "$val" ]] && OPT_NO_PTY="$val"
    fi
    if [[ $_CLI_CRLF -eq 0 ]]; then
        val=$(_config_bool '.global.crlf')
        [[ -n "$val" ]] && OPT_CRLF="$val"
    fi
    if [[ $_CLI_TLS -eq 0 ]]; then
        val=$(_config_bool '.global.tls')
        [[ -n "$val" ]] && OPT_TLS="$val"
    fi
    if [[ $_CLI_TLS_VERIFY -eq 0 ]]; then
        val=$(_config_bool '.global["tls-verify"]')
        [[ -n "$val" ]] && OPT_TLS_VERIFY="$val"
    fi
    if [[ $_CLI_IAC_SCRUB -eq 0 ]]; then
        val=$(_config_bool '.global["iac-scrub"]')
        [[ -n "$val" ]] && OPT_IAC_SCRUB="$val"
    fi
    if [[ $_CLI_LOG -eq 0 ]]; then
        val=$(_config_str '.global.log')
        [[ -n "$val" ]] && OPT_LOG=$(_expand_config_path "$val")
    fi
    if [[ $_CLI_LOG_FORMAT -eq 0 ]]; then
        val=$(_config_str '.global["log-format"]')
        [[ -n "$val" ]] && OPT_LOG_FORMAT="$val"
    fi
    if [[ $_CLI_LOG_TIMESTAMP -eq 0 ]]; then
        val=$(_config_bool '.global["log-timestamp"]')
        [[ -n "$val" ]] && OPT_LOG_TIMESTAMP="$val"
    fi
    if [[ $_CLI_PRE_FILTERS -eq 0 ]] && _config_has '.global["pre-filters"]'; then
        local -a arr=()
        mapfile -t arr < <(_config_array '.global["pre-filters"]')
        OPT_PRE_FILTERS=("${arr[@]}")
    fi
    if [[ $_CLI_POST_FILTERS -eq 0 ]] && _config_has '.global["post-filters"]'; then
        local -a arr=()
        mapfile -t arr < <(_config_array '.global["post-filters"]')
        OPT_POST_FILTERS=("${arr[@]}")
    fi

    debug "Global config loaded from $_RESOLVED_CONFIG"
}

#
# load_profile()
#
# Reads a named profile from the "profiles" block.  Profile values override
# global values for any field NOT explicitly set on the CLI.
#
load_profile() {
    local name="$1"

    # Verify profile exists
    local pkey=".profiles[\"${name}\"]"
    if ! _config_has "$pkey"; then
        local available
        local -a _avail_names=()
        mapfile -t _avail_names < <(_list_profile_names)
        local IFS=', '
        available="${_avail_names[*]}"
        err "profile '${name}' not found in $_RESOLVED_CONFIG"
        [[ -n "$available" ]] && info "Available profiles: $available"
        exit 1
    fi

    local val

    # --- Mode & mode-specific fields ---
    if [[ $_CLI_MODE -eq 0 ]]; then
        val=$(_config_str "${pkey}.mode")
        [[ -n "$val" ]] && OPT_MODE="$val"
    fi
    if [[ $_CLI_HOST -eq 0 ]]; then
        val=$(_config_str "${pkey}.host")
        [[ -n "$val" ]] && OPT_HOST="$val"
    fi
    if [[ $_CLI_PORT -eq 0 ]]; then
        val=$(_config_int "${pkey}.port")
        [[ -n "$val" ]] && OPT_PORT="$val"
    fi
    if [[ $_CLI_SSH_TARGET -eq 0 ]]; then
        val=$(_config_str "${pkey}.target")
        [[ -n "$val" ]] && OPT_SSH_TARGET="$val"
    fi
    if [[ $_CLI_SSH_OPTS -eq 0 ]]; then
        val=$(_config_str "${pkey}[\"ssh-opts\"]")
        [[ -n "$val" ]] && OPT_SSH_OPTS="$val"
    fi
    # EXEC command array (only if CLI did not provide a command)
    if [[ $_CLI_MODE -eq 0 && ${#WRAP_TARGET[@]} -eq 0 ]]; then
        if _config_has "${pkey}.exec"; then
            local -a exec_arr=()
            mapfile -t exec_arr < <(_config_array "${pkey}.exec")
            if [[ ${#exec_arr[@]} -gt 0 ]]; then
                WRAP_TARGET=("${exec_arr[@]}")
            fi
        fi
    fi

    # --- Common options (same keys as global, scoped to profile) ---
    if [[ $_CLI_HISTFILE -eq 0 ]]; then
        val=$(_config_str "${pkey}.history")
        [[ -n "$val" ]] && OPT_HISTFILE=$(_expand_config_path "$val")
    fi
    if [[ $_CLI_PROMPT -eq 0 ]]; then
        val=$(_config_str "${pkey}.prompt")
        [[ -n "$val" ]] && OPT_PROMPT="$val"
    fi
    if [[ $_CLI_TIMEOUT -eq 0 ]]; then
        val=$(_config_int "${pkey}.timeout")
        [[ -n "$val" ]] && OPT_TIMEOUT="$val"
    fi
    if [[ $_CLI_NO_PTY -eq 0 ]]; then
        val=$(_config_bool "${pkey}[\"no-pty\"]")
        [[ -n "$val" ]] && OPT_NO_PTY="$val"
    fi
    if [[ $_CLI_CRLF -eq 0 ]]; then
        val=$(_config_bool "${pkey}.crlf")
        [[ -n "$val" ]] && OPT_CRLF="$val"
    fi
    if [[ $_CLI_TLS -eq 0 ]]; then
        val=$(_config_bool "${pkey}.tls")
        [[ -n "$val" ]] && OPT_TLS="$val"
    fi
    if [[ $_CLI_TLS_VERIFY -eq 0 ]]; then
        val=$(_config_bool "${pkey}[\"tls-verify\"]")
        [[ -n "$val" ]] && OPT_TLS_VERIFY="$val"
    fi
    if [[ $_CLI_IAC_SCRUB -eq 0 ]]; then
        val=$(_config_bool "${pkey}[\"iac-scrub\"]")
        [[ -n "$val" ]] && OPT_IAC_SCRUB="$val"
    fi
    if [[ $_CLI_LOG -eq 0 ]]; then
        val=$(_config_str "${pkey}.log")
        [[ -n "$val" ]] && OPT_LOG=$(_expand_config_path "$val")
    fi
    if [[ $_CLI_LOG_FORMAT -eq 0 ]]; then
        val=$(_config_str "${pkey}[\"log-format\"]")
        [[ -n "$val" ]] && OPT_LOG_FORMAT="$val"
    fi
    if [[ $_CLI_LOG_TIMESTAMP -eq 0 ]]; then
        val=$(_config_bool "${pkey}[\"log-timestamp\"]")
        [[ -n "$val" ]] && OPT_LOG_TIMESTAMP="$val"
    fi

    # --- Filter arrays: profile replaces global (all-or-nothing) ---
    if [[ $_CLI_PRE_FILTERS -eq 0 ]] && _config_has "${pkey}[\"pre-filters\"]"; then
        local -a arr=()
        mapfile -t arr < <(_config_array "${pkey}[\"pre-filters\"]")
        OPT_PRE_FILTERS=("${arr[@]}")
    fi
    if [[ $_CLI_POST_FILTERS -eq 0 ]] && _config_has "${pkey}[\"post-filters\"]"; then
        local -a arr=()
        mapfile -t arr < <(_config_array "${pkey}[\"post-filters\"]")
        OPT_POST_FILTERS=("${arr[@]}")
    fi

    debug "Profile '${name}' loaded from $_RESOLVED_CONFIG"
}

# =============================================================================
# SECTION: Config Management (Phase 4)
# =============================================================================

#
# init_config()
#
# Creates a new config file with example content.
# Refuses to overwrite an existing file.
#
init_config() {
    local rc_path
    rc_path=$(_resolve_config_path)

    if [[ -f "$rc_path" ]]; then
        err "$rc_path already exists — refusing to overwrite"
        info "Use --rc FILE to specify a different path, or remove the existing file"
        exit 1
    fi

    # Ensure parent directory exists
    local rc_dir
    rc_dir=$(dirname "$rc_path")
    if [[ ! -d "$rc_dir" ]]; then
        mkdir -p "$rc_dir" || die "Could not create directory: $rc_dir"
    fi

    cat > "$rc_path" <<'INITCONFIG'
{
  "global": {
    "history": "~/.socwrap_history",
    "prompt": "socwrap> ",
    "timeout": 10,
    "no-pty": false,
    "crlf": false,
    "tls": false,
    "tls-verify": true,
    "iac-scrub": true,
    "log": "",
    "log-timestamp": false,
    "log-format": "text",
    "pre-filters": [],
    "post-filters": []
  },
  "profiles": {
    "router": {
      "mode": "telnet",
      "host": "router.local",
      "port": 23,
      "prompt": "router> ",
      "history": "~/.socwrap_histories/router",
      "log": "~/sessions/router-$(date +%Y%m%d).html",
      "log-format": "html",
      "log-timestamp": true,
      "pre-filters": [],
      "post-filters": ["@iac-strip", "@ansi-strip", "@trim", "@noblank"]
    },
    "api-json": {
      "mode": "tcp",
      "host": "api.internal",
      "port": 3000,
      "prompt": "api> ",
      "history": "~/.socwrap_histories/api",
      "post-filters": ["@json-pp", "@timestamp"]
    },
    "debug-http": {
      "mode": "tcp",
      "host": "api.example.com",
      "port": 80,
      "prompt": "http> ",
      "history": "~/debug/http-$(date +%Y%m%d-%H%M).log",
      "post-filters": ["@timestamp", "@ansi-strip"],
      "crlf": true
    },
    "local-bash": {
      "mode": "exec",
      "prompt": "bash> ",
      "history": "~/.socwrap_histories/bash",
      "no-pty": true,
      "exec": ["/bin/bash", "--norc", "--noprofile"]
    },
    "ssh-prod": {
      "mode": "ssh",
      "target": "deploy@prod-app-01.example.com",
      "ssh-opts": "-i ~/.ssh/prod_key",
      "prompt": "prod-01> ",
      "history": "~/.socwrap_histories/prod-app-01",
      "pre-filters": [],
      "post-filters": []
    },
    "est-server": {
      "mode": "tcp",
      "host": "est.example.com",
      "port": 443,
      "tls": true,
      "tls-verify": true,
      "prompt": "est> ",
      "history": "~/.socwrap_histories/est",
      "crlf": false,
      "macros": {
        "help": {
          "type": "help",
          "description": "EST (RFC 7030) quick reference",
          "text": "EST Endpoints (/.well-known/est/):\\n  GET  /cacerts        CA certs\\n  GET  /csrattrs       CSR attributes\\n  POST /simpleenroll   Initial enrollment\\n  POST /simplereenroll Re-enrollment\\n\\nSet: //set HOST <server>  //set CSR_B64 <base64>  //set CSR_LEN <len>"
        },
        "cacerts": {
          "type": "demo",
          "description": "GET /cacerts",
          "steps": [
            { "send": "GET /.well-known/est/cacerts HTTP/1.1", "waitfor": "" },
            { "send": "Host: {{HOST}}", "waitfor": "" },
            { "send": "Accept: application/pkcs7-mime", "waitfor": "" },
            { "send": "Connection: close", "waitfor": "" },
            { "send": "", "waitfor": "200" }
          ]
        },
        "enroll": {
          "type": "demo",
          "description": "POST /simpleenroll",
          "steps": [
            { "send": "POST /.well-known/est/simpleenroll HTTP/1.1", "waitfor": "" },
            { "send": "Host: {{HOST}}", "waitfor": "" },
            { "send": "Content-Type: application/pkcs10", "waitfor": "" },
            { "send": "Content-Length: {{CSR_LEN}}", "waitfor": "" },
            { "send": "Accept: application/pkcs7-mime; smime-type=certs-only", "waitfor": "" },
            { "send": "", "waitfor": "" },
            { "send": "{{CSR_B64}}", "waitfor": "200" }
          ]
        }
      }
    },
    "awk-repl": {
      "mode": "exec",
      "no-pty": true,
      "exec": ["/usr/bin/awk", "{print}"],
      "prompt": "awk> ",
      "history": "~/.socwrap_histories/awk",
      "macros": {
        "help": {
          "type": "help",
          "description": "Awk quick reference",
          "text": "Awk Quick Reference\\n───────────────────\\n{print NR, $0}     number lines\\n{print $NF}        last field\\nNF > 4             lines with >4 fields\\n/regex/            grep\\n!/regex/           grep -v\\n{gsub(/a/,\"b\");print}  replace\\nEND{print NR}      count lines\\n\\nMacros: //number //sum //trim //uniq //grep //fields\\nFull sheet: use --macro-file macros/awk-repl.json"
        },
        "number": {
          "type": "send",
          "description": "Number each line",
          "send": "{print NR \"\\t\" $0}"
        },
        "count": {
          "type": "send",
          "description": "Count lines",
          "send": "END{print NR}"
        }
      }
    },
    "sed-repl": {
      "mode": "exec",
      "no-pty": true,
      "exec": ["/bin/sed", "-n", "-e", "p"],
      "prompt": "sed> ",
      "history": "~/.socwrap_histories/sed",
      "macros": {
        "help": {
          "type": "help",
          "description": "Sed quick reference",
          "text": "Sed Quick Reference\\n───────────────────\\nsed G                  double space\\nsed 's/foo/bar/'       replace first\\nsed 's/foo/bar/g'      replace all\\nsed -n '/regex/p'      grep\\nsed '/regex/d'         grep -v\\nsed 10q                head -10\\nsed '$!d'              tail -1\\nsed '/^$/d'            delete blanks\\nsed '1!G;h;$!d'        reverse (tac)\\nsed 's/^[ \\t]*//'      trim leading\\n\\nMacros: //replace //grep //grepv //head //tail //trim //blank //reverse\\nFull sheet: use --macro-file macros/sed-repl.json"
        },
        "replace": {
          "type": "send",
          "description": "Replace first match",
          "send": "s/{{FIND}}/{{REPLACE}}/"
        },
        "blank": {
          "type": "send",
          "description": "Delete blank lines",
          "send": "/^$/d"
        }
      }
    },
    "ed-repl": {
      "mode": "exec",
      "no-pty": false,
      "exec": ["/bin/ed", "-p", "*"],
      "prompt": "ed> ",
      "history": "~/.socwrap_histories/ed",
      "macros": {
        "help": {
          "type": "help",
          "description": "Ed quick reference",
          "text": "Ed Quick Reference\\n──────────────────\\n(.)a    append after line    (.,.)d  delete lines\\n(.)i    insert before line   (.,.)p  print lines\\n(.,.)c  change lines         (.,.)n  print with numbers\\n(.,.)m(.) move lines          (.,.)t(.) copy lines\\n(.,.)s/re/rep/  substitute   (.,.)s/re/rep/g  global sub\\n(1,$)g/re/cmd  global cmd   (1,$)v/re/cmd  inverse global\\n(.)klc  mark line            'lc     go to mark\\ne file  edit file            f file  set filename\\n(1,$)w file  write file      q  quit   Q  quit unconditionally\\nu  undo last command       H  toggle error messages\\n($)=  print line number      (.+1)z  scroll\\n/re/  search forward         ?re?  search backward\\n.  current line   $  last line   ,  all lines   ;  to end\\n\\nMacros: //print //numbered //append //insert //delete //sub\\n//subg //write //read //search //goto //undo //demo-edit\\nFull sheet: use --macro-file macros/ed-repl.json"
        },
        "print": {
          "type": "send",
          "description": "Print current line",
          "send": "p"
        },
        "numbered": {
          "type": "send",
          "description": "Print all lines with numbers",
          "send": ",n"
        }
      }
    }
  }
}
INITCONFIG

    info "Created $rc_path with example configuration"
    info "Edit the file to add your own profiles"
    exit 0
}

#
# validate_config()
#
# Checks the config file for JSON syntax, structural validity, and
# profile correctness.  Reports all issues, not just the first.
#
validate_config() {
    _require_jq_for_config

    local rc_path
    rc_path=$(_resolve_config_path)

    printf '[%s] Config: %s\n' "$SOCWRAP_NAME" "$rc_path"

    if [[ ! -f "$rc_path" ]]; then
        err "Config file not found: $rc_path"
        exit 1
    fi

    # --- JSON syntax check ---
    local jq_output=""
    local jq_rc=0
    jq_output=$(jq '.' "$rc_path" 2>&1 >/dev/null) || jq_rc=$?
    if [[ $jq_rc -ne 0 ]]; then
        local jq_err
        jq_err=$(printf '%s' "$jq_output" | head -1)
        printf '[%s] Syntax: FAIL — invalid JSON (jq reports: %s)\n' \
            "$SOCWRAP_NAME" "$jq_err"
        exit 1
    fi
    printf '[%s] Syntax: OK\n' "$SOCWRAP_NAME"

    local errors=0
    local warnings=0

    # --- Valid key sets ---
    local valid_global=" history prompt timeout no-pty crlf tls tls-verify iac-scrub log log-timestamp log-format pre-filters post-filters "
    local valid_profile=" mode host port target ssh-opts exec ${valid_global} "

    # --- Validate global block ---
    if jq -e '.global' "$rc_path" > /dev/null 2>&1; then
        local -a global_keys=()
        mapfile -t global_keys < <(jq -r '.global | keys[]' "$rc_path" 2>/dev/null)
        local g_unknown=0
        local gk
        for gk in "${global_keys[@]}"; do
            if [[ "$valid_global" != *" $gk "* ]]; then
                printf '[%s] Global block: WARN — unknown key '\''%s'\'' (ignored)\n' \
                    "$SOCWRAP_NAME" "$gk"
                warnings=$((warnings + 1))
                g_unknown=1
            fi
        done
        [[ $g_unknown -eq 0 ]] && printf '[%s] Global block: OK\n' "$SOCWRAP_NAME"
    fi

    # --- Validate profiles ---
    local -a profile_names=()
    mapfile -t profile_names < <(jq -r '.profiles // {} | keys[]' "$rc_path" 2>/dev/null)

    local pname
    for pname in "${profile_names[@]}"; do
        local pkey=".profiles[\"${pname}\"]"
        local p_ok=1

        # mode is required
        local pmode
        pmode=$(jq -r "${pkey}.mode // empty" "$rc_path" 2>/dev/null) || true
        if [[ -z "$pmode" ]]; then
            printf '[%s] Profile '\''%s'\'': FAIL — '\''mode'\'' is required but missing\n' \
                "$SOCWRAP_NAME" "$pname"
            errors=$((errors + 1))
            p_ok=0
        else
            case "$pmode" in
                tcp|udp|telnet|unix|exec|chroot|ssh) ;;
                *)
                    printf '[%s] Profile '\''%s'\'': FAIL — invalid mode '\''%s'\''\n' \
                        "$SOCWRAP_NAME" "$pname" "$pmode"
                    errors=$((errors + 1))
                    p_ok=0
                    ;;
            esac
        fi

        # check for unknown keys
        local -a pkeys=()
        mapfile -t pkeys < <(jq -r "${pkey} | keys[]" "$rc_path" 2>/dev/null)
        local pk
        for pk in "${pkeys[@]}"; do
            if [[ "$valid_profile" != *" $pk "* ]]; then
                printf '[%s] Profile '\''%s'\'': WARN — unknown key '\''%s'\'' (ignored)\n' \
                    "$SOCWRAP_NAME" "$pname" "$pk"
                warnings=$((warnings + 1))
                p_ok=0
            fi
        done

        [[ $p_ok -eq 1 ]] && printf '[%s] Profile '\''%s'\'': OK\n' "$SOCWRAP_NAME" "$pname"
    done

    # --- Summary ---
    local profile_count=${#profile_names[@]}
    if [[ $errors -gt 0 ]]; then
        printf '[%s] Validation failed — %d error(s), %d warning(s)\n' \
            "$SOCWRAP_NAME" "$errors" "$warnings"
        exit 1
    else
        printf '[%s] Validation passed — %d profile(s) found\n' \
            "$SOCWRAP_NAME" "$profile_count"
        exit 0
    fi
}

#
# list_profiles()
#
# Prints a formatted table of all configured profiles and exits.
#
list_profiles() {
    local rc_path
    rc_path=$(_resolve_config_path)

    if [[ ! -f "$rc_path" ]]; then
        info "No config file found at $rc_path"
        exit 0
    fi

    printf '[%s] Configured profiles (%s):\n' "$SOCWRAP_NAME" "$rc_path"

    local -a names=()
    mapfile -t names < <(_list_profile_names)

    if [[ ${#names[@]} -eq 0 ]]; then
        printf '  (no profiles defined)\n'
        exit 0
    fi

    local pname
    for pname in "${names[@]}"; do
        local pkey=".profiles[\"${pname}\"]"
        local pmode ptarget
        pmode=$(_config_str "${pkey}.mode")
        [[ -z "$pmode" ]] && pmode="?"

        case "$pmode" in
            tcp|udp|telnet)
                local h p
                h=$(_config_str "${pkey}.host")
                p=$(_config_str "${pkey}.port")
                [[ -z "$h" ]] && h="?"
                [[ -z "$p" ]] && p="?"
                ptarget="${h}:${p}"
                ;;
            unix)
                ptarget=$(_config_str "${pkey}.host")
                [[ -z "$ptarget" ]] && ptarget="?"
                ;;
            ssh)
                ptarget=$(_config_str "${pkey}.target")
                [[ -z "$ptarget" ]] && ptarget="?"
                ;;
            exec)
                local -a exec_arr=()
                mapfile -t exec_arr < <(_config_array "${pkey}.exec")
                if [[ ${#exec_arr[@]} -gt 0 ]]; then
                    local IFS=' '
                    ptarget="${exec_arr[*]}"
                else
                    ptarget="?"
                fi
                ;;
            chroot)
                ptarget=$(_config_str "${pkey}.host")
                [[ -z "$ptarget" ]] && ptarget="?"
                ;;
            *)
                ptarget="(?)"
                ;;
        esac

        printf '  %-14s %-8s %s\n' "$pname" "$pmode" "$ptarget"
    done

    exit 0
}

# =============================================================================
# SECTION: Built-in Filter Resolution
# =============================================================================

#
# resolve_builtin_filter()
#
# Maps a @name filter to its shell command.
# Returns the command string via stdout; returns 1 if the filter is unknown.
# Handles parameterised filters like @tee:FILE.
#
resolve_builtin_filter() {
    local name="$1"

    # stdbuf prefix for commands that don't self-flush (tr, sed, tee, etc.)
    local sbuf=""
    if _has_stdbuf; then
        sbuf="stdbuf -oL "
    fi

    # Handle parameterised @tee:FILE
    if [[ "$name" == @tee:* ]]; then
        local tee_file="${name#@tee:}"
        if [[ -z "$tee_file" ]]; then
            err "@tee requires a file path: @tee:/path/to/file"
            return 1
        fi
        printf '%stee -a %q' "$sbuf" "$tee_file"
        return 0
    fi

    case "$name" in
        @timestamp)
            # shellcheck disable=SC2016
            printf '%s' 'awk '"'"'{ printf "%s  %s\n", strftime("%H:%M:%S"), $0; fflush() }'"'"
            ;;
        @datestamp)
            # shellcheck disable=SC2016
            printf '%s' 'awk '"'"'{ printf "%s  %s\n", strftime("%Y-%m-%d %H:%M:%S"), $0; fflush() }'"'"
            ;;
        @ansi-strip)
            if _has_perl; then
                printf '%s' 'perl -pe '"'"'$|=1; s/\x1b\[[0-9;]*[mGKHFABCDJMPST]//g; s/\x1b\][^\x07]*\x07//g; s/\r//g'"'"
            else
                printf '%s' "${sbuf}"'sed '"'"'s/\x1b\[[0-9;]*[mGKHFABCDJMPST]//g'"'"
            fi
            ;;
        @iac-strip)
            if _has_perl; then
                printf '%s' 'perl -pe '"'"'$|=1; s/\xff[\xfb-\xfe][\x00-\xff]//g; s/\xff[\xf0-\xfa]//g; s/\xff\xff/\xff/g'"'"
            else
                warn "@iac-strip requires perl — filter disabled"
                printf '%s' 'cat'
            fi
            ;;
        @hex-dump)
            if _has_xxd; then
                printf '%s' "${sbuf}xxd"
            else
                warn "@hex-dump requires xxd — filter disabled"
                printf '%s' 'cat'
            fi
            ;;
        @json-pp)
            if _has_jq; then
                printf '%s' 'jq -R '"'"'try (fromjson | tojson) catch .'"'"
            else
                warn "@json-pp requires jq — filter disabled"
                printf '%s' 'cat'
            fi
            ;;
        @rot13)
            printf '%s' "${sbuf}"'tr '"'"'A-Za-z'"'"' '"'"'N-ZA-Mn-za-m'"'"
            ;;
        @upper)
            printf '%s' "${sbuf}"'tr '"'"'a-z'"'"' '"'"'A-Z'"'"
            ;;
        @lower)
            printf '%s' "${sbuf}"'tr '"'"'A-Z'"'"' '"'"'a-z'"'"
            ;;
        @trim)
            # shellcheck disable=SC2016
            printf '%s' 'awk '"'"'{ gsub(/^[ \t]+|[ \t]+$/, ""); print; fflush() }'"'"
            ;;
        @noblank)
            printf '%s' 'awk '"'"'NF { print; fflush() }'"'"
            ;;
        *)
            # Check plugin-registered filters before failing
            if _resolve_plugin_filter "$name"; then
                return 0
            fi
            err "Unknown filter: $name (not a built-in or plugin filter)"
            return 1
            ;;
    esac
    return 0
}

#
# list_filters()
#
# Prints a table of all built-in filters with availability status.
#
list_filters() {
    local perl_ok="no"
    local xxd_ok="no"
    local jq_ok="no"
    local aha_ok="no"
    local stdbuf_ok="no"

    _has_perl   && perl_ok="yes"
    _has_xxd    && xxd_ok="yes"
    _has_jq     && jq_ok="yes"
    _has_aha    && aha_ok="yes"
    _has_stdbuf && stdbuf_ok="yes"

    printf '\n%s %s — Built-in Filters\n\n' "$SOCWRAP_NAME" "$SOCWRAP_VERSION"
    printf '  %-16s %-6s %-12s %s\n' "FILTER" "DIR" "REQUIRES" "STATUS"
    printf '  %-16s %-6s %-12s %s\n' "------" "---" "--------" "------"
    printf '  %-16s %-6s %-12s %s\n' "@timestamp"  "post" "awk"     "available"
    printf '  %-16s %-6s %-12s %s\n' "@datestamp"  "post" "awk"     "available"

    local ansi_status="available (sed fallback)"
    [[ "$perl_ok" == "yes" ]] && ansi_status="available (perl)"
    printf '  %-16s %-6s %-12s %s\n' "@ansi-strip" "post" "perl/sed" "$ansi_status"

    local iac_status="unavailable (needs perl)"
    [[ "$perl_ok" == "yes" ]] && iac_status="available"
    printf '  %-16s %-6s %-12s %s\n' "@iac-strip"  "post" "perl"    "$iac_status"

    local hex_status="unavailable (needs xxd)"
    [[ "$xxd_ok" == "yes" ]] && hex_status="available"
    [[ "$xxd_ok" == "yes" && "$stdbuf_ok" == "yes" ]] && hex_status="available (line-buffered)"
    printf '  %-16s %-6s %-12s %s\n' "@hex-dump"   "post" "xxd"     "$hex_status"

    local json_status="unavailable (needs jq)"
    [[ "$jq_ok" == "yes" ]] && json_status="available"
    printf '  %-16s %-6s %-12s %s\n' "@json-pp"    "post" "jq"      "$json_status"

    printf '  %-16s %-6s %-12s %s\n' "@rot13"      "both" "tr"      "available"
    printf '  %-16s %-6s %-12s %s\n' "@upper"      "both" "tr"      "available"
    printf '  %-16s %-6s %-12s %s\n' "@lower"      "both" "tr"      "available"
    printf '  %-16s %-6s %-12s %s\n' "@trim"       "post" "awk"     "available"
    printf '  %-16s %-6s %-12s %s\n' "@noblank"    "post" "awk"     "available"
    printf '  %-16s %-6s %-12s %s\n' "@tee:FILE"   "post" "tee"     "available"

    # Plugin-registered filters
    if [[ ${#_PLUGIN_FILTER_NAMES[@]} -gt 0 ]]; then
        printf '\n  Plugin filters:\n'
        local pi
        for (( pi=0; pi<${#_PLUGIN_FILTER_NAMES[@]}; pi++ )); do
            printf '  %-16s %-6s %-12s %s\n' \
                "@${_PLUGIN_FILTER_NAMES[$pi]}" \
                "${_PLUGIN_FILTER_DIRS[$pi]}" \
                "plugin" \
                "available"
        done
    fi

    printf '\n  Log formats:\n'
    printf '    text      always available\n'
    printf '    tsv       always available\n'
    local html_status="unavailable (needs aha)"
    [[ "$aha_ok" == "yes" ]] && html_status="available"
    printf '    html      %s\n' "$html_status"
    printf '\n'
}

# =============================================================================
# SECTION: Plugin System (Phase 6)
# =============================================================================

#
# socwrap_register_filter NAME DESCRIPTION DIRECTION COMMAND
#
# Plugin API: register a custom named filter.
# NAME: filter name without @ prefix (e.g. "redact")
# DESCRIPTION: one-line description
# DIRECTION: "pre", "post", or "both"
# COMMAND: shell command string for the filter pipeline
#
socwrap_register_filter() {
    local name="$1"
    local desc="$2"
    local dir="$3"
    local cmd="$4"

    if [[ -z "$name" || -z "$cmd" ]]; then
        warn "Plugin: socwrap_register_filter requires NAME and COMMAND"
        return 1
    fi

    _PLUGIN_FILTER_NAMES+=("$name")
    _PLUGIN_FILTER_DESCS+=("$desc")
    _PLUGIN_FILTER_DIRS+=("$dir")
    _PLUGIN_FILTER_CMDS+=("$cmd")
    debug "Plugin filter registered: @${name} (${dir})"
}

#
# _resolve_plugin_filter NAME
#
# Checks if @NAME matches a plugin-registered filter.
# If found, prints the command to stdout and returns 0.
#
_resolve_plugin_filter() {
    local name="$1"
    local stripped="${name#@}"
    local i
    for (( i=0; i<${#_PLUGIN_FILTER_NAMES[@]}; i++ )); do
        if [[ "${_PLUGIN_FILTER_NAMES[$i]}" == "$stripped" ]]; then
            printf '%s' "${_PLUGIN_FILTER_CMDS[$i]}"
            return 0
        fi
    done
    return 1
}

#
# load_plugins()
#
# Sources shell scripts from ~/.socwrap.d/ in lexicographic order.
# Each plugin can call socwrap_register_filter() to add custom filters.
# Failed plugins produce a warning but do not abort.
#
load_plugins() {
    if [[ "$OPT_NO_PLUGINS" -eq 1 ]]; then
        debug "Plugin loading skipped (--no-plugins)"
        return 0
    fi

    if [[ ! -d "$PLUGIN_DIR" ]]; then
        debug "No plugin directory: $PLUGIN_DIR"
        return 0
    fi

    local -a plugin_files=()
    local f
    for f in "$PLUGIN_DIR"/*.sh; do
        [[ -f "$f" ]] && plugin_files+=("$f")
    done

    if [[ ${#plugin_files[@]} -eq 0 ]]; then
        debug "No plugins found in $PLUGIN_DIR"
        return 0
    fi

    local pfile pname filters_before
    for pfile in "${plugin_files[@]}"; do
        pname=$(basename "$pfile")
        filters_before=${#_PLUGIN_FILTER_NAMES[@]}

        debug "Loading plugin: $pname"
        # shellcheck disable=SC1090
        if source "$pfile" 2>/dev/null; then
            local filters_added=$(( ${#_PLUGIN_FILTER_NAMES[@]} - filters_before ))
            _LOADED_PLUGINS+=("$pname")
            _LOADED_PLUGIN_FILTERS+=("$filters_added")
            debug "Plugin loaded: $pname ($filters_added filter(s))"
        else
            warn "Plugin failed to load: $pname (syntax error?)"
        fi
    done
}

#
# list_plugins()
#
# Prints a formatted report of loaded plugins and exits.
#
list_plugins() {
    printf '[%s] Plugin directory: %s\n' "$SOCWRAP_NAME" "$PLUGIN_DIR"

    if [[ ${#_LOADED_PLUGINS[@]} -eq 0 ]]; then
        printf '[%s] No plugins loaded\n' "$SOCWRAP_NAME"
        exit 0
    fi

    printf '[%s] Loaded plugins:\n' "$SOCWRAP_NAME"

    local i offset=0
    for (( i=0; i<${#_LOADED_PLUGINS[@]}; i++ )); do
        local pname="${_LOADED_PLUGINS[$i]}"
        local fcount="${_LOADED_PLUGIN_FILTERS[$i]}"

        if [[ "$fcount" -gt 0 ]]; then
            # Collect filter names for this plugin
            local -a fnames=()
            local j
            for (( j=offset; j<offset+fcount; j++ )); do
                fnames+=("@${_PLUGIN_FILTER_NAMES[$j]}")
            done
            local flist
            flist=$(IFS=', '; printf '%s' "${fnames[*]}")
            printf '  %-24s %d filter(s): %s\n' "$pname" "$fcount" "$flist"
        else
            printf '  %-24s (no extensions)\n' "$pname"
        fi
        offset=$((offset + fcount))
    done

    exit 0
}

# =============================================================================
# SECTION: Macro Engine (Phase 6)
# =============================================================================

#
# _macro_store NAME TYPE DESCRIPTION PAYLOAD
#
# Store a macro definition.  PAYLOAD meaning depends on TYPE:
#   display — text to print
#   help    — help text to print
#   send    — line to expand and send to remote
#   demo    — newline-separated step list (TYPE|PAYLOAD per step)
#
_macro_store() {
    local name="$1" type="$2" desc="$3" payload="$4"
    _MACROS["$name"]="${type}|${desc}|${payload}"
    debug "Macro stored: //${name} (${type})"
}

#
# _macro_expand_vars TEXT
#
# Replace {{VAR}} placeholders with values from _MACRO_VARS.
# Unresolved variables are left as-is with a warning.
#
_macro_expand_vars() {
    local text="$1"
    local var val
    for var in "${!_MACRO_VARS[@]}"; do
        val="${_MACRO_VARS[$var]}"
        text="${text//\{\{${var}\}\}/${val}}"
    done
    # Warn about unresolved variables
    if [[ "$text" == *'{{'*'}}'* ]]; then
        local unresolved
        unresolved=$(printf '%s' "$text" | grep -oE '\{\{[A-Za-z_][A-Za-z0-9_]*\}\}' | sort -u | tr '\n' ' ')
        printf '[%s] WARN: unresolved variable(s): %s\n' "$SOCWRAP_NAME" "$unresolved" >&2
    fi
    printf '%s' "$text"
}

#
# _macro_handle_line LINE
#
# Process a // prefixed line.  Returns 0 if the line was handled
# (should NOT be sent to remote), 1 if it should be forwarded.
#
# Writes terminal output to stderr (which appears on the user's
# terminal).  Sends remote data by writing to fd 4.
#
_macro_handle_line() {
    local line="$1"

    # Strip the // prefix
    local cmd="${line#//}"
    # Trim leading/trailing whitespace
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    cmd="${cmd%"${cmd##*[![:space:]]}"}"

    case "$cmd" in
        list)
            _macro_cmd_list
            return 0
            ;;
        help|"?")
            _macro_cmd_help
            return 0
            ;;
        vars)
            _macro_cmd_vars
            return 0
            ;;
        set\ *)
            local rest="${cmd#set }"
            local varname="${rest%% *}"
            local varval="${rest#* }"
            if [[ "$varname" == "$rest" ]]; then
                printf '[%s] Usage: //set VARNAME VALUE\n' "$SOCWRAP_NAME" >&2
            else
                _MACRO_VARS["$varname"]="$varval"
                printf '[%s] Set %s=%s\n' "$SOCWRAP_NAME" "$varname" "$varval" >&2
            fi
            return 0
            ;;
        clear\ *|unset\ *)
            local varname="${cmd#clear }"
            varname="${varname#unset }"
            varname="${varname#"${varname%%[![:space:]]*}"}"
            if [[ -n "${_MACRO_VARS[$varname]+x}" ]]; then
                unset '_MACRO_VARS['"$varname"']'
                printf '[%s] Cleared %s\n' "$SOCWRAP_NAME" "$varname" >&2
            else
                printf '[%s] Variable not set: %s\n' "$SOCWRAP_NAME" "$varname" >&2
            fi
            return 0
            ;;
        "")
            printf '[%s] Macro commands: //list //help //vars //set //unset //clear //MACRONAME\n' "$SOCWRAP_NAME" >&2
            return 0
            ;;
    esac

    # Look up named macro
    local macro_name="$cmd"
    # Strip any arguments after the macro name (for future use)
    macro_name="${macro_name%% *}"

    if [[ -z "${_MACROS[$macro_name]+x}" ]]; then
        printf '[%s] Unknown macro: //%s (type //list for available macros)\n' "$SOCWRAP_NAME" "$macro_name" >&2
        return 0
    fi

    local entry="${_MACROS[$macro_name]}"
    local mtype="${entry%%|*}"
    local rest="${entry#*|}"
    local mdesc="${rest%%|*}"
    local mpayload="${rest#*|}"

    case "$mtype" in
        display)
            local expanded
            expanded=$(_macro_expand_vars "$mpayload")
            # Convert \n to actual newlines for display
            printf '%b\n' "$expanded" >&2
            ;;
        help)
            printf '\n' >&2
            printf '%b\n' "$mpayload" >&2
            printf '\n' >&2
            ;;
        send)
            local expanded
            expanded=$(_macro_expand_vars "$mpayload")
            printf '[%s] → %s\n' "$SOCWRAP_NAME" "$expanded" >&2
            printf '%s\n' "$expanded" >&4 || true
            ;;
        demo)
            _macro_run_demo "$macro_name" "$mdesc" "$mpayload"
            ;;
        *)
            printf '[%s] Unknown macro type: %s\n' "$SOCWRAP_NAME" "$mtype" >&2
            ;;
    esac
    return 0
}

#
# _macro_run_demo NAME DESCRIPTION STEPS
#
# Execute a multi-step demo sequence.
# STEPS is newline-separated, each line: STEPTYPE|PAYLOAD[|WAITFOR]
#
_macro_run_demo() {
    local name="$1" desc="$2" steps="$3"

    printf '\n  Demo: %s\n' "$name" >&2
    printf '  %s\n' "─────────────────────────────────────────────" >&2

    local step_num=0
    local IFS=$'\n'
    local step
    for step in $steps; do
        [[ -z "$step" ]] && continue

        local stype="${step%%|*}"
        local srest="${step#*|}"
        local spayload="${srest%%|*}"
        local swaitfor="${srest#*|}"
        [[ "$swaitfor" == "$srest" ]] && swaitfor=""

        case "$stype" in
            send)
                step_num=$((step_num + 1))
                local expanded
                expanded=$(_macro_expand_vars "$spayload")
                printf '  [%d] → %s\n' "$step_num" "$expanded" >&2
                printf '%s\n' "$expanded" >&4 || true
                if [[ -n "$swaitfor" ]]; then
                    printf '  [%d] (expect: %s)\n' "$step_num" "$swaitfor" >&2
                fi
                sleep 0.5
                ;;
            display)
                step_num=$((step_num + 1))
                printf '  [%d] %s\n' "$step_num" "$spayload" >&2
                ;;
            delay)
                local secs="${spayload:-0.5}"
                sleep "$secs" 2>/dev/null || sleep 1
                ;;
        esac
    done

    # Pause to let async response data flush to terminal before prompt redraws
    sleep 1.5

    printf '  %s\n\n' "─────────────────────────────────────────────" >&2
}

#
# _macro_cmd_list
#
# Print all available macros for the current session.
#
_macro_cmd_list() {
    if [[ ${#_MACROS[@]} -eq 0 ]]; then
        printf '[%s] No macros defined (use --macro-file or add macros to config)\n' "$SOCWRAP_NAME" >&2
        return
    fi

    printf '\n[%s] Available macros:\n\n' "$SOCWRAP_NAME" >&2
    printf '  %-16s %-8s %s\n' "MACRO" "TYPE" "DESCRIPTION" >&2
    printf '  %-16s %-8s %s\n' "─────" "────" "───────────" >&2

    local name
    for name in $(printf '%s\n' "${!_MACROS[@]}" | sort); do
        local entry="${_MACROS[$name]}"
        local mtype="${entry%%|*}"
        local rest="${entry#*|}"
        local mdesc="${rest%%|*}"
        printf '  //%s' "$name" >&2
        # Pad to 16 chars
        local pad=$((14 - ${#name}))
        [[ $pad -gt 0 ]] && printf '%*s' "$pad" "" >&2
        printf '  %-8s %s\n' "$mtype" "$mdesc" >&2
    done
    printf '\n  Built-in: //list //help //vars //set //unset //clear\n\n' >&2
}

#
# _macro_cmd_help
#
# Show the help/cheat-sheet macro, if one is defined.
#
_macro_cmd_help() {
    # Look for a macro with type "help"
    local name
    for name in "${!_MACROS[@]}"; do
        local entry="${_MACROS[$name]}"
        local mtype="${entry%%|*}"
        if [[ "$mtype" == "help" ]]; then
            local rest="${entry#*|}"
            local mpayload="${rest#*|}"
            printf '\n%b\n\n' "$mpayload" >&2
            return
        fi
    done
    printf '[%s] No help macro defined for this session\n' "$SOCWRAP_NAME" >&2
}

#
# _macro_cmd_vars
#
# Show all currently set template variables.
#
_macro_cmd_vars() {
    if [[ ${#_MACRO_VARS[@]} -eq 0 ]]; then
        printf '[%s] No variables set (use //set VARNAME VALUE)\n' "$SOCWRAP_NAME" >&2
        return
    fi

    printf '\n[%s] Template variables:\n\n' "$SOCWRAP_NAME" >&2
    local var
    for var in $(printf '%s\n' "${!_MACRO_VARS[@]}" | sort); do
        printf '  {{%s}} = %s\n' "$var" "${_MACRO_VARS[$var]}" >&2
    done
    printf '\n' >&2
}

#
# load_macros_from_config()
#
# Load macros from ~/.socwraprc at three priority levels:
#   1. .macros.global — always loaded
#   2. .macros.MODE — loaded when OPT_MODE matches
#   3. .profiles.PROFILE.macros — loaded for the active profile
# Later levels override earlier on name conflicts.
# Requires jq.
#
load_macros_from_config() {
    [[ "$OPT_MACROS" -eq 1 ]] || return 0
    _config_file_exists || return 0
    _has_jq || { debug "Macro loading from config requires jq"; return 0; }

    local rc="$_RESOLVED_CONFIG"

    # 1. Global macros
    local -a gnames=()
    mapfile -t gnames < <(jq -r '.macros.global // {} | keys[]' "$rc" 2>/dev/null || true)
    local gn
    for gn in "${gnames[@]}"; do
        [[ -z "$gn" ]] && continue
        _load_macro_from_jq ".macros.global[\"${gn}\"]" "$gn" "$rc"
    done

    # 2. Mode-specific macros
    local mode_key="$OPT_MODE"
    local -a mnames=()
    mapfile -t mnames < <(jq -r ".macros[\"${mode_key}\"] // {} | keys[]" "$rc" 2>/dev/null || true)
    local mn
    for mn in "${mnames[@]}"; do
        [[ -z "$mn" ]] && continue
        _load_macro_from_jq ".macros[\"${mode_key}\"][\"${mn}\"]" "$mn" "$rc"
    done

    # 3. Profile-specific macros
    if [[ -n "$OPT_PROFILE" ]]; then
        local pkey=".profiles[\"${OPT_PROFILE}\"].macros"
        local -a pnames=()
        mapfile -t pnames < <(jq -r "(${pkey}) // {} | keys[]" "$rc" 2>/dev/null || true)
        local pn
        for pn in "${pnames[@]}"; do
            [[ -z "$pn" ]] && continue
            _load_macro_from_jq "${pkey}[\"${pn}\"]" "$pn" "$rc"
        done
    fi
}

#
# _load_macro_from_jq JQ_PATH NAME FILE
#
# Extract a single macro definition from JSON via jq and store it.
#
_load_macro_from_jq() {
    local jpath="$1" name="$2" file="$3"

    local mtype mdesc mpayload
    mtype=$(jq -r "(${jpath}).type // empty" "$file" 2>/dev/null) || return
    [[ -z "$mtype" ]] && return
    mdesc=$(jq -r "(${jpath}).description // \"\"" "$file" 2>/dev/null) || true

    case "$mtype" in
        display)
            mpayload=$(jq -r "(${jpath}).text // \"\"" "$file" 2>/dev/null) || true
            ;;
        help)
            mpayload=$(jq -r "(${jpath}).text // \"\"" "$file" 2>/dev/null) || true
            ;;
        send)
            mpayload=$(jq -r "(${jpath}).send // \"\"" "$file" 2>/dev/null) || true
            ;;
        demo)
            # Compile demo steps into newline-separated TYPE|PAYLOAD|WAITFOR
            local -a steps=()
            local step_count
            step_count=$(jq -r "(${jpath}).steps | length" "$file" 2>/dev/null) || step_count=0
            local si
            for (( si=0; si<step_count; si++ )); do
                local spath="${jpath}.steps[$si]"
                local sline=""
                if jq -e "(${spath}).send // empty" "$file" > /dev/null 2>&1; then
                    local ssend swait
                    ssend=$(jq -r "(${spath}).send // \"\"" "$file" 2>/dev/null) || true
                    swait=$(jq -r "(${spath}).waitfor // \"\"" "$file" 2>/dev/null) || true
                    sline="send|${ssend}|${swait}"
                elif jq -e "(${spath}).display // empty" "$file" > /dev/null 2>&1; then
                    local sdisp
                    sdisp=$(jq -r "(${spath}).display // \"\"" "$file" 2>/dev/null) || true
                    sline="display|${sdisp}"
                elif jq -e "(${spath}).delay // empty" "$file" > /dev/null 2>&1; then
                    local sdel
                    sdel=$(jq -r "(${spath}).delay // 0.5" "$file" 2>/dev/null) || true
                    sline="delay|${sdel}"
                fi
                [[ -n "$sline" ]] && steps+=("$sline")
            done
            mpayload=$(printf '%s\n' "${steps[@]}")
            ;;
        *)
            warn "Unknown macro type '$mtype' for //$name"
            return
            ;;
    esac

    _macro_store "$name" "$mtype" "$mdesc" "$mpayload"
}

#
# load_macros_from_file FILE
#
# Load macros from an external JSON file.
# The file is a flat object: { "name": { "type": ..., ... }, ... }
# External macros override config macros on name conflict.
#
load_macros_from_file() {
    local file="$1"

    if [[ ! -f "$file" && ! -c "$file" && ! -p "$file" ]]; then
        die "Macro file not found: $file"
    fi
    if [[ ! -r "$file" ]]; then
        die "Macro file not readable: $file"
    fi

    if ! _has_jq; then
        die "Macro file loading requires jq"
    fi

    local -a names=()
    mapfile -t names < <(jq -r 'keys[]' "$file" 2>/dev/null || true)

    local name
    for name in "${names[@]}"; do
        [[ -z "$name" ]] && continue
        _load_macro_from_jq ".[\"${name}\"]" "$name" "$file"
    done

    debug "Loaded ${#names[@]} macro(s) from $file"
}

#
# list_macros()
#
# Print available macros and exit.
#
list_macros() {
    if [[ ${#_MACROS[@]} -eq 0 ]]; then
        printf '[%s] No macros defined\n' "$SOCWRAP_NAME"
        printf '[%s] Use --macro-file FILE or add macros to your config\n' "$SOCWRAP_NAME"
        exit 0
    fi

    printf '\n[%s] Available macros:\n\n' "$SOCWRAP_NAME"
    printf '  %-16s %-8s %s\n' "MACRO" "TYPE" "DESCRIPTION"
    printf '  %-16s %-8s %s\n' "─────" "────" "───────────"

    local name
    for name in $(printf '%s\n' "${!_MACROS[@]}" | sort); do
        local entry="${_MACROS[$name]}"
        local mtype="${entry%%|*}"
        local rest="${entry#*|}"
        local mdesc="${rest%%|*}"
        printf '  //%s' "$name"
        local pad=$((14 - ${#name}))
        [[ $pad -gt 0 ]] && printf '%*s' "$pad" ""
        printf '  %-8s %s\n' "$mtype" "$mdesc"
    done
    printf '\n  Built-in: //list //help //vars //set //unset //clear\n\n'
    exit 0
}

# =============================================================================
# SECTION: Session Persistence (Phase 6a)
# =============================================================================

#
# save_session_state FILE
#
# Writes current session configuration to a key=value state file.
# Called automatically on clean exit when --save-state is set.
#
save_session_state() {
    local file="$1"

    # Ensure parent directory exists
    local dir
    dir=$(dirname "$file")
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" || { warn "Could not create state directory: $dir"; return 1; }
    fi

    local timestamp
    timestamp=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

    local source_desc="CLI"
    [[ -n "$OPT_PROFILE" ]] && source_desc="CLI + profile '${OPT_PROFILE}' from ${_RESOLVED_CONFIG}"

    # Build filter strings (space-separated)
    local pre_str="" post_str=""
    if [[ ${#OPT_PRE_FILTERS[@]} -gt 0 ]]; then
        local IFS=' '
        pre_str="${OPT_PRE_FILTERS[*]}"
    fi
    if [[ ${#OPT_POST_FILTERS[@]} -gt 0 ]]; then
        local IFS=' '
        post_str="${OPT_POST_FILTERS[*]}"
    fi

    # Build wrap target string (space-separated, exec mode)
    local wrap_str=""
    if [[ ${#WRAP_TARGET[@]} -gt 0 ]]; then
        local IFS=' '
        wrap_str="${WRAP_TARGET[*]}"
    fi

    # Build macro vars string (space-separated KEY=VALUE)
    local mvars_str=""
    if [[ ${#_MACRO_VARS[@]} -gt 0 ]]; then
        local -a mvpairs=()
        local k
        for k in "${!_MACRO_VARS[@]}"; do
            mvpairs+=("${k}=${_MACRO_VARS[$k]}")
        done
        local IFS=' '
        mvars_str="${mvpairs[*]}"
    fi

    cat > "$file" <<STATEEOF
# socwrap session state — saved ${timestamp}
# Source: ${source_desc}
mode=${OPT_MODE}
host=${OPT_HOST}
port=${OPT_PORT}
prompt=${OPT_PROMPT}
histfile=${OPT_HISTFILE}
timeout=${OPT_TIMEOUT}
no_pty=${OPT_NO_PTY}
crlf=${OPT_CRLF}
tls=${OPT_TLS}
tls_verify=${OPT_TLS_VERIFY}
iac_scrub=${OPT_IAC_SCRUB}
log=${OPT_LOG}
log_format=${OPT_LOG_FORMAT}
log_timestamp=${OPT_LOG_TIMESTAMP}
pre_filters=${pre_str}
post_filters=${post_str}
profile=${OPT_PROFILE}
unix_sock=${OPT_UNIX_SOCK}
ssh_target=${OPT_SSH_TARGET}
ssh_opts=${OPT_SSH_OPTS}
chroot_dir=${OPT_CHROOT_DIR}
chroot_shell=${OPT_CHROOT_SHELL}
wrap_target=${wrap_str}
macros_enabled=${OPT_MACROS}
macro_vars=${mvars_str}
STATEEOF

    info "Session state saved to $file"
}

#
# load_session_state FILE
#
# Reads a state file and applies values to OPT_* variables.
# Only applies values for fields NOT already set by CLI flags.
#
load_session_state() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        die "State file not found: $file"
    fi
    if [[ ! -r "$file" ]]; then
        die "State file not readable: $file"
    fi

    debug "Loading session state from $file"

    local line key val
    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" == \#* || -z "$line" ]] && continue

        key="${line%%=*}"
        val="${line#*=}"

        # Apply value and set _CLI_ marker to prevent config overwrite.
        # CLI flags already set their markers in parse_args, so they win.
        case "$key" in
            mode)       [[ $_CLI_MODE -eq 0 ]]      && { OPT_MODE="$val"; _CLI_MODE=1; } ;;
            host)       [[ $_CLI_HOST -eq 0 ]]       && { OPT_HOST="$val"; _CLI_HOST=1; } ;;
            port)       [[ $_CLI_PORT -eq 0 ]]       && { OPT_PORT="$val"; _CLI_PORT=1; } ;;
            prompt)     [[ $_CLI_PROMPT -eq 0 ]]     && { OPT_PROMPT="$val"; _CLI_PROMPT=1; } ;;
            histfile)   [[ $_CLI_HISTFILE -eq 0 ]]   && { OPT_HISTFILE="$val"; _CLI_HISTFILE=1; } ;;
            timeout)    [[ $_CLI_TIMEOUT -eq 0 ]]    && { OPT_TIMEOUT="$val"; _CLI_TIMEOUT=1; } ;;
            no_pty)     [[ $_CLI_NO_PTY -eq 0 ]]     && { OPT_NO_PTY="$val"; _CLI_NO_PTY=1; } ;;
            crlf)       [[ $_CLI_CRLF -eq 0 ]]       && { OPT_CRLF="$val"; _CLI_CRLF=1; } ;;
            tls)        [[ $_CLI_TLS -eq 0 ]]         && { OPT_TLS="$val"; _CLI_TLS=1; } ;;
            tls_verify) [[ $_CLI_TLS_VERIFY -eq 0 ]]  && { OPT_TLS_VERIFY="$val"; _CLI_TLS_VERIFY=1; } ;;
            iac_scrub)  [[ $_CLI_IAC_SCRUB -eq 0 ]]   && { OPT_IAC_SCRUB="$val"; _CLI_IAC_SCRUB=1; } ;;
            log)        [[ $_CLI_LOG -eq 0 && -n "$val" ]] && { OPT_LOG="$val"; _CLI_LOG=1; } ;;
            log_format) [[ $_CLI_LOG_FORMAT -eq 0 ]]  && { OPT_LOG_FORMAT="$val"; _CLI_LOG_FORMAT=1; } ;;
            log_timestamp) [[ $_CLI_LOG_TIMESTAMP -eq 0 ]] && { OPT_LOG_TIMESTAMP="$val"; _CLI_LOG_TIMESTAMP=1; } ;;
            pre_filters)
                if [[ $_CLI_PRE_FILTERS -eq 0 && -n "$val" ]]; then
                    local IFS=' '
                    # shellcheck disable=SC2206
                    OPT_PRE_FILTERS=($val)
                    _CLI_PRE_FILTERS=1
                fi
                ;;
            post_filters)
                if [[ $_CLI_POST_FILTERS -eq 0 && -n "$val" ]]; then
                    local IFS=' '
                    # shellcheck disable=SC2206
                    OPT_POST_FILTERS=($val)
                    _CLI_POST_FILTERS=1
                fi
                ;;
            profile)    OPT_PROFILE="$val" ;;
            unix_sock)  [[ $_CLI_UNIX_SOCK -eq 0 ]]   && { OPT_UNIX_SOCK="$val"; _CLI_UNIX_SOCK=1; } ;;
            ssh_target) [[ $_CLI_SSH_TARGET -eq 0 ]]   && { OPT_SSH_TARGET="$val"; _CLI_SSH_TARGET=1; } ;;
            ssh_opts)   [[ $_CLI_SSH_OPTS -eq 0 ]]     && { OPT_SSH_OPTS="$val"; _CLI_SSH_OPTS=1; } ;;
            chroot_dir) [[ $_CLI_CHROOT_DIR -eq 0 ]]   && { OPT_CHROOT_DIR="$val"; _CLI_CHROOT_DIR=1; } ;;
            chroot_shell) OPT_CHROOT_SHELL="$val" ;;
            wrap_target)
                if [[ ${#WRAP_TARGET[@]} -eq 0 && -n "$val" ]]; then
                    local IFS=' '
                    # shellcheck disable=SC2206
                    WRAP_TARGET=($val)
                fi
                ;;
            macros_enabled)
                [[ "$val" -eq 1 ]] && OPT_MACROS=1
                ;;
            macro_vars)
                if [[ -n "$val" ]]; then
                    local pair
                    local IFS=' '
                    for pair in $val; do
                        local mvk="${pair%%=*}"
                        local mvv="${pair#*=}"
                        _MACRO_VARS["$mvk"]="$mvv"
                    done
                fi
                ;;
        esac
    done < "$file"

    debug "Session state loaded from $file"
}

# =============================================================================
# SECTION: socat Address Builders
# =============================================================================

#
# build_exec_addr()
#
# Emits the socat EXEC address for wrapping a local command.
# Arguments: the command and all its args (as separate words).
#
build_exec_addr() {
    local -a target=("$@")

    local cmd_str
    cmd_str=$(printf '%q ' "${target[@]}")
    cmd_str="${cmd_str% }"

    local addr="EXEC:${cmd_str}"
    local -a opts=()

    if [[ "$OPT_NO_PTY" -eq 0 ]]; then
        opts+=("pty" "setsid" "echo=0")
    fi
    opts+=("stderr")

    local IFS=','
    [[ ${#opts[@]} -gt 0 ]] && printf '%s,%s' "$addr" "${opts[*]}" || printf '%s' "$addr"
}

#
# build_tcp_addr()
# TCP mode: connect to HOST:PORT with optional timeout and TLS.
#
build_tcp_addr() {
    local addr
    if [[ "$OPT_TLS" -eq 1 ]]; then
        addr="OPENSSL:${OPT_HOST}:${OPT_PORT}"
        local -a opts=("connect-timeout=${OPT_TIMEOUT}")
        [[ "$OPT_TLS_VERIFY" -eq 0 ]] && opts+=("verify=0")
    else
        addr="TCP:${OPT_HOST}:${OPT_PORT}"
        local -a opts=("connect-timeout=${OPT_TIMEOUT}")
    fi

    [[ "$OPT_CRLF" -eq 1 ]] && opts+=("crlf")

    local IFS=','
    [[ ${#opts[@]} -gt 0 ]] && printf '%s,%s' "$addr" "${opts[*]}" || printf '%s' "$addr"
}

#
# build_udp_addr()
# UDP mode: datagram connection to HOST:PORT.
#
build_udp_addr() {
    local addr="UDP:${OPT_HOST}:${OPT_PORT}"
    local -a opts=("connect-timeout=${OPT_TIMEOUT}")

    [[ "$OPT_CRLF" -eq 1 ]] && opts+=("crlf")

    local IFS=','
    printf '%s,%s' "$addr" "${opts[*]}"
}

#
# build_unix_addr()
# Unix domain socket mode.
#
build_unix_addr() {
    printf 'UNIX-CONNECT:%s' "$OPT_UNIX_SOCK"
}

#
# build_ssh_addr()
# SSH passthrough mode.
# socat wraps ssh in a PTY so readline sits on the local side.
#
build_ssh_addr() {
    local -a ssh_cmd=(ssh)

    # Inject SSH options if provided
    if [[ -n "$OPT_SSH_OPTS" ]]; then
        # Word-split the ssh options string deliberately
        # shellcheck disable=SC2206
        local -a extra_opts=($OPT_SSH_OPTS)
        ssh_cmd+=("${extra_opts[@]}")
    fi

    ssh_cmd+=("$OPT_SSH_TARGET")

    local cmd_str
    cmd_str=$(printf '%q ' "${ssh_cmd[@]}")
    cmd_str="${cmd_str% }"

    local addr="EXEC:${cmd_str}"
    local -a opts=(pty setsid echo=0 stderr)

    local IFS=','
    printf '%s,%s' "$addr" "${opts[*]}"
}

#
# build_telnet_addr()
# Telnet mode: TCP connection with IAC scrubbing on the output side.
#
build_telnet_addr() {
    build_tcp_addr
}

#
# build_chroot_addr()
# Chroot mode: exec a shell inside a chroot jail.
#
build_chroot_addr() {
    local shell="${OPT_CHROOT_SHELL:-$DEFAULT_SHELL}"

    # If additional args provided after chroot dir, use them as the shell + args
    if [[ ${#WRAP_TARGET[@]} -gt 0 ]]; then
        shell=$(printf '%q ' "${WRAP_TARGET[@]}")
        shell="${shell% }"
    fi

    local cmd_str
    cmd_str=$(printf 'chroot %q %s' "$OPT_CHROOT_DIR" "$shell")

    local addr="EXEC:${cmd_str}"
    local -a opts=(pty setsid echo=0 stderr)

    local IFS=','
    printf '%s,%s' "$addr" "${opts[*]}"
}

# =============================================================================
# SECTION: IAC Scrubber (Telnet)
# =============================================================================

#
# iac_scrub_cmd()
#
# Returns a shell pipeline fragment that strips Telnet IAC sequences.
# Preference order: perl (most reliable) → sed (POSIX-limited) → cat (none)
#
iac_scrub_cmd() {
    if [[ "$OPT_IAC_SCRUB" -eq 0 ]]; then
        printf '%s' 'cat'
        return
    fi

    if _has_perl; then
        debug "IAC scrubber: perl"
        # Strip: 0xFF + (DO/DONT/WILL/WONT=0xFB-0xFE) + option_byte  (3-byte)
        #        0xFF + (other cmds=0xF0-0xFA)                          (2-byte)
        #        0xFF 0xFF  (escaped literal 0xFF)
        printf '%s' 'perl -pe '"'"'$|=1; s/\xff[\xfb-\xfe][\x00-\xff]//g; s/\xff[\xf0-\xfa]//g; s/\xff\xff/\xff/g'"'"
    else
        debug "IAC scrubber: sed (limited — perl preferred)"
        # sed can't handle raw binary 0xFF portably; best-effort ANSI scrub
        local sbuf=""
        _has_stdbuf && sbuf="stdbuf -oL "
        printf '%s' "${sbuf}"'sed '"'"'s/\x1b\[[0-9;]*[mGKHFABCDJMPST]//g'"'"
        warn "perl not available — IAC scrubbing limited. Install perl for full telnet support."
    fi
}

# =============================================================================
# SECTION: Session Logging
# =============================================================================

#
# log_open()
#
# Writes a session header to the log file.
#
log_open() {
    [[ -n "$OPT_LOG" ]] || return 0

    SESSION_START_TIME=$(date +%s)
    local timestamp
    timestamp=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

    local target_desc=""
    case "$OPT_MODE" in
        exec)    target_desc=$(IFS=' '; echo "${WRAP_TARGET[*]}") ;;
        tcp)     target_desc="${OPT_HOST}:${OPT_PORT}" ;;
        udp)     target_desc="udp://${OPT_HOST}:${OPT_PORT}" ;;
        unix)    target_desc="${OPT_UNIX_SOCK}" ;;
        ssh)     target_desc="${OPT_SSH_TARGET}" ;;
        telnet)  target_desc="${OPT_HOST}:${OPT_PORT}" ;;
        chroot)  target_desc="${OPT_CHROOT_DIR}" ;;
    esac

    if [[ "$OPT_LOG_FORMAT" == "html" ]]; then
        cat >> "$OPT_LOG" <<HTMLHEADER
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<title>socwrap session — ${target_desc}</title>
<style>
body { background: #1e1e1e; color: #d4d4d4; font-family: monospace; white-space: pre-wrap; padding: 1em; }
.header, .footer { color: #569cd6; }
</style>
</head><body>
<span class="header"># ============================================================
# socwrap session log
# Version : ${SOCWRAP_VERSION}
# Started : ${timestamp}
# Mode    : ${OPT_MODE}
# Target  : ${target_desc}
# Format  : html
# ============================================================
</span>
HTMLHEADER
    else
        cat >> "$OPT_LOG" <<TEXTHEADER
# ============================================================
# socwrap session log
# Version : ${SOCWRAP_VERSION}
# Started : ${timestamp}
# Mode    : ${OPT_MODE}
# Target  : ${target_desc}
# Format  : ${OPT_LOG_FORMAT}
# ============================================================
TEXTHEADER
    fi

    debug "Log opened: $OPT_LOG (format: $OPT_LOG_FORMAT)"
}

#
# log_close()
#
# Writes a session footer to the log file.
#
log_close() {
    [[ -n "$OPT_LOG" ]] || return 0
    [[ -f "$OPT_LOG" ]] || return 0

    local timestamp
    timestamp=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

    local duration_str=""
    if [[ -n "$SESSION_START_TIME" ]]; then
        local now
        now=$(date +%s)
        local elapsed=$((now - SESSION_START_TIME))
        local mins=$((elapsed / 60))
        local secs=$((elapsed % 60))
        duration_str="${mins}m${secs}s"
    fi

    if [[ "$OPT_LOG_FORMAT" == "html" ]]; then
        cat >> "$OPT_LOG" <<HTMLFOOTER
<span class="footer">
# ============================================================
# Session ended : ${timestamp}
# Duration      : ${duration_str}
# ============================================================
</span>
</body></html>
HTMLFOOTER
    else
        cat >> "$OPT_LOG" <<TEXTFOOTER
# ============================================================
# Session ended : ${timestamp}
# Duration      : ${duration_str}
# ============================================================
TEXTFOOTER
    fi

    debug "Log closed: $OPT_LOG"
}

#
# build_log_tee_cmd()
#
# Returns a shell pipeline fragment that tees output into the log file
# in the appropriate format.
#
build_log_tee_cmd() {
    [[ -n "$OPT_LOG" ]] || return 0

    local log_escaped
    log_escaped=$(printf '%q' "$OPT_LOG")

    # stdbuf prefix for line-buffered tee (avoids block-buffered log output).
    local sbuf=""
    if _has_stdbuf; then
        sbuf="stdbuf -oL "
    fi

    case "$OPT_LOG_FORMAT" in
        text)
            if [[ "$OPT_LOG_TIMESTAMP" -eq 1 ]]; then
                # shellcheck disable=SC2016
                printf '%s' 'awk '"'"'{ printf "%s  %s\n", strftime("%H:%M:%S"), $0; fflush() }'"'"' | '"${sbuf}"'tee -a '"${log_escaped}"
            else
                printf '%s' "${sbuf}tee -a ${log_escaped}"
            fi
            ;;
        tsv)
            # shellcheck disable=SC2016
            printf '%s' 'awk '"'"'{ printf "%s\t%s\n", strftime("%Y-%m-%dT%H:%M:%S"), $0; fflush() }'"'"' | '"${sbuf}"'tee -a '"${log_escaped}"
            ;;
        html)
            printf '%s' "${sbuf}tee >(aha --no-header >> ${log_escaped})"
            ;;
    esac
}

# =============================================================================
# SECTION: Session Recording (Phase 7 — asciicast v2)
# =============================================================================

#
# cast_open()
#
# Writes the asciicast v2 header to the recording file and stores the
# start time for event timestamps.
#
cast_open() {
    [[ -n "$OPT_RECORD" ]] || return 0

    _RECORD_START="$EPOCHREALTIME"

    local term_width term_height
    term_width=$(tput cols  2>/dev/null) || term_width=80
    term_height=$(tput lines 2>/dev/null) || term_height=24

    local unix_ts
    unix_ts=$(date +%s)

    local target_desc=""
    case "$OPT_MODE" in
        exec)    target_desc=$(IFS=' '; echo "${WRAP_TARGET[*]}") ;;
        tcp)     target_desc="${OPT_HOST}:${OPT_PORT}" ;;
        udp)     target_desc="udp://${OPT_HOST}:${OPT_PORT}" ;;
        unix)    target_desc="${OPT_UNIX_SOCK}" ;;
        ssh)     target_desc="${OPT_SSH_TARGET}" ;;
        telnet)  target_desc="${OPT_HOST}:${OPT_PORT}" ;;
        chroot)  target_desc="${OPT_CHROOT_DIR}" ;;
    esac

    # Write asciicast v2 header (single JSON line)
    printf '{"version": 2, "width": %d, "height": %d, "timestamp": %s, "title": "%s", "env": {"SHELL": "%s", "TERM": "%s"}}\n' \
        "$term_width" "$term_height" "$unix_ts" \
        "socwrap ${OPT_MODE}: ${target_desc}" \
        "${SHELL:-/bin/bash}" "${TERM:-xterm}" \
        > "$OPT_RECORD"

    debug "Recording to: $OPT_RECORD (asciicast v2, ${term_width}x${term_height})"
}

#
# cast_event TYPE DATA
#
# Appends a single asciicast v2 event line: [elapsed, "type", "data"]
# TYPE is "o" (output) or "i" (input).
# DATA is the raw string to record (will be JSON-escaped).
#
cast_event() {
    [[ -n "$OPT_RECORD" ]] || return 0

    local etype="$1" edata="$2"

    # Compute elapsed time using awk for float subtraction
    local delta
    delta=$(awk "BEGIN{printf \"%.6f\", ${EPOCHREALTIME} - ${_RECORD_START}}")

    # JSON-escape the data
    local escaped="$edata"
    escaped="${escaped//\\/\\\\}"         # backslash first
    escaped="${escaped//\"/\\\"}"         # double quotes
    escaped="${escaped//$'\t'/\\t}"       # tab
    escaped="${escaped//$'\r'/\\r}"       # carriage return
    escaped="${escaped//$'\n'/\\n}"       # newline

    printf '[%s, "%s", "%s"]\n' "$delta" "$etype" "$escaped" >> "$OPT_RECORD"
}

#
# cast_close()
#
# Finalizes the recording. The asciicast v2 format doesn't require a
# footer, but we log a final marker event for completeness.
#
cast_close() {
    [[ -n "$OPT_RECORD" ]] || return 0
    [[ -f "$OPT_RECORD" ]] || return 0

    # Emit a final output event with session-end marker
    cast_event "o" "[session ended]\\r\\n"

    local delta
    delta=$(awk "BEGIN{printf \"%.1f\", ${EPOCHREALTIME} - ${_RECORD_START}}")
    info "Recording saved: $OPT_RECORD (${delta}s)"
}

#
# _cast_output_forwarder CAST_FILE START_TIME
#
# Reads lines from stdin (connected to socat's output pipe), forwards
# each line to stdout (the terminal), and records it as an "o" event
# in the asciicast file.  Runs as a background process.
#
_cast_output_forwarder() {
    local cast_file="$1" start_time="$2"
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line"           # pass through to terminal

        # Compute delta
        local delta
        delta=$(awk "BEGIN{printf \"%.6f\", ${EPOCHREALTIME} - ${start_time}}")

        # JSON-escape
        local escaped="$line"
        escaped="${escaped//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        escaped="${escaped//$'\t'/\\t}"
        escaped="${escaped//$'\r'/\\r}"

        printf '[%s, "o", "%s\\n"]\n' "$delta" "$escaped" >> "$cast_file"
    done
}

#
# replay_cast FILE [SPEED]
#
# Replays an asciicast v2 file to the terminal with original timing.
# SPEED is a multiplier: 2 = double speed, 0.5 = half speed.
#
replay_cast() {
    local cast_file="$1"
    local speed="${2:-1}"

    if [[ ! -f "$cast_file" ]]; then
        die "Recording file not found: $cast_file"
    fi

    # Read and display header info
    local header
    IFS= read -r header < "$cast_file"

    local title=""
    if command -v jq >/dev/null 2>&1; then
        title=$(printf '%s' "$header" | jq -r '.title // empty' 2>/dev/null) || true
    fi
    [[ -n "$title" ]] && info "Replaying: $title"
    info "File: $cast_file (speed: ${speed}x)"
    info "Press Ctrl-C to stop playback"
    printf '\n'

    local prev_time=0
    local line_num=0
    while IFS= read -r event_line; do
        line_num=$((line_num + 1))
        [[ -z "$event_line" ]] && continue

        # Parse the event: [time, "type", "data"]
        # Use awk to extract fields from the JSON array
        local etime etype edata

        if command -v jq >/dev/null 2>&1; then
            etime=$(printf '%s' "$event_line" | jq -r '.[0]' 2>/dev/null) || continue
            etype=$(printf '%s' "$event_line" | jq -r '.[1]' 2>/dev/null) || continue
            edata=$(printf '%s' "$event_line" | jq -r '.[2]' 2>/dev/null) || continue
        else
            # Lightweight awk fallback: parse [time, "type", "data"]
            etime=$(printf '%s' "$event_line" | awk -F',' '{gsub(/[[ \t]/,"",$1); print $1}')
            etype=$(printf '%s' "$event_line" | awk -F'"' '{print $2}')
            # Data is everything between the second pair of quotes to the closing bracket
            edata=$(printf '%s' "$event_line" | sed 's/^[^"]*"[^"]*"[^"]*"//; s/"[[:space:]]*]$//')
        fi

        # Only replay output events
        [[ "$etype" == "o" ]] || continue

        # Compute and apply delay
        local delay
        delay=$(awk "BEGIN{d=($etime - $prev_time) / $speed; if(d>5) d=5; if(d>0.001) printf \"%.4f\",d; else print \"0\"}")
        if [[ "$delay" != "0" ]]; then
            sleep "$delay" 2>/dev/null || true
        fi

        # Output the data. Command substitution strips the trailing newline
        # that jq -r decoded from the JSON "\n", so restore it.
        printf '%s\n' "$edata"

        prev_time="$etime"
    done < <(tail -n +2 "$cast_file")

    printf '\n'
    info "Replay complete"
}

# =============================================================================
# SECTION: Filter Pipeline Builder
# =============================================================================

#
# resolve_filter()
#
# Takes a filter specification (either @builtin or a custom command) and
# returns the resolved shell command.
#
resolve_filter() {
    local spec="$1"

    if [[ "$spec" == @* ]]; then
        resolve_builtin_filter "$spec"
    else
        printf '%s' "$spec"
    fi
}

#
# build_post_filter_pipeline()
#
# Assembles the complete post-filter pipeline string.
# This includes:
#   1. Implicit @iac-strip for telnet mode (if IAC scrub is on)
#   2. User-specified --post-filter stages
#   3. Log tee stage (if --log is active)
#
# Returns the pipeline via stdout. Empty string = no filtering needed.
#
build_post_filter_pipeline() {
    local -a stages=()

    # Implicit IAC stripping for telnet mode
    if [[ "$OPT_MODE" == "telnet" && "$OPT_IAC_SCRUB" -eq 1 ]]; then
        local iac_cmd
        iac_cmd=$(resolve_builtin_filter "@iac-strip")
        stages+=("$iac_cmd")
    fi

    # User post-filters
    local f resolved
    for f in "${OPT_POST_FILTERS[@]}"; do
        resolved=$(resolve_filter "$f")
        stages+=("$resolved")
    done

    # Log tee (last stage — logs post-filtered output)
    if [[ -n "$OPT_LOG" ]]; then
        local log_cmd
        log_cmd=$(build_log_tee_cmd)
        if [[ -n "$log_cmd" ]]; then
            stages+=("$log_cmd")
        fi
    fi

    if [[ ${#stages[@]} -eq 0 ]]; then
        return 0
    fi

    local IFS='|'
    # Join stages with " | "
    local result=""
    local i
    for (( i=0; i<${#stages[@]}; i++ )); do
        if [[ $i -eq 0 ]]; then
            result="${stages[$i]}"
        else
            result="${result} | ${stages[$i]}"
        fi
    done
    printf '%s' "$result"
}

#
# build_pre_filter_pipeline()
#
# Assembles the pre-filter pipeline string from user-specified --pre-filter stages.
# Returns the pipeline via stdout. Empty string = no pre-filtering.
#
build_pre_filter_pipeline() {
    if [[ ${#OPT_PRE_FILTERS[@]} -eq 0 ]]; then
        return 0
    fi

    local -a stages=()
    local f resolved
    for f in "${OPT_PRE_FILTERS[@]}"; do
        resolved=$(resolve_filter "$f")
        stages+=("$resolved")
    done

    local result=""
    local i
    for (( i=0; i<${#stages[@]}; i++ )); do
        if [[ $i -eq 0 ]]; then
            result="${stages[$i]}"
        else
            result="${result} | ${stages[$i]}"
        fi
    done
    printf '%s' "$result"
}

#
# has_filters()
#
# Returns 0 if any filters or logging are active (pipeline wrapper needed).
#
has_filters() {
    [[ ${#OPT_PRE_FILTERS[@]} -gt 0 ]] && return 0
    [[ ${#OPT_POST_FILTERS[@]} -gt 0 ]] && return 0
    [[ -n "$OPT_LOG" ]] && return 0
    # Telnet implicit IAC scrub counts as a filter
    [[ "$OPT_MODE" == "telnet" && "$OPT_IAC_SCRUB" -eq 1 ]] && return 0
    return 1
}

# =============================================================================
# SECTION: socat Command Assembler
# =============================================================================

#
# build_socat_cmd()
# Dispatches to the correct address builder based on OPT_MODE.
# Populates the global SOCAT_CMD array.
#
build_socat_cmd() {
    local remote_addr

    case "$OPT_MODE" in
        exec)
            remote_addr=$(build_exec_addr "${WRAP_TARGET[@]}")
            ;;
        tcp)
            remote_addr=$(build_tcp_addr)
            ;;
        udp)
            remote_addr=$(build_udp_addr)
            ;;
        unix)
            remote_addr=$(build_unix_addr)
            ;;
        ssh)
            remote_addr=$(build_ssh_addr)
            ;;
        telnet)
            remote_addr=$(build_telnet_addr)
            ;;
        chroot)
            remote_addr=$(build_chroot_addr)
            ;;
        *)
            die "Unknown mode: $OPT_MODE"
            ;;
    esac

    SOCAT_CMD=(socat "-" "$remote_addr")
    debug "socat command: ${SOCAT_CMD[*]}"
}

# =============================================================================
# SECTION: Execution
# =============================================================================

#
# run_dry()
#
# Prints what would be executed without actually running it.
#
run_dry() {
    printf '\n[%s] DRY RUN — mode: %s\n' "$SOCWRAP_NAME" "$OPT_MODE"
    [[ -n "$OPT_PROFILE" ]] && printf '[%s] Profile     : %s (from %s)\n' \
        "$SOCWRAP_NAME" "$OPT_PROFILE" "$_RESOLVED_CONFIG"
    printf '\n'

    # Readline layer: bash's read -e (not socat READLINE)
    printf '  Readline layer (bash read -e):\n'
    printf '    Prompt      : %s\n' "$OPT_PROMPT"
    printf '    History file: %s\n' "$OPT_HISTFILE"
    printf '    History size: %s\n' "$OPT_HISTSIZE"
    [[ -n "$OPT_LOG" ]] && printf '    Session log : %s (format: %s)\n' "$OPT_LOG" "$OPT_LOG_FORMAT"
    if [[ "$OPT_MODE" == "telnet" ]]; then
        printf '    IAC scrub   : %s\n' "$(iac_scrub_cmd)"
    fi
    if [[ "$OPT_MACROS" -eq 1 ]]; then
        printf '    Macros      : enabled (%d defined)\n' "${#_MACROS[@]}"
    fi
    [[ -n "$OPT_SAVE_STATE" ]] && printf '    Save state  : %s\n' "$OPT_SAVE_STATE"
    [[ -n "$OPT_LOAD_STATE" ]] && printf '    Loaded from : %s\n' "$OPT_LOAD_STATE"
    [[ -n "$OPT_RECORD" ]] && printf '    Recording   : %s (asciicast v2, input: %s)\n' "$OPT_RECORD" "$( [[ "$OPT_RECORD_INPUT" -eq 1 ]] && echo yes || echo no)"
    printf '\n'

    # socat I/O bridge command
    printf '  socat I/O bridge:\n'
    printf '    %s \\\n' "${SOCAT_CMD[0]}"
    local i
    for (( i=1; i<${#SOCAT_CMD[@]}-1; i++ )); do
        printf '      "%s" \\\n' "${SOCAT_CMD[$i]}"
    done
    printf '      "%s"\n\n' "${SOCAT_CMD[-1]}"

    printf '[%s] Mode        : %s\n'   "$SOCWRAP_NAME" "$OPT_MODE"
    printf '[%s] PTY         : %s\n'   "$SOCWRAP_NAME" "$( [[ $OPT_NO_PTY -eq 0 ]] && echo enabled || echo disabled )"
    printf '[%s] Timeout     : %ss\n'  "$SOCWRAP_NAME" "$OPT_TIMEOUT"

    case "$OPT_MODE" in
        tcp|telnet)
            printf '[%s] Host        : %s\n' "$SOCWRAP_NAME" "$OPT_HOST"
            printf '[%s] Port        : %s\n' "$SOCWRAP_NAME" "$OPT_PORT"
            if [[ "$OPT_TLS" -eq 1 ]]; then
                printf '[%s] TLS         : enabled (verify=%s)\n' \
                    "$SOCWRAP_NAME" "$( [[ $OPT_TLS_VERIFY -eq 1 ]] && echo on || echo off )"
            fi
            if [[ "$OPT_CRLF" -eq 1 ]]; then
                printf '[%s] CRLF        : enabled\n' "$SOCWRAP_NAME"
            fi
            ;;
        udp)
            printf '[%s] Host        : %s\n' "$SOCWRAP_NAME" "$OPT_HOST"
            printf '[%s] Port        : %s\n' "$SOCWRAP_NAME" "$OPT_PORT"
            ;;
        unix)
            printf '[%s] Socket      : %s\n' "$SOCWRAP_NAME" "$OPT_UNIX_SOCK"
            ;;
        ssh)
            printf '[%s] SSH target  : %s\n' "$SOCWRAP_NAME" "$OPT_SSH_TARGET"
            if [[ -n "$OPT_SSH_OPTS" ]]; then
                printf '[%s] SSH opts    : %s\n' "$SOCWRAP_NAME" "$OPT_SSH_OPTS"
            fi
            ;;
        chroot)
            printf '[%s] Chroot dir  : %s\n' "$SOCWRAP_NAME" "$OPT_CHROOT_DIR"
            printf '[%s] Chroot shell: %s\n' "$SOCWRAP_NAME" "$OPT_CHROOT_SHELL"
            ;;
    esac

    # Show filter pipelines if any
    if [[ ${#OPT_PRE_FILTERS[@]} -gt 0 ]]; then
        printf '\n[%s] Pre-filter pipeline (%d stage(s)):\n' "$SOCWRAP_NAME" "${#OPT_PRE_FILTERS[@]}"
        local idx=1
        local f resolved
        for f in "${OPT_PRE_FILTERS[@]}"; do
            resolved=$(resolve_filter "$f")
            printf '[%s]   %d. %-20s → %s\n' "$SOCWRAP_NAME" "$idx" "$f" "$resolved"
            idx=$((idx + 1))
        done
    fi

    local post_count=${#OPT_POST_FILTERS[@]}
    local has_implicit_iac=0
    if [[ "$OPT_MODE" == "telnet" && "$OPT_IAC_SCRUB" -eq 1 ]]; then
        has_implicit_iac=1
        post_count=$((post_count + 1))
    fi
    local has_log_stage=0
    if [[ -n "$OPT_LOG" ]]; then
        has_log_stage=1
        post_count=$((post_count + 1))
    fi

    if [[ $post_count -gt 0 ]]; then
        printf '\n[%s] Post-filter pipeline (%d stage(s)):\n' "$SOCWRAP_NAME" "$post_count"
        local idx=1

        if [[ $has_implicit_iac -eq 1 ]]; then
            local iac_resolved
            iac_resolved=$(resolve_builtin_filter "@iac-strip")
            printf '[%s]   %d. %-20s → %s\n' "$SOCWRAP_NAME" "$idx" "@iac-strip (implicit)" "$iac_resolved"
            idx=$((idx + 1))
        fi

        local f resolved
        for f in "${OPT_POST_FILTERS[@]}"; do
            resolved=$(resolve_filter "$f")
            printf '[%s]   %d. %-20s → %s\n' "$SOCWRAP_NAME" "$idx" "$f" "$resolved"
            idx=$((idx + 1))
        done

        if [[ $has_log_stage -eq 1 ]]; then
            local log_cmd
            log_cmd=$(build_log_tee_cmd)
            printf '[%s]   %d. %-20s → %s\n' "$SOCWRAP_NAME" "$idx" "log ($OPT_LOG_FORMAT)" "$log_cmd"
        fi
    fi

    printf '\n'
}

#
# _interpret_exit()
# Translate socat exit codes to human-readable warnings.
#
_interpret_exit() {
    local rc=$1
    case $rc in
        0)   debug "socat exited cleanly" ;;
        1)   warn "socat: general error (exit 1) — check connection parameters" ;;
        2)   warn "socat: syntax/usage error (exit 2)" ;;
        111) warn "socat: connection refused — is the target listening?" ;;
        130) debug "socat: interrupted by user (Ctrl-C)" ;;
        143) debug "socat: terminated by signal" ;;
        *)   warn "socat: exited with code $rc" ;;
    esac
}

#
# run_socat()
#
# Runs the interactive readline loop using bash's read -e builtin, with
# socat serving as the I/O bridge to the wrapped command/connection.
#
# Architecture:
#   User terminal
#       │  bash read -e  (readline: editing, history, Ctrl-R, prompt display)
#       │
#       ├─► named pipe (in_pipe)  ─► socat stdin  ─► target
#       └─◄ named pipe (out_pipe) ◄─ socat stdout ◄─ target
#                                         │
#                               [post-filter pipeline]
#
run_socat() {
    debug "Launching socat in mode: $OPT_MODE"

    # Ensure history file's parent directory exists
    local histdir
    histdir=$(dirname "$OPT_HISTFILE")
    if [[ ! -d "$histdir" ]]; then
        mkdir -p "$histdir" || warn "Could not create history directory: $histdir"
    fi

    # Save terminal state before handing control to socat
    SAVED_STTY=$(stty -g 2>/dev/null) || true

    # Open session log (header)
    log_open

    # Create named pipes for bidirectional I/O with socat
    local tmpdir
    tmpdir=$(mktemp -d)
    local in_pipe="${tmpdir}/stdin"
    local out_pipe="${tmpdir}/stdout"
    mkfifo "$in_pipe" "$out_pipe"

    # Start socat (I/O bridge only — readline handled by bash's read -e below).
    "${SOCAT_CMD[@]}" 0<"$in_pipe" 1>"$out_pipe" &
    local socat_pid=$!

    # Open both ends of the named pipes, then remove the filesystem entries.
    exec 4>"$in_pipe"   # write end: push readline input to socat
    exec 5<"$out_pipe"  # read end:  receive wrapped command output from socat
    rm -rf "$tmpdir"

    # Build post-filter pipeline for output forwarding
    local post_pipeline
    post_pipeline=$(build_post_filter_pipeline)

    # Build pre-filter pipeline for input transformation
    local pre_pipeline
    pre_pipeline=$(build_pre_filter_pipeline)

    # Open session recording (Phase 7 — asciicast v2 header)
    cast_open

    # Forward wrapped command output to terminal.
    # If filters are active, pipe through the post-filter pipeline.
    # If recording, also capture output as asciicast events.
    local cat_pid
    if [[ -n "$post_pipeline" ]]; then
        debug "Post-filter pipeline: $post_pipeline"
        if [[ -n "$OPT_RECORD" ]]; then
            eval "$post_pipeline" <&5 | _cast_output_forwarder "$OPT_RECORD" "$_RECORD_START" &
        else
            eval "$post_pipeline" <&5 &
        fi
    elif [[ -n "$OPT_RECORD" ]]; then
        # Recording active — forward through cast recorder
        if [[ -n "$OPT_LOG" ]]; then
            tee -a "$OPT_LOG" <&5 | _cast_output_forwarder "$OPT_RECORD" "$_RECORD_START" &
        else
            _cast_output_forwarder "$OPT_RECORD" "$_RECORD_START" <&5 &
        fi
    elif [[ -n "$OPT_LOG" ]]; then
        # No filters but logging active — simple tee.
        # Line-buffered via stdbuf when available so the log isn't delayed
        # by block buffering.
        debug "Session logging to: $OPT_LOG"
        local -a _tee_cmd=(tee -a "$OPT_LOG")
        if _has_stdbuf; then
            _tee_cmd=(stdbuf -oL tee -a "$OPT_LOG")
        fi
        "${_tee_cmd[@]}" <&5 &
    else
        cat <&5 &
    fi
    cat_pid=$!

    # Monitor: poll until socat exits, then send SIGUSR1 to break the read loop.
    (
        while kill -0 "$socat_pid" 2>/dev/null; do sleep 0.05; done
        kill -USR1 $$ 2>/dev/null
    ) &
    local monitor_pid=$!

    # Enable bash history mechanism (disabled by default in non-interactive
    # shells). Required for history -s / history -r / history -w to work
    # when socwrap is invoked as a script rather than sourced.
    set -o history
    # Apply history size limit (entries kept in memory and on disk)
    HISTSIZE="$OPT_HISTSIZE"
    HISTFILESIZE="$OPT_HISTSIZE"
    # Load persistent readline history into this bash session
    history -r "$OPT_HISTFILE" 2>/dev/null || true

    # Override signal handling for the interactive loop:
    #   INT  (Ctrl-C) — cancels the current readline line; stays in the loop
    #   USR1          — sent by monitor when wrapped process exits; breaks loop
    trap 'true' INT
    local _loop_exit=0
    trap '_loop_exit=1' USR1

    # ── Readline input loop ─────────────────────────────────────────────────
    # bash's read -e uses GNU readline: line editing, arrow-key history,
    # Ctrl-R reverse search, and — unlike socat's READLINE address — the
    # prompt renders immediately on each iteration without a keypress.
    #
    # Disable errexit for the loop: read returns non-zero on EOF (Ctrl-D)
    # and signal interrupts.  With set -e active, that would kill the script
    # before the post-loop cleanup (history write, fd close, reaping) runs.
    set +e
    local line rc=0
    while true; do
        IFS= read -e -r -p "$OPT_PROMPT" line
        rc=$?

        # USR1 arrived while read was blocking — wrapped process has exited
        [[ $_loop_exit -eq 1 ]] && break

        if [[ $rc -eq 0 ]]; then
            [[ -n "$line" ]] && history -s "$line"

            # Macro engine: intercept // prefixed lines (Phase 6)
            if [[ "$OPT_MACROS" -eq 1 && "$line" == //* ]]; then
                _macro_handle_line "$line"
                # Macro lines are never sent to remote — skip to next prompt
                sleep 0.05
                [[ $_loop_exit -eq 1 ]] && break
                kill -0 "$cat_pid" 2>/dev/null || break
                continue
            fi

            # Apply pre-filter pipeline if active
            if [[ -n "$pre_pipeline" ]]; then
                local filtered_line
                filtered_line=$(printf '%s' "$line" | eval "$pre_pipeline") || true
                printf '%s\n' "$filtered_line" >&4 || break
            else
                printf '%s\n' "$line" >&4 || break   # broken pipe = socat gone
            fi

            # Record input event (Phase 7)
            if [[ "$OPT_RECORD_INPUT" -eq 1 && -n "$OPT_RECORD" ]]; then
                cast_event "i" "${line}\n"
            fi

            # Brief pause: let the async output forwarder (cat) flush the
            # command's output to the terminal before read -e redraws the
            # prompt. Without this, fast commands (ls, pwd, etc.) race with
            # the prompt and their output appears after it.
            sleep 0.05
            # If the wrapped process exited during the sleep, break now.
            [[ $_loop_exit -eq 1 ]] && break
            kill -0 "$cat_pid" 2>/dev/null || break
        elif [[ $rc -eq 130 ]]; then
            continue    # Ctrl-C: readline cleaned up; re-show prompt
        else
            break       # Ctrl-D (EOF) or fatal read error
        fi
    done
    set -e
    # ───────────────────────────────────────────────────────────────────────

    # Restore signal handling
    trap 'exit 130' INT
    trap - USR1

    # Persist history, then disable the history mechanism we enabled earlier
    history -w "$OPT_HISTFILE" 2>/dev/null || true
    set +o history

    # Close our write end of in_pipe — socat sees EOF on stdin and exits
    exec 4>&-

    # Reap socat and capture its exit code
    wait "$socat_pid" 2>/dev/null
    rc=$?

    # Clean up remaining background helpers
    exec 5>&-
    kill "$cat_pid" 2>/dev/null || true
    kill "$monitor_pid" 2>/dev/null || true
    wait "$cat_pid" 2>/dev/null || true

    # Close session log (footer)
    log_close

    # Finalize recording (Phase 7)
    cast_close

    _interpret_exit "$rc"
    return $rc
}

# =============================================================================
# SECTION: Verbose Banner
# =============================================================================

print_banner() {
    info "${SOCWRAP_NAME} ${SOCWRAP_VERSION} starting"
    info "Mode    : ${OPT_MODE}"

    case "$OPT_MODE" in
        exec)    info "Wrapping: ${WRAP_TARGET[*]}" ;;
        tcp)     info "Target  : ${OPT_HOST}:${OPT_PORT}" ;;
        udp)     info "Target  : udp://${OPT_HOST}:${OPT_PORT}" ;;
        unix)    info "Socket  : ${OPT_UNIX_SOCK}" ;;
        ssh)     info "SSH     : ${OPT_SSH_TARGET}" ;;
        telnet)  info "Telnet  : ${OPT_HOST}:${OPT_PORT}" ;;
        chroot)  info "Chroot  : ${OPT_CHROOT_DIR} (${OPT_CHROOT_SHELL})" ;;
    esac

    [[ -n "$OPT_PROFILE" ]] && info "Profile : ${OPT_PROFILE} (from ${_RESOLVED_CONFIG})"
    [[ -n "$_RESOLVED_CONFIG" && -f "$_RESOLVED_CONFIG" ]] && info "Config  : ${_RESOLVED_CONFIG}"
    info "History : ${OPT_HISTFILE}"
    info "Prompt  : ${OPT_PROMPT}"
    [[ -n "$OPT_LOG" ]] && info "Log     : ${OPT_LOG} (format: ${OPT_LOG_FORMAT})"
    [[ -n "$OPT_RECORD" ]] && info "Record  : ${OPT_RECORD} (asciicast v2, input: $( [[ "$OPT_RECORD_INPUT" -eq 1 ]] && echo yes || echo no))"

    if [[ ${#OPT_PRE_FILTERS[@]} -gt 0 ]]; then
        info "Pre-filters : ${OPT_PRE_FILTERS[*]}"
    fi
    if [[ ${#OPT_POST_FILTERS[@]} -gt 0 ]]; then
        info "Post-filters: ${OPT_POST_FILTERS[*]}"
    fi
    if [[ ${#_LOADED_PLUGINS[@]} -gt 0 ]]; then
        info "Plugins : ${#_LOADED_PLUGINS[@]} loaded"
    fi
    if [[ "$OPT_MACROS" -eq 1 ]]; then
        info "Macros  : enabled (${#_MACROS[@]} defined)"
    fi

    detect_env >&2
    printf '\n' >&2
}

# =============================================================================
# SECTION: Help Text
# =============================================================================

show_help() {
    cat <<EOF

${SOCWRAP_NAME} ${SOCWRAP_VERSION} — socat-based interactive terminal wrapper

USAGE
  socwrap.sh [OPTIONS] -- COMMAND [ARGS...]     EXEC mode (local command)
  socwrap.sh [OPTIONS] -t HOST PORT             TCP mode
  socwrap.sh [OPTIONS] -u HOST PORT             UDP mode
  socwrap.sh [OPTIONS] -U SOCKET_PATH           Unix domain socket mode
  socwrap.sh [OPTIONS] -s USER@HOST             SSH passthrough mode
  socwrap.sh [OPTIONS] -T HOST PORT             Telnet mode (TCP + IAC scrub)
  socwrap.sh [OPTIONS] -c CHROOTDIR [SHELL]     Chroot shell mode
  socwrap.sh --detect                           Capability report
  socwrap.sh --list-filters                     Show built-in filters
  socwrap.sh --man                              Man-page formatted help
  socwrap.sh --help                             This help

MODE FLAGS (mutually exclusive)
  -t HOST PORT     Connect via TCP
  -u HOST PORT     Connect via UDP
  -U SOCKET        Connect to Unix domain socket at SOCKET path
  -s USER@HOST     Wrap an SSH session (readline on local side)
  -T HOST PORT     Telnet mode — TCP with IAC sequence scrubbing
  -c CHROOTDIR     Chroot into CHROOTDIR and run SHELL (default: /bin/sh)
                   Additional args after CHROOTDIR override the shell

COMMON OPTIONS
  -H, --history FILE    History file  (default: ~/.socwrap_history)
                        Env: SOCWRAP_HISTFILE
  -n, --histsize N      Max history entries kept  (default: 500)
                        Env: SOCWRAP_HISTSIZE
  -p, --prompt STR      Prompt string  (default: "socwrap> ")
                        Env: SOCWRAP_PROMPT
  -l, --log FILE        Append session output to FILE
      --log-format FMT  Log format: text (default), tsv, html
      --log-timestamp   Prepend timestamps in text-format logs
      --timeout N       Connection timeout in seconds  (default: 10)
      --no-pty          Disable PTY allocation (EXEC/SSH/chroot modes)
      --ssh-opts OPTS   Extra SSH options (e.g. "--ssh-opts '-i ~/.ssh/id_rsa'")
      --tls             Enable TLS for TCP connections
      --no-tls-verify   Skip TLS certificate verification (self-signed certs)
      --no-iac-scrub    Disable IAC sequence scrubbing in telnet mode
  -C, --crlf            Convert LF to CRLF on output (for HTTP/SMTP/etc)

FILTER OPTIONS
      --post-filter CMD   Add a post-filter stage (remote output → terminal)
                          Accumulates; order matters. Use @name for built-ins.
      --pre-filter CMD    Add a pre-filter stage (typed input → remote)
                          Accumulates; order matters. Use @name for built-ins.
      --list-filters      Show available built-in filters and exit

CONFIG & PROFILES
      --profile NAME    Load named profile from config file
      --list-profiles   List all configured profiles and exit
      --init-config     Create ~/.socwraprc with example profiles and exit
      --validate-config Validate config syntax and structure, then exit
      --no-config       Skip config file loading entirely
      --rc FILE         Use alternate config file (default: ~/.socwraprc)

PLUGIN OPTIONS
      --list-plugins    List loaded plugins and their contributions
      --no-plugins      Skip plugin loading from ~/.socwrap.d/

MACRO OPTIONS
      --macros          Enable the macro engine for this session
      --macro-file FILE Load macros from external JSON file
      --list-macros     List available macros for current mode/profile

SESSION PERSISTENCE
      --save-state FILE Save session state to FILE on exit
      --load-state FILE Restore session state from FILE at startup

SESSION RECORDING (asciicast v2)
      --record FILE     Record session to FILE in asciicast v2 (.cast) format
      --record-input    Also record input events (off by default for privacy)
      --replay FILE     Replay a previously recorded .cast file and exit
      --replay-speed N  Playback speed multiplier (default: 1, e.g. 2 = double)

DIAGNOSTIC OPTIONS
  -d, --dry-run         Show socat command and filter pipeline without executing
  -D, --detect          Run capability detection and exit
  -v, --verbose         Debug output on stderr
  -m, --man             Display help as a formatted man page
  -V, --version         Print version and exit
  -h, --help            This help

BUILT-IN FILTERS
  @timestamp    Prepend HH:MM:SS to each line (post)
  @datestamp    Prepend YYYY-MM-DD HH:MM:SS to each line (post)
  @ansi-strip   Strip ANSI/VT100 escape sequences (post)
  @iac-strip    Strip Telnet IAC negotiation bytes (post, needs perl)
  @hex-dump     Hex dump output (post, needs xxd)
  @json-pp      Pretty-print JSON lines (post, needs jq)
  @rot13        ROT-13 encode/decode (both directions)
  @upper        Uppercase all characters (both directions)
  @lower        Lowercase all characters (both directions)
  @trim         Strip leading/trailing whitespace (post)
  @noblank      Suppress blank lines (post)
  @tee:FILE     Tee output into FILE while passing through (post)

EXAMPLES
  # Wrap bash with readline
  socwrap.sh --no-pty -p "bash> " -- /bin/bash --norc --noprofile

  # TCP with ANSI stripping and timestamps
  socwrap.sh --post-filter @ansi-strip --post-filter @timestamp -t host 8080

  # Telnet with clean output + HTML session log
  socwrap.sh --post-filter @ansi-strip -l session.html --log-format html -T router 23

  # JSON API with pretty-printing
  socwrap.sh --post-filter @json-pp -t api.internal 3000

  # Session logging with timestamps
  socwrap.sh -l session.log --log-timestamp -t host 80

  # ROT-13 in both directions
  socwrap.sh --pre-filter @rot13 --post-filter @rot13 -- /bin/bash

  # Custom grep filter
  socwrap.sh --post-filter "grep --line-buffered -i error" -t loghost 514

  # Use a named profile
  socwrap.sh --profile router

  # Profile with CLI overrides
  socwrap.sh --profile router -p "core-sw-01> "

  # List configured profiles
  socwrap.sh --list-profiles

  # Bootstrap a new config
  socwrap.sh --init-config

  # See what would run without executing
  socwrap.sh --dry-run --post-filter @ansi-strip -t host 80

  # Record a session (asciicast v2)
  socwrap.sh --record session.cast -- /bin/bash
  socwrap.sh --record debug.cast --record-input -t host 22

  # Replay a recorded session
  socwrap.sh --replay session.cast
  socwrap.sh --replay session.cast --replay-speed 2

ENVIRONMENT VARIABLES
  SOCWRAP_HISTFILE    Override default history file path
  SOCWRAP_HISTSIZE    Override default history size limit
  SOCWRAP_PROMPT      Override default prompt string
  SOCWRAP_SSH_OPTS    Extra SSH options (alternative to --ssh-opts)
  SOCWRAP_RC          Override default config file path (~/.socwraprc)

NOTES
  socat readline support is NOT required. socat is used only as an I/O
  bridge; readline is provided by bash's read -e builtin.

  WRAPPING INTERACTIVE SHELLS (bash, sh, zsh):
    Use --no-pty (recommended) or pass PS1='' via env (see EXAMPLES).

  FILTER COMPOSITION:
    Filters compose left-to-right in the order specified. Each
    --post-filter or --pre-filter adds one stage to the pipeline.
    The output of stage N feeds into stage N+1.

  LINE BUFFERING:
    Custom filters must handle their own flushing. Use --line-buffered
    with grep, fflush() in awk, or \$|=1 in perl. Without it, output
    will batch and your interactive session will feel laggy.

  TELNET IAC SCRUBBING:
    In telnet mode, @iac-strip is automatically prepended to the
    post-filter chain. Use --no-iac-scrub to disable.

EOF
}

# =============================================================================
# SECTION: Man Page (Phase 5)
# =============================================================================

#
# show_man_page()
#
# Generates a troff-formatted man page and pipes it through man -l -
# (preferred) or nroff -man | ${PAGER:-less} (fallback).  If neither
# man nor nroff is available, falls back to plain-text help.
#
show_man_page() {
    local manpage
    manpage=$(cat <<'MANEOF'
.TH SOCWRAP 1 "2026-03-24" "5.0.0" "User Commands"
.SH NAME
socwrap \- socat-based interactive terminal wrapper with readline support
.SH SYNOPSIS
.B socwrap.sh
[\fIOPTIONS\fR] \-\- \fICOMMAND\fR [\fIARGS\fR...]
.br
.B socwrap.sh
[\fIOPTIONS\fR] \fB\-t\fR \fIHOST\fR \fIPORT\fR
.br
.B socwrap.sh
[\fIOPTIONS\fR] \fB\-u\fR \fIHOST\fR \fIPORT\fR
.br
.B socwrap.sh
[\fIOPTIONS\fR] \fB\-U\fR \fISOCKET_PATH\fR
.br
.B socwrap.sh
[\fIOPTIONS\fR] \fB\-s\fR \fIUSER@HOST\fR
.br
.B socwrap.sh
[\fIOPTIONS\fR] \fB\-T\fR \fIHOST\fR \fIPORT\fR
.br
.B socwrap.sh
[\fIOPTIONS\fR] \fB\-c\fR \fICHROOTDIR\fR [\fISHELL\fR]
.br
.B socwrap.sh
\fB\-\-profile\fR \fINAME\fR
.br
.B socwrap.sh
\fB\-\-detect\fR | \fB\-\-list\-filters\fR | \fB\-\-list\-profiles\fR
.br
.B socwrap.sh
\fB\-\-init\-config\fR | \fB\-\-validate\-config\fR
.SH DESCRIPTION
.B socwrap
wraps interactive sessions in a readline/history layer using bash's
.BR read\ \-e
builtin, with
.BR socat (1)
serving as a pure I/O bridge to the target process or network connection.
.PP
Unlike socat's built\-in READLINE address type (which suffers from a
first\-keypress prompt rendering bug), socwrap renders the prompt
immediately on each iteration. It supports line editing, arrow\-key
history navigation, and Ctrl\-R reverse search through GNU readline.
.SH "MODE FLAGS"
Mode flags are mutually exclusive.  Only one may be specified.
.TP
.BI \-t " HOST PORT"
TCP mode.  Connect to \fIHOST\fR on \fIPORT\fR.
.TP
.BI \-u " HOST PORT"
UDP mode.  Datagram connection to \fIHOST\fR:\fIPORT\fR.
.TP
.BI \-U " SOCKET"
Unix domain socket mode.  Connect to \fISOCKET\fR.
.TP
.BI \-s " USER@HOST"
SSH passthrough mode.  Wraps an SSH session with readline on the local side.
.TP
.BI \-T " HOST PORT"
Telnet mode.  TCP connection with automatic IAC sequence scrubbing.
.TP
.BI \-c " CHROOTDIR" " [SHELL]"
Chroot mode.  Run \fISHELL\fR (default: /bin/sh) inside \fICHROOTDIR\fR.
.TP
.B \-\- COMMAND [ARGS...]
EXEC mode (default).  Wrap a local command with readline.
.SH "COMMON OPTIONS"
.TP
.BI \-H ", \-\-history " FILE
History file path.  Default: ~/.socwrap_history.
Env: \fBSOCWRAP_HISTFILE\fR.
.TP
.BI \-p ", \-\-prompt " STR
Prompt string.  Default: "socwrap> ".
Env: \fBSOCWRAP_PROMPT\fR.
.TP
.BI \-l ", \-\-log " FILE
Append session output to \fIFILE\fR.
.TP
.BI \-\-log\-format " FMT"
Log format: \fBtext\fR (default), \fBtsv\fR, or \fBhtml\fR.
.TP
.B \-\-log\-timestamp
Prepend timestamps in text\-format logs.
.TP
.BI \-\-timeout " N"
Connection timeout in seconds (default: 10).
.TP
.B \-\-no\-pty
Disable PTY allocation for EXEC/SSH/chroot modes.
.TP
.BI \-\-ssh\-opts " OPTS"
Extra SSH options (e.g. "\-i ~/.ssh/id_rsa").
.TP
.B \-\-tls
Enable TLS for TCP connections (uses OPENSSL address).
.TP
.B \-\-no\-tls\-verify
Skip TLS certificate verification (for self\-signed certs).
.TP
.B \-\-no\-iac\-scrub
Disable automatic IAC scrubbing in telnet mode.
.TP
.BR \-C ", " \-\-crlf
Convert LF to CRLF on output (for HTTP/SMTP).
.SH "FILTER OPTIONS"
.TP
.BI \-\-post\-filter " CMD"
Add a post\-filter stage (remote output \(-> terminal).
Accumulates; order matters.  Use @name for built\-ins.
.TP
.BI \-\-pre\-filter " CMD"
Add a pre\-filter stage (typed input \(-> remote).
Accumulates; order matters.  Use @name for built\-ins.
.TP
.B \-\-list\-filters
Show available built\-in filters and exit.
.SH "CONFIG & PROFILES"
.TP
.BI \-\-profile " NAME"
Load named profile from the config file.
.TP
.B \-\-list\-profiles
List all configured profiles and exit.
.TP
.B \-\-init\-config
Create ~/.socwraprc with example profiles and exit.
.TP
.B \-\-validate\-config
Validate config syntax and structure, then exit.
.TP
.B \-\-no\-config
Skip config file loading entirely.
.TP
.BI \-\-rc " FILE"
Use alternate config file (default: ~/.socwraprc).
Env: \fBSOCWRAP_RC\fR.
.SH "DIAGNOSTIC OPTIONS"
.TP
.BR \-d ", " \-\-dry\-run
Show socat command and filter pipeline without executing.
.TP
.BR \-D ", " \-\-detect
Run capability detection and exit.
.TP
.BR \-v ", " \-\-verbose
Emit debug output on stderr.
.TP
.BR \-m ", " \-\-man
Display this man page.
.TP
.BR \-V ", " \-\-version
Print version and exit.
.TP
.BR \-h ", " \-\-help
Display help text and exit.
.SH "BUILT\-IN FILTERS"
.TS
l l l.
Filter	Direction	Description
_
@timestamp	post	Prepend HH:MM:SS to each line
@datestamp	post	Prepend YYYY\-MM\-DD HH:MM:SS
@ansi\-strip	post	Strip ANSI/VT100 escape sequences
@iac\-strip	post	Strip Telnet IAC bytes (needs perl)
@hex\-dump	post	Hex dump output (needs xxd)
@json\-pp	post	Pretty\-print JSON lines (needs jq)
@rot13	both	ROT\-13 encode/decode
@upper	both	Uppercase all characters
@lower	both	Lowercase all characters
@trim	post	Strip leading/trailing whitespace
@noblank	post	Suppress blank lines
@tee:FILE	post	Tee output into FILE
.TE
.SH "CONFIG FILE"
The config file (default: \fB~/.socwraprc\fR) is JSON with two top\-level keys:
.PP
.RS
\fBglobal\fR \- Default values for all sessions.
.br
\fBprofiles\fR \- Named profiles that override globals.
.RE
.PP
Precedence: CLI flags > profile values > global defaults > built\-in defaults.
.PP
When \fBjq\fR is not installed, a limited awk\-based parser is used
automatically.  A warning is emitted and complex JSON features (nested
objects, arrays with special characters) are not supported.
.SH "ENVIRONMENT"
.TP
.B SOCWRAP_HISTFILE
Override default history file path.
.TP
.B SOCWRAP_PROMPT
Override default prompt string.
.TP
.B SOCWRAP_SSH_OPTS
Extra SSH options (alternative to \-\-ssh\-opts).
.TP
.B SOCWRAP_RC
Override default config file path (~/.socwraprc).
.SH "EXIT STATUS"
.TP
.B 0
Success (or wrapped command exited 0).
.TP
.B 1
General error.
.TP
.B 2
Usage/argument error.
.TP
.B 130
Interrupted by Ctrl\-C (128 + SIGINT).
.SH EXAMPLES
.nf
# Wrap bash with readline
socwrap.sh \-\-no\-pty \-p "bash> " \-\- /bin/bash \-\-norc \-\-noprofile

# TCP with ANSI stripping and timestamps
socwrap.sh \-\-post\-filter @ansi\-strip \-\-post\-filter @timestamp \-t host 8080

# Telnet with clean output + HTML session log
socwrap.sh \-\-post\-filter @ansi\-strip \-l session.html \-\-log\-format html \-T router 23

# Use a named profile
socwrap.sh \-\-profile router

# Dry run to preview what would execute
socwrap.sh \-\-dry\-run \-\-post\-filter @ansi\-strip \-t host 80
.fi
.SH NOTES
socat readline support is NOT required.  socat is used only as an I/O
bridge; readline is provided by bash's
.B read \-e
builtin.
.PP
When wrapping interactive shells (bash, sh, zsh), use
.B \-\-no\-pty
to avoid double\-PTY issues, or pass PS1=\(aq\(aq via the environment.
.PP
Custom filters must handle their own line buffering.  Use
.B \-\-line\-buffered
with grep,
.B fflush()
in awk, or
.B $|=1
in perl.
.SH AUTHOR
That\-Guy / Positively Pedestrian Labs
.SH "SEE ALSO"
.BR socat (1),
.BR bash (1),
.BR readline (3),
.BR rlwrap (1)
MANEOF
)

    if _has_man; then
        printf '%s' "$manpage" | man -l - 2>/dev/null && return 0
    fi

    if _has_nroff; then
        printf '%s' "$manpage" | nroff -man 2>/dev/null | "${PAGER:-less}" && return 0
    fi

    # Final fallback: plain-text help
    warn "man/nroff not available — showing plain help"
    show_help
}

# =============================================================================
# SECTION: Argument Parsing
# =============================================================================

parse_args() {
    # Track whether a mode flag has been set (only one allowed)
    local mode_set=0

    _set_mode() {
        if [[ $mode_set -eq 1 ]]; then
            die "Only one mode flag may be specified (-t/-u/-U/-s/-T/-c)"
        fi
        OPT_MODE="$1"
        _CLI_MODE=1
        mode_set=1
    }

    # -------------------------------------------------------------------------
    # Pre-process: Extract mode flags and their arguments BEFORE getopt.
    # This handles -t HOST PORT, -u HOST PORT, -T HOST PORT correctly
    # because getopt can't handle multi-value options easily.
    # Also pre-process --post-filter, --pre-filter, and --profile (accumulating).
    # -------------------------------------------------------------------------
    local -a remaining_args=()
    local i=0
    local -a args=("$@")
    local argc=${#args[@]}

    while [[ $i -lt $argc ]]; do
        local arg="${args[$i]}"
        local next="${args[$((i+1))]:-}"
        local next2="${args[$((i+2))]:-}"

        case "$arg" in
            -t)
                _set_mode tcp
                _CLI_HOST=1; _CLI_PORT=1
                if [[ "$next" == *":"* ]]; then
                    OPT_HOST="${next%:*}"
                    OPT_PORT="${next#*:}"
                    i=$((i + 2))
                else
                    OPT_HOST="$next"
                    OPT_PORT="$next2"
                    i=$((i + 3))
                fi
                ;;
            -u)
                _set_mode udp
                _CLI_HOST=1; _CLI_PORT=1
                if [[ "$next" == *":"* ]]; then
                    OPT_HOST="${next%:*}"
                    OPT_PORT="${next#*:}"
                    i=$((i + 2))
                else
                    OPT_HOST="$next"
                    OPT_PORT="$next2"
                    i=$((i + 3))
                fi
                ;;
            -T)
                _set_mode telnet
                _CLI_HOST=1; _CLI_PORT=1
                if [[ "$next" == *":"* ]]; then
                    OPT_HOST="${next%:*}"
                    OPT_PORT="${next#*:}"
                    i=$((i + 2))
                else
                    OPT_HOST="$next"
                    OPT_PORT="$next2"
                    i=$((i + 3))
                fi
                ;;
            -U)
                _set_mode unix
                _CLI_UNIX_SOCK=1
                OPT_UNIX_SOCK="$next"
                i=$((i + 2))
                ;;
            -s)
                _set_mode ssh
                _CLI_SSH_TARGET=1
                OPT_SSH_TARGET="$next"
                i=$((i + 2))
                ;;
            -c)
                _set_mode chroot
                _CLI_CHROOT_DIR=1
                OPT_CHROOT_DIR="$next"
                i=$((i + 2))
                ;;
            --ssh-opts)
                OPT_SSH_OPTS="$next"
                _CLI_SSH_OPTS=1
                i=$((i + 2))
                ;;
            --post-filter)
                OPT_POST_FILTERS+=("$next")
                _CLI_POST_FILTERS=1
                i=$((i + 2))
                ;;
            --pre-filter)
                OPT_PRE_FILTERS+=("$next")
                _CLI_PRE_FILTERS=1
                i=$((i + 2))
                ;;
            --profile)
                OPT_PROFILE="$next"
                i=$((i + 2))
                ;;
            *)
                remaining_args+=("$arg")
                i=$((i + 1))
                ;;
        esac
    done

    # Build new args array without the pre-processed flags
    set -- "${remaining_args[@]}"

    # getopt long-option support check
    local getopt_rc=0
    getopt --test >/dev/null 2>&1 || getopt_rc=$?
    if [[ $getopt_rc -ne 4 ]]; then
        warn "util-linux getopt not found — long options may be unavailable"
    fi

    local short_opts="H:n:p:l:dDvVhmC"
    local long_opts="history:,histsize:,prompt:,log:,log-format:,log-timestamp,timeout:,ssh-opts:,\
tls,no-tls-verify,no-pty,no-iac-scrub,crlf,dry-run,detect,verbose,version,help,man,list-filters,\
profile:,list-profiles,init-config,validate-config,no-config,rc:,\
list-plugins,no-plugins,macros,macro-file:,list-macros,\
save-state:,load-state:,\
record:,record-input,replay:,replay-speed:"

    local parsed
    if ! parsed=$(getopt \
            --options      "$short_opts"  \
            --longoptions  "$long_opts"   \
            --name         "$SOCWRAP_NAME" \
            -- "$@" 2>&1); then
        err "Argument error: $parsed"
        show_help
        exit 2
    fi

    eval set -- "$parsed"

    while true; do
        case "$1" in
            -H|--history)
                OPT_HISTFILE="$2"; _CLI_HISTFILE=1; shift 2 ;;
            -n|--histsize)
                OPT_HISTSIZE="$2"; shift 2 ;;
            -p|--prompt)
                OPT_PROMPT="$2"; _CLI_PROMPT=1; shift 2 ;;
            -l|--log)
                OPT_LOG="$2"; _CLI_LOG=1; shift 2 ;;
            --log-format)
                case "$2" in
                    text|tsv|html) OPT_LOG_FORMAT="$2" ;;
                    *) die "--log-format must be one of: text, tsv, html" ;;
                esac
                _CLI_LOG_FORMAT=1; shift 2 ;;
            --log-timestamp)
                OPT_LOG_TIMESTAMP=1; _CLI_LOG_TIMESTAMP=1; shift ;;
            --timeout)
                [[ "$2" =~ ^[0-9]+$ ]] || die "--timeout requires a positive integer"
                OPT_TIMEOUT="$2"; _CLI_TIMEOUT=1; shift 2 ;;
            --ssh-opts)
                OPT_SSH_OPTS="$2"; _CLI_SSH_OPTS=1; shift 2 ;;
            --no-pty)
                OPT_NO_PTY=1; _CLI_NO_PTY=1; shift ;;
            --tls)
                OPT_TLS=1; _CLI_TLS=1; shift ;;
            --no-tls-verify)
                OPT_TLS_VERIFY=0; _CLI_TLS_VERIFY=1; shift ;;
            --no-iac-scrub)
                OPT_IAC_SCRUB=0; _CLI_IAC_SCRUB=1; shift ;;
            -C|--crlf)
                OPT_CRLF=1; _CLI_CRLF=1; shift ;;
            -d|--dry-run)
                OPT_DRY_RUN=1; shift ;;
            -D|--detect)
                OPT_DETECT_ONLY=1; shift ;;
            -v|--verbose)
                OPT_VERBOSE=1; shift ;;
            --list-filters)
                OPT_LIST_FILTERS=1; shift ;;
            -m|--man)
                OPT_MAN=1; shift ;;
            --profile)
                OPT_PROFILE="$2"; shift 2 ;;
            --list-profiles)
                OPT_LIST_PROFILES=1; shift ;;
            --init-config)
                OPT_INIT_CONFIG=1; shift ;;
            --validate-config)
                OPT_VALIDATE_CONFIG=1; shift ;;
            --no-config)
                OPT_NO_CONFIG=1; shift ;;
            --rc)
                OPT_RC="$2"; shift 2 ;;
            --list-plugins)
                OPT_LIST_PLUGINS=1; shift ;;
            --no-plugins)
                OPT_NO_PLUGINS=1; shift ;;
            --macros)
                OPT_MACROS=1; shift ;;
            --macro-file)
                OPT_MACRO_FILE="$2"; OPT_MACROS=1; shift 2 ;;
            --list-macros)
                OPT_LIST_MACROS=1; OPT_MACROS=1; shift ;;
            --save-state)
                OPT_SAVE_STATE="$2"; shift 2 ;;
            --load-state)
                OPT_LOAD_STATE="$2"; shift 2 ;;
            --record)
                OPT_RECORD="$2"; shift 2 ;;
            --record-input)
                OPT_RECORD_INPUT=1; shift ;;
            --replay)
                OPT_REPLAY="$2"; shift 2 ;;
            --replay-speed)
                OPT_REPLAY_SPEED="$2"; shift 2 ;;
            -V|--version)
                printf '%s %s\n' "$SOCWRAP_NAME" "$SOCWRAP_VERSION"
                exit 0 ;;
            -h|--help)
                show_help; exit 0 ;;
            --)
                shift; break ;;
            *)
                die "Unexpected option: $1" ;;
        esac
    done

    # Remaining args: command for EXEC mode, or shell+args for chroot
    WRAP_TARGET=("$@")

    # If --tls was given with a non-TCP mode flag, that's an error now.
    # The full TLS+mode check happens in main() after config loading.
    if [[ "$OPT_TLS" -eq 1 && $_CLI_MODE -eq 1 && "$OPT_MODE" != "tcp" && "$OPT_MODE" != "telnet" ]]; then
        die "--tls requires -t HOST PORT (incompatible with -${OPT_MODE:0:1})"
    fi

    # SSH opts from environment (if not set by --ssh-opts)
    [[ -n "$OPT_SSH_OPTS" ]] || OPT_SSH_OPTS="${SOCWRAP_SSH_OPTS:-}"
}

# =============================================================================
# SECTION: Main
# =============================================================================

main() {
    parse_args "$@"

    # --- Resolve config file path (used by several exit-early modes) ---
    _RESOLVED_CONFIG=$(_resolve_config_path)

    # --- Exit-early modes that do not need config ---
    if [[ "$OPT_DETECT_ONLY" -eq 1 ]]; then
        detect_env
        exit 0
    fi
    if [[ "$OPT_MAN" -eq 1 ]]; then
        show_man_page
        exit 0
    fi

    # --- Replay mode (Phase 7) — standalone, no session needed ---
    if [[ -n "$OPT_REPLAY" ]]; then
        replay_cast "$OPT_REPLAY" "$OPT_REPLAY_SPEED"
        exit 0
    fi

    # --- Initialize config parser (jq preferred, awk fallback) ---
    _init_config_parser

    # --- Load session state (Phase 6a) ---
    # State is loaded early so config/profile can layer on top,
    # but CLI flags still win (checked via _CLI_* markers).
    if [[ -n "$OPT_LOAD_STATE" ]]; then
        load_session_state "$OPT_LOAD_STATE"
    fi

    # --- Config management commands ---
    if [[ "$OPT_INIT_CONFIG" -eq 1 ]]; then
        init_config
        # init_config calls exit internally
    fi
    if [[ "$OPT_VALIDATE_CONFIG" -eq 1 ]]; then
        validate_config
        # validate_config calls exit internally
    fi
    if [[ "$OPT_LIST_PROFILES" -eq 1 ]]; then
        list_profiles
        # list_profiles calls exit internally
    fi

    # --- Load config file and profile ---
    if [[ "$OPT_NO_CONFIG" -eq 0 ]]; then
        if _config_file_exists; then
            load_global_config
            if [[ -n "$OPT_PROFILE" ]]; then
                load_profile "$OPT_PROFILE"
            fi
        elif [[ -n "$OPT_PROFILE" ]]; then
            die "No config file found at $_RESOLVED_CONFIG — cannot load profile '$OPT_PROFILE'"
        fi
        # No config file + no --profile → proceed with built-in defaults (Phase 3 compat)
    else
        # --no-config is set
        if [[ -n "$OPT_PROFILE" ]]; then
            die "--profile requires a config file (--no-config is set)"
        fi
    fi

    # --- Load plugins (Phase 6) ---
    load_plugins

    if [[ "$OPT_LIST_PLUGINS" -eq 1 ]]; then
        list_plugins
        # list_plugins calls exit internally
    fi
    if [[ "$OPT_LIST_FILTERS" -eq 1 ]]; then
        list_filters
        exit 0
    fi

    # --- Macro loading (Phase 6) ---
    # Auto-activate macros if profile has a macros block
    if [[ -n "$OPT_PROFILE" && "$OPT_MACROS" -eq 0 ]] && _has_jq && _config_file_exists; then
        local pkey=".profiles[\"${OPT_PROFILE}\"].macros"
        if _config_has "$pkey"; then
            OPT_MACROS=1
            debug "Macros auto-activated (profile '${OPT_PROFILE}' has macros block)"
        fi
    fi

    # Load macros from config and/or external file
    load_macros_from_config
    if [[ -n "$OPT_MACRO_FILE" ]]; then
        load_macros_from_file "$OPT_MACRO_FILE"
    fi

    if [[ "$OPT_LIST_MACROS" -eq 1 ]]; then
        list_macros
        # list_macros calls exit internally
    fi

    # --- TLS sanity check (after config may have set mode) ---
    if [[ "$OPT_TLS" -eq 1 && "$OPT_MODE" == "exec" ]]; then
        die "--tls requires a TCP mode (-t HOST PORT)"
    fi

    # --- Verbose banner ---
    if [[ "$OPT_VERBOSE" -eq 1 ]]; then
        print_banner
    fi

    # --- Preflight ---
    preflight

    # --- Build command ---
    build_socat_cmd

    # --- Dry run ---
    if [[ "$OPT_DRY_RUN" -eq 1 ]]; then
        run_dry
        exit 0
    fi

    # --- Execute ---
    run_socat
    local socat_rc=$?

    # --- Save session state (Phase 6a) ---
    if [[ -n "$OPT_SAVE_STATE" ]]; then
        save_session_state "$OPT_SAVE_STATE"
    fi

    return $socat_rc
}

main "$@"

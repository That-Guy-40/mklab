#!/usr/bin/env bash
# lab-fc.sh — Phase 7: Firecracker microVMs.
#
# The tool that removes the typing slices 1–3 did by hand. It is a config generator and a
# process babysitter, and the most useful thing it does is TELL YOU WHAT IT DID: every field
# of the generated config.json carries a provenance tag, so "the tool started doing this for
# you silently" cannot happen quietly. See `create --dry-run`.
#
# ── USAGE ──
#   lab-fc.sh preflight --config <f.toml> | <spec flags>
#   lab-fc.sh create    ... [--dry-run]      # --dry-run prints config + PROVENANCE, writes nothing
#   lab-fc.sh start     <name> [--force] [--jailer]
#                                            # --force:  start despite a changed/missing kernel
#                                            # --jailer: §5.6's isolation tier — chroot + a
#                                            #   uid/gid switch + seccomp, around the VMM.
#                                            #   Needs CAP_SYS_ADMIN (jailer unshares a mount
#                                            #   namespace) and stages the kernel and rootfs
#                                            #   INSIDE the jail, because every path in
#                                            #   config.json is then relative to the chroot.
#   lab-fc.sh stop      <name> [--force]     # --force: escalate to SIGKILL if SIGTERM is ignored
#   lab-fc.sh destroy   <name> [--force]     # --force: kill it first if it is running
#   lab-fc.sh snapshot  {create|list|restore|delete} <name> [snap]
#                                            # memory + devices + the disk, from one pause.
#                                            # create needs it RUNNING; restore needs it STOPPED.
#   lab-fc.sh clone     <src> <snap> <new>   # a NEW machine from an existing snapshot: its
#                                            # own copy of the disk, the snapshot's memory
#                                            # image SHARED (mapped MAP_PRIVATE, so N clones
#                                            # read one file). `restore` puts a snapshot back
#                                            # into its own instance; `clone` makes another
#                                            # machine out of it. It comes up believing it is
#                                            # <src> and says so — see RUNBOOK-fleet.md.
#   lab-fc.sh list      [--json]
#   lab-fc.sh inspect   <name>
#   lab-fc.sh mac       <name>               # the guest MAC this tool would set — read-only,
#                                            # no tap, no root. Must equal `fabric.sh mac <name>`;
#                                            # tests/test-fabric-mac-derivation.sh asserts it.
#
#   spec flags (one per [[microvm]] key — tests/test-cli-vs-config-parity.sh proves the
#   two entry points stay in step, and that every flag reaches the record):
#     --name --kernel --rootfs --memory --vcpus --tap --mac --ip --gateway --netmask
#     --append --lab --mmds
# ── END USAGE ──
#
# ── WHAT THIS TOOL DELIBERATELY DOES NOT DO ─────────────────────────────────
#
# It does NOT create or delete taps. §5.1 originally said `destroy` = "stop + delete tap +
# delete state dir", but slice 3 gave tap lifecycle to the fabric (`fabric.sh tap/retap`),
# and TWO owners for one resource is precisely the stale-record bug this plan keeps finding:
# whichever one deletes it first leaves the other's record describing something gone. So the
# tap is an INPUT here — validated, never manufactured.
#
# It has no verb justified by "the other engines will need this too" (§8.3 tripwire). There
# is no `explain` verb either: provenance belongs to the thing that generates the config, so
# it is a flag on `create`, not a new noun.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
    readonly LAB_STATE_DIR="${LAB_STATE_DIR:-/var/lib/lab-create}"
else
    readonly LAB_STATE_DIR="${LAB_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/lab-create}"
fi
readonly LAB_FC_STATE_DIR="${LAB_STATE_DIR}/fc"
readonly FC_PINNED_VERSION="${FC_PINNED_VERSION:-v1.16.1}"

# Defaults, each one a thing the tool supplies that you did not type. Every entry here is a
# line in the provenance table, by construction — a default that is not reported is exactly
# the drift this slice exists to expose.
readonly DEF_MEMORY_MIB=256
readonly DEF_VCPUS=1

die()  { printf 'lab-fc.sh: %s\n' "$*" >&2; exit 1; }
note() { printf '  - %s\n' "$*" >&2; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# ── the instance name is a PATH COMPONENT, so it is gated at the accessor ────
# REVIEW-phase7.md P7-3: `preflight_checks` has always regex-gated the name, but only
# `preflight` and `create` run it. `start`/`stop`/`destroy`/`inspect` took the name as a
# bare positional and pasted it into a path, so `destroy ../../<anything>` reached
# `rm -rf` on a directory outside the state dir and printed `PASS: destroyed`.
#
# The guard lives in `fc_dir` — the ONE chokepoint every path helper goes through — rather
# than being restated in each verb, for the reason Phase 1's P1-1 fix records: a call site
# added later is then safe by DEFAULT, whereas a per-verb guard reopens the hole the first
# time someone forgets one.
readonly FC_NAME_RE='^[a-z][a-z0-9-]{0,30}$'
valid_name() { [[ "$1" =~ $FC_NAME_RE ]]; }

fc_dir() {
    valid_name "$1" \
        || die "invalid instance name '$1' — must match ${FC_NAME_RE} (it is used as a directory name under $LAB_FC_STATE_DIR, so a path is not a name)"
    printf '%s/%s' "$LAB_FC_STATE_DIR" "$1"
}
fc_config()   { printf '%s/config.json'   "$(fc_dir "$1")"; }
fc_manifest() { printf '%s/manifest.toml' "$(fc_dir "$1")"; }
fc_pidfile()  { printf '%s/fc.pid'        "$(fc_dir "$1")"; }
fc_log()      { printf '%s/fc.log'        "$(fc_dir "$1")"; }
fc_rootfs()   { printf '%s/rootfs.ext4'   "$(fc_dir "$1")"; }
fc_snapdir()  { printf '%s/snapshots'     "$(fc_dir "$1")"; }

# ── the jailer tier (§5.6) ──────────────────────────────────────────────────
# `jailer` builds <chroot-base>/firecracker/<id>/root/, chroots into it and execs firecracker
# there. So the jail root is a path THIS tool has to know, because everything the VM opens has
# to be inside it and every path in config.json has to be spelled relative to it.
fc_jailbase() { printf '%s/jail' "$(fc_dir "$1")"; }
fc_jailroot() { printf '%s/firecracker/%s/root' "$(fc_jailbase "$1")" "$1"; }

# CAP_SYS_ADMIN, DERIVED — not `[[ $EUID -eq 0 ]]`.
# What jailer actually needs is unshare(CLONE_NEWNS), which is CAP_SYS_ADMIN. uid 0 usually
# carries it and a uid-0 check would be right most of the time, which is exactly the problem:
# it is a mechanism standing in for the capability, so it says "no" to a non-root process that
# has the capability and "yes" to a root process in a userns that does not. Bit 21 of CapEff
# is the fact itself.
have_cap_sys_admin() {
    local eff
    eff="$(sed -n 's/^CapEff:[[:space:]]*//p' /proc/self/status 2>/dev/null)" || return 1
    [[ -n "$eff" ]] || return 1
    # 16^n arithmetic without bc: bash handles 64-bit hex natively.
    (( ( 0x$eff >> 21 ) & 1 ))
}

# WHERE THE API SOCKET PATH IS RECORDED, AND WHY IT IS NOT IN manifest.toml.
# The manifest is the CREATE-time record — what this instance is. The socket is RUN-time
# state, chosen at `start`, exactly like the pidfile: rewriting a provenance file on every
# start is how a record starts describing two different things at once.
fc_sockfile() { printf '%s/api-sock.path' "$(fc_dir "$1")"; }

# THE 108-BYTE CAP IS NOT A DETAIL. `sockaddr_un.sun_path` is 108 bytes INCLUDING the NUL,
# and this stack has been bitten by it before: an agent scratch dir under $TMPDIR pushed
# Firecracker's `uds_path` and QEMU's `-qmp` path over the limit, and the error read like a
# vsock problem rather than a path-length one. So the primary location is inside the
# instance dir (where `destroy` already reaps it), and when THAT would not fit we fall back
# to a SHORT path derived from the instance dir — derived, so there is still exactly one
# owner and it is recomputable, not a random name nobody can find again.
_api_sock_for() {  # _api_sock_for <name> -> the path start would use
    local name="$1" primary h
    primary="$(fc_dir "$name")/api.sock"
    (( ${#primary} <= 100 )) && { printf '%s' "$primary"; return; }
    h="$(printf '%s' "$(fc_dir "$name")" | sha256sum)"
    printf '%s/lab-fc-%s.sock' "${TMPDIR:-/tmp}" "${h:0:12}"
}

api_sock_of() {  # api_sock_of <name> -> the socket THIS RUNNING instance was started with
    local f; f="$(fc_sockfile "$1")"
    [[ -r "$f" ]] || return 1
    local sp; sp="$(cat "$f" 2>/dev/null || true)"
    [[ -n "$sp" ]] || return 1
    printf '%s' "$sp"
}

# ── the Firecracker API, over its unix socket ───────────────────────────────
# The status code is the gate, and it is read from curl's own -w rather than from the body:
# Firecracker answers a REFUSED request with 400 and a JSON explanation, so "curl exited 0"
# means the HTTP conversation happened, not that the VMM agreed to anything.
_api() {  # _api <sock> <METHOD> <path> [json-body]  -> body on stdout; non-zero on any non-2xx
    local sock="$1" method="$2" path="$3" body="${4:-}" out code
    # Named `curl_args` rather than `args` on purpose: gen_config has a local STRING called
    # `args` (the guest kernel cmdline), and shellcheck reasons about the name across the
    # file, so reusing it here made it warn about the boot_args expansion 50 lines away.
    # BOUNDED, because an unresponsive VMM must not wedge the CLI. A Firecracker that has
    # accepted the connection and then stopped answering — wedged, paused mid-snapshot, or
    # simply not the thing you think is listening — would otherwise leave `curl` waiting
    # forever, and a tool that hangs is worse than one that fails: nothing prints, nothing
    # times out, and the operator has no verdict at all. Found by a stand-in VMM that binds
    # the socket without implementing the API, which is exactly that case.
    local -a curl_args=(--unix-socket "$sock" -sS -X "$method" "http://localhost${path}"
                        --connect-timeout 5 --max-time "${LAB_FC_API_TIMEOUT:-20}"
                        -H 'Accept: application/json' -w '\n%{http_code}')
    [[ -n "$body" ]] && curl_args+=(-H 'Content-Type: application/json' -d "$body")
    out="$(curl "${curl_args[@]}" 2>&1)" || { printf '%s' "$out"; return 1; }
    code="${out##*$'\n'}"
    printf '%s' "${out%$'\n'*}"
    [[ "$code" == 2* ]]
}

# ── provenance ──────────────────────────────────────────────────────────────
# Tags, worst-to-best for the reader's attention:
#   YOURS      you typed it
#   DEFAULT    the tool supplied it because you did not
#   DERIVED    the tool computed it from something you did type
#   APPENDED   Firecracker adds it AFTER ours and the kernel honours the last one
#   REFUSED    you asked for something the tool will not do, and why
#
# The three columns are joined on US (0x1f), NOT on '|'. REVIEW-phase7.md §3: with '|' as
# the separator, `append = "mc_name=a|b"` — an ordinary boot arg — split as
# field="boot_args: mc_name=a" / why="b|your append…", so the table whose entire job is to
# report what the tool did to your value misreported that value. US cannot appear here
# because `record_value_ok` refuses control characters in a config value, which is what
# makes this separator a guarantee rather than a hope.
readonly PROV_SEP=$'\x1f'
PROV=()
prov() { PROV+=("$1${PROV_SEP}$2${PROV_SEP}$3"); }   # tag | field | explanation

prov_table() {
    printf '\n  %-9s %-28s %s\n' "WHERE FROM" "FIELD = VALUE" "WHY"
    printf '  %-9s %-28s %s\n' "---------" "----------------------------" "---"
    local e tag field why
    for e in "${PROV[@]}"; do
        IFS="$PROV_SEP" read -r tag field why <<<"$e"
        printf '  %-9s %-28s %s\n' "$tag" "$field" "$why"
    done
    printf '\n'
}

# ── a very small TOML reader: [[microvm]] blocks, key = value ───────────────
# Deliberately not a general TOML parser. It reads the subset slices 1-3 proved necessary,
# and refuses anything it does not understand rather than ignoring it -- a config key that
# is silently dropped is a field that "appears to work and does nothing".
readonly KNOWN_KEYS="name kernel rootfs memory vcpus tap mac ip gateway netmask mmds append lab"

# A record is `k=v;k=v;…`, split back apart on ';'. So a ';' INSIDE a value is not a
# quoting nuisance, it is a second key — REVIEW-phase7.md P7-6, measured:
#
#     append = "quiet;mmds=true"      -> MMDS switched on, which the operator never wrote
#     append = "quiet;name=HIJACKED"  -> the instance name changed
#
# ...and the `known` gate above never sees those keys, because they are not keys in the
# FILE. A parser whose stated purpose is "refuse what you do not understand rather than
# ignoring it" could be handed keys it never looked at, through any value.
#
# Control characters are refused for the same reason one level up: US (0x1f) is the
# provenance table's column separator, and NUL/newline would corrupt the line-oriented
# record stream. Refusing at the parser — by name, like the unknown-key refusal beside it
# — keeps both guarantees true by construction instead of by hope.
record_value_ok() {  # record_value_ok <key> <value>  -> 0, or die naming the key
    case "$2" in
        *';'*) die "[[microvm]] $1: value contains ';', which is the record separator — it would be read as a second key (see REVIEW-phase7.md P7-6): $2" ;;
    esac
    [[ "$2" == *[$'\x01'-$'\x1f'$'\x7f']* ]] \
        && die "[[microvm]] $1: value contains a control character, which cannot survive the record or the provenance table"
    return 0
}

toml_microvms() {  # toml_microvms <file> -> one line per microvm: k=v;k=v;...
    local f="$1"
    [[ -r "$f" ]] || die "cannot read $f"
    awk -v known=" $KNOWN_KEYS " '
        function flush() { if (n) { print rec; rec=""; n=0 } }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*\[\[microvm\]\]/ { flush(); n=1; next }
        /^[[:space:]]*\[/ { flush(); next }
        n && /=/ {
            key=$0; sub(/[[:space:]]*=.*/,"",key); gsub(/^[[:space:]]+|[[:space:]]+$/,"",key)
            val=$0; sub(/^[^=]*=[[:space:]]*/,"",val)
            # An INLINE COMMENT is legal TOML and used to land inside the value:
            # `name = "t1"   # the api node` was read as the name `t1"   # the api node`,
            # and the tool then complained about the NAME. A quoted value keeps its own
            # `#`; a bare one ends at the first `#`.
            if (substr(val,1,1) == "\"") {
                q = index(substr(val,2), "\"")
                if (q > 0) val = substr(val, 2, q-1)
                else       val = substr(val, 2)
            } else {
                sub(/[[:space:]]*#.*/, "", val)
                gsub(/[[:space:]]+$/, "", val)
            }
            if (index(known, " " key " ") == 0) {
                printf("lab-fc.sh: unknown [[microvm]] key %s in %s\n", key, FILENAME) > "/dev/stderr"
                exit 3
            }
            # The record separator cannot be smuggled through a value. awk refuses here
            # rather than at the shell, so the refusal happens before the record exists.
            if (index(val, ";") > 0) {
                printf("lab-fc.sh: [[microvm]] %s in %s: value contains \";\", which is the record separator — it would be read as a second key (REVIEW-phase7.md P7-6): %s\n", key, FILENAME, val) > "/dev/stderr"
                exit 3
            }
            if (val ~ /[\001-\037\177]/) {
                printf("lab-fc.sh: [[microvm]] %s in %s: value contains a control character\n", key, FILENAME) > "/dev/stderr"
                exit 3
            }
            rec = rec key "=" val ";"
        }
        END { flush() }
    ' "$f"
}

field() {  # field <record> <key> [default]
    local rec="$1" key="$2" def="${3:-}" v
    v="$(printf '%s' "$rec" | tr ';' '\n' | sed -n "s/^${key}=//p" | head -1)"
    printf '%s' "${v:-$def}"
}

# ── mem_to_mib: a config value must never reach $(( )) ──────────────────────
# REVIEW-phase7.md P7-1. This used to be `printf '%s' $(( ${m%[Gg]} * 1024 ))`, and bash
# arithmetic evaluates ARRAY SUBSCRIPTS with full expansion — so a value shaped like
# `BASH_VERSINFO[$(…)]G` ran the command substitution. Measured: the command ran and the
# gate printed `ok  memory 5120 MiB`, during `preflight` — the one verb whose entire
# promise is that nothing has happened yet.
#
# `set -u` was not the guard it looked like: it stops the `a[$(…)]` form (unset name) but
# not `EUID[$(…)]` or `BASH_VERSINFO[$(…)]`, which name variables that exist.
#
# So the shape is checked FIRST and the arithmetic only ever sees digits. Anything else is
# returned unchanged, so the `memory must be an integer >= 64` gate below reports it — a
# refusal by the gate that exists, rather than a second, silent one here.
mem_to_mib() {  # accepts 256, 256M, 1G  (Phase-2 spelling)
    local m="$1" n
    case "$m" in
        *G|*g) n="${m%[Gg]}"; [[ "$n" =~ ^[0-9]+$ ]] || { printf '%s' "$m"; return 0; }
               printf '%s' $(( 10#$n * 1024 )) ;;   # 10# so `08G` is 8, not an octal error
        *M|*m) printf '%s' "${m%[Mm]}" ;;
        *)     printf '%s' "$m" ;;
    esac
}

# ── json_str: the config is JSON, so it is emitted as JSON ──────────────────
# REVIEW-phase7.md P7-2. Every scalar used to be interpolated raw into config.json, so a
# value could close its string and add siblings. Measured, and valid JSON at the end of it:
# an `append =` value injected a top-level `"vsock": {"guest_cid": 3, "uds_path": …}` — a
# host socket the guest can reach — and the provenance table reported nothing, because as
# far as the table is concerned that text is just your boot arg.
#
# Phases 3, 4 and 5 all grew this escaping (P3 export hardening, P4-5, P5-2). Phase 7 was
# the fourth emitter and the only one still raw. Pure bash on purpose: this driver's only
# hard dependencies are awk/sed/file, and a config generator that needs jq to be safe is
# not safe on a host without jq.
json_str() {  # json_str <value> -> a quoted, escaped JSON string
    local s="$1"
    s="${s//\\/\\\\}"          # backslash FIRST, or it re-escapes the escapes below
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
    # Any C0 control left over has no short escape; \u00XX it rather than emitting a raw
    # byte that makes the file un-parseable. (record_value_ok already refuses these on the
    # config path — this is the belt to that suspenders, for values built by `main`.)
    local c out=""
    if [[ "$s" == *[$'\x01'-$'\x1f'$'\x7f']* ]]; then
        while IFS= read -r -d '' -n1 c; do
            if [[ "$c" == [$'\x01'-$'\x1f'$'\x7f'] ]]; then
                printf -v c '\\u%04x' "'$c"
            fi
            out+="$c"
        done < <(printf '%s' "$s")
        s="$out"
    fi
    printf '"%s"' "$s"
}

# ═══════════════════════════════════════════════════════════════════════════
# PREFLIGHT — and `create` calls THIS function, not a copy of it.
#
# §5.9's rule: preflight must be the same function create runs first, never a second
# implementation that predicts what create will do. Two implementations drift, and the one
# that drifts is always the one that says "fine".
#
# Returns 0 if every gate passes. Prints one line per gate: ok / FAIL / UNKNOWN.
# UNKNOWN is a verdict distinct from ok -- an unverifiable gate must never render as a pass.
# ═══════════════════════════════════════════════════════════════════════════
PF_FAIL=0
PF_UNKNOWN=0
pf_ok()      { printf '  ok       %s\n' "$*"; }
pf_fail()    { printf '  FAIL     %s\n' "$*"; PF_FAIL=$((PF_FAIL+1)); }
pf_unknown() { printf '  UNKNOWN  %s\n' "$*"; PF_UNKNOWN=$((PF_UNKNOWN+1)); }

preflight_checks() {  # preflight_checks <record>
    local rec="$1"
    local name kernel rootfs tap ip mem vcpus append
    name="$(field "$rec" name)"
    kernel="$(field "$rec" kernel)"
    rootfs="$(field "$rec" rootfs)"
    tap="$(field "$rec" tap)"
    ip="$(field "$rec" ip)"
    append="$(field "$rec" append)"
    mem="$(mem_to_mib "$(field "$rec" memory "$DEF_MEMORY_MIB")")"
    vcpus="$(field "$rec" vcpus "$DEF_VCPUS")"

    # -- identity ---------------------------------------------------------
    # ONE regex, shared with the `fc_dir` accessor guard — a second copy here is a second
    # thing to forget to update, and the name is a path component (P7-3).
    valid_name "$name" \
        && pf_ok "name '$name' is a usable instance name" \
        || pf_fail "name '$name' must be lowercase alnum/dash starting with a letter (it becomes a directory name)"

    # -- the host can run a microVM at all --------------------------------
    if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        pf_ok "/dev/kvm present and read-write for uid $EUID"
    else
        pf_fail "/dev/kvm is missing or not read-write for uid $EUID (add yourself to the kvm group)"
    fi

    local fcbin; fcbin="$(command -v firecracker || true)"
    if [[ -n "$fcbin" ]]; then
        local v; v="$("$fcbin" --version 2>&1 | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || true)"
        if [[ "$v" == "$FC_PINNED_VERSION" ]]; then
            pf_ok "firecracker $v at $fcbin (pinned)"
        else
            pf_fail "firecracker is ${v:-unknown}, pinned is $FC_PINNED_VERSION"
        fi
    else
        pf_fail "firecracker not on PATH"
    fi

    # -- the kernel must be an ELF, not a bzImage -------------------------
    # §5.4 hole 2, confirmed in slice 1: Firecracker's loader is ELF-only and answers a
    # vmlinuz with Elf(InvalidElfMagicNumber). A generator test that only checks the path
    # string validates a document about an imaginary machine.
    if [[ -r "$kernel" ]]; then
        local kind; kind="$(file -b "$kernel" 2>/dev/null || true)"
        if [[ "$kind" == *ELF* ]]; then
            pf_ok "kernel is ELF: ${kind:0:44}"
        elif [[ "$kind" == *bzImage* ]]; then
            pf_fail "kernel is a bzImage, Firecracker needs the uncompressed ELF — run extract-vmlinux on it (vmlinuz -> vmlinux)"
        else
            pf_fail "kernel is neither ELF nor bzImage: ${kind:0:44}"
        fi
    else
        pf_fail "kernel not readable: ${kernel:-<unset>}"
    fi

    # -- the rootfs must exist, be a filesystem, and carry an init --------
    if [[ -r "$rootfs" ]]; then
        local rkind; rkind="$(file -b "$rootfs" 2>/dev/null || true)"
        if [[ "$rkind" == *filesystem* ]]; then
            pf_ok "rootfs is a filesystem image: ${rkind:0:44}"
        else
            pf_fail "rootfs does not look like a filesystem: ${rkind:0:44}"
        fi
        # /sbin/init: readable without mounting IF debugfs is installed. If it is not, this
        # is UNKNOWN -- not ok. A gate that cannot run must not report a pass.
        if command -v debugfs >/dev/null 2>&1; then
            # THREE outcomes, not two. The first version of this gate had only two and
            # reported "rootfs has no /sbin/init" about an image that booted fine minutes
            # earlier -- because debugfs had failed to OPEN the filesystem and the check
            # read the absence of output as absence of the file. "I could not look" is not
            # "I looked and it is missing"; conflating them invents a specific defect.
            local dbg; dbg="$(debugfs -R "stat /sbin/init" "$rootfs" 2>&1 || true)"
            if [[ "$dbg" == *"Filesystem not open"* || "$dbg" == *"while reading"* \
                  || "$dbg" == *"couldn't find valid filesystem"* ]]; then
                # Usually a dirty image: booted rw and never cleanly unmounted, so the
                # bitmap checksums are stale. Worth saying, because it is also the reason
                # a re-used rootfs can behave differently from a fresh one.
                pf_unknown "cannot read $rootfs with debugfs (image is dirty or unsupported) — /sbin/init NOT verified: ${dbg##*: }"
            elif [[ "$dbg" == *Inode:* ]]; then
                pf_ok "rootfs has /sbin/init"
            else
                pf_fail "rootfs has no /sbin/init — the kernel will panic with 'No init found'"
            fi
        else
            pf_unknown "cannot check /sbin/init: debugfs not installed (install e2fsprogs)"
        fi
    else
        pf_fail "rootfs not readable: ${rootfs:-<unset>}"
    fi

    # -- boot args we refuse to let you set -------------------------------
    # §5.2's first derived constraint (E.4): Firecracker appends its own root=/dev/vda and
    # the kernel honours the LAST one, so a user root= is silently ignored. Refusing loudly
    # beats offering a knob that does nothing.
    if [[ "$append" == *root=* ]]; then
        pf_fail "append contains root= — Firecracker appends its own root=/dev/vda AFTER ours and the kernel honours the last one, so yours would be silently ignored (see plan E.4)"
    fi

    # -- ip= if and only if a NIC ----------------------------------------
    # §5.4 hole 4 / plan F.4: a stray ip= with no NIC cost 0.55s -> 12.84s, spent in the
    # kernel's IP autoconfiguration waiting for a device that never appears, with NO
    # IP-Config line and no error anywhere in dmesg. Silent, 23x, and reproduced twice.
    if [[ -n "$ip" && -z "$tap" ]]; then
        pf_fail "ip=$ip is set but no tap is configured — this costs ~23x boot time in kernel IP autoconfig and reports nothing (plan F.4)"
    elif [[ -n "$ip" && -n "$tap" ]]; then
        pf_ok "ip= paired with a NIC"
    elif [[ -z "$ip" && -n "$tap" ]]; then
        pf_ok "NIC with no static ip= (DHCP or unconfigured)"
    else
        pf_ok "no NIC and no ip= — consistent"
    fi

    # -- the tap is an INPUT: validated, never manufactured ---------------
    if [[ -n "$tap" ]]; then
        if ip link show "$tap" >/dev/null 2>&1; then
            pf_ok "tap $tap exists"
            local own; own="$(cat "/sys/class/net/$tap/owner" 2>/dev/null || true)"
            if [[ "$own" == "$EUID" ]]; then
                pf_ok "tap $tap is owned by uid $EUID — openable unprivileged"
            else
                # Slice 3 found this the hard way: `ip tuntap add` exiting 0 says nothing
                # about the TUNSETIFF the VMM will issue.
                pf_fail "tap $tap is owned by uid ${own:-<unset>}, not $EUID — Firecracker would get EPERM from TUNSETIFF"
            fi
            local addrs; addrs="$(ip -4 -o addr show "$tap" 2>/dev/null)"
            if [[ "$addrs" == *inet* ]]; then
                pf_fail "tap $tap carries an IPv4 address — that makes it a CNI autodetection candidate (plan F.7.1 rule 2)"
            else
                pf_ok "tap $tap carries no IPv4 (correct: the bridge holds the address)"
            fi
        else
            pf_fail "tap $tap does not exist — create it with the fabric (fabric.sh tap ${name}); lab-fc.sh never manufactures taps"
        fi
    fi

    # -- resources --------------------------------------------------------
    [[ "$mem" =~ ^[0-9]+$ && "$mem" -ge 64 ]] \
        && pf_ok "memory ${mem} MiB" || pf_fail "memory '${mem}' must be an integer >= 64 MiB"
    [[ "$vcpus" =~ ^[0-9]+$ && "$vcpus" -ge 1 ]] \
        && pf_ok "vcpus $vcpus" || pf_fail "vcpus '$vcpus' must be a positive integer"

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# CONFIG GENERATION — and the provenance of every field
# ═══════════════════════════════════════════════════════════════════════════
gen_config() {  # gen_config <record> <outfile|-> ; fills PROV[]
    local rec="$1" out="$2"
    local name kernel rootfs tap mac ip gw mask mem vcpus mmds append
    name="$(field "$rec" name)"
    kernel="$(field "$rec" kernel)"
    rootfs="$(field "$rec" rootfs)"
    tap="$(field "$rec" tap)"
    mac="$(field "$rec" mac)"
    ip="$(field "$rec" ip)"
    gw="$(field "$rec" gateway)"
    mask="$(field "$rec" netmask "255.255.255.0")"
    mmds="$(field "$rec" mmds)"
    append="$(field "$rec" append)"
    mem="$(mem_to_mib "$(field "$rec" memory "$DEF_MEMORY_MIB")")"
    vcpus="$(field "$rec" vcpus "$DEF_VCPUS")"

    PROV=()
    prov YOURS   "kernel"  "$kernel"
    prov YOURS   "rootfs"  "$rootfs"

    [[ -n "$(field "$rec" memory)" ]] \
        && prov YOURS "mem_size_mib = $mem" "as given" \
        || prov DEFAULT "mem_size_mib = $mem" "you did not say; Firecracker's own default is 128"
    [[ -n "$(field "$rec" vcpus)" ]] \
        && prov YOURS "vcpu_count = $vcpus" "as given" \
        || prov DEFAULT "vcpu_count = $vcpus" "you did not say"
    prov DEFAULT "smt = false" "hyperthread siblings off; the microVM gets whole cores"

    # -- boot args, token by token, each one attributable -----------------
    local args="console=ttyS0 reboot=k panic=1 pci=off"
    prov DEFAULT "boot_args: console=ttyS0" "without it the guest boots silently and you cannot debug anything"
    prov DEFAULT "boot_args: reboot=k"      "a microVM has no ACPI; without this a reboot hangs instead of rebooting"
    prov DEFAULT "boot_args: panic=1"       "MEASURED (plan E.3): with it Firecracker exits in 1.63s on panic; without it the VM hung until killed at 20s"
    prov DEFAULT "boot_args: pci=off"       "there is no PCI bus to probe; probing it wastes boot time"

    if [[ -n "$ip" && -n "$tap" ]]; then
        args+=" ip=${ip}::${gw}:${mask}:${name}:eth0:off"
        prov DERIVED "boot_args: ip=" "built from ip/gateway/netmask/name; emitted ONLY because a tap is configured (plan F.4)"
    fi
    if [[ -n "$append" ]]; then
        args+=" $append"
        prov YOURS "boot_args: $append" "your append, passed through verbatim"
    fi
    prov APPENDED "boot_args: root=/dev/vda rw" "FIRECRACKER adds this after ours; the kernel honours the LAST root=, so this one wins"
    prov REFUSED  "boot_args: root=<yours>" "not offered as a knob — it would be silently overridden by the line above (plan E.4)"

    # -- network ----------------------------------------------------------
    local netblock=""
    if [[ -n "$tap" ]]; then
        if [[ -z "$mac" ]]; then
            # Deterministic from the name, so reruns are stable and two instances never collide.
            mac="$(mac_for_name "$name")"
            prov DERIVED "guest_mac = $mac" "hashed from the instance name so it is stable across reruns"
        else
            prov YOURS "guest_mac = $mac" "as given"
        fi
        prov YOURS "host_dev_name = $tap" "the tap must already exist — this tool validates taps, never creates them"
        netblock=$(cat <<EOF

  "network-interfaces": [
    { "iface_id": "eth0", "host_dev_name": $(json_str "$tap"), "guest_mac": $(json_str "$mac") }
  ],
EOF
)
    else
        prov DEFAULT "network-interfaces" "omitted entirely — you configured no tap"
    fi

    local mmdsblock=""
    if [[ "$mmds" == "true" ]]; then
        [[ -n "$tap" ]] || die "mmds = true needs a tap (MMDS is reached over a NIC)"
        mmdsblock=$'\n  "mmds-config": { "version": "V2", "network_interfaces": ["eth0"] },'
        prov YOURS "mmds-config V2" "V2 requires a PUT token handshake; V1 would answer any GET (plan F.2/F.3)"
    fi

    local json
    json=$(cat <<EOF
{
  "boot-source": {
    "kernel_image_path": $(json_str "$kernel"),
    "boot_args": $(json_str "$args")
  },
  "drives": [
    { "drive_id": "rootfs", "path_on_host": $(json_str "$rootfs"),
      "is_root_device": true, "is_read_only": false }
  ],${netblock}${mmdsblock}
  "machine-config": { "vcpu_count": $vcpus, "mem_size_mib": $mem, "smt": false }
}
EOF
)
    prov DERIVED "is_root_device = true" "exactly one root drive; this is what makes Firecracker append its root="

    if [[ "$out" == "-" ]]; then printf '%s\n' "$json"; else printf '%s\n' "$json" > "$out"; fi
}

# ═══════════════════════════════════════════════════════════════════════════
cmd_preflight() {
    local rec="$1"
    printf '\npreflight: %s\n' "$(field "$rec" name)"
    preflight_checks "$rec"
    printf '\n'
    if (( PF_FAIL > 0 )); then
        printf 'FAIL: %d gate(s) refused, %d UNKNOWN — nothing was created\n' "$PF_FAIL" "$PF_UNKNOWN"
        return 1
    fi
    if (( PF_UNKNOWN > 0 )); then
        printf 'PASS (with %d UNKNOWN): every gate that could run passed\n' "$PF_UNKNOWN"
    else
        printf 'PASS: every gate passed\n'
    fi
    return 0
}

cmd_create() {
    local rec="$1" dry="$2" name
    name="$(field "$rec" name)"

    # Refuse BEFORE the irreversible step. `create` copies a multi-hundred-megabyte rootfs;
    # every gate above is answerable first, and this is the SAME function preflight runs.
    PF_FAIL=0; PF_UNKNOWN=0
    printf '\npreflight (the same function `preflight` runs — not a second implementation):\n'
    preflight_checks "$rec"
    if (( PF_FAIL > 0 )); then
        printf '\nFAIL: %d gate(s) refused — nothing was created, nothing was copied\n' "$PF_FAIL"
        return 1
    fi

    gen_config "$rec" -  > /dev/null   # populate PROV
    printf '\ngenerated config.json:\n'
    gen_config "$rec" -

    printf '\nWHAT THIS TOOL DID THAT YOU DID NOT TYPE:'
    prov_table

    if [[ "$dry" == 1 ]]; then
        printf 'DRY RUN: nothing written. %d field(s) came from somewhere other than your spec.\n' \
            "$(printf '%s\n' "${PROV[@]}" | grep -cv '^YOURS' || true)"
        return 0
    fi

    local d; d="$(fc_dir "$name")"
    [[ -e "$d" ]] && die "instance '$name' already exists at $d — destroy it first (create does not overwrite)"
    mkdir -p "$d"

    # COPY FIRST, THEN GENERATE THE CONFIG AGAINST THE COPY.
    #
    # The first version of this generated config.json from the SOURCE record and then copied
    # the rootfs, so the manifest named `$d/rootfs.ext4` while config.json still pointed at
    # the original: the 128 MB copy was dead weight, the manifest described a file the VM
    # never touched, and two instances created from one source image would both have booted
    # it read-write and corrupted each other. A record that misdescribes its subject, in the
    # foundation everything else stacks on.
    local src; src="$(field "$rec" rootfs)"
    cp -- "$src" "$(fc_rootfs "$name")" || { rm -rf "$d"; die "could not copy rootfs $src -> $(fc_rootfs "$name")"; }

    # Re-point the record at the copy, then generate. The config and the manifest now name
    # the same file BY CONSTRUCTION rather than by both being edited in step.
    local rec_installed="${rec//rootfs=$src;/rootfs=$(fc_rootfs "$name");}"
    gen_config "$rec_installed" "$(fc_config "$name")"

    # Prove it, rather than trusting the substitution above: the path the VM will boot must
    # be the path we just wrote. This is cheap and it is the assertion the bug slipped past.
    local cfg_path; cfg_path="$(grep -o '"path_on_host": "[^"]*"' "$(fc_config "$name")" | head -1 | cut -d'"' -f4)"
    [[ "$cfg_path" == "$(fc_rootfs "$name")" ]] \
        || { rm -rf "$d"; die "REGRESSION: config.json points at '$cfg_path', not the per-instance copy '$(fc_rootfs "$name")'"; }

    # THE KERNEL IS NOT COPIED, SO ITS DIGEST IS THE ONLY THING BINDING THE RECORD TO IT.
    # REVIEW-phase7.md §3: the manifest recorded `rootfs_source_sha256` — and nothing, in
    # any verb, ever read it back, so "a re-staged source image is detectable" was a claim
    # with no reader. Meanwhile the KERNEL, which config.json points at by path and which
    # this repo actually does rebuild (micro-cloud rebuilds vmlinux between runs), had no
    # digest at all. That is the metal-as-a-service row verbatim: *the served vmlinuz vs
    # the kernel rebuilt over it — `file -b` printed the identical version string, only the
    # sha differed.* `start` now compares this one and refuses by name (see
    # `verify_recorded_artifacts`); `inspect` reports the rootfs source in three outcomes.
    local ksrc; ksrc="$(field "$rec" kernel)"
    {
        printf 'name = "%s"\n' "$name"
        printf 'lab = "%s"\n'  "$(field "$rec" lab micro-cloud)"
        printf 'kernel = "%s"\n' "$ksrc"
        printf 'kernel_sha256 = "%s"\n' "$(sha256sum "$ksrc" | cut -d' ' -f1)"
        printf 'rootfs = "%s"\n' "$(fc_rootfs "$name")"
        printf 'rootfs_source = "%s"\n' "$src"
        printf 'rootfs_source_sha256 = "%s"\n' "$(sha256sum "$src" | cut -d' ' -f1)"
        printf 'tap = "%s"\n'    "$(field "$rec" tap)"
        printf 'created = "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$(fc_manifest "$name")"
    printf '\nPASS: created %s\n' "$d"
    printf '      rootfs is a per-instance copy of %s (source sha recorded)\n' "$src"
    printf '      kernel stays where it is, bound to this instance by sha256 — `start` refuses a swapped one\n'
}

# ── the recorded digest is COMPARED, or it is decoration ────────────────────
# Only the kernel is checked, and deliberately only the kernel:
#   * it is read-only to the guest, so a mismatch means someone changed it — never the VM;
#   * it is the half the config points at by PATH rather than copying, so it is the half
#     that can change under a created instance;
#   * the rootfs COPY is booted read-write, so its digest is EXPECTED to differ after the
#     first boot. Gating `start` on that would be a gate that fires on correct behaviour,
#     which is how a real check gets switched off. `inspect` reports it instead.
# Refuse BEFORE the irreversible step: this runs before firecracker is spawned.
verify_recorded_artifacts() {  # verify_recorded_artifacts <name> <force>
    local name="$1" force="$2" man kpath kwant kgot
    man="$(fc_manifest "$name")"
    [[ -r "$man" ]] || return 0
    kwant="$(sed -n 's/^kernel_sha256 = "\(.*\)"$/\1/p' "$man")"
    kpath="$(sed -n 's/^kernel = "\(.*\)"$/\1/p' "$man")"
    # An instance created before this field existed has no digest. That is UNKNOWN, and
    # UNKNOWN is not a pass — say so rather than letting a missing record read as a match.
    if [[ -z "$kwant" ]]; then
        note "UNKNOWN: this instance's manifest records no kernel_sha256 (created by an older lab-fc.sh) — the kernel was NOT verified"
        return 0
    fi
    if [[ ! -r "$kpath" ]]; then
        (( force )) && { note "kernel '$kpath' is gone — starting anyway (--force)"; return 0; }
        die "the kernel this instance was created against is gone: $kpath (pass --force to start anyway; Firecracker will fail its own open)"
    fi
    kgot="$(sha256sum "$kpath" | cut -d' ' -f1)"
    if [[ "$kgot" != "$kwant" ]]; then
        (( force )) && { note "kernel sha256 mismatch on '$kpath' — starting anyway (--force)"; return 0; }
        die "REFUSING to start '$name': the kernel at $kpath is not the one it was created against.
       recorded: $kwant
       on disk:  $kgot
       A version string is not an identity — rebuild the instance (destroy + create) or pass --force."
    fi
    note "kernel sha256 matches the one recorded at create"
}

# ── ONE reader of the pidfile, and it asks about IDENTITY ───────────────────
# REVIEW-phase7.md P7-5. The identity check (`is the process at that pid actually ours?`)
# existed only inside `_kill_recorded`; `start` and `list` read the pidfile with a bare
# `-d /proc/$p`. Measured, with an unrelated `sleep 600`'s pid in fc.pid:
#
#     list  -> `k1  running`          start -> refused, "already running (pid …)"
#     stop  -> "was not running"
#
# One pidfile, three answers, in the same instant. And `_kill_recorded`'s own check was
# `grep -qa firecracker`, which cannot tell THIS instance's VMM from another one that
# happened to be recycled onto the pid — so it is now bound to the instance by its own
# config path, which is in firecracker's argv and unique per instance.
_running_pid() {  # _running_pid <name> -> prints the pid iff OUR firecracker is alive there
    local name="$1" pf p cfg
    pf="$(fc_pidfile "$name")"; [[ -r "$pf" ]] || return 1
    p="$(cat "$pf" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    [[ -d "/proc/$p" ]] || return 1
    cfg="$(fc_config "$name")"
    grep -qa firecracker "/proc/$p/cmdline" 2>/dev/null || return 1
    # EITHER per-instance path is a sufficient identity, and BOTH are needed as options
    # because a RESTORED VMM has no --config-file at all: a snapshot carries the machine
    # configuration, so `snapshot restore` starts firecracker with only --api-sock. Keeping
    # just the config check here would have made every restored instance invisible to
    # `list`, `stop` and `start` — the P7-5 defect (one pidfile, three answers) reintroduced
    # through a new verb rather than a new bug.
    local sock=""; sock="$(api_sock_of "$name" 2>/dev/null || true)"
    grep -qaF -- "$cfg" "/proc/$p/cmdline" 2>/dev/null && { printf '%s' "$p"; return 0; }
    [[ -n "$sock" ]] && grep -qaF -- "$sock" "/proc/$p/cmdline" 2>/dev/null \
        && { printf '%s' "$p"; return 0; }

    # A JAILED VMM'S ARGV CARRIES NEITHER OF THE ABOVE, AND THAT IS THE WHOLE POINT OF IT.
    # jailer chroots before it execs, so firecracker is told `--config-file /config.json` and
    # `--api-sock /api.sock` — paths inside the jail, identical for every instance, and
    # matching nothing on the host. Left as it was, `list`/`stop`/`start` would each have
    # given a different answer about a jailed instance: P7-5 for the THIRD time, arriving
    # through a third new verb rather than through a new bug.
    #
    # The identity used instead is STRONGER than an argv match, and it is the isolation
    # boundary itself: /proc/<pid>/root is where this process's filesystem root actually is,
    # and for a jailed instance that is a per-instance host path this tool created. It cannot
    # be spoofed by a recycled pid running an unrelated firecracker, because that process is
    # rooted somewhere else. (§5.6 asks you to READ this link as the exercise; here the tool
    # reads it to know what it is looking at.)
    # THE SAME QUESTION `start` ASKS, because a `start` that recognises a VMM one way and a
    # `stop` that recognises it another way IS P7-5, whatever the two ways are. Reading
    # /proc/<pid>/root or cwd was tried and measured wrong twice (see _jail_sock_pid); the
    # VMM answering `GET /` with its own id is not an inference about namespaces, it is the
    # machine speaking. Bounded by _api's own --max-time, so a wedged VMM cannot hang a list.
    local jroot=""; jroot="$(sed -n 's/^jail_root = "\(.*\)"$/\1/p' "$(fc_manifest "$name")" 2>/dev/null || true)"
    if [[ -n "$jroot" ]] && _jail_id_matches "$jroot" "$name"; then
        printf '%s' "$p"; return 0
    fi
    return 1
}

# ── FINDING THE JAILED VMM, AND THE TWO GUESSES THAT WERE WRONG ─────────────
#
# Measured over three privileged runs, because each answer was a guess about how the kernel
# renders a chrooted process and each one was wrong:
#
#   run 3: identity by `readlink /proc/<pid>/root` == the jail. It does not match. Diagnosed
#          as "jailer forks, so $! is the wrong pid" — WRONG, see below.
#   run 4: a /proc scan for any firecracker rooted at the jail, with a working-directory
#          fallback. Neither probe ever matched, and the scan was slow enough that its 60
#          iterations took 45 seconds while a perfectly healthy guest ticked away. The same
#          run also disproved the fork theory outright: `$!` was reported STILL ALIVE.
#
# So `$!` is the VMM after all, and what is unreliable is reading a process's root or cwd
# from another mount namespace — both are rendered relative to the reader, and after
# unshare(CLONE_NEWNS) neither is required to come back as a host path this tool would
# recognise. Two guesses about a rendering, in a row.
#
# THE THING THAT IS NOT A GUESS IS THE SOCKET. firecracker binds its API socket inside the
# chroot, which is a real directory on the host, so `$jroot/api.sock` is a host path with an
# inode — and the process holding it can be found by comparing that inode against every open
# fd. That is a derivation from a file this tool created, not an inference about namespaces.
# And the confirmation is stronger still: ASK THE VMM WHO IT IS. `GET /` returns the
# instance id jailer was given, so the machine answers for itself instead of being identified
# by something around it.
_jail_sock_pid() {  # _jail_sock_pid <jail-root> -> pid holding that jail's API socket, or 1
    # `stat -c %i` IS THE WRONG INODE, and it is the third rendering this got wrong: that is
    # the socket FILE's inode on the filesystem, while /proc/<pid>/fd shows `socket:[N]` with
    # N the socket's inode in the network/socket space. The two numbers are unrelated, so the
    # scan matched nothing and did so silently. /proc/net/unix is the table that joins a bound
    # path to that number, and it is the only thing here that is not an inference.
    local jroot="$1" path="$1/api.sock" ino d fd
    ino="$(awk -v p="$path" '$NF == p { print $(NF-1) }' /proc/net/unix 2>/dev/null | head -1)"
    [[ -n "$ino" ]] || return 1
    for d in /proc/[0-9]*; do
        for fd in "$d"/fd/*; do
            [[ "$(readlink "$fd" 2>/dev/null)" == "socket:[$ino]" ]] || continue
            printf '%s' "${d#/proc/}"; return 0
        done
    done
    return 1
}

_jail_id_matches() {  # _jail_id_matches <jail-root> <name> -> 0 iff the VMM says it is <name>
    local jroot="$1" name="$2" body id
    [[ -S "$jroot/api.sock" ]] || return 1
    body="$(_api "$jroot/api.sock" GET / 2>/dev/null)" || return 1
    id="$(grep -o '"id": *"[^"]*"' <<<"$body" | head -1 | cut -d'"' -f4 || true)"
    [[ "$id" == "$name" ]]
}

# ── staging a jail, which is where §5.6's sharp edge lives ──────────────────
#
# "Under the jailer every path in config.json is relative to the new chroot." That one
# sentence is the whole difference, and it bites in a way nothing warns you about: the config
# a plain `start` uses names /home/you/.local/state/.../rootfs.ext4, and inside the chroot
# that path does not exist. Firecracker then fails to open its own root device — which reads
# like a corrupt image, not like a path problem.
#
# So `--jailer` does three things a plain start does not:
#   1. stages the kernel and the rootfs INSIDE the jail root (hard link where the filesystem
#      allows it, copy otherwise — and it says which, because one is free and the other costs
#      the size of the guest disk);
#   2. writes a SECOND config.json, inside the jail, whose paths are the in-chroot ones;
#   3. hands jailer a --chroot-base-dir under this instance's own state dir, so a jail is
#      destroyed with its instance rather than accumulating under /srv/jailer.
#
# The rootfs is HARD-LINKED rather than copied when it can be, and that is not only an
# optimisation: a copy would be a second mutable image of the same disk, and this tool has
# already shipped the bug where two names for one guest's disk drift apart (see cmd_create).
# A hard link is the same inode — one disk, two names, no drift possible.
_stage_jail() {  # _stage_jail <name> <uid> <gid> -> populates the jail root; echoes nothing
    local name="$1" uid="$2" gid="$3" root; root="$(fc_jailroot "$name")"
    mkdir -p "$root" || die "could not create the jail root at $root"

    local man kernel; man="$(fc_manifest "$name")"
    kernel="$(sed -n 's/^kernel = "\(.*\)"$/\1/p' "$man")"
    [[ -r "$kernel" ]] || die "the kernel recorded for '$name' is not readable: $kernel"

    local how
    _stage_one() {  # _stage_one <src> <dst-basename> -> sets $how
        local src="$1" dst="$root/$2"
        rm -f -- "$dst"
        if ln -- "$src" "$dst" 2>/dev/null; then how=hard-linked; return 0; fi
        cp -- "$src" "$dst" || die "could not stage $src into the jail at $dst"
        how=copied
    }
    _stage_one "$kernel" vmlinux
    note "kernel $how into the jail ($how, because a hard link needs one filesystem)"
    _stage_one "$(fc_rootfs "$name")" rootfs.ext4
    note "rootfs $how into the jail"

    # ── THE STAGED FILES MUST BELONG TO THE UID THE VMM WILL BECOME ────────────────────
    # MEASURED 2026-08-19, on the first privileged run: without this the jailed VMM starts,
    # binds its API socket, and then dies with
    #     Unable to create the virtio block device: … Permission denied (os error 13) /rootfs.ext4
    # jailer chowns what IT creates — the chroot directory and its own copy of the exec-file
    # — and nothing else. Files staged in beforehand keep the ownership they were made with,
    # which is the invoking user's, and the VMM has by then dropped to --uid. So the guest
    # cannot open its own root device, and the error says "permission denied" about a path
    # inside a chroot, which reads like a jail-construction bug rather than a chown one.
    #
    # THE ROOTFS IS A HARD LINK, SO THIS CHOWNS THE INSTANCE'S OWN DISK TOO — one inode,
    # two names, one ownership. That is a real consequence of the tier rather than a side
    # effect to be hidden, and it is why `start` without --jailer now checks and says so
    # instead of failing the same opaque way from the other direction.
    local f
    for f in vmlinux rootfs.ext4; do
        chown "$uid:$gid" "$root/$f" \
            || die "could not chown $root/$f to $uid:$gid — the jailed VMM drops to that uid before it opens this file, and would fail with 'Permission denied' about a path inside the chroot.  (Staging a jail needs the same privilege jailer does.)"
    done

    # THE IN-CHROOT CONFIG. Derived from the real one by rewriting exactly the two paths that
    # move, so it cannot drift from the config `create` generated in any OTHER field — which
    # is what a hand-written second config would eventually do.
    # `[[:space:]]*` after the colon, not a literal space. JSON allows either and the first
    # version of this required the space `gen_config` happens to emit — so it silently
    # rewrote NOTHING against a config written any other way, and the only thing standing
    # between that and a Firecracker failing to open its root device was the assertion
    # below. Matching the format one writer happens to produce is a cache of that writer's
    # habits.
    local cfg; cfg="$(fc_config "$name")"
    sed -e "s#\"kernel_image_path\":[[:space:]]*\"[^\"]*\"#\"kernel_image_path\": \"/vmlinux\"#" \
        -e "s#\"path_on_host\":[[:space:]]*\"[^\"]*\"#\"path_on_host\": \"/rootfs.ext4\"#" \
        "$cfg" > "$root/config.json" \
        || die "could not write the in-chroot config at $root/config.json"

    # ASSERT THE REWRITE, rather than trusting the sed. A config that still names a host path
    # produces a Firecracker that cannot open its root device, and the error looks like a bad
    # image rather than a bad path — so this is the cheap assertion that saves the expensive
    # diagnosis.
    grep -q '"kernel_image_path": "/vmlinux"'  "$root/config.json" \
        || die "the in-chroot config still names a host kernel path — inside the chroot it does not exist"
    grep -q '"path_on_host": "/rootfs.ext4"'   "$root/config.json" \
        || die "the in-chroot config still names a host rootfs path — inside the chroot it does not exist"
    grep -q "$LAB_FC_STATE_DIR" "$root/config.json" \
        && die "the in-chroot config still contains a host state path — every path in it must resolve inside $root"
    chown "$uid:$gid" "$root/config.json" \
        || die "could not chown $root/config.json to $uid:$gid"
    return 0
}

cmd_start() {
    local name="$1" force="${2:-0}" jail="${3:-0}" d p i
    d="$(fc_dir "$name")"
    if [[ ! -r "$(fc_config "$name")" ]]; then
        # A CLONE has no config.json and never will: the machine configuration is inside the
        # memory image it was loaded from. Sending its operator to `create` would be a
        # confidently wrong instruction, which is the failure mode this tool's ledger keeps
        # naming — so the message is derived from what the instance actually IS.
        local cf; cf="$(sed -n 's/^cloned_from = "\(.*\)"$/\1/p' "$(fc_manifest "$name")" 2>/dev/null || true)"
        [[ -n "$cf" ]] \
            && die "'$name' is a CLONE of $cf and has no config.json — a snapshot carries the machine configuration, so there is nothing here to boot.  Once stopped, a clone is gone: make another with \`$0 clone ${cf%/*} ${cf#*/} <new-name>\`"
        die "no config for '$name' — run create first"
    fi
    if p="$(_running_pid "$name")"; then
        die "'$name' is already running (pid $p)"
    fi

    verify_recorded_artifacts "$name" "$force"

    # ── WHY THIS IS NO LONGER `--no-api` ───────────────────────────────────────────────
    # It was, from slice 1 onward, and nothing needed more. But Firecracker's snapshot
    # facility exists ONLY on the API socket: pause, snapshot/create and snapshot/load are
    # API calls, and a VMM launched with --no-api has nowhere to receive them. §5.8's fleet
    # (five warm clones from one memory image) and §9.5's fast preserve tier both bottom out
    # there, so `--no-api` was the actual blocker behind "lab-fc.sh has no snapshot verb".
    #
    # The config file STAYS. Firecracker takes both: it boots from --config-file and serves
    # the API on --api-sock, so nothing about how an instance boots changes — the socket only
    # adds a control channel that was previously absent. That matters for the identity check
    # above and for every existing test that greps this argv.
    if (( jail )); then
        require_cmd jailer
        # REFUSE BEFORE THE IRREVERSIBLE STEP, and refuse on the FACT rather than on a proxy
        # for it. Staging copies a guest disk; jailer's own failure comes after that, and its
        # message ("Failed to unshare into new mount namespace") does not say which privilege
        # is missing or how to get it.
        have_cap_sys_admin \
            || die "the jailer tier needs CAP_SYS_ADMIN and this process does not have it (CapEff=$(sed -n 's/^CapEff:[[:space:]]*//p' /proc/self/status)).
       jailer's first act is unshare(CLONE_NEWNS); without the capability it fails AFTER
       staging the chroot, with an error that names neither the privilege nor the fix.
       Run this verb under sudo, or start '$name' without --jailer for the untiered VMM."
        local jroot juid jgid
        jroot="$(fc_jailroot "$name")"
        juid="${LAB_FC_JAIL_UID:-$(id -u)}"; jgid="${LAB_FC_JAIL_GID:-$(id -g)}"
        _stage_jail "$name" "$juid" "$jgid"

        # The API socket lives INSIDE the jail, so it has two names: the one firecracker is
        # told (in-chroot) and the one the host opens. Recording the HOST one is what keeps
        # `snapshot` and `stop` working against a jailed instance.
        local hostsock="$jroot/api.sock"
        rm -f -- "$hostsock"
        printf '%s' "$hostsock" > "$(fc_sockfile "$name")"
        setsid jailer --id "$name" --exec-file "$(command -v firecracker)" \
            --uid "$juid" --gid "$jgid" \
            --chroot-base-dir "$(fc_jailbase "$name")" \
            -- --api-sock /api.sock --config-file /config.json \
            > "$(fc_log "$name")" 2>&1 < /dev/null &
        local forked=$!
        # The manifest gains the jail root BEFORE the wait, because it is what identity is
        # matched on afterwards. Appended rather than rewritten: the manifest is the
        # create-time record and this is the one run-time fact that is also a boundary.
        printf 'jail_root = "%s"\n' "$jroot" >> "$(fc_manifest "$name")"

        # WAIT FOR THE VMM TO ANSWER FOR ITSELF. Not for a pid to look a certain way in
        # /proc — two attempts at that were two wrong guesses about how the kernel renders a
        # chrooted process to a reader in another namespace. The socket appearing means
        # firecracker got far enough to bind it; `GET /` returning this instance's id means
        # the machine in the jail is the one we asked for.
        p=""
        for i in $(seq 1 200); do
            if _jail_id_matches "$jroot" "$name"; then
                p="$(_jail_sock_pid "$jroot")" || p="$forked"
                break
            fi
            [[ -d "/proc/$forked" ]] || break
            sleep 0.05
        done
        if [[ -z "$p" ]]; then
            printf 'FAIL: %s did not start jailed — the VMM never answered for itself on %s.\n' \
                "$name" "$jroot/api.sock" >&2
            printf '      socket present: %s · forked pid %s: %s\n' \
                "$( [[ -S "$jroot/api.sock" ]] && printf yes || printf no )" "$forked" \
                "$( [[ -d "/proc/$forked" ]] && printf 'alive' || printf 'gone' )" >&2
            printf '      Console log (%s):\n' "$(fc_log "$name")" >&2
            [[ -r "$(fc_log "$name")" ]] && { tail -10 "$(fc_log "$name")" | sed -e 's/^/      /' >&2 || true; }
            return 1
        fi
        printf '%s\n' "$p" > "$(fc_pidfile "$name")"
    else
        # A JAILED START TOOK OWNERSHIP OF THIS DISK, AND THIS IS THE WAY BACK.
        # `--jailer` hard-links the rootfs into the jail and chowns it to the jail uid — one
        # inode, two names, one ownership — so after a jailed run the instance's own disk
        # belongs to that uid. Firecracker would then fail here with a bare
        # "Permission denied (os error 13)" about its backing file, which is the same opaque
        # error the jailed arm gave from the other direction. Named instead, with the fix.
        if [[ ! -r "$(fc_rootfs "$name")" || ! -w "$(fc_rootfs "$name")" ]]; then
            die "'$name''s rootfs is not readable+writable by uid $EUID: $(fc_rootfs "$name") (owned by $(stat -c '%u:%g' "$(fc_rootfs "$name")" 2>/dev/null || printf '?'))
       A \`start --jailer\` hard-links this disk into the jail and chowns it to the jail uid,
       so it is one inode with one ownership. Take it back with:
           sudo chown $(id -u):$(id -g) $(fc_rootfs "$name")
       or start it jailed again."
        fi
        local sock; sock="$(_api_sock_for "$name")"
        rm -f -- "$sock" # a socket left by a dead VMM would make bind(2) fail with EADDRINUSE
        printf '%s' "$sock" > "$(fc_sockfile "$name")"
        setsid firecracker --api-sock "$sock" --config-file "$(fc_config "$name")" \
            > "$(fc_log "$name")" 2>&1 < /dev/null &
        p=$!
        printf '%s\n' "$p" > "$(fc_pidfile "$name")"
    fi

    # ASSERT THE OUTCOME. This used to print PASS on the strength of the fork returning —
    # which says only that bash created a process, not that a microVM exists. Measured
    # (P7-4): against a config Firecracker refuses, it printed `PASS: started k1 (pid …)`,
    # exited 0, and fc.log said `Error: Invalid JSON`. `stop` twenty lines below carries an
    # in-code comment about this exact mistake; the lesson was learned there and never
    # carried across.
    #
    # The wait is a POLL for the outcome, not a sleep long enough to "probably be fine":
    # it returns the moment the process is recognisably ours, and gives up the moment it is
    # gone. `setsid` may still be exec'ing when we first look, hence the loop.
    for i in $(seq 1 40); do
        _running_pid "$name" >/dev/null && break
        [[ -d "/proc/$p" ]] || break
        sleep 0.05
    done
    if ! _running_pid "$name" >/dev/null; then
        rm -f "$(fc_pidfile "$name")"
        printf 'FAIL: %s did not start — firecracker is not running. Console log (%s):\n' \
            "$name" "$(fc_log "$name")" >&2
        # `|| true` because `pipefail` is on and this is diagnostics, not a gate.
        [[ -r "$(fc_log "$name")" ]] \
            && { tail -10 "$(fc_log "$name")" | sed -e 's/^/      /' >&2 || true; }
        return 1
    fi
    if (( jail )); then
        printf 'PASS: started %s JAILED (pid %s) — process confirmed running, not merely forked; console -> %s\n' \
            "$name" "$p" "$(fc_log "$name")"
        printf '      chroot: %s\n' "$(fc_jailroot "$name")"
        printf '      compare it with a plain start:  readlink /proc/%s/root ; readlink /proc/%s/ns/net ; grep Seccomp /proc/%s/status\n' "$p" "$p" "$p"
    else
        printf 'PASS: started %s (pid %s) — process confirmed running, not merely forked; console -> %s\n' \
            "$name" "$p" "$(fc_log "$name")"
    fi
}

# stop/destroy resolve to a PID and kill THAT. Never a pattern: the per-VM paths appear in
# firecracker's argv, so `pkill -f` matches the process it names AND any tooling whose
# command line mentions it -- which once killed a QEMU VM and the agent's own shell.
_kill_recorded() {
    local name="$1" sig="$2" p
    p="$(_running_pid "$name")" || return 1
    kill "-$sig" "$p" && printf '%s' "$p"
}

cmd_stop() {
    local name="$1" force="${2:-0}" p i
    if ! p="$(_kill_recorded "$name" TERM)"; then
        printf 'PASS: %s was not running (nothing to signal)\n' "$name"
        rm -f "$(fc_pidfile "$name")"
        return 0
    fi
    # ASSERT THE OUTCOME. Sending a signal is not stopping a VM; the first version of this
    # printed PASS on the strength of kill(2) returning 0, which says only that the signal
    # was delivered. Firecracker with --no-api has no SendCtrlAltDel path, so whether TERM
    # is honoured is a fact about the guest, not about us.
    for i in $(seq 1 20); do
        [[ -d "/proc/$p" ]] || break
        sleep 0.25
    done
    if [[ -d "/proc/$p" ]]; then
        # --force NOW DOES SOMETHING. It was parsed, discarded with `: "$force"`, listed in
        # USAGE for both stop and destroy, recommended by THIS message, and passed by the
        # repo's only consumer (micro-cloud's cleanup calls `stop api1 --force`). A knob
        # that does nothing is the defect this tool's own header names — and it was in the
        # advice printed at the moment the operator most needs it to be true.
        if (( force )); then
            printf '  - %s (pid %s) ignored SIGTERM after 5s — escalating to SIGKILL (--force)\n' "$name" "$p" >&2
            kill -KILL "$p" 2>/dev/null || true
            for i in $(seq 1 20); do [[ -d "/proc/$p" ]] || break; sleep 0.25; done
        fi
        if [[ -d "/proc/$p" ]]; then
            printf 'FAIL: %s (pid %s) is still running after %s.\n' "$name" "$p" \
                "$( (( force )) && printf 'SIGTERM and SIGKILL' || printf 'SIGTERM for 5s — retry with --force')" >&2
            return 1
        fi
    fi
    rm -f "$(fc_pidfile "$name")"
    # A unix socket outlives the process that bound it, and bind(2) fails with EADDRINUSE on
    # a leftover — so a stopped instance leaves none. `start` also unlinks defensively,
    # because a SIGKILLed VMM never gets here.
    local sock; sock="$(api_sock_of "$name" 2>/dev/null || true)"
    [[ -n "$sock" ]] && rm -f -- "$sock"
    printf 'PASS: %s (pid %s) stopped — process confirmed gone, not merely signalled\n' "$name" "$p"
}

# ── snapshot: the verb §5.8 and §9.5 both bottom out on ─────────────────────
#
# Firecracker's snapshot is memory + device state, and it does NOT include the disk. The
# guest's page cache, its open inodes and its dirty buffers all describe the rootfs AS IT
# WAS at the instant of the pause. Restore that memory onto a rootfs that has moved on and
# nothing errors — you get a running guest whose kernel believes things about a filesystem
# that are no longer true, which is filesystem corruption with a clean exit code.
#
# So a snapshot here is SELF-CONTAINED: vmstate + mem + a copy of the rootfs, taken while
# the VM is paused so all three are the same instant. That is also exactly what §5.8's five
# warm clones need (each clone must get its own disk or they scribble over each other), so
# the expensive choice is the one the next slice was going to require anyway. It is not
# cheap — a 128 MiB rootfs is 128 MiB per snapshot — and `create` says so.
#
# The alternative, recording only the rootfs digest and refusing a changed one, was
# rejected: `create` resumes the VM afterwards, the guest immediately writes to its disk,
# and every later restore would refuse. A gate that fires on correct behaviour is how a
# real check gets switched off.
_snap_dir() { printf '%s/%s' "$(fc_snapdir "$1")" "$2"; }

# THE SNAPSHOT'S OWN DIGESTS, IN THREE OUTCOMES, IN ONE PLACE. A snapshot whose bytes have
# moved since it was taken is not restorable and it is not "probably fine"; a snapshot taken
# before this manifest existed is UNKNOWN, which is neither a match nor a mismatch and must
# not be rendered as either.
#
# It is a FUNCTION because `clone` needs the identical gate, and this repo's own ledger says
# what a second implementation of a safety check turns into: `preflight` is "the same
# function `create` calls first, not a second implementation that predicts what `create`
# will do" (§5.9), and the four-instruments audit (§18.7) found the one disagreement was a
# copy that had gone stale. A gate that two verbs implement separately is a gate one of them
# will stop having.
_verify_snapshot_digests() {  # _verify_snapshot_digests <snapshot-dir> <what-is-being-refused>
    local sdir="$1" what="$2"
    local m="$sdir/snapshot.toml" f want got
    if [[ ! -r "$m" ]]; then
        note "UNKNOWN: this snapshot has no snapshot.toml — its bytes were NOT verified"
        return 0
    fi
    for f in vmstate mem rootfs.ext4; do
        want="$(sed -n "s/^${f%%.*}_sha256 = \"\(.*\)\"$/\1/p" "$m")"
        [[ -n "$want" ]] || { note "UNKNOWN: no digest recorded for $f — it was NOT verified"; continue; }
        [[ -r "$sdir/$f" ]] || die "the snapshot is incomplete: $f is gone from $sdir"
        got="$(sha256sum "$sdir/$f" | cut -d' ' -f1)"
        [[ "$got" == "$want" ]] || die "REFUSING to $what: $f is not the file that was captured.
       recorded: $want
       on disk:  $got
       Restoring a memory image onto bytes it does not describe corrupts the guest silently."
    done
    note "snapshot digests match the ones recorded when it was taken"
}

_resume_or_warn() {  # best-effort resume; NEVER leave a paused VM behind on an error path
    local sock="$1" name="$2"
    if _api "$sock" PATCH /vm '{"state":"Resumed"}' >/dev/null 2>&1; then return 0; fi
    printf 'WARNING: %s is still PAUSED — the snapshot step failed and the resume did too.\n' "$name" >&2
    printf '         Resume it by hand:  curl --unix-socket %s -X PATCH http://localhost/vm -d '"'"'{"state":"Resumed"}'"'"'\n' "$sock" >&2
}

cmd_snapshot() {  # cmd_snapshot <action> <name> [snap] [force]
    local action="$1" name="$2" snap="${3:-}" force="${4:-0}"
    local d; d="$(fc_dir "$name")"
    [[ -d "$d" ]] || die "no such instance: $name"

    case "$action" in
        list)
            local sd; sd="$(fc_snapdir "$name")"
            if [[ ! -d "$sd" ]] || [[ -z "$(ls -A "$sd" 2>/dev/null)" ]]; then
                printf 'no snapshots for %s\n' "$name"; return 0
            fi
            printf '%-20s %-22s %10s  %s\n' SNAPSHOT TAKEN SIZE ROOTFS-SHA
            local one m
            for one in "$sd"/*/; do
                [[ -d "$one" ]] || continue
                m="$one/snapshot.toml"
                printf '%-20s %-22s %10s  %s\n' "$(basename "$one")" \
                    "$( [[ -r "$m" ]] && sed -n 's/^taken = "\(.*\)"$/\1/p' "$m" || printf '?')" \
                    "$(du -sh "$one" 2>/dev/null | cut -f1)" \
                    "$( [[ -r "$m" ]] && sed -n 's/^rootfs_sha256 = "\(.\{0,16\}\).*"$/\1…/p' "$m" || printf '?')"
            done
            return 0
            ;;
        create|restore|delete) ;;
        *) die "unknown snapshot action: $action (use create|list|restore|delete)" ;;
    esac

    [[ -n "$snap" ]] || die "snapshot $action needs a snapshot name: snapshot $action <instance> <snap>"
    # The snapshot name is a PATH COMPONENT, exactly as the instance name is — same gate,
    # same reason (P7-3). A name is not a path.
    valid_name "$snap" || die "invalid snapshot name '$snap' — must match ${FC_NAME_RE} (it is used as a directory name)"
    local sdir; sdir="$(_snap_dir "$name" "$snap")"

    case "$action" in
    delete)
        [[ -d "$sdir" ]] || die "no snapshot '$snap' for '$name' (try: snapshot list $name)"
        rm -rf -- "$sdir"
        [[ ! -d "$sdir" ]] || die "could not remove $sdir"
        printf 'PASS: deleted snapshot %s/%s\n' "$name" "$snap"
        ;;

    create)
        local p sock
        p="$(_running_pid "$name")" \
            || die "'$name' is not running — a snapshot captures MEMORY, and there is none to capture.  Run: $0 start $name"
        sock="$(api_sock_of "$name")" \
            || die "'$name' was started without an API socket (by a lab-fc.sh older than the snapshot verb).  Restart it: $0 stop $name && $0 start $name"
        [[ -S "$sock" ]] \
            || die "the recorded API socket is not there: $sock — restart '$name' so it is recreated"
        [[ ! -d "$sdir" ]] \
            || die "snapshot '$snap' already exists for '$name' — refusing to write over it (delete it first)"
        require_cmd curl
        mkdir -p "$sdir" || die "could not create $sdir"

        # PAUSE → CAPTURE → COPY THE DISK → RESUME. The copy happens INSIDE the pause on
        # purpose: that is the only window in which the memory image and the bytes on disk
        # describe the same instant.
        _api "$sock" PATCH /vm '{"state":"Paused"}' >/dev/null \
            || { rm -rf -- "$sdir"; die "could not pause '$name' — nothing was written"; }

        local rc=0 out
        out="$(_api "$sock" PUT /snapshot/create \
              "{\"snapshot_type\":\"Full\",\"snapshot_path\":\"$sdir/vmstate\",\"mem_file_path\":\"$sdir/mem\"}" 2>&1)" || rc=1
        if (( rc == 0 )); then
            cp -- "$(fc_rootfs "$name")" "$sdir/rootfs.ext4" || rc=1
        fi
        _resume_or_warn "$sock" "$name"
        if (( rc != 0 )); then
            rm -rf -- "$sdir"
            die "snapshot/create failed for '$name' (the VM was resumed; nothing was kept): $out"
        fi

        # ASSERT THE OUTCOME. A 204 from the API says the request was accepted; these files
        # existing and being non-empty is what says a snapshot exists. This tool has printed
        # PASS on the strength of a call returning before (P7-4) and the lesson is written
        # into `start` and `stop` twenty lines apart — carried across this time.
        local f
        for f in vmstate mem rootfs.ext4; do
            [[ -s "$sdir/$f" ]] || { rm -rf -- "$sdir"; die "snapshot/create returned success and left no $f — refusing to record a snapshot that is not there"; }
        done

        {
            printf '# snapshot of instance "%s" — written by lab-fc.sh\n' "$name"
            printf '#\n# The three files here are ONE INSTANT: mem and vmstate were captured while the VM\n'
            printf '# was paused, and rootfs.ext4 was copied before it was resumed. Restoring the memory\n'
            printf '# onto a different disk is silent filesystem corruption, which is why the disk is\n'
            printf '# kept here rather than referenced.\n\n'
            printf 'instance = "%s"\n' "$name"
            printf 'snapshot = "%s"\n' "$snap"
            printf 'taken = "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf 'fc_version = "%s"\n' "$(firecracker --version 2>/dev/null | head -1 || printf 'UNKNOWN')"
            printf 'vmstate_sha256 = "%s"\n' "$(sha256sum "$sdir/vmstate" | cut -d' ' -f1)"
            printf 'mem_sha256 = "%s"\n' "$(sha256sum "$sdir/mem" | cut -d' ' -f1)"
            printf 'rootfs_sha256 = "%s"\n' "$(sha256sum "$sdir/rootfs.ext4" | cut -d' ' -f1)"
        } > "$sdir/snapshot.toml"

        printf 'PASS: snapshot %s/%s — %s, VM resumed and still running (pid %s)\n' \
            "$name" "$snap" "$(du -sh "$sdir" | cut -f1)" "$p"
        printf '      memory, device state AND the disk, all from the same pause\n'
        ;;

    restore)
        [[ -d "$sdir" ]] || die "no snapshot '$snap' for '$name' (try: snapshot list $name)"
        local p
        if p="$(_running_pid "$name")"; then
            die "'$name' is running (pid $p) — restore replaces both its memory and its disk.  Stop it first: $0 stop $name"
        fi
        require_cmd curl

        _verify_snapshot_digests "$sdir" "restore '$name/$snap'"

        # The disk goes back FIRST and the VMM is started second, so the guest never sees a
        # disk change under it.
        cp -- "$sdir/rootfs.ext4" "$(fc_rootfs "$name")" \
            || die "could not restore the snapshot's rootfs over $(fc_rootfs "$name")"

        local sock; sock="$(_api_sock_for "$name")"
        rm -f -- "$sock"
        printf '%s' "$sock" > "$(fc_sockfile "$name")"
        # NO --config-file. The snapshot carries the machine configuration; passing a config
        # as well makes Firecracker refuse the load. This is why `_running_pid` accepts the
        # socket path as an identity.
        setsid firecracker --api-sock "$sock" >> "$(fc_log "$name")" 2>&1 < /dev/null &
        local newp=$!
        printf '%s\n' "$newp" > "$(fc_pidfile "$name")"

        local i
        for i in $(seq 1 60); do [[ -S "$sock" ]] && break; [[ -d "/proc/$newp" ]] || break; sleep 0.05; done
        [[ -S "$sock" ]] || { rm -f "$(fc_pidfile "$name")"; die "firecracker did not create its API socket at $sock (see $(fc_log "$name"))"; }

        local out rc2=0
        out="$(_api "$sock" PUT /snapshot/load \
              "{\"snapshot_path\":\"$sdir/vmstate\",\"mem_backend\":{\"backend_type\":\"File\",\"backend_path\":\"$sdir/mem\"},\"enable_diff_snapshots\":false,\"resume_vm\":true}" 2>&1)" || rc2=1
        if (( rc2 != 0 )); then
            kill "$newp" 2>/dev/null || true
            rm -f "$(fc_pidfile "$name")"
            die "snapshot/load failed for '$name/$snap': $out"
        fi

        # ASSERT THE OUTCOME, TWICE, because each half can be true while the other is not:
        # the process being alive says a VMM exists, and the API saying Running says a GUEST
        # was resumed into it. A load that half-failed leaves the first true and the second
        # not, and that is precisely the shape this tool has shipped before.
        _running_pid "$name" >/dev/null \
            || { rm -f "$(fc_pidfile "$name")"; die "the restored VMM is not running (see $(fc_log "$name"))"; }
        local state
        state="$(_api "$sock" GET / 2>/dev/null | grep -o '"state": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
        [[ "$state" == "Running" ]] \
            || die "the VMM is up but the guest was not resumed — /  reports state=${state:-UNKNOWN} (see $(fc_log "$name"))"

        printf 'PASS: restored %s from snapshot %s (pid %s) — API reports state=Running\n' "$name" "$snap" "$newp"
        printf '      memory, devices and disk all came from the same captured instant\n'
        ;;
    esac
}

# ── clone: N machines from ONE memory image ─────────────────────────────────
#
# `snapshot restore` puts a snapshot back into the instance it came from. `clone` makes a
# DIFFERENT machine from it — which is the whole of §5.8's fleet, and the two differ in
# exactly two places:
#
#   * the disk is COPIED per clone, never shared. A snapshot's rootfs is one instant of one
#     filesystem; two guests writing to one copy of it is corruption on the first write.
#   * the MEMORY IMAGE IS SHARED, and that is the point rather than an optimisation.
#     Firecracker maps a `File` mem backend MAP_PRIVATE, so N clones read one file and each
#     one's writes are private to it. MEASURED, not assumed: after five clones had been
#     running and writing for several seconds, the mem file's sha256 was unchanged
#     (tests/../examples/micro-cloud/tests/test-fleet-clones.sh asserts exactly that). One
#     256 MiB image serves the whole fleet; copying it per clone would cost 5x the RAM for
#     no benefit, and it is why five clones come up in a fraction of one boot.
#
# WHY THE RESTORED CONFIG HAS TO BE PATCHED, AND WHY THE PATCH IS A HARD GATE.
# The machine configuration lives INSIDE the snapshot, and it names the SOURCE instance's
# rootfs by absolute path. Load it and resume with no further ado and every clone opens the
# source's disk — five guests, one file, silent mutual corruption, exit code 0 throughout.
# So the sequence is load(resume_vm:false) -> PATCH /drives/rootfs -> resume, and a PATCH
# that does not return 2xx tears the clone down instead of resuming it. Resuming anyway
# would be the LIED rung: a fleet that looks up and is eating itself.
#
# WHAT THIS VERB DELIBERATELY DOES NOT DO: --tap.
# `PATCH /network-interfaces` moves the HOST tap. It cannot touch the guest's MAC or its
# `ip=`, because both of those are in the memory image being copied — so N clones would all
# claim one MAC and one address on one L2. That is not a networking bug to be worked around
# later, it is §5.8's lesson in its purest form (identity is a property of a running thing),
# and a knob that produced it silently would be this tool telling its own tripwire a lie.
# The clone comes up with the source's identity and `clone` says so, by name, every time.
cmd_clone() {  # cmd_clone <src> <snap> <new>
    local src="$1" snap="$2" new="$3"
    [[ -d "$(fc_dir "$src")" ]] || die "no such instance: $src"
    valid_name "$snap" || die "invalid snapshot name '$snap' — must match ${FC_NAME_RE} (it is used as a directory name)"
    local sdir; sdir="$(_snap_dir "$src" "$snap")"
    [[ -d "$sdir" ]] || die "no snapshot '$snap' for '$src' (try: $0 snapshot list $src)"
    [[ "$new" != "$src" ]] \
        || die "a clone needs a NEW name — '$new' is the instance the snapshot was taken from.  To put it back into itself: $0 snapshot restore $src $snap"
    local nd; nd="$(fc_dir "$new")"
    [[ -e "$nd" ]] && die "instance '$new' already exists at $nd — clone does not overwrite (destroy it first)"
    require_cmd curl sha256sum

    # REFUSE BEFORE THE IRREVERSIBLE STEP. Nothing below this line is undone for free: the
    # rootfs copy is the size of the guest's disk. The gate is the SAME function `restore`
    # calls, not a second one.
    _verify_snapshot_digests "$sdir" "clone '$src/$snap' into '$new'"

    mkdir -p "$nd" || die "could not create $nd"
    local rootfs; rootfs="$(fc_rootfs "$new")"
    cp -- "$sdir/rootfs.ext4" "$rootfs" \
        || { rm -rf -- "$nd"; die "could not copy the snapshot's rootfs to $rootfs — nothing was started"; }

    local sock; sock="$(_api_sock_for "$new")"
    rm -f -- "$sock"
    printf '%s' "$sock" > "$(fc_sockfile "$new")"

    # NO --config-file, for the same reason `snapshot restore` passes none: the snapshot
    # carries the machine configuration, and Firecracker refuses a load when both are given.
    setsid firecracker --api-sock "$sock" >> "$(fc_log "$new")" 2>&1 < /dev/null &
    local p=$!
    printf '%s\n' "$p" > "$(fc_pidfile "$new")"

    # Every failure from here on tears the clone down. A half-made clone is worse than none:
    # it has a directory, a manifest and a pidfile, so `list` would report it.
    _clone_abort() {  # _clone_abort <msg>
        kill "$p" 2>/dev/null || true
        rm -f -- "$sock"
        rm -rf -- "$nd"
        die "$1"
    }

    local _i
    for _i in $(seq 1 60); do [[ -S "$sock" ]] && break; [[ -d "/proc/$p" ]] || break; sleep 0.05; done
    [[ -S "$sock" ]] || _clone_abort "firecracker did not create its API socket at $sock (see $(fc_log "$new"))"

    local out
    out="$(_api "$sock" PUT /snapshot/load \
          "{\"snapshot_path\":\"$sdir/vmstate\",\"mem_backend\":{\"backend_type\":\"File\",\"backend_path\":\"$sdir/mem\"},\"enable_diff_snapshots\":false,\"resume_vm\":false}" 2>&1)" \
        || _clone_abort "snapshot/load failed for clone '$new' from '$src/$snap': $out"

    # THE PATCH IS A GATE, NOT A COURTESY -- see the header. Loaded-but-not-patched means
    # this clone is pointed at the SOURCE's disk.
    out="$(_api "$sock" PATCH /drives/rootfs \
          "{\"drive_id\":\"rootfs\",\"path_on_host\":$(json_str "$rootfs")}" 2>&1)" \
        || _clone_abort "could not re-point clone '$new' at its own disk (PATCH /drives/rootfs): $out
       It was NOT resumed. Resuming it would have run it on '$src''s rootfs."

    out="$(_api "$sock" PATCH /vm '{"state":"Resumed"}' 2>&1)" \
        || _clone_abort "clone '$new' loaded and was re-pointed at its own disk, but would not resume: $out"

    # ASSERT THE OUTCOME, TWICE, for the reason `snapshot restore` does: a live process says
    # a VMM exists; the API saying Running says a GUEST was resumed into it. Each can be true
    # while the other is not.
    _running_pid "$new" >/dev/null || _clone_abort "the cloned VMM is not running (see $(fc_log "$new"))"
    local state
    state="$(_api "$sock" GET / 2>/dev/null | grep -o '"state": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    [[ "$state" == "Running" ]] \
        || _clone_abort "clone '$new' has a VMM but no resumed guest — / reports state=${state:-UNKNOWN} (see $(fc_log "$new"))"

    # The manifest binds this clone to the memory image it is READING RIGHT NOW, by digest.
    # That file lives in another instance's state dir and this clone does not own it, which
    # is exactly the shape of record this repo keeps finding outliving its subject -- so
    # `inspect` re-derives it in three outcomes and `destroy` refuses to pull it out from
    # under a live clone by name.
    {
        printf '# instance "%s" — a CLONE, written by lab-fc.sh\n' "$new"
        printf '#\n# It has no config.json: a snapshot carries the machine configuration, so there is\n'
        printf '# nothing for this tool to generate. It also has no kernel of its own — the kernel is\n'
        printf '# already running inside the memory image below.\n\n'
        printf 'name = "%s"\n' "$new"
        printf 'lab = "%s"\n' "$(sed -n 's/^lab = "\(.*\)"$/\1/p' "$(fc_manifest "$src")" 2>/dev/null || printf 'micro-cloud')"
        printf 'cloned_from = "%s/%s"\n' "$src" "$snap"
        printf 'clone_mem = "%s"\n' "$sdir/mem"
        printf 'clone_mem_sha256 = "%s"\n' "$(sha256sum "$sdir/mem" | cut -d' ' -f1)"
        printf 'rootfs = "%s"\n' "$rootfs"
        printf 'rootfs_source = "%s"\n' "$sdir/rootfs.ext4"
        printf 'rootfs_source_sha256 = "%s"\n' "$(sha256sum "$sdir/rootfs.ext4" | cut -d' ' -f1)"
        printf 'created = "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$(fc_manifest "$new")"

    printf 'PASS: cloned %s/%s -> %s (pid %s) — API reports state=Running\n' "$src" "$snap" "$new" "$p"
    printf '      its own disk: %s\n' "$rootfs"
    printf '      SHARED memory image (read-only to it, mapped MAP_PRIVATE): %s\n' "$sdir/mem"
    printf '\n'
    printf 'NOT RE-PERSONALISED — this clone resumed as a copy of a RUNNING machine, so it\n'
    printf 'currently believes it is %s. Identical to every other clone of this snapshot:\n' "$src"
    printf '  - /proc/sys/kernel/random/boot_id  (the kernel session id systemd and journald key off)\n'
    printf '  - anything already derived from /dev/urandom and held in memory: session keys,\n'
    printf '    ssh host keys read at boot, a seeded PRNG in a long-running process\n'
    printf '  - the clock, the hostname, and (had it a NIC) the guest MAC and its ip= address\n'
    printf 'The CRNG is reseeded on resume by the guest kernel IF it has VMGenID — but that\n'
    printf 'reseed is an ASYNC notify, so it narrows the window rather than closing it, and it\n'
    printf 'does not touch anything already derived from the pool. Measured both ways in\n'
    printf 'RUNBOOK-fleet.md. Re-personalisation is a GUEST-side step; this tool does not fake it.\n'
}

cmd_destroy() {
    local name="$1" force="${2:-0}" d p; d="$(fc_dir "$name")"
    [[ -d "$d" ]] || die "no such instance: $name"
    # Same meaning for --force as `stop`: without it, a RUNNING instance is not silently
    # killed out from under you. `create` already refuses to overwrite; `destroy` refusing
    # to reap a live VM completes the pair.
    if p="$(_running_pid "$name")"; then
        (( force )) || die "'$name' is running (pid $p) — stop it first, or pass --force to kill and destroy it"
        _kill_recorded "$name" KILL >/dev/null || true
    fi
    # The API socket is normally INSIDE $d and goes with it. When the instance path was too
    # long for sun_path it is not, and a `rm -rf $d` would leave it behind — a stale socket
    # that makes the next `start` fail its bind. Reap it by the path this instance recorded,
    # never by a pattern over /tmp.
    local sock; sock="$(api_sock_of "$name" 2>/dev/null || true)"
    [[ -n "$sock" && "$sock" != "$d"/* ]] && rm -f -- "$sock"

    # A CLONE READS ITS MEMORY IMAGE OUT OF THIS DIRECTORY, AND DOES NOT OWN IT.
    # `clone` shares the snapshot's mem file rather than copying it (see cmd_clone), so
    # destroying the source takes the backing file out from under every clone made from it.
    # A running clone survives -- the mapping outlives the unlink -- but nothing can be
    # cloned from that snapshot again and no clone's provenance can ever be re-derived, so
    # this is the "record outlives its subject" shape with the subject deleted on purpose.
    # It is refused BY NAME, and --force is how you say you meant it. Derived by reading the
    # sibling manifests, never cached: a list of dependants written at clone time is a
    # record that goes stale the moment one is destroyed.
    local -a users=() other om
    for other in "$LAB_FC_STATE_DIR"/*/; do
        om="$other/manifest.toml"
        [[ -r "$om" ]] || continue
        [[ "$(basename "$other")" != "$name" ]] || continue
        grep -qF "clone_mem = \"$d/" "$om" 2>/dev/null && users+=("$(basename "$other")")
    done
    if (( ${#users[@]} )); then
        if (( ! force )); then
            printf 'lab-fc.sh: %d clone(s) read their memory image out of %s:\n' "${#users[@]}" "$d" >&2
            local u
            for u in "${users[@]}"; do
                printf '  - %s (%s)\n' "$u" "$( _running_pid "$u" >/dev/null && printf 'RUNNING' || printf 'stopped' )" >&2
            done
            die "refusing to destroy '$name' — destroy those first, or pass --force to remove the memory image they were made from"
        fi
        note "--force: removing a memory image ${#users[@]} clone(s) were made from (${users[*]})"
    fi

    rm -rf -- "$d"
    # The tap is NOT deleted here -- the fabric owns it (see the header).
    printf 'PASS: destroyed %s (its tap, if any, belongs to the fabric and was left alone)\n' "$name"
}

cmd_list() {
    local json="${1:-0}" first=1
    [[ "$json" == 1 ]] && printf '['
    local d name run
    for d in "$LAB_FC_STATE_DIR"/*/; do
        [[ -d "$d" && -r "$d/manifest.toml" ]] || continue
        name="$(basename "$d")"
        # A directory whose name is not a valid instance name was not made by `create`, and
        # `_running_pid`/`fc_dir` would refuse it anyway. Skipping it here also keeps the
        # --json output from carrying a name nothing validated.
        valid_name "$name" || continue
        run=stopped
        _running_pid "$name" >/dev/null && run=running   # IDENTITY, not just liveness (P7-5)
        if [[ "$json" == 1 ]]; then
            [[ "$first" == 1 ]] || printf ','; first=0
            printf '{"name":%s,"state":"%s"}' "$(json_str "$name")" "$run"
        else
            printf '%-16s %s\n' "$name" "$run"
        fi
    done
    [[ "$json" == 1 ]] && printf ']\n'
    return 0
}

cmd_inspect() {
    local name="$1" d; d="$(fc_dir "$name")"
    [[ -d "$d" ]] || die "no such instance: $name"
    cat "$(fc_manifest "$name")"
    # Name the file only if it is there. A clone has no config.json and never will, and a
    # path printed as a fact is read as one -- `config = "…/w1/config.json"` sent a reader
    # looking for a file that was never going to exist.
    if [[ -r "$(fc_config "$name")" ]]; then
        printf 'config = "%s"\n' "$(fc_config "$name")"
    else
        printf 'config = "none — a snapshot carries the machine configuration"\n'
    fi
    local p; p="$(_running_pid "$name")" && printf 'state = "running"\npid = %s\n' "$p" \
        || printf 'state = "stopped"\n'
    # THREE outcomes for each recorded digest, never two. "I could not look" is not "it
    # matches" and it is not "it changed" either — the same rule the /sbin/init gate learned
    # the hard way (test-unknown-is-not-pass.sh).
    _digest_row() {   # _digest_row <label> <path> <recorded>
        local label="$1" path="$2" want="$3"
        [[ -n "$want" ]] || { printf '%s_check = "UNKNOWN: no digest recorded at create"\n' "$label"; return; }
        [[ -r "$path" ]] || { printf '%s_check = "UNKNOWN: %s is gone"\n' "$label" "$path"; return; }
        if [[ "$(sha256sum "$path" | cut -d' ' -f1)" == "$want" ]]; then
            printf '%s_check = "match"\n' "$label"
        else
            printf '%s_check = "CHANGED since create"\n' "$label"
        fi
    }
    local man; man="$(fc_manifest "$name")"
    # A CLONE has no kernel row to check — the kernel is inside the memory image — and it
    # has one dependency an ordinary instance does not: a mem file in ANOTHER instance's
    # state dir, which it is reading right now and does not own. Printing
    # `kernel_check = "UNKNOWN: no digest recorded at create"` at a clone would be an
    # UNKNOWN about a question that does not apply, and the one thing genuinely worth
    # re-deriving would not be reported at all.
    local cf; cf="$(sed -n 's/^cloned_from = "\(.*\)"$/\1/p' "$man")"
    if [[ -n "$cf" ]]; then
        printf 'kernel_check = "n/a — cloned instance; the kernel is inside the memory image"\n'
        _digest_row clone_mem "$(sed -n 's/^clone_mem = "\(.*\)"$/\1/p' "$man")" \
                              "$(sed -n 's/^clone_mem_sha256 = "\(.*\)"$/\1/p' "$man")"
    else
        _digest_row kernel "$(sed -n 's/^kernel = "\(.*\)"$/\1/p' "$man")" \
                           "$(sed -n 's/^kernel_sha256 = "\(.*\)"$/\1/p' "$man")"
    fi
    _digest_row rootfs_source "$(sed -n 's/^rootfs_source = "\(.*\)"$/\1/p' "$man")" \
                              "$(sed -n 's/^rootfs_source_sha256 = "\(.*\)"$/\1/p' "$man")"
}

# ── argument handling ───────────────────────────────────────────────────────
# Marker-delimited so edits to the header cannot silently shift what --help prints.
# The guest MAC for an instance name.
#
# THIS FORMULA IS SHARED WITH `examples/micro-cloud/fabric.sh` AND MUST NOT DRIFT. The fabric
# reserves a DHCP lease against a MAC; this tool sets the MAC on the guest. Derive them
# differently and the microVM misses its reservation, takes a dynamic lease, and dnsmasq goes
# on answering the name with an address nothing holds — invisible from either tool alone.
# That is not hypothetical: until 2026-08-05 the fabric derived its MAC from the ORDER taps
# were created (`api1` -> 06:00:ac:47:00:01) while this tool hashed the name
# (`api1` -> 06:00:ac:47:f1:f7), so the two could never agree. It went unnoticed because no
# run had ever pointed this tool at a fabric tap.
#
# The two live in different phases and cannot share code, so the agreement is asserted by
# `examples/micro-cloud/tests/test-fabric-mac-derivation.sh`, which drives BOTH tools' `mac`
# verb rather than re-implementing either formula.
mac_for_name() {
    local n="$1" h
    h="$(printf '%s' "$n" | md5sum)" || return 1
    printf '06:00:ac:47:%02x:%02x' $(( 0x${h:0:2} )) $(( 0x${h:2:2} ))
}

usage() { sed -n '/^# ── USAGE ──/,/^# ── END USAGE ──/p' "$0" | sed '1d;$d; s/^# \{0,1\}//'; exit 0; }

main() {
    local verb="${1:-}"; shift || true
    [[ -n "$verb" ]] || usage
    case "$verb" in help|-h|--help) usage ;; esac

    local cfg="" name="" kernel="" rootfs="" memory="" vcpus="" tap="" mac="" ipaddr="" gw="" mask="" mmds="" append="" dry=0 json=0 lab="" force=0 jailer=0
    local positional=()
    while (( $# )); do
        case "$1" in
            --config)  cfg="$2"; shift 2 ;;
            --name)    name="$2"; shift 2 ;;
            --kernel)  kernel="$2"; shift 2 ;;
            --rootfs)  rootfs="$2"; shift 2 ;;
            --memory)  memory="$2"; shift 2 ;;
            --vcpus)   vcpus="$2"; shift 2 ;;
            --tap)     tap="$2"; shift 2 ;;
            --mac)     mac="$2"; shift 2 ;;
            --ip)      ipaddr="$2"; shift 2 ;;
            --gateway) gw="$2"; shift 2 ;;
            --netmask) mask="$2"; shift 2 ;;
            --append)  append="$2"; shift 2 ;;
            --lab)     lab="$2"; shift 2 ;;
            --mmds)    mmds=true; shift ;;
            --dry-run) dry=1; shift ;;
            --json)    json=1; shift ;;
            --force)   force=1; shift ;;
            --jailer)  jailer=1; shift ;;
            -*)        die "unknown flag: $1" ;;
            *)         positional+=("$1"); shift ;;
        esac
    done

    # THE NAME IS VALIDATED WHERE IT IS SELECTED, not inside each verb (P7-3). The `fc_dir`
    # accessor guard is the backstop, but a `die` inside `$( … )` exits only the command
    # substitution — measured here: `cmd_stop` reaches `fc_dir` through
    # `p="$(_kill_recorded …)"`, so the refusal died in the subshell and the caller went on
    # to print `PASS: … was not running`. The repo has this exact gotcha written down; it
    # still cost a run. Both guards are kept: this one because it is in the caller's own
    # shell, the accessor one because it is what makes a verb added later safe by default.
    # It SETS a variable rather than printing one, for the same reason: `n="$(_name_arg)"`
    # would put the `die` back inside a command substitution and lose it again.
    _name_arg() {
        local n="${positional[0]:-}"
        [[ -n "$n" ]] || die "instance name required: $verb <name>"
        valid_name "$n" || die "invalid instance name '$n' — must match ${FC_NAME_RE} (it is used as a directory name under $LAB_FC_STATE_DIR, so a path is not a name)"
        name="$n"
    }
    case "$verb" in
        list)    cmd_list "$json"; return ;;
        start|stop|destroy|inspect) _name_arg ;;
        snapshot)
            # `snapshot <action> <name> [snap]` — the instance is the SECOND positional, so
            # _name_arg (which reads the first) cannot be reused. Same validation, applied
            # to the argument that is actually the name.
            [[ -n "${positional[1]:-}" ]] || die "usage: $0 snapshot {create|list|restore|delete} <name> [snap]"
            valid_name "${positional[1]}" || die "invalid instance name '${positional[1]}' — must match ${FC_NAME_RE}"
            name="${positional[1]}" ;;
        clone)
            # `clone <src> <snap> <new>` — TWO instance names, and both are path components.
            # Validating only the first is how the escape gets back in through the argument
            # nobody was looking at (P7-3 was exactly one un-gated positional).
            (( ${#positional[@]} == 3 )) || die "usage: $0 clone <src-instance> <snapshot> <new-name>"
            valid_name "${positional[0]}" || die "invalid instance name '${positional[0]}' — must match ${FC_NAME_RE}"
            valid_name "${positional[2]}" || die "invalid instance name '${positional[2]}' — must match ${FC_NAME_RE}" ;;
    esac
    case "$verb" in
        start)   cmd_start   "$name" "$force" "$jailer"; return ;;
        stop)    cmd_stop    "$name" "$force"; return ;;
        destroy) cmd_destroy "$name" "$force"; return ;;
        inspect) cmd_inspect "$name"; return ;;
        snapshot) cmd_snapshot "${positional[0]}" "$name" "${positional[2]:-}" "$force"; return ;;
        clone)    cmd_clone "${positional[0]}" "${positional[1]}" "${positional[2]}"; return ;;
        mac)     # read-only, no tap, no root: the MAC this tool WOULD set for a name.
                 # Exists so the fabric/VMM agreement can be asserted in CI instead of only
                 # on a host that can create taps — an invariant only checkable under root
                 # is an invariant that drifts.
                 mac_for_name "${positional[0]:?instance name required}" \
                     || die "could not derive a MAC (is md5sum present?)"
                 printf '\n'; return ;;
        preflight|create) ;;
        *) die "unknown verb: $verb (try --help)" ;;
    esac

    local -a records=()
    if [[ -n "$cfg" ]]; then
        # NOT `mapfile < <(toml_microvms ...)`: a process substitution DISCARDS the
        # producer's exit status, so the parser's "unknown key" refusal (exit 3) printed a
        # message and the run carried on with a partial record -- a refusal that refuses
        # nothing. Capture to a file so the status is testable.
        local _recs; _recs="$(mktemp)"
        if ! toml_microvms "$cfg" > "$_recs"; then
            rm -f "$_recs"
            die "refusing $cfg — see the parser error above (nothing was created)"
        fi
        mapfile -t records < "$_recs"; rm -f "$_recs"
        (( ${#records[@]} )) || die "no [[microvm]] blocks in $cfg"
    else
        [[ -n "$name" ]] || die "need --config <file> or --name <n> --kernel <k> --rootfs <r>"
        # EVERY KNOWN KEY IS REACHABLE FROM THE CLI, AND EVERY FLAG REACHES THE RECORD.
        # REVIEW-phase7.md §3: `--lab` was parsed into a variable and then thrown away by
        # `: "$force" "$lab"`, so `--lab MY-OWN-LAB` wrote `lab = "micro-cloud"` into the
        # manifest and said nothing; `--mac` and `--netmask` were `KNOWN_KEYS` with no flag
        # at all. Both halves are the tool's own tripwire — "a config key that is silently
        # dropped is a field that appears to work and does nothing" — turned on itself.
        # tests/test-cli-vs-config-parity.sh now derives this list from KNOWN_KEYS, so a
        # key added later without a flag fails rather than being noticed by someone.
        local r="" k v
        for k in name kernel rootfs memory vcpus tap mac ip gateway netmask append lab mmds; do
            case "$k" in
                name) v="$name" ;; kernel) v="$kernel" ;; rootfs) v="$rootfs" ;;
                memory) v="$memory" ;; vcpus) v="$vcpus" ;; tap) v="$tap" ;;
                mac) v="$mac" ;; ip) v="$ipaddr" ;; gateway) v="$gw" ;;
                netmask) v="$mask" ;; append) v="$append" ;; lab) v="$lab" ;;
                mmds) v="$mmds" ;;
            esac
            [[ -n "$v" ]] || continue
            # The same refusal the config parser makes, at the other entry point — the
            # record separator does not become smugglable just because the value arrived
            # through argv (P7-6).
            record_value_ok "$k" "$v"
            r+="$k=$v;"
        done
        records=("$r")
    fi

    local rc=0 rec
    for rec in "${records[@]}"; do
        PF_FAIL=0; PF_UNKNOWN=0
        case "$verb" in
            preflight) cmd_preflight "$rec" || rc=1 ;;
            create)    cmd_create "$rec" "$dry" || rc=1 ;;
        esac
    done
    return "$rc"
}

main "$@"

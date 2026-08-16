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
#   lab-fc.sh start     <name> [--force]     # --force: start despite a changed/missing kernel
#   lab-fc.sh stop      <name> [--force]     # --force: escalate to SIGKILL if SIGTERM is ignored
#   lab-fc.sh destroy   <name> [--force]     # --force: kill it first if it is running
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
    grep -qaF -- "$cfg" "/proc/$p/cmdline" 2>/dev/null || return 1
    printf '%s' "$p"
}

cmd_start() {
    local name="$1" force="${2:-0}" d p i
    d="$(fc_dir "$name")"
    [[ -r "$(fc_config "$name")" ]] || die "no config for '$name' — run create first"
    if p="$(_running_pid "$name")"; then
        die "'$name' is already running (pid $p)"
    fi

    verify_recorded_artifacts "$name" "$force"

    setsid firecracker --no-api --config-file "$(fc_config "$name")" \
        > "$(fc_log "$name")" 2>&1 < /dev/null &
    p=$!
    printf '%s\n' "$p" > "$(fc_pidfile "$name")"

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
    printf 'PASS: started %s (pid %s) — process confirmed running, not merely forked; console -> %s\n' \
        "$name" "$p" "$(fc_log "$name")"
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
    printf 'PASS: %s (pid %s) stopped — process confirmed gone, not merely signalled\n' "$name" "$p"
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
    printf 'config = "%s"\n' "$(fc_config "$name")"
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
    _digest_row kernel "$(sed -n 's/^kernel = "\(.*\)"$/\1/p' "$man")" \
                       "$(sed -n 's/^kernel_sha256 = "\(.*\)"$/\1/p' "$man")"
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

    local cfg="" name="" kernel="" rootfs="" memory="" vcpus="" tap="" mac="" ipaddr="" gw="" mask="" mmds="" append="" dry=0 json=0 lab="" force=0
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
    esac
    case "$verb" in
        start)   cmd_start   "$name" "$force"; return ;;
        stop)    cmd_stop    "$name" "$force"; return ;;
        destroy) cmd_destroy "$name" "$force"; return ;;
        inspect) cmd_inspect "$name"; return ;;
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

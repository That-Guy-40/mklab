#!/usr/bin/env bash
# lab-fc.sh — Phase 7: Firecracker microVMs.
#
# The tool that removes the typing slices 1–3 did by hand. It is a config generator and a
# process babysitter, and the most useful thing it does is TELL YOU WHAT IT DID: every field
# of the generated config.json carries a provenance tag, so "the tool started doing this for
# you silently" cannot happen quietly. See `create --dry-run`.
#
# ── USAGE ──
#   lab-fc.sh preflight --config <f.toml> | --name N --kernel K --rootfs R
#   lab-fc.sh create    ... [--dry-run]      # --dry-run prints config + PROVENANCE, writes nothing
#   lab-fc.sh start     <name>
#   lab-fc.sh stop      <name> [--force]
#   lab-fc.sh destroy   <name> [--force]
#   lab-fc.sh list      [--lab L] [--json]
#   lab-fc.sh inspect   <name> [--json]
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

fc_dir()      { printf '%s/%s' "$LAB_FC_STATE_DIR" "$1"; }
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
PROV=()
prov() { PROV+=("$1|$2|$3"); }   # tag | field | explanation

prov_table() {
    printf '\n  %-9s %-28s %s\n' "WHERE FROM" "FIELD = VALUE" "WHY"
    printf '  %-9s %-28s %s\n' "---------" "----------------------------" "---"
    local e tag field why
    for e in "${PROV[@]}"; do
        IFS='|' read -r tag field why <<<"$e"
        printf '  %-9s %-28s %s\n' "$tag" "$field" "$why"
    done
    printf '\n'
}

# ── a very small TOML reader: [[microvm]] blocks, key = value ───────────────
# Deliberately not a general TOML parser. It reads the subset slices 1-3 proved necessary,
# and refuses anything it does not understand rather than ignoring it -- a config key that
# is silently dropped is a field that "appears to work and does nothing".
readonly KNOWN_KEYS="name kernel rootfs memory vcpus tap mac ip gateway netmask mmds append lab"

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
            gsub(/^"|"$/,"",val); gsub(/[[:space:]]+$/,"",val)
            if (index(known, " " key " ") == 0) {
                printf("lab-fc.sh: unknown [[microvm]] key %s in %s\n", key, FILENAME) > "/dev/stderr"
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

mem_to_mib() {  # accepts 256, 256M, 1G  (Phase-2 spelling)
    local m="$1"
    case "$m" in
        *G|*g) printf '%s' $(( ${m%[Gg]} * 1024 )) ;;
        *M|*m) printf '%s' "${m%[Mm]}" ;;
        *)     printf '%s' "$m" ;;
    esac
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
    [[ "$name" =~ ^[a-z][a-z0-9-]{0,30}$ ]] \
        && pf_ok "name '$name' is a usable instance name" \
        || pf_fail "name '$name' must be lowercase alnum/dash starting with a letter"

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
            mac="$(printf '06:00:ac:47:%02x:%02x' \
                   $(( 0x$(printf '%s' "$name" | md5sum | cut -c1-2) )) \
                   $(( 0x$(printf '%s' "$name" | md5sum | cut -c3-4) )) )"
            prov DERIVED "guest_mac = $mac" "hashed from the instance name so it is stable across reruns"
        else
            prov YOURS "guest_mac = $mac" "as given"
        fi
        prov YOURS "host_dev_name = $tap" "the tap must already exist — this tool validates taps, never creates them"
        netblock=$(cat <<EOF

  "network-interfaces": [
    { "iface_id": "eth0", "host_dev_name": "$tap", "guest_mac": "$mac" }
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
    "kernel_image_path": "$kernel",
    "boot_args": "$args"
  },
  "drives": [
    { "drive_id": "rootfs", "path_on_host": "$rootfs",
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

    {
        printf 'name = "%s"\n' "$name"
        printf 'lab = "%s"\n'  "$(field "$rec" lab micro-cloud)"
        printf 'kernel = "%s"\n' "$(field "$rec" kernel)"
        printf 'rootfs = "%s"\n' "$(fc_rootfs "$name")"
        printf 'rootfs_source = "%s"\n' "$src"
        printf 'rootfs_source_sha256 = "%s"\n' "$(sha256sum "$src" | cut -d' ' -f1)"
        printf 'tap = "%s"\n'    "$(field "$rec" tap)"
        printf 'created = "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$(fc_manifest "$name")"
    printf '\nPASS: created %s\n' "$d"
    printf '      rootfs is a per-instance copy of %s (source sha recorded)\n' "$src"
}

cmd_start() {
    local name="$1" d; d="$(fc_dir "$name")"
    [[ -r "$(fc_config "$name")" ]] || die "no config for '$name' — run create first"
    if [[ -r "$(fc_pidfile "$name")" ]]; then
        local p; p="$(cat "$(fc_pidfile "$name")")"
        [[ "$p" =~ ^[0-9]+$ && -d "/proc/$p" ]] && die "'$name' is already running (pid $p)"
    fi
    setsid firecracker --no-api --config-file "$(fc_config "$name")" \
        > "$(fc_log "$name")" 2>&1 < /dev/null &
    printf '%s\n' "$!" > "$(fc_pidfile "$name")"
    printf 'PASS: started %s (pid %s), console -> %s\n' "$name" "$!" "$(fc_log "$name")"
}

# stop/destroy resolve to a PID and kill THAT. Never a pattern: the per-VM paths appear in
# firecracker's argv, so `pkill -f` matches the process it names AND any tooling whose
# command line mentions it -- which once killed a QEMU VM and the agent's own shell.
_kill_recorded() {
    local name="$1" sig="$2" pf p
    pf="$(fc_pidfile "$name")"; [[ -r "$pf" ]] || return 1
    p="$(cat "$pf" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    [[ -d "/proc/$p" ]] || return 1
    grep -qa firecracker "/proc/$p/cmdline" 2>/dev/null || return 1   # identity, not just liveness
    kill "-$sig" "$p" && printf '%s' "$p"
}

cmd_stop() {
    local name="$1" p i
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
        printf 'FAIL: %s (pid %s) ignored SIGTERM after 5s — still running. Use --force.\n' "$name" "$p" >&2
        return 1
    fi
    rm -f "$(fc_pidfile "$name")"
    printf 'PASS: %s (pid %s) stopped — process confirmed gone, not merely signalled\n' "$name" "$p"
}

cmd_destroy() {
    local name="$1" d; d="$(fc_dir "$name")"
    [[ -d "$d" ]] || die "no such instance: $name"
    _kill_recorded "$name" KILL >/dev/null || true
    rm -rf "$d"
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
        run=stopped
        local p pf="$d/fc.pid"
        if [[ -r "$pf" ]]; then p="$(cat "$pf")"; [[ "$p" =~ ^[0-9]+$ && -d "/proc/$p" ]] && run=running; fi
        if [[ "$json" == 1 ]]; then
            [[ "$first" == 1 ]] || printf ','; first=0
            printf '{"name":"%s","state":"%s"}' "$name" "$run"
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
}

# ── argument handling ───────────────────────────────────────────────────────
# Marker-delimited so edits to the header cannot silently shift what --help prints.
usage() { sed -n '/^# ── USAGE ──/,/^# ── END USAGE ──/p' "$0" | sed '1d;$d; s/^# \{0,1\}//'; exit 0; }

main() {
    local verb="${1:-}"; shift || true
    [[ -n "$verb" ]] || usage
    case "$verb" in help|-h|--help) usage ;; esac

    local cfg="" name="" kernel="" rootfs="" memory="" vcpus="" tap="" ipaddr="" gw="" mmds="" append="" dry=0 json=0 lab="" force=0
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
            --ip)      ipaddr="$2"; shift 2 ;;
            --gateway) gw="$2"; shift 2 ;;
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
    : "$force" "$lab"

    case "$verb" in
        list)    cmd_list "$json"; return ;;
        start)   cmd_start   "${positional[0]:?instance name required}"; return ;;
        stop)    cmd_stop    "${positional[0]:?instance name required}"; return ;;
        destroy) cmd_destroy "${positional[0]:?instance name required}"; return ;;
        inspect) cmd_inspect "${positional[0]:?instance name required}"; return ;;
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
        local r="name=$name;kernel=$kernel;rootfs=$rootfs;"
        [[ -n "$memory" ]] && r+="memory=$memory;"
        [[ -n "$vcpus"  ]] && r+="vcpus=$vcpus;"
        [[ -n "$tap"    ]] && r+="tap=$tap;"
        [[ -n "$ipaddr" ]] && r+="ip=$ipaddr;"
        [[ -n "$gw"     ]] && r+="gateway=$gw;"
        [[ -n "$append" ]] && r+="append=$append;"
        [[ -n "$mmds"   ]] && r+="mmds=$mmds;"
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

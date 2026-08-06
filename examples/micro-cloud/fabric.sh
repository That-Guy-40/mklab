#!/usr/bin/env bash
# fabric.sh — MICRO_CLOUD_LAB_PLAN.md §7: the micro-cloud network fabric. Slice 3.
#
#   sudo examples/micro-cloud/fabric.sh up          # bridge + nft + dnsmasq. Records what it found.
#   sudo examples/micro-cloud/fabric.sh tap <name>  # one addressless tap, enslaved, owned by the user
#        examples/micro-cloud/fabric.sh status      # unprivileged: what we own, and Calico's binding
#   sudo examples/micro-cloud/fabric.sh down        # reverse ONLY ours, assert absence, compare Calico
#
# ─────────────────────────────────────────────────────────────────────────────
# THIS FILE WAS ALMOST LOST, WHICH IS THE FIRST THING TO KNOW ABOUT IT.
#
# Written and exercised on 2026-08-02 (plan Appendix G) in a session scratchpad under
# /tmp. PR #129 landed the 307-line appendix ABOUT it without landing IT: §14 said the
# slice was done, §9.1 listed this file, and BOTH catalog gates were green — because
# neither checker has an opinion about a tool that does not exist.
#
# DEFERRED.md §17.0 (2026-08-03) made committing it the top item, and said the file was in
# `~/.local/state/lab-create/micro-cloud-s3/`. IT WAS NOT. That workdir holds the images,
# boot logs and configs; the scripts were in a /tmp scratchpad that had already been
# reaped. The only surviving copy was the session transcript, and this file was recovered
# from it on 2026-08-04 by replaying one Write and eleven Edits — each one's tool_result
# checked for is_error (an attempted call is not a successful one) and each old_string
# asserted unique before replacing. See plan §18.1.
#
# Two lessons, both the plan's own:
#   "merged, and CI is green" is a MECHANISM check; `git ls-files` is the outcome check.
#   A recovery plan naming a location nobody re-checked is itself a stale record.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE FOUR CONSTRAINTS THIS SCRIPT EXISTS TO HONOUR. Each was paid for.
#
# 1. THE BRIDGE MUST BE NAMED `br-*`.  Calico v3.28.1's first-found autodetection
#    excludes `^br-.*`. `br-mc0` is therefore structurally invisible to it. This is not
#    a style choice; renaming this bridge re-arms F.6.            (plan F.7.1 rule 1)
#
# 2. TAPS MUST CARRY NO IPv4 ADDRESS.  An addressless interface is never a first-found
#    candidate, whatever it is called. Slice 2's tap became one *only* because slice 2
#    had no bridge and the tap had to hold 10.71.0.1 itself — and it captured the live
#    cluster's VXLAN tunnel endpoint. The bridge holds the address here. (F.7.1 rule 2)
#
# 3. PRE-FLIGHT RECORDS CALICO'S BINDING; TEARDOWN COMPARES IT.  Non-negotiable, and
#    explicitly independent of rules 1 and 2: those are derived from ONE host at ONE
#    Calico version, and this assertion is the only reason F.6 was visible at all. It
#    costs nothing and does not depend on the rule being right.        (F.7.1 closing)
#
# 4. RECORD WHAT YOU CHANGED; REVERT ONLY THAT.  `net.ipv4.ip_forward` is already 1 on
#    this host because a live Kubernetes needs it. A teardown that reverts someone
#    else's global is not a cleanup, it is an outage.                      (§7.1 / §7.2)
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THE PRE-FLIGHT RECORDS THE WHOLE CANDIDATE SET, NOT JUST THE BINDING.
#
# NOTHING BELOW IS A CURRENT FACT. Both paragraphs are DATED OBSERVATIONS, kept because
# they are why the code has the shape it has. Calico's binding is DERIVED at every `up`
# and compared at every `down`; it is never read from a comment, a constant, or a doc.
#
#   [2026-08-02] Calico was bound to `incusbr0`, and `incusbr0` was DOWN and memberless —
#   that day's tools/lab-sweep.sh had removed the last Incus instances. The interface
#   Calico had chosen was no longer a valid candidate, so a re-detection would relocate
#   the node IP no matter who caused it. Had teardown recorded only "bound to incusbr0"
#   it would have reported a migration and implicated the fabric. Recording the whole
#   candidate set makes the true cause legible.
#
#   [2026-08-04] It relocated — and no lab caused it. A reboot left both container-engine
#   daemons inactive, so `incusbr0` and `lxdbr0` did not exist at all, and Calico selected
#   `enx00051b8eb138`: the PHYSICAL UPLINK, i.e. the very interface this script's
#   masquerade rule names in `oifname`. (The rules do not overlap — ours matches
#   `ip saddr 10.71.0.0/24` only — but it is the first time our rule set and the CNI's
#   endpoint have shared an interface.) See plan Appendix I.
#
#   This is exactly why the comparison is derived rather than constant: a version of this
#   script that had hard-coded `incusbr0` as the expected value — the obvious, correct-
#   looking thing to write on 2026-08-02 — would now blame the fabric for a reboot.
#
# AND THE TRIGGER IS NOT WHAT WE THOUGHT. Plan F.8 concluded that only a `calico-node`
# restart re-runs autodetection. Falsified 2026-08-04: `monitor-addresses/
# autodetection_methods.go:103` re-runs it EVERY 60 SECONDS for the process lifetime
# (`startup/` is a second caller). The exposure window is not "between restarts" — a lab
# that creates an interface is exposed for its whole run. Nothing in this script changes
# as a result; the pre-flight/teardown comparison already assumes the worst. What changes
# is that you should not believe you are safe merely because nothing restarted.
set -uo pipefail

BR=br-mc0                       # rule 1 — the name is load-bearing
NET=10.71.0.0/24
GW=10.71.0.1
# THE POOL IS OVERRIDABLE **SO IT CAN BE EXHAUSTED ON PURPOSE**, and for no other reason.
#
# §14's break pass for slice 3 lists "exhaust the DHCP pool" and G.9 deferred it because
# `.100–.200` is 101 leases — untractable to fill, so nobody ever watched this fabric run
# out. That deferral was then restated four times as "needs a host without a live cluster",
# which was never true of THIS scenario: exhausting our own dnsmasq's pool on our own bridge
# reaches nothing Calico owns. The only thing in the way was that these two lines were bare
# assignments (plan M.7). Now they are not, and `tests/test-dhcp-exhaustion.sh` fills a
# four-address pool in seconds.
#
# Keep the default. A narrow pool is a TEST fixture: shrink it for an experiment, never for
# a lab you intend to use, or the fourth instance you create will be refused by the guard in
# `tap` below — honestly, but refused.
DHCP_LO="${MC_DHCP_LO:-10.71.0.100}"
DHCP_HI="${MC_DHCP_HI:-10.71.0.200}"
DOMAIN=mc.lab
NFT_TABLE=mklab-mc              # OUR table. Teardown deletes this and nothing else.
STATE=/run/mklab-mc
# WHO OWNS THE TAPS. `${SUDO_USER:-sqs}` was wrong: run `sudo fabric.sh` from a ROOT
# shell and sudo sets SUDO_USER=root, so the tap is created owned by uid 0 and the
# unprivileged Firecracker that must open it gets EPERM from TUNSETIFF -- far from here,
# wearing someone else's clothes. Measured on mc-api2, 2026-08-02. Override with
# MC_OWNER=<user>; `tap` refuses outright rather than creating a tap nobody can use.
OWNER="${MC_OWNER:-${SUDO_USER:-}}"
ACTION="${1:-status}"

hr(){ printf '%s\n' "──────────────────────────────────────────────────────────────────────"; }
die(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
note(){ printf '  - %s\n' "$*"; }

# Validate the pool HERE — before any verb, so a malformed override is refused by this
# script rather than by dnsmasq halfway through `up`, with a bridge and an nft table
# already created. (A gate after the act is a post-mortem — the MAAS lesson, applied to
# our own new knob.) Both ends must sit in the same /24 as the gateway, because `tap`
# derives reservations by last octet and the fabric serves exactly one subnet.
#
# This block sits BELOW `die` on purpose. Written above it, every refusal printed
# `die: command not found` and then CARRIED ON — the bad range sailed past four gates
# into the rest of the script. A validator that cannot fail is worse than no validator,
# and it took one run to find out, which is why it was run rather than reasoned about.
GW_PREFIX="${GW%.*}"
for _v in DHCP_LO DHCP_HI; do
    _a="${!_v}"
    [[ "$_a" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$_v='$_a' is not an IPv4 address"
    [[ "${_a%.*}" == "$GW_PREFIX" ]] || die "$_v='$_a' is not in $GW_PREFIX.0/24 — the fabric serves one subnet, and 'tap' derives reservations inside it"
    (( ${_a##*.} >= 1 && ${_a##*.} <= 254 )) || die "$_v='$_a' has an unusable host octet"
done
(( ${DHCP_LO##*.} < ${DHCP_HI##*.} )) || die "MC_DHCP_LO ($DHCP_LO) must be below MC_DHCP_HI ($DHCP_HI)"
(( ${GW##*.} < ${DHCP_LO##*.} || ${GW##*.} > ${DHCP_HI##*.} )) \
    || die "the pool $DHCP_LO-$DHCP_HI contains the gateway $GW — dnsmasq would hand out the bridge's own address"
unset _v _a

# ── the observations pre-flight records and teardown compares ────────────────
calico_binding(){ ip -d link show vxlan.calico 2>/dev/null | grep -oE 'local [0-9.]+ dev [a-z0-9.-]+'; }
calico_veths(){   ip -o link show 2>/dev/null | grep -cE ': cali[0-9a-f]+@'; }

# Every interface scored against Calico v3.28.1's own exclusion list, extracted from the
# running binary (plan F.7). Recomputed live — a cached candidate set is exactly the
# stale-record bug this plan keeps finding.
CALICO_EXCLUDES='^br-|^cali|^cbr|^cni|^docker|^dummy|^flannel|^kube-ipvs|^lxcbr|^nodelocaldns|^podman|^tunl|^veth|^virbr'
candidate_set(){
    local i idx st a
    for i in $(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//'); do
        [[ "$i" == lo ]] && continue
        idx=$(cat "/sys/class/net/$i/ifindex" 2>/dev/null)
        st=$(cat "/sys/class/net/$i/operstate" 2>/dev/null)
        a=$(ip -4 -o addr show "$i" 2>/dev/null | awk '{print $4}' | head -1)
        # A candidate is: UP, has an IPv4, and matches no exclusion.
        if [[ "$st" == up && -n "$a" ]] && ! grep -qE "$CALICO_EXCLUDES" <<<"$i"; then
            printf '%s %s %s CANDIDATE\n' "$idx" "$i" "$a"
        fi
    done | sort -n
}

record(){ printf '%s\n' "$*" >> "$STATE/preflight"; }

# The guest MAC for an instance name.
#
# THIS FORMULA IS SHARED WITH `phase7-firecracker/lab-fc.sh` AND MUST NOT DRIFT. The fabric
# reserves a DHCP lease against a MAC; the VMM sets the MAC. If the two derive it differently
# the guest silently misses its reservation, takes a dynamic lease, and dnsmasq goes on
# answering the name with an address nothing holds — a record that outlives its subject, and
# invisible from either tool alone. They live in different phases and cannot share code, so
# `tests/test-fabric-mac-derivation.sh` asserts the two implementations still agree.
#
# 06:00:.. is a locally-administered unicast prefix; ac:47 is this lab's tag.
mac_for_name() {
    local n="$1" h
    h="$(printf '%s' "$n" | md5sum)" || return 1
    printf '06:00:ac:47:%02x:%02x' $(( 0x${h:0:2} )) $(( 0x${h:2:2} ))
}

# Create ONE tap and prove it is USABLE, or leave nothing behind. Both properties are read
# back from the kernel afterwards, because `ip tuntap add` exiting 0 establishes neither:
#   - the outcome that matters is the TUNSETIFF ioctl the VMM will later issue (P2 /
#     Appendix B) -- a root-owned tap passes every check here and fails there, with EPERM,
#     far away and wearing someone else's clothes. Measured on mc-api2, 2026-08-02.
#   - an IPv4 on the tap makes it a Calico first-found candidate. That is the F.6 mechanism.
# Either failure DELETES the tap: a half-made device that nobody refuses is worse than none.
make_tap() {
    local tap="$1" got
    ip tuntap add dev "$tap" mode tap user "$OWNER" || die "tap create failed"
    ip link set "$tap" master "$BR" || { ip link del "$tap"; die "enslave to $BR failed"; }
    ip link set "$tap" up           || { ip link del "$tap"; die "tap up failed"; }
    # NOT `ip ... | grep -q inet`: grep -q exits on first match and closes the pipe, ip can
    # die on SIGPIPE, and under `pipefail` the pipeline then reports FAILURE -- so an `if`
    # around it reads false and a tap WITH an address passes the check written to catch
    # exactly that. Capture first, test second.
    local addrs; addrs="$(ip -4 -o addr show "$tap" 2>/dev/null)"
    if [[ "$addrs" == *inet* ]]; then
        ip link del "$tap"
        die "REGRESSION: $tap acquired an IPv4 address — that makes it a Calico first-found candidate (F.7.1 rule 2, the F.6 mechanism)"
    fi
    got="$(cat "/sys/class/net/$tap/owner" 2>/dev/null)"
    if [[ "$got" != "$OWNER_UID" ]]; then
        ip link del "$tap"
        die "REGRESSION: $tap owner uid is '${got:-<unset>}', expected $OWNER_UID ($OWNER) — an unprivileged Firecracker would get EPERM from TUNSETIFF"
    fi
}

case "$ACTION" in
status)
    hr; echo "OURS"
    if ip link show "$BR" >/dev/null 2>&1; then
        ip -o link show "$BR" | sed 's/\\.*//; s/^/  /'
        ip -4 -o addr show "$BR" | sed 's/^/  /'
        echo "  members: $(ls "/sys/class/net/$BR/brif/" 2>/dev/null | tr '\n' ' ')"
    else
        echo "  $BR absent — fabric is down"
    fi
    if [[ -r "$STATE/preflight" ]]; then
        echo; echo "  recorded at up:"; sed 's/^/    /' "$STATE/preflight"
    fi
    hr; echo "THEIRS (compare against the recorded values above)"
    echo "  calico tunnel : $(calico_binding || echo '<absent>')"
    echo "  cali* veths   : $(calico_veths)"
    echo "  ip_forward    : $(cat /proc/sys/net/ipv4/ip_forward)"
    echo "  candidate set :"; candidate_set | sed 's/^/    /'
    hr
    exit 0 ;;
mac)
    # Read-only, unprivileged, machine-readable: the ONE question a consumer has to ask
    # before it can boot a guest onto this fabric. Without it, a spec file has to guess the
    # MAC — and a guess that is wrong fails silently, as a dynamic lease.
    NAME="${2:-}"
    [[ -n "$NAME" ]] || die "usage: $0 mac <name>"
    [[ "$NAME" =~ ^[a-z][a-z0-9-]{0,10}$ ]] || die "name must be lowercase alnum/dash, <=11 chars"
    mac_for_name "$NAME" || die "could not derive a MAC for '$NAME' (is md5sum present?)"
    printf '\n'
    exit 0 ;;
up|down|tap|retap) [[ $EUID -eq 0 ]] || die "must run as root (bridge/nft/dnsmasq are CAP_NET_ADMIN)" ;;
*) die "usage: $0 [up|tap <name>|retap <name>|mac <name>|status|down]" ;;
esac

# Gate the owner ONCE, for every verb that creates a tap. A tap owned by root cannot be
# opened by the unprivileged VMM this whole design rests on, so this is a refusal, not a
# warning -- and it fires BEFORE the device exists (a gate after the act is a post-mortem).
if [[ "$ACTION" == tap || "$ACTION" == retap ]]; then
    [[ -n "$OWNER" ]] || die "cannot determine the tap owner (no SUDO_USER) — re-run as: MC_OWNER=<user> $0 $ACTION ..."
    [[ "$OWNER" != root ]] || die "refusing to create a root-owned tap: Firecracker runs unprivileged and TUNSETIFF would return EPERM. Re-run as: MC_OWNER=<user> $0 $ACTION ${2:-<name>}"
    OWNER_UID="$(id -u "$OWNER" 2>/dev/null)" || die "no such user: $OWNER"
fi

case "$ACTION" in
# ═══════════════════════════════════════════════════════════════════════════
up)
    # ── refuse BEFORE the irreversible step (MAAS's lesson: a gate after the act
    #    is a post-mortem, not a gate) ────────────────────────────────────────
    ip link show "$BR" >/dev/null 2>&1 && die "$BR already exists — refusing to adopt an interface we may not own"
    [[ -e "$STATE/preflight" ]] && die "$STATE/preflight exists — a previous 'up' was never torn down; run 'down' first"
    if ip -4 route show | grep -q '10\.71\.0\.'; then
        ip -4 route show | grep '10\.71\.0\.' >&2
        die "something already routes $NET — P1 verified it free; re-check before proceeding"
    fi
    nft list table ip "$NFT_TABLE" >/dev/null 2>&1 && die "nft table ip $NFT_TABLE already exists — refusing to merge into it"
    command -v dnsmasq >/dev/null || die "dnsmasq not installed"
    UPLINK="$(ip -4 route show default | awk '{print $5; exit}')"
    [[ -n "$UPLINK" ]] || die "no default route — cannot determine the masquerade uplink"

    mkdir -p "$STATE"; : > "$STATE/preflight"

    # ── constraint 3 + the candidate-set rationale above ────────────────────
    hr; echo "1. PRE-FLIGHT — recording what we found, so teardown can prove we gave it back"
    FWD_BEFORE="$(cat /proc/sys/net/ipv4/ip_forward)"
    CAL_BEFORE="$(calico_binding)"
    VETH_BEFORE="$(calico_veths)"
    record "uplink=$UPLINK"
    record "ip_forward_before=$FWD_BEFORE"
    record "calico_binding=${CAL_BEFORE:-<absent>}"
    record "calico_veths=$VETH_BEFORE"
    record "candidates_before<<"
    candidate_set >> "$STATE/preflight"
    record ">>"
    # The FORWARD hook as it stands BEFORE we add anything. `br_netfilter` is active with
    # bridge-nf-call-iptables=1 (measured), so api1<->api2 on one bridge is filtered rather
    # than switched in L2 -- these chains are what our packets must survive. Both policies
    # measured `accept`, which is why §7's own-table design is sufficient and we insert
    # nothing into a chain someone else owns. Recorded because if the ping later fails,
    # this is the first thing to diff, and it is unreadable after the fact from a shell
    # that cannot sudo.
    record "forward_surface<<"
    { nft list chain ip filter FORWARD 2>/dev/null
      echo "--- legacy xtables (a SEPARATE subsystem at the same hook) ---"
      iptables-legacy -S FORWARD 2>/dev/null
    } >> "$STATE/preflight"
    record ">>"
    note "uplink            : $UPLINK"
    note "ip_forward        : $FWD_BEFORE"
    note "calico tunnel     : ${CAL_BEFORE:-<absent>}"
    note "cali* veths (pods): $VETH_BEFORE"
    echo "  - candidate set   :"; candidate_set | sed 's/^/      /'
    # Attribute the hazard now, while it is cheap, rather than after a migration.
    if [[ -n "$CAL_BEFORE" ]]; then
        cal_if="${CAL_BEFORE##*dev }"
        cal_st="$(cat "/sys/class/net/$cal_if/operstate" 2>/dev/null)"
        if [[ "$cal_st" != up ]]; then
            echo "  - ⚠ NOTE, not caused by us: Calico is bound to '$cal_if', which is currently"
            echo "      '$cal_st'. Autodetection re-runs every 60s (plan I.4), so the node IP can"
            echo "      relocate at any moment, with or without a restart and whoever triggers it."
            echo "      Recorded so teardown does not misattribute that to the fabric."
            record "hazard_preexisting=calico bound to $cal_if which is $cal_st"
        fi
    fi

    # ── the bridge. Rule 1: the name is the safety property. ────────────────
    hr; echo "2. Bridge — named '$BR' so Calico's ^br-.* exclusion covers it (rule 1)"
    ip link add "$BR" type bridge      || die "bridge create failed"
    ip addr add "$GW/24" dev "$BR"     || die "address add failed"
    ip link set "$BR" up               || die "bridge up failed"
    record "created_bridge=$BR"
    ip -o link show "$BR" | sed 's/\\.*//; s/^/  /'

    # ── constraint 4: record, then change only if needed ────────────────────
    hr; echo "3. ip_forward — change only if it is not already what we need (rule 4)"
    if [[ "$FWD_BEFORE" == 1 ]]; then
        note "already 1 (a live Kubernetes depends on it) — NOT touched, so never reverted"
        record "we_set_ip_forward=no"
    else
        echo 1 > /proc/sys/net/ipv4/ip_forward
        note "was 0, set to 1 — recorded, and teardown will put it back"
        record "we_set_ip_forward=yes"
    fi

    # ── additive nft, scoped by iifname so hook order never matters (§7.1 c2 / B.1)
    hr; echo "4. nftables — our own table '$NFT_TABLE', scoped by iifname"
    nft -f - <<EOF || die "nft load failed"
table ip $NFT_TABLE {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr $NET ip daddr != $NET oifname "$UPLINK" masquerade
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
        iifname "$BR" oifname "$UPLINK" accept
        iifname "$UPLINK" oifname "$BR" ct state established,related accept
        iifname "$BR" oifname "$BR" accept
    }
}
EOF
    record "created_nft_table=$NFT_TABLE"
    note "every rule names an interface — Docker's, libvirt's and LXD's chains at the"
    note "same hooks are untouched, and hook priority ordering cannot change our meaning"

    # ── dnsmasq: DHCP *and* DNS, bound to this bridge only ──────────────────
    hr; echo "5. dnsmasq — DHCP + DNS for $DOMAIN, bound to $BR only"
    : > "$STATE/dhcp-hosts"; : > "$STATE/hosts"; : > "$STATE/leases"
    dnsmasq \
        --conf-file=/dev/null \
        --pid-file="$STATE/dnsmasq.pid" \
        --interface="$BR" --bind-interfaces --except-interface=lo \
        --listen-address="$GW" \
        --dhcp-range="$DHCP_LO,$DHCP_HI,12h" \
        --dhcp-option=option:router,"$GW" \
        --dhcp-option=option:dns-server,"$GW" \
        --dhcp-hostsfile="$STATE/dhcp-hosts" \
        --dhcp-leasefile="$STATE/leases" \
        --addn-hosts="$STATE/hosts" \
        --domain="$DOMAIN" --local=/"$DOMAIN"/ --expand-hosts --no-hosts \
        --domain-needed --bogus-priv \
        --log-facility="$STATE/dnsmasq.log" --log-dhcp \
        || die "dnsmasq failed to start"
    sleep 1
    DPID="$(cat "$STATE/dnsmasq.pid" 2>/dev/null)"
    [[ -n "$DPID" && -d "/proc/$DPID" ]] || die "dnsmasq wrote no usable pid file"
    # Bind the PID to its subject: teardown verifies this before signalling anything.
    grep -qa -- "--pid-file=$STATE/dnsmasq.pid" "/proc/$DPID/cmdline" \
        || die "pid $DPID does not look like our dnsmasq — refusing to record it"
    record "dnsmasq_pid=$DPID"
    note "pid $DPID, verified by its own cmdline (kill by PID, never by pattern)"
    note "listening on $GW:53 only — systemd-resolved (127.0.0.53) and libvirt's"
    note "dnsmasq (192.168.122.1) are untouched"

    hr; echo "PASS: fabric up. Add taps with:  sudo bash $0 tap <name>"
    ;;

# ═══════════════════════════════════════════════════════════════════════════
tap)
    NAME="${2:-}"
    [[ -n "$NAME" ]] || die "usage: $0 tap <name>"
    [[ "$NAME" =~ ^[a-z][a-z0-9-]{0,10}$ ]] || die "name must be lowercase alnum/dash, <=11 chars"
    ip link show "$BR" >/dev/null 2>&1 || die "$BR absent — run '$0 up' first"
    TAP="mc-$NAME"
    ip link show "$TAP" >/dev/null 2>&1 && die "$TAP already exists"

    # ── the MAC is derived FROM THE NAME, and that is load-bearing ──────────
    # It used to be derived from the LINE COUNT of dhcp-hosts — i.e. from the order taps
    # happen to be created — while the comment right here claimed it came from the name.
    # Two things were wrong with that, and the second is worse:
    #
    #   1. `api1` was 10.71.0.101 only because it was always created first. Bring up a
    #      subset, or add an instance ahead of it, and every name shifts. Anything that
    #      wrote an address down became a record that outlives its subject.
    #   2. `lab-fc.sh` — the slice-4 tool that is supposed to CONSUME these taps — already
    #      derives its guest MAC as md5(name), and has done since slice 4. For `api1` that
    #      is 06:00:ac:47:f1:f7, against the 06:00:ac:47:00:01 reserved here. THE TWO
    #      COMMITTED TOOLS COULD NEVER AGREE: a microVM created by `lab-fc.sh` on a tap made
    #      here would miss its reservation, take a dynamic lease, and leave dnsmasq still
    #      answering `api1` with an address nothing holds. Slices 1-3 and 5a never hit it
    #      because they hand-wrote the config with the positional MAC; lab-fc.sh had never
    #      been pointed at a fabric tap.
    #
    # So: same formula as lab-fc.sh, keyed on the name, order-independent by construction.
    # `tests/test-fabric-mac-derivation.sh` asserts the two implementations still agree —
    # they live in different phases and cannot share code, so the agreement is a TEST, not
    # a hope.
    MAC="$(mac_for_name "$NAME")"

    # The ADDRESS stays first-come, and is deliberately not derived from the name: a hash
    # into a /24 collides, and a collision here is two guests fighting over one lease. It is
    # recorded in dhcp-hosts and served by DHCP, so nothing needs to predict it —
    # **the NAME is the contract, never the address.** If a spec, doc or test hard-codes
    # 10.71.0.10x it is asserting something this fabric does not promise.
    #
    # NOT `$(grep -c . f || echo 0)` — on an empty file grep prints 0 AND exits 1, so the
    # fallback appends a second 0 and the arithmetic below dies. House gotcha, cost real time.
    if grep -q ",$NAME\$" "$STATE/dhcp-hosts" 2>/dev/null; then
        die "$NAME already has a reservation: $(grep ",$NAME\$" "$STATE/dhcp-hosts") — use 'retap' to rebuild its tap"
    fi
    n=0; [[ -r "$STATE/dhcp-hosts" ]] && n="$(wc -l < "$STATE/dhcp-hosts")"
    IDX=$(( n + 1 ))
    # DERIVED from DHCP_LO, not from the constant 100 it used to be. The old line read
    # `IP="10.71.0.$((100 + IDX))"` — correct only while the pool started at .100, and
    # silently wrong the moment it did not: reservations would march out of the range and
    # dnsmasq would serve addresses it had not been told to manage. The first offset stays
    # +1, so the bottom of the pool (DHCP_LO itself) remains dynamic exactly as before.
    LO_OCT="${DHCP_LO##*.}"; HI_OCT="${DHCP_HI##*.}"
    OCT=$(( LO_OCT + IDX ))
    # Pool exhaustion at RESERVATION time — refused BEFORE the tap exists, so there is no
    # half-made instance to clean up. This is the honest end of §14's break-pass scenario:
    # the fabric runs out and SAYS SO, naming the pool, rather than handing out an address
    # outside the range that dnsmasq will never answer for.
    (( OCT <= HI_OCT )) \
        || die "DHCP pool exhausted: $((HI_OCT - LO_OCT)) reservable addresses in $DHCP_LO-$DHCP_HI, and $n are already taken. '$NAME' cannot be given one. Widen the pool (MC_DHCP_LO/MC_DHCP_HI) or 'down' the fabric."
    IP="${DHCP_LO%.*}.$OCT"

    make_tap "$TAP"

    printf '%s,%s,%s\n' "$MAC" "$IP" "$NAME" >> "$STATE/dhcp-hosts"
    printf '%s %s\n'    "$IP" "$NAME"        >> "$STATE/hosts"
    DPID="$(sed -n 's/^dnsmasq_pid=//p' "$STATE/preflight")"
    if [[ -n "$DPID" && -d "/proc/$DPID" ]] && grep -qa -- "--pid-file=$STATE/dnsmasq.pid" "/proc/$DPID/cmdline"; then
        kill -HUP "$DPID"          # re-reads dhcp-hostsfile + addn-hosts
        note "dnsmasq $DPID re-read its host files (SIGHUP)"
    else
        die "dnsmasq pid $DPID is gone or is not ours — refusing to signal it"
    fi
    record "created_tap=$TAP"

    hr
    echo "  tap    : $TAP  (owner $OWNER — Firecracker opens it unprivileged via TUNSETIFF)"
    echo "  mac    : $MAC"
    echo "  address: $IP   served by DHCP, resolvable as $NAME.$DOMAIN"
    echo "  ipv4 on the tap itself: none — asserted, not assumed (rule 2)"
    echo "  owner uid $OWNER_UID  — asserted from /sys/class/net/$TAP/owner, not from this echo"
    hr; echo "PASS: $TAP ready"
    ;;

# ═══════════════════════════════════════════════════════════════════════════
# Repair a tap that exists but is unusable (wrong owner). Deliberately does NOT touch
# dhcp-hosts/hosts: the guest's MAC is set by the VMM's config, not by the host tap, so
# the DHCP reservation stays valid across a recreate. Re-appending would hand the guest a
# second, different address and break the name it is meant to answer to.
retap)
    NAME="${2:-}"
    [[ -n "$NAME" ]] || die "usage: $0 retap <name>"
    TAP="mc-$NAME"
    ip link show "$BR" >/dev/null 2>&1 || die "$BR absent — run '$0 up' first"
    grep -q ",$NAME\$" "$STATE/dhcp-hosts" 2>/dev/null \
        || die "$NAME has no dhcp-hosts entry — use '$0 tap $NAME' to create it"
    if ip link show "$TAP" >/dev/null 2>&1; then
        old="$(cat "/sys/class/net/$TAP/owner" 2>/dev/null)"
        ip link del "$TAP" || die "could not delete $TAP"
        note "deleted $TAP (owner uid was ${old:-<unset>})"
    fi
    make_tap "$TAP"
    hr
    echo "  tap    : $TAP  recreated, owner uid $OWNER_UID ($OWNER)"
    echo "  dhcp   : $(grep ",$NAME\$" "$STATE/dhcp-hosts") — unchanged, reservation still valid"
    echo "  ipv4 on the tap itself: none — asserted (rule 2)"
    hr; echo "PASS: $TAP repaired"
    ;;

# ═══════════════════════════════════════════════════════════════════════════
down)
    [[ -r "$STATE/preflight" ]] || die "no $STATE/preflight — nothing recorded, so nothing can be safely reverted"
    UPLINK="$(sed -n 's/^uplink=//p' "$STATE/preflight")"
    FWD_BEFORE="$(sed -n 's/^ip_forward_before=//p' "$STATE/preflight")"
    WE_SET_FWD="$(sed -n 's/^we_set_ip_forward=//p' "$STATE/preflight")"
    CAL_BEFORE="$(sed -n 's/^calico_binding=//p' "$STATE/preflight")"
    VETH_BEFORE="$(sed -n 's/^calico_veths=//p' "$STATE/preflight")"
    DPID="$(sed -n 's/^dnsmasq_pid=//p' "$STATE/preflight")"

    hr; echo "1. Reverse ONLY what the record says we created"
    if [[ -n "$DPID" ]]; then
        if [[ -d "/proc/$DPID" ]] && grep -qa -- "--pid-file=$STATE/dnsmasq.pid" "/proc/$DPID/cmdline"; then
            kill "$DPID"; sleep 1
            note "dnsmasq $DPID killed by PID after verifying its cmdline"
        else
            note "dnsmasq $DPID already gone (or not ours) — not signalled"
        fi
    fi
    while read -r t; do
        [[ -n "$t" ]] || continue
        ip link del "$t" 2>/dev/null && note "deleted tap $t" || note "tap $t already absent"
    done < <(sed -n 's/^created_tap=//p' "$STATE/preflight")
    nft list table ip "$NFT_TABLE" >/dev/null 2>&1 && { nft delete table ip "$NFT_TABLE" && note "deleted nft table $NFT_TABLE"; }
    ip link show "$BR" >/dev/null 2>&1 && { ip link del "$BR" && note "deleted bridge $BR"; }
    if [[ "$WE_SET_FWD" == yes ]]; then
        echo "$FWD_BEFORE" > /proc/sys/net/ipv4/ip_forward
        note "ip_forward restored to $FWD_BEFORE (we had set it)"
    else
        note "ip_forward not touched at up, so not touched now (still $(cat /proc/sys/net/ipv4/ip_forward))"
    fi

    # ── teardown is a test (§7.2). Assert absence of ours; compare theirs. ──
    hr; echo "2. ASSERTIONS — ours gone"
    rc=0
    if ip link show "$BR" >/dev/null 2>&1; then echo "  FAIL: $BR survived teardown"; rc=1
    else echo "  ok: $BR absent"; fi
    leftover="$(ip -o link show | grep -oE 'mc-[a-z0-9-]+' | sort -u | tr '\n' ' ')"
    if [[ -n "$leftover" ]]; then echo "  FAIL: mc-* taps survived: $leftover"; rc=1
    else echo "  ok: no mc-* taps left"; fi
    if nft list table ip "$NFT_TABLE" >/dev/null 2>&1; then echo "  FAIL: nft table $NFT_TABLE survived"; rc=1
    else echo "  ok: nft table $NFT_TABLE absent"; fi
    if ip -4 route show | grep -q '10\.71\.0\.'; then echo "  FAIL: a $NET route survived"; rc=1
    else echo "  ok: no $NET route left behind"; fi
    if [[ -n "$DPID" && -d "/proc/$DPID" ]]; then echo "  FAIL: dnsmasq $DPID still running"; rc=1
    else echo "  ok: our dnsmasq is gone"; fi

    hr; echo "3. COMPARISON — theirs unchanged (constraint 3: the assertion that caught F.6)"
    CAL_AFTER="$(calico_binding)"; VETH_AFTER="$(calico_veths)"
    if [[ "${CAL_AFTER:-<absent>}" == "$CAL_BEFORE" ]]; then
        echo "  ok: calico tunnel unchanged (${CAL_AFTER:-<absent>})"
    else
        echo "  FAIL: calico tunnel MOVED: '$CAL_BEFORE' -> '${CAL_AFTER:-<absent>}'"
        echo "        candidate set at up:"; sed -n '/^candidates_before<</,/^>>/p' "$STATE/preflight" | grep -vE '^(candidates_before<<|>>)$' | sed 's/^/          /'
        echo "        candidate set now :"; candidate_set | sed 's/^/          /'
        echo "        ^ compare these two before blaming the fabric — see the pre-existing"
        echo "          hazard note in $STATE/preflight, if one was recorded."
        rc=1
    fi
    if [[ "$VETH_AFTER" == "$VETH_BEFORE" ]]; then
        echo "  ok: cali* veth count unchanged ($VETH_AFTER) — pods were not recreated"
    else
        echo "  FAIL: cali* veth count moved $VETH_BEFORE -> $VETH_AFTER — pods were recreated"
        rc=1
    fi
    now_fwd="$(cat /proc/sys/net/ipv4/ip_forward)"
    if [[ "$now_fwd" == "$FWD_BEFORE" ]]; then echo "  ok: ip_forward back at $now_fwd"
    else echo "  FAIL: ip_forward $FWD_BEFORE -> $now_fwd"; rc=1; fi

    hr
    if [[ "$rc" -eq 0 ]]; then
        rm -f "$STATE/preflight" "$STATE/dhcp-hosts" "$STATE/hosts" "$STATE/leases" "$STATE/dnsmasq.pid"
        echo "PASS: teardown left nothing of ours and nothing of theirs"
    else
        echo "FAIL: teardown assertions failed — $STATE/preflight KEPT for diagnosis"
        exit 1
    fi
    ;;
esac

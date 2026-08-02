#!/usr/bin/env bash
# micro-cloud-fabric-probe.sh — MICRO-CLOUD slice-3 firewall-placement probe. READ-ONLY.
#
#   usage:  sudo tools/micro-cloud-fabric-probe.sh
#   exits:  0 always — this is an instrument, not a gate. Read section 6's VERDICT.
#
# Answers the one question that decides WHERE slice 3's firewall rules have to live, before
# any interface exists. Changes nothing, starts nothing, needs no cleanup. Third in the
# family after tools/micro-cloud-preflight.sh (P1) and -p2.sh; results land in
# MICRO_CLOUD_LAB_PLAN.md Appendix G.2 as a dated measurement.
#
# THE QUESTION. `br_netfilter` is active on this host with `bridge-nf-call-iptables=1`,
# so traffic between two ports of the SAME bridge is handed to the FORWARD hook instead
# of being switched silently in L2. Slice 3's exercise is `api1` pinging `api2` — both on
# `br-mc0` — so if any chain at that hook drops it, the exercise fails and §7's "our own
# additive table" design is not sufficient on its own.
#
# A chain's `policy drop` only bites packets that reach the end of THAT chain without a
# verdict; but in netfilter a DROP anywhere at a hook wins over an ACCEPT elsewhere. So a
# separate table with `policy accept` cannot rescue a packet that Docker's FORWARD chain
# drops. That is why this has to be measured before `fabric.sh up`, not after.
#
# AND IT MUST BE ASKED OF BOTH BACKENDS. nft and legacy xtables are separate subsystems
# at the same hooks; `nft list ruleset` cannot see legacy rules, and `iptables-save` is
# nft-backed here so it is not a second opinion either.
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "FAIL: must run as root (rulesets are root-readable only)" >&2; exit 1; }

hr(){ printf '%s\n' "──────────────────────────────────────────────────────────────────────"; }

hr; echo "1. Does bridge traffic even reach the FORWARD hook?"
# ASSERT THE OUTCOME, NOT THE MECHANISM. The first version of this asked `lsmod | grep -q`
# and printed "no" on a host where br_netfilter was demonstrably Live. Cause: `grep -q`
# exits on first match and closes the pipe, `lsmod` dies on SIGPIPE, and `pipefail` then
# reports the PIPELINE as failed -- so `&& echo yes` never fired. A check that reports the
# opposite of the truth is worse than no check, hence: read the state directly.
# The sysctl nodes below exist ONLY when br_netfilter is present, so their existence IS
# the property, and no pipeline stands between the question and the answer.
SYSCTL=/proc/sys/net/bridge/bridge-nf-call-iptables
if [[ -r "$SYSCTL" ]]; then
    printf '  %-24s : present (br_netfilter is active)\n' "$(basename "$(dirname "$SYSCTL")")/"
    printf '  bridge-nf-call-iptables  : %s\n' "$(cat "$SYSCTL")"
    [[ "$(cat "$SYSCTL")" == 1 ]] \
        && echo "  -> YES: api1<->api2 on one bridge IS filtered. Section 6 decides the design." \
        || echo "  -> NO: intra-bridge traffic is switched in L2 and never sees FORWARD."
else
    echo "  $SYSCTL absent -> br_netfilter not active; intra-bridge traffic is not filtered"
fi
printf '  (corroboration) /proc/modules: %s\n' "$(awk '/^br_netfilter /{print $1, $NF}' /proc/modules 2>/dev/null || echo '<not a module -- may be builtin>')"

hr; echo "2. nftables — every chain registered at the forward hook, with its policy"
nft list ruleset 2>/dev/null \
  | awk '/^table /{t=$0} /hook forward/{print "  " t "  ->  " $0}' \
  || echo "  (nft produced nothing)"
echo
echo "  full table list:"
nft list tables 2>/dev/null | sed 's/^/    /' || echo "    (none)"

hr; echo "3. legacy xtables — the SEPARATE subsystem nft cannot see"
if command -v iptables-legacy >/dev/null 2>&1; then
    printf '  FORWARD policy : %s\n' "$(iptables-legacy -S FORWARD 2>/dev/null | head -1)"
    printf '  FORWARD rules  : %s\n' "$(iptables-legacy -S FORWARD 2>/dev/null | grep -c '^-A' || true)"
    printf '  total rules    : %s\n' "$(iptables-legacy-save 2>/dev/null | grep -c '^-A' || true)"
else
    echo "  iptables-legacy not installed — nothing can be hiding there"
fi

hr; echo "4. nft filter FORWARD in detail — the chain a new bridge must survive"
nft -a list chain ip filter FORWARD 2>/dev/null | sed 's/^/  /' || echo "  (no ip filter FORWARD chain)"

hr; echo "5. THE MODEL TO COPY — how the bridges that already work got permission"
for b in virbr0 lxdbr0 incusbr0 docker0; do
    hits="$(nft list ruleset 2>/dev/null | grep -c "\"$b\"" || true)"
    printf '  %-10s referenced in %s nft rule(s)\n' "$b" "$hits"
done
echo
echo "  libvirt's rules for virbr0 (the clearest exemplar of an additive, per-bridge grant):"
nft list ruleset 2>/dev/null | grep -nE '"virbr0"' | head -8 | sed 's/^/    /' || echo "    (none)"
echo
echo "  LXD's per-bridge chain layout (plan B.1 names this as the shape to imitate):"
nft list table inet lxd 2>/dev/null | sed 's/^/    /' | head -25 || echo "    (no inet lxd table)"

hr; echo "6. Would a packet br-mc0 -> br-mc0 be dropped? (static read of the policies)"
verdict=UNKNOWN
nftpol="$(nft list chain ip filter FORWARD 2>/dev/null | grep -oE 'policy [a-z]+' | head -1)"
legpol="$(iptables-legacy -S FORWARD 2>/dev/null | grep -oE '^-P FORWARD [A-Z]+' | awk '{print $3}')"
printf '  nft   ip filter FORWARD policy : %s\n' "${nftpol:-<no such chain>}"
printf '  legacy       FORWARD policy    : %s\n' "${legpol:-<no legacy chain>}"
if [[ "$nftpol" == "policy drop" || "$legpol" == "DROP" ]]; then
    verdict="RULES REQUIRED in the shared FORWARD chain"
elif [[ -z "$nftpol" && -z "$legpol" ]]; then
    verdict="no FORWARD chain at all — our own table suffices"
else
    verdict="policies are accept — our own additive table suffices, BUT see any explicit drop rules above"
fi
echo
echo "  VERDICT: $verdict"
echo
echo "  NOTE: this is a static read of chain POLICIES. An explicit '-A FORWARD ... -j DROP'"
echo "  or an nft 'drop' rule can still bite regardless of policy; sections 2-4 above are"
echo "  where such a rule would show. The live test is slice 3's ping itself."
hr
echo "Nothing was modified by this probe."

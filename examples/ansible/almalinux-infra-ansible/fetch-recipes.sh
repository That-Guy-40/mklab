#!/usr/bin/env bash
# fetch-recipes.sh — Stage the AlmaLinux infra-ansible recipe catalog + the lab
#                    control-node workdir for the LXD Ansible lab.
#
# Upstream: https://github.com/AlmaLinux/infra-ansible
#   AlmaLinux's production infrastructure playbooks — a curated set of roles
#   (common, gitea, keycloak, mattermost, matrix_synapse, mirror, mqtt, …) plus
#   the top-level *.yml playbooks that compose them.
#
# This assembles a self-contained control-node workdir (default ~/ansible-lab),
# mounted into the control container at /lab by the lab TOML:
#
#   <out>/raw/            verbatim clone of infra-ansible (reference; untouched)
#   <out>/infra-ansible/  lab-PATCHED clone: roles untouched, but the top-level
#                         playbooks have their AlmaLinux-only roles commented out
#                         (see "Why patch").  roles_path points here.
#   <out>/ansible.cfg, inventory.ini, group_vars/, lab-playbooks/
#                         the lab overlay (copied from this lab's control-files/)
#   <out>/ssh/id_ed25519  a throwaway lab keypair (control→target SSH)
#
# ─── Why patch (and why so little) ───────────────────────────────────────────
# The roles themselves run fine against a vanilla AlmaLinux host.  What doesn't
# is the *playbook* role lists: every play also pulls in roles that need
# AlmaLinux's real infra — community.zabbix.zabbix_agent (a Zabbix server),
# devsec.hardening.* (would also lock down SSH mid-lab), ipa_client (FreeIPA),
# hashivault (Vault), artis3n.tailscale, almalinux.wazuh.  The patch comments
# *only* those role lines, leaving `common` + the service role intact.  Roles
# are never touched; the verbatim upstream is kept under raw/.  --verbatim skips
# patching entirely.
#
# NOTE: the lab RUNS recipes via the thin lab-playbooks/ (hosts: lab), which
# apply the untouched upstream roles to the lab target.  The patched playbooks
# are staged as a curated reference + for advanced use against your own hosts.
#
# Usage:
#   examples/ansible/almalinux-infra-ansible/fetch-recipes.sh [OPTIONS]
#
# Options:
#   --out      <dir>   control-node workdir (default: ~/ansible-lab)
#   --ref      <ref>   git branch/tag to clone (default: upstream default branch)
#   --verbatim         do NOT patch the playbooks — stage upstream unchanged
#   --help             show this help and exit

set -euo pipefail

readonly LAB_PROG="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly UPSTREAM="https://github.com/AlmaLinux/infra-ansible.git"

_log() {
    local level="$1"; shift
    local color="" reset=""
    if [[ -t 2 ]]; then
        case "$level" in info) color=$'\033[36m';; warn) color=$'\033[33m';;
            error) color=$'\033[31m';; ok) color=$'\033[32m';; esac
        reset=$'\033[0m'
    fi
    printf '%s[%s]%s %s\n' "$color" "$level" "$reset" "$*" >&2
}
log_info(){ _log info "$@"; }; log_warn(){ _log warn "$@"; }
log_ok(){ _log ok "$@"; };     die(){ _log error "$@"; exit 1; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ─── Args ─────────────────────────────────────────────────────────────────────
out_dir=""
ref=""
verbatim=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)      shift; out_dir="${1:?--out requires a path}"; shift ;;
        --ref)      shift; ref="${1:?--ref requires a ref}";      shift ;;
        --verbatim) verbatim=1; shift ;;
        --help|-h)  usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done
[[ -n "$out_dir" ]] || out_dir="${LAB_ANSIBLE_DIR:-$HOME/ansible-lab}"
command -v git >/dev/null || die "git is required but not found in PATH"
[[ -d "${SCRIPT_DIR}/control-files" ]] || die "control-files/ not found next to ${LAB_PROG}"

# ─── Clone upstream (shallow) ────────────────────────────────────────────────
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
log_info "cloning ${UPSTREAM}${ref:+ (ref=$ref)} …"
git clone --quiet --depth 1 ${ref:+--branch "$ref"} "$UPSTREAM" "$tmp/src" \
    || die "git clone failed (network? bad --ref '${ref}'?)"

mkdir -p "$out_dir"
rm -rf "${out_dir}/raw" "${out_dir}/infra-ansible"
cp -a "$tmp/src" "${out_dir}/raw"; rm -rf "${out_dir}/raw/.git"
cp -a "$tmp/src" "${out_dir}/infra-ansible"; rm -rf "${out_dir}/infra-ansible/.git"

# ─── Patch: comment AlmaLinux-infra-only roles out of the playbooks ──────────
# A role line is "  - <name>" or "  - role: <name>"; comment the ones that need
# external infra.  Roles directory is never touched.
patch_playbook() {
    awk '
        /^[[:space:]]*-[[:space:]]+(role:[[:space:]]*)?(community\.zabbix\.|devsec\.hardening\.|ipa_client|hashivault|artis3n\.tailscale|almalinux\.wazuh)/ {
            match($0, /^[[:space:]]*/); indent = substr($0, 1, RLENGTH)
            sub(/^[[:space:]]*/, "")
            print indent "# " $0 "   # lab-disabled: needs AlmaLinux infra (Zabbix/IPA/Vault/Tailscale/Wazuh)"
            next
        }
        { print }
    '
}
patched=0
if (( ! verbatim )); then
    while IFS= read -r pb; do
        tmpf="$(mktemp)"
        patch_playbook < "$pb" > "$tmpf" && mv "$tmpf" "$pb"
        patched=$((patched+1))
    done < <(find "${out_dir}/infra-ansible" -maxdepth 1 -name '*.yml' -type f)
    log_info "patched ${patched} playbook(s) (commented infra-only roles); roles untouched"
else
    log_warn "VERBATIM mode: playbooks unpatched — they pull Zabbix/IPA/Vault roles that need AlmaLinux infra"
fi

# ─── Stage the lab overlay + a throwaway control→target SSH key ──────────────
cp -a "${SCRIPT_DIR}/control-files/." "$out_dir/"
mkdir -p "${out_dir}/ssh"; chmod 700 "${out_dir}/ssh"
if [[ ! -f "${out_dir}/ssh/id_ed25519" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C 'almalinux-infra-ansible-lab' -f "${out_dir}/ssh/id_ed25519"
    log_info "generated throwaway lab SSH keypair → ${out_dir}/ssh/id_ed25519"
fi
chmod 600 "${out_dir}/ssh/id_ed25519"

# ─── Summary ─────────────────────────────────────────────────────────────────
log_ok "staged the control-node workdir → ${out_dir}"
log_info "  raw/            verbatim upstream (reference)"
log_info "  infra-ansible/  $( ((verbatim)) && echo 'unpatched' || echo 'patched (infra-only roles commented)')"
log_info "  lab-playbooks/  runnable recipes: $(ls "${out_dir}/lab-playbooks" 2>/dev/null | sed 's/\.yml$//' | paste -sd, -)"
cat >&2 <<EOF

next steps (see examples/ansible/almalinux-infra-ansible/README.md):
  1. Bring up the control + target containers (Phase 5 LXD/Incus):
       phase5-lxd/lab-lxd.sh up --config examples/ansible/almalinux-infra-ansible/ansible-infra-lab.toml
  2. Run a recipe (bootstraps ansible+ssh on first run, then runs it):
       examples/ansible/almalinux-infra-ansible/run-recipe.sh common
EOF

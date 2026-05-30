#!/usr/bin/env bash
# run-recipe.sh — Bootstrap (idempotent) the control + target containers, then
#                 run a curated infra-ansible recipe against the target.
#
#   examples/ansible/almalinux-infra-ansible/run-recipe.sh <recipe> [OPTIONS]
#
# <recipe>  a lab-playbook name, e.g. `common` (resolves lab-playbooks/common.yml
#           in the staged workdir).  Run with no recipe to list the available ones.
#
# First run installs ansible-core + ansible.posix/community.general in the
# control container, python3 + sshd + the lab SSH key on the target, and writes
# the target's live IP into the inventory.  Subsequent runs skip what's already
# done.  Prereqs: `fetch-recipes.sh` (stages ~/ansible-lab) and `lab-lxd.sh up`
# (brings up the containers) — see README.md.
#
# Options:
#   --out       <dir>  control-node workdir (default: ~/ansible-lab)
#   --tags      <t>    pass --tags to ansible-playbook
#   --check            run ansible-playbook in --check (dry-run) mode
#   --rebootstrap      force re-install/re-key even if already bootstrapped
#   --help             show this help and exit

set -euo pipefail

readonly LAB="ansible-infra"
readonly TARGET="lab-${LAB}-target"
readonly CONTROL="lab-${LAB}-control"

_log(){ local l="$1"; shift; local c="" r=""; if [[ -t 2 ]]; then case "$l" in
    info)c=$'\033[36m';;warn)c=$'\033[33m';;error)c=$'\033[31m';;ok)c=$'\033[32m';;esac; r=$'\033[0m'; fi
    printf '%s[%s]%s %s\n' "$c" "$l" "$r" "$*" >&2; }
log_info(){ _log info "$@"; }; log_warn(){ _log warn "$@"; }
log_ok(){ _log ok "$@"; };     die(){ _log error "$@"; exit 1; }
usage(){ sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ─── Args ─────────────────────────────────────────────────────────────────────
recipe=""; out_dir=""; tags=""; check=0; rebootstrap=0
while [[ $# -gt 0 ]]; do case "$1" in
    --out)         shift; out_dir="${1:?}"; shift ;;
    --tags)        shift; tags="${1:?}";    shift ;;
    --check)       check=1; shift ;;
    --rebootstrap) rebootstrap=1; shift ;;
    --help|-h)     usage ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)  [[ -z "$recipe" ]] || die "only one <recipe> allowed"; recipe="$1"; shift ;;
esac; done
[[ -n "$out_dir" ]] || out_dir="${LAB_ANSIBLE_DIR:-$HOME/ansible-lab}"

command -v incus >/dev/null || die "incus not found (this lab uses the Incus engine)"
[[ -d "$out_dir" && -d "$out_dir/lab-playbooks" ]] \
    || die "workdir ${out_dir} not staged — run fetch-recipes.sh first"

# ─── List recipes if none given ──────────────────────────────────────────────
list_recipes(){ for f in "$out_dir"/lab-playbooks/*.yml; do [[ -e "$f" ]] && printf '    %s\n' "$(basename "${f%.yml}")"; done; }
if [[ -z "$recipe" ]]; then
    log_info "available recipes (lab-playbooks):"; list_recipes >&2; exit 0
fi
play="$out_dir/lab-playbooks/${recipe}.yml"
[[ -f "$play" ]] || { log_warn "no recipe '${recipe}'. available:"; list_recipes >&2; die "unknown recipe"; }

# ─── Containers must exist (lab-lxd.sh up) ───────────────────────────────────
for inst in "$TARGET" "$CONTROL"; do
    incus info "$inst" >/dev/null 2>&1 || die "container ${inst} not found — run: phase5-lxd/lab-lxd.sh up --config $(dirname "$0")/ansible-infra-lab.toml"
done

# ─── The /lab mount comes from the TOML (control instance `devices`) ─────────
# Sanity-check it's actually there (e.g. the device wasn't stripped from the
# TOML, or a custom --out doesn't match the TOML's source path).
incus exec "$CONTROL" -- test -e /lab/ansible.cfg 2>/dev/null \
    || die "/lab not mounted in ${CONTROL} (or ${out_dir} not staged). Ensure the control instance's 'devices' mount points at ${out_dir} and re-run: phase5-lxd/lab-lxd.sh up --config $(dirname "$0")/ansible-infra-lab.toml"

# ─── Bootstrap the TARGET: python3 + sshd + the lab key ──────────────────────
if (( rebootstrap )) || ! incus exec "$TARGET" -- test -x /usr/bin/python3 2>/dev/null \
   || [[ "$(incus exec "$TARGET" -- systemctl is-active sshd 2>/dev/null)" != active ]]; then
    log_info "bootstrapping target (python3 + sshd) …"
    incus exec "$TARGET" -- bash -lc 'dnf -y -q install python3 openssh-server passwd && systemctl enable --now sshd' >/dev/null \
        || die "target bootstrap failed"
fi
log_info "authorising the lab SSH key on the target …"
pub="$(cat "$out_dir/ssh/id_ed25519.pub")"
incus exec "$TARGET" -- bash -lc "install -d -m700 /root/.ssh && printf '%s\n' '$pub' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"

# ─── Bootstrap the CONTROL: ansible-core + collections ───────────────────────
if (( rebootstrap )) || ! incus exec "$CONTROL" -- test -x /usr/bin/ansible-playbook 2>/dev/null; then
    log_info "bootstrapping control (ansible-core + ansible.posix + community.general) …"
    incus exec "$CONTROL" -- bash -lc '
        dnf -y -q install ansible-core git openssh-clients python3 &&
        ansible-galaxy collection install -p /root/.ansible/collections ansible.posix community.general >/dev/null' \
        || die "control bootstrap failed"
fi

# ─── Render the inventory with the target's live IP (host-side write) ────────
tip="$(incus list "$TARGET" -c4 --format csv 2>/dev/null | grep -oE '([0-9]+\.){3}[0-9]+' | head -1)"
[[ -n "$tip" ]] || die "could not determine target IP (is ${TARGET} running?)"
sed "s/__TARGET_IP__/${tip}/" "$out_dir/inventory.ini" > "$out_dir/.inventory.rendered" \
    && mv "$out_dir/.inventory.rendered" "$out_dir/inventory.ini"
log_info "target ${TARGET} @ ${tip}"

# ─── Run the recipe from the control container ───────────────────────────────
declare -a pa=(ansible-playbook "lab-playbooks/${recipe}.yml")
[[ -n "$tags" ]] && pa+=(--tags "$tags")
(( check )) && pa+=(--check)
log_info "running recipe '${recipe}' from ${CONTROL} …"
incus exec "$CONTROL" --env ANSIBLE_CONFIG=/lab/ansible.cfg --cwd /lab -- "${pa[@]}"
log_ok "recipe '${recipe}' complete"

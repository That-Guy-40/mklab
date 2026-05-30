# AlmaLinux infra-ansible lab

Run AlmaLinux's **own** infrastructure playbooks — [AlmaLinux/infra-ansible](https://github.com/AlmaLinux/infra-ansible),
the curated recipes they use to build their gitea / keycloak / mattermost /
matrix / mirror / mqtt servers — from an **Ansible control container** against an
**AlmaLinux target container**, both LXD/Incus (Phase 5). The Ansible cousin of
the `kali-preseed-gallery` / `rocky-kickstart-gallery`: it stages the upstream
catalog (verbatim `raw/` + a minimally-patched copy) and curates which recipes
actually run against a vanilla host.

```
fetch-recipes.sh ─► ~/ansible-lab/   (raw/ verbatim + infra-ansible/ patched + lab overlay + ssh key)
lab-lxd.sh up    ─► control + target AlmaLinux containers   (~/ansible-lab mounted at /lab in control)
run-recipe.sh common ─► control  ──ssh:root──▶  target   (applies the upstream 'common' role)
```

---

## What's in this directory

| File | Role |
|---|---|
| `fetch-recipes.sh` | Clone infra-ansible → `~/ansible-lab/` (`raw/` verbatim + `infra-ansible/` patched), stage the lab overlay, generate a throwaway control→target SSH key. |
| `run-recipe.sh` | Bootstrap both containers (ansible on control; python3 + sshd + the key on target), mount `/lab`, render the inventory with the live target IP, run a recipe. |
| `ansible-infra-lab.toml` | Phase-5 config: the `control` + `target` containers. |
| `control-files/` | The lab overlay staged into `~/ansible-lab`: `ansible.cfg`, `inventory.ini`, `group_vars/lab.yml`, `lab-playbooks/`. |
| `README.md`, `MANUAL_TESTING.md` | This file + the run-verify walkthrough. |

The upstream **roles are reused unchanged** (`~/ansible-lab/infra-ansible/roles`);
nothing is vendored into the repo.

---

## The recipe catalog

infra-ansible ships ~14 roles. The lab **runs** a recipe via a thin
`control-files/lab-playbooks/<recipe>.yml` (sets `hosts: lab`, applies the upstream
role, supplies lab vars). Most upstream playbooks lean on AlmaLinux's real infra,
so they're curated:

| Recipe | Status | Notes |
|---|---|---|
| **common** | ✅ **verified** | Base host setup: hostname, EPEL + CRB, firewalld, base packages. The role every other playbook starts with. Runs green + idempotent against a vanilla AlmaLinux 9 container; only lab vars needed (`ssh_authorized_keys`, `common_packages`). |
| gitea, mattermost, matrix_synapse, cachet, keycloak | ⏸ deferred | Service roles that also need a database (geerlingguy.mysql/postgresql), app secrets, and TLS — feasible with extra `group_vars`, but more than a first lab. |
| mqtt | ⏸ deferred | The mosquitto password is pulled from **HashiCorp Vault** (`community.hashi_vault` lookup) — needs a Vault. |
| mirror, almalinux_repo | ⏸ deferred | Full mirror servers (rsync + nginx/caddy + certbot + Route53/Cloudflare DNS). |
| ipa_client, hashivault, astra, people, matterbridge | ⏸ deferred | Tied to FreeIPA / Vault / AlmaLinux-specific services. |

Adding a recipe = drop a `lab-playbooks/<name>.yml` + any vars in
`group_vars/lab.yml`, then `run-recipe.sh <name>`.

---

## Does the upstream need patching for this environment?

**The roles don't — the playbooks do.** Every upstream play also pulls in roles
that need AlmaLinux's real infrastructure:

- `community.zabbix.zabbix_agent` (a Zabbix server),
- `devsec.hardening.os_hardening` / `ssh_hardening` (would also lock down SSH
  mid-run, and need the collection),
- `ipa_client` (FreeIPA), `hashivault` (Vault), `artis3n.tailscale`, `almalinux.wazuh`.

`fetch-recipes.sh` comments out **only those role lines** in the top-level
playbooks (leaving `common` + the service role), keeps the verbatim originals
under `raw/`, and never touches the roles. `--verbatim` skips patching.

Two more environment fits, handled in the lab overlay (not by editing upstream):

- **Vars** the kept roles need come from `control-files/group_vars/lab.yml`
  (`ssh_authorized_keys`, `common_packages`) — AlmaLinux supplies these from its
  own group_vars + Vault.
- **firewalld works fine** in the unprivileged incus container (verified — it
  installs, starts, and applies zone rules), so no patching needed there.

---

## Workflow

Run from the repo root. Replace `/home/sqs` in the TOML with your `$HOME` if
different (it's the disk-device source).

```bash
# 1. Stage the recipe catalog + control workdir (clone + patch + lab overlay + key):
examples/ansible/almalinux-infra-ansible/fetch-recipes.sh

# 2. Bring up the control + target containers (Phase 5 LXD/Incus):
phase5-lxd/lab-lxd.sh up --config examples/ansible/almalinux-infra-ansible/ansible-infra-lab.toml

# 3. Run a recipe (first run bootstraps ansible + ssh + the inventory):
examples/ansible/almalinux-infra-ansible/run-recipe.sh common
#    run with no recipe to list them; --check for a dry run; --rebootstrap to redo setup.
```

Inspect the result:

```bash
incus exec lab-ansible-infra-target -- bash -lc 'hostname; rpm -q epel-release; firewall-cmd --state'
```

**Tear down:**

```bash
phase5-lxd/lab-lxd.sh down --lab ansible-infra
rm -rf ~/ansible-lab          # the staged control workdir + lab SSH key
```

---

## How it works

- **target** — AlmaLinux 9 container; `run-recipe.sh` installs `python3` +
  `openssh-server` and authorises the lab key, so Ansible reaches it as `root`
  over SSH on the `incusbr0` bridge.
- **control** — AlmaLinux 9 container with `ansible-core` + `ansible.posix` +
  `community.general`. `~/ansible-lab` is mounted at `/lab` via the control
  instance's `devices` entry in the TOML (`shift=true` idmaps host ownership so
  the unprivileged container's root can read the files, incl. the 0600 SSH key),
  so it has the inventory, vars, lab-playbooks, the patched roles, and the key.
- The inventory's target IP is re-rendered host-side each run from `incus list`,
  so it survives container restarts.

---

## Security posture

Throwaway lab. `fetch-recipes.sh` generates an **unencrypted** SSH keypair under
`~/ansible-lab/ssh/` and authorises it for `root` on the target; Ansible runs as
root. Fine for local LXD containers on your own machine — **never** point this at
anything you don't own. `~/ansible-lab` (key included) is removed on teardown.

---

## What's verified

`common` was run end-to-end on KVM/Incus: `fetch-recipes.sh` → `lab-lxd.sh up` →
`run-recipe.sh common` configured a vanilla AlmaLinux 9 container (hostname, EPEL,
CRB, firewalld with zone rules, base packages) with **`failed=0`**, and a second
run reported **`changed=0`** (idempotent). The bootstrap is idempotent too (re-runs
skip the installs + the mount). The deferred recipes share this exact path and
differ only in their role's external dependencies (see the catalog).

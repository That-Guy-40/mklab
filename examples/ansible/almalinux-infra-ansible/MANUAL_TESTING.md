# AlmaLinux infra-ansible lab — run-verify walkthrough

Step-by-step manual test with the host-side checks that prove each stage. The
lab is: an Ansible **control** container running a curated infra-ansible recipe
against an AlmaLinux **target** container, both LXD/Incus.

---

## 0. Stage + bring up

```bash
examples/ansible/almalinux-infra-ansible/fetch-recipes.sh
phase5-lxd/lab-lxd.sh up --config examples/ansible/almalinux-infra-ansible/ansible-infra-lab.toml
```

## 1. Verify the staged workdir + patch

```bash
D=~/ansible-lab
ls "$D"                                  # raw/ infra-ansible/ ansible.cfg inventory.ini group_vars/ lab-playbooks/ ssh/
ls "$D"/lab-playbooks                    # common.yml  (the runnable recipes)
test -f "$D"/ssh/id_ed25519 && echo "lab key present"

# The patch comments infra-only roles in the playbooks; roles are untouched; raw is verbatim:
grep -nE 'zabbix|devsec|ipa_client' "$D"/infra-ansible/gitea.yml   # → all '# - …  # lab-disabled'
grep -nE 'zabbix|devsec|ipa_client' "$D"/raw/gitea.yml             # → uncommented (verbatim)
diff -q "$D"/raw/roles/common/tasks/main.yml "$D"/infra-ansible/roles/common/tasks/main.yml && echo "roles identical (untouched)"
```

## 2. Verify the containers

```bash
incus list | grep ansible-infra          # lab-ansible-infra-control + -target, both RUNNING
```

## 3. Run the recipe

```bash
examples/ansible/almalinux-infra-ansible/run-recipe.sh common
```

First run should show the bootstrap then a green play:

```
[info] bootstrapping target (python3 + sshd) …
[info] bootstrapping control (ansible-core + ansible.posix + community.general) …
[info] mounting ~/ansible-lab → lab-ansible-infra-control:/lab …
[info] target lab-ansible-infra-target @ 10.x.x.x
TASK [common : Install firewalld] … changed
TASK [common : Install common packages] … changed
PLAY RECAP: target : ok=10 changed=7 failed=0
```

## 4. Idempotence + dry-run

```bash
examples/ansible/almalinux-infra-ansible/run-recipe.sh common          # → changed=0 (idempotent)
examples/ansible/almalinux-infra-ansible/run-recipe.sh common --check  # → dry-run, no changes
```

A second run skips the bootstrap (no "bootstrapping …" lines) and the recipe
reports `changed=0`.

## 5. Confirm the target was configured

```bash
incus exec lab-ansible-infra-target -- bash -lc '
  hostname                       # → target
  rpm -q epel-release rsync      # installed by common
  firewall-cmd --state           # → running (firewalld works in the container)
  firewall-cmd --list-services'  # ssh + dhcpv6-client, cockpit removed
```

## 6. List / add recipes

```bash
examples/ansible/almalinux-infra-ansible/run-recipe.sh        # lists available lab-playbooks
# add one: drop control-files/lab-playbooks/<name>.yml + vars in group_vars/lab.yml,
# re-run fetch-recipes.sh (re-stages the overlay), then run-recipe.sh <name>.
```

## 7. Tear down

```bash
phase5-lxd/lab-lxd.sh down --lab ansible-infra
rm -rf ~/ansible-lab
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `workdir ~/ansible-lab not staged` | run `fetch-recipes.sh` first. |
| `container lab-ansible-infra-* not found` | run `lab-lxd.sh up --config …ansible-infra-lab.toml` first. |
| ansible can't reach target (ssh) | `--rebootstrap` re-installs sshd + re-authorises the key; check `incus list` shows the target with an IP. |
| `Permission denied (publickey)` reading `/lab/ssh/id_ed25519` | the mount needs `shift=true` (run-recipe adds it); on an old kernel without idmapped mounts, the container root can't read the host 0600 key. |
| recipe needs Vault/FreeIPA/DB | that recipe is deferred — see README catalog. |

> **Verified on KVM/Incus:** `common` ran green (`failed=0`) and idempotent
> (`changed=0` on re-run) against a vanilla AlmaLinux 9 container — hostname, EPEL,
> CRB, firewalld (with zone rules), and base packages all applied.

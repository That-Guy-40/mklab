# Ansible labs

A category of labs that exercise **Ansible** — a control node running playbooks
against one or more managed target hosts — on top of the mklab phase tools.

Unlike the install/PXE labs (which provision a single machine), an Ansible lab
has **two roles**:

```
control node  ──ssh──▶  target host(s)
(runs ansible)          (configured by the playbooks)
```

The labs here use **Phase 5 (LXD/Incus)** system containers for both: they boot
in seconds, run systemd + sshd, and behave like small hosts — the canonical
fast target for Ansible. A throwaway lab SSH key wires control → target.

## Labs in this category

| Lab | What it does |
|---|---|
| [`almalinux-infra-ansible/`](almalinux-infra-ansible/) | Runs AlmaLinux's own [infra-ansible](https://github.com/AlmaLinux/infra-ansible) recipes (the playbooks that build AlmaLinux's gitea/keycloak/mattermost/mirror/… infrastructure) against an AlmaLinux target container. Curated + patched so the recipes run against a vanilla host with no Vault/FreeIPA/Zabbix. |

## Shape of an Ansible lab here

- A `fetch-*.sh` that clones the upstream recipe source and stages a control-node
  workdir (verbatim `raw/` + a minimally-patched copy + the lab inventory/vars/
  playbooks), mirroring the `kali-preseed-gallery` / `rocky-kickstart-gallery`
  convention.
- An `*.toml` (Phase 5) defining the `control` + `target` containers.
- A `run-*.sh` that bootstraps both containers (ansible on control; python/sshd +
  the lab key on target) and runs a chosen recipe.
- `README.md` + `MANUAL_TESTING.md`.

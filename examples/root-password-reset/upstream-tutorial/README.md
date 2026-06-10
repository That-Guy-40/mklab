# Upstream tutorials — provenance & archive

This lab operationalizes **four** distro-specific root-password-reset write-ups.
Three are **vendored byte-exact** here; the fourth (a living wiki) is **cited**
per the repo's two-tier rule.

## Provenance

| # | Title | Author / Publisher | Canonical URL | Retrieved | Archive |
|---|---|---|---|---|---|
| 1 | *Reset lost root password* | ArchWiki contributors | <https://wiki.archlinux.org/title/Reset_lost_root_password> | 2026-06-10 | **cited** — living wiki |
| 2 | *Reset Root Password on Rocky Linux* | CIQ Knowledge Base | <https://kb.ciq.com/article/rocky-linux/rl-reset-root-password> | 2026-06-10 | **vendored** |
| 3 | *How to reset Kali Linux root password* | linuxconfig.org | <https://linuxconfig.org/how-to-reset-kali-linux-root-password> | 2026-06-10 | **vendored** |
| 4 | *Resetting the Root Password on Debian* | ggCircuit Knowledge Base | <https://ggcircuit.atlassian.net/wiki/spaces/GKB/pages/15861051/Resetting+the+Root+Password+on+Debian> | 2026-06-10 | **vendored** |

## Vendored files

| File | sha256 |
|---|---|
| [`rocky-ciq-reset.html`](rocky-ciq-reset.html) | `1a4c0a75e914598ffa5caa330e04bdf03eef0ad73672cad7b685469b67de838b` |
| [`kali-linuxconfig-reset.html`](kali-linuxconfig-reset.html) | `b0e741d0481a8dc1ad57b96fa79ba8348288839c6755e7180e54532796a2500f` |
| [`debian-ggcircuit-reset.html`](debian-ggcircuit-reset.html) | `bf9c6b7caea80d1d1fcaa4026c2420ad1034c1321cd14cc4407ee4a866fac3ba` |

**How each was captured.** The CIQ/Rocky page was fetched **as served**
(`curl`, HTTP 200). The linuxconfig/Kali and ggCircuit/Debian pages are
**browser-saved (rendered DOM)** — linuxconfig sits behind **Cloudflare** (HTTP
403 to non-interactive fetches) and ggCircuit is an Atlassian **Confluence** page
whose body is rendered client-side, so a plain `curl` returns no recipe text; the
saved HTML carries the full procedure and reads offline (external CSS/JS/images
are not vendored — only the static markup is needed for the steps). The RUNBOOKs
were reconciled **against these exact files**, not from memory.

## Why Arch is cited, not mirrored

The ArchWiki page is a **living wiki** (continuously edited), so the convention is
to cite it (URL + retrieved date) rather than enshrine a snapshot. Its two methods
are reproduced faithfully in [`../RUNBOOK-init-shell.md`](../RUNBOOK-init-shell.md)
(`init=/bin/bash`) and [`../RUNBOOK-systemd-debug-shell.md`](../RUNBOOK-systemd-debug-shell.md)
(`systemd.debug_shell`).

## Copyright & attribution

Each tutorial is the work of its respective author/publisher (ArchWiki
contributors — CC BY-SA / GFDL; **CIQ**; **linuxconfig.org**; **ggCircuit**), and
**all rights remain with them.** The archived copies exist solely as offline,
fixed-point references for the [`../`](../) lab, which reimplements these recipes
on `lab-vm.sh` VMs. For the authoritative, maintained versions — and to support
the authors — always use the canonical URLs above. If you are a rights holder and
would prefer an archived copy not be redistributed, removing it is a one-line
`git rm`.

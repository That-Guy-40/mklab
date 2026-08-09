# RPM-dependency-hell-in-the-yum-shell — bottled hell, and three roads out

**"And as so many times before, it is a shell that solves our problems."**
Sigurd Urdahl's
[*yum shell - bat out of dependency hell*](upstream-tutorial/redpill-linpro/techblog/2018/01/22/bat_out_of_dependency_hell.html)
(Redpill Linpro techblog, 2018, vendored byte-exact) is a war story in three
beats: a one-package `yum install` refused by a package **conflict**; the
"obvious" `yum remove` whose transaction table quietly lists **six innocent
production packages** as collateral ("Very much not OK"); and the turn —
noticing the word *transaction* in yum's own output and realizing that
`yum shell` lets `remove` + `install` ride **one transaction**, so the shared
library the bystanders need is never unprovided, and nothing cascades.

This lab bottles his hell so it can be entered on demand: a **throwaway Rocky
Linux 9 system container** — where `/usr/bin/yum` *is* dnf, so his commands run
**verbatim** — with a **local repo of ten tiny metadata-only RPMs** recreating
his Percona conflict topology name for name, a sudo-capable non-root
**`learner`**, and a `~/dependency-hell/` sandbox whose **`demo.sh`** enters
the hell and escapes it **three ways**, proving each is one transaction with
zero bystanders harmed. Built and driven through the repo's **Phase-5** tool
([`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/)), which speaks **LXD or Incus**
identically.

## The cast: his topology, renamed after his own epigraph

The article opens quoting Meat Loaf's *Bat out of Hell*, so the fake packages
do too — nothing in the lab shadows a real repository. Ten noarch,
payload-free RPMs ([`bin/build-bat-hell-repo.sh`](bin/build-bat-hell-repo.sh)):
dependency hell is pure metadata, so an empty `%files` is all it takes.

| the article (EL7, Percona) | this lab | role |
|---|---|---|
| `Percona-Server-shared-56` | `bat-shared-56` | **installed**; provides `libbat.so.18` |
| `Percona-Server-shared-compat-57` | `bat-shared-compat-57` | provides `libbat.so.18`; **Conflicts** with `bat-shared-56` — the crux |
| `Percona-Server-shared-57` | `bat-shared-57` | requires compat-57 |
| `Percona-Server-client-57` | `bat-client-57` | **what you actually wanted to install** |
| `postfix` | `meatloaf-mta` | bystander: requires `libbat.so.18`; provides `mta` |
| `MySQL-python` | `python-bat` | bystander: requires `libbat.so.18` |
| `perl-DBD-MySQL` | `perl-DBD-bat` | bystander: requires `libbat.so.18` |
| `fail2ban` | `hellban` | bystander: requires `hellban-sendmail` |
| `fail2ban-sendmail` | `hellban-sendmail` | bystander: requires `mta` |
| `redhat-lsb-core` | `hell-lsb-core` | bystander: requires `mta` — his "Very much not OK" |

One soname, two mutually exclusive providers, six packages standing on it.
That is the whole machine — his diagnosis verbatim: *"several major versions
of a program available, all providing some of the same functionality to other
packages, all being mutually exclusive."*

## Quick start

```bash
# 1) launch the Rocky 9 container
phase5-lxd/lab-lxd.sh up --config examples/RPM-dependency-hell-in-the-yum-shell/yum-shell-rocky.toml

# 2) provision: build the bat-hell repo, install the baseline, cut the box
#    offline, create the learner, push + run demo.sh              (~2 min)
examples/RPM-dependency-hell-in-the-yum-shell/setup-workshop.sh yum-shell-rocky/shell

# 3) descend by hand — RUNBOOK.md with the article open
phase5-lxd/lab-lxd.sh exec yum-shell-rocky/shell -- su - learner

# 4) tear down
phase5-lxd/lab-lxd.sh down --lab yum-shell-rocky
```

## `demo.sh` proves it, it doesn't just show it

Twenty-three checks over seven acts — the hell must *refuse* correctly, the
trap must *threaten* correctly (and be declined), and each escape must be one
transaction that touches exactly two library packages:

```
   [ok]  yum on this box is the dnf compat CLI (article commands run verbatim)
   [ok]  the install is refused (exit status)
   [ok]  the refusal names the crux: compat-57 conflicts with bat-shared-56
   [ok]  the cascade would take all 6 innocent bystanders ("Very much not OK")
   [ok]  transaction summary: Remove 7 Packages — for a 1-package problem
   [ok]  --assumeno said N for us: rc=1 and nothing was actually removed
   [ok]  yum shell ran the swap (exit status)
   [ok]  all 6 bystanders survived — the entire point of the article
   [ok]  dnf history agrees: ONE transaction holds both the Install and the Removed
   ...
PASS: all 23 checks hold (yum shell == dnf swap == --allowerasing; 6 bystanders, 0 harmed)
```

The ground truth for "one transaction" is **`dnf history info last`**, not the
scroll-by output: the history database records which marks rode together, which
is precisely the claim the article turns on.

## Three roads out, one destination

| road | spelling | existed in 2018? |
|---|---|---|
| 1 | `yum shell` → `remove` + `install` + `run` (his fix, **verbatim**) | yes — the article |
| 2 | `dnf swap bat-shared-56 bat-shared-compat-57` | **no** — the trick became a verb |
| 3 | `dnf install --allowerasing bat-client-57` | **no** — the *error message* now prints the way out |

`demo.sh` runs all three (resetting the hell between roads —
[`bin/reset-hell.sh`](bin/reset-hell.sh), offline, ~1 s) and asserts the end
states are **identical, package for package**. Road 3 is the closed loop worth
savoring: his EL7 yum could only suggest `--skip-broken`, which cannot help —
nothing is *broken*, something is *conflicting*. EL9's dnf suggests
`--allowerasing` inside the very refusal, and the depsolver then erases
**exactly the one package** he had to identify by hand in 2018. The article's
hard-won insight is now a hint printed at the moment of failure — and
`yum shell` remains the general form (arbitrary marks, one transaction) that
the two one-liners are special cases of.

## Documented 2018 → now deltas

| | his EL7 box | this Rocky 9 box |
|---|---|---|
| `yum` | yum proper (python depsolver) | **the `dnf-3` compat CLI** — same commands, libsolv underneath |
| conflict advice | `--skip-broken` (useless here) | **`--allowerasing`** (solves the whole post) |
| swap-in-one-transaction | only via `yum shell` | `yum shell` still works **verbatim**, + `dnf swap` |
| transaction log | `yum history` | `dnf history` — `info last` is demo.sh's oracle |
| loaded-plugins banner | `Loaded plugins: fastestmirror, priorities` | gone (dnf loads quietly) |

## Files

| File | Purpose |
|---|---|
| [`yum-shell-rocky.toml`](yum-shell-rocky.toml) | Phase-5 spec: one Rocky 9 container |
| [`setup-workshop.sh`](setup-workshop.sh) | Provision: tools → bat-hell repo → baseline → offline → `learner` → sandbox → run demo |
| [`demo.sh`](demo.sh) | The seven acts; **23 checks**; ends on `PASS:`/`FAIL:` |
| [`bin/build-bat-hell-repo.sh`](bin/build-bat-hell-repo.sh) | Ten spec files, `rpmbuild`, `createrepo_c`, the `.repo` file — hell as code |
| [`bin/reset-hell.sh`](bin/reset-hell.sh) | Back to the article's opening state, from any state, offline |
| [`RUNBOOK.md`](RUNBOOK.md) | The by-hand walk — every step, with the *why* |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Real captured transcripts, incl. both negative controls |
| [`upstream-tutorial/`](upstream-tutorial/README.md) | Byte-exact archive of the article + CSS + provenance |

## Scope & caveats

- **Throwaway lab.** Containers are disposable; `down` wipes them. Re-run the
  quick start for a clean slate.
- **The hell is fake; the mechanics are not.** The ten RPMs are payload-free
  stand-ins, but the depsolver, the transaction machinery, `yum shell`,
  `dnf swap`, `--allowerasing` and `dnf history` are the real EL9 stack doing
  exactly what it does in production. Only the stakes are simulated.
- **`Provides: libbat.so.18` is a plain string.** A real library package's
  soname provide is generated from the payload and spelled
  `libbat.so.18()(64bit)`; the flat string keeps the packages noarch. The
  resolution logic being demonstrated is identical.
- **The box goes offline after provisioning** (mirrors disabled) so the walk
  is deterministic and fast; [RUNBOOK §7](RUNBOOK.md#7-optional-excursions)
  shows the one-line re-enable.
- **`--allowerasing` deserves its paranoia.** The lab *proves* it erases
  exactly one package *here*; the lesson to export is "read the transaction
  table", not "the flag is always polite".
- **Root is used deliberately.** Package transactions are root's job; the
  `learner` sudoes them like any operator. This is the one shell-path lab
  where that is the realistic posture, not a compromise.
- **Read the article on the host, type in the container.** It lives in this
  repo; the offline copy renders unstyled over `file://` —
  [serving instructions](upstream-tutorial/README.md#opening-it-offline).

## Prerequisites

- **LXD or Incus initialised** — `incus admin init` (or `lxd init`). See the
  Phase-5 docs: [`START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md).
- Outbound network from the container **once**, for step 2 of provisioning
  (`rpm-build`, `createrepo_c`, `sudo`); everything after is local.

## Sources

The page states **no license**, and is vendored byte-exact for **offline
educational reference** under [`upstream-tutorial/`](upstream-tutorial/README.md)
(provenance + `sha256` + attribution).

- <https://www.redpill-linpro.com/techblog/2018/01/22/bat_out_of_dependency_hell.html>

**Kinship:** the shell-fluency path teaches the interactive shell as a
*language*; this lab is the same lesson from ops-land — the moment a sysadmin's
day is saved by recognizing that a package manager's REPL exists precisely so
that several verbs can share **one transaction**. The nearest EL neighbors in
the catalog are [`rocky-kickstart-gallery/`](../rocky-kickstart-gallery/) and
[`rocky-pxe-lab/`](../rocky-pxe-lab/), which install Rocky boxes this lab then
breaks in a controlled fashion.

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog.

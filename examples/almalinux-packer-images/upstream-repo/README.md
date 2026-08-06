# Upstream archive — `AlmaLinux/cloud-images`, vendored in full

A **byte-exact archive of the complete upstream repository** — the Packer builder that
produces AlmaLinux's *official* cloud and VM images. Everything below `cloud-images/` is
upstream's, unmodified; this file and `SHA256SUMS` are the only additions.

## Provenance

| | |
|---|---|
| **Project** | AlmaLinux Cloud Images — the official Packer/Ansible image factory |
| **Canonical URL** | <https://github.com/AlmaLinux/cloud-images> |
| **Pinned commit** | `6d808bf710be1ca57c456f91db5d2d750e92d4e3` |
| **Commit date** | 2026-07-30 |
| **Default branch** | `main` |
| **Retrieved** | 2026-08-06 |
| **Status upstream** | **Active.** Unlike [`kali-packer`](../../kali-packer-vagrant/upstream-repo/), this repo is maintained — see the caveat below |
| **Files / size** | 563 tracked files, ~3.9 MB |
| **License** | Upstream [`LICENSE`](cloud-images/LICENSE) |

**All rights remain with the AlmaLinux OS Foundation and contributors.** Archived for
offline reference and reproducibility; nothing is relicensed. To remove:
`git rm -r examples/almalinux-packer-images/upstream-repo/`.

## ⚠️ The vendoring argument is weaker here than for Kali, and that is worth saying

[`CLAUDE.md`](../../../CLAUDE.md) says a lab following upstream **code** should *cite, don't
mirror*. [`TODO.md`](../../../TODO.md) item 7 documents the exception — a builder must be
**available in whole, runnable per its own instructions** — and for Kali that argument is
strong: **that** repo is retired, so a URL is a poor custodian of something nobody
maintains.

**This repo is alive.** Its last commit is a week before this snapshot. So the archive:

- **is a dated snapshot, not a mirror.** It will diverge, and that divergence is *expected*
  rather than a defect. The pin and the retrieved date above are the whole point — they say
  *which* AlmaLinux factory this lab operationalizes.
- **must not become the thing people read instead of upstream.** For "what does AlmaLinux
  build today", go to the canonical URL. For "what did this lab build, and can I rebuild it
  offline in a year", read the archive.
- **is verified on every use, not trusted.** `fetch-cloud-images.sh` checks `SHA256SUMS`
  before staging and refuses a mismatch, so a locally-edited archive cannot quietly become
  the thing that builds.

Run `fetch-cloud-images.sh --upstream` to build from live `main` instead and see what has
moved.

## What else already consumes this repository

[`../../almalinux-kickstart-gallery/`](../../almalinux-kickstart-gallery/) pulls **only**
`http/*.ks` from it, and clones an **unpinned** `main` at run time. This lab is the
complementary half: the whole builder, pinned, offline. The two are deliberately not
merged — the gallery is about *kickstarts as a catalog*, this is about *the image factory
as a mechanism*.

## Files

563 files; the per-file digests live in [`SHA256SUMS`](SHA256SUMS) rather than a table
nobody could read. Verify the whole archive at any time:

```sh
cd examples/almalinux-packer-images/upstream-repo
sha256sum -c SHA256SUMS        # 563 lines, all OK
```

Shape of the tree:

| path | files | what it is |
|---|---|---|
| [`cloud-images/`](cloud-images/) *(top level)* | 66 | one `*.pkr.hcl` per target (AMI, Azure, GCP, OCI, OpenNebula, Vagrant, gencloud…) × releases 8/9/10, plus `variables.pkr.hcl` |
| [`cloud-images/tests/`](cloud-images/tests/) | 194 | the image test suite |
| [`cloud-images/ansible/`](cloud-images/ansible/) | 186 | the provisioning roles Packer runs |
| [`cloud-images/http/`](cloud-images/http/) | 52 | **the kickstarts** — the slice the gallery consumes |
| [`cloud-images/.github/`](cloud-images/.github/) | 46 | upstream CI (not run here) |
| [`cloud-images/vm-scripts/`](cloud-images/vm-scripts/), [`tools/`](cloud-images/tools/), [`tpl/`](cloud-images/tpl/) | 19 | helper scripts and templates |

### One file needs `git add -f`, and the check is why we know

Upstream ships a `.gitignore` containing `*.pkrvars.hcl`, and it also **tracks**
`tests/test-values.pkrvars.hcl`. Vendored verbatim, that `.gitignore` applies to *our*
subtree — so a plain `git add` silently drops that one file and the archive stops being
complete, with nothing reporting it. It is force-added, and the 563-file count in
`SHA256SUMS` is what makes a future omission visible.

*(The same trap was checked for the Kali archive and did not fire there. It is checked, not
assumed, because "vendoring a `.gitignore` changes your own repository's ignore rules" is
not obvious until it costs you a file.)*

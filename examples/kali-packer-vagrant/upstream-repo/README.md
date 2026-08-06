# Upstream archive — `kali-packer`, vendored in full

A **byte-exact archive of the complete upstream repository**, so this lab is
reproducible **offline** and its provenance is explicit. Everything below
`kali-packer/` is upstream's, unmodified; this file is the only addition.

## Provenance

| | |
|---|---|
| **Project** | Kali-Packer — Kali's HashiCorp Packer configs for building Kali Vagrant base boxes |
| **Canonical URL** | <https://gitlab.com/kalilinux/build-scripts/kali-packer> |
| **Pinned commit** | `b8c9b34efc553a3744b39387d359b89ede04267b` |
| **Commit subject** | `GitLab: issues -> work_items` — Ben Wilson, 2026-03-25 |
| **Default branch** | `main` |
| **Retrieved** | 2026-08-06 |
| **Status upstream** | **Retired / "no longer in production."** Kali moved to [debos](https://gitlab.com/kalilinux/build-scripts/kali-vm) at the 2025.2 release; these scripts no longer produce the published Vagrant boxes |
| **License** | Upstream [`LICENSE`](kali-packer/LICENSE) records that `scripts/minimize.sh` is altered from [chef/bento](https://github.com/chef/bento) (**Apache-2.0**); the remainder is Kali's own build tooling |

**All rights remain with the respective authors.** This copy is archived purely
for offline reference and reproducibility; nothing here is relicensed. To remove
it, `git rm -r examples/kali-packer-vagrant/upstream-repo/`.

## Why a full vendor, when the repo's default is *cite, don't mirror*

[`CLAUDE.md`](../../../CLAUDE.md) says a lab that follows upstream **code** should
cite rather than archive. This is the documented exception
([`TODO.md`](../../../TODO.md) item 7): the requirement is that the builder be
**available in whole, runnable per its own instructions**, which a build-time
`git clone` cannot satisfy without the network.

That difference is not theoretical. The upstream project is **retired**, its
last commit is from 2026-03-25, and a retired GitLab repo is exactly the kind of
subject that disappears out from under a lab that only holds a URL. The pin was
already recorded in [`../UPSTREAM.md`](../UPSTREAM.md); what was missing was the
bytes it names.

**The pin was re-derived, not trusted.** The commit archived here is the same
`b8c9b34e…` that `UPSTREAM.md` recorded on 2026-07-03, confirmed by a fresh
clone on 2026-08-06 — upstream has not moved since. A recorded hash whose
subject nobody re-checked is a cached fact; this one was checked.

## Files

Every file upstream tracks, with the sha256 of the archived bytes. Verify the
whole archive at any time with:

```sh
cd examples/kali-packer-vagrant/upstream-repo
sha256sum -c SHA256SUMS
```

| File | sha256 |
|---|---|
| [`config.pkr.hcl`](kali-packer/config.pkr.hcl) | `e8d91b2a6e72dde259a4c8835ba15ea306ca6b6b89e750c02356781a0762c10a` |
| [`.gitignore`](kali-packer/.gitignore) | `d37dadc573ce8afbdefeeda40e965c25b5891070be631fe2f4df3b006a9b8967` |
| [`.gitlab-ci.yml`](kali-packer/.gitlab-ci.yml) | `7b25ddcfbb15a9d48f57f2a380f605d08229696ef78a3888080153199bac8fe5` |
| [`.gitlab/images/heatmap.png`](kali-packer/.gitlab/images/heatmap.png) | `ac7ad02e2578c11d0cd60867e79299dccadcf6d2ad55759b3c8796ca3d1358cc` |
| [`.gitlab/images/hypervisor.png`](kali-packer/.gitlab/images/hypervisor.png) | `112eb37729179457858be4f82e0ef56771107c8c980a283acfc37debf8f33f71` |
| [`.gitlab/images/machine.png`](kali-packer/.gitlab/images/machine.png) | `93eb2c6c720c609b240c3c11247c416dbb0849cb12c82dac425eb905732c3c49` |
| [`http/preseed.cfg`](kali-packer/http/preseed.cfg) | `6fce7ac9d4e04fc3df52e71e89ad62393b81eeae7077d3ccbb27a33041ad36be` |
| [`kali.pkrvars.hcl.template`](kali-packer/kali.pkrvars.hcl.template) | `f584aed3acc273377423f88117a6777a419d744d9fe5c5484764d6f15764b4f9` |
| [`legacy/config.json`](kali-packer/legacy/config.json) | `420cba94d7b7d0b3dd1b1553b5ae7bd1486a89f279c9ce4ef084df5f74071c85` |
| [`legacy/kali-vars.json.template`](kali-packer/legacy/kali-vars.json.template) | `452f73c6c919e875ad1840244ce813a4b7c0687628991a9e35ddefb03aa61386` |
| [`LICENSE`](kali-packer/LICENSE) | `723c4bf01b7416f05479f547915b524ab5b76344885e63ed046bff4a39acc6af` |
| [`README.md`](kali-packer/README.md) | `e95125cc2727c079c8b00c5645d1e87049c0aa6b466239003f905143447892df` |
| [`README.packer.md`](kali-packer/README.packer.md) | `bf47ebca432ec76ef0058d0ce73aa3d963a8fbb5dc471bc4514f569c038a990c` |
| [`README.vagrant.md`](kali-packer/README.vagrant.md) | `6f389f0ef24b0674428e43512be7a272a9370d8268f38190870e96c88cfdc191` |
| [`scripts/minimize.sh`](kali-packer/scripts/minimize.sh) | `d99786a41cdb39f3ae0c9c9e287460f2b1522cefe7148685c8987b1aefcfa36e` |
| [`scripts/vagrant.sh`](kali-packer/scripts/vagrant.sh) | `00c2311020d3092efc36a4e23b9aded6b5573626c7d00956cfb9a62ee8215d60` |
| [`Vagrantfile.tpl`](kali-packer/Vagrantfile.tpl) | `a0c8fb5b98cd0693530ddc839c02c5ab440594cc1294c75a9bcd97446be8605f` |

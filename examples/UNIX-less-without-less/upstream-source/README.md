# upstream-source/ — the original `ddpager` project, byte-exact

This directory archives the lab's source material **byte-exact**, per the
repo's provenance convention. Unlike the sibling Matt Might labs, the upstream
here is not a web tutorial — it is **first-party work**: a pager written by
this repo's author together with an earlier Claude instance (Claude Opus 4.x),
in spring 2026, as a private bash experiment with its own git repo and a full
documentation set. Everything is vendored so the lab is self-contained and
the object of study can never drift.

## Provenance

| | |
|---|---|
| **Title** | `ddpager` — a less-like pager using BASH builtins, dd, and tput |
| **Authors** | the repo author + an earlier Claude instance (Claude Opus 4.x), pair-authored |
| **Original path** | `~/scripts/BASH_EXPERIMENTS/WORKING_PROJECTS/pager_less_more_shell-script/working_copy/` |
| **Git** | single commit `930b975` — "Initial commit: ddpager 0.1.0" — 2026-04-15 |
| **Version** | 0.1.0 (`DDPAGER_VERSION` in the script) |
| **Retrieved** | 2026-07-18 (copied byte-exact from the working copy) |
| **License** | first-party work by the repo author; vendored with the author's request |

## Integrity

| file | what it is | sha256 |
|---|---|---|
| [`ddpager.sh`](ddpager.sh) | **the pager — canonical** | `96edd0965de6cd33fa12b24814f7d5c64c518056ebcb723cb7628cbc21d7866a` |
| [`ddpager-README.md`](ddpager-README.md) | the project's own README | `9e3626dd1e03411ee87fa24d3d89287a10cb232e6489f91a2a267dcd87604642` |
| [`USAGE.md`](USAGE.md) | user guide / command reference | `339218c5df2404a346e87f5c68c6c31b3d618323f88a0ed88f23cab17c1ebc37` |
| [`DESIGN.md`](DESIGN.md) | architecture deep dive | `a9ce13b70f6035851539692957029e30f6a3613a491bae92ba1241338474a3fe` |
| [`FEATURES.md`](FEATURES.md) | feature breakdown | `383597282fd48f16a72e5166e3eeea81c1b5ae559ff424e41e2c68feca5045f2` |
| [`MAINTENANCE.md`](MAINTENANCE.md) | troubleshooting guide | `a378daffa7be54d5c6c17a172b3e8c5824b2b532ea0af7df444d526074a4d1ab` |
| [`SHOWCASE.md`](SHOWCASE.md) | demo walkthrough | `51b3ae34933606fcdd29e351523f8625c754fd8cfe8683a634bb4aa514ba73e4` |
| [`test_cmds.sh`](test_cmds.sh) | the project's test script (a stub — see below) | `986b29982bc68e4a5cdb3be757a2bc7c260b9e59e39ec2b4ea60e3dc74b08a50` |

[`../bin/ddpager`](../bin/ddpager) is `ddpager.sh` under the runnable name;
`../demo.sh` asserts that equality (by sha256) on every run.

## A caveat the lab is built on

**The script is canonical; the six companion documents are period
documentation and may not match the code** (the author says so, and the lab
verified it). What checking found:

- `USAGE.md`'s claim that **Ctrl-C exits 130** is *true* — but for a subtler
  reason than it knew: the pager's own `stty raw` should *prevent* SIGINT,
  and it is bash's `read -n1` that quietly re-enables it (proven in
  [`../demo.sh`](../demo.sh), section 4).
- The README's "optionally uses **socat** for readline integration" describes
  an aspiration; no code path invokes socat.
- `test_cmds.sh` is an honest stub — it prints manual-test instructions and
  admits "This is complex - better to manual test". The lab's
  [`../demo.sh`](../demo.sh) + [`../drive-pager.py`](../drive-pager.py) are
  the automation it wished for.

Read the vendored docs for the *intent*; read
[`../RUNBOOK.md`](../RUNBOOK.md) for the *mechanics as verified*.

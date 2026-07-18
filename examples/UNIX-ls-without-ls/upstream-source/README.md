# upstream-source/ — the original `ddls`, byte-exact

This directory archives the lab's source material **byte-exact**, per the
repo's provenance convention. Unlike the sibling Matt Might labs, the upstream
here is not a web tutorial — it is **first-party work**: a script written by
this repo's author together with an earlier Claude instance (Claude Opus 4.x),
in spring 2026, as a private bash experiment. It is vendored so the lab is
self-contained and the object of study can never drift.

## Provenance

| | |
|---|---|
| **Title** | `ddls` — an ls replacement using BASH builtins, stat, tput ~~and dd~~ |
| **Authors** | the repo author + an earlier Claude instance (Claude Opus 4.x), pair-authored |
| **Original path** | `~/scripts/BASH_EXPERIMENTS/WORKING_PROJECTS/LS_SHELL_SCRIPT/ddls.sh.txt` |
| **File date** | 2026-03-21 (mtime; the project has no git history) |
| **Version** | 0.1.0 (`DDLS_VERSION` in the script) |
| **Retrieved** | 2026-07-18 (copied byte-exact from the original path) |
| **License** | first-party work by the repo author; vendored with the author's request |

## Integrity

| file | sha256 |
|---|---|
| [`ddls.sh.txt`](ddls.sh.txt) | `45437be6ab84316fab53069ca1052bccddaf9363b92f66ed547d5ba1e660e47a` |

[`../bin/ddls`](../bin/ddls) is the same bytes under the runnable name;
`../demo.sh` asserts that equality (by sha256) on every run, so the verbatim
copy cannot be silently "improved".

## A caveat the lab is built on

The script's **own header does not match its code** — the lab treats the
script as canonical and its self-description as data to be checked:

- the header says the tool uses **`dd`**; nothing in it ever invokes dd
  (the `dd` in the name is family branding, shared with `ddpager`);
- a comment says stat's `-L` is used "to NOT follow symlinks" — `-L` would
  *follow* them, and the code (correctly) never passes it;
- the stated constraint, "no other text-processing externals", is broken by
  one `dirname` call.

All three are pinned by checks in [`../demo.sh`](../demo.sh) and discussed in
[`../README.md`](../README.md#documented-errata).

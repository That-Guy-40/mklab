# SOURCES.md — provenance (cite-don't-mirror)

Per the repo's provenance convention
([CLAUDE.md §Provenance](../../CLAUDE.md)), this lab operationalizes **official
docs + upstream release notes + upstream reference code** — several sources, not
one blog page — so it **cites** them with retrieved dates rather than vendoring a
byte-exact `upstream-tutorial/` archive. All links verified reachable on the
**Retrieved** date below.

**Retrieved:** 2026-07-11.

## systemd 261 — the directives this lab centers

| What | URL | Note |
|---|---|---|
| systemd v261 release + NEWS | https://github.com/systemd/systemd/releases/tag/v261 | Source of truth for `ConditionSecurity=measured-os`, `RestrictFileSystemAccess=`, `ConditionFraction=`, `ConditionMachineTag=`, `systemd-tpm2-swtpm.service`, `systemd-repart … BlockDeviceReplace=`. Released 2026-06. |
| `systemd.unit(5)` — conditions | https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html | `ConditionSecurity=`, `ConditionFraction=`, `ConditionMachineTag=`. |
| `systemd.exec(5)` — sandboxing | https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html | `RestrictFileSystemAccess=`. |
| `systemd-repart(8)` | https://www.freedesktop.org/software/systemd/man/latest/systemd-repart.html | `BlockDeviceReplace=`, verity `Verity=`/`VerityMatchKey=`. |
| `systemd-sysupdate(8)` / `sysupdate.d(5)` | https://www.freedesktop.org/software/systemd/man/latest/sysupdate.d.html | A/B `*.transfer` files. |

> Man pages track the latest systemd; when the pinned nixpkgs systemd differs,
> read the man pages shipped by that exact build (`man systemd.unit`). The v261
> release page above is the version-pinned reference.

## NixOS — reproducible immutable images with `image.repart`

| What | URL | Note |
|---|---|---|
| NixOS `image.repart` module | https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/image/repart.nix | The module `nix/image.nix` configures; option names track the pinned rev. |
| Reproducibility gotcha #286969 | https://github.com/NixOS/nixpkgs/issues/286969 | `systemd-repart` namespace drops `SOURCE_DATE_EPOCH`/`TZ`; worked around in `nix/image.nix`. |
| Moritz Sanft — reproducible immutable NixOS (All Systems Go! 2024) | https://github.com/msanft/reproducible-immutable-nixos | Reference implementation this lab's structure mirrors. |
| applicative-systems — simple systemd-repart NixOS image | https://github.com/applicative-systems/simple-systemd-repart-nixos-image | Second reference for the ESP/root/verity partition split. |

## Pinning

The exact nixpkgs revision is pinned in `nix/flake.lock` (created by
`nix flake update`). Record the rev + date here when you lock it:

```
nixpkgs = github:NixOS/nixpkgs/<rev>   # locked <date>; systemd <version>
```

If that systemd is `< 261`, use the overlay sketched in
[`nix/configuration.nix`](nix/configuration.nix) pointing `src` at the
`v261` tag from the systemd release page above, and record its hash here.

## Copyright / attribution

All rights to the cited works remain with their authors and projects (systemd —
the systemd contributors; NixOS — the NixOS/nixpkgs contributors; the two
reference repos — their respective authors). Nothing here is redistributed; these
are pointers for offline reproduction. Remove any pin you no longer need.

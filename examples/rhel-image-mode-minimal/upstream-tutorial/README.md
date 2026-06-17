# Upstream tutorial — archived copy

A **byte-exact archive** of the Red Hat documentation chapter that this lab
operationalizes, vendored here for offline reference and provenance.

| | |
|---|---|
| **Title** | *Chapter 9. Creating bootc images from scratch* |
| **In** | *Using image mode for RHEL to build, deploy, and manage operating systems* |
| **Publisher** | Red Hat, Inc. |
| **Product / version** | Red Hat Enterprise Linux 9 (image mode) |
| **Canonical URL** | <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/generating-a-custom-minimal-base-image> |
| **Retrieved** | 2026-06-16 |

> **Note — living, versioned source.** Per this repo's provenance convention,
> official doc sites are normally *cited, not mirrored*. We vendor this one page
> anyway (it was explicitly requested for offline study, and `docs.redhat.com` is
> hard bot-walled — see below), but treat it as a **point-in-time snapshot**: the
> live page tracks the current RHEL 9 minor and may change. Always go to the
> canonical URL for the authoritative, current version.

## Files

| File | sha256 |
|---|---|
| [`generating-a-custom-minimal-base-image.html`](generating-a-custom-minimal-base-image.html) | `123d958986df6fc82ef3dde47384a938e52f9d035bda54e11b775c43b50c54b5` |

## What is and isn't vendored

Saved from a browser as **"Web Page, HTML Only"** — a single self-contained
`.html` (no asset folder). The **full chapter text and every code block** are
present and readable offline with no network: the §9.1 pinned-content example,
the §9.2 minimal example (`build-rootfs --manifest=minimal` + the
`NetworkManager cowsay` customization), the §9.3 required-privileges flags, the
§9.4 from-scratch example (`NetworkManager openssh-server`), and the §9.5
`rechunk` command.

**Not vendored:** the docs site's CSS/JS/theme chrome and fonts (loaded by
absolute URL from `docs.redhat.com` and CDNs). Mirroring a docs platform's whole
asset pipeline is neither practical nor the point; opened in a browser the page
renders unstyled-but-complete. This is the convention's "many assets → cite the
chrome, mirror the content that matters" case.

The file was **renamed** from the browser's default
(`Chapter 9. Creating bootc images from scratch _ … .html`) to the URL slug for
clean Markdown links; the **bytes are unchanged** (sha256 above).

### Acquisition note

`docs.redhat.com` returns Akamai **HTTP 403 "Access Denied"** to every
non-browser fetch (`curl`/`wget`/WebFetch, any user-agent) — the same bot-wall as
this repo's linuxconfig/Confluence sources. So this page **cannot** be re-fetched
by a script; it was saved by hand from a logged-in browser. Verify a refresh the
same way (Ctrl-S → HTML Only), confirming the title is *"Creating bootc images
from scratch"* (not an error stub) before re-hashing.

## Copyright & attribution

This documentation is **© Red Hat, Inc.**, and **all rights and copyright remain
with Red Hat.** It is archived here solely as an offline, fixed-point reference
for the [`../`](../) lab, which reproduces the minimal-bootc-base-image procedure
on CentOS Stream 9 (RHEL 9's upstream). For the authoritative, current version
always use the [canonical page](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/generating-a-custom-minimal-base-image).
If you are the rights holder and would prefer this copy not be redistributed,
removing it is a one-line `git rm`.
